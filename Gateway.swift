import Foundation
import SwiftUI

struct GatewayObservation {
    let event: String
    var time = Date()
    var instant = ContinuousClock.now
    var mode = ""
    var request = ""
    var http: Int? = nil
    var error = ""
    var heartbeat: Int? = nil
    var ackMS: Double? = nil
    var closeCode: Int? = nil
}

struct PingTarget: Equatable {
    let guild: String
    let channel: String
}

@MainActor
final class Gateway: NSObject, ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "未接続"
    @Published private(set) var transport = "未接続"
    @Published private(set) var ready = "未受信"
    @Published private(set) var sendResult = "未送信"
    @Published private(set) var sending = false
    @Published private(set) var sent = 0
    @Published private(set) var acknowledged = 0
    @Published private(set) var latency = "—"
    @Published private(set) var logs: [String] = []
    @Published private(set) var authenticated = false
    @Published private(set) var socketNumber = 0
    @Published private(set) var socketSent = 0
    @Published private(set) var socketACK = 0
    @Published private(set) var pendingCount = 0
    @Published private(set) var intervalMS: Int?
    @Published private(set) var registerResult = "未登録"
    @Published private(set) var registering = false
    var observe: ((GatewayObservation) -> Void)?

    private struct SessionState {
        let id: String
        let url: URL
    }

    private struct Retry: Error {
        var reason: String
        var delay: Double
        var resetSession = false
    }

    private enum APIError: Error {
        case status(Int)
        case invalidResponse
        case identifyLimit(Int)
    }

    private let http = URLSession(configuration: .ephemeral)
    private lazy var sockets = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private var connection: Task<Void, Never>?
    private var message: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var resumable: SessionState?
    private var sequence: Int?
    private var lastIdentify: ContinuousClock.Instant?
    private var identifiesRemaining = 0
    private var identifyReset: ContinuousClock.Instant?
    private struct Heartbeat {
        let id: Int
        let started: ContinuousClock.Instant
    }
    private var pendingHeartbeats: [Heartbeat] = []
    private var heartbeatID = 0
    private var socketFailure: String?
    private var stable = false
    private var attemptedResume = false
    private var botToken: String?
    private var botID: String?
    private var applicationID: String?
    private var pingTarget: PingTarget?
    private var pingDeadline: ContinuousClock.Instant?
    private var registration: Task<Void, Never>?
    private var responses: [String: Task<Void, Never>] = [:]
    private var handled: Set<String> = []
    private var recent: [String] = []
    private var responseNumber = 0
    private var rateLimitedUntil: [String: ContinuousClock.Instant] = [:]

    func connect(token: String) {
        guard !running, Self.validTokenInput(token) else { return }
        running = true
        transport = "未接続"
        ready = "未受信"
        sent = 0
        acknowledged = 0
        latency = "—"
        socketNumber = 0
        socketSent = 0
        socketACK = 0
        heartbeatID = 0
        rateLimitedUntil.removeAll()
        botToken = token
        registerResult = "未確認"
        status = "Bot認証を確認中"
        connection = Task {
            defer {
                if !Task.isCancelled {
                    running = false
                    connection = nil
                    resetSession()
                    botToken = nil
                }
            }
            do {
                let data = try await request("gateway/bot", token: token)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let url = Self.gatewayURL(object["url"] as? String),
                      let limit = object["session_start_limit"] as? [String: Any],
                      let remaining = limit["remaining"] as? Int, remaining >= 0,
                      let reset = limit["reset_after"] as? Double, (0...172_800_000).contains(reset)
                else { throw APIError.invalidResponse }
                identifiesRemaining = remaining
                identifyReset = ContinuousClock.now.advanced(by: .milliseconds(reset))
                try await run(token: token, initialURL: url)
            } catch {
                guard !Task.isCancelled else { return }
                transport = "切断"
                status = "接続終了"
                log("接続終了: \(Self.describe(error))")
                observe?(GatewayObservation(event: "gateway_stopped", error: Self.describe(error)))
            }
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        if socket != nil { closeSocket(reason: "manual_or_test_stop") }
        resetSession()
        botToken = nil
        registration?.cancel()
        registration = nil
        registering = false
        endPingResponses()
        running = false
        transport = "切断"
        status = "切断"
        ready = "未受信"
    }

    func stopAll() {
        disconnect()
        message?.cancel()
        message = nil
        if sending { sendResult = "キャンセル" }
        sending = false
    }

    func sendTest(token: String, channel: String) {
        guard !sending, Self.validTokenInput(token), Self.validID(channel) else {
            sendResult = "Bot Tokenと数値のチャンネルIDを確認"
            return
        }
        sending = true
        sendResult = "Bot認証を確認中"
        message = Task {
            defer { if !Task.isCancelled { sending = false; message = nil } }
            do {
                let account = try await request("users/@me", token: token)
                guard let user = try JSONSerialization.jsonObject(with: account) as? [String: Any],
                      user["bot"] as? Bool == true else { throw APIError.invalidResponse }
                try Task.checkCancellation()
                sendResult = "送信中"
                let body: [String: Any] = ["content": "Hello from Swift iOS PoC!", "allowed_mentions": ["parse": [String]()]]
                _ = try await request("channels/\(channel)/messages", token: token, body: body)
                try Task.checkCancellation()
                sendResult = "送信成功（REST 2xx）"
                log("送信テスト成功")
            } catch {
                guard !Task.isCancelled else { return }
                sendResult = "送信失敗: \(Self.describe(error))"
                log(sendResult)
            }
        }
    }

    private func run(token: String, initialURL: URL) async throws {
        var retries = 0
        var failedResumes = 0
        while !Task.isCancelled {
            let ws = sockets.webSocketTask(with: resumable?.url ?? initialURL)
            socket = ws
            socketNumber += 1
            socketSent = 0
            socketACK = 0
            intervalMS = nil
            latency = "—"
            authenticated = false
            stable = false
            attemptedResume = false
            socketFailure = nil
            transport = "接続中"
            ready = "待機中"
            status = "WebSocket接続中"
            observe?(GatewayObservation(event: socketNumber == 1 ? "websocket_connecting" : "websocket_reconnecting"))
            ws.resume()
            startWatchdog(ws)
            var retry: Retry
            var failureCode: Int?
            var terminal: Error?
            do {
                try await receive(from: ws, token: token)
                retry = Retry(reason: "接続終了", delay: 1)
            } catch {
                try Task.checkCancellation()
                let code = ws.closeCode.rawValue
                failureCode = code == 0 ? nil : code
                if case APIError.identifyLimit = error {
                    terminal = error
                }
                if [4004, 4010, 4011, 4012, 4013, 4014].contains(code) {
                    terminal = Retry(reason: "再接続不可（Gateway \(code)）", delay: 0)
                }
                let backoff = min(60, pow(2, Double(stable ? 0 : retries)))
                retry = (error as? Retry) ?? Retry(
                    reason: socketFailure ?? (code == 0 ? Self.describe(error) : "Gateway切断 \(code)"),
                    delay: backoff * Double.random(in: 0.75...1.25),
                    resetSession: [4007, 4009].contains(code)
                )
                if code == 4008 { retry.delay = max(5, retry.delay) }
                if !(error is Retry) {
                    observe?(GatewayObservation(event: "websocket_error", error: socketFailure ?? Self.describe(error),
                                                closeCode: failureCode))
                }
            }
            let wasStable = stable
            if wasStable { failedResumes = 0 }
            if attemptedResume, !wasStable, terminal == nil {
                failedResumes += 1
                if failedResumes >= 2 { retry.resetSession = true }
            }
            if let failureCode, [4007, 4009].contains(failureCode) { retry.resetSession = true }
            if retry.resetSession, attemptedResume {
                observe?(GatewayObservation(event: "resume_fallback_identify"))
            }
            if retry.resetSession { resetSession() }
            closeSocket(reason: retry.reason, code: failureCode)
            if let terminal { throw terminal }
            retries = (wasStable ? 0 : retries) + 1
            transport = "切断"
            ready = "待機中"
            log(retry.reason)
            guard retries <= 8 else { throw Retry(reason: "再試行上限に到達", delay: 0) }
            status = "再接続待機（\(retries)/8）"
            observe?(GatewayObservation(event: "reconnect_wait", mode: resumable != nil ? "resume" : "identify"))
            try await Task.sleep(for: .seconds(retry.delay))
        }
    }

    private func receive(from ws: URLSessionWebSocketTask, token: String) async throws {
        var receivedHello = false
        while !Task.isCancelled {
            let frame = try await ws.receive()
            let received = Date()
            let receivedAt = ContinuousClock.now
            try Task.checkCancellation()
            let data: Data
            switch frame {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            guard let packet = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let opcode = packet["op"] as? Int else { continue }
            switch opcode {
            case 10:
                guard !receivedHello, let hello = packet["d"] as? [String: Any],
                      let ms = hello["heartbeat_interval"] as? Double, ms > 0, ms <= 300_000 else {
                    throw Retry(reason: "HelloのHeartbeat間隔が不正", delay: 5)
                }
                receivedHello = true
                intervalMS = Int(ms)
                transport = "接続済み / Hello受信"
                log("Hello受信 / Heartbeat間隔 \(Int(ms)) ms")
                observe?(GatewayObservation(event: "hello", time: received))
                startHeartbeat(ws, interval: ms / 1000)
                if let resumable, let sequence {
                    attemptedResume = true
                    try await transmit(ws, op: 6, data: ["token": token, "session_id": resumable.id, "seq": sequence])
                    log("Resume送信")
                    observe?(GatewayObservation(event: "resume_sent"))
                } else {
                    guard identifiesRemaining > 0 else {
                        let wait = identifyReset.map { ContinuousClock.now.duration(to: $0).components.seconds } ?? 0
                        throw APIError.identifyLimit(Int(max(0, wait)))
                    }
                    if let lastIdentify {
                        let remaining = lastIdentify.advanced(by: .seconds(5.5)) - ContinuousClock.now
                        if remaining > .zero { try await Task.sleep(for: remaining) }
                    }
                    try Task.checkCancellation()
                    lastIdentify = .now
                    identifiesRemaining -= 1
                    try await transmit(ws, op: 2, data: [
                        "token": token, "intents": 1 << 9,
                        "properties": ["os": "iOS", "browser": "SwiftIOSRuntimePoC", "device": "SwiftIOSRuntimePoC"]
                    ])
                    log("Identify送信")
                    observe?(GatewayObservation(event: "identify_sent"))
                }
            case 0:
                if let next = packet["s"] as? Int { sequence = next }
                if packet["t"] as? String == "READY" {
                    guard let event = packet["d"] as? [String: Any], let id = event["session_id"] as? String,
                          let url = Self.gatewayURL(event["resume_gateway_url"] as? String),
                          let user = event["user"] as? [String: Any], let bot = user["id"] as? String,
                          let application = event["application"] as? [String: Any], let app = application["id"] as? String,
                          Self.validID(bot), Self.validID(app) else {
                        throw Retry(reason: "READYの再開情報が不正", delay: 5, resetSession: true)
                    }
                    resumable = SessionState(id: id, url: url)
                    botID = bot
                    applicationID = app
                    markReady("READY受信")
                    observe?(GatewayObservation(event: "ready", time: received))
                } else if packet["t"] as? String == "RESUMED" {
                    markReady("RESUMED受信")
                    observe?(GatewayObservation(event: "resumed", time: received))
                } else if let type = packet["t"] as? String, let event = packet["d"] as? [String: Any] {
                    handlePing(type: type, event: event, received: received)
                }
            case 1:
                try await sendHeartbeat(ws)
            case 7:
                throw Retry(reason: "サーバーから再接続要求（OP 7）", delay: Double.random(in: 0.1...0.5))
            case 9:
                throw Retry(reason: "セッション無効（OP 9）", delay: Double.random(in: 1...5),
                            resetSession: packet["d"] as? Bool != true)
            case 11:
                acknowledged += 1
                socketACK += 1
                if !pendingHeartbeats.isEmpty {
                    let heartbeat = pendingHeartbeats.removeFirst()
                    pendingCount = pendingHeartbeats.count
                    let elapsed = heartbeat.started.duration(to: receivedAt)
                    let milliseconds = Double(elapsed.components.seconds) * 1_000
                        + Double(elapsed.components.attoseconds) / 1e15
                    latency = String(format: "%.0f ms", milliseconds)
                    observe?(GatewayObservation(event: "heartbeat_ack", time: received, instant: receivedAt, heartbeat: heartbeat.id,
                                                ackMS: milliseconds))
                } else {
                    observe?(GatewayObservation(event: "heartbeat_ack_unmatched", time: received))
                }
            default:
                break
            }
        }
    }

    private func startWatchdog(_ ws: URLSessionWebSocketTask) {
        watchdog = Task {
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled, socket === ws, !stable else { return }
            socketFailure = "Hello / READY / RESUMED 待機タイムアウト"
            ws.cancel(with: .goingAway, reason: nil)
        }
    }

    private func startHeartbeat(_ ws: URLSessionWebSocketTask, interval: Double) {
        heartbeat = Task {
            do {
                try await Task.sleep(for: .seconds(interval * Double.random(in: 0..<1)))
                while !Task.isCancelled, socket === ws {
                    if let pendingHeartbeat = pendingHeartbeats.first,
                       pendingHeartbeat.started.duration(to: .now) >= .seconds(interval * 0.99) {
                        socketFailure = "Heartbeat ACKが届かず再接続"
                        observe?(GatewayObservation(event: "heartbeat_ack_timeout", heartbeat: pendingHeartbeat.id))
                        ws.cancel(with: .goingAway, reason: nil)
                        return
                    }
                    try await sendHeartbeat(ws)
                    try await Task.sleep(for: .seconds(interval))
                }
            } catch {
                guard !Task.isCancelled, socket === ws else { return }
                socketFailure = "Heartbeat送信失敗: \(Self.describe(error))"
                ws.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func sendHeartbeat(_ ws: URLSessionWebSocketTask) async throws {
        guard pendingHeartbeats.count < 16 else {
            throw Retry(reason: "未ACKのHeartbeatが多すぎます", delay: 5)
        }
        heartbeatID += 1
        let heartbeat = Heartbeat(id: heartbeatID, started: .now)
        pendingHeartbeats.append(heartbeat)
        pendingCount = pendingHeartbeats.count
        let attemptedAt = Date()
        observe?(GatewayObservation(event: "heartbeat_send_started", time: attemptedAt, heartbeat: heartbeat.id))
        let payload: Any = sequence.map { $0 as Any } ?? NSNull()
        do {
            try await transmit(ws, op: 1, data: payload)
        } catch {
            if socket === ws {
                pendingHeartbeats.removeAll { $0.id == heartbeat.id }
                pendingCount = pendingHeartbeats.count
                observe?(GatewayObservation(event: "heartbeat_send_failed", error: Self.describe(error), heartbeat: heartbeat.id))
            }
            throw error
        }
        guard socket === ws, !Task.isCancelled else { return }
        sent += 1
        socketSent += 1
        observe?(GatewayObservation(event: "heartbeat_sent", heartbeat: heartbeat.id))
    }

    private func transmit(_ ws: URLSessionWebSocketTask, op: Int, data: Any) async throws {
        let json = try JSONSerialization.data(withJSONObject: ["op": op, "d": data])
        try await ws.send(.string(String(decoding: json, as: UTF8.self)))
    }

    private func markReady(_ event: String) {
        stable = true
        authenticated = true
        ready = event
        status = "稼働中"
        watchdog?.cancel()
        log(event)
    }

    private func closeSocket(reason: String, code: Int? = nil) {
        heartbeat?.cancel()
        heartbeat = nil
        watchdog?.cancel()
        watchdog = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        authenticated = false
        transport = "切断"
        for heartbeat in pendingHeartbeats {
            observe?(GatewayObservation(event: "heartbeat_unacked_at_close", heartbeat: heartbeat.id, closeCode: code))
        }
        pendingHeartbeats.removeAll()
        pendingCount = 0
        observe?(GatewayObservation(event: "websocket_disconnected", error: reason, closeCode: code))
    }

    private func resetSession() {
        resumable = nil
        sequence = nil
        botID = nil
        applicationID = nil
    }

    private func request(_ path: String, token: String, body: [String: Any]? = nil) async throws -> Data {
        let (data, response) = try await requestWithStatus(path, token: token, body: body)
        guard (200..<300).contains(response.statusCode) else { throw APIError.status(response.statusCode) }
        return data
    }

    private func requestWithStatus(_ path: String, token: String?, body: [String: Any]? = nil,
                                   timeout: TimeInterval = 20) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = URL(string: "https://discord.com/api/v10/\(path)") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token { request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("DiscordBot (https://github.com/, 1.0)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await http.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, response)
    }

    static func validID(_ value: String) -> Bool {
        (17...20).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) } && UInt64(value) != nil
    }

    static func validTokenInput(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 256 && token.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func gatewayURL(_ raw: String?) -> URL? {
        guard let raw, var parts = URLComponents(string: raw), parts.scheme == "wss",
              let host = parts.host?.lowercased(), host.hasSuffix(".discord.gg"),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        parts.queryItems = [URLQueryItem(name: "v", value: "10"), URLQueryItem(name: "encoding", value: "json")]
        parts.fragment = nil
        return parts.url
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let retry as Retry: return retry.reason
        case APIError.status(401): return "HTTP 401（Bot Tokenを確認）"
        case APIError.status(403): return "HTTP 403（Botのチャンネル権限を確認）"
        case APIError.status(404): return "HTTP 404（チャンネルIDを確認）"
        case APIError.status(429): return "HTTP 429（時間をおいて再試行）"
        case APIError.status(let code): return "Discord HTTP \(code)"
        case APIError.invalidResponse: return "Discordの応答形式またはBot認証を確認"
        case APIError.identifyLimit(let seconds): return "Identifyの残枠がありません。\(seconds)秒後に再確認してください。"
        case let url as URLError: return "ネットワークエラー \(url.errorCode)"
        default: return "通信処理エラー"
        }
    }

    private func log(_ text: String) {
        logs.insert("\(Date().formatted(date: .omitted, time: .standard))  \(text)", at: 0)
        if logs.count > 40 { logs.removeLast() }
    }
}

extension Gateway {
    func registerPing(_ target: PingTarget) {
        guard authenticated, !registering, pingTarget == nil, let botToken, let applicationID,
              Self.validID(target.guild), Self.validID(target.channel) else { return }
        registering = true
        registerResult = "登録先を確認中"
        registration = Task {
            defer { if !Task.isCancelled { registering = false; registration = nil } }
            do {
                let channel = try await request("channels/\(target.channel)", token: botToken)
                guard let item = try JSONSerialization.jsonObject(with: channel) as? [String: Any],
                      item["guild_id"] as? String == target.guild else {
                    registerResult = "チャンネルが指定サーバーに属していません"
                    return
                }
                let route = "applications/\(applicationID)/guilds/\(target.guild)/commands"
                let list = try await request(route, token: botToken)
                guard let commands = try JSONSerialization.jsonObject(with: list) as? [[String: Any]]
                else { throw APIError.invalidResponse }
                let description = "Swift iOS Background Gateway test"
                if let existing = commands.first(where: { $0["name"] as? String == "ping" && $0["type"] as? Int == 1 }) {
                    let noOptions = (existing["options"] as? [[String: Any]])?.isEmpty ?? true
                    registerResult = existing["description"] as? String == description && noOptions
                        ? "このサーバーに登録済み" : "同名の既存 /ping があるため登録を中止"
                    return
                }
                _ = try await request(route, token: botToken, body: ["name": "ping", "type": 1, "description": description])
                registerResult = "テストサーバーに /ping を登録"
            } catch {
                guard !Task.isCancelled else { return }
                registerResult = "登録失敗: \(Self.describe(error))"
            }
        }
    }

    func beginPingResponses(_ target: PingTarget, until deadline: ContinuousClock.Instant) {
        pingTarget = target
        pingDeadline = deadline
        handled.removeAll()
        recent.removeAll()
        responseNumber = 0
    }

    func endPingResponses() {
        pingTarget = nil
        pingDeadline = nil
        for task in responses.values { task.cancel() }
        responses.removeAll()
    }

    private func handlePing(type: String, event: [String: Any], received: Date) {
        guard let target = pingTarget, let pingDeadline, ContinuousClock.now < pingDeadline,
              let botToken, let botID, let applicationID,
              event["guild_id"] as? String == target.guild,
              let id = event["id"] as? String, Self.validID(id) else { return }
        let channel = event["channel_id"] as? String ?? (event["channel"] as? [String: Any])?["id"] as? String
        guard channel == target.channel else { return }

        let mode: String
        let route: String
        let auth: String?
        let body: [String: Any]
        let allowed: [String: Any] = ["parse": [String](), "replied_user": false]
        if type == "MESSAGE_CREATE" {
            guard let author = event["author"] as? [String: Any], let authorID = author["id"] as? String,
                  authorID != botID, author["bot"] as? Bool != true,
                  let mentions = event["mentions"] as? [[String: Any]],
                  mentions.contains(where: { $0["id"] as? String == botID }),
                  let text = event["content"] as? String,
                  ["<@\(botID)> ping", "<@!\(botID)> ping"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            else { return }
            mode = "mention"
            route = "channels/\(target.channel)/messages"
            auth = botToken
            body = ["content": "Pong!", "allowed_mentions": allowed, "message_reference": ["message_id": id]]
        } else if type == "INTERACTION_CREATE" {
            guard event["type"] as? Int == 2, event["application_id"] as? String == applicationID,
                  let command = event["data"] as? [String: Any], command["name"] as? String == "ping",
                  command["type"] as? Int == 1,
                  let member = event["member"] as? [String: Any], let user = member["user"] as? [String: Any],
                  user["id"] as? String != botID, user["bot"] as? Bool != true,
                  let key = event["token"] as? String, (1...512).contains(key.utf8.count),
                  key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || [45, 46, 95].contains($0) })
            else { return }
            mode = "slash"
            route = "interactions/\(id)/\(key)/callback"
            auth = nil
            body = ["type": 4, "data": ["content": "Pong!", "allowed_mentions": allowed]]
        } else {
            return
        }

        guard handled.insert(id).inserted else { return }
        recent.append(id)
        if recent.count > 1024 { handled.remove(recent.removeFirst()) }
        responseNumber += 1
        let label = String(responseNumber)
        observe?(GatewayObservation(event: "ping_received", time: received, mode: mode, request: label))
        let age = UInt64(id).map { received.timeIntervalSince1970 - (Double($0 >> 22) / 1000 + 1_420_070_400) } ?? 0
        let budget = mode == "slash" ? min(2.5, 2.8 - max(0, age)) : 10
        if mode == "slash", budget <= 0 {
            observe?(GatewayObservation(event: "pong_failed", mode: mode, request: label, error: "interaction_deadline"))
            return
        }
        let limits = [rateLimitedUntil[mode], rateLimitedUntil["global"]].compactMap { $0 }
        guard responses.count < 4, limits.allSatisfy({ $0 <= .now }) else {
            observe?(GatewayObservation(event: "pong_failed", mode: mode, request: label, error: "local_rate_limit_or_busy"))
            return
        }
        let deadline = min(pingDeadline, ContinuousClock.now.advanced(by: .seconds(budget)))
        responses[label] = Task {
            defer { if !Task.isCancelled { responses.removeValue(forKey: label) } }
            do {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else {
                    observe?(GatewayObservation(event: "pong_failed", mode: mode, request: label, error: "response_deadline"))
                    return
                }
                let parts = remaining.components
                let timeout = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                let (data, response) = try await requestWithStatus(route, token: auth, body: body, timeout: timeout)
                if response.statusCode == 429 {
                    let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let retry = detail?["retry_after"] as? Double ?? 5
                    let limited = detail?["global"] as? Bool == true && mode == "mention" ? "global" : mode
                    rateLimitedUntil[limited] = ContinuousClock.now.advanced(by: .seconds(min(86_400, max(1, retry))))
                }
                let success = (200..<300).contains(response.statusCode)
                observe?(GatewayObservation(event: success ? "pong_succeeded" : "pong_failed",
                                            mode: mode, request: label, http: response.statusCode,
                                            error: success ? "" : "discord_http_error"))
            } catch {
                guard !Task.isCancelled else { return }
                observe?(GatewayObservation(event: "pong_failed", mode: mode, request: label, error: Self.describe(error)))
            }
        }
    }
}

extension Gateway: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        let received = Date()
        Task { @MainActor in
            guard socket === webSocketTask, transport == "接続中" else { return }
            transport = "WebSocket接続済み"
            log("WebSocketハンドシェイク成功")
            observe?(GatewayObservation(event: "websocket_open", time: received))
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let received = Date()
        let receivedAt = ContinuousClock.now
        Task { @MainActor in
            guard socket === webSocketTask else { return }
            observe?(GatewayObservation(event: "websocket_close_frame", time: received, instant: receivedAt,
                                        closeCode: closeCode.rawValue))
        }
    }
}
