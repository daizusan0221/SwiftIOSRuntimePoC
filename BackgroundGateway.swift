import BackgroundTasks
import SwiftUI
import UIKit

@MainActor
final class BackgroundGateway: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "待機中"
    @Published private(set) var taskState = "idle"
    @Published private(set) var lastEvent: Date?
    @Published private(set) var pingCount = ["mention": 0, "slash": 0]
    @Published private(set) var pongCount = ["mention": 0, "slash": 0]
    @Published private(set) var disconnects = 0
    @Published private(set) var reconnects = 0
    @Published private(set) var observed = 0
    @Published private(set) var expected = 0
    @Published private(set) var files = RunCSV.files("GatewayRuns")
    @Published private(set) var logError: String?
    @Published private(set) var rows = 0

    private let dates = ISO8601DateFormatter()
    private weak var gateway: Gateway?
    private var file: URL?
    private var startTime: ContinuousClock.Instant?
    private var stopTime: ContinuousClock.Instant?
    private var requestID: String?
    private var task: BGTask?
    private var monitor: Task<Void, Never>?
    private var deliveryTimeout: Task<Void, Never>?
    private var target: PingTarget?
    private var unanswered: [String: String] = [:]
    private var ending = false

    init() { dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }

    var availabilityError: String? {
        guard #available(iOS 26.0, *) else { return "iOS 26以降が必要です。" }
        guard let bundle = Bundle.main.bundleIdentifier,
              let allowed = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
              allowed.contains(bundle + ".gateway-watch.*") else {
            return "再署名後のアプリIDと許可タスクIDが一致しません。"
        }
        return nil
    }

    func start(gateway: Gateway, target: PingTarget, minutes: Int) {
        guard !running, gateway.authenticated, !gateway.registering,
              [3, 10, 30, 60].contains(minutes), Gateway.validID(target.guild), Gateway.validID(target.channel),
              UIApplication.shared.applicationState == .active else { return }
        guard #available(iOS 26.0, *), availabilityError == nil, let bundle = Bundle.main.bundleIdentifier else {
            status = availabilityError ?? "実行できません"
            return
        }
        do {
            file = try RunCSV.create(in: "GatewayRuns", timestamp: dates.string(from: Date()),
                header: "utc,elapsed_seconds,sequence,event,app_state,bg_task,gateway,socket,heartbeat_id,interval_ms,ack_ms,socket_sent,socket_ack,connection_total_sent,connection_total_ack,pending,close_code,method,request,http_status,observations,expected,error")
        } catch {
            status = "CSV作成失敗"
            logError = Self.safeError(error)
            return
        }
        files = RunCSV.files("GatewayRuns")
        self.gateway = gateway
        self.target = target
        rows = 0
        logError = nil
        stopTime = nil
        startTime = .now
        lastEvent = nil
        pingCount = ["mention": 0, "slash": 0]
        pongCount = pingCount
        unanswered.removeAll()
        disconnects = 0
        reconnects = 0
        observed = 0
        expected = minutes * 12
        running = true
        taskState = "registering"
        status = "OSの開始通知を待機"
        gateway.observe = { [weak self] observation in self?.record(observation) }
        record(GatewayObservation(event: "test_requested"))
        guard logError == nil else { return }

        let id = bundle + ".gateway-watch." + UUID().uuidString
        guard BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main, launchHandler: { [weak self] task in
            Task { @MainActor in
                guard let self, let job = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.accept(job)
            }
        }) else {
            finish(event: "register_failed", message: "継続処理の登録に失敗")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Discord Gateway試験", subtitle: "OSの開始通知を待機")
        request.strategy = .fail
        requestID = id
        do {
            try BGTaskScheduler.shared.submit(request)
            taskState = "submitted"
            record(GatewayObservation(event: "task_submitted"))
            deliveryTimeout = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, running, task == nil else { return }
                finish(event: "delivery_timeout", message: "OSから開始通知が届きませんでした")
            }
        } catch {
            record(GatewayObservation(event: "submit_error", error: Self.safeError(error)))
            finish(event: "submit_failed", message: "OSが継続処理の要求を拒否")
        }
    }

    @available(iOS 26.0, *)
    private func accept(_ task: BGContinuedProcessingTask) {
        guard running, !ending, logError == nil, requestID == task.identifier,
              self.task == nil, let gateway, let target else {
            task.setTaskCompleted(success: false)
            return
        }
        deliveryTimeout?.cancel()
        deliveryTimeout = nil
        self.task = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                self.finish(event: "os_expired_or_cancelled", message: "OSから終了通知（失効または取消）")
            }
        }
        let now = ContinuousClock.now
        let end = now.advanced(by: .seconds(expected * 5))
        taskState = "running"
        status = "試験中"
        task.progress.totalUnitCount = Int64(expected)
        task.progress.completedUnitCount = 0
        gateway.beginPingResponses(target, until: end)
        record(GatewayObservation(event: "watch_started"))
        guard logError == nil else { return }
        monitor = Task {
            var slot = 1
            while !Task.isCancelled {
                let scheduled = now.advanced(by: .seconds(slot * 5))
                do { try await Task.sleep(until: scheduled, clock: .continuous) } catch { return }
                guard !Task.isCancelled, self.task === task else { return }
                let actual = ContinuousClock.now
                let skipped = max(0, Self.seconds(scheduled.duration(to: actual)))
                if skipped < 5 {
                    observed += 1
                    task.progress.completedUnitCount = Int64(observed)
                    task.updateTitle("Discord Gateway試験", subtitle: "観測 \(observed) / \(expected) · ACK \(gateway.socketACK)")
                    record(GatewayObservation(event: "gateway_sample"))
                }
                if actual >= end {
                    let full = observed == expected
                    finish(event: full ? "window_completed" : "window_incomplete",
                           message: full ? "観測期間終了" : "期間終了・観測に空白あり", success: full)
                    return
                }
                slot += max(1, Int(skipped / 5) + 1)
            }
        }
    }

    func lifecycle(_ event: String) {
        if running { record(GatewayObservation(event: event)) }
    }

    func stop() {
        if running { finish(event: "user_stopped", message: "手動停止") }
    }

    func elapsed() -> Double {
        startTime.map { Self.seconds($0.duration(to: stopTime ?? .now)) } ?? 0
    }

    private func finish(event: String, message: String, success: Bool = false) {
        guard running, !ending else { return }
        ending = true
        stopTime = .now
        status = message
        taskState = event
        monitor?.cancel()
        monitor = nil
        deliveryTimeout?.cancel()
        deliveryTimeout = nil
        for (id, method) in unanswered.sorted(by: { $0.key < $1.key }) {
            record(GatewayObservation(event: "pong_outcome_unknown", mode: method, request: id, error: event))
        }
        unanswered.removeAll()
        gateway?.endPingResponses()
        gateway?.stopAll()
        record(GatewayObservation(event: event))
        gateway?.observe = nil
        if let task {
            task.expirationHandler = nil
            task.setTaskCompleted(success: success && logError == nil)
        } else if let requestID {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID)
        }
        task = nil
        requestID = nil
        target = nil
        running = false
        ending = false
    }

    private func record(_ item: GatewayObservation) {
        guard let file, let gateway else { return }
        switch item.event {
        case "ping_received":
            pingCount[item.mode, default: 0] += 1
            unanswered[item.request] = item.mode
        case "pong_succeeded":
            pongCount[item.mode, default: 0] += 1
            unanswered[item.request] = nil
        case "pong_failed": unanswered[item.request] = nil
        case "websocket_disconnected": if !ending { disconnects += 1 }
        case "websocket_reconnecting": reconnects += 1
        default: break
        }
        lastEvent = item.time
        let app: String
        switch UIApplication.shared.applicationState {
        case .active: app = "foreground"
        case .inactive: app = "inactive"
        case .background: app = "background"
        @unknown default: app = "unknown"
        }
        let eventElapsed = startTime.map { Self.seconds($0.duration(to: item.instant)) } ?? 0
        var values = [dates.string(from: item.time), Self.decimal(eventElapsed), String(rows + 1), item.event,
                      app, taskState, gateway.transport, String(gateway.socketNumber)]
        values += [item.heartbeat.map { String($0) } ?? "", gateway.intervalMS.map { String($0) } ?? "",
                   item.ackMS.map(Self.decimal) ?? "", String(gateway.socketSent), String(gateway.socketACK),
                   String(gateway.sent), String(gateway.acknowledged), String(gateway.pendingCount)]
        values += [item.closeCode.map { String($0) } ?? "", item.mode, item.request,
                   item.http.map { String($0) } ?? "", String(observed), String(expected), item.error]
        do {
            try RunCSV.append(values, to: file)
            rows += 1
        } catch {
            guard logError == nil else { return }
            logError = Self.safeError(error)
            if !ending {
                Task { finish(event: "csv_write_failed", message: "CSV書き込み失敗") }
            }
        }
    }

    private static func safeError(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain) (\(value.code))"
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
