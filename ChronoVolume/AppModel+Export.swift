import Foundation
import AppKit
import AVFoundation

@MainActor
extension AppModel {
    private var exportCPUVolume: CPUVolume? {
        Mirror(reflecting: self).descendant("fullCPUVolume") as? CPUVolume
    }

    private var exportPreviewLoadedVolume: LoadedVolume? {
        Mirror(reflecting: self).descendant("pendingPreviewVolume") as? LoadedVolume
    }

    private var exportLoadedVolume: LoadedVolume? {
        Mirror(reflecting: self).descendant("fullLoadedVolume") as? LoadedVolume
    }

    private var exportMeshSurface: LoadedMesh? {
        Mirror(reflecting: self).descendant("fullMeshSurface") as? LoadedMesh
    }

    private var exportSourceURL: URL? {
        if let asset = player?.currentItem?.asset as? AVURLAsset {
            return asset.url
        }
        return nil
    }

    func highPrecisionCacheStatusText() -> String? {
        guard let pair = videoSourcePair else { return nil }

        let opaque = HighPrecisionCacheHelper.hasCache(for: pair, preserveAlpha: false)
        let alpha = HighPrecisionCacheHelper.hasCache(for: pair, preserveAlpha: true)

        let opaqueText = opaque ? "不带Alpha已建立" : "不带Alpha未建立"
        let alphaText = alpha ? "带Alpha已建立" : "带Alpha未建立"
        return "\(opaqueText)｜\(alphaText)"
    }

    func removeHighPrecisionCacheInteractively() {
        guard let pair = videoSourcePair else {
            status = "没有可用的源视频 URL，无法清理高精度缓存"
            return
        }

        HighPrecisionCacheHelper.removeCache(for: pair)
        status = "已清理当前视频的高精度缓存"
    }

