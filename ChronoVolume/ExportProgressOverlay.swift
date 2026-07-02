import SwiftUI

struct ExportProgressOverlay: View {
    @ObservedObject var runtime: ExportRuntimeState
    @ObservedObject var distributedSettings: DistributedExportSettings

    let appStatus: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(runtime.title)
                            .font(.title3.bold())

                        Text("导出期间已锁定主界面操作，并暂停与导出无关的交互。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("耗时 \(runtime.elapsedText)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("当前状态")
                        .font(.headline)

                    Text(appStatus.isEmpty ? runtime.latestStatus : appStatus)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if !distributedSettings.progressItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("分布式进度")
                                .font(.headline)

                            Spacer()

                            Text("总进度 \(Int(distributedSettings.totalDistributedProgress * 100))%")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: distributedSettings.totalDistributedProgress)

                        ForEach(distributedSettings.progressItems.filter { $0.role != "cluster" }) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.displayName)
                                        .font(.subheadline.bold())

                                    Text(roleText(for: item))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    Text(item.percentText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                ProgressView(value: item.progress)

                                Text("\(item.state)：\(item.message)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)

                                if let timingText = item.timingText, !timingText.isEmpty {
                                    Text(timingText)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本机导出进度")
                            .font(.headline)

                        ProgressView()
                            .progressViewStyle(.linear)

                        Text("本机普通导出当前使用 App 状态栏文本判断完成状态。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack {
                    Label("导出期间：预览区、播放快捷键、导出按钮等主界面功能会暂时不可操作。", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(runtime.canClose ? "关闭" : "导出进行中…") {
                        onClose()
                    }
                    .disabled(!runtime.canClose)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 620)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(radius: 24)
            .padding()
        }
    }

    private func roleText(for item: DistributedProgressItem) -> String {
        switch item.role {
        case "host":
            return "主机"
        case "worker":
            return "Worker"
        case "cluster":
            return "总进度"
        default:
            return item.role
        }
    }
}
