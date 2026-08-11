import Foundation
import SwiftUI
import AppKit
import MetalKit
import CoreGraphics
import simd
import AVFoundation
import QuartzCore

private let videoModifierInteractivePreviewMaxBytes = 128 * 1024 * 1024
private let videoModifierSurfaceSDFPreviewMaxBytes = 32 * 1024 * 1024
private let videoModifierAutoFullRebuildMaxBytes = 512 * 1024 * 1024

private struct CachedVideoLoad {
    let package: LoadedVideoPackage
    let cpuVolume: CPUVolume
    let modifierPreviewVolume: LoadedVolume
    let bestVisibleIndex: Int
    let previewAlphaBounds: VolumeVoxelBounds?
}

private struct CachedMeshLoad: Sendable {
    let volume: LoadedVolume
    let mesh: LoadedMesh?
    let cpuVolume: CPUVolume
    let bestVisibleIndex: Int
    let previewAlphaBounds: VolumeVoxelBounds?
    let meshSlicePreviewCache: MeshSliceRasterizer.Cache?
}

struct ModifiedVideoVolumeExportSnapshot: Sendable {
    let generation: Int
    let currentLoadedVolume: LoadedVolume
    let baseLoadedVolume: LoadedVolume
    let modifiers: [MeshModifierItem]
}

@MainActor
final class AppModel: ObservableObject {
    private static let meshModifierPreviewDelayNanoseconds: UInt64 = 120_000_000
    private static let meshModifierHighPrecisionDelayNanoseconds: UInt64 = 1_800_000_000

    @Published var fileName: String = "未加载"
    @Published var volumeInfo: String = "-"
    @Published var previewVolumeInfo: String = "-"
    @Published var actualVolumeInfo: String = "-"
    @Published var alphaInfo: String = "-"
    @Published var status: String = "就绪"

    @Published var useAlpha: Bool = true
    @Published var steps: Int = 192
    @Published var density: Double = 1.1
    @Published var brightness: Double = 1.6
    @Published var useVoxelBlockRendering: Bool = false
    @Published var smoothVolumeEdges: Bool = false
    @Published var volumeBackgroundMode: VolumeBackgroundMode = .color
    @Published var volumeBackgroundColor = VolumeBackgroundColor()
    @Published var volumeTransform = VolumeTransformState()
    @Published var meshModifierState = MeshModifierState()
    @Published var meshModifierStack: [MeshModifierItem] = []
    @Published var selectedMeshModifierID: UUID?
    @Published var isVideoVolumeModifierActive: Bool = false
    @Published var modifierLoadingMessage: String?
    @Published var cameraRig = CameraRigState()
    @Published var cameraTimelineFrame: Int = 0
    @Published var isCameraTimelinePlaying: Bool = false
    @Published var cameraTimelineFPS: Double = 30
    @Published var cameraKeyframes: [CameraKeyframe] = []
    @Published var isCameraPreviewFloating: Bool = false
    @Published var cameraExportPreserveAlpha: Bool = false
    @Published var cameraFunctionDriver = CameraFunctionDriverState()
    @Published var cameraExportSizeMode: CameraExportSizeMode = .preview
    @Published var cameraExportCustomWidth: Int = 1920
    @Published var cameraExportCustomHeight: Int = 1080
    @Published var cameraExportFPSMode: CameraExportFPSMode = .source
    @Published var cameraExportCustomFPS: Double = 30
    @Published var cameraExportBackgroundMode: CameraExportBackgroundMode = .white
    @Published var cameraExportBackgroundColor = VolumeBackgroundColor(red: 1, green: 1, blue: 1)

    @Published var sliceMode: SliceMode = .axis
    @Published var playbackAxis: PlaybackAxis = .t
    @Published var currentIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var playbackRate: Double = 1.0
    @Published var showCheckerboard: Bool = true
    @Published var currentSliceCGImage: CGImage?
    @Published var isSliceRendering: Bool = false
    @Published var isAxisCacheBuilding: Bool = false

    // 兼容现有 UI / 导出逻辑
    @Published var useFastPreviewWhilePlaying: Bool = true
    @Published var reduceResolutionWhilePlaying: Bool = true

    @Published var referencePlane = ReferencePlaneState()

    @Published var showCornerAxesOverlay: Bool = true
    @Published var showOriginAxesOverlay: Bool = true
    @Published var showPlaneOverlay: Bool = true
    @Published var showCameraOverlay: Bool = true

    @Published var cameraYaw: Float = 0
    @Published var cameraPitch: Float = 0
    @Published var cameraRoll: Float = 0
    @Published var cameraDistance: Float = 2.2
    @Published var cameraPositionX: Float = 0
    @Published var cameraPositionY: Float = 0
    @Published var cameraPositionZ: Float = 0
    @Published var volumeScaleForOverlay: SIMD3<Float> = SIMD3<Float>(1, 1, 1)

    @Published var sourceFPS: Double = 0.0
    @Published var sourceDurationSeconds: Double = 0.0
    @Published var sourceFrameCount: Int = 0
    @Published var sourceBitDepth: Int = 8
    @Published var sourceColorProfile: VideoColorProfile = .rec709
    @Published var sourceAlphaBitDepth: Int = 8
    @Published var previewAlphaBitDepth: Int = 8
    @Published var videoSourcePair: VideoSourcePair?
    @Published var colorSourceMetadata: VideoSourceMetadata?
    @Published var alphaSourceMetadata: VideoSourceMetadata?
    @Published var alphaSyncStatus: String = "单源"
    @Published var externalAlphaPreviewMode: ExternalAlphaPreviewMode = .checkerboardTransparency
    @Published var fullTemporalDepthCount: Int = 0
    @Published var previewDepthCount: Int = 0
    @Published var bestVisibleTIndex: Int = 0

    @Published var player: AVPlayer?

    var renderer: VolumeRenderer?
    var cameraPreviewRenderer: VolumeRenderer?
    var planeSliceRenderer: PlaneSliceRenderer?
    var axisSliceRenderer: AxisSliceRenderer?
    var sliceRenderer: SliceRenderer?

    // 保持为 stored property，供导出扩展通过 Mirror 读取
    private var fullCPUVolume: CPUVolume?
    private var fullLoadedVolume: LoadedVolume?
    private(set) var highPrecisionAlphaVolume: HighPrecisionAlphaVolume?
    var highPrecisionPairedCPUVolume: CPUVolume?
    private var externalAlphaMaskPreviewVolume: LoadedVolume?
    private var pendingPreviewVolume: LoadedVolume?
    private var originalMeshSurface: LoadedMesh?
    private var fullMeshSurface: LoadedMesh?
    private var meshSlicePreviewCache: MeshSliceRasterizer.Cache?
    private var originalFullCPUVolumeForModifiers: CPUVolume?
    private var originalFullLoadedVolumeForModifiers: LoadedVolume?
    private var originalPreviewLoadedVolumeForModifiers: LoadedVolume?
    private var originalModifierPreviewLoadedVolumeForModifiers: LoadedVolume?
    private var previewAlphaBoundsForOverlay: VolumeVoxelBounds?

    private var playbackTimer: Timer?
    private var displayLinkDriver: CVDisplayLinkDriver?
    private var playbackStartTime: CFTimeInterval = 0
    private var playbackStartIndex: Int = 0
    private var lastPresentedFrameIndex: Int = -1

    private var playerTimeObserver: Any?
    private var playerTimeObserverOwner: AVPlayer?
    private var playerEndObserver: NSObjectProtocol?

    private var loadTask: Task<Void, Never>?
    private var loadGenerationID: Int = 0
    private var meshModifierCacheTask: Task<Void, Never>?
    private var meshModifierCacheGeneration: Int = 0

    var hasMeshSlicePreview: Bool {
        fullMeshSurface != nil && meshSlicePreviewCache != nil
    }

    var hasEditableMesh: Bool {
        originalMeshSurface != nil
    }

    var hasModifierTarget: Bool {
        originalMeshSurface != nil || originalFullLoadedVolumeForModifiers != nil
    }

    var isVideoVolumeModifierTarget: Bool {
        originalMeshSurface == nil && originalFullLoadedVolumeForModifiers != nil
    }

    var usesGeneratedTimeAxisPreview: Bool {
        hasMeshSlicePreview || isVideoVolumeModifierActive || videoSourcePair?.alphaSourceMode == .external
    }

    var selectedMeshModifierState: MeshModifierState {
        guard let index = selectedMeshModifierIndex else { return MeshModifierState() }
        return meshModifierStack[index].state
    }

    private var selectedMeshModifierIndex: Int? {
        if let selectedMeshModifierID,
           let index = meshModifierStack.firstIndex(where: { $0.id == selectedMeshModifierID }) {
            return index
        }
        return meshModifierStack.indices.first
    }
    private var pendingProjectStateAfterLoad: ChronoVolumeProjectDocument.AppProjectState?
    private var videoLoadCache: [VideoSourcePair: CachedVideoLoad] = [:]
    private var meshLoadCache: [URL: CachedMeshLoad] = [:]
    var lastDistributedStatusBarUpdate: Date = .distantPast

    private var pendingPlaneApplyWorkItem: DispatchWorkItem?
    private var cameraTimelineTimer: Timer?
    private var cameraPreviewWindow: NSWindow?
    private var cameraPreviewWindowCloseObserver: NSObjectProtocol?

    deinit {
        loadTask?.cancel()
        meshModifierCacheTask?.cancel()
        playbackTimer?.invalidate()
        cameraTimelineTimer?.invalidate()
        displayLinkDriver?.callback = nil
        displayLinkDriver?.stop()

        if let player = playerTimeObserverOwner {
            player.pause()
        }

        if let player = playerTimeObserverOwner, let observer = playerTimeObserver {
            player.removeTimeObserver(observer)
        }

        if let endObserver = playerEndObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        if let cameraPreviewWindowCloseObserver {
            NotificationCenter.default.removeObserver(cameraPreviewWindowCloseObserver)
        }
    }

    // MARK: - Renderer attach

    func attachRenderer(_ renderer: VolumeRenderer) {
        if self.renderer === renderer {
            configure(renderer: renderer)
            renderer.requestRedraw()
            return
        }

        self.renderer = renderer
        configure(renderer: renderer)

        if let pendingPreviewVolume {
            renderer.setVolume(pendingPreviewVolume)
            renderer.setMeshSurface(fullMeshSurface)
            if let fullCPUVolume {
                renderer.setDisplayScale(fullCPUVolume.normalizedVolumeScale())
            }
            if fullCPUVolume != nil {
                status = "就绪"
            }
        }
    }

    func attachPlaneSliceRenderer(_ renderer: PlaneSliceRenderer) {
        if self.planeSliceRenderer === renderer {
            if let fullLoadedVolume { renderer.setVolume(fullLoadedVolume) }
            renderer.requestRedraw()
            return
        }
        self.planeSliceRenderer = renderer
        if let fullLoadedVolume { renderer.setVolume(fullLoadedVolume) }
    }

    func attachAxisSliceRenderer(_ renderer: AxisSliceRenderer) {
        if self.axisSliceRenderer === renderer {
            if let fullLoadedVolume { renderer.setVolume(fullLoadedVolume) }
            renderer.requestRedraw()
            return
        }
        self.axisSliceRenderer = renderer
        if let fullLoadedVolume { renderer.setVolume(fullLoadedVolume) }
    }

    func attachSliceRenderer(_ renderer: SliceRenderer) {
        if self.sliceRenderer === renderer {
            if let fullLoadedVolume { renderer.setVolume(fullLoadedVolume) }
            updateSliceRendererForCurrentState()
            return
        }
        self.sliceRenderer = renderer
        if let fullLoadedVolume { renderer.setVolume(fullLoadedVolume) }
        updateSliceRendererForCurrentState()
    }

