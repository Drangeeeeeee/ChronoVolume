import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum RuntimeAuditSeverity: String, Codable, CaseIterable {
    case info
    case success
    case completed
    case warning
    case error

    var title: String {
        switch self {
        case .info: return "信息"
        case .success: return "生效"
        case .completed: return "完成"
        case .warning: return "注意"
        case .error: return "异常"
        }
    }

    var color: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .completed: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

enum RuntimeAuditProbeState: String, Codable, CaseIterable, Identifiable {
    case idle
    case passed
    case warning
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: return "待触发"
        case .passed: return "生效"
        case .warning: return "需关注"
        case .failed: return "异常"
        }
    }

    var severity: RuntimeAuditSeverity {
        switch self {
        case .idle: return .info
        case .passed: return .success
        case .warning: return .warning
        case .failed: return .error
        }
    }

    var sortRank: Int {
        switch self {
        case .failed: return 0
        case .warning: return 1
        case .passed: return 2
        case .idle: return 3
        }
    }
}

struct RuntimeAuditProbe: Identifiable, Codable, Equatable {
    let id: String
    var category: String
    var title: String
    var state: RuntimeAuditProbeState
    var summary: String
    var detail: String
    var updatedAt: Date
    var transitionCount: Int
}

struct RuntimeAuditEvent: Identifiable, Codable, Equatable {
    let id: UUID
    var date: Date
    var severity: RuntimeAuditSeverity
    var category: String
    var title: String
    var message: String
}

private struct RuntimeAuditSnapshotDocument: Codable {
    var schemaVersion: Int
    var toolVersion: String
    var generatedAt: Date
    var lastSampleAt: Date?
    var applicationName: String
    var bundleIdentifier: String
    var processIdentifier: Int32
    var stateSummary: String
    var worstState: RuntimeAuditProbeState
    var probes: [RuntimeAuditProbe]
    var events: [RuntimeAuditEvent]
}

@MainActor
final class RuntimeAuditModel: ObservableObject {
    static let toolVersion = "runtime-audit-refresh-completed-v2"

    @Published var isEnabled = true
    @Published var refreshRequestID = 0
    @Published private(set) var probes: [RuntimeAuditProbe] = []
    @Published private(set) var events: [RuntimeAuditEvent] = []
    @Published private(set) var lastExportedURL: URL?

    private var lastStatuses: [String: String] = [:]
    private var lastSampleDate: Date?
    private var isSampling = false
    private let maxEvents = 350
    private let externalBridge = RuntimeAuditExternalBridge()

    var stateSummaryText: String {
        let failed = probes.filter { $0.state == .failed }.count
        let warnings = probes.filter { $0.state == .warning }.count
        let passed = probes.filter { $0.state == .passed }.count

        if failed > 0 {
            return "异常 \(failed)｜注意 \(warnings)｜生效 \(passed)"
        }
        if warnings > 0 {
            return "注意 \(warnings)｜生效 \(passed)"
        }
        return "生效 \(passed)"
    }

    var worstState: RuntimeAuditProbeState {
        probes.map(\.state).min { $0.sortRank < $1.sortRank } ?? .idle
    }

    var sortedProbes: [RuntimeAuditProbe] {
        probes.sorted {
            if $0.state.sortRank != $1.state.sortRank {
                return $0.state.sortRank < $1.state.sortRank
            }
            if $0.category != $1.category {
                return $0.category < $1.category
            }
            return $0.title < $1.title
        }
    }

    var recentEvents: [RuntimeAuditEvent] {
        events.sorted { $0.date > $1.date }
    }

    func record(
        _ severity: RuntimeAuditSeverity,
        category: String,
        title: String,
        message: String
    ) {
        guard isEnabled else { return }
        events.append(
            RuntimeAuditEvent(
                id: UUID(),
                date: Date(),
                severity: severity,
                category: category,
                title: title,
                message: message
            )
        )
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        if !isSampling {
            publishExternalSnapshot()
        }
    }

