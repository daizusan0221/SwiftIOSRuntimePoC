import BackgroundTasks
import CryptoKit
import Foundation
import SwiftUI
import UIKit

enum ExperimentMode: String, CaseIterable, Identifiable {
    case normal = "A"
    case assertion = "B"
    case continued = "C"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: return "A · 通常実行"
        case .assertion: return "B · beginBackgroundTask"
        case .continued: return "C · BGContinuedProcessingTask"
        }
    }
}

@MainActor
final class OfflineExperiment: ObservableObject {
    static let shared = OfflineExperiment()
    static let interval = 10.0
    private static let gapTolerance = 2.0
    private static let schedulerSuffix = ".offline-work"

    @Published private(set) var status = "待機中"
    @Published private(set) var taskState = "none"
    @Published private(set) var running = false
    @Published private(set) var mode: ExperimentMode = .normal
    @Published private(set) var rows = 0
    @Published private(set) var completed = 0
    @Published private(set) var target = 0
    @Published private(set) var lastExecution: Date?
    @Published private(set) var longest = 0.0
    @Published private(set) var estimatedGap = 0.0
    @Published private(set) var largestGap = 0.0
    @Published private(set) var files: [URL] = []
    @Published private(set) var continuedAvailable = false
    @Published private(set) var continuedStatus = "iOS 26以降が必要"
    @Published private(set) var logError: String?

    private let launch = ContinuousClock.now
    private let dates = ISO8601DateFormatter()
    private var started: ContinuousClock.Instant?
    private var stopped: ContinuousClock.Instant?
    private var latestTick: ContinuousClock.Instant?
    private var streakStart: ContinuousClock.Instant?
    private var phase: ScenePhase?
    private var currentFile: URL?
    private var timer: Task<Void, Never>?
    private var assertion = UIBackgroundTaskIdentifier.invalid
    private var submitted = false
    private var continuedTask: BGTask?
    private var digest = Data(repeating: 0, count: 32)
    private var requestID: String?

    private init() {
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshFiles()
    }

    private var schedulerPrefix: String? {
        Bundle.main.bundleIdentifier.map { $0 + Self.schedulerSuffix }
    }

    func checkContinuedAvailability() {
        guard #available(iOS 26.0, *) else { return }
        let allowed = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let prefix = schedulerPrefix, allowed.contains(prefix + ".*") else {
            continuedStatus = "利用不可：署名後のアプリIDとInfo.plistのタスクIDが一致しません"
            return
        }
        continuedAvailable = true
        continuedStatus = "要求可能：進捗はシステムのLive Activityに通知"
    }

