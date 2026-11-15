import Foundation
import SwiftUI

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
    private var pendingHeartbeat: ContinuousClock.Instant?
    private var socketFailure: String?
    private var stable = false

    func connect(token: String) {
        guard !running, Self.validTokenInput(token) else { return }
        running = true
        transport = "未接続"
        ready = "未受信"
        sent = 0
        acknowledged = 0
        latency = "—"
        status = "Bot認証を確認中"
        connection = Task {
            defer {
                if !Task.isCancelled {
                    running = false
                    connection = nil
                    resetSession()
                }
            }
            do {
                let data = try await request("gateway/bot", token: token)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let url = Self.gatewayURL(object["url"] as? String) else { throw APIError.invalidResponse }
                try await run(token: token, initialURL: url)
            } catch {
                guard !Task.isCancelled else { return }
                status = "接続終了"
                log("接続終了: \(Self.describe(error))")
            }
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        closeSocket()
        resetSession()
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
        guard !sending, Self.validTokenInput(token), (17...20).contains(channel.utf8.count),
              channel.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(channel) != nil else {
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
        while !Task.isCancelled {
            let ws = sockets.webSocketTask(with: resumable?.url ?? initialURL)
            socket = ws
            stable = false
            socketFailure = nil
            transport = "接続中"
            ready = "待機中"
            status = "WebSocket接続中"
            ws.resume()
            startWatchdog(ws)
            var retry: Retry
            do {
                try await receive(from: ws, token: token)
                retry = Retry(reason: "接続終了", delay: 1)
            } catch {
                try Task.checkCancellation()
                let code = ws.closeCode.rawValue
                if [4004, 4010, 4011, 4012, 4013, 4014].contains(code) {
                    closeSocket()
                    throw Retry(reason: "再接続不可（Gateway \(code)）", delay: 0)
                }
                let backoff = min(60, pow(2, Double(stable ? 0 : retries)))
                retry = (error as? Retry) ?? Retry(
                    reason: socketFailure ?? (code == 0 ? Self.describe(error) : "Gateway切断 \(code)"),
                    delay: backoff * Double.random(in: 0.75...1.25),
                    resetSession: [4007, 4009].contains(code)
                )
            }
            if retry.resetSession { resetSession() }
            closeSocket()
            retries = (stable ? 0 : retries) + 1
            transport = "切断"
            ready = "待機中"
            log(retry.reason)
            guard retries <= 8 else { throw Retry(reason: "再試行上限に到達", delay: 0) }
            status = "再接続待機（\(retries)/8）"
            try await Task.sleep(for: .seconds(retry.delay))
        }
    }

    private func receive(from ws: URLSessionWebSocketTask, token: String) async throws {
        var receivedHello = false
        while !Task.isCancelled {
            let frame = try await ws.receive()
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
                transport = "接続済み / Hello受信"
                log("Hello受信 / Heartbeat間隔 \(Int(ms)) ms")
                startHeartbeat(ws, interval: ms / 1000)
                if let resumable, let sequence {
                    try await transmit(ws, op: 6, data: ["token": token, "session_id": resumable.id, "seq": sequence])
                    log("Resume送信")
                } else {
                    if let lastIdentify {
                        let remaining = lastIdentify.advanced(by: .seconds(5.5)) - ContinuousClock.now
                        if remaining > .zero { try await Task.sleep(for: remaining) }
                    }
                    try Task.checkCancellation()
                    lastIdentify = .now
                    try await transmit(ws, op: 2, data: [
                        "token": token, "intents": 0,
                        "properties": ["os": "iOS", "browser": "SwiftIOSRuntimePoC", "device": "SwiftIOSRuntimePoC"]
                    ])
                    log("Identify送信")
                }
            case 0:
                if let next = packet["s"] as? Int { sequence = next }
                if packet["t"] as? String == "READY" {
                    guard let event = packet["d"] as? [String: Any], let id = event["session_id"] as? String,
                          let url = Self.gatewayURL(event["resume_gateway_url"] as? String) else {
                        throw Retry(reason: "READYの再開情報が不正", delay: 5, resetSession: true)
                    }
                    resumable = SessionState(id: id, url: url)
                    markReady("READY受信")
                } else if packet["t"] as? String == "RESUMED" {
                    markReady("RESUMED受信")
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
                if let started = pendingHeartbeat {
                    let elapsed = started.duration(to: .now)
                    let milliseconds = Double(elapsed.components.seconds) * 1_000
                        + Double(elapsed.components.attoseconds) / 1e15
                    latency = String(format: "%.0f ms", milliseconds)
                }
                pendingHeartbeat = nil
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
                    if let pendingHeartbeat,
                       pendingHeartbeat.duration(to: .now) >= .seconds(interval * 0.99) {
                        socketFailure = "Heartbeat ACKが届かず再接続"
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
        if pendingHeartbeat == nil { pendingHeartbeat = .now }
        let payload: Any = sequence.map { $0 as Any } ?? NSNull()
        try await transmit(ws, op: 1, data: payload)
        guard socket === ws, !Task.isCancelled else { return }
        sent += 1
    }

    private func transmit(_ ws: URLSessionWebSocketTask, op: Int, data: Any) async throws {
        let json = try JSONSerialization.data(withJSONObject: ["op": op, "d": data])
        try await ws.send(.string(String(decoding: json, as: UTF8.self)))
    }

    private func markReady(_ event: String) {
        stable = true
        ready = event
        status = "稼働中"
        watchdog?.cancel()
        log(event)
    }

    private func closeSocket() {
        heartbeat?.cancel()
        heartbeat = nil
        watchdog?.cancel()
        watchdog = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pendingHeartbeat = nil
    }

    private func resetSession() {
        resumable = nil
        sequence = nil
    }

    private func request(_ path: String, token: String, body: [String: Any]? = nil) async throws -> Data {
        let url = URL(string: "https://discord.com/api/v10/\(path)")!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("DiscordBot (https://github.com/, 1.0)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await http.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw APIError.status(response.statusCode) }
        return data
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
        case let url as URLError: return "ネットワークエラー \(url.errorCode)"
        default: return "通信処理エラー"
        }
    }

    private func log(_ text: String) {
        logs.insert("\(Date().formatted(date: .omitted, time: .standard))  \(text)", at: 0)
        if logs.count > 40 { logs.removeLast() }
    }
}

extension Gateway: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard socket === webSocketTask, transport == "接続中" else { return }
            transport = "WebSocket接続済み"
            log("WebSocketハンドシェイク成功")
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        // The receive loop reads closeCode and handles reconnection without logging the remote reason.
    }
}