    func observeStatus(source: String, status: String) {
        guard isEnabled else { return }
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-", lastStatuses[source] != trimmed else { return }
        lastStatuses[source] = trimmed

        if containsFailure(trimmed) {
            record(.error, category: "状态", title: source, message: trimmed)
        } else if containsCompletion(trimmed) {
            record(.completed, category: "状态", title: source, message: trimmed)
        } else if containsReady(trimmed) {
            record(.success, category: "状态", title: source, message: trimmed)
        } else if trimmed.contains("取消") || trimmed.contains("丢失") {
            record(.warning, category: "状态", title: source, message: trimmed)
        }
    }

    func clearEvents() {
        events.removeAll()
        publishExternalSnapshot()
    }

    func refreshSnapshot() {
        refreshRequestID += 1
        record(.completed, category: "动态审查", title: "刷新完成", message: "已完成一次手动刷新请求")
    }

    func exportSnapshotInteractively() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ChronoVolume-runtime-audit-\(Self.fileTimestamp()).json"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let document = makeSnapshotDocument()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: url, options: .atomic)
            lastExportedURL = url
            record(.success, category: "动态审查", title: "导出审查日志", message: url.lastPathComponent)
        } catch {
            record(.error, category: "动态审查", title: "导出审查日志失败", message: error.localizedDescription)
        }
    }

    func sample(
        app: AppModel,
        composition: CompositionModel,
        exportRuntime: ExportRuntimeState,
        distributed: DistributedExportSettings,
        projectURL: URL?,
        importedVideoCount: Int,
        selectedVideoID: UUID?,
        selectedTab: Int,
        hasUnsavedChanges: Bool,
        autosaveExists: Bool
    ) {
        guard isEnabled else { return }
        lastSampleDate = Date()
        isSampling = true
        defer {
            isSampling = false
            publishExternalSnapshot()
        }

        updateProjectProbe(projectURL: projectURL, hasUnsavedChanges: hasUnsavedChanges, autosaveExists: autosaveExists)
        updateMediaProbe(app: app, importedVideoCount: importedVideoCount, selectedVideoID: selectedVideoID)
        updateMissingMediaProbe(composition: composition)
        updateVolumeProbe(app: app)
        updatePlaybackProbe(app: app, composition: composition)
        updateThreeDProbe(app: app, selectedTab: selectedTab)
        updateCameraProbe(app: app, composition: composition)
        updateCompositionProbe(composition: composition, selectedTab: selectedTab)
        updateLayerProbe(composition: composition, selectedTab: selectedTab)
        updateKeyframeProbe(composition: composition)
        updateExpressionProbe(composition: composition)
        updateBlendProbe(composition: composition)
        updateCacheProbe(composition: composition)
        updateExportProbe(app: app, composition: composition, exportRuntime: exportRuntime)
        updateRenderQueueProbe(composition: composition)
        updateDistributedProbe(distributed: distributed)
        updatePerformanceProbe(composition: composition)
    }

    private func updateProbe(
        id: String,
        category: String,
        title: String,
        state: RuntimeAuditProbeState,
        summary: String,
        detail: String = ""
    ) {
        let now = Date()
        if let index = probes.firstIndex(where: { $0.id == id }) {
            let oldState = probes[index].state
            probes[index].category = category
            probes[index].title = title
            probes[index].state = state
            probes[index].summary = summary
            probes[index].detail = detail
            probes[index].updatedAt = now
            if oldState != state {
                probes[index].transitionCount += 1
                recordStateTransition(probe: probes[index], oldState: oldState)
            }
        } else {
            let probe = RuntimeAuditProbe(
                id: id,
                category: category,
                title: title,
                state: state,
                summary: summary,
                detail: detail,
                updatedAt: now,
                transitionCount: 0
            )
            probes.append(probe)
            if state == .failed || state == .warning || state == .passed {
                record(state.severity, category: category, title: title, message: summary)
            }
        }
    }

    private func recordStateTransition(probe: RuntimeAuditProbe, oldState: RuntimeAuditProbeState) {
        if oldState != .idle, probe.state == .idle {
            let message = "\(oldState.title) → \(probe.state.title)：\(probe.summary)"
            record(.completed, category: probe.category, title: "\(probe.title)完成", message: message)
            return
        }
        guard probe.state == .failed || probe.state == .warning || probe.state == .passed else { return }
        let message = "\(oldState.title) → \(probe.state.title)：\(probe.summary)"
        record(probe.state.severity, category: probe.category, title: probe.title, message: message)
    }

    private func updateProjectProbe(projectURL: URL?, hasUnsavedChanges: Bool, autosaveExists: Bool) {
        if let projectURL {
            let validExtension = projectURL.pathExtension.caseInsensitiveCompare(ChronoVolumeProjectDocument.fileExtension) == .orderedSame
            updateProbe(
                id: "project.document",
                category: "项目",
                title: "项目文件 / 保存状态",
                state: validExtension ? .passed : .warning,
                summary: validExtension ? "当前项目文件为 .CV" : "当前项目扩展名不是 .CV",
                detail: "\(projectURL.lastPathComponent)｜\(hasUnsavedChanges ? "有未保存更改" : "已保存")"
            )
        } else if hasUnsavedChanges {
            updateProbe(
                id: "project.document",
                category: "项目",
                title: "项目文件 / 保存状态",
                state: autosaveExists ? .passed : .warning,
                summary: autosaveExists ? "未保存项目已有自动保存恢复文件" : "未保存项目尚未生成恢复文件",
                detail: "新项目或恢复项目尚未另存为 .CV"
            )
        } else {
            updateProbe(
                id: "project.document",
                category: "项目",
                title: "项目文件 / 保存状态",
                state: .idle,
                summary: "当前没有待验证的保存动作",
                detail: "保存、另存为或自动保存后会更新"
            )
        }
    }

    private func updateMediaProbe(app: AppModel, importedVideoCount: Int, selectedVideoID: UUID?) {
        guard importedVideoCount > 0 else {
            updateProbe(
                id: "media.import",
                category: "素材",
                title: "素材导入 / 当前素材",
                state: .idle,
                summary: "尚未导入主视频素材"
            )
            return
        }

        if selectedVideoID == nil {
            updateProbe(
                id: "media.import",
                category: "素材",
                title: "素材导入 / 当前素材",
                state: .failed,
                summary: "已有导入素材但没有选中素材"
            )
            return
        }

        let loaded = app.sourceFrameCount > 0 && app.previewDepthCount > 0
        let loading = app.status.contains("导入") || app.status.contains("加载") || app.status.contains("构建")
        updateProbe(
            id: "media.import",
            category: "素材",
            title: "素材导入 / 当前素材",
            state: loaded ? .passed : (loading ? .warning : .failed),
            summary: loaded ? "当前素材已载入体数据" : "当前素材尚未完成体数据载入",
            detail: "主素材 \(importedVideoCount) 个｜\(app.sourceFrameCount) 帧｜\(app.sourceBitDepth)-bit｜\(app.sourceColorProfile.title)"
        )
    }

    private func updateMissingMediaProbe(composition: CompositionModel) {
        let videos = composition.videoAssets
        guard !videos.isEmpty else {
            updateProbe(
                id: "media.missing",
                category: "素材",
                title: "素材缺失检查",
                state: .idle,
                summary: "合成素材列表为空"
            )
            return
        }

        let missing = videos.filter(\.sourceFileMissing)
        updateProbe(
            id: "media.missing",
            category: "素材",
            title: "素材缺失检查",
            state: missing.isEmpty ? .passed : .failed,
            summary: missing.isEmpty ? "合成素材文件均在线" : "发现 \(missing.count) 个脱机素材",
            detail: missing.map(\.name).prefix(4).joined(separator: "、")
        )
    }

    private func updateVolumeProbe(app: AppModel) {
        guard app.sourceFrameCount > 0 else {
            updateProbe(
                id: "volume.integrity",
                category: "体数据",
                title: "体数据 / 元数据",
                state: .idle,
                summary: "尚无已载入视频"
            )
            return
        }

        let previewOK = app.previewDepthCount > 0
        let fullOK = app.fullTemporalDepthCount == 0 || app.previewDepthCount <= app.fullTemporalDepthCount
        let state: RuntimeAuditProbeState = previewOK && fullOK ? .passed : .failed
        let alphaText = app.alphaInfo.isEmpty ? "Alpha 状态未知" : app.alphaInfo
        updateProbe(
            id: "volume.integrity",
            category: "体数据",
            title: "体数据 / 元数据",
            state: state,
            summary: state == .passed ? "预览体与完整体深度关系正常" : "预览体/完整体深度异常",
            detail: "预览 \(app.previewDepthCount)｜完整 \(app.fullTemporalDepthCount)｜源 \(app.sourceFrameCount)｜\(alphaText)"
        )
    }

    private func updatePlaybackProbe(app: AppModel, composition: CompositionModel) {
        if app.isPlaying {
            updateProbe(
                id: "playback.active",
                category: "播放",
                title: "2D 播放",
                state: .passed,
                summary: "2D 播放正在运行",
                detail: "索引 \(app.currentIndex)｜倍率 \(String(format: "%.2f", app.playbackRate))x"
            )
        } else if composition.isCompositionPlaying {
            updateProbe(
                id: "playback.active",
                category: "播放",
                title: "合成播放",
                state: .passed,
                summary: "合成时间线正在播放",
                detail: "帧 \(composition.currentFrame)"
            )
        } else {
            updateProbe(
                id: "playback.active",
                category: "播放",
                title: "播放状态",
                state: .idle,
                summary: "当前未播放",
                detail: "2D 索引 \(app.currentIndex)｜合成帧 \(composition.currentFrame)"
            )
        }
    }

    private func updateThreeDProbe(app: AppModel, selectedTab: Int) {
        guard selectedTab == 1 else {
            updateProbe(
                id: "view.3d",
                category: "3D",
                title: "3D 视图",
                state: .idle,
                summary: "3D 工作区未处于前台"
            )
            return
        }

        updateProbe(
            id: "view.3d",
            category: "3D",
            title: "3D 视图",
            state: app.renderer == nil ? .warning : .passed,
            summary: app.renderer == nil ? "3D 渲染器尚未附着" : "3D 渲染器已附着",
            detail: "Alpha \(app.useAlpha ? "开" : "关")｜边缘连续 \(app.smoothVolumeEdges ? "开" : "关")｜背景 \(app.volumeBackgroundMode.rawValue)"
        )
    }

    private func updateCameraProbe(app: AppModel, composition: CompositionModel) {
        let compositionCameraCount = composition.composition.cameraClips.count
        let active = app.isCameraPreviewFloating || compositionCameraCount > 0
        updateProbe(
            id: "camera.system",
            category: "摄像机",
            title: "摄像机系统",
            state: active ? .passed : .idle,
            summary: active ? "摄像机状态正在被管理" : "尚未触发摄像机工作流",
            detail: "主摄像机关键帧 \(app.cameraKeyframes.count)｜合成摄像机 \(compositionCameraCount)｜悬浮预览 \(app.isCameraPreviewFloating ? "开" : "关")"
        )
    }

    private func updateCompositionProbe(composition: CompositionModel, selectedTab: Int) {
        let active = selectedTab == 2 || !composition.assets.isEmpty || !composition.composition.layers.isEmpty
        updateProbe(
            id: "composition.workspace",
            category: "合成",
            title: "合成工作区",
            state: active ? .passed : .idle,
            summary: active ? "合成模型处于可用状态" : "尚未进入合成工作流",
            detail: "\(composition.activeCompositionName)｜素材 \(composition.assets.count)｜预合成 \(composition.precompositionAssets.count)"
        )
    }

    private func updateLayerProbe(composition: CompositionModel, selectedTab: Int) {
        let layers = composition.composition.layers
        guard !layers.isEmpty else {
            updateProbe(
                id: "composition.layers",
                category: "合成",
                title: "图层系统",
                state: selectedTab == 2 ? .warning : .idle,
                summary: selectedTab == 2 ? "当前合成还没有图层" : "尚未添加图层",
                detail: "把素材拖入或加入时间线后会变为生效"
            )
            return
        }

        let visible = layers.filter(\.isVisible).count
        let locked = layers.filter(\.isLocked).count
        let solo = layers.filter(\.isSolo).count
        updateProbe(
            id: "composition.layers",
            category: "合成",
            title: "图层系统",
            state: visible == 0 ? .warning : .passed,
            summary: visible == 0 ? "当前合成没有可见图层" : "图层系统正在生效",
            detail: "总计 \(layers.count)｜可见 \(visible)｜锁定 \(locked)｜Solo \(solo)"
        )
    }

    private func updateKeyframeProbe(composition: CompositionModel) {
        let layerKeys = composition.composition.layers.reduce(0) { $0 + $1.keyframes.count }
        let cameraKeys = composition.composition.cameraClips.reduce(0) { $0 + $1.keyframes.count }
        let total = layerKeys + cameraKeys
        updateProbe(
            id: "timeline.keyframes",
            category: "时间线",
            title: "关键帧 / 曲线",
            state: total > 0 ? .passed : .idle,
            summary: total > 0 ? "关键帧数据正在生效" : "尚未创建关键帧",
            detail: "图层关键帧 \(layerKeys)｜摄像机关键帧 \(cameraKeys)｜已选 \(composition.selectedKeyframeCount)"
        )
    }

    private func updateExpressionProbe(composition: CompositionModel) {
        let layerExpressions = composition.composition.layers.reduce(0) { total, layer in
            total + layer.expressions.values.filter(\.isActive).count
        }
        let cameraExpressions = composition.composition.cameraClips.reduce(0) { total, clip in
            total + clip.expressions.values.filter(\.isActive).count
        }
        let total = layerExpressions + cameraExpressions
        updateProbe(
            id: "timeline.expressions",
            category: "时间线",
            title: "表达式系统",
            state: total > 0 ? .passed : .idle,
            summary: total > 0 ? "表达式已启用并会参与求值" : "尚未启用表达式",
            detail: "图层表达式 \(layerExpressions)｜摄像机表达式 \(cameraExpressions)"
        )
    }

    private func updateBlendProbe(composition: CompositionModel) {
        let blended = composition.composition.layers.filter { $0.blendMode != .normal }
        let mattes = composition.composition.layers.filter { $0.blendMode == .alphaTrackMatte }
        updateProbe(
            id: "composition.blend",
            category: "合成",
            title: "混合模式 / 遮罩",
            state: blended.isEmpty ? .idle : .passed,
            summary: blended.isEmpty ? "当前没有启用混合或遮罩图层" : "混合/遮罩图层正在参与合成",
            detail: "非正常混合 \(blended.count)｜Alpha 轨道遮罩 \(mattes.count)"
        )
    }

    private func updateCacheProbe(composition: CompositionModel) {
        let videos = composition.videoAssets
        guard !videos.isEmpty else {
            updateProbe(
                id: "cache.policy",
                category: "缓存",
                title: "缓存策略",
                state: .idle,
                summary: "尚无视频素材缓存可检查"
            )
            return
        }

        if composition.isBuildingCachePolicyCaches {
            updateProbe(
                id: "cache.policy",
                category: "缓存",
                title: "缓存策略",
                state: .passed,
                summary: "缓存策略中心正在后台构建缓存",
                detail: "素材 \(videos.count) 个"
            )
            return
        }

        let needs = composition.cachePolicyNeedsWorkCount
        updateProbe(
            id: "cache.policy",
            category: "缓存",
            title: "缓存策略",
            state: needs == 0 ? .passed : .warning,
            summary: needs == 0 ? "代理/高精度缓存状态正常" : "\(needs) 个素材缓存需要处理",
            detail: "缓存总量 \(composition.cachePolicyTotalSizeText)"
        )
    }

    private func updateExportProbe(app: AppModel, composition: CompositionModel, exportRuntime: ExportRuntimeState) {
        if exportRuntime.isExporting || composition.isCompositionExporting {
            updateProbe(
                id: "export.active",
                category: "导出",
                title: "导出系统",
                state: .passed,
                summary: exportRuntime.isExporting ? exportRuntime.title : "合成导出",
                detail: exportRuntime.latestStatus
            )
            return
        }

        let exportRelatedStatuses = [app.status, composition.status, exportRuntime.latestStatus]
            .filter { $0.contains("导出") || $0.contains("渲染") || $0.contains("队列") }
            .joined(separator: " ")
        if containsFailure(exportRelatedStatuses) {
            updateProbe(
                id: "export.active",
                category: "导出",
                title: "导出系统",
                state: .failed,
                summary: "最近状态中出现失败/错误",
                detail: trimStatus(exportRelatedStatuses)
            )
        } else {
            updateProbe(
                id: "export.active",
                category: "导出",
                title: "导出系统",
                state: .idle,
                summary: "当前没有导出任务",
                detail: "开始 2D、3D、参考面或合成导出后会变为生效"
            )
        }
    }

    private func updateRenderQueueProbe(composition: CompositionModel) {
        let jobs = composition.compositionRenderQueue
        guard !jobs.isEmpty else {
            updateProbe(
                id: "export.queue",
                category: "导出",
                title: "渲染队列",
                state: .idle,
                summary: "渲染队列为空"
            )
            return
        }

        let failed = jobs.filter { $0.status == .failed }.count
        let running = jobs.filter { $0.status == .running }.count
        updateProbe(
            id: "export.queue",
            category: "导出",
            title: "渲染队列",
            state: failed > 0 ? .failed : .passed,
            summary: failed > 0 ? "渲染队列存在失败任务" : (running > 0 ? "渲染队列正在运行" : "渲染队列状态正常"),
            detail: composition.compositionRenderQueueSummaryText
        )
    }

    private func updateDistributedProbe(distributed: DistributedExportSettings) {
        guard distributed.isEnabled else {
            updateProbe(
                id: "distributed.workers",
                category: "分布式",
                title: "Worker / 分布式",
                state: .idle,
                summary: "分布式导出未启用"
            )
            return
        }

        let online = distributed.workers.filter(\.isOnline).count
        let preparing = distributed.workers.filter(\.isRawCachePreparing).count
        let ready = distributed.workers.filter(\.isRawCacheReady).count
        updateProbe(
            id: "distributed.workers",
            category: "分布式",
            title: "Worker / 分布式",
            state: online > 0 ? .passed : .warning,
            summary: online > 0 ? "\(online) 个 Worker 在线" : "分布式已启用但没有在线 Worker",
            detail: "总 Worker \(distributed.workers.count)｜raw cache 就绪 \(ready)｜准备中 \(preparing)｜总进度 \(Int(distributed.totalDistributedProgress * 100))%"
        )
    }

    private func updatePerformanceProbe(composition: CompositionModel) {
        let snapshot = composition.performanceSnapshot
        let hasActivity = snapshot.previewFPS > 0 || snapshot.activeLayerCount > 0 || snapshot.textureHitCount + snapshot.textureMissCount > 0
        updateProbe(
            id: "diagnostics.performance",
            category: "诊断",
            title: "性能 / 诊断",
            state: hasActivity ? .passed : .idle,
            summary: hasActivity ? "性能快照正在更新" : "尚未收到有效性能快照",
            detail: String(
                format: "FPS %.1f｜图层 %d｜纹理命中 %.0f%%｜raw 命中 %.0f%%｜%@",
                snapshot.previewFPS,
                snapshot.activeLayerCount,
                snapshot.textureHitRate * 100,
                snapshot.rawCacheHitRate * 100,
                snapshot.memoryPressureText
            )
        )
    }

    private func containsFailure(_ text: String) -> Bool {
        ["失败", "错误", "异常", "崩溃", "不存在", "源文件丢失"].contains { text.contains($0) }
    }

    private func containsCompletion(_ text: String) -> Bool {
        ["完成", "已保存", "已打开", "已导入", "已加入", "已清理"].contains { text.contains($0) }
    }

    private func containsReady(_ text: String) -> Bool {
        ["就绪"].contains { text.contains($0) }
    }

    private func trimStatus(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        guard normalized.count > 220 else { return normalized }
        return String(normalized.prefix(220)) + "…"
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func makeSnapshotDocument() -> RuntimeAuditSnapshotDocument {
        RuntimeAuditSnapshotDocument(
            schemaVersion: 1,
            toolVersion: Self.toolVersion,
            generatedAt: Date(),
            lastSampleAt: lastSampleDate,
            applicationName: ProcessInfo.processInfo.processName,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.chronovolume.ChronoVolume",
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            stateSummary: stateSummaryText,
            worstState: worstState,
            probes: probes,
            events: events
        )
    }

    private func publishExternalSnapshot() {
        externalBridge.publish(makeSnapshotDocument())
    }
}

