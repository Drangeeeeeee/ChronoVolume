import Foundation
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers
import CryptoKit

enum HighPrecisionCacheHelper {
    static let externalAlphaCacheVersion = 5

    struct CacheContext: Sendable {
        let pair: VideoSourcePair
        let preserveAlpha: Bool
        let key: String
        let directory: URL
        let movieURL: URL
        let metadataURL: URL
        let alphaSidecarURL: URL
    }

    private struct SourceContentHashes: Sendable, Equatable {
        let color: String?
        let alpha: String?
    }

    private struct ValidatedAlphaSidecarContext {
        let cacheContext: CacheContext
        let metadata: HighPrecisionCacheMetadata
        let width: Int
        let height: Int
        let depth: Int
        let sampleCount: Int
        let expectedByteCount: Int
        let memoryEstimate: PairedVolumeMemoryEstimate
        let memoryBudget: VideoVolumeMemoryBudget
    }

    private enum ContentHashAudit {
        @TaskLocal static var observer: (@Sendable (URL) -> Void)?
    }

    private struct SourceCacheContext: Sendable {
        let sourceURL: URL
        let preserveAlpha: Bool
        let directory: URL
        let movieURL: URL
        let metadataURL: URL
    }

    struct PairedVolumeMemoryEstimate: Sendable {
        let width: Int
        let height: Int
        let depth: Int
        let estimatedPeakBytes: UInt64
        let budgetBytes: UInt64

        var diagnostic: String {
            let peak = Double(estimatedPeakBytes) / 1_073_741_824.0
            let budget = Double(budgetBytes) / 1_073_741_824.0
            return "源分辨率 \(width)×\(height)×\(depth)，预计峰值内存 \(String(format: "%.2f", peak)) GiB / 预算 \(String(format: "%.2f", budget)) GiB"
        }
    }

    struct FrameDepthProbeResult: Sendable {
        let presentationTimes: [Double]
        let reliableFrameCount: Int?
        let nominalFrameRate: Double
        let durationSeconds: Double
    }

    static func cacheDirectory(for sourceURL: URL) -> URL {
        sourceCacheContext(for: sourceURL, preserveAlpha: false).directory
    }

    static func cacheMovieURL(for sourceURL: URL, preserveAlpha: Bool) -> URL {
        sourceCacheContext(for: sourceURL, preserveAlpha: preserveAlpha).movieURL
    }

    static func cacheDirectory(for pair: VideoSourcePair) -> URL {
        makeCacheContext(for: pair, preserveAlpha: true).directory
    }

    static func cacheMovieURL(for pair: VideoSourcePair, preserveAlpha: Bool) -> URL {
        makeCacheContext(for: pair, preserveAlpha: preserveAlpha).movieURL
    }

    static func cacheMetadataURL(for pair: VideoSourcePair, preserveAlpha: Bool) -> URL {
        makeCacheContext(for: pair, preserveAlpha: preserveAlpha).metadataURL
    }

    static func cacheAlphaSidecarURL(for pair: VideoSourcePair) -> URL {
        makeCacheContext(for: pair, preserveAlpha: true).alphaSidecarURL
    }

    static func makeCacheContext(for pair: VideoSourcePair, preserveAlpha: Bool) -> CacheContext {
        let key = cacheKey(for: pair)
        let directory = cacheRoot().appendingPathComponent(
            "\(safeName(pair.colorURL))_\(key.prefix(20))",
            isDirectory: true
        )
        return CacheContext(
            pair: pair,
            preserveAlpha: preserveAlpha,
            key: key,
            directory: directory,
            movieURL: directory.appendingPathComponent(preserveAlpha ? "hp_cache_alpha.mov" : "hp_cache_opaque.mov"),
            metadataURL: directory.appendingPathComponent(preserveAlpha ? "hp_cache_alpha.json" : "hp_cache_opaque.json"),
            alphaSidecarURL: directory.appendingPathComponent("external_alpha_u16le.raw")
        )
    }

    static func hasCache(for pair: VideoSourcePair, preserveAlpha: Bool) -> Bool {
        let context = makeCacheContext(for: pair, preserveAlpha: preserveAlpha)
        let basic = FileManager.default.fileExists(atPath: context.movieURL.path) &&
            FileManager.default.fileExists(atPath: context.metadataURL.path)
        if preserveAlpha, pair.alphaSourceMode == .external {
            return basic && FileManager.default.fileExists(atPath: context.alphaSidecarURL.path)
        }
        return basic
    }