    private func configure(renderer: VolumeRenderer) {
        renderer.useAlpha = useAlpha
        renderer.steps = steps
        renderer.density = Float(density)
        renderer.brightness = Float(brightness)
        renderer.useVoxelBlockRendering = useVoxelBlockRendering
        renderer.smoothEdges = smoothVolumeEdges
        renderer.setVolumeTransform(volumeTransform)
        updateReferencePlaneOverlay(renderer: renderer)
        renderer.setBackgroundColor(
            red: volumeBackgroundColor.red,
            green: volumeBackgroundColor.green,
            blue: volumeBackgroundColor.blue,
            alpha: volumeBackgroundMode == .checkerboard ? 0 : 1
        )

        renderer.onCameraChanged = { [weak self] yaw, pitch, roll, distance, positionX, positionY, positionZ in
            DispatchQueue.main.async {
                self?.cameraYaw = yaw
                self?.cameraPitch = pitch
                self?.cameraRoll = roll
                self?.cameraDistance = distance
                self?.cameraPositionX = positionX
                self?.cameraPositionY = positionY
                self?.cameraPositionZ = positionZ
            }
        }

        renderer.onReferencePlaneDelta = { [weak self] dyaw, dpitch, droll in
            DispatchQueue.main.async {
                guard let self else { return }
                if let dyaw { self.referencePlane.yawDegrees += dyaw }
                if let dpitch { self.referencePlane.pitchDegrees += dpitch }
                if let droll { self.referencePlane.rollDegrees += droll }
                self.applyReferencePlane()
            }
        }
    }

    func attachCameraPreviewRenderer(_ renderer: VolumeRenderer) {
        if self.cameraPreviewRenderer === renderer {
            configureCameraPreview(renderer: renderer)
            renderer.requestRedraw()
            return
        }

        self.cameraPreviewRenderer = renderer
        configureCameraPreview(renderer: renderer)

        if let pendingPreviewVolume {
            renderer.setVolume(pendingPreviewVolume)
            renderer.setMeshSurface(fullMeshSurface)
            if let fullCPUVolume {
                renderer.setDisplayScale(fullCPUVolume.normalizedVolumeScale())
            }
        }
    }

    private func configureCameraPreview(renderer: VolumeRenderer) {
        renderer.useAlpha = useAlpha
        renderer.steps = steps
        renderer.density = Float(density)
        renderer.brightness = Float(brightness)
        renderer.useVoxelBlockRendering = useVoxelBlockRendering
        renderer.smoothEdges = smoothVolumeEdges
        renderer.focalLength = cameraRig.focalLength
        renderer.setVolumeTransform(volumeTransform)
        renderer.setCamera(
            yaw: cameraRig.yaw,
            pitch: cameraRig.pitch,
            roll: cameraRig.roll,
            distance: 0,
            position: SIMD3<Float>(cameraRig.positionX, cameraRig.positionY, cameraRig.positionZ),
            focusLockEnabled: cameraRig.focusLockEnabled,
            focusTarget: SIMD3<Float>(cameraRig.focusTargetX, cameraRig.focusTargetY, cameraRig.focusTargetZ)
        )
        renderer.setBackgroundColor(
            red: volumeBackgroundColor.red,
            green: volumeBackgroundColor.green,
            blue: volumeBackgroundColor.blue,
            alpha: volumeBackgroundMode == .checkerboard ? 0 : 1
        )
    }

    func updateCameraPreviewRenderer() {
        guard let cameraPreviewRenderer else { return }
        configureCameraPreview(renderer: cameraPreviewRenderer)
        cameraPreviewRenderer.requestRedraw()
    }

    func updateCameraRigAndPreview(syncFocusOrientation: Bool = true) {
        if syncFocusOrientation {
            syncCameraOrientationFromFocusLock()
        }
        updateCameraPreviewRenderer()
    }

    func syncCameraOrientationFromFocusLock() {
        guard cameraRig.focusLockEnabled else { return }
        guard let orientation = Self.cameraYawPitchForFocus(
            position: SIMD3<Float>(cameraRig.positionX, cameraRig.positionY, cameraRig.positionZ),
            target: SIMD3<Float>(cameraRig.focusTargetX, cameraRig.focusTargetY, cameraRig.focusTargetZ)
        ) else { return }

        cameraRig.yaw = orientation.yaw
        cameraRig.pitch = orientation.pitch
    }

    static func cameraYawPitchForFocus(position: SIMD3<Float>, target: SIMD3<Float>) -> (yaw: Float, pitch: Float)? {
        let toTarget = target - position
        guard simd_length_squared(toTarget) > 0.000001 else { return nil }

        let forward = simd_normalize(toTarget)
        let pitch = asin(max(-1, min(1, forward.y)))
        let yaw = atan2(-forward.x, -forward.z)
        return (yaw, pitch)
    }

    func updateVolumeBackground() {
        renderer?.setBackgroundColor(
            red: volumeBackgroundColor.red,
            green: volumeBackgroundColor.green,
            blue: volumeBackgroundColor.blue,
            alpha: volumeBackgroundMode == .checkerboard ? 0 : 1
        )
        cameraPreviewRenderer?.setBackgroundColor(
            red: volumeBackgroundColor.red,
            green: volumeBackgroundColor.green,
            blue: volumeBackgroundColor.blue,
            alpha: volumeBackgroundMode == .checkerboard ? 0 : 1
        )
    }

    func updateVolumeTransformRenderers() {
        renderer?.setVolumeTransform(volumeTransform)
        cameraPreviewRenderer?.setVolumeTransform(volumeTransform)
        if let renderer {
            updateReferencePlaneOverlay(renderer: renderer)
        }
        renderer?.requestRedraw()
        cameraPreviewRenderer?.requestRedraw()
    }

    func resetVolumeTransform() {
        volumeTransform = VolumeTransformState()
        updateVolumeTransformRenderers()
    }

    private func cancelMeshModifierCacheRebuild() {
        meshModifierCacheTask?.cancel()
        meshModifierCacheTask = nil
        meshModifierCacheGeneration += 1
        modifierLoadingMessage = nil
    }

    private func effectiveMeshModifierStack() -> [MeshModifierItem] {
        if meshModifierStack.isEmpty {
            guard !meshModifierState.isIdentity else { return [] }
            return [MeshModifierItem(name: "变换 1", state: meshModifierState)]
        }
        return meshModifierStack
    }

    @discardableResult
    private func ensureSelectedMeshModifier() -> Int? {
        guard hasModifierTarget else { return nil }
        if meshModifierStack.isEmpty {
            let modifier = MeshModifierItem(name: "变换 1")
            meshModifierStack = [modifier]
            selectedMeshModifierID = modifier.id
            meshModifierState = modifier.state
            return 0
        }
        if let index = selectedMeshModifierIndex {
            selectedMeshModifierID = meshModifierStack[index].id
            meshModifierState = meshModifierStack[index].state
            return index
        }
        return nil
    }

    func updateMeshModifierResult() {
        if let originalMeshSurface, let fullCPUVolume {
            let modifiers = effectiveMeshModifierStack()
            meshSlicePreviewCache = nil
            let hasActiveModifier = modifiers.contains { $0.isEnabled && !$0.state.isIdentity }
            scheduleMeshModifierCacheRebuild(
                mesh: originalMeshSurface,
                modifiers: modifiers,
                volume: fullCPUVolume
            )
            status = hasActiveModifier ? "模型修改器栈已更新，正在后台应用模型变换" : "模型修改器栈为空，正在恢复原始切片缓存"
            return
        }

        if let baseFullCPU = originalFullCPUVolumeForModifiers,
           let baseFullLoaded = originalFullLoadedVolumeForModifiers,
           let basePreviewLoaded = originalPreviewLoadedVolumeForModifiers,
           let baseModifierPreviewLoaded = originalModifierPreviewLoadedVolumeForModifiers {
            let modifiers = effectiveMeshModifierStack()
            let hasActiveModifier = VolumeModifierRasterizer.hasActiveModifiers(modifiers)
            if hasActiveModifier {
                isVideoVolumeModifierActive = true
                scheduleVideoVolumeModifierRebuild(
                    modifiers: modifiers,
                    baseFullCPU: baseFullCPU,
                    baseFullLoaded: baseFullLoaded,
                    basePreviewLoaded: basePreviewLoaded,
                    baseModifierPreviewLoaded: baseModifierPreviewLoaded
                )
            } else {
                isVideoVolumeModifierActive = false
                applyVideoModifierVolumes(
                    fullCPU: baseFullCPU,
                    fullLoaded: baseFullLoaded,
                    previewLoaded: basePreviewLoaded,
                    statusText: "体素修改器栈为空，已恢复原始视频体"
                )
            }
            return
        }

        cancelMeshModifierCacheRebuild()
        isVideoVolumeModifierActive = false
        fullMeshSurface = nil
        meshSlicePreviewCache = nil
        renderer?.setMeshSurface(nil)
        cameraPreviewRenderer?.setMeshSurface(nil)
        rebuildCurrentSlice()
    }

    private func scheduleMeshModifierCacheRebuild(
        mesh: LoadedMesh,
        modifiers: [MeshModifierItem],
        volume: CPUVolume
    ) {
        cancelMeshModifierCacheRebuild()
        let generation = meshModifierCacheGeneration
        modifierLoadingMessage = "正在应用模型修改器…"

        meshModifierCacheTask = Task.detached(priority: .userInitiated) { [mesh, modifiers, volume, generation] in
            try? await Task.sleep(nanoseconds: AppModel.meshModifierPreviewDelayNanoseconds)
            guard !Task.isCancelled else { return }

            let evaluatedMesh = mesh.applying(modifiers)

            await MainActor.run { [weak self] in
                guard let self,
                      self.meshModifierCacheGeneration == generation,
                      !Task.isCancelled else { return }
                self.fullMeshSurface = evaluatedMesh
                self.meshSlicePreviewCache = nil
                self.renderer?.setMeshSurface(evaluatedMesh)
                self.cameraPreviewRenderer?.setMeshSurface(evaluatedMesh)
                self.renderer?.requestRedraw()
                self.cameraPreviewRenderer?.requestRedraw()
                self.rebuildCurrentSlice()
                self.status = "模型变换已更新，正在后台重建切片缓存"
                self.modifierLoadingMessage = "正在重建模型切片缓存…"
            }

            guard !Task.isCancelled else { return }
            let cache = MeshSliceRasterizer.makeCache(mesh: evaluatedMesh, volume: volume)

            await MainActor.run { [weak self] in
                guard let self,
                      self.meshModifierCacheGeneration == generation,
                      !Task.isCancelled else { return }
                self.meshModifierCacheTask = nil
                self.modifierLoadingMessage = nil
                self.meshSlicePreviewCache = cache
                self.rebuildCurrentSlice()
                self.status = cache == nil ? "模型修改器已更新，但切片缓存为空" : "模型修改器栈已更新，切片缓存已就绪"
            }
        }
    }