private final class RuntimeAuditExternalBridge {
    private let fileManager = FileManager.default

    func publish(_ document: RuntimeAuditSnapshotDocument) {
        do {
            let directory = try auditDirectory()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(document)
            let latestURL = directory.appendingPathComponent("latest.json")
            let processURL = directory.appendingPathComponent("process-\(document.processIdentifier).json")
            try data.write(to: processURL, options: .atomic)
            try data.write(to: latestURL, options: .atomic)
        } catch {
            // External auditing is diagnostic only; never interrupt the editing session.
        }
    }

    private func auditDirectory() throws -> URL {
        if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return support
                .appendingPathComponent("ChronoVolume", isDirectory: true)
                .appendingPathComponent("RuntimeAudit", isDirectory: true)
        }

        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ChronoVolume", isDirectory: true)
            .appendingPathComponent("RuntimeAudit", isDirectory: true)
    }
}

struct RuntimeAuditPanel: View {
    @ObservedObject var model: RuntimeAuditModel

    private var groupedProbes: [(String, [RuntimeAuditProbe])] {
        let grouped = Dictionary(grouping: model.sortedProbes, by: \.category)
        return grouped.keys.sorted().map { key in
            (key, grouped[key] ?? [])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HSplitView {
                probeList
                    .frame(minWidth: 560, idealWidth: 720)

                eventList
                    .frame(minWidth: 360, idealWidth: 440)
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("动态审查")
                    .font(.title3.bold())
                Text(model.stateSummaryText)
                    .foregroundStyle(model.worstState.severity.color)
                    .font(.footnote)
                Text(RuntimeAuditModel.toolVersion)
                    .foregroundStyle(.secondary)
                    .font(.caption2.monospaced())
                Text("PID \(ProcessInfo.processInfo.processIdentifier)")
                    .foregroundStyle(.secondary)
                    .font(.caption2.monospaced())
            }

            Spacer()

            Toggle("启用", isOn: $model.isEnabled)
                .toggleStyle(.switch)

            Button {
                model.refreshSnapshot()
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)

            Button("清空事件") {
                model.clearEvents()
            }

            Button("导出 JSON") {
                model.exportSnapshotInteractively()
            }
        }
        .padding(14)
    }

