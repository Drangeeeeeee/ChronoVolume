import Foundation
import CryptoKit

enum WorkerJobExecutorError: LocalizedError {
    case invalidRange
    case sourceMissing(String)
    case outputDirectoryCreateFailed(String)
    case sourceHashMismatch(name: String)
    case externalAlphaLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "分段范围无效"
        case .sourceMissing(let path):
            return "源文件不存在：\(path)"
        case .outputDirectoryCreateFailed(let reason):
            return "创建输出目录失败：\(reason)"
        case .sourceHashMismatch(let name):
            return "分布式源文件哈希校验失败：\(name)"
        case .externalAlphaLoadFailed(let reason):
            return "Worker 双源解码失败：\(reason)"
        }
    }
}

struct SegmentExecutionResult {
    let segmentURL: URL
    let metadata: SegmentMetadata
}

protocol DistributedRangeExporter {
    func exportSegment(
        request: DistributedRangeExportRequest,
        progress: @escaping (Double, String) -> Void
    ) throws -> SegmentExecutionResult
}

final class RealDistributedRangeExporter: DistributedRangeExporter {
    func exportSegment(
        request: DistributedRangeExportRequest,
        progress: @escaping (Double, String) -> Void
    ) throws -> SegmentExecutionResult {
        let outURL = request.outputDirectory
            .appendingPathComponent("segment_\(request.jobID.uuidString)_\(request.mode == .plane ? "plane" : request.axis.rawValue)_\(request.outputStartFrame)_\(request.outputEndFrame).mov")

        try VideoExportHelper.exportHighPrecisionDistributedSegment(
            outputURL: outURL,
            sourceURL: URL(fileURLWithPath: request.localSourcePath),
            mode: request.mode,
            axis: request.axis == .x ? .x : .y,
            referencePlane: request.referencePlane,
            sourceWidth: request.sourceWidth,
            sourceHeight: request.sourceHeight,
            sourceFrameCount: request.sourceFrameCount,
            fps: request.fps,
            preserveAlpha: request.preserveAlpha,
            padToEven: request.padToEven,
            qualityScale: request.qualityScale,
            outputStartFrame: request.outputStartFrame,
            outputEndFrame: request.outputEndFrame,
            preparedRawCacheURL: request.preparedRawCacheURL,
            preparedRawCacheData: request.preparedRawCacheData,
            preparedCPUVolume: request.preparedCPUVolume,
            highPrecisionBatchByteBudget: request.highPrecisionBatchByteBudget,
            bitDepth: request.bitDepth,
            colorProfile: request.colorProfile,
            progress: { p, text in
                progress(p, text ?? "")
            }
        )

        let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        let meta = SegmentMetadata(
            jobID: request.jobID,
            segmentIndex: 0,
            axis: request.axis.rawValue,
            outputStartFrame: request.outputStartFrame,
            outputEndFrame: request.outputEndFrame,
            outputWidth: request.outputWidth,
            outputHeight: request.outputHeight,
            fps: request.fps,
            preserveAlpha: request.preserveAlpha,
            codec: request.codec,
            outputBitDepth: request.bitDepth,
            alphaAssociation: request.preparedCPUVolume?.alphaAssociation ?? .straight,
            fileName: outURL.lastPathComponent,
            fileSizeBytes: size
        )

        return SegmentExecutionResult(segmentURL: outURL, metadata: meta)
    }
}

final class WorkerJobExecutor {
    private let exporter: DistributedRangeExporter
    private let pairedVolumeMemoryBudgetBytes: UInt64?
    private static let minWorkerBatchBudget = 768 * 1024 * 1024
    private static let maxWorkerBatchBudget = 3 * 1024 * 1024 * 1024

    init(
        exporter: DistributedRangeExporter = RealDistributedRangeExporter(),
        pairedVolumeMemoryBudgetBytes: UInt64? = nil
    ) {
        self.exporter = exporter
        self.pairedVolumeMemoryBudgetBytes = pairedVolumeMemoryBudgetBytes
    }

