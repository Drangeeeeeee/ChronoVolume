import Foundation
import CryptoKit

enum DistributedCoordinatorError: LocalizedError {
    case invalidWorkerURL
    case sourceHashFailed(String)
    case sourceNotReadable(String)
    case badResponse
    case remoteStartFailed(String)
    case remoteResultFailed(String)
    case remoteDownloadFailed(String)
    case remoteUploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkerURL:
            return "Worker 地址无效"
        case .sourceHashFailed(let detail):
            return "无法计算源视频哈希：\(detail)"
        case .sourceNotReadable(let detail):
            return "源视频不可读：\(detail)"
        case .badResponse:
            return "Worker 返回格式无效"
        case .remoteStartFailed(let reason):
            return "Worker 启动任务失败：\(reason)"
        case .remoteResultFailed(let reason):
            return "Worker 结果获取失败：\(reason)"
        case .remoteDownloadFailed(let reason):
            return "Worker 分段下载失败：\(reason)"
        case .remoteUploadFailed(let reason):
            return "Worker 源文件上传失败：\(reason)"
        }
    }
}

struct DistributedSourceCheckRequest: Codable {
    let sourceFileHash: String
    let sourceFileName: String
}

struct DistributedSourceCheckResponse: Codable {
    let exists: Bool
    let localPath: String?
}

struct DistributedStartJobRequest: Codable {
    let job: DistributedJobManifest
    let localSourcePath: String
    let outputDirectory: String
    let preparedRawCachePath: String?
    var localAlphaSourcePath: String? = nil
}

struct DistributedStartJobBatchRequest: Codable {
    let batchID: UUID
    let jobs: [DistributedJobManifest]
    let localSourcePath: String
    let outputDirectory: String
    let preparedRawCachePath: String?
    var localAlphaSourcePath: String? = nil
}

struct DistributedPrepareSourceRequest: Codable {
    let sourceFileHash: String
    let sourceFileName: String
    let localSourcePath: String
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceFrameCount: Int
}

struct DistributedPrepareSourceResponse: Codable {
    let sourceFileHash: String
    let state: String
    let progress: Double
    let message: String
    let rawCachePath: String?
    let importedVolumeInfo: String?
    let error: String?
}

struct DistributedJobProgressResponse: Codable {
    let jobID: UUID
    let state: String
    let progress: Double
    let message: String
}

struct DistributedJobResultResponse: Codable {
    let jobID: UUID
    let state: String
    let segmentMetadata: SegmentMetadata?
    let segmentPath: String?
    let error: String?
}

struct DistributedJobBatchProgressResponse: Codable {
    let batchID: UUID
    let state: String
    let progress: Double
    let message: String
    let currentJobID: UUID?
    let completedJobIDs: [UUID]
    let error: String?
}

struct DistributedJobBatchResultResponse: Codable {
    let batchID: UUID
    let state: String
    let results: [DistributedJobResultResponse]
    let error: String?
}

struct DistributedGenericOKResponse: Codable {
    let ok: Bool
    let message: String
}

enum DistributedExportCoordinator {
    static let defaultUploadChunkSize = 64 * 1024 * 1024