    static func validatedCacheURL(
        for pair: VideoSourcePair,
        preserveAlpha: Bool
    ) async throws -> URL {
        let context = makeCacheContext(for: pair, preserveAlpha: preserveAlpha)
        guard FileManager.default.fileExists(atPath: context.movieURL.path),
              FileManager.default.fileExists(atPath: context.metadataURL.path) else {
            throw HighPrecisionCacheError.metadataReadFailed("高精度缓存 MOV 或 metadata 不存在")
        }
        let metadata = try loadMetadata(context: context)
        let expectedSidecarHash: String?
        if preserveAlpha, pair.alphaSourceMode == .external {
            guard let hash = metadata.alphaSidecarSHA256, !hash.isEmpty else {
                throw HighPrecisionCacheError.metadataReadFailed(
                    "external Alpha 缓存版本过旧或缓存不完整：缺少 sidecar SHA-256，请重新建立缓存"
                )
            }
            expectedSidecarHash = hash
        } else {
            expectedSidecarHash = nil
        }
        let sourceHashes = await captureSourceHashes(for: pair)
        try validateSourceHashes(metadata: metadata, pair: pair, hashes: sourceHashes)
        if preserveAlpha, pair.alphaSourceMode == .external {
            guard FileManager.default.fileExists(atPath: context.alphaSidecarURL.path) else {
                throw HighPrecisionCacheError.metadataReadFailed("高精度 Alpha sidecar 不存在")
            }
            guard let expectedHash = expectedSidecarHash else {
                throw HighPrecisionCacheError.metadataReadFailed(
                    "external Alpha 缓存版本过旧或缓存不完整：缺少 sidecar SHA-256，请重新建立缓存"
                )
            }
            guard await contentSHA256InBackground(context.alphaSidecarURL) == expectedHash else {
                throw HighPrecisionCacheError.metadataReadFailed("Alpha sidecar SHA-256 校验失败")
            }
        }
        return context.movieURL
    }

    static func loadMetadata(for pair: VideoSourcePair, preserveAlpha: Bool) throws -> HighPrecisionCacheMetadata {
        try loadMetadata(context: makeCacheContext(for: pair, preserveAlpha: preserveAlpha))
    }

    static func removeCache(for pair: VideoSourcePair) {
        let context = makeCacheContext(for: pair, preserveAlpha: true)
        try? FileManager.default.removeItem(at: context.directory)
    }

    static func cacheKey(for pair: VideoSourcePair) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let settingsData = (try? encoder.encode(pair.externalAlphaSettings)) ?? Data()
        var identity = "v\(externalAlphaCacheVersion)|\(fileIdentity(pair.colorURL))|\(pair.alphaSourceMode.rawValue)|white=\(pair.usesGeneratedWhiteColor)|"
        if let alphaURL = pair.alphaURL {
            identity += fileIdentity(alphaURL)
        }
        var data = Data(identity.utf8)
        data.append(settingsData)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileIdentity(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(url.standardizedFileURL.path)|\(size)|\(String(format: "%.6f", modified))"
    }

