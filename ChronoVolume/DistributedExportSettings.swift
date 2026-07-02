import Foundation
import SwiftUI
import AppKit

enum DistributedConnectionState: Equatable {
    case idle
    case checking
    case online
    case offline(String)
}

enum DistributedSplitMode: String, CaseIterable, Identifiable, Codable {
    case automatic = "自动"
    case manual = "手动"

    var id: String { rawValue }
}

enum DistributedSchedulingMode: String, CaseIterable, Identifiable, Codable {
    case dynamicChunk = "动态 chunk"
    case automaticFixed = "自动分配"
    case manualFixed = "手动分配"

    var id: String { rawValue }
}

struct DistributedSchedulingChoice {
    let mode: DistributedSchedulingMode
    let manualBoundaries: [Double]
}

struct DistributedWorkerHello: Codable {
    let name: String
    let status: String
}

struct DistributedWorkerCapabilities: Codable, Equatable {
    let machineName: String
    let hostName: String
    let cpuCores: Int
    let gpuCores: Int
    let memoryGB: Int
    let passiveCooling: Bool
    let osVersion: String
    let appVersion: String
    let supportsAlpha4444: Bool
    let supportsHighPrecisionXY: Bool
}

struct DistributedWorkerNode: Identifiable, Equatable {
    let id: UUID
    var baseURL: String
    var connectionState: DistributedConnectionState
    var name: String
    var capabilities: DistributedWorkerCapabilities?
    var lastExpectedCacheFileName: String
    var lastExpectedCacheFullPath: String
    var lastCacheCheckMessage: String
    var lastCacheExists: Bool
    var rawCacheState: String
    var rawCacheMessage: String

    init(
        id: UUID = UUID(),
        baseURL: String,
        connectionState: DistributedConnectionState = .idle,
        name: String = "-"
    ) {
        self.id = id
        self.baseURL = baseURL
        self.connectionState = connectionState
        self.name = name
        self.capabilities = nil
        self.lastExpectedCacheFileName = "-"
        self.lastExpectedCacheFullPath = "-"
        self.lastCacheCheckMessage = "-"
        self.lastCacheExists = false
        self.rawCacheState = "unknown"
        self.rawCacheMessage = "-"
    }

    var nodeID: String {
        "worker-\(id.uuidString)"
    }

    var normalizedURL: URL? {
        Self.normalizedURL(from: baseURL)
    }

    var connectionSummary: String {
        switch connectionState {
        case .idle:
            return "未检测"
        case .checking:
            return "检测中"
        case .online:
            return "在线"
        case .offline(let reason):
            return "离线：\(reason)"
        }
    }

    var capabilitiesSummary: String {
        guard let capabilities else {
            return "暂无能力信息"
        }
        return "\(capabilities.machineName)｜CPU \(capabilities.cpuCores)｜GPU \(capabilities.gpuCores)｜内存 \(capabilities.memoryGB)GB"
    }

    var displayName: String {
        name == "-" ? "Worker" : name
    }

    var isOnline: Bool {
        if case .online = connectionState {
            return true
        }
        return false
    }

    var isRawCacheReady: Bool {
        rawCacheState == "ready"
    }

    var isRawCachePreparing: Bool {
        rawCacheState == "running" || rawCacheState == "preparing"
    }

    static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        return URL(string: "http://" + trimmed)
    }
}

struct DistributedSplitPlan: Equatable {
    let localStartFrame: Int
    let localEndFrame: Int
    let workerStartFrame: Int
    let workerEndFrame: Int

    var localFrameCount: Int {
        max(0, localEndFrame - localStartFrame + 1)
    }

    var workerFrameCount: Int {
        max(0, workerEndFrame - workerStartFrame + 1)
    }

