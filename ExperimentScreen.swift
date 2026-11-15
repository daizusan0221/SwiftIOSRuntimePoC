import SwiftUI

struct ExperimentScreen: View {
    @ObservedObject var experiment: OfflineExperiment
    let stopNetwork: () -> Void
    let backgroundRunning: Bool
    @State private var mode: ExperimentMode = .normal
    @State private var minutes = 1

    var body: some View {
        Form {
            Section("条件") {
                Picker("実験モード", selection: $mode) {
                    ForEach(ExperimentMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .disabled(experiment.running)
                Picker("連続実行時の目標", selection: $minutes) {
                    Text("1分").tag(1)
                    Text("5分").tag(5)
                    Text("30分").tag(30)
                    Text("8時間").tag(480)
                }
                .disabled(experiment.running)
                if mode == .continued {
                    Text(experiment.continuedStatus).font(.footnote)
                }
                Button("計測開始") {
                    experiment.start(mode: mode, minutes: minutes, stopNetwork: stopNetwork)
                }
                .disabled(backgroundRunning || experiment.running || (mode == .continued && !experiment.continuedAvailable))
                Button("計測停止", role: .destructive) { experiment.stop() }
                    .disabled(!experiment.running)
            }
            Section("計測結果") {
                LabeledContent("状態", value: experiment.status)
                LabeledContent("タスク状態", value: experiment.taskState)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("開始からの経過", value: Self.time(experiment.elapsed()))
                }
                LabeledContent("進捗", value: "\(experiment.completed) / \(experiment.target) バッチ")
                if experiment.target > 0 {
                    ProgressView(value: Double(experiment.completed), total: Double(experiment.target))
                }
                LabeledContent("保存済みログ件数", value: String(experiment.rows))
                LabeledContent("最終実処理", value: experiment.lastExecution?.formatted(date: .abbreviated, time: .standard) ?? "—")
                LabeledContent("最大連続稼働（観測）", value: Self.time(experiment.longest))
                LabeledContent("推定空白の合計", value: Self.time(experiment.estimatedGap))
                LabeledContent("推定空白の最大", value: Self.time(experiment.largestGap))
                if let error = experiment.logError {
                    LabeledContent("保存エラー", value: error)
                }
            }
            Section("CSVエクスポート") {
                if experiment.running { Text("計測停止後にエクスポートできます。") }
                if experiment.files.isEmpty { Text("保存済みCSVなし") }
                ForEach(experiment.files, id: \.self) { file in
                    ShareLink(item: file) { Label(file.lastPathComponent, systemImage: "square.and.arrow.up") }
                        .disabled(experiment.running)
                }
            }
        }
        .navigationTitle("オフライン計測")
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
