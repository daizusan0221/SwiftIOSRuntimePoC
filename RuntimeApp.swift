import SwiftUI

@main
struct RuntimeApp: App {
    @StateObject private var gateway = Gateway()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                GatewayScreen(gateway: gateway, offline: false)
            }
        }
    }
}

struct GatewayScreen: View {
    @ObservedObject var gateway: Gateway
    let offline: Bool
    @State private var token = ""
    @State private var channel = ""

    var body: some View {
        Form {
            Section("認証") {
                SecureField("Discord Bot Token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("チャンネルID", text: $channel)
                    .keyboardType(.numberPad)
                Text("Bot Tokenはメモリにのみ保持します。")
                    .font(.footnote)
                Button("入力したTokenを消去") {
                    gateway.stopAll()
                    token = ""
                }
            }
            Section("操作") {
                if offline { Text("オフライン計測中はDiscord通信を停止します。") }
                Button("Gateway接続") { gateway.connect(token: cleanedToken) }
                    .disabled(offline || gateway.running || !Gateway.validTokenInput(cleanedToken))
                Button("Gateway切断") { gateway.disconnect() }.disabled(!gateway.running)
                Button("送信テスト") {
                    gateway.sendTest(token: cleanedToken, channel: channel.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .disabled(offline || gateway.sending || !Gateway.validTokenInput(cleanedToken) || channel.isEmpty)
            }
            Section("結果") {
                LabeledContent("Gateway", value: gateway.status)
                LabeledContent("WebSocket / Hello", value: gateway.transport)
                LabeledContent("READY / RESUMED", value: gateway.ready)
                LabeledContent("Heartbeat送信 / ACK", value: "\(gateway.sent) / \(gateway.acknowledged)")
                LabeledContent("最終ACK応答時間", value: gateway.latency)
                LabeledContent("REST送信", value: gateway.sendResult)
            }
            Section("通信ログ") {
                ForEach(Array(gateway.logs.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.footnote.monospaced())
                }
            }
        }
        .navigationTitle("Discord Gateway")
    }

    private var cleanedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
}