    private var probeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groupedProbes, id: \.0) { category, probes in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category)
                            .font(.headline)
                            .padding(.horizontal, 2)

                        ForEach(probes) { probe in
                            RuntimeAuditProbeRow(probe: probe)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("事件")
                    .font(.headline)
                Spacer()
                Text("\(model.events.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            List(model.recentEvents) { event in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(event.severity.title)
                            .foregroundStyle(event.severity.color)
                            .font(.caption.bold())
                        Text(event.category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.timeText(event.date))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(event.title)
                        .font(.subheadline.bold())
                    Text(event.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

final class RuntimeAuditWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    @MainActor
    func show(model: RuntimeAuditModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = RuntimeAuditPanel(model: model)
        let hostingView = NSHostingView(rootView: panel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ChronoVolume 动态审查"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct RuntimeAuditProbeRow: View {
    let probe: RuntimeAuditProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(probe.state.title)
                    .font(.caption.bold())
                    .foregroundStyle(probe.state.severity.color)
                    .frame(width: 52, alignment: .leading)

                Text(probe.title)
                    .font(.subheadline.bold())

                Spacer()

                Text(Self.timeText(probe.updatedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(probe.summary)
                .font(.callout)

            if !probe.detail.isEmpty {
                Text(probe.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(probe.state.severity.color.opacity(0.45), lineWidth: 1)
        )
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
