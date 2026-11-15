import SwiftUI

struct BackgroundGatewayScreen: View {
    @ObservedObject var test: BackgroundGateway
    @ObservedObject var gateway: Gateway
    let offline: Bool
    @Binding var channel: String
    @State private var guild = ""
    @State private var minutes = 3

    var body: some View {
        Form {
            Section("テスト用Botとサーバー") {
                Text("Discordタブで専用Botに接続し、READYを確認してください。")
                TextField("テストサーバーID", text: $guild).keyboardType(.numberPad).disabled(test.running || gateway.registering)
                TextField("テストチャンネルID", text: $channel).keyboardType(.numberPad).disabled(test.running || gateway.registering)
                Button("テストサーバーに /ping を登録") { gateway.registerPing(target) }
                    .disabled(!canConfigure)
                LabeledContent("/ping 登録", value: gateway.registerResult)
            }
            Section("実験") {
                Picker("観測時間", selection: $minutes) {
                    ForEach([3, 10, 30, 60], id: \.self) { Text("\($0)分").tag($0) }
                }
                .disabled(test.running)
                if let error = test.availabilityError { Text(error).font(.footnote) }
                Button("バックグラウンド試験開始") {
                    test.start(gateway: gateway, target: target, minutes: minutes)
                }
                .disabled(!canConfigure || gateway.sending || test.availabilityError != nil)
                Button("試験停止", role: .destructive) { test.stop() }.disabled(!test.running)
            }
            Section("観測結果") {
                LabeledContent("試験", value: test.status)
                LabeledContent("BGTask", value: test.taskState)
                LabeledContent("Gateway", value: gateway.transport + " / " + gateway.ready)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("経過", value: String(format: "%.0f 秒", test.elapsed()))
                }
                LabeledContent("実観測", value: "\(test.observed) / \(test.expected)")
                LabeledContent("送信 / ACK（累計）", value: "\(gateway.sent) / \(gateway.acknowledged)")
                LabeledContent("送信 / ACK（接続 #\(gateway.socketNumber)）", value: "\(gateway.socketSent) / \(gateway.socketACK)")
                LabeledContent("ACK待ち", value: String(gateway.pendingCount))
                LabeledContent("Heartbeat間隔", value: gateway.intervalMS.map { "\($0) ms" } ?? "—")
                LabeledContent("最終ACK遅延", value: gateway.latency)
                LabeledContent("メンション 受信 / 成功", value: result("mention"))
                LabeledContent("/ping 受信 / 成功", value: result("slash"))
                LabeledContent("切断 / 再接続試行", value: "\(test.disconnects) / \(test.reconnects)")
                LabeledContent("最終イベント", value: test.lastEvent?.formatted(date: .omitted, time: .standard) ?? "—")
                if let error = test.logError { LabeledContent("CSVエラー", value: error) }
            }
            Section("CSVエクスポート") {
                if test.running { Text("試験終了後に共有できます。") }
                if test.files.isEmpty { Text("保存済みCSVなし") }
                ForEach(test.files, id: \.self) { file in
                    ShareLink(item: file) { Label(file.lastPathComponent, systemImage: "square.and.arrow.up") }
                        .disabled(test.running)
                }
            }
        }
        .navigationTitle("Background Gateway Test")
    }

    private var target: PingTarget {
        PingTarget(guild: guild.trimmingCharacters(in: .whitespacesAndNewlines),
                   channel: channel.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var canConfigure: Bool {
        gateway.authenticated && !gateway.registering && !offline && !test.running
            && Gateway.validID(target.guild) && Gateway.validID(target.channel)
    }

    private func result(_ mode: String) -> String {
        "\(test.pingCount[mode, default: 0]) / \(test.pongCount[mode, default: 0])"
    }
}
