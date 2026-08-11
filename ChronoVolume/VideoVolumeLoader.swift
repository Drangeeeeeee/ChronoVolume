import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import CoreGraphics
import ImageIO

struct LoadedVolume: Sendable {
    let width: Int
    let height: Int
    let depth: Int
    let textureCacheID: UUID
    let rgba: [UInt8]
    let hasMeaningfulAlpha: Bool

    let sourceFPS: Double
    let sourceDurationSeconds: Double
    let sourceFrameCountEstimate: Int
    var sourceColorProfile: VideoColorProfile = .rec709

    init(
        width: Int,
        height: Int,
        depth: Int,
        textureCacheID: UUID = UUID(),
        rgba: [UInt8],
        hasMeaningfulAlpha: Bool,
        sourceFPS: Double,
        sourceDurationSeconds: Double,
        sourceFrameCountEstimate: Int,
        sourceColorProfile: VideoColorProfile = .rec709
    ) {
        self.width = width
        self.height = height
        self.depth = depth
        self.textureCacheID = textureCacheID
        self.rgba = rgba
        self.hasMeaningfulAlpha = hasMeaningfulAlpha
        self.sourceFPS = sourceFPS
        self.sourceDurationSeconds = sourceDurationSeconds
        self.sourceFrameCountEstimate = sourceFrameCountEstimate
        self.sourceColorProfile = sourceColorProfile
    }
}

struct LoadedVideoPackage {
    let fullTemporalVolume: LoadedVolume
    let previewVolume: LoadedVolume

    let sourceFPS: Double
    let sourceDurationSeconds: Double
    let sourceFrameCount: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceBitDepth: Int
    let sourceColorProfile: VideoColorProfile
    var sourceAlphaBitDepth: Int = 8
    var previewAlphaBitDepth: Int = 8
    var colorMetadata: VideoSourceMetadata? = nil
    var alphaMetadata: VideoSourceMetadata? = nil
    var alphaSourceMode: AlphaSourceMode = .opaque
    var alphaSyncStatus: String = "单源"
    var highPrecisionAlphaVolume: HighPrecisionAlphaVolume? = nil
}

enum VideoVolumeAllocationStage: String, Sendable {
    case colorFrameAccumulation
    case alphaFrameAccumulation
    case mergedFrameAccumulation
    case fullTemporalVolume
    case fullTemporalVolumeAllocated
    case highPrecisionAlphaSamples
    case highPrecisionAlphaSamplesAllocated
    case alphaSidecarDataMapped
    case alphaSidecarSamplesAllocated
}

struct VideoVolumeMemoryBudget: @unchecked Sendable {
    let maxPeakBytes: UInt64
    let bytesPerVoxel: UInt64
    let allocationObserver: (@Sendable (VideoVolumeAllocationStage) -> Void)?

    init(
        maxPeakBytes: UInt64,
        bytesPerVoxel: UInt64 = 24,
        allocationObserver: (@Sendable (VideoVolumeAllocationStage) -> Void)? = nil
    ) {
        self.maxPeakBytes = maxPeakBytes
        self.bytesPerVoxel = bytesPerVoxel
        self.allocationObserver = allocationObserver
    }

    func validate(width: Int, height: Int, frameCount: Int, stage: VideoVolumeAllocationStage) throws {
        guard width > 0, height > 0, frameCount > 0 else { return }
        let pixels = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        let voxels = pixels.partialValue.multipliedReportingOverflow(by: UInt64(frameCount))
        let bytes = voxels.partialValue.multipliedReportingOverflow(by: bytesPerVoxel)
        guard !pixels.overflow, !voxels.overflow, !bytes.overflow else {
            throw VideoVolumeLoaderError.memoryBudgetExceeded("\(stage.rawValue) 内存计算溢出")
        }
        guard bytes.partialValue <= maxPeakBytes else {
            throw VideoVolumeLoaderError.memoryBudgetExceeded(
                "\(stage.rawValue) 在 \(width)×\(height)×\(frameCount) 需要预计峰值 \(bytes.partialValue) bytes，预算仅 \(maxPeakBytes) bytes；已在数组扩容/体数据打包前拒绝"
            )
        }
    }

    func record(_ stage: VideoVolumeAllocationStage) {
        allocationObserver?(stage)
    }
}

private struct DecodedFrameSet {
    let frames: [[UInt8]]
    let presentationTimes: [Double]
    let hasRealPresentationTimes: Bool
    let meaningfulAlpha: Bool
}

private struct DecodedAlphaFrameSet {
    let frames: [[UInt16]]
    let presentationTimes: [Double]
    let hasRealPresentationTimes: Bool
    let decodedBitDepth: Int
    let sourceBitDepth: Int
    let resolvedRange: ExternalAlphaRange
    let allowsRangeOverride: Bool
    let metadata: VideoSourceMetadata
}

enum VideoVolumeLoaderError: LocalizedError {
    case noVideoTrack
    case cannotAddReaderOutput
    case cannotStartReader(String)
    case readerFailed(String)
    case noFrames
    case imageGeneratorFailed(String)
    case externalAlpha(String)
    case memoryBudgetExceeded(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "没有找到视频轨道"
        case .cannotAddReaderOutput:
            return "AVAssetReader 无法添加输出"
        case .cannotStartReader(let reason):
            return "AVAssetReader 启动失败：\(reason)"
        case .readerFailed(let reason):
            return "AVAssetReader 读取失败：\(reason)"
        case .noFrames:
            return "没有读取到任何视频帧"
        case .imageGeneratorFailed(let reason):
            return "AVAssetImageGenerator/ffmpeg 读取失败：\(reason)"
        case .externalAlpha(let reason):
            return "B_alpha 读取失败：\(reason)"
        case .memoryBudgetExceeded(let reason):
            return "双源体内存预算不足：\(reason)"
        }
    }
}

enum VideoVolumeLoader {
    static func loadHighPrecisionExternalAlpha(
        colorURL: URL,
        alphaURL: URL,
        settings: ExternalAlphaSettings,
        memoryBudget: VideoVolumeMemoryBudget? = nil
    ) async throws -> HighPrecisionAlphaVolume {
        let colorAsset = AVURLAsset(url: colorURL)
        guard let colorTrack = try await colorAsset.loadTracks(withMediaType: .video).first else {
            throw VideoVolumeLoaderError.noVideoTrack
        }
        let naturalSize = try await colorTrack.load(.naturalSize)
        let transform = try await colorTrack.load(.preferredTransform)
        let displaySize = orientedDisplaySize(naturalSize: naturalSize, preferredTransform: transform)
        let duration = max(0, CMTimeGetSeconds(try await colorAsset.load(.duration)))
        let fps = Double(try await colorTrack.load(.nominalFrameRate))
        let colorTimes = try realPresentationTimes(asset: colorAsset, track: colorTrack)
        guard !colorTimes.isEmpty else { throw ExternalAlphaError.noTimestamp }
        let colorMetadata = try await metadata(
            url: colorURL,
            asset: colorAsset,
            track: colorTrack,
            decodedFrameCount: colorTimes.count,
            fallbackBitDepth: SourceBitDepthDetector.detect(from: colorTrack)
        )
        let alpha = try decodeExternalAlpha(
            url: alphaURL,
            targetDisplayWidth: displaySize.width,
            targetDisplayHeight: displaySize.height,
            targetDecodeWidth: displaySize.width,
            targetDecodeHeight: displaySize.height,
            settings: settings,
            memoryBudget: memoryBudget
        )
        try ExternalAlphaCompatibilityValidator.validateDimensions(
            color: colorMetadata,
            alpha: alpha.metadata,
            policy: settings.resizePolicy
        )
        let matches = try ExternalAlphaFrameSynchronizer.matches(
            colorTimes: colorTimes,
            alphaTimes: alpha.presentationTimes,
            policy: settings.syncPolicy,
            colorFPS: fps,
            alphaFPS: alpha.metadata.fps,
            colorDuration: duration,
            alphaDuration: alpha.metadata.durationSeconds,
            colorTimeBase: colorMetadata.timeBase,
            alphaTimeBase: alpha.metadata.timeBase,
            colorHasRealPTS: true,
            alphaHasRealPTS: alpha.hasRealPresentationTimes
        )
        try memoryBudget?.validate(
            width: displaySize.width,
            height: displaySize.height,
            frameCount: matches.count,
            stage: .highPrecisionAlphaSamples
        )
        let range = alpha.allowsRangeOverride
            ? (settings.range == .auto ? alpha.resolvedRange : settings.range)
            : .full
        let sampleCapacity = try checkedDimensionProduct(
            [displaySize.width, displaySize.height, matches.count],
            context: "high-precision Alpha samples"
        )
        var samples: [UInt16] = []
        samples.reserveCapacity(sampleCapacity)
        memoryBudget?.record(.highPrecisionAlphaSamplesAllocated)
        for match in matches {
            let frame0 = alpha.frames[match.alpha0]
            let frame1 = alpha.frames[match.alpha1]
            for index in frame0.indices {
                let raw: UInt16
                if match.alpha0 == match.alpha1 {
                    raw = frame0[index]
                } else {
                    raw = UInt16(min(65535, max(0, Int((Double(frame0[index]) + (Double(frame1[index]) - Double(frame0[index])) * match.fraction).rounded()))))
                }
                samples.append(try ExternalAlphaNormalizer.highPrecisionUInt16(
                    codeValue: raw,
                    bitDepth: alpha.decodedBitDepth,
                    range: range,
                    invert: settings.invert
                ))
            }
        }
        return HighPrecisionAlphaVolume(
            width: displaySize.width,
            height: displaySize.height,
            depth: matches.count,
            samples: samples,
            sourceBitDepth: alpha.sourceBitDepth,
            sourceRange: range,
            presentationTimes: matches.map { colorTimes[$0.color] }
        )
    }

