import SwiftUI

struct DistributedExportPanel: View {
    @ObservedObject var settings: DistributedExportSettings
    let currentAxisTitle: String
    let totalOutputFrames: Int
    let pairedPrecisionNotice: String?
    let onTestAllWorkers: (() -> Void)?
    let onStartDistributedExport: (() -> Void)?
    let onRefreshWorkerSource: (() -> Void)?
    let onUploadSourceToWorker: (() -> Void)?
    let onPrepareWorkerRawCache: (() -> Void)?

    var body: some View {
        GroupBox("分布式导出") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用分布式导出", isOn: $settings.isEnabled)
                Toggle("Worker 缺少源缓存时询问上传", isOn: $settings.offerUploadWhenSourceMissing)
                Toggle("记录导出诊断数据", isOn: $settings.recordExportDiagnostics)

                Text("这里用于设置 Worker、分配比例与源缓存策略；导出进度会集中显示在导出弹窗里。开启诊断记录后，导出完成会在视频同目录保存主机与 Worker 的耗时数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let pairedPrecisionNotice {
                    Text(pairedPrecisionNotice)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                LabeledContent("当前轴") {
                    Text(currentAxisTitle)
                }

                LabeledContent("总输出帧数") {
                    Text("\(totalOutputFrames)")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Worker 列表")
                            .font(.subheadline.bold())

                        Spacer()

                        Button("测试全部") {
                            onTestAllWorkers?()
                        }

                        Button("添加 Worker") {
                            settings.addWorker()
                        }
                    }

                    ForEach($settings.workers) { $worker in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("http://10.77.77.2:8787", text: $worker.baseURL)
                                    .textFieldStyle(.roundedBorder)

                                Button("测试") {
                                    settings.testConnection(workerID: worker.id)
                                }

                                Button("删除") {
                                    settings.removeWorker(id: worker.id)
                                }
                                .disabled(settings.workers.count <= 1)
                            }

                            HStack {
                                Text(worker.connectionSummary)
                                    .foregroundStyle(connectionColor(for: worker.connectionState))

                                Text(worker.displayName)

                                Text(worker.capabilitiesSummary)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.footnote)

                            if worker.lastExpectedCacheFileName != "-" {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(worker.lastCacheCheckMessage)
                                        .foregroundStyle(worker.lastCacheExists ? .green : .orange)

                                    Text("视频会话：\(worker.rawCacheMessage)")
                                        .foregroundStyle(worker.isRawCacheReady ? .green : .secondary)

                                    Text("缓存文件名：\(worker.lastExpectedCacheFileName)")
                                        .textSelection(.enabled)

                                    Text("建议完整路径：\(worker.lastExpectedCacheFullPath)")
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                }
                                .font(.footnote)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("调度方式")
                        .font(.subheadline.bold())

                    Text("动态 chunk：本机和所有在线 Worker 从同一个队列领取 chunk，谁先完成谁继续领取下一批。")
                        .foregroundStyle(.secondary)
                        .font(.footnote)

                    Text("自动分配：按 Worker 能力信息估算固定连续区间，导出时每台机器只处理自己的区间。")
                        .foregroundStyle(.secondary)
                        .font(.footnote)

                    Text("手动分配：导出前用累计百分比边界指定本机和每台 Worker 的连续区间。")
                        .foregroundStyle(.secondary)
                        .font(.footnote)

                    Text("在线 Worker：\(settings.workers.filter { $0.isOnline }.count) 台｜总输出 \(totalOutputFrames) 帧")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Worker 缓存操作")
                        .font(.subheadline.bold())

                    HStack {
                        Button("刷新源文件检查") {
                            onRefreshWorkerSource?()
                        }
                        .disabled(!canOperateWorkerCache)

                        Button("发送当前源文件") {
                            onUploadSourceToWorker?()
                        }
                        .disabled(!canUploadSource)

                        Button("导入 Worker 视频") {
                            onPrepareWorkerRawCache?()
                        }
                        .disabled(!canPrepareRawCache)
                    }

                    Text("可先让所有在线 Worker 建立源文件和视频会话缓存；正式分布式导出时也会自动检查并预热所有在线 Worker。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func connectionColor(for state: DistributedConnectionState) -> Color {
        switch state {
        case .online:
            return .green
        case .checking:
            return .orange
        case .idle:
            return .secondary
        case .offline:
            return .red
        }
    }

    private var canOperateWorkerCache: Bool {
        settings.workers.contains { $0.isOnline } && totalOutputFrames > 0
    }

    private var canUploadSource: Bool {
        canOperateWorkerCache && settings.workers.contains {
            $0.isOnline
                && !$0.lastCacheExists
                && $0.lastExpectedCacheFileName != "-"
                && $0.rawCacheState != "checking"
        }
    }

    private var canPrepareRawCache: Bool {
        canOperateWorkerCache
            && settings.workers.contains {
                $0.isOnline
                    && $0.lastExpectedCacheFileName != "-"
                    && $0.lastCacheExists
                    && !$0.isRawCacheReady
                    && !$0.isRawCachePreparing
            }
    }

    private func rangeText(start: Int, end: Int, frameCount: Int) -> String {
        guard frameCount > 0 else {
            return "无"
        }

        guard end >= start, start >= 0 else {
            return "-"
        }

        return "\(start)...\(end)"
    }
}