    static func build(totalFrames: Int, localSharePercent: Double) -> DistributedSplitPlan {
        let clamped = min(100.0, max(0.0, localSharePercent))
        let localFrames = Int((Double(totalFrames) * clamped / 100.0).rounded())
        let safeLocalFrames = min(max(0, localFrames), max(0, totalFrames))

        if totalFrames <= 0 {
            return DistributedSplitPlan(
                localStartFrame: 0,
                localEndFrame: -1,
                workerStartFrame: 0,
                workerEndFrame: -1
            )
        }

        if safeLocalFrames == 0 {
            return DistributedSplitPlan(
                localStartFrame: 0,
                localEndFrame: -1,
                workerStartFrame: 0,
                workerEndFrame: totalFrames - 1
            )
        }

        if safeLocalFrames >= totalFrames {
            return DistributedSplitPlan(
                localStartFrame: 0,
                localEndFrame: totalFrames - 1,
                workerStartFrame: totalFrames,
                workerEndFrame: totalFrames - 1
            )
        }

        let localEnd = safeLocalFrames - 1
        return DistributedSplitPlan(
            localStartFrame: 0,
            localEndFrame: localEnd,
            workerStartFrame: localEnd + 1,
            workerEndFrame: totalFrames - 1
        )
    }
}

struct DistributedSegmentAllocation: Identifiable, Equatable {
    let id: String
    let displayName: String
    let role: String
    let startFrame: Int
    let endFrame: Int

    var frameCount: Int {
        max(0, endFrame - startFrame + 1)
    }
}

struct DistributedMultiSplitPlan: Equatable {
    let local: DistributedSegmentAllocation
    let workers: [DistributedSegmentAllocation]

    var all: [DistributedSegmentAllocation] {
        [local] + workers
    }

    var totalFrameCount: Int {
        all.map(\.frameCount).reduce(0, +)
    }

    static func build(
        totalFrames: Int,
        localSharePercent: Double,
        workers: [DistributedWorkerNode]
    ) -> DistributedMultiSplitPlan {
        let clamped = min(100.0, max(0.0, localSharePercent))
        let safeTotal = max(0, totalFrames)
        let localFrames = min(max(0, Int((Double(safeTotal) * clamped / 100.0).rounded())), safeTotal)
        let onlineWorkers = workers.filter(\.isOnline)

        var cursor = 0
        let local = DistributedSegmentAllocation(
            id: "host",
            displayName: "本机",
            role: "host",
            startFrame: localFrames > 0 ? cursor : 0,
            endFrame: localFrames > 0 ? cursor + localFrames - 1 : -1
        )
        cursor += localFrames

        let remaining = max(0, safeTotal - localFrames)
        guard !onlineWorkers.isEmpty, remaining > 0 else {
            return DistributedMultiSplitPlan(local: local, workers: [])
        }

        let base = remaining / onlineWorkers.count
        let remainder = remaining % onlineWorkers.count
        let workerAllocations = onlineWorkers.enumerated().map { index, worker in
            let count = base + (index < remainder ? 1 : 0)
            let start = count > 0 ? cursor : cursor
            let end = count > 0 ? cursor + count - 1 : cursor - 1
            cursor += count
            return DistributedSegmentAllocation(
                id: worker.nodeID,
                displayName: worker.displayName,
                role: "worker",
                startFrame: start,
                endFrame: end
            )
        }

        return DistributedMultiSplitPlan(local: local, workers: workerAllocations)
    }

