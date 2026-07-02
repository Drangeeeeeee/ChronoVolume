import Foundation

enum WorkerJobExecutorError: LocalizedError {
    case invalidRange
    case sourceMissing(String)
    case outputDirectoryCreateFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "分段范围无效"
        case .sourceMissing(let path):
            return "源文件不存在：\(path)"
        case .outputDirectoryCreateFailed(let reason):
            return "创建输出目录失败：\(reason)"
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
            .appendingPathComponent("segment_\(request.mode == .plane ? "plane" : request.axis.rawValue)_\(request.outputStartFrame)_\(request.outputEndFrame).mov")

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
            fileName: outURL.lastPathComponent,
            fileSizeBytes: size
        )

        return SegmentExecutionResult(segmentURL: outURL, metadata: meta)
    }
}

final class WorkerJobExecutor {
    private let exporter: DistributedRangeExporter
    private static let minWorkerBatchBudget = 768 * 1024 * 1024
    private static let maxWorkerBatchBudget = 3 * 1024 * 1024 * 1024

    init(exporter: DistributedRangeExporter = RealDistributedRangeExporter()) {
        self.exporter = exporter
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

        let outputDir = URL(fileURLWithPath: request.outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            throw WorkerJobExecutorError.outputDirectoryCreateFailed(error.localizedDescription)
        }

        let internalRequest = DistributedRangeExportRequest(
            jobID: job.jobID,
            localSourcePath: request.localSourcePath,
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
            outputDirectory: outputDir,
            preparedRawCacheURL: request.preparedRawCachePath.map {
                URL(fileURLWithPath: $0)
            },
            preparedRawCacheData: preparedRawCacheData,
            preparedCPUVolume: preparedCPUVolume,
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
}
