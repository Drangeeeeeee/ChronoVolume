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
}

private struct DecodedFrameSet {
    let frames: [[UInt8]]
    let meaningfulAlpha: Bool
}

enum VideoVolumeLoaderError: LocalizedError {
    case noVideoTrack
    case cannotAddReaderOutput
    case cannotStartReader(String)
    case readerFailed(String)
    case noFrames
    case imageGeneratorFailed(String)

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
        }
    }
}

enum VideoVolumeLoader {
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

        let fullTemporalVolume = packFramesToVolume(
            scaledFrames,
            width: targetSize.width,
            height: targetSize.height,
            meaningfulAlpha: decoded.meaningfulAlpha,
            sourceFPS: sourceFPS,
            durationSeconds: durationSeconds,
            sourceFrameCount: actualFrameCount,
            sourceColorProfile: sourceColorProfile
        )

        let previewVolume = packFramesToVolume(
            previewFrames,
            width: targetSize.width,
            height: targetSize.height,
            meaningfulAlpha: decoded.meaningfulAlpha,
            sourceFPS: sourceFPS,
            durationSeconds: durationSeconds,
            sourceFrameCount: actualFrameCount,
            sourceColorProfile: sourceColorProfile
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
            sourceColorProfile: sourceColorProfile
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
        sourceColorProfile: VideoColorProfile
    ) throws -> DecodedFrameSet {
        do {
            return try decodeWithAssetReader(
                asset: asset,
                track: track,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                preferredTransform: preferredTransform,
                sourceColorProfile: sourceColorProfile
            )
        } catch {
            let readerError = error.localizedDescription

            do {
                return try decodeWithImageGenerator(
                    asset: asset,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    durationSeconds: durationSeconds,
                    sourceFPS: sourceFPS,
                    estimatedFrameCount: estimatedFrameCount,
                    sourceColorProfile: sourceColorProfile
                )
            } catch {
                let imageGenError = error.localizedDescription

                do {
                    return try decodeWithFFmpeg(
                        url: url,
                        targetWidth: targetWidth,
                        targetHeight: targetHeight,
                        sourceColorProfile: sourceColorProfile
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
        sourceColorProfile: VideoColorProfile
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
        var meaningfulAlpha = false

        while let sample = output.copyNextSampleBuffer(),
              let imageBuffer = CMSampleBufferGetImageBuffer(sample) {
            autoreleasepool {
                guard var rgba = renderPixelBufferToRGBA8(
                    pixelBuffer: imageBuffer,
                    width: targetWidth,
                    height: targetHeight,
                    preferredTransform: preferredTransform,
                    ciContext: ciContext,
                    colorSpace: sourceColorProfile.renderColorSpace
                ) else {
                    return
                }
                repairPremultipliedAlphaEdgesIfNeeded(&rgba)

                if !meaningfulAlpha && containsUsefulAlpha(rgba) {
                    meaningfulAlpha = true
                }
                frames.append(rgba)
            }
        }

        if reader.status == .failed {
            let message = reader.error?.localizedDescription ?? "未知原因"
            throw VideoVolumeLoaderError.readerFailed(message)
        }

        guard !frames.isEmpty else {
            throw VideoVolumeLoaderError.noFrames
        }

        return DecodedFrameSet(frames: frames, meaningfulAlpha: meaningfulAlpha)
    }

    private static func decodeWithImageGenerator(
        asset: AVAsset,
        targetWidth: Int,
        targetHeight: Int,
        durationSeconds: Double,
        sourceFPS: Double,
        estimatedFrameCount: Int,
        sourceColorProfile: VideoColorProfile
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
        var meaningfulAlpha = false
        var firstError: Error?

        for timeValue in times {
            autoreleasepool {
                do {
                    let image = try generator.copyCGImage(at: timeValue.timeValue, actualTime: nil)
                    guard var rgba = renderCGImageToRGBA8(
                        image,
                        width: targetWidth,
                        height: targetHeight,
                        ciContext: ciContext,
                        colorSpace: sourceColorProfile.renderColorSpace
                    ) else {
                        return
                    }
                    repairPremultipliedAlphaEdgesIfNeeded(&rgba)

                    if !meaningfulAlpha && containsUsefulAlpha(rgba) {
                        meaningfulAlpha = true
                    }
                    frames.append(rgba)
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

        return DecodedFrameSet(frames: frames, meaningfulAlpha: meaningfulAlpha)
    }

    private static func decodeWithFFmpeg(
        url: URL,
        targetWidth: Int,
        targetHeight: Int,
        sourceColorProfile: VideoColorProfile
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
        var meaningfulAlpha = false

        for file in files {
            autoreleasepool {
                guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      var rgba = renderCGImageToRGBA8(
                        cg,
                        width: targetWidth,
                        height: targetHeight,
                        ciContext: ciContext,
                        colorSpace: sourceColorProfile.renderColorSpace
                      ) else {
                    return
                }
                repairPremultipliedAlphaEdgesIfNeeded(&rgba)

                if !meaningfulAlpha && containsUsefulAlpha(rgba) {
                    meaningfulAlpha = true
                }
                frames.append(rgba)
            }
        }

        guard !frames.isEmpty else {
            throw VideoVolumeLoaderError.noFrames
        }

        return DecodedFrameSet(frames: frames, meaningfulAlpha: meaningfulAlpha)
    }

    private static func renderPixelBufferToRGBA8(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        preferredTransform: CGAffineTransform,
        ciContext: CIContext,
        colorSpace: CGColorSpace
    ) -> [UInt8]? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = normalizeImageExtent(ciImage.transformed(by: preferredTransform))
        guard oriented.extent.width > 0, oriented.extent.height > 0 else { return nil }

        let sx = CGFloat(width) / oriented.extent.width
        let sy = CGFloat(height) / oriented.extent.height
        let scaled = oriented.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        ciContext.render(
            scaled,
            toBitmap: &rgba,
            rowBytes: width * 4,
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
        colorSpace: CGColorSpace
    ) -> [UInt8]? {
        let ciImage = CIImage(cgImage: image)
        let sx = CGFloat(width) / ciImage.extent.width
        let sy = CGFloat(height) / ciImage.extent.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        ciContext.render(
            scaled,
            toBitmap: &rgba,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        return rgba
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

    private static func packFramesToVolume(
        _ frames: [[UInt8]],
        width: Int,
        height: Int,
        meaningfulAlpha: Bool,
        sourceFPS: Double,
        durationSeconds: Double,
        sourceFrameCount: Int,
        sourceColorProfile: VideoColorProfile
    ) -> LoadedVolume {
        let depth = max(1, frames.count)
        let frameBytes = width * height * 4
        var rgba = [UInt8](repeating: 0, count: frameBytes * depth)

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