    static func build(
        totalFrames: Int,
        workers: [DistributedWorkerNode],
        weights: [Double]
    ) -> DistributedMultiSplitPlan {
        let onlineWorkers = workers.filter(\.isOnline)
        let nodeCount = onlineWorkers.count + 1
        let safeTotal = max(0, totalFrames)
        let safeWeights = (0..<nodeCount).map { index in
            index < weights.count ? max(0.0, weights[index]) : 1.0
        }
        let totalWeight = max(0.0001, safeWeights.reduce(0.0, +))

        var frameCounts: [Int] = safeWeights.map {
            Int((Double(safeTotal) * $0 / totalWeight).rounded())
        }
        var delta = safeTotal - frameCounts.reduce(0, +)
        var adjustIndex = 0
        while delta != 0, !frameCounts.isEmpty {
            if delta > 0 {
                frameCounts[adjustIndex % frameCounts.count] += 1
                delta -= 1
            } else if frameCounts[adjustIndex % frameCounts.count] > 0 {
                frameCounts[adjustIndex % frameCounts.count] -= 1
                delta += 1
            }
            adjustIndex += 1
        }

        return buildFromFrameCounts(totalFrames: safeTotal, workers: onlineWorkers, frameCounts: frameCounts)
    }

    static func build(
        totalFrames: Int,
        workers: [DistributedWorkerNode],
        manualBoundaries: [Double]
    ) -> DistributedMultiSplitPlan {
        let onlineWorkers = workers.filter(\.isOnline)
        let nodeCount = onlineWorkers.count + 1
        let safeTotal = max(0, totalFrames)
        let sortedBoundaries = manualBoundaries
            .map { min(100.0, max(0.0, $0)) }
            .sorted()
        var marks = [0] + sortedBoundaries.prefix(max(0, nodeCount - 1)).map {
            Int((Double(safeTotal) * $0 / 100.0).rounded())
        } + [safeTotal]

        while marks.count < nodeCount + 1 {
            marks.insert(safeTotal, at: marks.count - 1)
        }

        let frameCounts = (0..<nodeCount).map { index in
            max(0, marks[index + 1] - marks[index])
        }
        return buildFromFrameCounts(totalFrames: safeTotal, workers: onlineWorkers, frameCounts: frameCounts)
    }

    private static func buildFromFrameCounts(
        totalFrames: Int,
        workers: [DistributedWorkerNode],
        frameCounts: [Int]
    ) -> DistributedMultiSplitPlan {
        var cursor = 0
        func allocation(id: String, displayName: String, role: String, count: Int) -> DistributedSegmentAllocation {
            let start = count > 0 ? cursor : cursor
            let end = count > 0 ? cursor + count - 1 : cursor - 1
            cursor += count
            return DistributedSegmentAllocation(
                id: id,
                displayName: displayName,
                role: role,
                startFrame: start,
                endFrame: min(end, max(-1, totalFrames - 1))
            )
        }

        let local = allocation(
            id: "host",
            displayName: "本机",
            role: "host",
            count: frameCounts.first ?? totalFrames
        )
        let workerAllocations = workers.enumerated().map { index, worker in
            allocation(
                id: worker.nodeID,
                displayName: worker.displayName,
                role: "worker",
                count: index + 1 < frameCounts.count ? frameCounts[index + 1] : 0
            )
        }
        return DistributedMultiSplitPlan(local: local, workers: workerAllocations)
    }
}