    func execute(
        request: StartDistributedJobRequest,
        preparedRawCacheData: Data? = nil,
        preparedCPUVolume: CPUVolume? = nil,
        progress: @escaping (Double, String) -> Void
    ) throws -> SegmentExecutionResult {
        let job = request.job

        guard job.outputEndFrame >= job.outputStartFrame else {
            throw WorkerJobExecutorError.invalidRange
        }

        guard FileManager.default.fileExists(atPath: request.localSourcePath) else {
            throw WorkerJobExecutorError.sourceMissing(request.localSourcePath)
        }
        guard Self.sha256(path: request.localSourcePath) == job.sourceFileHash else {
            throw WorkerJobExecutorError.sourceHashMismatch(name: job.sourceFileName)
        }

        let generatedWhiteColor = job.usesGeneratedWhiteColor ?? false
        let effectiveExternalAlphaSettings = (job.externalAlphaSettings ?? ExternalAlphaSettings())
            .applyingGeneratedWhiteColorSemantics(generatedWhiteColor)
        var effectiveCPUVolume = preparedCPUVolume
        if job.alphaSourceMode == .external {
            if let rejection = ExternalPairedRenderPolicy.rejectionReason(
                sourceColorBitDepth: job.sourceColorBitDepth ?? 8,
                sourceAlphaBitDepth: job.sourceAlphaBitDepth ?? 8,
                outputBitDepth: job.outputBitDepth ?? 8,
                usesGeneratedWhiteColor: generatedWhiteColor
            ) {
                throw WorkerJobExecutorError.externalAlphaLoadFailed(
                    rejection
                )
            }
            guard let alphaPath = request.localAlphaSourcePath,
                  FileManager.default.fileExists(atPath: alphaPath) else {
                throw WorkerJobExecutorError.sourceMissing(request.localAlphaSourcePath ?? "B_alpha")
            }
            if let expected = job.alphaSourceFileHash,
               Self.sha256(path: alphaPath) != expected {
                throw WorkerJobExecutorError.sourceHashMismatch(name: job.alphaSourceFileName ?? "B_alpha")
            }
            let pairedVolume = try Self.loadExternalAlphaCPUVolume(
                colorPath: request.localSourcePath,
                alphaPath: alphaPath,
                settings: effectiveExternalAlphaSettings,
                generatedWhiteColor: generatedWhiteColor,
                memoryBudgetBytes: pairedVolumeMemoryBudgetBytes
            )
            guard pairedVolume.width == job.sourceWidth,
                  pairedVolume.height == job.sourceHeight,
                  pairedVolume.depth == job.sourceFrameCount else {
                throw WorkerJobExecutorError.externalAlphaLoadFailed(
                    "Worker paired volume \(pairedVolume.width)×\(pairedVolume.height)×\(pairedVolume.depth) 与主机 manifest \(job.sourceWidth)×\(job.sourceHeight)×\(job.sourceFrameCount) 不一致"
                )
            }
            if let expectedPTS = job.sourcePresentationTimes, !expectedPTS.isEmpty {
                guard expectedPTS.count == pairedVolume.presentationTimes.count else {
                    throw WorkerJobExecutorError.externalAlphaLoadFailed("Worker PTS 数量与主机不一致")
                }
                for (host, worker) in zip(expectedPTS, pairedVolume.presentationTimes) where abs(host - worker) > 0.000_001 {
                    throw WorkerJobExecutorError.externalAlphaLoadFailed(
                        "Worker PTS 与主机不一致：host=\(host)，worker=\(worker)"
                    )
                }
            }
            if let expectedAssociation = job.alphaAssociation,
               pairedVolume.alphaAssociation != expectedAssociation {
                throw WorkerJobExecutorError.externalAlphaLoadFailed(
                    "Worker Alpha association \(pairedVolume.alphaAssociation.rawValue) 与主机 \(expectedAssociation.rawValue) 不一致"
                )
            }
            effectiveCPUVolume = pairedVolume
        }

        let outputDir = URL(fileURLWithPath: request.outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            throw WorkerJobExecutorError.outputDirectoryCreateFailed(error.localizedDescription)
        }

        let internalRequest = DistributedRangeExportRequest(
            jobID: job.jobID,
            localSourcePath: request.localSourcePath,
            localAlphaSourcePath: request.localAlphaSourcePath,
            externalAlphaSettings: job.alphaSourceMode == .external ? effectiveExternalAlphaSettings : nil,
            mode: job.mode,
            axis: job.axis,
            referencePlane: job.referencePlane,
            preserveAlpha: job.preserveAlpha,
            padToEven: job.padToEven,
            qualityScale: job.qualityScale,
            sourceWidth: job.sourceWidth,
            sourceHeight: job.sourceHeight,
            sourceFrameCount: job.sourceFrameCount,
            fps: job.fps,
            outputWidth: job.outputWidth,
            outputHeight: job.outputHeight,
            outputStartFrame: job.outputStartFrame,
            outputEndFrame: job.outputEndFrame,
            codec: job.codec,
            colorProfile: job.colorProfile,
            bitDepth: job.outputBitDepth ?? 8,
            outputDirectory: outputDir,
            preparedRawCacheURL: request.preparedRawCachePath.map {
                URL(fileURLWithPath: $0)
            },
            preparedRawCacheData: preparedRawCacheData,
            preparedCPUVolume: effectiveCPUVolume,
            highPrecisionBatchByteBudget: Self.workerHighPrecisionBatchBudget()
        )

        return try exporter.exportSegment(
            request: internalRequest,
            progress: progress
        )
    }

