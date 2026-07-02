import SwiftUI

struct ExportActionPanel: View {
    @ObservedObject var options: ExportOptionsState
    @ObservedObject var distributedSettings: DistributedExportSettings
    let sourceBitDepth: Int
    let sourceColorProfile: VideoColorProfile
    let onLocalExport: () -> Void
    let onDistributedExport: () -> Void

    var body: some View {
        GroupBox("导出设置") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("携带 Alpha 通道", isOn: $options.preserveAlpha)
                Toggle("高精度导出", isOn: $options.highPrecision)
                Toggle("自动补齐偶数尺寸", isOn: $options.padToEven)
                HStack {
                    Text("质量倍率").frame(width: 76, alignment: .leading)
                    Slider(value: $options.qualityScale, in: 0.10...4.0, step: 0.10)
                    Text(String(format: "%.2f", options.qualityScale)).frame(width: 48, alignment: .trailing)
                }
                Text("STL 模型导出可用大于 1.0 的倍率提高像素尺寸和切片数量；视频源高精度仍以源尺寸为上限。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("导出位深").frame(width: 76, alignment: .leading)
                    Picker("导出位深", selection: $options.bitDepth) {
                        ForEach(ExportBitDepth.allCases) { bitDepth in
                            Text(bitDepth.title).tag(bitDepth)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Text("\(options.bitDepth.resolved(sourceBitDepth: sourceBitDepth))-bit")
                        .frame(width: 54, alignment: .trailing)
                }
                HStack {
                    Text("色彩空间").frame(width: 76, alignment: .leading)
                    Picker("色彩空间", selection: $options.colorProfile) {
                        ForEach(ExportColorProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Text("源视频：\(sourceColorProfile.detailText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button("本机导出") { onLocalExport() }
                    Button("分布式导出") { onDistributedExport() }
                        .disabled(!canDistributedExport)
                }
                Text("当前选项：Alpha=\(options.preserveAlpha ? "开启" : "关闭")，高精度=\(options.highPrecision ? "开启" : "关闭")，位深=\(options.bitDepth.resolved(sourceBitDepth: sourceBitDepth))-bit，色彩=\(options.colorProfile.resolved(source: sourceColorProfile).title)。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canDistributedExport: Bool {
        distributedSettings.isEnabled
            && distributedSettings.workers.contains { $0.isOnline }
            && options.highPrecision
    }
}