@MainActor
final class DistributedExportSettings: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var workers: [DistributedWorkerNode] = [
        DistributedWorkerNode(baseURL: "http://10.77.77.2:8787")
    ]
    @Published var splitMode: DistributedSplitMode = .manual
    @Published var localSharePercent: Double = 50.0
    @Published var automaticSuggestedLocalSharePercent: Double = 60.0

    @Published var offerUploadWhenSourceMissing: Bool = true
    @Published var recordExportDiagnostics: Bool = false

    @Published var lastExpectedWorkerCacheFileName: String = "-"
    @Published var lastExpectedWorkerCacheFullPath: String = "-"
    @Published var lastWorkerCacheCheckMessage: String = "-"
    @Published var lastWorkerCacheExists: Bool = false
    @Published var workerRawCacheState: String = "unknown"
    @Published var workerRawCacheMessage: String = "-"

    // 分布式进度。先支持本机 + 单 Worker，后续多 Worker 直接追加 item 即可。
    @Published var activeSessionID: String = "-"
    @Published var totalDistributedProgress: Double = 0.0
    @Published var progressItems: [DistributedProgressItem] = []

    func makeProjectState() -> ChronoVolumeProjectDocument.DistributedExportProjectState {
        ChronoVolumeProjectDocument.DistributedExportProjectState(
            isEnabled: isEnabled,
            splitMode: splitMode,
            localSharePercent: localSharePercent,
            automaticSuggestedLocalSharePercent: automaticSuggestedLocalSharePercent,
            offerUploadWhenSourceMissing: offerUploadWhenSourceMissing,
            recordExportDiagnostics: recordExportDiagnostics,
            workers: workers.map {
                ChronoVolumeProjectDocument.DistributedWorkerRecord(
                    id: $0.id,
                    baseURL: $0.baseURL,
                    name: $0.name
                )
            }
        )
    }

    func restoreProjectState(_ state: ChronoVolumeProjectDocument.DistributedExportProjectState) {
        isEnabled = state.isEnabled
        splitMode = state.splitMode
        localSharePercent = max(0, min(100, state.localSharePercent))
        automaticSuggestedLocalSharePercent = max(0, min(100, state.automaticSuggestedLocalSharePercent))
        offerUploadWhenSourceMissing = state.offerUploadWhenSourceMissing
        recordExportDiagnostics = state.recordExportDiagnostics
        workers = state.workers.isEmpty
            ? [DistributedWorkerNode(baseURL: "http://10.77.77.2:8787")]
            : state.workers.map {
                DistributedWorkerNode(
                    id: $0.id,
                    baseURL: $0.baseURL,
                    connectionState: .idle,
                    name: $0.name
                )
            }
        clearWorkerCacheHint()
        activeSessionID = "-"
        totalDistributedProgress = 0
        progressItems = []
    }

    var primaryWorker: DistributedWorkerNode? {
        workers.first
    }

    var workerBaseURL: String {
        get { workers.first?.baseURL ?? "" }
        set {
            if workers.isEmpty {
                workers = [DistributedWorkerNode(baseURL: newValue)]
            } else {
                workers[0].baseURL = newValue
            }
        }
    }

    var connectionState: DistributedConnectionState {
        workers.first?.connectionState ?? .idle
    }

    var workerName: String {
        workers.first?.name ?? "-"
    }

    var workerCapabilities: DistributedWorkerCapabilities? {
        workers.first?.capabilities
    }

    var effectiveLocalSharePercent: Double {
        switch splitMode {
        case .automatic:
            return automaticSuggestedLocalSharePercent
        case .manual:
            return localSharePercent
        }
    }

    var normalizedWorkerURL: URL? {
        primaryWorker?.normalizedURL
    }

    var connectionSummary: String {
        switch connectionState {
        case .idle:
            return "未检测"
        case .checking:
            return "检测中"
        case .online:
            return "在线"
        case .offline(let reason):
            return "离线：\(reason)"
        }
    }

    var capabilitiesSummary: String {
        guard let caps = workerCapabilities else {
            return "暂无能力信息"
        }

        return "\(caps.machineName)｜CPU \(caps.cpuCores)｜GPU \(caps.gpuCores)｜内存 \(caps.memoryGB)GB"
    }

    func splitPlan(totalOutputFrames: Int) -> DistributedSplitPlan {
        DistributedSplitPlan.build(
            totalFrames: totalOutputFrames,
            localSharePercent: effectiveLocalSharePercent
        )
    }

    func multiSplitPlan(totalOutputFrames: Int) -> DistributedMultiSplitPlan {
        DistributedMultiSplitPlan.build(
            totalFrames: totalOutputFrames,
            localSharePercent: effectiveLocalSharePercent,
            workers: workers
        )
    }

    func addWorker() {
        let next = workers.count + 2
        workers.append(DistributedWorkerNode(baseURL: "http://10.77.77.\(next):8787"))
    }

    func removeWorker(id: UUID) {
        workers.removeAll { $0.id == id }
        if workers.isEmpty {
            workers.append(DistributedWorkerNode(baseURL: "http://10.77.77.2:8787"))
        }
    }

    func clearWorkerCacheHint() {
        lastExpectedWorkerCacheFileName = "-"
        lastExpectedWorkerCacheFullPath = "-"
        lastWorkerCacheCheckMessage = "-"
        lastWorkerCacheExists = false
        workerRawCacheState = "unknown"
        workerRawCacheMessage = "-"
    }

    func updateWorkerCacheHint(
        expectedFileName: String,
        expectedFullPath: String,
        exists: Bool,
        message: String
    ) {
        lastExpectedWorkerCacheFileName = expectedFileName
        lastExpectedWorkerCacheFullPath = expectedFullPath
        lastWorkerCacheExists = exists
        lastWorkerCacheCheckMessage = message
        if let firstID = workers.first?.id {
            updateWorkerCacheHint(
                workerID: firstID,
                expectedFileName: expectedFileName,
                expectedFullPath: expectedFullPath,
                exists: exists,
                message: message
            )
        }
    }

    func updateWorkerRawCacheState(
        state: String,
        message: String
    ) {
        workerRawCacheState = state
        workerRawCacheMessage = message
        if let firstID = workers.first?.id {
            updateWorkerRawCacheState(workerID: firstID, state: state, message: message)
        }
    }

    func updateWorkerCacheHint(
        workerID: UUID,
        expectedFileName: String,
        expectedFullPath: String,
        exists: Bool,
        message: String
    ) {
        guard let index = workers.firstIndex(where: { $0.id == workerID }) else { return }
        workers[index].lastExpectedCacheFileName = expectedFileName
        workers[index].lastExpectedCacheFullPath = expectedFullPath
        workers[index].lastCacheExists = exists
        workers[index].lastCacheCheckMessage = message
    }

    func updateWorkerRawCacheState(
        workerID: UUID,
        state: String,
        message: String
    ) {
        guard let index = workers.firstIndex(where: { $0.id == workerID }) else { return }
        workers[index].rawCacheState = state
        workers[index].rawCacheMessage = message
    }

    func updateWorkerConnection(
        workerID: UUID,
        state: DistributedConnectionState,
        name: String,
        capabilities: DistributedWorkerCapabilities?
    ) {
        guard let index = workers.firstIndex(where: { $0.id == workerID }) else { return }
        workers[index].connectionState = state
        workers[index].name = name
        workers[index].capabilities = capabilities

        let onlineCaps = workers.compactMap { worker -> DistributedWorkerCapabilities? in
            worker.isOnline ? worker.capabilities : nil
        }
        automaticSuggestedLocalSharePercent = onlineCaps.contains { $0.gpuCores < 10 } ? 50.0 : 40.0
    }

    var isWorkerRawCacheReady: Bool {
        workerRawCacheState == "ready"
    }

    var isWorkerRawCachePreparing: Bool {
        workerRawCacheState == "running" || workerRawCacheState == "preparing"
    }

    func copyExpectedWorkerCacheFileName() {
        guard lastExpectedWorkerCacheFileName != "-", !lastExpectedWorkerCacheFileName.isEmpty else {
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastExpectedWorkerCacheFileName, forType: .string)
    }

    func copyExpectedWorkerCacheFullPath() {
        guard lastExpectedWorkerCacheFullPath != "-", !lastExpectedWorkerCacheFullPath.isEmpty else {
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastExpectedWorkerCacheFullPath, forType: .string)
    }

    func resetProgress(sessionID: String) {
        activeSessionID = sessionID
        totalDistributedProgress = 0.0
        progressItems = [
            DistributedProgressItem(
                nodeID: "host",
                displayName: "本机",
                role: "host",
                state: "waiting",
                progress: 0.0,
                message: "等待开始",
                timingText: nil
            )
        ]
    }

    func updateProgressItem(
        nodeID: String,
        displayName: String,
        role: String,
        state: String,
        progress: Double,
        message: String,
        timingText: String? = nil
    ) {
        let safeProgress = max(0.0, min(1.0, progress))
        let existingIndex = progressItems.firstIndex(where: { $0.nodeID == nodeID })
        let monotonicStates: Set<String> = ["running", "downloading", "stitching", "completed"]
        let itemProgress: Double
        if
            let existingIndex,
            monotonicStates.contains(state)
        {
            itemProgress = max(progressItems[existingIndex].progress, safeProgress)
        } else {
            itemProgress = safeProgress
        }

        let item = DistributedProgressItem(
            nodeID: nodeID,
            displayName: displayName,
            role: role,
            state: state,
            progress: itemProgress,
            message: message,
            timingText: timingText ?? existingIndex.map { progressItems[$0].timingText } ?? nil
        )

        if let existingIndex {
            progressItems[existingIndex] = item
        } else {
            progressItems.append(item)
        }

        if let cluster = progressItems.first(where: { $0.role == "cluster" }) {
            totalDistributedProgress = cluster.progress
        } else {
            let workItems = progressItems.filter { $0.state != "skipped" }
            if workItems.isEmpty {
                totalDistributedProgress = 0.0
            } else {
                totalDistributedProgress = workItems.map(\.progress).reduce(0.0, +) / Double(workItems.count)
            }
        }
    }

    func makeClusterSnapshot(title: String) -> DistributedClusterProgressSnapshot {
        DistributedClusterProgressSnapshot(
            sessionID: activeSessionID,
            title: title,
            totalProgress: totalDistributedProgress,
            items: progressItems,
            updatedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )
    }

    func testConnection() {
        testAllConnections()
    }

    func testAllConnections() {
        for worker in workers {
            testConnection(workerID: worker.id)
        }
    }

    func testConnection(workerID: UUID) {
        guard let index = workers.firstIndex(where: { $0.id == workerID }) else { return }
        guard let baseURL = workers[index].normalizedURL else {
            workers[index].connectionState = .offline("Worker 地址无效")
            workers[index].capabilities = nil
            workers[index].name = "-"
            return
        }

        workers[index].connectionState = .checking
        workers[index].capabilities = nil
        workers[index].name = "-"

        Task {
            do {
                let helloURL = baseURL.appendingPathComponent("hello")
                let capsURL = baseURL.appendingPathComponent("capabilities")

                let (helloData, helloResp) = try await URLSession.shared.data(from: helloURL)
                guard let helloHTTP = helloResp as? HTTPURLResponse,
                      (200...299).contains(helloHTTP.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                let hello = try JSONDecoder().decode(DistributedWorkerHello.self, from: helloData)

                let (capsData, capsResp) = try await URLSession.shared.data(from: capsURL)
                guard let capsHTTP = capsResp as? HTTPURLResponse,
                      (200...299).contains(capsHTTP.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                let caps = try JSONDecoder().decode(DistributedWorkerCapabilities.self, from: capsData)

                await MainActor.run {
                    guard let index = self.workers.firstIndex(where: { $0.id == workerID }) else { return }
                    self.workers[index].name = hello.name
                    self.workers[index].capabilities = caps
                    self.workers[index].connectionState = .online

                    let onlineCaps = self.workers.compactMap { worker -> DistributedWorkerCapabilities? in
                        worker.isOnline ? worker.capabilities : nil
                    }
                    self.automaticSuggestedLocalSharePercent = onlineCaps.contains { $0.gpuCores < 10 } ? 50.0 : 40.0
                }
            } catch {
                await MainActor.run {
                    guard let index = self.workers.firstIndex(where: { $0.id == workerID }) else { return }
                    self.workers[index].connectionState = .offline(error.localizedDescription)
                    self.workers[index].capabilities = nil
                    self.workers[index].name = "-"
                }
            }
        }
    }
}