    private static func workerHighPrecisionBatchBudget() -> Int {
        let physicalMemoryBudget = Int(min(UInt64(Int.max), ProcessInfo.processInfo.physicalMemory / 5))
        return min(max(physicalMemoryBudget, minWorkerBatchBudget), maxWorkerBatchBudget)
    }

    private final class LoadBox: @unchecked Sendable {
        var result: Result<CPUVolume, Error>?
    }

    private static func loadExternalAlphaCPUVolume(
        colorPath: String,
        alphaPath: String,
        settings: ExternalAlphaSettings,
        generatedWhiteColor: Bool,
        memoryBudgetBytes: UInt64?
    ) throws -> CPUVolume {
        let box = LoadBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let estimate = try await HighPrecisionCacheHelper.validatePairedVolumeMemoryBudget(
                    colorURL: URL(fileURLWithPath: colorPath),
                    fallbackDepth: nil,
                    budgetBytesOverride: memoryBudgetBytes,
                    generatedWhiteColor: generatedWhiteColor
                )
                let package = try await VideoVolumeLoader.load(
                    colorURL: URL(fileURLWithPath: colorPath),
                    alphaURL: URL(fileURLWithPath: alphaPath),
                    settings: settings,
                    generatedWhiteColor: generatedWhiteColor,
                    maxWidth: estimate.width,
                    maxHeight: estimate.height,
                    previewMaxDepth: Int.max,
                    memoryBudget: VideoVolumeMemoryBudget(maxPeakBytes: estimate.budgetBytes)
                )
                let volume = package.fullTemporalVolume
                guard let highPrecisionAlpha = package.highPrecisionAlphaVolume else {
                    throw WorkerJobExecutorError.externalAlphaLoadFailed("Worker 双源解码未返回高精度 Alpha")
                }
                guard volume.width == highPrecisionAlpha.width,
                      volume.height == highPrecisionAlpha.height,
                      volume.depth == highPrecisionAlpha.depth else {
                    throw WorkerJobExecutorError.externalAlphaLoadFailed(
                        "源分辨率 Alpha sidecar 与 Worker 体尺寸不一致"
                    )
                }
                var rgba = volume.rgba
                for index in highPrecisionAlpha.samples.indices {
                    rgba[index * 4 + 3] = UInt8(min(255, max(0, Int((Double(highPrecisionAlpha.samples[index]) / 257.0).rounded()))))
                }
                box.result = .success(CPUVolume(
                    width: volume.width,
                    height: volume.height,
                    depth: volume.depth,
                    rgba: rgba,
                    hasMeaningfulAlpha: true,
                    sourceColorProfile: package.sourceColorProfile,
                    presentationTimes: highPrecisionAlpha.presentationTimes,
                    alphaAssociation: .straight
                ))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else {
            throw WorkerJobExecutorError.externalAlphaLoadFailed("异步加载没有返回结果")
        }
        do {
            return try result.get()
        } catch {
            throw WorkerJobExecutorError.externalAlphaLoadFailed(error.localizedDescription)
        }
    }

    private static func sha256(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