    func buildHighPrecisionCacheInteractively(preserveAlpha: Bool) {
        guard let pair = videoSourcePair else {
            status = "没有可用的源视频 URL，无法建立高精度缓存"
            return
        }

        let label = preserveAlpha ? "建立高精度缓存（带 Alpha）" : "建立高精度缓存（不带 Alpha）"
        status = "\(label) 0%"
        let alphaSnapshot = highPrecisionAlphaVolume

        Task.detached(priority: .userInitiated) {
            do {
                _ = try await HighPrecisionCacheHelper.buildCache(
                    from: pair,
                    preserveAlpha: preserveAlpha,
                    highPrecisionAlpha: alphaSnapshot,
                    progress: { progress, text in
                        Task { @MainActor in
                            let pct = Int(progress * 100.0)
                            self.status = "\(text) \(pct)%"
                        }
                    }
                )
                let mergedSourceVolume = pair.alphaSourceMode == .external && preserveAlpha
                    ? try await HighPrecisionCacheHelper.loadMergedSourceCPUVolume(for: pair)
                    : nil

                await MainActor.run {
                    self.highPrecisionPairedCPUVolume = mergedSourceVolume
                    self.status = "\(label) 完成"
                }
            } catch {
                await MainActor.run {
                    self.status = "\(label) 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func buildHighPrecisionCacheAndExportInteractively(
        preserveAlpha: Bool,
        padToEven: Bool = true
    ) {
        guard exportSourceURL != nil, let pair = videoSourcePair else {
            status = "没有可用的源视频 URL，无法建立高精度缓存"
            return
        }

        if HighPrecisionCacheHelper.hasCache(for: pair, preserveAlpha: preserveAlpha) {
            if pair.alphaSourceMode == .external, preserveAlpha, highPrecisionPairedCPUVolume == nil {
                status = "正在读取源分辨率 Alpha sidecar…"
                Task.detached(priority: .userInitiated) {
                    do {
                        let merged = try await HighPrecisionCacheHelper.loadMergedSourceCPUVolume(for: pair)
                        await MainActor.run {
                            self.highPrecisionPairedCPUVolume = merged
                            self.exportCurrent2DVideoInteractively(
                                preserveAlpha: preserveAlpha,
                                qualityScale: 1,
                                padToEven: padToEven,
                                highPrecision: true,
                                colorProfile: self.sourceColorProfile
                            )
                        }
                    } catch {
                        await MainActor.run { self.status = "读取高精度 paired cache 失败：\(error.localizedDescription)" }
                    }
                }
                return
            }
            exportCurrent2DVideoInteractively(
                preserveAlpha: preserveAlpha,
                qualityScale: 1.0,
                padToEven: padToEven,
                highPrecision: true,
                colorProfile: sourceColorProfile
            )
            return
        }

        let label = preserveAlpha ? "建立缓存并高精度导出（带 Alpha）" : "建立缓存并高精度导出（不带 Alpha）"
        status = "\(label) 0%"
        let alphaSnapshot = highPrecisionAlphaVolume

        Task.detached(priority: .userInitiated) {
            do {
                _ = try await HighPrecisionCacheHelper.buildCache(
                    from: pair,
                    preserveAlpha: preserveAlpha,
                    highPrecisionAlpha: alphaSnapshot,
                    progress: { progress, text in
                        Task { @MainActor in
                            let pct = Int(progress * 100.0)
                            self.status = "\(text) \(pct)%"
                        }
                    }
                )
                let mergedSourceVolume = pair.alphaSourceMode == .external && preserveAlpha
                    ? try await HighPrecisionCacheHelper.loadMergedSourceCPUVolume(for: pair)
                    : nil

                await MainActor.run {
                    self.highPrecisionPairedCPUVolume = mergedSourceVolume
                    self.status = "\(label) 缓存完成，准备导出"
                    self.exportCurrent2DVideoInteractively(
                        preserveAlpha: preserveAlpha,
                        qualityScale: 1.0,
                        padToEven: padToEven,
                        highPrecision: true,
                        colorProfile: self.sourceColorProfile
                    )
                }
            } catch {
                await MainActor.run {
                    self.status = "\(label) 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func exportCurrent2DVideoInteractively(
        preserveAlpha: Bool,
        qualityScale: Double = 1.0,
        padToEven: Bool = true,
        highPrecision: Bool = false,
        bitDepth: Int = 8,
        colorProfile: VideoColorProfile = .rec709
    ) {
        guard let previewVolume = exportCPUVolume else {
            status = "没有可导出的 2D 数据"
            return
        }

        let usesExternalHighPrecision = highPrecision && preserveAlpha && videoSourcePair?.alphaSourceMode == .external
        if usesExternalHighPrecision, sourceBitDepth > 8 || sourceAlphaBitDepth > 8 {
            status = "当前 CPU/MOV paired-volume 导出只能无损承载 8-bit A_color + 8-bit B_alpha；源为颜色 \(sourceBitDepth)-bit / Alpha \(sourceAlphaBitDepth)-bit，已明确拒绝降位深。"
            return
        }
        if usesExternalHighPrecision, highPrecisionPairedCPUVolume == nil {
            status = "请先建立“带 Alpha”高精度缓存；导出将从源分辨率 UInt16 sidecar 构建 paired volume，不会使用 1024px 预览体。"
            return
        }
        let volume = usesExternalHighPrecision ? highPrecisionPairedCPUVolume! : previewVolume

        let sourceURL = exportSourceURL
        let usesModifiedVolumeTexture = isVideoVolumeModifierActive
        let modifiedSnapshot = usesModifiedVolumeTexture ? modifiedVideoVolumeExportSnapshot() : nil
        guard !usesModifiedVolumeTexture || modifiedSnapshot != nil else {
            status = "修改体尚未就绪，请等待体素修改器完成"
            return
        }
        let modifiedGPUTextureAvailable = modifiedSnapshot.map {
            modifiedVideoVolumeTextureIsAvailableForExport($0)
        } ?? false
        let exportMeshForSizing = exportMeshSurface
        let outputQualityScale = exportMeshForSizing == nil
            ? min(1.0, max(0.05, qualityScale))
            : min(4.0, max(0.05, qualityScale))
        let meshQualityScale = exportMeshForSizing == nil ? 1.0 : max(1.0, outputQualityScale)
        let canUseSourceHighPrecision = highPrecision && sourceURL != nil && !usesModifiedVolumeTexture && !usesExternalHighPrecision

        let highPrecisionPlaneMetrics = canUseSourceHighPrecision && sliceMode == .plane && distributedSourceWidth > 0 && distributedSourceHeight > 0 && sourceFrameCount > 0
            ? VideoExportHelper.highPrecisionPlaneOutputMetrics(
                sourceWidth: distributedSourceWidth,
                sourceHeight: distributedSourceHeight,
                sourceFrameCount: sourceFrameCount,
                referencePlane: referencePlane,
                qualityScale: outputQualityScale,
                padToEven: padToEven
            )
            : nil

        let baseFrameCount: Int = usesExternalHighPrecision ? {
            switch sliceMode {
            case .axis:
                switch playbackAxis {
                case .t: return volume.depth
                case .x: return volume.width
                case .y: return volume.height
                }
            case .plane:
                return volume.planeGeometry(for: referencePlane).sliceCount
            }
        }() : totalFrameCountForCurrentMode()
        let frameCount = highPrecisionPlaneMetrics?.sliceCount
            ?? max(baseFrameCount, Int((Double(baseFrameCount) * meshQualityScale).rounded()))
        guard frameCount > 0 else {
            status = "当前模式没有可导出的帧"
            return
        }

        let pairedSize: (Int, Int)? = usesExternalHighPrecision ? {
            switch sliceMode {
            case .axis:
                switch playbackAxis {
                case .t: return (volume.width, volume.height)
                case .x: return (volume.depth, volume.height)
                case .y: return (volume.width, volume.depth)
                }
            case .plane:
                let geometry = volume.planeGeometry(for: referencePlane)
                return (geometry.outWidth, geometry.outHeight)
            }
        }() : nil
        let size = highPrecisionPlaneMetrics.map { ($0.width, $0.height) } ?? pairedSize ?? imageSizeForCurrentMode()
        guard size.0 > 0, size.1 > 0 else {
            status = "当前模式尺寸无效，无法导出"
            return
        }

        let scaledWidth = highPrecisionPlaneMetrics?.width ?? max(1, Int((Double(size.0) * outputQualityScale).rounded()))
        let scaledHeight = highPrecisionPlaneMetrics?.height ?? max(1, Int((Double(size.1) * outputQualityScale).rounded()))

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.movie]

        let modeName: String
        switch sliceMode {
        case .axis:
            modeName = "axis_\(playbackAxis.rawValue)"
        case .plane:
            modeName = "plane"
        }

        let alphaSuffix = preserveAlpha ? "_alpha" : "_opaque"
        let scaleSuffix: String
        if outputQualityScale < 0.999 {
            scaleSuffix = "_\(Int((outputQualityScale * 100).rounded()))pct"
        } else if outputQualityScale > 1.001 {
            scaleSuffix = "_\(String(format: "%.1fx", outputQualityScale))"
        } else {
            scaleSuffix = "_full"
        }
        let sizeSuffix = padToEven ? "_even" : "_rawsize"
        let hpSuffix = highPrecision ? "_hp" : ""
        panel.nameFieldStringValue =
            "\(fileName.replacingOccurrences(of: ".", with: "_"))_\(modeName)\(alphaSuffix)\(scaleSuffix)\(sizeSuffix)\(hpSuffix).mov"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fpsBase = sourceFPS > 0 ? sourceFPS : 30.0
        let exportFPS = max(0.05, fpsBase * playbackRate)

        let exportMode = sliceMode
        let exportAxis = playbackAxis
        let exportShowCheckerboard = showCheckerboard
        let exportUseAlpha = useAlpha
        let exportReferencePlane = referencePlane
        let exportFrameCount = frameCount
        let exportURL = url
        let exportVolume = volume
        let exportPlaybackRate = playbackRate
        let exportSourceFrameCount = sourceFrameCount
        let exportBitDepth = max(8, bitDepth)
        let exportColorProfile = colorProfile
        let exportMesh = exportMeshForSizing
        let exportMeshSupersampleScale = exportMesh == nil ? 1 : 2
        let exportVolumeTextureCacheID = modifiedGPUTextureAvailable
            ? modifiedSnapshot?.currentLoadedVolume.textureCacheID
            : nil
        let exportNeedsModifiedCPUFallback = usesModifiedVolumeTexture && !modifiedGPUTextureAvailable

        let exportPair = videoSourcePair
        let cachedSourcePair: VideoSourcePair?
        let effectiveSourceURL: URL?
        if usesExternalHighPrecision {
            cachedSourcePair = exportPair
            effectiveSourceURL = nil
        } else if canUseSourceHighPrecision, sourceURL != nil, let pair = exportPair,
                  HighPrecisionCacheHelper.hasCache(for: pair, preserveAlpha: preserveAlpha) {
            cachedSourcePair = pair
            // hasCache is UI/presence-only. The URL is resolved only after the
            // asynchronous SHA-256 validation at export start.
            effectiveSourceURL = sourceURL
        } else {
            cachedSourcePair = nil
            effectiveSourceURL = sourceURL
        }

        let baseLabel: String
        if usesModifiedVolumeTexture {
            baseLabel = preserveAlpha ? "修改体导出（带 Alpha）" : "修改体导出"
        } else if highPrecision, !canUseSourceHighPrecision {
            baseLabel = preserveAlpha ? "模型体素导出（带 Alpha）" : "模型体素导出"
        } else if highPrecision {
            if preserveAlpha {
                baseLabel = "高精度导出（带 Alpha）"
            } else {
                baseLabel = "高精度导出（不带 Alpha）"
            }
        } else if preserveAlpha {
            baseLabel = qualityScale < 0.999 ? "带 Alpha 快速导出" : "带 Alpha 标准导出"
        } else {
            baseLabel = qualityScale < 0.999 ? "不带 Alpha 快速导出" : "不带 Alpha 标准导出"
        }

        let sourceHint = highPrecision && cachedSourcePair != nil ? " · 使用高精度缓存" : ""
        let label = padToEven ? "\(baseLabel)\(sourceHint)" : "\(baseLabel)\(sourceHint)（原始尺寸）"
        status = "\(label) 0%"

        Task.detached(priority: .userInitiated) {
            do {
                let validatedEffectiveSourceURL: URL?
                if let cachedSourcePair {
                    let validatedCache = try await HighPrecisionCacheHelper.validatedCacheURL(
                        for: cachedSourcePair,
                        preserveAlpha: preserveAlpha
                    )
                    validatedEffectiveSourceURL = usesExternalHighPrecision ? nil : validatedCache
                } else {
                    validatedEffectiveSourceURL = effectiveSourceURL
                }
                var requestVolume = exportVolume
                var requestVolumeTextureCacheID = exportVolumeTextureCacheID
                var requestUsesModifiedVolumeTexture = usesModifiedVolumeTexture && modifiedGPUTextureAvailable

                if exportNeedsModifiedCPUFallback {
                    guard let modifiedSnapshot else {
                        throw VideoExportError.metalUnavailable("修改体导出快照不可用")
                    }
                    await MainActor.run {
                        self.status = "\(label) · 正在按需生成修改体 CPU 兜底"
                    }

                    let materializedLoaded = VolumeModifierRasterizer.materializedCPUVolume(
                        from: modifiedSnapshot.currentLoadedVolume
                    ) ?? VolumeModifierRasterizer.applying(
                        modifiedSnapshot.modifiers,
                        to: modifiedSnapshot.baseLoadedVolume
                    )

                    requestVolume = CPUVolume(
                        width: materializedLoaded.width,
                        height: materializedLoaded.height,
                        depth: materializedLoaded.depth,
                        rgba: materializedLoaded.rgba,
                        hasMeaningfulAlpha: materializedLoaded.hasMeaningfulAlpha,
                        sourceColorProfile: materializedLoaded.sourceColorProfile
                    )
                    requestVolumeTextureCacheID = nil
                    requestUsesModifiedVolumeTexture = false

                    await MainActor.run {
                        self.installMaterializedModifiedVideoVolumeForExport(
                            materializedLoaded,
                            generation: modifiedSnapshot.generation
                        )
                        self.status = "\(label) · 修改体 CPU 兜底已就绪"
                    }
                }

                let request = VideoExportRequest(
                    url: exportURL,
                    width: scaledWidth,
                    height: scaledHeight,
                    fps: exportFPS,
                    frameCount: exportFrameCount,
                    mode: exportMode,
                    axis: exportAxis,
                    showCheckerboard: exportShowCheckerboard,
                    useAlpha: exportUseAlpha,
                    preserveAlpha: preserveAlpha,
                    padToEven: padToEven,
                    highPrecision: canUseSourceHighPrecision,
                    sourceFrameCount: exportSourceFrameCount,
                    playbackRate: exportPlaybackRate,
                    sourceURL: validatedEffectiveSourceURL,
                    referencePlane: exportReferencePlane,
                    bitDepth: exportBitDepth,
                    colorProfile: exportColorProfile,
                    mesh: exportMesh,
                    meshSupersampleScale: exportMeshSupersampleScale,
                    volumeTextureCacheID: requestVolumeTextureCacheID,
                    usesModifiedVolumeTexture: requestUsesModifiedVolumeTexture
                )

                try VideoExportHelper.export(
                    volume: requestVolume,
                    request: request,
                    progress: { progress, routeText in
                        Task { @MainActor in
                            let pct = Int(progress * 100.0)
                            if let routeText, !routeText.isEmpty {
                                self.status = "\(label) · \(routeText) \(pct)%"
                            } else {
                                self.status = "\(label) \(pct)%"
                            }
                        }
                    }
                )

                await MainActor.run {
                    self.status = "导出完成：\(exportURL.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    self.status = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func exportCameraVideoInteractively(
        preserveAlpha: Bool,
        padToEven: Bool = true,
        bitDepth: Int = 8,
        colorProfile: VideoColorProfile = .rec709,
        onExportStarted: (() -> Void)? = nil
    ) -> Bool {
        guard let volume = exportPreviewLoadedVolume else {
            status = "没有可导出的摄像机 3D 数据"
            return false
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.movie]
        let alphaSuffix = preserveAlpha ? "_alpha" : "_whitebg"
        panel.nameFieldStringValue =
            "\(fileName.replacingOccurrences(of: ".", with: "_"))_camera\(alphaSuffix).mov"

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "就绪"
            return false
        }

        let baseSize: (width: Int, height: Int)
        switch cameraExportSizeMode {
        case .preview:
            baseSize = (max(2, volume.width), max(2, volume.height))
        case .source:
            baseSize = (
                max(2, distributedSourceWidth > 0 ? distributedSourceWidth : volume.width),
                max(2, distributedSourceHeight > 0 ? distributedSourceHeight : volume.height)
            )
        case .custom:
            baseSize = (max(2, cameraExportCustomWidth), max(2, cameraExportCustomHeight))
        }
        let baseWidth = baseSize.width
        let baseHeight = baseSize.height
        let width = padToEven ? (baseWidth % 2 == 0 ? baseWidth : baseWidth + 1) : baseWidth
        let height = padToEven ? (baseHeight % 2 == 0 ? baseHeight : baseHeight + 1) : baseHeight
        let frameCount = max(1, cameraTimelineMaxFrame() + 1)
        let fps: Double
        switch cameraExportFPSMode {
        case .source:
            fps = sourceFPS > 0 ? sourceFPS : cameraTimelineFPS
        case .timeline:
            fps = cameraTimelineFPS
        case .custom:
            fps = cameraExportCustomFPS
        }
        let exportFPS = max(0.05, fps)

        let resolvedBackgroundMode: CameraExportBackgroundMode
        let resolvedBackgroundColor: VolumeBackgroundColor
        if preserveAlpha {
            resolvedBackgroundMode = .color
            resolvedBackgroundColor = VolumeBackgroundColor(red: 0, green: 0, blue: 0)
        } else {
            switch cameraExportBackgroundMode {
            case .white:
                resolvedBackgroundMode = .color
                resolvedBackgroundColor = VolumeBackgroundColor(red: 1, green: 1, blue: 1)
            case .current:
                resolvedBackgroundMode = volumeBackgroundMode == .checkerboard ? .checkerboard : .color
                resolvedBackgroundColor = volumeBackgroundColor
            case .color:
                resolvedBackgroundMode = .color
                resolvedBackgroundColor = cameraExportBackgroundColor
            case .checkerboard:
                resolvedBackgroundMode = .checkerboard
                resolvedBackgroundColor = cameraExportBackgroundColor
            }
        }

        let request = CameraVideoExportRequest(
            url: url,
            width: width,
            height: height,
            fps: exportFPS,
            frameCount: frameCount,
            volume: volume,
            volumeScale: volumeScaleForOverlay,
            volumeTransform: volumeTransform,
            keyframes: cameraKeyframes,
            fallbackCamera: cameraRig,
            functionDriver: cameraFunctionDriver,
            useAlphaVolume: useAlpha,
            useVoxelBlockRendering: useVoxelBlockRendering,
            smoothEdges: smoothVolumeEdges,
            preserveAlpha: preserveAlpha,
            backgroundMode: resolvedBackgroundMode,
            backgroundColor: resolvedBackgroundColor,
            steps: steps,
            density: Float(density),
            brightness: Float(brightness),
            bitDepth: max(8, bitDepth),
            colorProfile: colorProfile
        )

        let label = preserveAlpha ? "摄像机画面导出（带 Alpha）" : "摄像机画面导出（白色背景）"
        status = "\(label) 0%"
        onExportStarted?()

        Task.detached(priority: .userInitiated) {
            do {
                try CameraVideoExporter.export(request: request) { progress, routeText in
                    Task { @MainActor in
                        let pct = Int(progress * 100)
                        if let routeText {
                            self.status = "\(label) · \(routeText) \(pct)%"
                        } else {
                            self.status = "\(label) \(pct)%"
                        }
                    }
                }

                await MainActor.run {
                    self.status = "摄像机画面导出完成：\(url.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    self.status = "摄像机画面导出失败：\(error.localizedDescription)"
                }
            }
        }
        return true
    }
}