    static func load(
        colorURL: URL,
        alphaURL: URL?,
        settings: ExternalAlphaSettings,
        generatedWhiteColor: Bool = false,
        maxWidth: Int = 1024,
        maxHeight: Int = 1024,
        previewMaxDepth: Int = 256,
        memoryBudget: VideoVolumeMemoryBudget? = nil
    ) async throws -> LoadedVideoPackage {
        if generatedWhiteColor {
            guard let alphaURL else {
                throw VideoVolumeLoaderError.externalAlpha("B_alpha 白模缺少 B_alpha URL")
            }
            return try loadGeneratedWhiteAlpha(
                alphaURL: alphaURL,
                settings: settings,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                previewMaxDepth: previewMaxDepth,
                memoryBudget: memoryBudget
            )
        }
        guard let alphaURL else {
            return try await load(
                url: colorURL,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                previewMaxDepth: previewMaxDepth
            )
        }

        let colorAsset = AVURLAsset(url: colorURL)
        guard let colorTrack = try await colorAsset.loadTracks(withMediaType: .video).first else {
            throw VideoVolumeLoaderError.noVideoTrack
        }
        let naturalSize = try await colorTrack.load(.naturalSize)
        let preferredTransform = try await colorTrack.load(.preferredTransform)
        let displaySize = orientedDisplaySize(naturalSize: naturalSize, preferredTransform: preferredTransform)
        let targetSize = fitInside(
            width: displaySize.width,
            height: displaySize.height,
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )
        let duration = try await colorAsset.load(.duration)
        let durationSeconds = max(0, CMTimeGetSeconds(duration))
        let nominalFPS = try await colorTrack.load(.nominalFrameRate)
        let sourceFPS = nominalFPS > 0 ? Double(nominalFPS) : 0
        let sourceBitDepth = SourceBitDepthDetector.detect(from: colorTrack)
        let sourceColorProfile = SourceColorProfileDetector.detect(from: colorTrack)
        let estimatedFrameCount = estimateFrameCount(fps: sourceFPS, durationSeconds: durationSeconds)

        let colorDecoded = try decodeFrames(
            asset: colorAsset,
            track: colorTrack,
            url: colorURL,
            targetWidth: targetSize.width,
            targetHeight: targetSize.height,
            preferredTransform: preferredTransform,
            durationSeconds: durationSeconds,
            sourceFPS: sourceFPS,
            estimatedFrameCount: estimatedFrameCount,
            sourceColorProfile: sourceColorProfile,
            repairPremultipliedEdges: false,
            forceOpaqueAlpha: true,
            memoryBudget: memoryBudget
        )
        let colorMetadata = try await metadata(
            url: colorURL,
            asset: colorAsset,
            track: colorTrack,
            decodedFrameCount: colorDecoded.frames.count,
            fallbackBitDepth: sourceBitDepth
        )
        let alphaDecoded = try decodeExternalAlpha(
            url: alphaURL,
            targetDisplayWidth: displaySize.width,
            targetDisplayHeight: displaySize.height,
            targetDecodeWidth: targetSize.width,
            targetDecodeHeight: targetSize.height,
            settings: settings,
            memoryBudget: memoryBudget
        )

        try ExternalAlphaCompatibilityValidator.validateDimensions(
            color: colorMetadata,
            alpha: alphaDecoded.metadata,
            policy: settings.resizePolicy
        )

        let pairs = try ExternalAlphaFrameSynchronizer.matches(
            colorTimes: colorDecoded.presentationTimes,
            alphaTimes: alphaDecoded.presentationTimes,
            policy: settings.syncPolicy,
            colorFPS: colorMetadata.fps,
            alphaFPS: alphaDecoded.metadata.fps,
            colorDuration: colorMetadata.durationSeconds,
            alphaDuration: alphaDecoded.metadata.durationSeconds,
            colorTimeBase: colorMetadata.timeBase,
            alphaTimeBase: alphaDecoded.metadata.timeBase,
            colorHasRealPTS: colorDecoded.hasRealPresentationTimes,
            alphaHasRealPTS: alphaDecoded.hasRealPresentationTimes
        )

        let resolvedRange = alphaDecoded.allowsRangeOverride
            ? (settings.range == .auto ? alphaDecoded.resolvedRange : settings.range)
            : .full
        try memoryBudget?.validate(
            width: targetSize.width,
            height: targetSize.height,
            frameCount: pairs.count,
            stage: .mergedFrameAccumulation
        )
        var mergedFrames: [[UInt8]] = []
        var highPrecisionSamples: [UInt16] = []
        var mergedTimes: [Double] = []
        mergedFrames.reserveCapacity(pairs.count)
        highPrecisionSamples.reserveCapacity(try checkedDimensionProduct(
            [targetSize.width, targetSize.height, pairs.count],
            context: "paired high-precision Alpha samples"
        ))
        mergedTimes.reserveCapacity(pairs.count)
        var unrecoverablePremultipliedPixels = 0
        let generatedWhiteFrame: [UInt8]?
        if generatedWhiteColor {
            let byteCount = try checkedDimensionProduct(
                [targetSize.width, targetSize.height, 4],
                context: "generated white A_color frame"
            )
            generatedWhiteFrame = [UInt8](repeating: 255, count: byteCount)
        } else {
            generatedWhiteFrame = nil
        }

        for pair in pairs {
            let sourceColorFrame = generatedWhiteFrame ?? colorDecoded.frames[pair.color]
            let alphaFrame0 = alphaDecoded.frames[pair.alpha0]
            let alphaFrame: [UInt16]
            if pair.alpha0 == pair.alpha1 || pair.fraction <= 0 {
                alphaFrame = alphaFrame0
            } else {
                let alphaFrame1 = alphaDecoded.frames[pair.alpha1]
                alphaFrame = zip(alphaFrame0, alphaFrame1).map { lhs, rhs in
                    UInt16(min(65535, max(0, Int((Double(lhs) + (Double(rhs) - Double(lhs)) * pair.fraction).rounded()))))
                }
            }
            let pixelCount = try checkedDimensionProduct(
                [targetSize.width, targetSize.height],
                context: "paired frame pixels"
            )
            guard alphaFrame.count == pixelCount else {
                throw VideoVolumeLoaderError.externalAlpha(
                    "规范化后像素数不一致：A_color 每帧 \(pixelCount)，B_alpha 每帧 \(alphaFrame.count)"
                )
            }
            var colorFrame = try ExternalAlphaMerger.mergePreview(
                colorRGBA: sourceColorFrame,
                alphaCodeValues: alphaFrame,
                bitDepth: alphaDecoded.decodedBitDepth,
                range: resolvedRange,
                invert: settings.invert
            )
            var highPrecisionFrame: [UInt16] = []
            highPrecisionFrame.reserveCapacity(pixelCount)
            for pixel in 0..<pixelCount {
                let raw = alphaFrame[pixel]
                let high = try ExternalAlphaNormalizer.highPrecisionUInt16(
                    codeValue: raw,
                    bitDepth: alphaDecoded.decodedBitDepth,
                    range: resolvedRange,
                    invert: settings.invert
                )
                highPrecisionFrame.append(high)
            }
            if settings.association == .premultiplied, !generatedWhiteColor {
                unrecoverablePremultipliedPixels += ExternalAlphaMerger.unpremultiplyRGB(
                    rgba: &colorFrame,
                    normalizedAlpha: highPrecisionFrame
                )
            }
            highPrecisionSamples.append(contentsOf: highPrecisionFrame)
            mergedFrames.append(colorFrame)
            mergedTimes.append(colorDecoded.presentationTimes[pair.color])
        }

        let actualFrameCount = mergedFrames.count
        guard actualFrameCount > 0 else { throw VideoVolumeLoaderError.noFrames }
        let spatialScale = computeSpatialScale(
            srcW: displaySize.width,
            srcH: displaySize.height,
            targetW: targetSize.width,
            targetH: targetSize.height
        )
        let scaledDepth = max(1, min(actualFrameCount, Int((Double(actualFrameCount) * spatialScale).rounded())))
        let scaledIndices = depthSampleIndices(count: actualFrameCount, maxDepth: scaledDepth)
        let scaledFrames = scaledIndices.map { mergedFrames[$0] }
        let previewDepth = max(1, min(scaledDepth, previewMaxDepth))
        let previewIndices = depthSampleIndices(count: scaledFrames.count, maxDepth: previewDepth)
        let previewFrames = previewIndices.map { scaledFrames[$0] }

        let fullTemporalVolume = try packFramesToVolume(
            scaledFrames,
            width: targetSize.width,
            height: targetSize.height,
            meaningfulAlpha: true,
            sourceFPS: sourceFPS,
            durationSeconds: durationSeconds,
            sourceFrameCount: actualFrameCount,
            sourceColorProfile: sourceColorProfile,
            memoryBudget: memoryBudget,
            allocationStage: .fullTemporalVolume
        )
        let previewVolume = try packFramesToVolume(
            previewFrames,
            width: targetSize.width,
            height: targetSize.height,
            meaningfulAlpha: true,
            sourceFPS: sourceFPS,
            durationSeconds: durationSeconds,
            sourceFrameCount: actualFrameCount,
            sourceColorProfile: sourceColorProfile,
            memoryBudget: nil,
            allocationStage: .fullTemporalVolume
        )

        return LoadedVideoPackage(
            fullTemporalVolume: fullTemporalVolume,
            previewVolume: previewVolume,
            sourceFPS: sourceFPS,
            sourceDurationSeconds: durationSeconds,
            sourceFrameCount: actualFrameCount,
            sourceWidth: displaySize.width,
            sourceHeight: displaySize.height,
            sourceBitDepth: generatedWhiteColor ? 8 : sourceBitDepth,
            sourceColorProfile: generatedWhiteColor ? .rec709 : sourceColorProfile,
            sourceAlphaBitDepth: alphaDecoded.sourceBitDepth,
            previewAlphaBitDepth: 8,
            colorMetadata: colorMetadata,
            alphaMetadata: alphaDecoded.metadata,
            alphaSourceMode: .external,
            alphaSyncStatus: {
                let base = settings.syncPolicy == .strict
                    ? "严格 PTS 对齐通过（\(actualFrameCount) 帧；time_base 仅诊断）"
                    : "已按显式策略 \(settings.syncPolicy.rawValue) 对齐（\(actualFrameCount) 帧）"
                if generatedWhiteColor {
                    return base + "；A_color 未提供，已生成未预乘白色 RGB 白模"
                }
                if settings.association == .premultiplied, unrecoverablePremultipliedPixels > 0 {
                    return base + "；Alpha=0 的 \(unrecoverablePremultipliedPixels) 个像素无法反预乘，保留源 RGB"
                }
                return base
            }(),
            highPrecisionAlphaVolume: HighPrecisionAlphaVolume(
                width: targetSize.width,
                height: targetSize.height,
                depth: actualFrameCount,
                samples: highPrecisionSamples,
                sourceBitDepth: alphaDecoded.sourceBitDepth,
                sourceRange: resolvedRange,
                presentationTimes: mergedTimes
            )
        )
    }

