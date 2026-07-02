import Foundation
import AppKit
import SwiftUI

struct NodeSourceCheckEvent {
    let originalFileName: String
    let sourceHash: String
    let expectedCacheFileName: String
    let cacheDirectoryPath: String
    let exists: Bool
    let localPath: String?
}

@MainActor
final class NodeServiceModel: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var isRunning: Bool = false
    @Published var portText: String = "8787"

    @Published var cacheDirectoryPath: String
    @Published var outputDirectoryPath: String

    @Published var nodeURLText: String = "-"
    @Published var capabilitySummary: String = "读取中…"

    @Published var lastExpectedCacheFileName: String = "-"
    @Published var lastOriginalFileName: String = "-"
    @Published var lastSourceHash: String = "-"
    @Published var lastCheckExists: Bool = false
    @Published var lastLocalPath: String = "-"

    @Published var latestJobState: String = "-"
    @Published var latestJobMessage: String = "-"
    @Published var latestClusterState: String = "-"
    @Published var latestClusterMessage: String = "-"

    @Published var logLines: [String] = []

    private var server: WorkerServer?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDirectoryPath = appSupport.appendingPathComponent("ChronoVolume/WorkerSourceCache", isDirectory: true).path
        outputDirectoryPath = appSupport.appendingPathComponent("ChronoVolume/WorkerOutput", isDirectory: true).path
        refreshCapabilitySummary()
    }

    func refreshCapabilitySummary() {
        capabilitySummary = "读取中…"
        Task.detached(priority: .userInitiated) {
            let caps = DeviceCapabilityDetector.detect(appVersion: "1.0.0")
            await MainActor.run {
                // 按你的要求：不再显示被动散热
                self.capabilitySummary = "\(caps.machineName)｜CPU \(caps.cpuCores)｜GPU \(caps.gpuCores)｜内存 \(caps.memoryGB)GB"
            }
        }
    }

    func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func startServer() {
        guard !isRunning else { return }
        guard let port = UInt16(portText) else {
            appendLog("端口无效：\(portText)")
            return
        }

        let cacheURL = URL(fileURLWithPath: cacheDirectoryPath, isDirectory: true)
        let outputURL = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)

        let runtime = WorkerServer(
            port: port,
            workerName: Host.current().localizedName ?? "ChronoVolume-Node",
            appVersion: "1.0.0",
            sourceCacheDirectory: cacheURL,
            outputDirectory: outputURL,
            onLog: { [weak self] text in
                Task { @MainActor in
                    self?.appendLog(text)
                }
            },
            onSourceCheckEvent: { [weak self] event in
                Task { @MainActor in
                    self?.lastExpectedCacheFileName = event.expectedCacheFileName
                    self?.lastOriginalFileName = event.originalFileName
                    self?.lastSourceHash = event.sourceHash
                    self?.lastCheckExists = event.exists
                    self?.lastLocalPath = event.localPath ?? "-"
                }
            },
            onJobStateChanged: { [weak self] _, state, progress, message in
                Task { @MainActor in
                    self?.latestJobState = "\(state) \(Int(progress * 100))%"
                    self?.latestJobMessage = message
                }
            },
            onClusterProgressChanged: { [weak self] snapshot in
                Task { @MainActor in
                    self?.latestClusterState = "总进度 \(Int(max(0, min(1, snapshot.totalProgress)) * 100))%"
                    self?.latestClusterMessage = snapshot.title
                }
            }
        )

        do {
            try runtime.start()
            server = runtime
            isRunning = true

            let hostName = Host.current().name ?? "localhost"
            nodeURLText = "http://\(hostName):\(port)"

            appendLog("节点服务已启动：\(nodeURLText)")
        } catch {
            appendLog("节点服务启动失败：\(error.localizedDescription)")
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        isRunning = false
        appendLog("节点服务已停止")
    }

    func chooseCacheDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            cacheDirectoryPath = url.path
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectoryPath = url.path
        }
    }

    func copyExpectedCacheFileName() {
        guard lastExpectedCacheFileName != "-", !lastExpectedCacheFileName.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastExpectedCacheFileName, forType: .string)
        appendLog("已复制缓存文件名")
    }

    func copyExpectedFullPath() {
        guard lastExpectedCacheFileName != "-", !lastExpectedCacheFileName.isEmpty else { return }
        let fullPath = URL(fileURLWithPath: cacheDirectoryPath, isDirectory: true)
            .appendingPathComponent(lastExpectedCacheFileName)
            .path
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(fullPath, forType: .string)
        appendLog("已复制缓存完整路径")
    }

    func openCacheDirectoryInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: cacheDirectoryPath, isDirectory: true))
    }

    private func appendLog(_ text: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        logLines.insert("[\(ts)] \(text)", at: 0)
        if logLines.count > 200 {
            logLines.removeLast(logLines.count - 200)
        }
    }
}