    private func scheduleVideoVolumeModifierRebuild(
        modifiers: [MeshModifierItem],
        baseFullCPU: CPUVolume,
        baseFullLoaded: LoadedVolume,
        basePreviewLoaded: LoadedVolume,
        baseModifierPreviewLoaded: LoadedVolume
    ) {
        cancelMeshModifierCacheRebuild()
        let generation = meshModifierCacheGeneration
        fullCPUVolume = baseFullCPU
        fullLoadedVolume = baseFullLoaded
        pendingPreviewVolume = basePreviewLoaded
        let shouldAutoBuildFull = baseFullLoaded.rgba.count <= videoModifierAutoFullRebuildMaxBytes
        modifierLoadingMessage = "正在计算体素修改器低延迟预览…"
        volumeScaleForOverlay = baseFullCPU.normalizedVolumeScale()
        volumeInfo = "\(baseFullCPU.width) × \(baseFullCPU.height) × \(baseFullCPU.depth)"
        currentIndex = min(currentIndex, max(0, totalFrameCountForCurrentMode() - 1))
        status = "体素修改器栈已更新，正在准备低延迟预览"
        if sliceMode == .axis && playbackAxis == .t {
            player?.pause()
            if isPlaying {
                playbackStartTime = CACurrentMediaTime()
                playbackStartIndex = currentIndex
                lastPresentedFrameIndex = -1
                ensureDisplayLinkDriver()
                displayLinkDriver?.start()
            }
        }

        let shouldUseSurfaceSDFPreview = VolumeModifierRasterizer.usesSurfaceSDFMode(modifiers)

        meshModifierCacheTask = Task.detached(priority: .userInitiated) { [modifiers, baseFullLoaded, basePreviewLoaded, baseModifierPreviewLoaded, shouldAutoBuildFull, shouldUseSurfaceSDFPreview, generation] in
            try? await Task.sleep(nanoseconds: AppModel.meshModifierPreviewDelayNanoseconds)
            guard !Task.isCancelled else { return }

            let previewSource = shouldUseSurfaceSDFPreview
                ? VolumeModifierRasterizer.downsampledPreviewVolumeForModifierEditing(
                    from: basePreviewLoaded,
                    maxBytes: videoModifierSurfaceSDFPreviewMaxBytes
                )
                : baseModifierPreviewLoaded
            let modifiedPreview = VolumeModifierRasterizer.applyingForInteractivePreview(modifiers, to: previewSource)
            await MainActor.run { [weak self] in
                guard let self,
                      self.meshModifierCacheGeneration == generation,
                      !Task.isCancelled else { return }
                self.pendingPreviewVolume = modifiedPreview
                self.previewAlphaBoundsForOverlay = Self.alphaBoundsForOverlay(volume: basePreviewLoaded)
                self.renderer?.setVolume(modifiedPreview)
                self.cameraPreviewRenderer?.setVolume(modifiedPreview)
                self.updateReferencePlaneOverlay()
                self.rebuildCurrentSlice()
                self.renderer?.requestRedraw()
                self.cameraPreviewRenderer?.requestRedraw()
                self.status = shouldAutoBuildFull
                    ? "体素修改器低延迟预览已更新，停止调整后会重建完整 GPU 体"
                    : "体素修改器低延迟预览已更新，完整修改体会在导出时按需生成"
                self.modifierLoadingMessage = shouldAutoBuildFull
                    ? "正在后台重建完整 GPU 体…"
                    : nil
            }

            guard shouldAutoBuildFull else {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.meshModifierCacheGeneration == generation,
                          !Task.isCancelled else { return }
                    self.meshModifierCacheTask = nil
                    self.modifierLoadingMessage = nil
                    self.status = "体素修改器低延迟预览已更新，完整修改体会在导出时按需生成"
                }
                return
            }

            try? await Task.sleep(nanoseconds: AppModel.meshModifierHighPrecisionDelayNanoseconds)
            guard !Task.isCancelled else { return }

            let modifiedFullGPU = VolumeModifierRasterizer.applyingForInteractivePreview(modifiers, to: baseFullLoaded)
            await MainActor.run { [weak self] in
                guard let self,
                      self.meshModifierCacheGeneration == generation,
                      !Task.isCancelled else { return }
                self.meshModifierCacheTask = nil
                self.modifierLoadingMessage = nil
                self.fullLoadedVolume = modifiedFullGPU
                self.planeSliceRenderer?.setVolume(modifiedFullGPU)
                self.axisSliceRenderer?.setVolume(modifiedFullGPU)
                self.sliceRenderer?.setVolume(modifiedFullGPU)
                self.planeSliceRenderer?.requestRedraw()
                self.axisSliceRenderer?.requestRedraw()
                self.sliceRenderer?.requestRedraw()
                if self.sliceMode == .plane || self.sliceMode == .axis {
                    self.rebuildCurrentSlice()
                }
                self.status = "体素修改器完整 GPU 体已就绪，CPU 兜底将按需生成"
            }
        }
    }

    private func applyVideoModifierVolumes(
        fullCPU: CPUVolume,
        fullLoaded: LoadedVolume,
        previewLoaded: LoadedVolume,
        statusText: String
    ) {
        fullCPUVolume = fullCPU
        fullLoadedVolume = fullLoaded
        pendingPreviewVolume = previewLoaded
        modifierLoadingMessage = nil
        previewAlphaBoundsForOverlay = Self.alphaBoundsForOverlay(volume: previewLoaded)
        volumeScaleForOverlay = fullCPU.normalizedVolumeScale()
        previewVolumeInfo = "\(previewLoaded.width) × \(previewLoaded.height) × \(previewLoaded.depth)"
        volumeInfo = "\(fullCPU.width) × \(fullCPU.height) × \(fullCPU.depth)"
        bestVisibleTIndex = Self.findBestVisibleTIndex(volume: fullCPU)
        currentIndex = min(currentIndex, max(0, totalFrameCountForCurrentMode() - 1))

        renderer?.setVolume(previewLoaded)
        renderer?.setDisplayScale(fullCPU.normalizedVolumeScale())
        cameraPreviewRenderer?.setVolume(previewLoaded)
        cameraPreviewRenderer?.setDisplayScale(fullCPU.normalizedVolumeScale())
        planeSliceRenderer?.setVolume(fullLoaded)
        axisSliceRenderer?.setVolume(fullLoaded)
        sliceRenderer?.setVolume(fullLoaded)

        updateReferencePlaneOverlay()
        rebuildCurrentSlice()
        renderer?.requestRedraw()
        cameraPreviewRenderer?.requestRedraw()
        planeSliceRenderer?.requestRedraw()
        axisSliceRenderer?.requestRedraw()
        sliceRenderer?.requestRedraw()
        status = statusText
        if isPlaying, sliceMode == .axis, playbackAxis == .t {
            startPlayback()
        }
    }

    func modifiedVideoVolumeExportSnapshot() -> ModifiedVideoVolumeExportSnapshot? {
        guard isVideoVolumeModifierActive,
              let currentLoadedVolume = fullLoadedVolume,
              let baseLoadedVolume = originalFullLoadedVolumeForModifiers else {
            return nil
        }

        let modifiers = effectiveMeshModifierStack()
        guard VolumeModifierRasterizer.hasActiveModifiers(modifiers) else {
            return nil
        }

        return ModifiedVideoVolumeExportSnapshot(
            generation: meshModifierCacheGeneration,
            currentLoadedVolume: currentLoadedVolume,
            baseLoadedVolume: baseLoadedVolume,
            modifiers: modifiers
        )
    }

    func modifiedVideoVolumeTextureIsAvailableForExport(_ snapshot: ModifiedVideoVolumeExportSnapshot) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return VolumeModifierRasterizer.cachedModifiedTexture(
            for: snapshot.currentLoadedVolume.textureCacheID,
            device: device
        ) != nil
    }

    func installMaterializedModifiedVideoVolumeForExport(
        _ loadedVolume: LoadedVolume,
        generation: Int
    ) {
        guard isVideoVolumeModifierActive,
              meshModifierCacheGeneration == generation else {
            return
        }

        let cpuVolume = CPUVolume(
            width: loadedVolume.width,
            height: loadedVolume.height,
            depth: loadedVolume.depth,
            rgba: loadedVolume.rgba,
            hasMeaningfulAlpha: loadedVolume.hasMeaningfulAlpha,
            sourceColorProfile: loadedVolume.sourceColorProfile
        )
        fullCPUVolume = cpuVolume
        fullLoadedVolume = loadedVolume
        volumeScaleForOverlay = cpuVolume.normalizedVolumeScale()
        volumeInfo = "\(cpuVolume.width) × \(cpuVolume.height) × \(cpuVolume.depth)"
        bestVisibleTIndex = Self.findBestVisibleTIndex(volume: cpuVolume)
        currentIndex = min(currentIndex, max(0, totalFrameCountForCurrentMode() - 1))

        planeSliceRenderer?.setVolume(loadedVolume)
        axisSliceRenderer?.setVolume(loadedVolume)
        sliceRenderer?.setVolume(loadedVolume)
        planeSliceRenderer?.requestRedraw()
        axisSliceRenderer?.requestRedraw()
        sliceRenderer?.requestRedraw()
    }

    func addMeshTransformModifier() {
        guard hasModifierTarget else { return }
        let modifier = MeshModifierItem(name: "变换 \(meshModifierStack.count + 1)")
        meshModifierStack.append(modifier)
        selectedMeshModifierID = modifier.id
        meshModifierState = modifier.state
        updateMeshModifierResult()
    }

    func selectMeshModifier(id: UUID) {
        guard let index = meshModifierStack.firstIndex(where: { $0.id == id }) else { return }
        selectedMeshModifierID = meshModifierStack[index].id
        meshModifierState = meshModifierStack[index].state
    }

    func setMeshModifierEnabled(id: UUID, isEnabled: Bool) {
        guard let index = meshModifierStack.firstIndex(where: { $0.id == id }) else { return }
        guard meshModifierStack[index].isEnabled != isEnabled else { return }
        meshModifierStack[index].isEnabled = isEnabled
        updateMeshModifierResult()
    }

    func updateSelectedMeshModifierState(_ update: (inout MeshModifierState) -> Void) {
        guard let index = ensureSelectedMeshModifier() else { return }
        let oldState = meshModifierStack[index].state
        update(&meshModifierStack[index].state)
        guard meshModifierStack[index].state != oldState else { return }
        meshModifierState = meshModifierStack[index].state
        updateMeshModifierResult()
    }

    func moveSelectedMeshModifier(up: Bool) {
        guard let index = selectedMeshModifierIndex else { return }
        let target = up ? index - 1 : index + 1
        guard meshModifierStack.indices.contains(target) else { return }
        meshModifierStack.swapAt(index, target)
        selectedMeshModifierID = meshModifierStack[target].id
        updateMeshModifierResult()
    }

    func deleteSelectedMeshModifier() {
        guard let index = selectedMeshModifierIndex else { return }
        meshModifierStack.remove(at: index)
        if meshModifierStack.isEmpty {
            selectedMeshModifierID = nil
            meshModifierState = MeshModifierState()
        } else {
            let next = min(index, meshModifierStack.count - 1)
            selectedMeshModifierID = meshModifierStack[next].id
            meshModifierState = meshModifierStack[next].state
        }
        updateMeshModifierResult()
    }

    func resetSelectedMeshModifier() {
        updateSelectedMeshModifierState { state in
            state = MeshModifierState()
        }
    }

    func resetMeshModifiers() {
        meshModifierStack = []
        selectedMeshModifierID = nil
        meshModifierState = MeshModifierState()
        updateMeshModifierResult()
    }

    func centerMeshModifierPosition() {
        updateSelectedMeshModifierState { state in
            state.positionX = 0
            state.positionY = 0
            state.positionZ = 0
        }
    }

    func captureCameraKeyframe() {
        syncCameraOrientationFromFocusLock()
        let keyframe = CameraKeyframe(frame: cameraTimelineFrame, camera: cameraRig)
        if let existing = cameraKeyframes.firstIndex(where: { $0.frame == cameraTimelineFrame }) {
            cameraKeyframes[existing] = keyframe
        } else {
            cameraKeyframes.append(keyframe)
            cameraKeyframes.sort { $0.frame < $1.frame }
        }
    }

    func applyCameraKeyframe(_ keyframe: CameraKeyframe) {
        cameraTimelineFrame = keyframe.frame
        cameraRig = keyframe.camera
        syncCameraOrientationFromFocusLock()
        updateCameraPreviewRenderer()
    }

    func setCameraTimelineFrame(_ frame: Int, applyAnimation: Bool = true) {
        cameraTimelineFrame = max(0, min(cameraTimelineMaxFrame(), frame))
        if applyAnimation, let interpolated = interpolatedCamera(at: cameraTimelineFrame) {
            cameraRig = interpolated
            syncCameraOrientationFromFocusLock()
            updateCameraPreviewRenderer()
        }
    }

    func cameraTimelineMaxFrame() -> Int {
        max(0, totalFrameCountForCurrentMode() - 1)
    }

    func toggleCameraTimelinePlayback() {
        isCameraTimelinePlaying ? stopCameraTimelinePlayback() : startCameraTimelinePlayback()
    }

    func startCameraTimelinePlayback() {
        stopCameraTimelinePlayback()
        isCameraTimelinePlaying = true
        let interval = 1.0 / max(1, cameraTimelineFPS)
        cameraTimelineTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceCameraTimeline()
            }
        }
        RunLoop.main.add(cameraTimelineTimer!, forMode: .common)
    }

    func stopCameraTimelinePlayback() {
        cameraTimelineTimer?.invalidate()
        cameraTimelineTimer = nil
        isCameraTimelinePlaying = false
    }

    private func advanceCameraTimeline() {
        let maxFrame = cameraTimelineMaxFrame()
        if cameraTimelineFrame >= maxFrame {
            setCameraTimelineFrame(0)
        } else {
            setCameraTimelineFrame(cameraTimelineFrame + 1)
        }
    }

    func interpolatedCamera(at frame: Int) -> CameraRigState? {
        let base = baseInterpolatedCamera(at: frame)
        guard cameraFunctionDriver.isEnabled, cameraFunctionDriver.hasAnyExpression else {
            return base
        }

        let maxFrame = max(1, cameraTimelineMaxFrame())
        let x = Double(max(0, min(maxFrame, frame))) / Double(maxFrame)
        var camera = base ?? cameraRig
        camera.yaw = applyCameraExpression(cameraFunctionDriver.yawExpression, x: x, y: camera.yaw)
        camera.pitch = applyCameraExpression(cameraFunctionDriver.pitchExpression, x: x, y: camera.pitch)
        camera.roll = applyCameraExpression(cameraFunctionDriver.rollExpression, x: x, y: camera.roll)
        camera.positionX = applyCameraExpression(cameraFunctionDriver.positionXExpression, x: x, y: camera.positionX)
        camera.positionY = applyCameraExpression(cameraFunctionDriver.positionYExpression, x: x, y: camera.positionY)
        camera.positionZ = applyCameraExpression(cameraFunctionDriver.positionZExpression, x: x, y: camera.positionZ)
        camera.focalLength = applyCameraExpression(cameraFunctionDriver.focalLengthExpression, x: x, y: camera.focalLength, lowerLimit: 1)
        camera.aperture = applyCameraExpression(cameraFunctionDriver.apertureExpression, x: x, y: camera.aperture, lowerLimit: 0.1)
        if camera.focusLockEnabled,
           let orientation = Self.cameraYawPitchForFocus(
            position: SIMD3<Float>(camera.positionX, camera.positionY, camera.positionZ),
            target: SIMD3<Float>(camera.focusTargetX, camera.focusTargetY, camera.focusTargetZ)
           ) {
            camera.yaw = orientation.yaw
            camera.pitch = orientation.pitch
        }
        return camera
    }

    private func baseInterpolatedCamera(at frame: Int) -> CameraRigState? {
        let sorted = cameraKeyframes.sorted { $0.frame < $1.frame }
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first.camera }
        if frame <= first.frame { return first.camera }
        if let last = sorted.last, frame >= last.frame { return last.camera }

        guard let upperIndex = sorted.firstIndex(where: { $0.frame >= frame }), upperIndex > 0 else {
            return first.camera
        }

        let lower = sorted[upperIndex - 1]
        let upper = sorted[upperIndex]
        let span = max(1, upper.frame - lower.frame)
        let t = Float(frame - lower.frame) / Float(span)
        return CameraRigState(
            yaw: lerpCameraValue(lower.camera.yaw, upper.camera.yaw, t),
            pitch: lerpCameraValue(lower.camera.pitch, upper.camera.pitch, t),
            roll: lerpCameraValue(lower.camera.roll, upper.camera.roll, t),
            distance: lerpCameraValue(lower.camera.distance, upper.camera.distance, t),
            positionX: lerpCameraValue(lower.camera.positionX, upper.camera.positionX, t),
            positionY: lerpCameraValue(lower.camera.positionY, upper.camera.positionY, t),
            positionZ: lerpCameraValue(lower.camera.positionZ, upper.camera.positionZ, t),
            focusLockEnabled: t < 0.5 ? lower.camera.focusLockEnabled : upper.camera.focusLockEnabled,
            focusTargetX: lerpCameraValue(lower.camera.focusTargetX, upper.camera.focusTargetX, t),
            focusTargetY: lerpCameraValue(lower.camera.focusTargetY, upper.camera.focusTargetY, t),
            focusTargetZ: lerpCameraValue(lower.camera.focusTargetZ, upper.camera.focusTargetZ, t),
            focalLength: lerpCameraValue(lower.camera.focalLength, upper.camera.focalLength, t),
            aperture: lerpCameraValue(lower.camera.aperture, upper.camera.aperture, t)
        )
    }

    private func applyCameraExpression(_ expression: String, x: Double, y: Float, lowerLimit: Float? = nil) -> Float {
        guard let value = CameraExpressionEvaluator.evaluate(expression, x: x, y: Double(y)),
              value.isFinite else {
            return y
        }
        let resolved = Float(value)
        if let lowerLimit {
            return max(lowerLimit, resolved)
        }
        return resolved
    }

    func deleteCameraKeyframe(_ keyframe: CameraKeyframe) {
        cameraKeyframes.removeAll { $0.id == keyframe.id }
    }

    func deleteCameraKeyframeAtCurrentFrame() {
        cameraKeyframes.removeAll { $0.frame == cameraTimelineFrame }
    }

    var hasCameraKeyframeAtCurrentFrame: Bool {
        cameraKeyframes.contains { $0.frame == cameraTimelineFrame }
    }

    func showFloatingCameraPreviewWindow() {
        if let cameraPreviewWindow, cameraPreviewWindow.isVisible {
            cameraPreviewWindow.makeKeyAndOrderFront(nil)
            return
        }

        cameraPreviewRenderer = nil
        isCameraPreviewFloating = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "摄像机视图"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .managed]
        window.center()
        window.contentView = NSHostingView(rootView: CameraFloatingPreviewWindowView(model: self))
        if let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow, parentWindow !== window {
            parentWindow.addChildWindow(window, ordered: .above)
        }
        if let cameraPreviewWindowCloseObserver {
            NotificationCenter.default.removeObserver(cameraPreviewWindowCloseObserver)
        }
        cameraPreviewWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cameraPreviewWindowDidClose()
            }
        }
        cameraPreviewWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func cameraPreviewWindowDidClose() {
        if let window = cameraPreviewWindow {
            window.parent?.removeChildWindow(window)
        }
        if let cameraPreviewWindowCloseObserver {
            NotificationCenter.default.removeObserver(cameraPreviewWindowCloseObserver)
            self.cameraPreviewWindowCloseObserver = nil
        }
        cameraPreviewWindow = nil
        cameraPreviewRenderer = nil
        isCameraPreviewFloating = false
    }

    private func lerpCameraValue(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * max(0, min(1, t))
    }

    // MARK: - Load video

    func makeProjectState() -> ChronoVolumeProjectDocument.AppProjectState {
        ChronoVolumeProjectDocument.AppProjectState(
            useAlpha: useAlpha,
            steps: steps,
            density: density,
            brightness: brightness,
            useVoxelBlockRendering: useVoxelBlockRendering,
            smoothVolumeEdges: smoothVolumeEdges,
            volumeBackgroundMode: volumeBackgroundMode,
            volumeBackgroundColor: volumeBackgroundColor,
            volumeTransform: volumeTransform,
            meshModifierState: meshModifierState,
            meshModifierStack: meshModifierStack,
            cameraRig: cameraRig,
            cameraTimelineFrame: cameraTimelineFrame,
            cameraTimelineFPS: cameraTimelineFPS,
            cameraKeyframes: cameraKeyframes,
            cameraExportPreserveAlpha: cameraExportPreserveAlpha,
            cameraFunctionDriver: cameraFunctionDriver,
            cameraExportSizeMode: cameraExportSizeMode,
            cameraExportCustomWidth: cameraExportCustomWidth,
            cameraExportCustomHeight: cameraExportCustomHeight,
            cameraExportFPSMode: cameraExportFPSMode,
            cameraExportCustomFPS: cameraExportCustomFPS,
            cameraExportBackgroundMode: cameraExportBackgroundMode,
            cameraExportBackgroundColor: cameraExportBackgroundColor,
            sliceMode: sliceMode,
            playbackAxis: playbackAxis,
            currentIndex: currentIndex,
            playbackRate: playbackRate,
            showCheckerboard: showCheckerboard,
            useFastPreviewWhilePlaying: useFastPreviewWhilePlaying,
            reduceResolutionWhilePlaying: reduceResolutionWhilePlaying,
            referencePlane: referencePlane,
            showCornerAxesOverlay: showCornerAxesOverlay,
            showOriginAxesOverlay: showOriginAxesOverlay,
            showPlaneOverlay: showPlaneOverlay,
            showCameraOverlay: showCameraOverlay
        )
    }

    func restoreProjectState(_ state: ChronoVolumeProjectDocument.AppProjectState) {
        stopPlayback()
        stopCameraTimelinePlayback()

        useAlpha = state.useAlpha
        steps = max(1, state.steps)
        density = state.density
        brightness = state.brightness
        useVoxelBlockRendering = state.useVoxelBlockRendering
        smoothVolumeEdges = state.smoothVolumeEdges
        volumeBackgroundMode = state.volumeBackgroundMode
        volumeBackgroundColor = state.volumeBackgroundColor
        volumeTransform = state.volumeTransform
        meshModifierState = state.meshModifierState
        meshModifierStack = state.meshModifierStack
        if meshModifierStack.isEmpty && !meshModifierState.isIdentity {
            let legacyModifier = MeshModifierItem(name: "变换 1", state: meshModifierState)
            meshModifierStack = [legacyModifier]
        }
        selectedMeshModifierID = meshModifierStack.first?.id
        if let firstModifier = meshModifierStack.first {
            meshModifierState = firstModifier.state
        }
        cameraRig = state.cameraRig
        syncCameraOrientationFromFocusLock()
        cameraTimelineFPS = max(0.05, state.cameraTimelineFPS)
        cameraKeyframes = state.cameraKeyframes.sorted { $0.frame < $1.frame }
        cameraExportPreserveAlpha = state.cameraExportPreserveAlpha
        cameraFunctionDriver = state.cameraFunctionDriver
        cameraExportSizeMode = state.cameraExportSizeMode
        cameraExportCustomWidth = max(1, state.cameraExportCustomWidth)
        cameraExportCustomHeight = max(1, state.cameraExportCustomHeight)
        cameraExportFPSMode = state.cameraExportFPSMode
        cameraExportCustomFPS = max(0.05, state.cameraExportCustomFPS)
        cameraExportBackgroundMode = state.cameraExportBackgroundMode
        cameraExportBackgroundColor = state.cameraExportBackgroundColor
        sliceMode = state.sliceMode
        playbackAxis = state.playbackAxis
        playbackRate = max(0.05, state.playbackRate)
        showCheckerboard = state.showCheckerboard
        useFastPreviewWhilePlaying = state.useFastPreviewWhilePlaying
        reduceResolutionWhilePlaying = state.reduceResolutionWhilePlaying
        referencePlane = state.referencePlane
        showCornerAxesOverlay = state.showCornerAxesOverlay
        showOriginAxesOverlay = state.showOriginAxesOverlay
        showPlaneOverlay = state.showPlaneOverlay
        showCameraOverlay = state.showCameraOverlay

        cameraTimelineFrame = max(0, min(state.cameraTimelineFrame, cameraTimelineMaxFrame()))
        currentIndex = max(0, min(state.currentIndex, max(0, totalFrameCountForCurrentMode() - 1)))

        if let renderer {
            configure(renderer: renderer)
            renderer.requestRedraw()
        }
        if hasModifierTarget {
            updateMeshModifierResult()
        }
        updateCameraPreviewRenderer()
        applyReferencePlane()
        setCurrentIndex(currentIndex)
        status = fullCPUVolume == nil ? status : "就绪"
    }

    func resetForNewProject(statusMessage: String = "就绪") {
        loadTask?.cancel()
        cancelMeshModifierCacheRebuild()
        loadGenerationID += 1
        pendingProjectStateAfterLoad = nil

        stopPlayback()
        stopCameraTimelinePlayback()
        removePlayerObservers()
        player = nil

        fileName = "未加载"
        volumeInfo = "-"
        previewVolumeInfo = "-"
        actualVolumeInfo = "-"
        alphaInfo = "-"
        sourceFPS = 0
        sourceDurationSeconds = 0
        sourceFrameCount = 0
        sourceBitDepth = 8
        sourceColorProfile = .rec709
        sourceAlphaBitDepth = 8
        previewAlphaBitDepth = 8
        videoSourcePair = nil
        colorSourceMetadata = nil
        alphaSourceMetadata = nil
        alphaSyncStatus = "单源"
        fullTemporalDepthCount = 0
        previewDepthCount = 0
        bestVisibleTIndex = 0
        currentSliceCGImage = nil
        currentIndex = 0
        fullCPUVolume = nil
        fullLoadedVolume = nil
        highPrecisionAlphaVolume = nil
        highPrecisionPairedCPUVolume = nil
        externalAlphaMaskPreviewVolume = nil
        externalAlphaMaskPreviewVolume = nil
        pendingPreviewVolume = nil
        originalMeshSurface = nil
        fullMeshSurface = nil
        meshSlicePreviewCache = nil
        originalFullCPUVolumeForModifiers = nil
        originalFullLoadedVolumeForModifiers = nil
        originalPreviewLoadedVolumeForModifiers = nil
        originalModifierPreviewLoadedVolumeForModifiers = nil
        isVideoVolumeModifierActive = false
        modifierLoadingMessage = nil
        previewAlphaBoundsForOverlay = nil
        videoLoadCache.removeAll()
        meshLoadCache.removeAll()
        pendingPlaneApplyWorkItem?.cancel()
        isSliceRendering = false
        isAxisCacheBuilding = false

        restoreProjectState(ChronoVolumeProjectDocument.AppProjectState())
        renderer?.clearVolume()
        cameraPreviewRenderer?.clearVolume()
        planeSliceRenderer?.clearVolume()
        axisSliceRenderer?.clearVolume()
        sliceRenderer?.clearVolume()
        status = statusMessage
    }

    func loadVideo(url: URL, restoring state: ChronoVolumeProjectDocument.AppProjectState) {
        pendingProjectStateAfterLoad = state
        let alphaURL = VideoSourcePairDiscovery.matchingAlphaURL(for: url)
        loadVideoInternal(pair: VideoSourcePair(
            colorURL: url,
            alphaURL: alphaURL,
            alphaSourceMode: alphaURL == nil ? .opaque : .external
        ))
    }

    func loadVideo(url: URL) {
        pendingProjectStateAfterLoad = nil
        let alphaURL = VideoSourcePairDiscovery.matchingAlphaURL(for: url)
        loadVideoInternal(pair: VideoSourcePair(
            colorURL: url,
            alphaURL: alphaURL,
            alphaSourceMode: alphaURL == nil ? .opaque : .external
        ))
    }

    func loadVideo(pair: VideoSourcePair, restoring state: ChronoVolumeProjectDocument.AppProjectState? = nil) {
        pendingProjectStateAfterLoad = state
        loadVideoInternal(pair: pair)
    }

    func addExternalAlpha(url: URL) {
        guard var pair = videoSourcePair else {
            status = "请先打开 A_color"
            return
        }
        let state = makeProjectState()
        pair.alphaURL = url
        pair.alphaSourceMode = .external
        pendingProjectStateAfterLoad = state
        loadVideoInternal(pair: pair)
    }

    func removeExternalAlpha() {
        guard var pair = videoSourcePair, pair.alphaURL != nil else { return }
        let state = makeProjectState()
        pair.alphaURL = nil
        pair.alphaSourceMode = .opaque
        pendingProjectStateAfterLoad = state
        loadVideoInternal(pair: pair)
    }

    func updateExternalAlphaSettings(_ settings: ExternalAlphaSettings) {
        guard var pair = videoSourcePair, pair.alphaURL != nil else { return }
        let state = makeProjectState()
        pair.externalAlphaSettings = settings
        pair.alphaSourceMode = .external
        pendingProjectStateAfterLoad = state
        loadVideoInternal(pair: pair)
    }

    func loadStaticMeshPackage(_ package: LoadedMeshPackage, url: URL, displayName: String) {
        pendingProjectStateAfterLoad = nil
        loadGenerationID += 1
        let generationID = loadGenerationID
        let cached = Self.makeCachedMeshLoad(volume: package.volume, mesh: package.mesh)
        meshLoadCache[url] = cached
        applyLoadedMesh(cached, url: url, displayName: displayName, generationID: generationID)
    }

    func loadStaticMesh(url: URL, restoring state: ChronoVolumeProjectDocument.AppProjectState? = nil) {
        loadTask?.cancel()
        cancelMeshModifierCacheRebuild()
        loadGenerationID += 1
        let generationID = loadGenerationID
        pendingProjectStateAfterLoad = state

        stopPlayback()
        removePlayerObservers()
        player = nil
        fileName = url.lastPathComponent
        status = "正在读取模型…"
        currentSliceCGImage = nil
        isSliceRendering = false
        isAxisCacheBuilding = false

        if let cached = meshLoadCache[url] {
            status = "正在切换已缓存模型…"
            loadTask = nil
            applyLoadedMesh(cached, url: url, displayName: url.lastPathComponent, generationID: generationID)
            return
        }

        loadTask = Task.detached(priority: .userInitiated) { [url, generationID] in
            do {
                let package = try MeshVolumeLoader.load(url: url)
                let cached = Self.makeCachedMeshLoad(volume: package.volume, mesh: package.mesh)
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, self.loadGenerationID == generationID else { return }
                    self.meshLoadCache[url] = cached
                    self.applyLoadedMesh(cached, url: url, displayName: url.lastPathComponent, generationID: generationID)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.loadGenerationID == generationID else { return }
                    self.pendingProjectStateAfterLoad = nil
                    self.status = "模型读取失败：\(error.localizedDescription)"
                    self.volumeInfo = "-"
                    self.previewVolumeInfo = "-"
                    self.actualVolumeInfo = "-"
                    self.alphaInfo = "-"
                    self.fullCPUVolume = nil
                    self.fullLoadedVolume = nil
                    self.pendingPreviewVolume = nil
                    self.originalMeshSurface = nil
                    self.fullMeshSurface = nil
                    self.meshSlicePreviewCache = nil
                    self.originalFullCPUVolumeForModifiers = nil
                    self.originalFullLoadedVolumeForModifiers = nil
                    self.originalPreviewLoadedVolumeForModifiers = nil
                    self.originalModifierPreviewLoadedVolumeForModifiers = nil
                    self.isVideoVolumeModifierActive = false
                    self.meshModifierState = MeshModifierState()
                    self.meshModifierStack = []
                    self.selectedMeshModifierID = nil
                    self.previewAlphaBoundsForOverlay = nil
                    self.currentSliceCGImage = nil
                    self.renderer?.setMeshSurface(nil)
                    self.cameraPreviewRenderer?.setMeshSurface(nil)
                    self.updateReferencePlaneOverlay()
                }
            }
        }
    }

    func loadStaticMeshVolume(_ volume: LoadedVolume, url: URL, displayName: String) {
        pendingProjectStateAfterLoad = nil
        loadStaticMeshVolume(volume, mesh: nil, url: url, displayName: displayName)
    }

    private func loadStaticMeshVolume(_ volume: LoadedVolume, mesh: LoadedMesh?, url: URL, displayName: String) {
        loadGenerationID += 1
        let generationID = loadGenerationID
        let cached = Self.makeCachedMeshLoad(volume: volume, mesh: mesh)
        meshLoadCache[url] = cached
        applyLoadedMesh(cached, url: url, displayName: displayName, generationID: generationID)
    }

    nonisolated private static func makeCachedMeshLoad(volume: LoadedVolume, mesh: LoadedMesh?) -> CachedMeshLoad {
        let cpuVolume = CPUVolume(
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            rgba: volume.rgba,
            hasMeaningfulAlpha: volume.hasMeaningfulAlpha,
            sourceColorProfile: volume.sourceColorProfile
        )
        let bestVisibleIndex = findBestVisibleTIndex(volume: cpuVolume)
        let previewAlphaBounds = alphaBoundsForOverlay(volume: volume)
        let meshSlicePreviewCache = mesh.flatMap {
            MeshSliceRasterizer.makeCache(mesh: $0, volume: cpuVolume)
        }
        return CachedMeshLoad(
            volume: volume,
            mesh: mesh,
            cpuVolume: cpuVolume,
            bestVisibleIndex: bestVisibleIndex,
            previewAlphaBounds: previewAlphaBounds,
            meshSlicePreviewCache: meshSlicePreviewCache
        )
    }

    private func applyLoadedMesh(_ cached: CachedMeshLoad, url: URL, displayName: String, generationID: Int) {
        guard loadGenerationID == generationID else { return }
        loadTask?.cancel()
        cancelMeshModifierCacheRebuild()
        meshModifierState = MeshModifierState()
        meshModifierStack = []
        selectedMeshModifierID = nil

        stopPlayback()
        removePlayerObservers()
        player = nil
        pendingPlaneApplyWorkItem?.cancel()

        let volume = cached.volume
        let cpuVolume = cached.cpuVolume
        let mesh = cached.mesh
        let bestVisibleIndex = cached.bestVisibleIndex

        fileName = displayName.isEmpty ? url.lastPathComponent : displayName
        videoSourcePair = nil
        colorSourceMetadata = nil
        alphaSourceMetadata = nil
        highPrecisionAlphaVolume = nil
        highPrecisionPairedCPUVolume = nil
        externalAlphaMaskPreviewVolume = nil
        fullCPUVolume = cpuVolume
        fullLoadedVolume = volume
        pendingPreviewVolume = volume
        originalMeshSurface = mesh
        fullMeshSurface = mesh?.applying(effectiveMeshModifierStack())
        meshSlicePreviewCache = cached.meshSlicePreviewCache
        originalFullCPUVolumeForModifiers = nil
        originalFullLoadedVolumeForModifiers = nil
        originalPreviewLoadedVolumeForModifiers = nil
        originalModifierPreviewLoadedVolumeForModifiers = nil
        isVideoVolumeModifierActive = false
        previewAlphaBoundsForOverlay = cached.previewAlphaBounds
        volumeScaleForOverlay = cpuVolume.normalizedVolumeScale()
        previewVolumeInfo = "\(volume.width) × \(volume.height) × \(volume.depth)"
        actualVolumeInfo = "3D 模型体素代理：\(volume.width) × \(volume.height) × \(volume.depth)"

        sourceFPS = volume.sourceFPS
        sourceDurationSeconds = volume.sourceDurationSeconds
        sourceFrameCount = volume.depth
        sourceBitDepth = 8
        sourceColorProfile = volume.sourceColorProfile
        fullTemporalDepthCount = volume.depth
        previewDepthCount = volume.depth
        bestVisibleTIndex = bestVisibleIndex

        volumeInfo = "\(volume.width) × \(volume.height) × \(volume.depth)"
        alphaInfo = "模型体素 Alpha"
        currentSliceCGImage = nil
        currentIndex = sliceMode == .axis && playbackAxis == .t ? bestVisibleIndex : 0
        isSliceRendering = false
        isAxisCacheBuilding = false

        if let renderer {
            renderer.setVolume(volume)
            renderer.setMeshSurface(fullMeshSurface)
            renderer.setDisplayScale(cpuVolume.normalizedVolumeScale())
        }
        if let cameraRenderer = cameraPreviewRenderer {
            cameraRenderer.setVolume(volume)
            cameraRenderer.setMeshSurface(fullMeshSurface)
            cameraRenderer.setDisplayScale(cpuVolume.normalizedVolumeScale())
        }
        if let planeRenderer = planeSliceRenderer {
            planeRenderer.setVolume(volume)
        }
        if let axisRenderer = axisSliceRenderer {
            axisRenderer.setVolume(volume)
        }
        if let sliceRenderer {
            sliceRenderer.setVolume(volume)
        }

        updateReferencePlaneOverlay()
        rebuildCurrentSlice()
        if let pendingProjectStateAfterLoad {
            self.pendingProjectStateAfterLoad = nil
            restoreProjectState(pendingProjectStateAfterLoad)
        } else {
            status = "模型已导入，可在 3D 视图查看并进行 2D 切片"
        }
    }

    private func loadVideoInternal(pair: VideoSourcePair) {
        let url = pair.colorURL
        loadTask?.cancel()
        cancelMeshModifierCacheRebuild()
        loadGenerationID += 1
        let generationID = loadGenerationID

        stopPlayback()

        fileName = url.lastPathComponent
        videoSourcePair = pair
        volumeInfo = "-"
        previewVolumeInfo = "-"
        actualVolumeInfo = "-"
        alphaInfo = "-"
        sourceBitDepth = 8
        sourceColorProfile = .rec709
        sourceAlphaBitDepth = 8
        previewAlphaBitDepth = 8
        colorSourceMetadata = nil
        alphaSourceMetadata = nil
        alphaSyncStatus = pair.alphaURL == nil ? "单源" : "等待 PTS 校验"
        currentSliceCGImage = nil
        currentIndex = 0
        bestVisibleTIndex = 0
        fullCPUVolume = nil
        fullLoadedVolume = nil
        highPrecisionAlphaVolume = nil
        pendingPreviewVolume = nil
        originalMeshSurface = nil
        fullMeshSurface = nil
        meshSlicePreviewCache = nil
        originalFullCPUVolumeForModifiers = nil
        originalFullLoadedVolumeForModifiers = nil
        originalPreviewLoadedVolumeForModifiers = nil
        originalModifierPreviewLoadedVolumeForModifiers = nil
        isVideoVolumeModifierActive = false
        meshModifierState = MeshModifierState()
        meshModifierStack = []
        selectedMeshModifierID = nil
        previewAlphaBoundsForOverlay = nil
        isSliceRendering = false
        isAxisCacheBuilding = false
        removePlayerObservers()
        player = nil
        pendingPlaneApplyWorkItem?.cancel()
        renderer?.setMeshSurface(nil)
        cameraPreviewRenderer?.setMeshSurface(nil)

        status = "正在读取视频…"

        if let cached = videoLoadCache[pair] {
            status = "正在切换已缓存视频…"
            loadTask = nil
            applyLoadedVideo(cached, pair: pair, generationID: generationID)
            return
        }

        loadTask = Task.detached(priority: .userInitiated) { [pair, generationID] in
            let colorAccess = pair.colorURL.startAccessingSecurityScopedResource()
            let alphaAccess = pair.alphaURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if colorAccess { pair.colorURL.stopAccessingSecurityScopedResource() }
                if alphaAccess { pair.alphaURL?.stopAccessingSecurityScopedResource() }
            }
            do {
                let package = try await VideoVolumeLoader.load(
                    colorURL: pair.colorURL,
                    alphaURL: pair.alphaURL,
                    settings: pair.externalAlphaSettings,
                    generatedWhiteColor: pair.usesGeneratedWhiteColor,
                    maxWidth: 1024,
                    maxHeight: 1024,
                    previewMaxDepth: 256
                )

                try Task.checkCancellation()
                let cached = Self.makeCachedVideoLoad(package: package)
                try Task.checkCancellation()

                await MainActor.run { [weak self] in
                    guard let self, self.loadGenerationID == generationID else { return }
                    self.videoLoadCache[pair] = cached
                    self.applyLoadedVideo(cached, pair: pair, generationID: generationID)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.loadGenerationID == generationID else { return }

                    self.pendingProjectStateAfterLoad = nil
                    self.status = "读取失败：\(error.localizedDescription)"
                    self.volumeInfo = "-"
                    self.previewVolumeInfo = "-"
                    self.actualVolumeInfo = "-"
                    self.alphaInfo = "-"
                    self.sourceBitDepth = 8
                    self.sourceColorProfile = .rec709
                    self.fullCPUVolume = nil
                    self.fullLoadedVolume = nil
                    self.pendingPreviewVolume = nil
                    self.originalMeshSurface = nil
                    self.fullMeshSurface = nil
                    self.meshSlicePreviewCache = nil
                    self.originalFullCPUVolumeForModifiers = nil
                    self.originalFullLoadedVolumeForModifiers = nil
                    self.originalPreviewLoadedVolumeForModifiers = nil
                    self.originalModifierPreviewLoadedVolumeForModifiers = nil
                    self.isVideoVolumeModifierActive = false
                    self.meshModifierState = MeshModifierState()
                    self.meshModifierStack = []
                    self.selectedMeshModifierID = nil
                    self.previewAlphaBoundsForOverlay = nil
                    self.currentSliceCGImage = nil
                    self.isSliceRendering = false
                    self.isAxisCacheBuilding = false
                    self.updateReferencePlaneOverlay()
                }
            }
        }
    }

    func cacheLoadedVideoPackage(_ package: LoadedVideoPackage, url: URL) {
        let pair = VideoSourcePair(colorURL: url, alphaSourceMode: package.alphaSourceMode)
        guard videoLoadCache[pair] == nil else { return }

        Task.detached(priority: .utility) { [package, pair] in
            let cached = Self.makeCachedVideoLoad(package: package)
            await MainActor.run { [weak self] in
                guard let self, self.videoLoadCache[pair] == nil else { return }
                self.videoLoadCache[pair] = cached
            }
        }
    }

    nonisolated private static func makeCachedVideoLoad(package: LoadedVideoPackage) -> CachedVideoLoad {
        let full = package.fullTemporalVolume
        let preview = package.previewVolume
        let cpuVolume = CPUVolume(
            width: full.width,
            height: full.height,
            depth: full.depth,
            rgba: full.rgba,
            hasMeaningfulAlpha: full.hasMeaningfulAlpha,
            sourceColorProfile: package.sourceColorProfile
        )
        let bestVisibleIndex = findBestVisibleTIndex(volume: cpuVolume)
        let previewAlphaBounds = alphaBoundsForOverlay(volume: preview)
        let modifierPreviewVolume = VolumeModifierRasterizer.downsampledPreviewVolumeForModifierEditing(
            from: preview,
            maxBytes: videoModifierInteractivePreviewMaxBytes
        )

        return CachedVideoLoad(
            package: package,
            cpuVolume: cpuVolume,
            modifierPreviewVolume: modifierPreviewVolume,
            bestVisibleIndex: bestVisibleIndex,
            previewAlphaBounds: previewAlphaBounds
        )
    }

    private func applyLoadedVideo(_ cached: CachedVideoLoad, pair: VideoSourcePair, generationID: Int) {
        guard loadGenerationID == generationID else { return }
        cancelMeshModifierCacheRebuild()

        let package = cached.package
        let full = package.fullTemporalVolume
        let preview = package.previewVolume
        let cpuVolume = cached.cpuVolume
        let url = pair.colorURL

        fullCPUVolume = cpuVolume
        fullLoadedVolume = full
        highPrecisionAlphaVolume = package.highPrecisionAlphaVolume
        highPrecisionPairedCPUVolume = nil
        externalAlphaMaskPreviewVolume = package.alphaSourceMode == .external
            ? Self.makeAlphaMaskPreviewVolume(from: full)
            : nil
        pendingPreviewVolume = preview
        originalMeshSurface = nil
        fullMeshSurface = nil
        meshSlicePreviewCache = nil
        originalFullCPUVolumeForModifiers = cpuVolume
        originalFullLoadedVolumeForModifiers = full
        originalPreviewLoadedVolumeForModifiers = preview
        originalModifierPreviewLoadedVolumeForModifiers = cached.modifierPreviewVolume
        isVideoVolumeModifierActive = false
        meshModifierState = MeshModifierState()
        meshModifierStack = []
        selectedMeshModifierID = nil
        previewAlphaBoundsForOverlay = cached.previewAlphaBounds
        volumeScaleForOverlay = cpuVolume.normalizedVolumeScale()
        previewVolumeInfo = "\(preview.width) × \(preview.height) × \(preview.depth)"
        actualVolumeInfo = "\(package.sourceWidth) × \(package.sourceHeight) × \(package.sourceFrameCount)"

        sourceFPS = package.sourceFPS
        sourceDurationSeconds = package.sourceDurationSeconds
        sourceFrameCount = package.sourceFrameCount
        sourceBitDepth = package.sourceBitDepth
        sourceColorProfile = package.sourceColorProfile
        sourceAlphaBitDepth = package.sourceAlphaBitDepth
        previewAlphaBitDepth = package.previewAlphaBitDepth
        colorSourceMetadata = package.colorMetadata
        alphaSourceMetadata = package.alphaMetadata
        alphaSyncStatus = package.alphaSyncStatus
        var resolvedPair = pair
        resolvedPair.alphaSourceMode = package.alphaSourceMode
        videoSourcePair = resolvedPair
        fullTemporalDepthCount = full.depth
        previewDepthCount = preview.depth
        bestVisibleTIndex = cached.bestVisibleIndex

        volumeInfo = "\(full.width) × \(full.height) × \(full.depth)"
        switch package.alphaSourceMode {
        case .external:
            alphaInfo = "外部 B_alpha（源 \(package.sourceAlphaBitDepth)-bit → 交互预览 8-bit）"
        case .embedded:
            alphaInfo = "检测到有效内嵌 Alpha"
        case .opaque:
            alphaInfo = "无有效 Alpha，按不透明解释"
        }

        if sliceMode == .axis && playbackAxis == .t {
            currentIndex = cached.bestVisibleIndex
        } else {
            currentIndex = 0
        }

        setupPlayer(url: url)

        if let renderer {
            renderer.setVolume(preview)
            renderer.setDisplayScale(cpuVolume.normalizedVolumeScale())
        }
        if let cameraRenderer = cameraPreviewRenderer {
            cameraRenderer.setVolume(preview)
            cameraRenderer.setDisplayScale(cpuVolume.normalizedVolumeScale())
        }
        if let planeRenderer = planeSliceRenderer {
            planeRenderer.setVolume(full)
        }
        if let axisRenderer = axisSliceRenderer {
            axisRenderer.setVolume(full)
        }
        if let sliceRenderer {
            sliceRenderer.setVolume(full)
        }

        applyExternalAlphaPreviewMode()

        updateReferencePlaneOverlay()
        rebuildCurrentSlice()
        status = "就绪"

        if let pendingProjectStateAfterLoad {
            self.pendingProjectStateAfterLoad = nil
            restoreProjectState(pendingProjectStateAfterLoad)
        }
    }

    func setExternalAlphaPreviewMode(_ mode: ExternalAlphaPreviewMode) {
        externalAlphaPreviewMode = mode
        applyExternalAlphaPreviewMode()
        rebuildCurrentSlice()
    }

    private func applyExternalAlphaPreviewMode() {
        guard videoSourcePair?.alphaSourceMode == .external, let fullLoadedVolume else { return }
        let volume: LoadedVolume
        if externalAlphaPreviewMode == .grayscaleMask, let mask = externalAlphaMaskPreviewVolume {
            volume = mask
            showCheckerboard = false
        } else {
            volume = fullLoadedVolume
            showCheckerboard = externalAlphaPreviewMode == .checkerboardTransparency
        }
        sliceRenderer?.setVolume(volume)
        axisSliceRenderer?.setVolume(volume)
        planeSliceRenderer?.setVolume(volume)
        sliceRenderer?.requestRedraw()
        axisSliceRenderer?.requestRedraw()
        planeSliceRenderer?.requestRedraw()
    }

    nonisolated private static func makeAlphaMaskPreviewVolume(from volume: LoadedVolume) -> LoadedVolume {
        var rgba = volume.rgba
        var offset = 0
        while offset + 3 < rgba.count {
            let alpha = rgba[offset + 3]
            rgba[offset] = alpha
            rgba[offset + 1] = alpha
            rgba[offset + 2] = alpha
            rgba[offset + 3] = 255
            offset += 4
        }
        return LoadedVolume(
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            rgba: rgba,
            hasMeaningfulAlpha: false,
            sourceFPS: volume.sourceFPS,
            sourceDurationSeconds: volume.sourceDurationSeconds,
            sourceFrameCountEstimate: volume.sourceFrameCountEstimate,
            sourceColorProfile: volume.sourceColorProfile
        )
    }

    // MARK: - Player

    private func setupPlayer(url: URL) {
        removePlayerObservers()

        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        self.player = player

        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        playerTimeObserverOwner = player
        playerTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.sliceMode == .axis, self.playbackAxis == .t else { return }
                guard self.sourceDurationSeconds > 0, self.fullTemporalDepthCount > 0 else { return }

                let seconds = max(0.0, CMTimeGetSeconds(time))
                let frameDuration = self.sourceDurationSeconds / Double(max(1, self.fullTemporalDepthCount))
                let idx = max(0, min(self.fullTemporalDepthCount - 1, Int(floor(seconds / max(frameDuration, 0.000_001)))))
                if idx != self.currentIndex {
                    self.currentIndex = idx
                    self.updateReferencePlaneOverlay()
                }
            }
        }

        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player?.seek(to: .zero)
                self.currentIndex = 0
                if self.isPlaying {
                    self.player?.playImmediately(atRate: Float(self.playbackRate))
                }
            }
        }

        if sliceMode == .axis && playbackAxis == .t {
            seekPlayerToCurrentIndex()
        }
    }

    private func removePlayerObservers() {
        if let player = playerTimeObserverOwner, let observer = playerTimeObserver {
            player.removeTimeObserver(observer)
        }
        playerTimeObserver = nil
        playerTimeObserverOwner = nil

        if let endObserver = playerEndObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        playerEndObserver = nil
    }

    private func seekPlayerToCurrentIndex() {
        guard let player else { return }
        guard sourceDurationSeconds > 0, fullTemporalDepthCount > 0 else { return }

        let frameDuration = sourceDurationSeconds / Double(max(1, fullTemporalDepthCount))
        let seconds = Double(currentIndex) * frameDuration
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Playback driver optimization

    private func ensureDisplayLinkDriver() {
        if displayLinkDriver != nil { return }

        displayLinkDriver = CVDisplayLinkDriver()
        displayLinkDriver?.callback = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.isPlaying else { return }
                guard self.usesGeneratedTimeAxisPreview || !(self.sliceMode == .axis && self.playbackAxis == .t) else { return }
                self.advanceOneFrameWithDisplayLink()
            }
        }
    }

    private func advanceOneFrameWithDisplayLink() {
        let total = totalFrameCountForCurrentMode()
        guard total > 0 else { return }

        let elapsed = CACurrentMediaTime() - playbackStartTime
        let fps = effectivePlaybackFPS()
        let advancedFrames = Int(floor(elapsed * fps))
        let newIndex = (playbackStartIndex + advancedFrames) % total

        guard newIndex != lastPresentedFrameIndex else { return }
        lastPresentedFrameIndex = newIndex

        if newIndex != currentIndex {
            currentIndex = newIndex
            rebuildCurrentSlice()
            planeSliceRenderer?.requestRedraw()
            axisSliceRenderer?.requestRedraw()
        }
    }


    var current2DAspectRatio: CGFloat {
        let size = imageSizeForCurrentMode()
        guard size.0 > 0, size.1 > 0 else { return 16.0 / 9.0 }
        return CGFloat(size.0) / CGFloat(size.1)
    }

    var current3DViewportAspectRatio: CGFloat {
        guard let fullCPUVolume else { return 16.0 / 9.0 }
        return max(0.1, CGFloat(fullCPUVolume.width) / CGFloat(fullCPUVolume.height))
    }

    // MARK: - Public helpers

    func jumpToBestVisibleFrame() {
        guard sliceMode == .axis, playbackAxis == .t else { return }
        setCurrentIndex(bestVisibleTIndex)
    }

    func reset3DDefaultView() {
        if let renderer {
            renderer.resetView()
        } else {
            cameraYaw = 0
            cameraPitch = 0
            cameraDistance = 2.2
        }
    }

    func correctedPlaneBasis() -> (u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>) {
        let uRaw = referencePlane.uAxis
        let vRaw = referencePlane.vAxis
        let nHint = referencePlane.normalAxis

        let u = simd_length(uRaw) > 1e-6 ? simd_normalize(uRaw) : SIMD3<Float>(1, 0, 0)
        var n = simd_cross(u, vRaw)
        if simd_length(n) <= 1e-6 {
            n = simd_length(nHint) > 1e-6 ? simd_normalize(nHint) : SIMD3<Float>(0, 0, 1)
        } else {
            n = simd_normalize(n)
            if simd_dot(n, nHint) < 0 { n = -n }
        }
        var v = simd_cross(n, u)
        if simd_length(v) <= 1e-6 {
            v = simd_length(vRaw) > 1e-6 ? simd_normalize(vRaw) : SIMD3<Float>(0, 1, 0)
        } else {
            v = simd_normalize(v)
        }
        n = simd_normalize(simd_cross(u, v))
        if simd_dot(n, nHint) < 0 {
            n = -n
            v = -v
        }
        return (u, v, n)
    }

    func referencePlaneOverlayGeometry() -> (corners: [SIMD3<Float>], center: SIMD3<Float>, normalEnd: SIMD3<Float>, upEnd: SIMD3<Float>)? {
        guard let fullCPUVolume else { return nil }
        let previewWidth = max(1, pendingPreviewVolume?.width ?? fullCPUVolume.width)
        let previewHeight = max(1, pendingPreviewVolume?.height ?? fullCPUVolume.height)
        let previewDepth = max(1, pendingPreviewVolume?.depth ?? fullCPUVolume.depth)
        let fullGeometry = fullCPUVolume.planeGeometry(for: referencePlane)
        let g = previewAlphaBoundsForOverlay.map {
            makePlaneGeometry(bounds: $0, plane: referencePlane)
        } ?? makePlaneGeometry(
            width: previewWidth,
            height: previewHeight,
            depth: previewDepth,
            plane: referencePlane
        )
        let fullSliceCount = max(1, fullGeometry.sliceCount)
        let previewSliceCount = max(1, g.sliceCount)
        let fullSliceIndex = max(0, min(currentIndex, fullSliceCount - 1))
        let progress = fullSliceCount == 1 ? 0.5 : Float(fullSliceIndex) / Float(fullSliceCount - 1)
        let sliceIndex = max(0, min(previewSliceCount - 1, Int(round(progress * Float(previewSliceCount - 1)))))
        let d: Float
        if previewSliceCount == 1 {
            d = (g.nMin + g.nMax) * 0.5
        } else {
            d = g.nMin + (g.nMax - g.nMin) * (Float(sliceIndex) / Float(previewSliceCount - 1))
        }

        func voxelPoint(u: Float, v: Float) -> SIMD3<Float> {
            g.u * u + g.v * v + g.n * d
        }

        func toLocal(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(
                p.x / max(1, Float(previewWidth - 1)),
                p.y / max(1, Float(previewHeight - 1)),
                p.z / max(1, Float(previewDepth - 1))
            )
        }

        let p0 = voxelPoint(u: g.uMin, v: g.vMin)
        let p1 = voxelPoint(u: g.uMax, v: g.vMin)
        let p2 = voxelPoint(u: g.uMax, v: g.vMax)
        let p3 = voxelPoint(u: g.uMin, v: g.vMax)
        let centerVoxel = voxelPoint(u: (g.uMin + g.uMax) * 0.5, v: (g.vMin + g.vMax) * 0.5)
        let arrowLength = max(1, min(Float(previewWidth), Float(previewHeight), Float(previewDepth)) * 0.18)

        return (
            corners: [toLocal(p0), toLocal(p1), toLocal(p2), toLocal(p3)],
            center: toLocal(centerVoxel),
            normalEnd: toLocal(centerVoxel + g.n * arrowLength),
            upEnd: toLocal(centerVoxel - g.v * arrowLength)
        )
    }

    func referencePlaneOverlayTriangles() -> [SIMD3<Float>] {
        guard showPlaneOverlay, let geometry = referencePlaneOverlayGeometry(), geometry.corners.count == 4 else {
            return []
        }
        let c = geometry.corners
        return [c[0], c[1], c[2], c[0], c[2], c[3]]
    }

    func updateReferencePlaneOverlay(renderer: VolumeRenderer? = nil) {
        let target = renderer ?? self.renderer
        target?.setReferencePlaneOverlay(vertices: referencePlaneOverlayTriangles(), visible: showPlaneOverlay)
    }

    nonisolated private static func alphaBoundsForOverlay(volume: LoadedVolume) -> VolumeVoxelBounds? {
        var minX = volume.width
        var maxX = -1
        var minY = volume.height
        var maxY = -1
        var minT = volume.depth
        var maxT = -1
        let threshold: UInt8 = volume.hasMeaningfulAlpha ? 8 : 1

        for t in 0..<volume.depth {
            for y in 0..<volume.height {
                let rowBase = ((t * volume.height + y) * volume.width) * 4
                for x in 0..<volume.width {
                    let index = rowBase + x * 4
                    let alpha = volume.rgba[index + 3]
                    let visible = volume.hasMeaningfulAlpha
                        ? alpha > threshold
                        : (volume.rgba[index] > threshold || volume.rgba[index + 1] > threshold || volume.rgba[index + 2] > threshold)
                    if visible {
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                        minY = min(minY, y)
                        maxY = max(maxY, y)
                        minT = min(minT, t)
                        maxT = max(maxT, t)
                    }
                }
            }
        }

        guard maxX >= minX, maxY >= minY, maxT >= minT else { return nil }
        return VolumeVoxelBounds(
            minX: Float(minX) - Float(volume.width - 1) * 0.5,
            maxX: Float(maxX) - Float(volume.width - 1) * 0.5,
            minY: Float(minY) - Float(volume.height - 1) * 0.5,
            maxY: Float(maxY) - Float(volume.height - 1) * 0.5,
            minT: Float(minT) - Float(volume.depth - 1) * 0.5,
            maxT: Float(maxT) - Float(volume.depth - 1) * 0.5
        )
    }

    func axisPreviewParameters(previewScale: Float) -> AxisSliceParameters? {
        guard let fullCPUVolume else { return nil }
        guard sliceMode == .axis, playbackAxis == .x || playbackAxis == .y else { return nil }

        let size = fullCPUVolume.imageSize(for: playbackAxis)
        let outW = max(1, Int(Float(size.width) * previewScale))
        let outH = max(1, Int(Float(size.height) * previewScale))

        return AxisSliceParameters(
            outWidth: outW,
            outHeight: outH,
            axis: playbackAxis,
            index: currentIndex,
            volumeWidth: fullCPUVolume.width,
            volumeHeight: fullCPUVolume.height,
            volumeDepth: fullCPUVolume.depth
        )
    }

    func planePreviewParameters(previewScale: Float) -> PlaneSliceParameters? {
        guard let fullCPUVolume else { return nil }
        let g = fullCPUVolume.planeGeometry(for: referencePlane)
        let basis = correctedPlaneBasis()

        let sliceCount = max(1, g.sliceCount)
        let sliceIndex = max(0, min(currentIndex, sliceCount - 1))

        let d: Float
        if sliceCount == 1 {
            d = (g.nMin + g.nMax) * 0.5
        } else {
            d = g.nMin + (g.nMax - g.nMin) * (Float(sliceIndex) / Float(sliceCount - 1))
        }

        let outW = max(1, Int(Float(g.outWidth) * previewScale))
        let outH = max(1, Int(Float(g.outHeight) * previewScale))

        return PlaneSliceParameters(
            outWidth: outW,
            outHeight: outH,
            u: basis.u,
            v: basis.v,
            n: basis.n,
            uMin: g.uMin,
            uMax: g.uMax,
            vMin: g.vMin,
            vMax: g.vMax,
            d: d,
            volumeWidth: fullCPUVolume.width,
            volumeHeight: fullCPUVolume.height,
            volumeDepth: fullCPUVolume.depth
        )
    }

    func invalidateSliceCacheAndRebuild() {
        rebuildCurrentSlice()
        planeSliceRenderer?.requestRedraw()
        axisSliceRenderer?.requestRedraw()
    }

    func totalFrameCountForCurrentMode() -> Int {
        guard let fullCPUVolume else { return 0 }
        switch sliceMode {
        case .axis:
            return fullCPUVolume.timeCount(for: playbackAxis)
        case .plane:
            return fullCPUVolume.planeGeometry(for: referencePlane).sliceCount
        }
    }

    func imageSizeForCurrentMode() -> (Int, Int) {
        guard let fullCPUVolume else { return (0, 0) }
        switch sliceMode {
        case .axis:
            let s = fullCPUVolume.imageSize(for: playbackAxis)
            return (s.width, s.height)
        case .plane:
            let g = fullCPUVolume.planeGeometry(for: referencePlane)
            return (g.outWidth, g.outHeight)
        }
    }

    // MARK: - Mode / axis / plane

    func setSliceMode(_ mode: SliceMode) {
        sliceMode = mode
        currentIndex = min(currentIndex, max(0, totalFrameCountForCurrentMode() - 1))
        updateReferencePlaneOverlay()
        rebuildCurrentSlice()
        planeSliceRenderer?.requestRedraw()
        axisSliceRenderer?.requestRedraw()

        if mode == .axis && playbackAxis == .t && !usesGeneratedTimeAxisPreview {
            seekPlayerToCurrentIndex()
        } else if isPlaying {
            startPlayback()
        }
    }

    func setPlaybackAxis(_ axis: PlaybackAxis) {
        playbackAxis = axis
        if sliceMode == .axis && axis == .t {
            currentIndex = min(bestVisibleTIndex, max(0, totalFrameCountForCurrentMode() - 1))
            seekPlayerToCurrentIndex()
        } else {
            currentIndex = min(currentIndex, max(0, totalFrameCountForCurrentMode() - 1))
        }

        updateReferencePlaneOverlay()
        rebuildCurrentSlice()
        planeSliceRenderer?.requestRedraw()
        axisSliceRenderer?.requestRedraw()

        if isPlaying {
            startPlayback()
        }
    }

    func stageReferencePlane(yaw: Float? = nil, pitch: Float? = nil, roll: Float? = nil) {
        if let yaw { referencePlane.yawDegrees = yaw }
        if let pitch { referencePlane.pitchDegrees = pitch }
        if let roll { referencePlane.rollDegrees = roll }

        updateReferencePlaneOverlay()
        planeSliceRenderer?.requestRedraw()

        pendingPlaneApplyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.applyReferencePlane()
            }
        }
        pendingPlaneApplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: workItem)
    }

    func applyReferencePlane() {
        currentIndex = min(currentIndex, max(0, totalFrameCountForCurrentMode() - 1))
        updateReferencePlaneOverlay()
        rebuildCurrentSlice()
        planeSliceRenderer?.requestRedraw()
    }

    func resetReferencePlane() {
        pendingPlaneApplyWorkItem?.cancel()
        referencePlane.reset()
        currentIndex = min(currentIndex, max(0, totalFrameCountForCurrentMode() - 1))
        updateReferencePlaneOverlay()
        rebuildCurrentSlice()
        planeSliceRenderer?.requestRedraw()
    }

    func setCurrentIndex(_ index: Int) {
        let total = totalFrameCountForCurrentMode()
        guard total > 0 else {
            currentIndex = 0
            currentSliceCGImage = nil
            updateReferencePlaneOverlay()
            return
        }
        currentIndex = max(0, min(index, total - 1))
        updateReferencePlaneOverlay()

        if sliceMode == .axis && playbackAxis == .t && !usesGeneratedTimeAxisPreview {
            seekPlayerToCurrentIndex()
        } else {
            rebuildCurrentSlice()
            planeSliceRenderer?.requestRedraw()
            axisSliceRenderer?.requestRedraw()
        }
    }

    // MARK: - Playback

    func setPlaybackRate(_ newRate: Double) {
        playbackRate = newRate
        if isPlaying {
            if sliceMode == .axis && playbackAxis == .t && !usesGeneratedTimeAxisPreview {
                player?.playImmediately(atRate: Float(playbackRate))
            } else {
                playbackStartTime = CACurrentMediaTime()
                playbackStartIndex = currentIndex
                lastPresentedFrameIndex = -1
            }
        }
    }

    func startPlayback() {
        guard fullCPUVolume != nil else { return }

        stopPlayback(rebuildSlice: false)
        isPlaying = true

        if sliceMode == .axis && playbackAxis == .t && !usesGeneratedTimeAxisPreview {
            player?.playImmediately(atRate: Float(playbackRate))
            return
        }

        playbackStartTime = CACurrentMediaTime()
        playbackStartIndex = currentIndex
        lastPresentedFrameIndex = -1

        ensureDisplayLinkDriver()
        displayLinkDriver?.start()

        rebuildCurrentSlice()
        planeSliceRenderer?.requestRedraw()
        axisSliceRenderer?.requestRedraw()
    }

    func stopPlayback() {
        stopPlayback(rebuildSlice: true)
    }

    private func stopPlayback(rebuildSlice: Bool) {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        displayLinkDriver?.stop()
        lastPresentedFrameIndex = -1
        player?.pause()
        guard rebuildSlice else { return }
        rebuildCurrentSlice()
        planeSliceRenderer?.requestRedraw()
        axisSliceRenderer?.requestRedraw()
    }

    func releaseInteractivePreviewResourcesForExport() {
        stopPlayback()
        currentSliceCGImage = nil
        renderer?.clearVolume()
        cameraPreviewRenderer?.clearVolume()
        planeSliceRenderer?.clearVolume()
        axisSliceRenderer?.clearVolume()
        sliceRenderer?.clearVolume()
    }

    func restoreInteractivePreviewResourcesAfterExport() {
        if let renderer, let pendingPreviewVolume {
            renderer.setVolume(pendingPreviewVolume)
            renderer.setMeshSurface(fullMeshSurface)
            if let fullCPUVolume {
                renderer.setDisplayScale(fullCPUVolume.normalizedVolumeScale())
            }
            updateReferencePlaneOverlay(renderer: renderer)
        }

        if let cameraPreviewRenderer, let pendingPreviewVolume {
            cameraPreviewRenderer.setVolume(pendingPreviewVolume)
            cameraPreviewRenderer.setMeshSurface(fullMeshSurface)
            if let fullCPUVolume {
                cameraPreviewRenderer.setDisplayScale(fullCPUVolume.normalizedVolumeScale())
            }
            configureCameraPreview(renderer: cameraPreviewRenderer)
        }

        if let planeSliceRenderer, let fullLoadedVolume {
            planeSliceRenderer.setVolume(fullLoadedVolume)
        }

        if let axisSliceRenderer, let fullLoadedVolume {
            axisSliceRenderer.setVolume(fullLoadedVolume)
        }

        if let sliceRenderer, let fullLoadedVolume {
            sliceRenderer.setVolume(fullLoadedVolume)
        }

        rebuildCurrentSlice()
        updateReferencePlaneOverlay()
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func effectivePlaybackFPS() -> Double {
        let base = sourceFPS > 0 ? sourceFPS : 30.0
        return max(0.05, base * playbackRate)
    }

    func advanceOneFrame() {
        let total = totalFrameCountForCurrentMode()
        guard total > 0 else { return }

        let elapsed = CACurrentMediaTime() - playbackStartTime
        let fps = effectivePlaybackFPS()
        let advancedFrames = Int(floor(elapsed * fps))
        let newIndex = (playbackStartIndex + advancedFrames) % total

        guard newIndex != currentIndex else { return }

        currentIndex = newIndex
        updateReferencePlaneOverlay()
        rebuildCurrentSlice()
        planeSliceRenderer?.requestRedraw()
        axisSliceRenderer?.requestRedraw()
    }

    // MARK: - Slice rebuild

    func rebuildCurrentSlice() {
        currentSliceCGImage = nil
        isSliceRendering = false
        isAxisCacheBuilding = false

        if let meshSlicePreviewCache {
            if isPlaying {
                currentSliceCGImage = nil
                if sliceMode == .axis && playbackAxis == .t {
                    updateSliceRendererForCurrentState()
                } else if sliceMode == .plane {
                    planeSliceRenderer?.requestRedraw()
                } else if sliceMode == .axis && (playbackAxis == .x || playbackAxis == .y) {
                    axisSliceRenderer?.requestRedraw()
                }
                return
            }

            guard sliceMode == .axis && playbackAxis == .t else {
                currentSliceCGImage = nil
                if sliceMode == .plane {
                    planeSliceRenderer?.requestRedraw()
                } else if sliceMode == .axis && (playbackAxis == .x || playbackAxis == .y) {
                    axisSliceRenderer?.requestRedraw()
                }
                return
            }

            let size = imageSizeForCurrentMode()
            currentSliceCGImage = MeshSliceRasterizer.makeCGImage(
                cache: meshSlicePreviewCache,
                mode: sliceMode,
                axis: playbackAxis,
                index: currentIndex,
                referencePlane: referencePlane,
                width: size.0,
                height: size.1,
                useAlpha: useAlpha,
                showCheckerboard: showCheckerboard,
                supersampleScale: meshSlicePreviewSupersampleScale
            )
            return
        }

        if isVideoVolumeModifierActive, sliceMode == .axis, playbackAxis == .t {
            updateSliceRendererForCurrentState()
        } else if sliceMode == .plane {
            planeSliceRenderer?.requestRedraw()
        } else if sliceMode == .axis && (playbackAxis == .x || playbackAxis == .y) {
            axisSliceRenderer?.requestRedraw()
        }
    }

    private func updateSliceRendererForCurrentState() {
        guard let sliceRenderer else { return }
        sliceRenderer.updateParams(
            sliceMode: sliceMode,
            playbackAxis: playbackAxis,
            currentIndex: currentIndex,
            showCheckerboard: showCheckerboard,
            useAlpha: useAlpha,
            referencePlane: referencePlane,
            fastPreview: isPlaying && useFastPreviewWhilePlaying
        )
        sliceRenderer.requestRedraw()
    }

    private var meshSlicePreviewSupersampleScale: Int {
        isPlaying ? 1 : 2
    }

    // MARK: - Visible frame scan

    nonisolated private static func findBestVisibleTIndex(volume: CPUVolume) -> Int {
        var bestIndex = 0
        var bestScore: Double = -1

        let stepX = max(1, volume.width / 128)
        let stepY = max(1, volume.height / 128)

        for t in 0..<volume.depth {
            var score: Double = 0
            var found = false

            var y = 0
            while y < volume.height {
                var x = 0
                while x < volume.width {
                    let (_, _, _, a) = volume.rgbaAt(t: t, y: y, x: x)
                    if a > 8 {
                        found = true
                        score += Double(a)
                    }
                    x += stepX
                }
                y += stepY
            }

            if found && score > bestScore {
                bestScore = score
                bestIndex = t
            }
        }

        return bestIndex
    }
}