    func start(mode: ExperimentMode, minutes: Int, stopNetwork: () -> Void) {
        guard !running else { return }
        guard UIApplication.shared.applicationState == .active else {
            status = "アプリを表示してから開始してください"
            return
        }
        guard mode != .continued || continuedAvailable else {
            status = continuedStatus
            return
        }
        do {
            currentFile = try makeLog()
        } catch {
            status = "ログファイルの作成に失敗"
            logError = errorCode(error)
            return
        }
        stopNetwork()
        self.mode = mode
        target = minutes * 6
        completed = 0
        rows = 0
        digest = Data(repeating: 0, count: 32)
        logError = nil
        lastExecution = nil
        latestTick = nil
        streakStart = nil
        longest = 0
        estimatedGap = 0
        largestGap = 0
        stopped = nil
        started = .now
        running = true
        status = mode == .continued ? "OSの開始通知を待機" : "計測中"
        taskState = mode == .continued ? "request_submitting" : "none"
        guard append("run_started") else { return }

        if mode == .continued {
            if #available(iOS 26.0, *), let prefix = schedulerPrefix {
                let id = prefix + "." + UUID().uuidString
                let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
                    Task { @MainActor in
                        guard let continued = task as? BGContinuedProcessingTask else {
                            task.setTaskCompleted(success: false)
                            return
                        }
                        Self.shared.accept(continued)
                    }
                }
                guard registered else {
                    finish(event: "continued_register_failed", message: "継続処理を登録できませんでした",
                           error: "BGTaskScheduler.register returned false")
                    return
                }
                requestID = id
                let request = BGContinuedProcessingTaskRequest(
                    identifier: id, title: "オフライン計測", subtitle: "0 / \(target) バッチ"
                )
                request.strategy = .fail
                do {
                    try BGTaskScheduler.shared.submit(request)
                    submitted = true
                    taskState = "request_submitted"
                    _ = append("continued_submitted")
                } catch {
                    finish(event: "continued_submit_failed", message: "OSが継続処理の要求を拒否", error: errorCode(error))
                }
            }
        } else {
            if mode == .assertion { beginAssertion() }
            if running { startTimer() }
        }
    }

    func stop() {
        guard running else { return }
        finish(event: "user_stopped", message: "手動停止")
    }

    func elapsed() -> Double {
        guard let started else { return 0 }
        return seconds(started.duration(to: stopped ?? .now))
    }

    func sceneChanged(_ next: ScenePhase) {
        guard phase != next else { return }
        phase = next
        guard running else { return }
        guard append("scene_\(appState(next))") else { return }
        if mode == .assertion, next == .active, assertion == .invalid { beginAssertion() }
    }

    func lifecycle(_ event: String) {
        if running { _ = append(event) }
    }

    @available(iOS 26.0, *)
    private func accept(_ task: BGContinuedProcessingTask) {
        guard running, mode == .continued, submitted, task.identifier == requestID, continuedTask == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        submitted = false
        continuedTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.continuedTask === task else { return }
                self.finish(event: "continued_expired_or_cancelled",
                            message: "OSから終了通知（期限・資源・システムUIからの取消）")
            }
        }
        task.progress.totalUnitCount = Int64(target)
        task.progress.completedUnitCount = 0
        taskState = "continued_running"
        status = "計測中"
        guard append("continued_delivered") else { return }
        startTimer()
    }

    private func startTimer() {
        latestTick = .now
        streakStart = latestTick
        timer = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(Self.interval)) }
                catch { break }
                guard !Task.isCancelled, running else { break }
                tick()
            }
        }
    }

    private func tick() {
        let now = ContinuousClock.now
        let timestamp = Date()
        let delta = latestTick.map { seconds($0.duration(to: now)) } ?? Self.interval
        let gap = delta > Self.interval + Self.gapTolerance ? delta - Self.interval : 0
        if gap > 0 {
            estimatedGap += gap
            largestGap = max(largestGap, gap)
            streakStart = now
        }
        if let streakStart { longest = max(longest, seconds(streakStart.duration(to: now))) }
        latestTick = now
        lastExecution = timestamp
        completed += 1

        // A finite, local checksum of deterministic batches. Each actual tick
        // extends the digest; missed ticks do not consume batches.
        let block = Data(repeating: UInt8(truncatingIfNeeded: completed), count: 4096)
        var hash = SHA256()
        hash.update(data: digest)
        for _ in 0..<128 { hash.update(data: block) }
        digest = Data(hash.finalize())
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(completed)
            task.updateTitle("オフライン計測", subtitle: "\(completed) / \(target) バッチ")
        }
        guard append("tick", now: now, date: timestamp, gap: gap) else { return }
        if completed == target { finish(event: "work_completed", message: "全バッチ完了", success: true) }
    }

    private func beginAssertion() {
        guard assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "Offline measurement") { [weak self] in
            MainActor.assumeIsolated {
                self?.endAssertion(event: "assertion_expired")
            }
        }
        taskState = assertion == .invalid ? "assertion_unavailable" : "assertion_active"
        _ = append(taskState)
    }

    private func endAssertion(event: String) {
        guard assertion != .invalid else { return }
        let id = assertion
        assertion = .invalid
        UIApplication.shared.endBackgroundTask(id)
        taskState = event
        _ = append(event)
    }

    private func finish(event: String, message: String, success: Bool = false, error: String = "") {
        stopped = .now
        status = message
        taskState = event
        _ = append(event, error: error, stopOnFailure: false)
        releaseTasks(success: success && logError == nil)
    }

    private func releaseTasks(success: Bool) {
        running = false
        timer?.cancel()
        timer = nil
        if assertion != .invalid {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
        if submitted, let id = requestID {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
            submitted = false
        }
        requestID = nil
        if let task = continuedTask {
            continuedTask = nil
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        }
    }

    private func appState(_ scene: ScenePhase) -> String {
        switch scene {
        case .active: return "foreground"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private var currentAppState: String {
        switch UIApplication.shared.applicationState {
        case .active: return "foreground"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private var powerState: String {
        switch UIDevice.current.batteryState {
        case .charging: return "charging"
        case .full: return "full"
        case .unplugged: return "unplugged"
        default: return "unknown"
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func precise(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func logDirectory() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("OfflineRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func refreshFiles() {
        if let directory = try? logDirectory(),
           let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            files = entries.filter { $0.pathExtension == "csv" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
    }

    private func makeLog() throws -> URL {
        let filename = dates.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            + "-" + UUID().uuidString.prefix(8) + ".csv"
        let file = try logDirectory().appendingPathComponent(filename)
        let header = "timestamp_utc,app_elapsed_seconds,run_elapsed_seconds,sequence,mode,event,app_state,task_state,power,batches_done,batches_total,estimated_gap_seconds,longest_observed_streak_seconds,sha256,error\r\n"
        try Data(header.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        refreshFiles()
        return file
    }

    @discardableResult
    private func append(_ event: String, now: ContinuousClock.Instant = .now, date: Date = Date(),
                        gap: Double = 0, error: String = "", stopOnFailure: Bool = true) -> Bool {
        guard let currentFile, let started else { return false }
        let checksum = event == "tick" ? digest.map { String(format: "%02x", $0) }.joined() : ""
        let values = [dates.string(from: date), precise(seconds(launch.duration(to: now))),
                      precise(seconds(started.duration(to: now))), String(rows + 1), mode.rawValue, event,
                      currentAppState, taskState, powerState, String(completed), String(target),
                      precise(gap), precise(longest), checksum, error]
        let line = values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        do {
            let file = try FileHandle(forWritingTo: currentFile)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data((line + "\r\n").utf8))
            try file.synchronize()
            rows += 1
            return true
        } catch {
            logError = errorCode(error)
            status = "ログの書き込みに失敗"
            if stopOnFailure {
                stopped = .now
                releaseTasks(success: false)
            }
            return false
        }
    }

    private func errorCode(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) (\(ns.code))"
    }
}
