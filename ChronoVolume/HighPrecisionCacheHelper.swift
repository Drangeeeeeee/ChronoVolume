import Foundation
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers

enum HighPrecisionCacheHelper {
    static func cacheDirectory(for sourceURL: URL) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("ChronoVolume/HighPrecisionCache", isDirectory: true)
        let safeName = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return root.appendingPathComponent(safeName, isDirectory: true)
    }

    static func cacheMovieURL(for sourceURL: URL, preserveAlpha: Bool) -> URL {
        let name = preserveAlpha ? "hp_cache_alpha.mov" : "hp_cache_opaque.mov"
        return cacheDirectory(for: sourceURL).appendingPathComponent(name)
    }

    static func cacheMetadataURL(for sourceURL: URL, preserveAlpha: Bool) -> URL {
        let name = preserveAlpha ? "hp_cache_alpha.json" : "hp_cache_opaque.json"
        return cacheDirectory(for: sourceURL).appendingPathComponent(name)
    }

    static func hasCache(for sourceURL: URL, preserveAlpha: Bool) -> Bool {
        let movie = cacheMovieURL(for: sourceURL, preserveAlpha: preserveAlpha)
        let meta = cacheMetadataURL(for: sourceURL, preserveAlpha: preserveAlpha)
        return FileManager.default.fileExists(atPath: movie.path) &&
               FileManager.default.fileExists(atPath: meta.path)
    }

    static func loadMetadata(for sourceURL: URL, preserveAlpha: Bool) throws -> HighPrecisionCacheMetadata {
        let url = cacheMetadataURL(for: sourceURL, preserveAlpha: preserveAlpha)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HighPrecisionCacheError.metadataReadFailed(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(HighPrecisionCacheMetadata.self, from: data)
        } catch {
            throw HighPrecisionCacheError.metadataReadFailed(error.localizedDescription)
        }
    }

    static func removeCache(for sourceURL: URL) {
        let dir = cacheDirectory(for: sourceURL)
        try? FileManager.default.removeItem(at: dir)
    }

    static func buildCache(
        from sourceURL: URL,
        preserveAlpha: Bool,
        progress: @escaping (Double, String) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw HighPrecisionCacheError.sourceNotFound
        }

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw HighPrecisionCacheError.invalidSource("没有视频轨道")
        }

        let naturalSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let nominalFPS = try await track.load(.nominalFrameRate)

        let srcW = max(1, Int(abs(naturalSize.width.rounded())))
        let srcH = max(1, Int(abs(naturalSize.height.rounded())))
        let durationSeconds = max(0.0, CMTimeGetSeconds(duration))
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30.0
        let frameCount = max(1, Int((fps * max(durationSeconds, 0.0001)).rounded()))
        let colorProfile = SourceColorProfileDetector.detect(from: track)

        let dir = cacheDirectory(for: sourceURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let outputURL = cacheMovieURL(for: sourceURL, preserveAlpha: preserveAlpha)
        let metadataURL = cacheMetadataURL(for: sourceURL, preserveAlpha: preserveAlpha)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try? FileManager.default.removeItem(at: metadataURL)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw HighPrecisionCacheError.readerFailed(error.localizedDescription)
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw HighPrecisionCacheError.readerFailed("无法添加 Reader 输出")
        }
        reader.add(readerOutput)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw HighPrecisionCacheError.writerFailed(error.localizedDescription)
        }

        let codecValue = preserveAlpha ? "ap4h" : "apcn"
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: codecValue,
            AVVideoWidthKey: srcW,
            AVVideoHeightKey: srcH,
            AVVideoColorPropertiesKey: colorProfile.avVideoColorProperties
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.mediaTimeScale = 600

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: srcW,
                kCVPixelBufferHeightKey as String: srcH,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw HighPrecisionCacheError.writerFailed("无法添加 Writer 输入")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw HighPrecisionCacheError.readerFailed(reader.error?.localizedDescription ?? "启动失败")
        }
        guard writer.startWriting() else {
            throw HighPrecisionCacheError.writerFailed(writer.error?.localizedDescription ?? "启动失败")
        }
        writer.startSession(atSourceTime: .zero)

        progress(0.01, "正在建立高精度缓存")

        var writtenFrames = 0
        let semaphore = DispatchSemaphore(value: 0)

        writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "ChronoVolume.hp.cache.writer")) {
            while writerInput.isReadyForMoreMediaData {
                guard let sample = readerOutput.copyNextSampleBuffer() else {
                    writerInput.markAsFinished()
                    semaphore.signal()
                    return
                }

                let time = CMSampleBufferGetPresentationTimeStamp(sample)

                guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
                    continue
                }

                if !adaptor.append(imageBuffer, withPresentationTime: time) {
                    writerInput.markAsFinished()
                    semaphore.signal()
                    return
                }

                writtenFrames += 1
                if writtenFrames % 8 == 0 || writtenFrames == frameCount {
                    let p = min(0.98, Double(writtenFrames) / Double(max(1, frameCount)))
                    progress(p, "正在建立高精度缓存")
                }
            }
        }

        semaphore.wait()

        if reader.status == .failed {
            throw HighPrecisionCacheError.readerFailed(reader.error?.localizedDescription ?? "读取失败")
        }

        let finishSemaphore = DispatchSemaphore(value: 0)
        var finishError: Error?

        writer.finishWriting {
            if writer.status != .completed {
                finishError = writer.error
            }
            finishSemaphore.signal()
        }
        finishSemaphore.wait()

        if let finishError {
            throw HighPrecisionCacheError.writerFailed(finishError.localizedDescription)
        }

        let metadata = HighPrecisionCacheMetadata(
            version: 1,
            sourcePath: sourceURL.path,
            sourceFileName: sourceURL.lastPathComponent,
            sourceWidth: srcW,
            sourceHeight: srcH,
            sourceFrameCount: frameCount,
            fps: fps,
            durationSeconds: durationSeconds,
            preserveAlpha: preserveAlpha,
            codecName: preserveAlpha ? "ProRes 4444" : "ProRes 422",
            colorProfile: colorProfile,
            createdAtISO8601: ISO8601DateFormatter().string(from: Date())
        )

        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL)
        } catch {
            throw HighPrecisionCacheError.metadataWriteFailed(error.localizedDescription)
        }

        progress(1.0, "高精度缓存建立完成")
        return outputURL
    }
}
