import SwiftUI

struct NodeServicePanel: View {
    @ObservedObject var model: NodeServiceModel

    var body: some View {
        GroupBox("节点服务") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("允许本机作为辅助导出节点", isOn: $model.isEnabled)

                HStack {
                    Text("端口")
                        .frame(width: 72, alignment: .leading)
                    TextField("8787", text: $model.portText)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("缓存目录")
                        .frame(width: 72, alignment: .leading)
                    TextField("", text: $model.cacheDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("选择") {
                        model.chooseCacheDirectory()
                    }
                }

                HStack {
                    Text("输出目录")
                        .frame(width: 72, alignment: .leading)
                    TextField("", text: $model.outputDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("选择") {
                        model.chooseOutputDirectory()
                    }
                }

                HStack {
                    Button(model.isRunning ? "停止节点服务" : "启动节点服务") {
                        model.toggleServer()
                    }
                    .disabled(!model.isEnabled && !model.isRunning)

                    Button("刷新能力") {
                        model.refreshCapabilitySummary()
                    }

                    Text(model.isRunning ? "运行中" : "未运行")
                        .foregroundStyle(model.isRunning ? .green : .secondary)
                }

                Text("节点地址：\(model.nodeURLText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(model.capabilitySummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("最近一次源文件检查")
                        .font(.subheadline.bold())

                    Text("原文件名：\(model.lastOriginalFileName)")
                        .lineLimit(2)
                    Text("源哈希：\(model.lastSourceHash)")
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text("缓存文件名：\(model.lastExpectedCacheFileName)")
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text("是否已存在：\(model.lastCheckExists ? "是" : "否")")
                    Text("本地路径：\(model.lastLocalPath)")
                        .lineLimit(3)
                        .textSelection(.enabled)

                    HStack {
                        Button("复制缓存文件名") {
                            model.copyExpectedCacheFileName()
                        }
                        .disabled(model.lastExpectedCacheFileName == "-" || model.lastExpectedCacheFileName.isEmpty)

                        Button("复制完整路径") {
                            model.copyExpectedFullPath()
                        }
                        .disabled(model.lastExpectedCacheFileName == "-" || model.lastExpectedCacheFileName.isEmpty)

                        Button("打开缓存目录") {
                            model.openCacheDirectoryInFinder()
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("最近任务状态")
                        .font(.subheadline.bold())

                    Text("Worker 状态：\(model.latestJobState)")
                    Text("Worker 消息：\(model.latestJobMessage)")
                        .foregroundStyle(.secondary)

                    Text("主机总进度：\(model.latestClusterState)")
                    Text("主机消息：\(model.latestClusterMessage)")
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("日志")
                        .font(.subheadline.bold())

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(minHeight: 140)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