    private static func cacheRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ChronoVolume/HighPrecisionCache", isDirectory: true)
    }

    private static func safeName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private static func sourceCacheContext(for sourceURL: URL, preserveAlpha: Bool) -> SourceCacheContext {
        let pathDigest = SHA256.hash(data: Data(sourceURL.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = cacheRoot().appendingPathComponent(
            "\(safeName(sourceURL))_source_\(pathDigest.prefix(20))",
            isDirectory: true
        )
        return SourceCacheContext(
            sourceURL: sourceURL,
            preserveAlpha: preserveAlpha,
            directory: directory,
            movieURL: directory.appendingPathComponent(preserveAlpha ? "hp_cache_alpha.mov" : "hp_cache_opaque.mov"),
            metadataURL: directory.appendingPathComponent(preserveAlpha ? "hp_cache_alpha.json" : "hp_cache_opaque.json")
        )
    }

    static func buildCache(
        from pair: VideoSourcePair,
        preserveAlpha: Bool,
        highPrecisionAlpha: HighPrecisionAlphaVolume?,
        memoryBudget: VideoVolumeMemoryBudget? = nil,
        sidecarHashProvider: (@Sendable (URL) async -> String?)? = nil,
        progress: @escaping (Double, String) -> Void
    ) async throws -> URL {
        let context = makeCacheContext(for: pair, preserveAlpha: preserveAlpha)
        if pair.usesGeneratedWhiteColor {
            throw HighPrecisionCacheError.invalidSource(
                "B_alpha 白模可用于交互式 RGBA8 预览和普通本机 RGBA8 导出；只有不超过 8-bit 的 B_alpha 可进入当前分布式 RGBA8 paired renderer。B-only 高精度缓存尚不支持，已明确拒绝以避免把 B_alpha 灰度误作颜色。"
            )
        }
        let sourceContext = sourceCacheContext(for: pair.colorURL, preserveAlpha: preserveAlpha)
        let initialSourceHashes = await captureSourceHashes(for: pair)
        guard initialSourceHashes.color != nil,
              pair.alphaURL == nil || initialSourceHashes.alpha != nil else {
            throw HighPrecisionCacheError.invalidSource("无法读取 A_color 或 B_alpha 以计算内容哈希")
        }
        let sourceAlpha: HighPrecisionAlphaVolume?
        if preserveAlpha, pair.alphaSourceMode == .external {
            guard let alphaURL = pair.alphaURL else {
                throw HighPrecisionCacheError.invalidSource("external Alpha 模式缺少 B_alpha URL")
            }
            let estimate = try await validatePairedVolumeMemoryBudget(
                colorURL: pair.colorURL,
                fallbackDepth: nil,
                budgetBytesOverride: memoryBudget?.maxPeakBytes
            )
            let pairedBudget = memoryBudget ?? VideoVolumeMemoryBudget(maxPeakBytes: estimate.budgetBytes)
            sourceAlpha = try await VideoVolumeLoader.loadHighPrecisionExternalAlpha(
                colorURL: pair.colorURL,
                alphaURL: alphaURL,
                settings: pair.externalAlphaSettings,
                memoryBudget: pairedBudget
            )
        } else {
            sourceAlpha = highPrecisionAlpha
        }
        let temporaryMovie = try await buildCache(context: sourceContext, progress: progress)
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: context.movieURL)
        try FileManager.default.copyItem(at: temporaryMovie, to: context.movieURL)

        var metadata = try loadMetadata(context: sourceContext)
        metadata.cacheKey = context.key
        metadata.alphaSourcePath = pair.alphaURL?.path
        metadata.sourceAlphaBitDepth = sourceAlpha?.sourceBitDepth
        metadata.previewAlphaBitDepth = pair.alphaSourceMode == .external ? 8 : nil
        metadata.externalAlphaSettings = pair.alphaSourceMode == .external ? pair.externalAlphaSettings : nil

        metadata.colorSourceSHA256 = initialSourceHashes.color
        metadata.alphaSourceSHA256 = initialSourceHashes.alpha
        if preserveAlpha, let alpha = sourceAlpha {
            try writeAlphaSidecarStreaming(samples: alpha.samples, to: context.alphaSidecarURL)
            metadata.alphaSidecarFileName = context.alphaSidecarURL.lastPathComponent
            metadata.alphaSidecarWidth = alpha.width
            metadata.alphaSidecarHeight = alpha.height
            metadata.alphaSidecarDepth = alpha.depth
            metadata.alphaSampleFormat = "uint16_normalized"
            metadata.alphaEndianness = "little"
            metadata.alphaPresentationTimes = alpha.presentationTimes
            metadata.alphaSourceRange = alpha.sourceRange
            let sidecarHash: String?
            if let sidecarHashProvider {
                sidecarHash = await sidecarHashProvider(context.alphaSidecarURL)
            } else {
                sidecarHash = await contentSHA256InBackground(context.alphaSidecarURL)
            }
            guard let sidecarHash, !sidecarHash.isEmpty else {
                try? FileManager.default.removeItem(at: context.directory)
                throw HighPrecisionCacheError.metadataWriteFailed(
                    "无法生成 Alpha sidecar SHA-256；已删除本次不完整缓存"
                )
            }
            metadata.alphaSidecarSHA256 = sidecarHash
        }
        let finalSourceHashes = await captureSourceHashes(for: pair)
        guard finalSourceHashes == initialSourceHashes else {
            try? FileManager.default.removeItem(at: context.directory)
            throw HighPrecisionCacheError.invalidSource(
                "缓存构建期间 A_color 或 B_alpha 内容发生变化，已丢弃不一致缓存"
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: context.metadataURL, options: .atomic)
        return context.movieURL
    }

    static func loadAlphaSidecar(
        for pair: VideoSourcePair,
        memoryBudget: VideoVolumeMemoryBudget? = nil
    ) async throws -> HighPrecisionAlphaVolume {
        let validated = try await validateAlphaSidecarContext(for: pair, memoryBudget: memoryBudget)
        return try loadAlphaSidecar(validated: validated)
    }

    private static func validateAlphaSidecarContext(
        for pair: VideoSourcePair,
        memoryBudget: VideoVolumeMemoryBudget?
    ) async throws -> ValidatedAlphaSidecarContext {
        let context = makeCacheContext(for: pair, preserveAlpha: true)
        let metadata = try loadMetadata(context: context)
        guard let expectedHash = metadata.alphaSidecarSHA256, !expectedHash.isEmpty else {
            throw HighPrecisionCacheError.metadataReadFailed(
                "external Alpha 缓存版本过旧或缓存不完整：缺少 sidecar SHA-256，请重新建立缓存"
            )
        }
        guard let width = metadata.alphaSidecarWidth,
              let height = metadata.alphaSidecarHeight,
              let depth = metadata.alphaSidecarDepth,
              metadata.alphaSampleFormat == "uint16_normalized",
              metadata.alphaEndianness == "little" else {
            throw HighPrecisionCacheError.metadataReadFailed("Alpha sidecar 元数据不完整")
        }
        let sampleCount = try checkedDimensionProduct(
            [width, height, depth],
            context: "Alpha sidecar samples"
        )
        let expectedBytes = try checkedDimensionProduct(
            [sampleCount, MemoryLayout<UInt16>.size],
            context: "Alpha sidecar bytes"
        )
        let budget = memoryBudget ?? VideoVolumeMemoryBudget(maxPeakBytes: configuredPairedVolumeMemoryBudget())
        let estimate = try makePairedVolumeMemoryEstimate(
            width: width,
            height: height,
            depth: depth,
            budgetBytes: budget.maxPeakBytes
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: context.alphaSidecarURL.path)
        guard let sizeNumber = attributes[.size] as? NSNumber,
              sizeNumber.int64Value >= 0 else {
            throw HighPrecisionCacheError.metadataReadFailed("无法读取 Alpha sidecar 文件大小")
        }
        guard UInt64(expectedBytes) == sizeNumber.uint64Value else {
            throw HighPrecisionCacheError.metadataReadFailed(
                "Alpha sidecar 大小不匹配：预期 \(expectedBytes)，实际 \(sizeNumber.uint64Value)"
            )
        }
        let sourceHashes = await captureSourceHashes(for: pair)
        try validateSourceHashes(metadata: metadata, pair: pair, hashes: sourceHashes)
        guard await contentSHA256InBackground(context.alphaSidecarURL) == expectedHash else {
            throw HighPrecisionCacheError.metadataReadFailed("Alpha sidecar SHA-256 校验失败")
        }
        return ValidatedAlphaSidecarContext(
            cacheContext: context,
            metadata: metadata,
            width: width,
            height: height,
            depth: depth,
            sampleCount: sampleCount,
            expectedByteCount: expectedBytes,
            memoryEstimate: estimate,
            memoryBudget: budget
        )
    }

    private static func loadAlphaSidecar(
        validated: ValidatedAlphaSidecarContext
    ) throws -> HighPrecisionAlphaVolume {
        let data = try Data(contentsOf: validated.cacheContext.alphaSidecarURL, options: .mappedIfSafe)
        validated.memoryBudget.record(.alphaSidecarDataMapped)
        guard data.count == validated.expectedByteCount else {
            throw HighPrecisionCacheError.metadataReadFailed(
                "Alpha sidecar 映射后大小不匹配：预期 \(validated.expectedByteCount)，实际 \(data.count)"
            )
        }
        var samples = [UInt16](repeating: 0, count: validated.sampleCount)
        validated.memoryBudget.record(.alphaSidecarSamplesAllocated)
        data.withUnsafeBytes { bytes in
            let source = bytes.bindMemory(to: UInt8.self)
            for index in samples.indices {
                samples[index] = UInt16(source[index * 2]) | (UInt16(source[index * 2 + 1]) << 8)
            }
        }
        return HighPrecisionAlphaVolume(
            width: validated.width,
            height: validated.height,
            depth: validated.depth,
            samples: samples,
            sourceBitDepth: validated.metadata.sourceAlphaBitDepth ?? 16,
            sourceRange: validated.metadata.alphaSourceRange ?? .full,
            presentationTimes: validated.metadata.alphaPresentationTimes ?? []
        )
    }

    static func loadMergedSourceCPUVolume(
        for pair: VideoSourcePair,
        memoryBudget: VideoVolumeMemoryBudget? = nil
    ) async throws -> CPUVolume {
        guard let alphaURL = pair.alphaURL else {
            throw HighPrecisionCacheError.invalidSource("缺少 B_alpha URL")
        }
        let validatedSidecar = try await validateAlphaSidecarContext(for: pair, memoryBudget: memoryBudget)
        let estimate = validatedSidecar.memoryEstimate
        let sidecar = try loadAlphaSidecar(validated: validatedSidecar)
        let package = try await VideoVolumeLoader.load(
            colorURL: pair.colorURL,
            alphaURL: alphaURL,
            settings: pair.externalAlphaSettings,
            generatedWhiteColor: pair.usesGeneratedWhiteColor,
            maxWidth: max(16_384, sidecar.width),
            maxHeight: max(16_384, sidecar.height),
            previewMaxDepth: Int.max,
            memoryBudget: validatedSidecar.memoryBudget
        )
        let volume = package.fullTemporalVolume
        _ = try validateDecodedPairedVolumeMemoryBudget(
            width: volume.width,
            height: volume.height,
            actualDepth: volume.depth,
            preflightEstimate: estimate
        )
        guard volume.width == sidecar.width,
              volume.height == sidecar.height,
              volume.depth == sidecar.depth else {
            throw HighPrecisionCacheError.invalidSource(
                "合并体与 Alpha sidecar 尺寸不一致：体 \(volume.width)×\(volume.height)×\(volume.depth)，sidecar \(sidecar.width)×\(sidecar.height)×\(sidecar.depth)"
            )
        }
        var rgba = volume.rgba
        for index in sidecar.samples.indices {
            rgba[index * 4 + 3] = UInt8(min(255, max(0, Int((Double(sidecar.samples[index]) / 257.0).rounded()))))
        }
        return CPUVolume(
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            rgba: rgba,
            hasMeaningfulAlpha: true,
            sourceColorProfile: package.sourceColorProfile,
            presentationTimes: sidecar.presentationTimes,
            alphaAssociation: .straight
        )
    }

    static func prepareSourceResolutionPairedVolume(
        for pair: VideoSourcePair,
        validatedEstimate: PairedVolumeMemoryEstimate? = nil
    ) async throws -> (volume: CPUVolume, diagnostic: String) {
        guard pair.alphaSourceMode == .external, let alphaURL = pair.alphaURL else {
            throw HighPrecisionCacheError.invalidSource("源分辨率 paired volume 需要 external B_alpha")
        }
        let estimate: PairedVolumeMemoryEstimate
        if let validatedEstimate {
            estimate = validatedEstimate
        } else {
            estimate = try await validatePairedVolumeMemoryBudget(
                colorURL: pair.colorURL,
                fallbackDepth: nil,
                generatedWhiteColor: pair.usesGeneratedWhiteColor
            )
        }
        let package = try await VideoVolumeLoader.load(
            colorURL: pair.colorURL,
            alphaURL: alphaURL,
            settings: pair.externalAlphaSettings,
            generatedWhiteColor: pair.usesGeneratedWhiteColor,
            maxWidth: estimate.width,
            maxHeight: estimate.height,
            previewMaxDepth: Int.max,
            memoryBudget: VideoVolumeMemoryBudget(maxPeakBytes: estimate.budgetBytes)
        )
        let loaded = package.fullTemporalVolume
        let actualEstimate = try validateDecodedPairedVolumeMemoryBudget(
            width: loaded.width,
            height: loaded.height,
            actualDepth: loaded.depth,
            preflightEstimate: estimate
        )
        guard loaded.width == estimate.width, loaded.height == estimate.height else {
            throw HighPrecisionCacheError.invalidSource(
                "源分辨率合并失败：预期 \(estimate.width)×\(estimate.height)，实际 \(loaded.width)×\(loaded.height)"
            )
        }
        return (
            CPUVolume(
                width: loaded.width,
                height: loaded.height,
                depth: loaded.depth,
                rgba: loaded.rgba,
                hasMeaningfulAlpha: true,
                sourceColorProfile: package.sourceColorProfile,
                presentationTimes: package.highPrecisionAlphaVolume?.presentationTimes ?? [],
                alphaAssociation: .straight
            ),
            actualEstimate.diagnostic
        )
    }

    static func validatePairedVolumeMemoryBudget(
        colorURL: URL,
        fallbackDepth: Int?,
        budgetBytesOverride: UInt64? = nil,
        generatedWhiteColor: Bool = false
    ) async throws -> PairedVolumeMemoryEstimate {
        if generatedWhiteColor {
            let probe = try await Task.detached(priority: .utility) {
                try VideoVolumeLoader.probeExternalSource(colorURL)
            }.value
            let depth = fallbackDepth ?? (!probe.presentationTimes.isEmpty
                ? probe.presentationTimes.count
                : probe.metadata.frameCount)
            guard depth > 0 else {
                throw HighPrecisionCacheError.invalidSource("无法取得 B_alpha 的实际逐帧 PTS 或可靠帧数，不能估算白模 paired volume 内存")
            }
            return try makePairedVolumeMemoryEstimate(
                width: probe.metadata.displayWidth,
                height: probe.metadata.displayHeight,
                depth: depth,
                budgetBytes: budgetBytesOverride ?? configuredPairedVolumeMemoryBudget()
            )
        }
        let asset = AVURLAsset(url: colorURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw HighPrecisionCacheError.invalidSource("A_color 没有视频轨道")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = natural.applying(transform)
        let width = max(1, Int(abs(transformed.width).rounded()))
        let height = max(1, Int(abs(transformed.height).rounded()))
        let actualDepth: Int
        if let fallbackDepth {
            actualDepth = fallbackDepth
        } else {
            let presentationTimes = try await probeDecodedPresentationTimes(colorURL)
            let probe = FrameDepthProbeResult(
                presentationTimes: presentationTimes,
                reliableFrameCount: presentationTimes.count,
                nominalFrameRate: Double(try await track.load(.nominalFrameRate)),
                durationSeconds: max(0, CMTimeGetSeconds(try await asset.load(.duration)))
            )
            guard let resolvedDepth = resolvedFrameDepthForMemoryBudget(probe) else {
                throw HighPrecisionCacheError.invalidSource("无法取得 A_color 的实际逐帧 PTS，不能可靠估算 paired volume 内存")
            }
            actualDepth = resolvedDepth
        }
        return try makePairedVolumeMemoryEstimate(
            width: width,
            height: height,
            depth: actualDepth,
            budgetBytes: budgetBytesOverride ?? configuredPairedVolumeMemoryBudget()
        )
    }

    static func validateDecodedPairedVolumeMemoryBudget(
        width: Int,
        height: Int,
        actualDepth: Int,
        preflightEstimate: PairedVolumeMemoryEstimate
    ) throws -> PairedVolumeMemoryEstimate {
        do {
            return try makePairedVolumeMemoryEstimate(
                width: width,
                height: height,
                depth: actualDepth,
                budgetBytes: preflightEstimate.budgetBytes
            )
        } catch {
            throw HighPrecisionCacheError.invalidSource(
                "实际解码尺寸 \(width)×\(height)×\(actualDepth) 超出 paired volume 内存预算，已在构建 CPUVolume 前拒绝：\(error.localizedDescription)"
            )
        }
    }

    static func resolvedFrameDepthForMemoryBudget(_ probe: FrameDepthProbeResult) -> Int? {
        if !probe.presentationTimes.isEmpty {
            return probe.presentationTimes.count
        }
        if let reliableFrameCount = probe.reliableFrameCount, reliableFrameCount > 0 {
            return reliableFrameCount
        }
        // nominalFrameRate and duration are diagnostic-only for VFR sources.
        // Their product must never be promoted to a reliable volume depth.
        return nil
    }

    static func makePairedVolumeMemoryEstimate(
        width: Int,
        height: Int,
        depth: Int,
        budgetBytes: UInt64
    ) throws -> PairedVolumeMemoryEstimate {
        guard width > 0, height > 0, depth > 0 else {
            throw HighPrecisionCacheError.invalidSource("源分辨率或实际帧数无效：\(width)×\(height)×\(depth)")
        }
        let voxelCount = UInt64(width)
            .multipliedReportingOverflow(by: UInt64(height))
        guard !voxelCount.overflow else {
            throw HighPrecisionCacheError.invalidSource("源分辨率体素数溢出")
        }
        let fullVoxelCount = voxelCount.partialValue.multipliedReportingOverflow(by: UInt64(depth))
        guard !fullVoxelCount.overflow else {
            throw HighPrecisionCacheError.invalidSource("源分辨率体素数溢出")
        }
        // Current decoder temporarily retains decoded A, decoded B, merged RGBA,
        // normalized UInt16 Alpha and packing buffers. Reject before allocation
        // using a conservative 24 bytes/voxel peak estimate.
        let peak = fullVoxelCount.partialValue.multipliedReportingOverflow(by: 24)
        guard !peak.overflow else {
            throw HighPrecisionCacheError.invalidSource("预计峰值内存溢出")
        }
        let estimate = PairedVolumeMemoryEstimate(
            width: width,
            height: height,
            depth: depth,
            estimatedPeakBytes: peak.partialValue,
            budgetBytes: budgetBytes
        )
        guard estimate.estimatedPeakBytes <= estimate.budgetBytes else {
            throw HighPrecisionCacheError.invalidSource(
                estimate.diagnostic + "；当前尚未完成全流式 paired 解码，已拒绝超预算素材"
            )
        }
        return estimate
    }

    private static func checkedDimensionProduct(_ factors: [Int], context: String) throws -> Int {
        var result = 1
        for factor in factors {
            guard factor > 0 else {
                throw HighPrecisionCacheError.metadataReadFailed(
                    "\(context) 包含无效尺寸：\(factors)"
                )
            }
            let multiplied = result.multipliedReportingOverflow(by: factor)
            guard !multiplied.overflow else {
                throw HighPrecisionCacheError.metadataReadFailed(
                    "\(context) 尺寸乘法溢出：\(factors)"
                )
            }
            result = multiplied.partialValue
        }
        return result
    }

    private static func configuredPairedVolumeMemoryBudget() -> UInt64 {
        let environmentBudget = ProcessInfo.processInfo.environment["CHRONOVOLUME_PAIRED_MEMORY_BUDGET_BYTES"]
            .flatMap(UInt64.init)
        let defaultBudget = max(
            UInt64(512 * 1024 * 1024),
            min(UInt64(4 * 1024 * 1024 * 1024), ProcessInfo.processInfo.physicalMemory / 3)
        )
        return environmentBudget ?? defaultBudget
    }

    private static func probeDecodedPresentationTimes(_ url: URL) async throws -> [Double] {
        try await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw HighPrecisionCacheError.invalidSource("A_color 没有视频轨道")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw HighPrecisionCacheError.invalidSource("无法为内存预算探测添加 A_color 解码输出")
            }
            reader.add(output)
            guard reader.startReading() else {
                throw HighPrecisionCacheError.invalidSource(
                    "无法启动 A_color 逐帧内存预算探测：\(reader.error?.localizedDescription ?? "未知错误")"
                )
            }
            var presentationTimes: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                presentationTimes.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
            }
            if reader.status == .failed {
                throw HighPrecisionCacheError.invalidSource(
                    "A_color 逐帧内存预算探测失败：\(reader.error?.localizedDescription ?? "未知错误")"
                )
            }
            return presentationTimes
        }.value
    }

    private static func contentSHA256(_ url: URL) -> String? {
        ContentHashAudit.observer?(url)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func withContentHashObserver<T>(
        _ observer: @escaping @Sendable (URL) -> Void,
        operation: () throws -> T
    ) rethrows -> T {
        try ContentHashAudit.$observer.withValue(observer, operation: operation)
    }

    private static func contentSHA256InBackground(_ url: URL) async -> String? {
        await Task.detached(priority: .utility) { contentSHA256(url) }.value
    }

    private static func captureSourceHashes(for pair: VideoSourcePair) async -> SourceContentHashes {
        await Task.detached(priority: .utility) {
            SourceContentHashes(
                color: contentSHA256(pair.colorURL),
                alpha: pair.alphaURL.flatMap(contentSHA256)
            )
        }.value
    }

    private static func loadMetadata(context: CacheContext) throws -> HighPrecisionCacheMetadata {
        let data = try Data(contentsOf: context.metadataURL)
        return try JSONDecoder().decode(HighPrecisionCacheMetadata.self, from: data)
    }

    private static func loadMetadata(context: SourceCacheContext) throws -> HighPrecisionCacheMetadata {
        let data = try Data(contentsOf: context.metadataURL)
        return try JSONDecoder().decode(HighPrecisionCacheMetadata.self, from: data)
    }

    private static func hashesMatch(
        metadata: HighPrecisionCacheMetadata,
        pair: VideoSourcePair,
        hashes: SourceContentHashes
    ) -> Bool {
        metadata.colorSourceSHA256 != nil &&
        metadata.colorSourceSHA256 == hashes.color &&
        (pair.alphaURL == nil || (
            metadata.alphaSourceSHA256 != nil &&
            metadata.alphaSourceSHA256 == hashes.alpha
        ))
    }

    private static func validateSourceHashes(
        metadata: HighPrecisionCacheMetadata,
        pair: VideoSourcePair,
        hashes: SourceContentHashes
    ) throws {
        guard hashesMatch(metadata: metadata, pair: pair, hashes: hashes) else {
            throw HighPrecisionCacheError.metadataReadFailed(
                "A_color 或 B_alpha 内容哈希已变化，缓存失效，请重新建立高精度缓存"
            )
        }
    }

    private static func writeAlphaSidecarStreaming(samples: [UInt16], to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer { try? handle.close() }
        let chunkSamples = 262_144
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + chunkSamples)
            var bytes = [UInt8](repeating: 0, count: (end - offset) * 2)
            for index in offset..<end {
                let value = samples[index]
                let destination = (index - offset) * 2
                bytes[destination] = UInt8(truncatingIfNeeded: value)
                bytes[destination + 1] = UInt8(truncatingIfNeeded: value >> 8)
            }
            try handle.write(contentsOf: bytes)
            offset = end
        }
        try handle.synchronize()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    static func cacheMetadataURL(for sourceURL: URL, preserveAlpha: Bool) -> URL {
        sourceCacheContext(for: sourceURL, preserveAlpha: preserveAlpha).metadataURL
    }

    static func hasCache(for sourceURL: URL, preserveAlpha: Bool) -> Bool {
        let context = sourceCacheContext(for: sourceURL, preserveAlpha: preserveAlpha)
        return FileManager.default.fileExists(atPath: context.movieURL.path) &&
               FileManager.default.fileExists(atPath: context.metadataURL.path)
    }

    static func validatedCacheURL(for sourceURL: URL, preserveAlpha: Bool) async throws -> URL {
        let context = sourceCacheContext(for: sourceURL, preserveAlpha: preserveAlpha)
        guard FileManager.default.fileExists(atPath: context.movieURL.path),
              FileManager.default.fileExists(atPath: context.metadataURL.path) else {
            throw HighPrecisionCacheError.metadataReadFailed("高精度缓存 MOV 或 metadata 不存在")
        }
        let currentHash = await contentSHA256InBackground(sourceURL)
        let metadata = try loadMetadata(context: context)
        guard let expectedHash = metadata.colorSourceSHA256,
              expectedHash == currentHash else {
            throw HighPrecisionCacheError.metadataReadFailed(
                "A_color 内容哈希已变化，缓存失效，请重新建立高精度缓存"
            )
        }
        return context.movieURL
    }

    static func loadMetadata(for sourceURL: URL, preserveAlpha: Bool) throws -> HighPrecisionCacheMetadata {
        let context = sourceCacheContext(for: sourceURL, preserveAlpha: preserveAlpha)
        let data: Data
        do {
            data = try Data(contentsOf: context.metadataURL)
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
        let context = sourceCacheContext(for: sourceURL, preserveAlpha: false)
        try? FileManager.default.removeItem(at: context.directory)
    }

    static func buildCache(
        from sourceURL: URL,
        preserveAlpha: Bool,
        progress: @escaping (Double, String) -> Void
    ) async throws -> URL {
        let context = sourceCacheContext(for: sourceURL, preserveAlpha: preserveAlpha)
        let initialHash = await contentSHA256InBackground(sourceURL)
        guard initialHash != nil else { throw HighPrecisionCacheError.sourceNotFound }
        let movieURL = try await buildCache(context: context, progress: progress)
        let finalHash = await contentSHA256InBackground(sourceURL)
        guard finalHash == initialHash else {
            try? FileManager.default.removeItem(at: context.directory)
            throw HighPrecisionCacheError.invalidSource("缓存构建期间 A_color 内容发生变化，已丢弃不一致缓存")
        }
        var metadata = try loadMetadata(context: context)
        metadata.colorSourceSHA256 = initialHash
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: context.metadataURL, options: .atomic)
        return movieURL
    }

    private static func buildCache(
        context: SourceCacheContext,
        progress: @escaping (Double, String) -> Void
    ) async throws -> URL {
        let sourceURL = context.sourceURL
        let preserveAlpha = context.preserveAlpha
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

        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)

        let outputURL = context.movieURL
        let metadataURL = context.metadataURL

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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL)
        } catch {
            throw HighPrecisionCacheError.metadataWriteFailed(error.localizedDescription)
        }

        progress(1.0, "高精度缓存建立完成")
        return outputURL
    }
}