    private static func loadGeneratedWhiteAlpha(
        alphaURL: URL,
        settings: ExternalAlphaSettings,
        maxWidth: Int,
        maxHeight: Int,
        previewMaxDepth: Int,
        memoryBudget: VideoVolumeMemoryBudget?
    ) throws -> LoadedVideoPackage {
        let probe = try ffprobe(url: alphaURL)
        let metadata = probe.metadata
        let displaySize = (width: metadata.displayWidth, height: metadata.displayHeight)
        let targetSize = fitInside(
            width: displaySize.width,
            height: displaySize.height,
            maxWidth: maxWidth,
            maxHeight: maxHeight
        )
        let alphaDecoded = try decodeExternalAlpha(
            url: alphaURL,
            targetDisplayWidth: displaySize.width,
            targetDisplayHeight: displaySize.height,
            targetDecodeWidth: targetSize.width,
            targetDecodeHeight: targetSize.height,
            settings: settings,
            memoryBudget: memoryBudget
        )
        let frameCount = alphaDecoded.frames.count
        guard frameCount > 0 else { throw VideoVolumeLoaderError.noFrames }
        try memoryBudget?.validate(
            width: targetSize.width,
            height: targetSize.height,
            frameCount: frameCount,
            stage: .mergedFrameAccumulation
        )
        let pixelCount = try checkedDimensionProduct(
            [targetSize.width, targetSize.height],
            context: "generated white paired frame pixels"
        )
        let whiteFrame = [UInt8](repeating: 255, count: try checkedDimensionProduct(
            [pixelCount, 4],
            context: "generated white paired frame RGBA"
        ))
        let resolvedRange = alphaDecoded.allowsRangeOverride
            ? (settings.range == .auto ? alphaDecoded.resolvedRange : settings.range)
            : .full
        var mergedFrames: [[UInt8]] = []
        var highPrecisionSamples: [UInt16] = []
        mergedFrames.reserveCapacity(frameCount)
        highPrecisionSamples.reserveCapacity(try checkedDimensionProduct(
            [pixelCount, frameCount],
            context: "generated white high-precision Alpha samples"
        ))
        for alphaFrame in alphaDecoded.frames {
            guard alphaFrame.count == pixelCount else {
                throw VideoVolumeLoaderError.externalAlpha(
                    "白模像素数不一致：预期每帧 \(pixelCount)，B_alpha 为 \(alphaFrame.count)"
                )
            }
            mergedFrames.append(try ExternalAlphaMerger.mergePreview(
                colorRGBA: whiteFrame,
                alphaCodeValues: alphaFrame,
                bitDepth: alphaDecoded.decodedBitDepth,
                range: resolvedRange,
                invert: settings.invert
            ))
            for raw in alphaFrame {
                highPrecisionSamples.append(try ExternalAlphaNormalizer.highPrecisionUInt16(
                    codeValue: raw,
                    bitDepth: alphaDecoded.decodedBitDepth,
                    range: resolvedRange,
                    invert: settings.invert
                ))
            }
        }

        let spatialScale = computeSpatialScale(
            srcW: displaySize.width,
            srcH: displaySize.height,
            targetW: targetSize.width,
            targetH: targetSize.height
        )
        let scaledDepth = max(1, min(frameCount, Int((Double(frameCount) * spatialScale).rounded())))
        let scaledIndices = depthSampleIndices(count: frameCount, maxDepth: scaledDepth)
        let scaledFrames = scaledIndices.map { mergedFrames[$0] }
        let previewDepth = max(1, min(scaledDepth, previewMaxDepth))
        let previewIndices = depthSampleIndices(count: scaledFrames.count, maxDepth: previewDepth)
        let previewFrames = previewIndices.map { scaledFrames[$0] }
        let sourceFPS = metadata.fps
        let durationSeconds = metadata.durationSeconds
        let fullTemporalVolume = try packFramesToVolume(
            scaledFrames,
            width: targetSize.width,
            height: targetSize.height,
            meaningfulAlpha: true,
            sourceFPS: sourceFPS,
            durationSeconds: durationSeconds,
            sourceFrameCount: frameCount,
            sourceColorProfile: .rec709,
            memoryBudget: memoryBudget,
            allocationStage: .fullTemporalVolume
        )
        let previewVolume = try packFramesToVolume(
            previewFrames,
            width: targetSize.width,
            height: targetSize.height,
            meaningfulAlpha: true,
            sourceFPS: sourceFPS,
            durationSeconds: durationSeconds,
            sourceFrameCount: frameCount,
            sourceColorProfile: .rec709
        )
        return LoadedVideoPackage(
            fullTemporalVolume: fullTemporalVolume,
            previewVolume: previewVolume,
            sourceFPS: sourceFPS,
            sourceDurationSeconds: durationSeconds,
            sourceFrameCount: frameCount,
            sourceWidth: displaySize.width,
            sourceHeight: displaySize.height,
            sourceBitDepth: 8,
            sourceColorProfile: .rec709,
            sourceAlphaBitDepth: alphaDecoded.sourceBitDepth,
            previewAlphaBitDepth: 8,
            colorMetadata: nil,
            alphaMetadata: metadata,
            alphaSourceMode: .external,
            alphaSyncStatus: "B_alpha 单源 PTS 时间线（\(frameCount) 帧）；A_color 未提供，已生成未预乘白色 RGB 白模",
            highPrecisionAlphaVolume: HighPrecisionAlphaVolume(
                width: targetSize.width,
                height: targetSize.height,
                depth: frameCount,
                samples: highPrecisionSamples,
                sourceBitDepth: alphaDecoded.sourceBitDepth,
                sourceRange: resolvedRange,
                presentationTimes: alphaDecoded.presentationTimes
            )
        )
    }