    static func sha256Hex(of fileURL: URL) throws -> String {
        guard fileURL.isFileURL else {
            throw DistributedCoordinatorError.sourceHashFailed("当前源 URL 不是本地文件 URL：\(fileURL.absoluteString)")
        }

        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw DistributedCoordinatorError.sourceNotReadable("文件不存在：\(path)")
        }

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }

            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch {
            throw DistributedCoordinatorError.sourceHashFailed(error.localizedDescription)
        }
    }

    static func checkWorkerSource(
        workerURL: URL,
        sourceURL: URL
    ) async throws -> (hash: String, response: DistributedSourceCheckResponse) {
        let hash = try sha256Hex(of: sourceURL)

        let req = DistributedSourceCheckRequest(
            sourceFileHash: hash,
            sourceFileName: sourceURL.lastPathComponent
        )

        let response: DistributedSourceCheckResponse = try await postJSON(
            baseURL: workerURL,
            path: "/source/check",
            body: req
        )

        return (hash, response)
    }

    /// 使用原生 TCP 单连接流式传输源文件。
    ///
    /// HTTP 仍然用于任务控制和状态查询；大文件复制改走：
    ///   Worker HTTP 端口 + 1
    ///
    /// 例如：
    ///   Worker 控制地址 http://10.77.77.2:8787
    ///   文件流式传输端口 10.77.77.2:8788
    static func uploadSourceToWorker(
        workerURL: URL,
        sourceURL: URL,
        sourceHash: String,
        progress: @escaping (Double, String) async -> Void = { _, _ in }
    ) async throws {
        try await RawFileTransferClient.uploadSourceToWorker(
            workerURL: workerURL,
            sourceURL: sourceURL,
            sourceHash: sourceHash,
            progress: progress
        )
    }

    static func postClusterStatus(
        workerURL: URL,
        snapshot: DistributedClusterProgressSnapshot
    ) async {
        do {
            let _: DistributedGenericOKResponse = try await postJSON(
                baseURL: workerURL,
                path: "/cluster/status",
                body: snapshot
            )
        } catch {
            // 进度同步失败不应中断导出
        }
    }

    static func startRemoteWorkerJob(
        workerURL: URL,
        job: DistributedJobManifest,
        workerLocalSourcePath: String,
        outputDirectory: String = "/tmp/ChronoVolumeDistributed",
        preparedRawCachePath: String? = nil,
        workerLocalAlphaSourcePath: String? = nil
    ) async throws {
        let req = DistributedStartJobRequest(
            job: job,
            localSourcePath: workerLocalSourcePath,
            outputDirectory: outputDirectory,
            preparedRawCachePath: preparedRawCachePath,
            localAlphaSourcePath: workerLocalAlphaSourcePath
        )

        let response: DistributedGenericOKResponse = try await postJSON(
            baseURL: workerURL,
            path: "/job/start",
            body: req
        )

        guard response.ok else {
            throw DistributedCoordinatorError.remoteStartFailed(response.message)
        }
    }

    static func startRemoteWorkerJobBatch(
        workerURL: URL,
        batchID: UUID,
        jobs: [DistributedJobManifest],
        workerLocalSourcePath: String,
        outputDirectory: String = "/tmp/ChronoVolumeDistributed",
        preparedRawCachePath: String? = nil,
        workerLocalAlphaSourcePath: String? = nil
    ) async throws {
        let req = DistributedStartJobBatchRequest(
            batchID: batchID,
            jobs: jobs,
            localSourcePath: workerLocalSourcePath,
            outputDirectory: outputDirectory,
            preparedRawCachePath: preparedRawCachePath,
            localAlphaSourcePath: workerLocalAlphaSourcePath
        )

        let response: DistributedGenericOKResponse = try await postJSON(
            baseURL: workerURL,
            path: "/job/batch/start",
            body: req
        )

        guard response.ok else {
            throw DistributedCoordinatorError.remoteStartFailed(response.message)
        }
    }

    static func startWorkerSourcePrepare(
        workerURL: URL,
        sourceURL: URL,
        sourceHash: String,
        workerLocalSourcePath: String,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int
    ) async throws -> DistributedPrepareSourceResponse {
        let req = DistributedPrepareSourceRequest(
            sourceFileHash: sourceHash,
            sourceFileName: sourceURL.lastPathComponent,
            localSourcePath: workerLocalSourcePath,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceFrameCount: sourceFrameCount
        )

        return try await postJSON(
            baseURL: workerURL,
            path: "/source/prepare",
            body: req
        )
    }

    static func checkWorkerSourcePrepare(
        workerURL: URL,
        sourceURL: URL,
        sourceHash: String,
        workerLocalSourcePath: String,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int
    ) async throws -> DistributedPrepareSourceResponse {
        let req = DistributedPrepareSourceRequest(
            sourceFileHash: sourceHash,
            sourceFileName: sourceURL.lastPathComponent,
            localSourcePath: workerLocalSourcePath,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceFrameCount: sourceFrameCount
        )

        return try await postJSON(
            baseURL: workerURL,
            path: "/source/prepare/check",
            body: req
        )
    }

    static func pollWorkerSourcePrepare(
        workerURL: URL,
        sourceHash: String,
        onProgress: @escaping (DistributedPrepareSourceResponse) async -> Void
    ) async throws -> DistributedPrepareSourceResponse {
        while true {
            try await Task.sleep(nanoseconds: 500_000_000)
            let progress: DistributedPrepareSourceResponse = try await getJSON(
                baseURL: workerURL,
                path: "/source/prepare/progress?hash=\(sourceHash)"
            )
            await onProgress(progress)

            if progress.state == "ready" || progress.state == "failed" {
                return progress
            }
        }
    }

    static func pollRemoteWorkerJob(
        workerURL: URL,
        jobID: UUID,
        onProgress: @escaping (DistributedJobProgressResponse) async -> Void
    ) async throws -> DistributedJobResultResponse {
        while true {
            let progress: DistributedJobProgressResponse = try await getJSON(
                baseURL: workerURL,
                path: "/job/progress?id=\(jobID.uuidString)"
            )

            await onProgress(progress)

            switch progress.state {
            case "completed", "failed", "cancelled":
                let result: DistributedJobResultResponse = try await getJSON(
                    baseURL: workerURL,
                    path: "/job/result?id=\(jobID.uuidString)"
                )
                return result
            default:
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    static func pollRemoteWorkerJobBatch(
        workerURL: URL,
        batchID: UUID,
        onProgress: @escaping (DistributedJobBatchProgressResponse) async -> Void
    ) async throws -> DistributedJobBatchResultResponse {
        while true {
            let progress: DistributedJobBatchProgressResponse = try await getJSON(
                baseURL: workerURL,
                path: "/job/batch/progress?id=\(batchID.uuidString)"
            )

            await onProgress(progress)

            switch progress.state {
            case "completed", "failed", "cancelled":
                let result: DistributedJobBatchResultResponse = try await getJSON(
                    baseURL: workerURL,
                    path: "/job/batch/result?id=\(batchID.uuidString)"
                )
                return result
            default:
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    static func downloadRemoteWorkerSegment(
        workerURL: URL,
        jobID: UUID,
        to localURL: URL
    ) async throws {
        guard let url = URL(string: "/job/download?id=\(jobID.uuidString)", relativeTo: workerURL) else {
            throw DistributedCoordinatorError.invalidWorkerURL
        }

        let session = longTimeoutURLSession()
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw DistributedCoordinatorError.remoteDownloadFailed("HTTP 下载失败")
        }

        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }

        try data.write(to: localURL, options: .atomic)
    }

    static func buildWorkerJob(
        sourceURL: URL,
        mode: SliceMode = .axis,
        axis: PlaybackAxis,
        referencePlane: ReferencePlaneState = ReferencePlaneState(),
        totalOutputFrames: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        fps: Double,
        preserveAlpha: Bool,
        padToEven: Bool,
        qualityScale: Double,
        rangeStart: Int,
        rangeEnd: Int,
        colorProfile: VideoColorProfile = .rec709,
        sourceFileHash: String,
        alphaSourceURL: URL? = nil,
        alphaSourceFileHash: String? = nil,
        alphaSourceMode: AlphaSourceMode? = nil,
        externalAlphaSettings: ExternalAlphaSettings? = nil,
        usesGeneratedWhiteColor: Bool = false,
        sourceColorBitDepth: Int? = nil,
        sourceAlphaBitDepth: Int? = nil,
        outputBitDepth: Int? = nil,
        sourcePresentationTimes: [Double]? = nil,
        alphaAssociation: AlphaAssociation? = nil
    ) -> DistributedJobManifest {
        let finalOutputWidth: Int
        let finalOutputHeight: Int
        if let outputWidth, let outputHeight {
            finalOutputWidth = outputWidth
            finalOutputHeight = outputHeight
        } else {
            let baseOutputWidth: Int
            let baseOutputHeight: Int

            switch axis {
            case .x:
                baseOutputWidth = sourceFrameCount
                baseOutputHeight = sourceHeight
            case .y:
                baseOutputWidth = sourceWidth
                baseOutputHeight = sourceFrameCount
            case .t:
                baseOutputWidth = sourceWidth
                baseOutputHeight = sourceHeight
            }

            finalOutputWidth = scaledDimension(
                baseOutputWidth,
                qualityScale: qualityScale,
                padToEven: padToEven
            )

            finalOutputHeight = scaledDimension(
                baseOutputHeight,
                qualityScale: qualityScale,
                padToEven: padToEven
            )
        }

        return DistributedJobManifest(
            jobID: UUID(),
            sourceFileName: sourceURL.lastPathComponent,
            sourceFileHash: sourceFileHash,
            alphaSourceFileName: alphaSourceURL?.lastPathComponent,
            alphaSourceFileHash: alphaSourceFileHash,
            alphaSourceMode: alphaSourceMode,
            externalAlphaSettings: externalAlphaSettings,
            usesGeneratedWhiteColor: usesGeneratedWhiteColor,
            sourceColorBitDepth: sourceColorBitDepth,
            sourceAlphaBitDepth: sourceAlphaBitDepth,
            outputBitDepth: outputBitDepth,
            sourcePresentationTimes: sourcePresentationTimes,
            alphaAssociation: alphaAssociation,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceFrameCount: sourceFrameCount,
            fps: fps,
            mode: mode,
            axis: axis == .x ? .x : .y,
            referencePlane: referencePlane,
            preserveAlpha: preserveAlpha,
            padToEven: padToEven,
            qualityScale: min(1.0, max(0.05, qualityScale)),
            outputWidth: finalOutputWidth,
            outputHeight: finalOutputHeight,
            totalOutputFrames: totalOutputFrames,
            outputStartFrame: rangeStart,
            outputEndFrame: rangeEnd,
            codec: "ap4h",
            colorProfile: colorProfile,
            createdAtISO8601: ISO8601DateFormatter().string(from: Date())
        )
    }

    private static func scaledDimension(
        _ value: Int,
        qualityScale: Double,
        padToEven: Bool
    ) -> Int {
        let scale = min(1.0, max(0.05, qualityScale))
        var v = max(1, Int((Double(value) * scale).rounded()))

        if padToEven && v % 2 != 0 {
            v += 1
        }

        return max(1, v)
    }

    private static func getJSON<T: Decodable>(
        baseURL: URL,
        path: String
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DistributedCoordinatorError.invalidWorkerURL
        }

        let session = longTimeoutURLSession()
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw DistributedCoordinatorError.badResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func postJSON<Body: Encodable, T: Decodable>(
        baseURL: URL,
        path: String,
        body: Body
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DistributedCoordinatorError.invalidWorkerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 300

        let session = longTimeoutURLSession()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw DistributedCoordinatorError.badResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func longTimeoutURLSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }
}