    static func load(
        url: URL,
        maxWidth: Int = 1024,
        maxHeight: Int = 1024,
        previewMaxDepth: Int = 256
    ) async throws -> LoadedVideoPackage {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw VideoVolumeLoaderError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let displaySize = orientedDisplaySize(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        let srcW = displaySize.width
        let srcH = displaySize.height
        let targetSize = fitInside(width: srcW, height: srcH, maxWidth: maxWidth, maxHeight: maxHeight)

        let duration = try await asset.load(.duration)
        let durationSeconds = max(0.0, CMTimeGetSeconds(duration))

        let nominalFPS = try await track.load(.nominalFrameRate)
        let sourceFPS = nominalFPS > 0 ? Double(nominalFPS) : 0.0
        let sourceBitDepth = SourceBitDepthDetector.detect(from: track)
        let sourceColorProfile = SourceColorProfileDetector.detect(from: track)

        let estimatedFrameCount = estimateFrameCount(
            fps: sourceFPS,
            durationSeconds: durationSeconds
        )

        let decoded = try decodeFrames(
            asset: asset,
            track: track,
            url: url,
            targetWidth: targetSize.width,
            targetHeight: targetSize.height,
            preferredTransform: preferredTransform,
            durationSeconds: durationSeconds,
            sourceFPS: sourceFPS,
            estimatedFrameCount: estimatedFrameCount,
            sourceColorProfile: sourceColorProfile
        )

        let actualFrameCount = max(1, decoded.frames.count)
        let spatialScale = computeSpatialScale(
            srcW: srcW,
            srcH: srcH,
            targetW: targetSize.width,
            targetH: targetSize.height
        )

        // 关键逻辑：时间轴也按空间同比缩放
        let scaledDepthDouble = Double(actualFrameCount) * spatialScale
        let scaledDepthRounded = Int(scaledDepthDouble.rounded())
        let scaledDepth = max(1, min(actualFrameCount, scaledDepthRounded))

        let scaledFrames = depthSample(decoded.frames, maxDepth: scaledDepth)
        let previewDepth = max(1, min(scaledDepth, previewMaxDepth))
        let previewFrames = depthSample(scaledFrames, maxDepth: previewDepth)

        let fullTemporalVolume = try packFramesToVolume(
            scaledFrames,
            width: targetSize.width,
            height: targetSize.height,
            meaningfulAlpha: decoded.meaningfulAlpha,
            sourceFPS: sourceFPS,
            durationSeconds: durationSeconds,
            sourceFrameCount: actualFrameCount,
            sourceColorProfile: sourceColorProfile
        )

        let previewVolume = try packFramesToVolume(
            previewFrames,
            width: targetSize.width,
            height: targetSize.height,
            meaningfulAlpha: decoded.meaningfulAlpha,
            sourceFPS: sourceFPS,
            durationSeconds: durationSeconds,
            sourceFrameCount: actualFrameCount,
            sourceColorProfile: sourceColorProfile
        )

        let sourceMetadata = try? await metadata(
            url: url,
            asset: asset,
            track: track,
            decodedFrameCount: actualFrameCount,
            fallbackBitDepth: sourceBitDepth
        )
        return LoadedVideoPackage(
            fullTemporalVolume: fullTemporalVolume,
            previewVolume: previewVolume,
            sourceFPS: sourceFPS,
            sourceDurationSeconds: durationSeconds,
            sourceFrameCount: actualFrameCount,
            sourceWidth: srcW,
            sourceHeight: srcH,
            sourceBitDepth: sourceBitDepth,
            sourceColorProfile: sourceColorProfile,
            sourceAlphaBitDepth: sourceMetadata?.hasEmbeddedAlpha == true ? sourceBitDepth : 8,
            previewAlphaBitDepth: 8,
            colorMetadata: sourceMetadata,
            alphaMetadata: nil,
            alphaSourceMode: decoded.meaningfulAlpha ? .embedded : .opaque,
            alphaSyncStatus: "单源"
        )
    }

    private static func estimateFrameCount(
        fps: Double,
        durationSeconds: Double
    ) -> Int {
        guard fps > 0, durationSeconds > 0 else { return 1 }
        let count = Int((fps * durationSeconds).rounded())
        return max(1, count)
    }

    private static func realPresentationTimes(asset: AVAsset, track: AVAssetTrack) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        // Read decoded video frames, not compressed track samples.  A codec may expose
        // codec/config or edit-list samples that do not correspond one-for-one with
        // renderable frames; the external-alpha timeline must match the frames that
        // will actually become volume slices.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoVolumeLoaderError.cannotAddReaderOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoVolumeLoaderError.cannotStartReader(reader.error?.localizedDescription ?? "未知原因")
        }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if time.isFinite { times.append(time) }
        }
        if reader.status == .failed {
            throw VideoVolumeLoaderError.readerFailed(reader.error?.localizedDescription ?? "未知原因")
        }
        return times
    }

    private static func computeSpatialScale(
        srcW: Int,
        srcH: Int,
        targetW: Int,
        targetH: Int
    ) -> Double {
        let scaleW = Double(targetW) / Double(max(1, srcW))
        let scaleH = Double(targetH) / Double(max(1, srcH))
        return min(1.0, min(scaleW, scaleH))
    }

    private static func decodeFrames(
        asset: AVAsset,
        track: AVAssetTrack,
        url: URL,
        targetWidth: Int,
        targetHeight: Int,
        preferredTransform: CGAffineTransform,
        durationSeconds: Double,
        sourceFPS: Double,
        estimatedFrameCount: Int,
        sourceColorProfile: VideoColorProfile,
        repairPremultipliedEdges: Bool = true,
        forceOpaqueAlpha: Bool = false,
        memoryBudget: VideoVolumeMemoryBudget? = nil
    ) throws -> DecodedFrameSet {
        do {
            return try decodeWithAssetReader(
                asset: asset,
                track: track,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                preferredTransform: preferredTransform,
                sourceColorProfile: sourceColorProfile,
                repairPremultipliedEdges: repairPremultipliedEdges,
                forceOpaqueAlpha: forceOpaqueAlpha,
                memoryBudget: memoryBudget
            )
        } catch {
            if case VideoVolumeLoaderError.memoryBudgetExceeded = error { throw error }
            let readerError = error.localizedDescription

            do {
                return try decodeWithImageGenerator(
                    asset: asset,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    durationSeconds: durationSeconds,
                    sourceFPS: sourceFPS,
                    estimatedFrameCount: estimatedFrameCount,
                    sourceColorProfile: sourceColorProfile,
                    repairPremultipliedEdges: repairPremultipliedEdges,
                    forceOpaqueAlpha: forceOpaqueAlpha,
                    memoryBudget: memoryBudget
                )
            } catch {
                if case VideoVolumeLoaderError.memoryBudgetExceeded = error { throw error }
                let imageGenError = error.localizedDescription

                do {
                    return try decodeWithFFmpeg(
                        url: url,
                        targetWidth: targetWidth,
                        targetHeight: targetHeight,
                        sourceColorProfile: sourceColorProfile,
                        repairPremultipliedEdges: repairPremultipliedEdges,
                        forceOpaqueAlpha: forceOpaqueAlpha,
                        sourceFPS: sourceFPS,
                        memoryBudget: memoryBudget
                    )
                } catch {
                    let ffmpegError = error.localizedDescription
                    let message = "AVAssetReader 失败：\(readerError)；AVAssetImageGenerator 失败：\(imageGenError)；ffmpeg 失败：\(ffmpegError)"
                    throw VideoVolumeLoaderError.imageGeneratorFailed(message)
                }
            }
        }
    }

    private static func decodeWithAssetReader(
        asset: AVAsset,
        track: AVAssetTrack,
        targetWidth: Int,
        targetHeight: Int,
        preferredTransform: CGAffineTransform,
        sourceColorProfile: VideoColorProfile,
        repairPremultipliedEdges: Bool,
        forceOpaqueAlpha: Bool,
        memoryBudget: VideoVolumeMemoryBudget?
    ) throws -> DecodedFrameSet {
        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw VideoVolumeLoaderError.cannotAddReaderOutput
        }

        reader.add(output)

        guard reader.startReading() else {
            let message = reader.error?.localizedDescription ?? "未知原因"
            throw VideoVolumeLoaderError.cannotStartReader(message)
        }

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        var frames: [[UInt8]] = []
        var presentationTimes: [Double] = []
        var meaningfulAlpha = false

        while let sample = output.copyNextSampleBuffer(),
              let imageBuffer = CMSampleBufferGetImageBuffer(sample) {
            try memoryBudget?.validate(
                width: targetWidth,
                height: targetHeight,
                frameCount: frames.count + 1,
                stage: .colorFrameAccumulation
            )
            autoreleasepool {
                guard var rgba = renderPixelBufferToRGBA8(
                    pixelBuffer: imageBuffer,
                    width: targetWidth,
                    height: targetHeight,
                    preferredTransform: preferredTransform,
                    ciContext: ciContext,
                    colorSpace: sourceColorProfile.renderColorSpace,
                    forceOpaqueAlpha: forceOpaqueAlpha
                ) else {
                    return
                }
                if repairPremultipliedEdges {
                    repairPremultipliedAlphaEdgesIfNeeded(&rgba)
                }

                if !meaningfulAlpha && containsUsefulAlpha(rgba) {
                    meaningfulAlpha = true
                }
                frames.append(rgba)
                presentationTimes.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
            }
        }

        if reader.status == .failed {
            let message = reader.error?.localizedDescription ?? "未知原因"
            throw VideoVolumeLoaderError.readerFailed(message)
        }

        guard !frames.isEmpty else {
            throw VideoVolumeLoaderError.noFrames
        }

        return DecodedFrameSet(frames: frames, presentationTimes: presentationTimes, hasRealPresentationTimes: true, meaningfulAlpha: meaningfulAlpha)
    }

    private static func decodeWithImageGenerator(
        asset: AVAsset,
        targetWidth: Int,
        targetHeight: Int,
        durationSeconds: Double,
        sourceFPS: Double,
        estimatedFrameCount: Int,
        sourceColorProfile: VideoColorProfile,
        repairPremultipliedEdges: Bool,
        forceOpaqueAlpha: Bool,
        memoryBudget: VideoVolumeMemoryBudget?
    ) throws -> DecodedFrameSet {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: targetWidth, height: targetHeight)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let frameCount: Int
        if sourceFPS > 0 && durationSeconds > 0 {
            frameCount = max(1, Int((sourceFPS * durationSeconds).rounded()))
        } else {
            frameCount = max(1, estimatedFrameCount)
        }

        var times: [NSValue] = []
        times.reserveCapacity(frameCount)

        for i in 0..<frameCount {
            let seconds: Double
            if durationSeconds > 0 && sourceFPS > 0 {
                let candidate = Double(i) / sourceFPS
                seconds = min(durationSeconds, candidate)
            } else if sourceFPS > 0 {
                seconds = Double(i) / sourceFPS
            } else {
                seconds = Double(i) / 30.0
            }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            times.append(NSValue(time: time))
        }

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        var frames: [[UInt8]] = []
        var presentationTimes: [Double] = []
        var meaningfulAlpha = false
        var firstError: Error?

        for timeValue in times {
            try memoryBudget?.validate(
                width: targetWidth,
                height: targetHeight,
                frameCount: frames.count + 1,
                stage: .colorFrameAccumulation
            )
            autoreleasepool {
                do {
                    let image = try generator.copyCGImage(at: timeValue.timeValue, actualTime: nil)
                    guard var rgba = renderCGImageToRGBA8(
                        image,
                        width: targetWidth,
                        height: targetHeight,
                        ciContext: ciContext,
                        colorSpace: sourceColorProfile.renderColorSpace,
                        forceOpaqueAlpha: forceOpaqueAlpha
                    ) else {
                        return
                    }
                    if repairPremultipliedEdges {
                        repairPremultipliedAlphaEdgesIfNeeded(&rgba)
                    }

                    if !meaningfulAlpha && containsUsefulAlpha(rgba) {
                        meaningfulAlpha = true
                    }
                    frames.append(rgba)
                    presentationTimes.append(CMTimeGetSeconds(timeValue.timeValue))
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
        }

        if frames.isEmpty, let firstError {
            throw VideoVolumeLoaderError.imageGeneratorFailed(firstError.localizedDescription)
        }

        guard !frames.isEmpty else {
            throw VideoVolumeLoaderError.noFrames
        }

        return DecodedFrameSet(frames: frames, presentationTimes: presentationTimes, hasRealPresentationTimes: false, meaningfulAlpha: meaningfulAlpha)
    }

    private static func decodeWithFFmpeg(
        url: URL,
        targetWidth: Int,
        targetHeight: Int,
        sourceColorProfile: VideoColorProfile,
        repairPremultipliedEdges: Bool,
        forceOpaqueAlpha: Bool,
        sourceFPS: Double,
        memoryBudget: VideoVolumeMemoryBudget?
    ) throws -> DecodedFrameSet {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let pattern = tempDir.appendingPathComponent("frame_%06d.png").path

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let ffmpegURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.fileExists(atPath: ffmpegURL.path) else {
            throw VideoVolumeLoaderError.imageGeneratorFailed("未找到 ffmpeg：\(ffmpegURL.path)")
        }

        let task = Process()
        task.executableURL = ffmpegURL
        task.arguments = [
            "-y",
            "-i", url.path,
            "-vf", "scale=\(targetWidth):\(targetHeight):flags=lanczos",
            pattern
        ]

        let stderr = Pipe()
        task.standardError = stderr

        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "未知 ffmpeg 错误"
            throw VideoVolumeLoaderError.imageGeneratorFailed(message)
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        var frames: [[UInt8]] = []
        var presentationTimes: [Double] = []
        var meaningfulAlpha = false

        for file in files {
            try memoryBudget?.validate(
                width: targetWidth,
                height: targetHeight,
                frameCount: frames.count + 1,
                stage: .colorFrameAccumulation
            )
            autoreleasepool {
                guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      var rgba = renderCGImageToRGBA8(
                        cg,
                        width: targetWidth,
                        height: targetHeight,
                        ciContext: ciContext,
                        colorSpace: sourceColorProfile.renderColorSpace,
                        forceOpaqueAlpha: forceOpaqueAlpha
                      ) else {
                    return
                }
                if repairPremultipliedEdges {
                    repairPremultipliedAlphaEdgesIfNeeded(&rgba)
                }

                if !meaningfulAlpha && containsUsefulAlpha(rgba) {
                    meaningfulAlpha = true
                }
                frames.append(rgba)
                let fps = sourceFPS > 0 ? sourceFPS : 30
                presentationTimes.append(Double(frames.count - 1) / fps)
            }
        }

        guard !frames.isEmpty else {
            throw VideoVolumeLoaderError.noFrames
        }

        return DecodedFrameSet(frames: frames, presentationTimes: presentationTimes, hasRealPresentationTimes: false, meaningfulAlpha: meaningfulAlpha)
    }

    private static func renderPixelBufferToRGBA8(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        preferredTransform: CGAffineTransform,
        ciContext: CIContext,
        colorSpace: CGColorSpace,
        forceOpaqueAlpha: Bool = false
    ) -> [UInt8]? {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if forceOpaqueAlpha {
            ciImage = forceOpaque(ciImage)
        }
        let oriented = normalizeImageExtent(ciImage.transformed(by: preferredTransform))
        guard oriented.extent.width > 0, oriented.extent.height > 0 else { return nil }

        let sx = CGFloat(width) / oriented.extent.width
        let sy = CGFloat(height) / oriented.extent.height
        let scaled = oriented.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        guard let bitmapCount = try? checkedDimensionProduct([width, height, 4], context: "RGBA bitmap"),
              let rowBytes = try? checkedDimensionProduct([width, 4], context: "RGBA row") else {
            return nil
        }
        var rgba = [UInt8](repeating: 0, count: bitmapCount)

        ciContext.render(
            scaled,
            toBitmap: &rgba,
            rowBytes: rowBytes,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        return rgba
    }

    private static func orientedDisplaySize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> (width: Int, height: Int) {
        let naturalRect = CGRect(origin: .zero, size: naturalSize)
        let transformed = naturalRect.applying(preferredTransform)
        let width = max(1, Int(abs(transformed.width).rounded()))
        let height = max(1, Int(abs(transformed.height).rounded()))
        return (width, height)
    }

    private static func normalizeImageExtent(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.origin.x != 0 || extent.origin.y != 0 else {
            return image
        }
        return image.transformed(
            by: CGAffineTransform(
                translationX: -extent.origin.x,
                y: -extent.origin.y
            )
        )
    }

    private static func renderCGImageToRGBA8(
        _ image: CGImage,
        width: Int,
        height: Int,
        ciContext: CIContext,
        colorSpace: CGColorSpace,
        forceOpaqueAlpha: Bool = false
    ) -> [UInt8]? {
        var ciImage = CIImage(cgImage: image)
        if forceOpaqueAlpha {
            ciImage = forceOpaque(ciImage)
        }
        let sx = CGFloat(width) / ciImage.extent.width
        let sy = CGFloat(height) / ciImage.extent.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        guard let bitmapCount = try? checkedDimensionProduct([width, height, 4], context: "RGBA bitmap"),
              let rowBytes = try? checkedDimensionProduct([width, 4], context: "RGBA row") else {
            return nil
        }
        var rgba = [UInt8](repeating: 0, count: bitmapCount)

        ciContext.render(
            scaled,
            toBitmap: &rgba,
            rowBytes: rowBytes,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        return rgba
    }

    private static func forceOpaque(_ image: CIImage) -> CIImage {
        image.settingAlphaOne(in: image.extent)
    }

    private static func repairPremultipliedAlphaEdgesIfNeeded(_ rgba: inout [UInt8]) {
        var translucentCount = 0
        var premultipliedLikeCount = 0
        var index = 0
        while index + 3 < rgba.count {
            let alpha = Int(rgba[index + 3])
            if alpha > 0 && alpha < 255 {
                translucentCount += 1
                let maxRGB = max(Int(rgba[index]), Int(rgba[index + 1]), Int(rgba[index + 2]))
                if maxRGB <= alpha + 2 {
                    premultipliedLikeCount += 1
                }
            }
            index += 4
        }

        guard translucentCount > 0, premultipliedLikeCount * 2 >= translucentCount else {
            return
        }

        index = 0
        while index + 3 < rgba.count {
            let alpha = Int(rgba[index + 3])
            if alpha > 0 && alpha < 255 {
                rgba[index] = UInt8(min(255, Int(rgba[index]) * 255 / alpha))
                rgba[index + 1] = UInt8(min(255, Int(rgba[index + 1]) * 255 / alpha))
                rgba[index + 2] = UInt8(min(255, Int(rgba[index + 2]) * 255 / alpha))
            }
            index += 4
        }
    }

    private static func containsUsefulAlpha(_ rgba: [UInt8]) -> Bool {
        var idx = 3
        while idx < rgba.count {
            let a = rgba[idx]
            if a < 251 {
                return true
            }
            idx += 4
        }
        return false
    }

    private static func depthSample(_ frames: [[UInt8]], maxDepth: Int) -> [[UInt8]] {
        guard !frames.isEmpty else { return [] }
        guard frames.count > maxDepth else { return frames }
        guard maxDepth > 1 else { return [frames[0]] }

        var result: [[UInt8]] = []
        result.reserveCapacity(maxDepth)

        let denom = Double(maxDepth - 1)
        let srcMax = Double(frames.count - 1)

        for i in 0..<maxDepth {
            let ratio = Double(i) / denom
            let src = Int((ratio * srcMax).rounded())
            let clamped = max(0, min(frames.count - 1, src))
            result.append(frames[clamped])
        }

        return result
    }

    private static func checkedDimensionProduct(_ factors: [Int], context: String) throws -> Int {
        var result = 1
        for factor in factors {
            guard factor > 0 else {
                throw VideoVolumeLoaderError.externalAlpha("\(context) 尺寸无效：\(factors)")
            }
            let multiplied = result.multipliedReportingOverflow(by: factor)
            guard !multiplied.overflow else {
                throw VideoVolumeLoaderError.memoryBudgetExceeded("\(context) 尺寸乘法溢出：\(factors)")
            }
            result = multiplied.partialValue
        }
        return result
    }

    private static func packFramesToVolume(
        _ frames: [[UInt8]],
        width: Int,
        height: Int,
        meaningfulAlpha: Bool,
        sourceFPS: Double,
        durationSeconds: Double,
        sourceFrameCount: Int,
        sourceColorProfile: VideoColorProfile,
        memoryBudget: VideoVolumeMemoryBudget? = nil,
        allocationStage: VideoVolumeAllocationStage = .fullTemporalVolume
    ) throws -> LoadedVolume {
        let depth = max(1, frames.count)
        try memoryBudget?.validate(
            width: width,
            height: height,
            frameCount: depth,
            stage: allocationStage
        )
        let frameBytes = try checkedDimensionProduct([width, height, 4], context: "packed RGBA frame")
        let volumeBytes = try checkedDimensionProduct([frameBytes, depth], context: "packed RGBA volume")
        var rgba = [UInt8](repeating: 0, count: volumeBytes)
        memoryBudget?.record(.fullTemporalVolumeAllocated)

        for (t, frame) in frames.enumerated() {
            let dstStart = t * frameBytes
            let dstEnd = dstStart + frameBytes
            if frame.count >= frameBytes {
                rgba[dstStart..<dstEnd] = frame[0..<frameBytes]
            }
        }

        return LoadedVolume(
            width: width,
            height: height,
            depth: depth,
            rgba: rgba,
            hasMeaningfulAlpha: meaningfulAlpha,
            sourceFPS: sourceFPS,
            sourceDurationSeconds: durationSeconds,
            sourceFrameCountEstimate: sourceFrameCount,
            sourceColorProfile: sourceColorProfile
        )
    }

    private static func depthSampleIndices(count: Int, maxDepth: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > maxDepth else { return Array(0..<count) }
        guard maxDepth > 1 else { return [0] }
        return (0..<maxDepth).map { index in
            let ratio = Double(index) / Double(maxDepth - 1)
            return min(count - 1, max(0, Int((ratio * Double(count - 1)).rounded())))
        }
    }

    private static func metadata(
        url: URL,
        asset: AVAsset,
        track: AVAssetTrack,
        decodedFrameCount: Int,
        fallbackBitDepth: Int
    ) async throws -> VideoSourceMetadata {
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let fps = Double(try await track.load(.nominalFrameRate))
        let timeRange = try await track.load(.timeRange)
        let descriptions = try await track.load(.formatDescriptions)
        let description = descriptions.first
        let subtype = description.map(CMFormatDescriptionGetMediaSubType) ?? 0
        let codec = fourCC(subtype)
        let extensions = description.flatMap(CMFormatDescriptionGetExtensions) as? [String: Any]
        let pixelFormat = extensions?[kCMFormatDescriptionExtension_FormatName as String] as? String ?? codec
        let colorPrimaries = extensions?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? "未知"
        let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? "未知"
        let matrix = extensions?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String ?? "未知"
        let fullRange = extensions?[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool
        let durationSeconds = max(0, CMTimeGetSeconds(duration))
        let start = CMTimeGetSeconds(timeRange.start)
        let rotation = rotationDegrees(for: transform)

        return VideoSourceMetadata(
            fileName: url.lastPathComponent,
            container: url.pathExtension.lowercased(),
            codec: codec,
            width: max(1, Int(abs(naturalSize.width).rounded())),
            height: max(1, Int(abs(naturalSize.height).rounded())),
            rotationDegrees: rotation,
            fps: fps > 0 ? fps : (durationSeconds > 0 ? Double(decodedFrameCount) / durationSeconds : 0),
            durationSeconds: durationSeconds,
            frameCount: decodedFrameCount,
            startTimeSeconds: start.isFinite ? start : 0,
            timeBase: timeRange.duration.timescale > 0 ? "1/\(timeRange.duration.timescale)" : "未知",
            pixelFormat: pixelFormat,
            bitDepth: fallbackBitDepth,
            range: fullRange == true ? .full : (fullRange == false ? .limited : .auto),
            colorPrimaries: colorPrimaries,
            transfer: transfer,
            matrix: matrix,
            hasEmbeddedAlpha: codec == "ap4h" || codec == "ap4x" || codec == "r4fl" || pixelFormat.lowercased().contains("alpha")
        )
    }

    private static func decodeExternalAlpha(
        url: URL,
        targetDisplayWidth: Int,
        targetDisplayHeight: Int,
        targetDecodeWidth: Int,
        targetDecodeHeight: Int,
        settings: ExternalAlphaSettings,
        memoryBudget: VideoVolumeMemoryBudget? = nil
    ) throws -> DecodedAlphaFrameSet {
        let probe = try ffprobe(url: url)
        let metadata = probe.metadata
        if settings.resizePolicy == .strict,
           (metadata.displayWidth != targetDisplayWidth || metadata.displayHeight != targetDisplayHeight) {
            throw ExternalAlphaError.resolutionMismatch(
                colorWidth: targetDisplayWidth,
                colorHeight: targetDisplayHeight,
                alphaWidth: metadata.displayWidth,
                alphaHeight: metadata.displayHeight
            )
        }

        let grayFormats: [String: (output: String, depth: Int, bytes: Int)] = [
            "gray": ("gray", 8, 1),
            "gray8": ("gray", 8, 1),
            "gray10le": ("gray10le", 10, 2),
            "gray12le": ("gray12le", 12, 2),
            "gray16le": ("gray16le", 16, 2)
        ]
        let sourceFormat = metadata.pixelFormat.lowercased()
        let isYUVLuma = settings.channel == .luma && (
            sourceFormat.hasPrefix("yuv") || sourceFormat.hasPrefix("yuva") ||
            sourceFormat.hasPrefix("nv") || sourceFormat.hasPrefix("p0")
        )
        let nativeGray: (output: String, depth: Int, bytes: Int)?
        if let gray = grayFormats[sourceFormat] {
            nativeGray = gray
        } else if isYUVLuma {
            let depth = metadata.bitDepth
            nativeGray = depth <= 8 ? ("gray", 8, 1) : ("gray\(depth)le", depth, 2)
        } else {
            nativeGray = nil
        }
        let outputPixelFormat = nativeGray?.output ?? "rgba64le"
        let decodedBitDepth = nativeGray?.depth ?? 16
        let bytesPerPixel = nativeGray?.bytes ?? 8

        var filters: [String] = []
        switch normalizedRotation(metadata.rotationDegrees) {
        case 90: filters.append("transpose=clock")
        case 180: filters.append("hflip,vflip")
        case 270: filters.append("transpose=cclock")
        default: break
        }
        if isYUVLuma { filters.append("extractplanes=y") }
        filters.append("scale=\(targetDecodeWidth):\(targetDecodeHeight):flags=lanczos")
        filters.append("format=\(outputPixelFormat)")

        let executable = try ffmpegExecutable(named: "ffmpeg")
        let task = Process()
        task.executableURL = executable
        task.arguments = [
            "-v", "error", "-noautorotate", "-i", url.path,
            "-map", "0:v:0", "-vsync", "0",
            "-vf", filters.joined(separator: ","),
            "-pix_fmt", outputPixelFormat,
            "-f", "rawvideo", "pipe:1"
        ]
        let rawURL = FileManager.default.temporaryDirectory.appendingPathComponent("chronovolume-alpha-\(UUID().uuidString).raw")
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        let rawHandle = try FileHandle(forWritingTo: rawURL)
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("chronovolume-alpha-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        task.standardOutput = rawHandle
        task.standardError = errorHandle
        defer {
            try? errorHandle.close()
            try? rawHandle.close()
            try? FileManager.default.removeItem(at: rawURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        try task.run()
        task.waitUntilExit()
        try rawHandle.close()
        try errorHandle.synchronize()
        if task.terminationStatus != 0 {
            let message = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? "未知错误"
            throw ExternalAlphaError.ffmpegFailed(message)
        }

        let rawByteCount = ((try? FileManager.default.attributesOfItem(atPath: rawURL.path)[.size] as? NSNumber)?.intValue) ?? 0
        let pixelCount = try checkedDimensionProduct(
            [targetDecodeWidth, targetDecodeHeight],
            context: "external Alpha frame pixels"
        )
        let frameBytes = try checkedDimensionProduct(
            [pixelCount, bytesPerPixel],
            context: "external Alpha frame bytes"
        )
        guard frameBytes > 0, rawByteCount.isMultiple(of: frameBytes) else {
            throw ExternalAlphaError.decodedByteCountMismatch(expectedMultiple: frameBytes, actual: rawByteCount)
        }
        let frameCount = rawByteCount / frameBytes
        guard frameCount > 0 else { throw VideoVolumeLoaderError.noFrames }
        try memoryBudget?.validate(
            width: targetDecodeWidth,
            height: targetDecodeHeight,
            frameCount: frameCount,
            stage: .alphaFrameAccumulation
        )
        let raw = try Data(contentsOf: rawURL, options: .mappedIfSafe)
        var frames: [[UInt16]] = []
        frames.reserveCapacity(frameCount)

        raw.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            for frameIndex in 0..<frameCount {
                let base = frameIndex * frameBytes
                var frame = [UInt16](repeating: 0, count: pixelCount)
                if let nativeGray {
                    if nativeGray.bytes == 1 {
                        for pixel in 0..<pixelCount {
                            frame[pixel] = UInt16(bytes[base + pixel])
                        }
                    } else {
                        for pixel in 0..<pixelCount {
                            let offset = base + pixel * 2
                            frame[pixel] = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                        }
                    }
                } else {
                    let coefficients = ExternalAlphaNormalizer.lumaCoefficients(
                        matrix: metadata.matrix,
                        primaries: metadata.colorPrimaries
                    )
                    for pixel in 0..<pixelCount {
                        let offset = base + pixel * 8
                        let rgba = (
                            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8),
                            UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8),
                            UInt16(bytes[offset + 4]) | (UInt16(bytes[offset + 5]) << 8),
                            UInt16(bytes[offset + 6]) | (UInt16(bytes[offset + 7]) << 8)
                        )
                        let selected16 = ExternalAlphaNormalizer.selectedCodeValue(
                            rgba: rgba,
                            channel: settings.channel,
                            bitDepth: 16,
                            lumaCoefficients: coefficients
                        )
                        frame[pixel] = selected16
                    }
                }
                frames.append(frame)
            }
        }

        var timestamps = probe.presentationTimes
        let hasRealPresentationTimes = timestamps.count == frameCount
        if timestamps.count != frameCount {
            let fps = metadata.fps > 0 ? metadata.fps : 30
            timestamps = (0..<frameCount).map { metadata.startTimeSeconds + Double($0) / fps }
        }
        let taggedRange = nativeGray == nil ? .full : (metadata.range == .auto ? .full : metadata.range)
        return DecodedAlphaFrameSet(
            frames: frames,
            presentationTimes: timestamps,
            hasRealPresentationTimes: hasRealPresentationTimes,
            decodedBitDepth: decodedBitDepth,
            sourceBitDepth: metadata.bitDepth,
            resolvedRange: taggedRange,
            allowsRangeOverride: nativeGray != nil,
            metadata: metadata
        )
    }

    private static func ffprobe(url: URL) throws -> (metadata: VideoSourceMetadata, presentationTimes: [Double]) {
        let executable = try ffmpegExecutable(named: "ffprobe")
        let task = Process()
        task.executableURL = executable
        task.arguments = [
            "-v", "error", "-select_streams", "v:0",
            "-show_streams", "-show_format", "-show_frames",
            "-show_entries", "stream=codec_name,width,height,pix_fmt,bits_per_raw_sample,avg_frame_rate,r_frame_rate,time_base,duration,nb_frames,start_time,color_range,color_space,color_transfer,color_primaries:stream_tags=rotate:stream_side_data=rotation:format=format_name,duration,start_time:frame=best_effort_timestamp_time,pkt_pts_time",
            "-of", "json", url.path
        ]
        let output = Pipe()
        let error = Pipe()
        task.standardOutput = output
        task.standardError = error
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let reason = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知错误"
            throw ExternalAlphaError.ffprobeFailed(reason)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (root["streams"] as? [[String: Any]])?.first else {
            throw ExternalAlphaError.ffprobeFailed("没有视频流元数据")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let width = intValue(stream["width"])
        let height = intValue(stream["height"])
        let pixelFormat = stringValue(stream["pix_fmt"], fallback: "unknown")
        let bitDepth = inferredBitDepth(pixelFormat: pixelFormat, explicit: intValue(stream["bits_per_raw_sample"]))
        let fpsText = stringValue(stream["avg_frame_rate"], fallback: stringValue(stream["r_frame_rate"], fallback: "0/1"))
        let fps = rationalValue(fpsText)
        let duration = doubleValue(stream["duration"]) ?? doubleValue(format["duration"]) ?? 0
        let start = doubleValue(stream["start_time"]) ?? doubleValue(format["start_time"]) ?? 0
        let tags = stream["tags"] as? [String: Any]
        var rotation = Int(doubleValue(tags?["rotate"]) ?? 0)
        if let sideData = stream["side_data_list"] as? [[String: Any]],
           let sideRotation = sideData.compactMap({ doubleValue($0["rotation"]) }).first {
            rotation = Int(sideRotation.rounded())
        }
        let rangeText = stringValue(stream["color_range"], fallback: "")
        let range: ExternalAlphaRange = rangeText == "pc" || rangeText == "jpeg" || rangeText == "full"
            ? .full
            : (rangeText == "tv" || rangeText == "mpeg" || rangeText == "limited" ? .limited : .auto)
        let frames = root["frames"] as? [[String: Any]] ?? []
        let times = frames.compactMap {
            doubleValue($0["best_effort_timestamp_time"]) ?? doubleValue($0["pkt_pts_time"])
        }
        let declaredCount = intValue(stream["nb_frames"])
        let codec = stringValue(stream["codec_name"], fallback: "unknown")
        let hasAlpha = pixelFormat.lowercased().contains("a") || codec == "qtrle" || codec == "prores_ks"
        let metadata = VideoSourceMetadata(
            fileName: url.lastPathComponent,
            container: stringValue(format["format_name"], fallback: url.pathExtension.lowercased()),
            codec: codec,
            width: width,
            height: height,
            rotationDegrees: rotation,
            fps: fps,
            durationSeconds: duration,
            frameCount: declaredCount > 0 ? declaredCount : times.count,
            startTimeSeconds: start,
            timeBase: stringValue(stream["time_base"], fallback: "unknown"),
            pixelFormat: pixelFormat,
            bitDepth: bitDepth,
            range: range,
            colorPrimaries: stringValue(stream["color_primaries"], fallback: "unknown"),
            transfer: stringValue(stream["color_transfer"], fallback: "linear/unknown"),
            matrix: stringValue(stream["color_space"], fallback: "identity/unknown"),
            hasEmbeddedAlpha: hasAlpha
        )
        return (metadata, times)
    }

    static func probeExternalSource(_ url: URL) throws -> (metadata: VideoSourceMetadata, presentationTimes: [Double]) {
        try ffprobe(url: url)
    }

    private static func ffmpegExecutable(named name: String) throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw ExternalAlphaError.ffmpegNotFound
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> FourCharCode($0)) & 0xff) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? String(format: "0x%08x", value)
    }

    private static func rotationDegrees(for transform: CGAffineTransform) -> Int {
        normalizedRotation(Int((atan2(transform.b, transform.a) * 180 / .pi).rounded()))
    }

    private static func normalizedRotation(_ degrees: Int) -> Int {
        let value = degrees % 360
        return value < 0 ? value + 360 : value
    }

    private static func inferredBitDepth(pixelFormat: String, explicit: Int) -> Int {
        if explicit > 0 { return explicit }
        let lower = pixelFormat.lowercased()
        if lower.contains("16") { return 16 }
        if lower.contains("14") { return 14 }
        if lower.contains("12") { return 12 }
        if lower.contains("10") { return 10 }
        return 8
    }

    private static func rationalValue(_ value: String) -> Double {
        let parts = value.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else {
            return Double(value) ?? 0
        }
        return numerator / denominator
    }

    private static func stringValue(_ value: Any?, fallback: String) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return fallback
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func fitInside(
        width: Int,
        height: Int,
        maxWidth: Int,
        maxHeight: Int
    ) -> (width: Int, height: Int) {
        let scaleW = Double(maxWidth) / Double(max(1, width))
        let scaleH = Double(maxHeight) / Double(max(1, height))
        let scale = min(1.0, min(scaleW, scaleH))

        let w = max(1, Int((Double(width) * scale).rounded()))
        let h = max(1, Int((Double(height) * scale).rounded()))
        return (w, h)
    }
}
