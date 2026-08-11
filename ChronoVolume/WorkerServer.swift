import Foundation
import Network

enum WorkerServerError: Error {
    case cannotStart(String)
    case badRequest
    case unsupportedRoute
}

struct SourceCheckEvent {
    let originalFileName: String
    let sourceHash: String
    let expectedCacheFileName: String
    let cacheDirectoryPath: String
    let exists: Bool
    let localPath: String?
}

private struct PreparedSourceState {
    let sourceFileHash: String
    var state: String
    var progress: Double
    var message: String
    var rawCachePath: String?
    var mappedRawCacheData: Data?
    var importedCPUVolume: CPUVolume?
    var importedFullVolume: LoadedVolume?
    var importedPreviewVolume: LoadedVolume?
    var importedVolumeInfo: String?
    var error: String?
}

private struct WorkerBatchState {
    let batchID: UUID
    var state: String
    var progress: Double
    var message: String
    var currentJobID: UUID?
    var completedJobIDs: [UUID]
    var jobIDs: [UUID]
    var error: String?
}

final class WorkerServer {
    private let port: NWEndpoint.Port
    private let workerName: String
    private let appVersion: String
    private let sourceCacheDirectory: URL
    private let outputDirectory: URL
    private let executor: WorkerJobExecutor
    private let onLog: ((String) -> Void)?
    private let onSourceCheckEvent: ((SourceCheckEvent) -> Void)?
    private let onJobStateChanged: ((UUID, String, Double, String) -> Void)?
    private let onClusterProgressChanged: ((DistributedClusterProgressSnapshot) -> Void)?

    private var listener: NWListener?
    private var rawFileTransferServer: RawFileTransferServer?
    private let stateQueue = DispatchQueue(label: "ChronoVolume.WorkerServer.state")
    private var jobs: [UUID: WorkerJobState] = [:]
    private var batches: [UUID: WorkerBatchState] = [:]
    private var preparedSources: [String: PreparedSourceState] = [:]

    private let headerDelimiter = Data([13, 10, 13, 10]) // \r\n\r\n

    init(
        port: UInt16 = 8787,
        workerName: String = Host.current().localizedName ?? "ChronoVolume-Worker",
        appVersion: String = "1.0.0",
        sourceCacheDirectory: URL,
        outputDirectory: URL,
        executor: WorkerJobExecutor = WorkerJobExecutor(),
        onLog: ((String) -> Void)? = nil,
        onSourceCheckEvent: ((SourceCheckEvent) -> Void)? = nil,
        onJobStateChanged: ((UUID, String, Double, String) -> Void)? = nil,
        onClusterProgressChanged: ((DistributedClusterProgressSnapshot) -> Void)? = nil
    ) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.workerName = workerName
        self.appVersion = appVersion
        self.sourceCacheDirectory = sourceCacheDirectory
        self.outputDirectory = outputDirectory
        self.executor = executor
        self.onLog = onLog
        self.onSourceCheckEvent = onSourceCheckEvent
        self.onJobStateChanged = onJobStateChanged
        self.onClusterProgressChanged = onClusterProgressChanged
    }

    func start() throws {
        try FileManager.default.createDirectory(at: sourceCacheDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            throw WorkerServerError.cannotStart(error.localizedDescription)
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        log("[WorkerServer] listening on port \(port.rawValue)")

        let transferPort = RawFileTransferPort.transferPort(fromHTTPPort: port.rawValue)
        let transferServer = RawFileTransferServer(
            port: transferPort,
            sourceCacheDirectory: sourceCacheDirectory,
            onLog: onLog
        )
        try transferServer.start()
        self.rawFileTransferServer = transferServer
        log("[WorkerServer] raw TCP file transfer listening on port \(transferPort)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        rawFileTransferServer?.stop()
        rawFileTransferServer = nil
        log("[WorkerServer] stopped")
    }

    private func log(_ text: String) {
        onLog?(text)
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveEntireRequest(connection: connection, accumulated: Data())
    }

    private func receiveEntireRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                let payload = self.makeJSONErrorResponse("连接接收失败：\(error.localizedDescription)")
                connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
                return
            }

            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if self.isRequestComplete(buffer) || isComplete {
                self.processRequest(buffer, connection: connection)
            } else {
                self.receiveEntireRequest(connection: connection, accumulated: buffer)
            }
        }
    }

    // 关键修复：只把 HTTP 头部转换成 UTF-8 字符串，不再把二进制 body 一起转字符串。
    private func splitHeaderAndBody(_ data: Data) -> (header: String, body: Data)? {
        guard let delimiterRange = data.range(of: headerDelimiter) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<delimiterRange.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let bodyStart = delimiterRange.upperBound
        let body = data.subdata(in: bodyStart..<data.count)
        return (header, body)
    }

    private func isRequestComplete(_ data: Data) -> Bool {
        guard let parts = splitHeaderAndBody(data) else {
            return false
        }

        let contentLength = parseContentLength(from: parts.header) ?? 0
        return parts.body.count >= contentLength
    }

    private func parseContentLength(from headerPart: String) -> Int? {
        for line in headerPart.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private func processRequest(_ requestData: Data, connection: NWConnection) {
        do {
            let response = try route(requestData: requestData)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        } catch {
            let payload = makeJSONErrorResponse(error.localizedDescription)
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func route(requestData: Data) throws -> Data {
        guard let parts = splitHeaderAndBody(requestData) else {
            throw WorkerServerError.badRequest
        }

        let headerPart = parts.header
        let bodyData = parts.body

        let headerLines = headerPart.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            throw WorkerServerError.badRequest
        }

        let requestItems = requestLine.components(separatedBy: " ")
        guard requestItems.count >= 2 else {
            throw WorkerServerError.badRequest
        }

        let method = requestItems[0]
        let path = requestItems[1]

        switch (method, path) {
        case ("GET", "/hello"):
            return jsonOK(WorkerHelloResponse(name: workerName, status: "ok"))

        case ("GET", "/capabilities"):
            return jsonOK(DeviceCapabilityDetector.detect(appVersion: appVersion))

        case ("POST", "/cluster/status"):
            let snapshot = try JSONDecoder().decode(DistributedClusterProgressSnapshot.self, from: bodyData)
            onClusterProgressChanged?(snapshot)
            return jsonOK(GenericOKResponse(ok: true, message: "进度已同步"))

        case ("POST", "/source/check"):
            let req = try JSONDecoder().decode(SourceCheckRequest.self, from: bodyData)
            return jsonOK(handleSourceCheck(req))

        case let ("POST", p) where p.hasPrefix("/source/upload?"):
            let query = parseQueryItems(from: p)
            guard let hash = query["hash"],
                  let name = query["name"],
                  let offsetText = query["offset"],
                  let totalText = query["total"],
                  let offset = Int64(offsetText),
                  let total = Int64(totalText) else {
                return makeJSONErrorResponse("上传参数缺失")
            }

            return try handleSourceUploadChunk(
                hash: hash,
                name: name,
                offset: offset,
                total: total,
                body: bodyData
            )

        case ("POST", "/source/prepare"):
            let req = try JSONDecoder().decode(PrepareSourceRequest.self, from: bodyData)
            return jsonOK(handleSourcePrepare(req))

        case ("POST", "/source/prepare/check"):
            let req = try JSONDecoder().decode(PrepareSourceRequest.self, from: bodyData)
            return jsonOK(handleSourcePrepareCheck(req))

        case let ("GET", p) where p.hasPrefix("/source/prepare/progress?hash="):
            let hash = String(p.dropFirst("/source/prepare/progress?hash=".count))
            return jsonOK(handleSourcePrepareProgress(hash: hash))

        case ("POST", "/job/start"):
            let req = try JSONDecoder().decode(StartDistributedJobRequest.self, from: bodyData)
            return jsonOK(try handleStartJob(req))

        case ("POST", "/job/batch/start"):
            let req = try JSONDecoder().decode(StartDistributedJobBatchRequest.self, from: bodyData)
            return jsonOK(try handleStartJobBatch(req))

        case let ("GET", p) where p.hasPrefix("/job/batch/progress?id="):
            let idText = String(p.dropFirst("/job/batch/progress?id=".count))
            guard let id = UUID(uuidString: idText) else { throw WorkerServerError.badRequest }
            return jsonOK(handleJobBatchProgress(id: id))

        case let ("GET", p) where p.hasPrefix("/job/batch/result?id="):
            let idText = String(p.dropFirst("/job/batch/result?id=".count))
            guard let id = UUID(uuidString: idText) else { throw WorkerServerError.badRequest }
            return jsonOK(handleJobBatchResult(id: id))

        case let ("GET", p) where p.hasPrefix("/job/progress?id="):
            let idText = String(p.dropFirst("/job/progress?id=".count))
            guard let id = UUID(uuidString: idText) else { throw WorkerServerError.badRequest }
            return jsonOK(handleJobProgress(id: id))

        case let ("GET", p) where p.hasPrefix("/job/result?id="):
            let idText = String(p.dropFirst("/job/result?id=".count))
            guard let id = UUID(uuidString: idText) else { throw WorkerServerError.badRequest }
            return jsonOK(handleJobResult(id: id))

        case let ("GET", p) where p.hasPrefix("/job/download?id="):
            let idText = String(p.dropFirst("/job/download?id=".count))
            guard let id = UUID(uuidString: idText) else { throw WorkerServerError.badRequest }
            return try handleJobDownload(id: id)

        case ("POST", "/job/cancel"):
            let req = try JSONDecoder().decode(CancelJobRequest.self, from: bodyData)
            return jsonOK(handleJobCancel(req))

        default:
            throw WorkerServerError.unsupportedRoute
        }
    }

    private func parseQueryItems(from rawPath: String) -> [String: String] {
        guard let comps = URLComponents(string: "http://dummy\(rawPath)") else { return [:] }
        var out: [String: String] = [:]
        comps.queryItems?.forEach { out[$0.name] = $0.value }
        return out
    }

    private func handleSourceCheck(_ req: SourceCheckRequest) -> SourceCheckResponse {
        let expectedFileName = req.sourceFileHash + "_" + req.sourceFileName
        let target = sourceCacheDirectory.appendingPathComponent(expectedFileName)
        let exists = FileManager.default.fileExists(atPath: target.path)
        let response = SourceCheckResponse(exists: exists, localPath: exists ? target.path : nil)

        onSourceCheckEvent?(SourceCheckEvent(
            originalFileName: req.sourceFileName,
            sourceHash: req.sourceFileHash,
            expectedCacheFileName: expectedFileName,
            cacheDirectoryPath: sourceCacheDirectory.path,
            exists: exists,
            localPath: response.localPath
        ))

        log("[source.check] \(expectedFileName) | exists=\(exists)")
        return response
    }

    private func handleSourceUploadChunk(
        hash: String,
        name: String,
        offset: Int64,
        total: Int64,
        body: Data
    ) throws -> Data {
        let finalURL = sourceCacheDirectory.appendingPathComponent(hash + "_" + name)
        let tempURL = sourceCacheDirectory.appendingPathComponent(hash + "_" + name + ".uploading")

        if offset == 0 {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        }

        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            return makeJSONErrorResponse("上传临时文件不存在，请从 offset=0 重新开始")
        }

        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        try handle.seekToEnd()
        let currentSize = try handle.offset()
        guard currentSize == UInt64(offset) else {
            return makeJSONErrorResponse("上传 offset 不匹配，当前 \(currentSize)，收到 \(offset)")
        }

        try handle.write(contentsOf: body)

        let newSize = offset + Int64(body.count)
        if newSize >= total {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            log("[source.upload] completed -> \(finalURL.path)")
        } else {
            let percent = Int(Double(newSize) / Double(max(1, total)) * 100.0)
            log("[source.upload] chunk \(percent)% \(newSize)/\(total)")
        }

        return jsonOK(GenericOKResponse(ok: true, message: "上传分块已接收"))
    }

    private func preparedRawCacheURL(
        sourceHash: String,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int
    ) -> URL {
        outputDirectory
            .appendingPathComponent("PreparedRawCaches", isDirectory: true)
            .appendingPathComponent("\(sourceHash)_\(sourceWidth)x\(sourceHeight)x\(sourceFrameCount).rawframes")
    }

    private func handleSourcePrepare(_ req: PrepareSourceRequest) -> PrepareSourceResponse {
        let rawURL = preparedRawCacheURL(
            sourceHash: req.sourceFileHash,
            sourceWidth: req.sourceWidth,
            sourceHeight: req.sourceHeight,
            sourceFrameCount: req.sourceFrameCount
        )

        let existing = stateQueue.sync { preparedSources[req.sourceFileHash] }
        if let existing, existing.state == "running" {
            return makePrepareResponse(existing)
        }
        if let existing, existing.state == "ready" {
            if existing.importedVolumeInfo == nil,
               let rawCachePath = existing.rawCachePath {
                importSourceIntoWorkerSession(req: req, rawCacheURL: URL(fileURLWithPath: rawCachePath))
                return stateQueue.sync {
                    makePrepareResponse(preparedSources[req.sourceFileHash] ?? existing)
                }
            }
            return makePrepareResponse(existing)
        }

        let expectedBytes = req.sourceWidth * req.sourceHeight * 4 * req.sourceFrameCount
        if
            FileManager.default.fileExists(atPath: rawURL.path),
            let attrs = try? FileManager.default.attributesOfItem(atPath: rawURL.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue >= expectedBytes
        {
            let ready = PreparedSourceState(
                sourceFileHash: req.sourceFileHash,
                state: "ready",
                progress: 1.0,
                message: "Worker raw cache 已就绪",
                rawCachePath: rawURL.path,
                mappedRawCacheData: mapPreparedRawCacheData(rawURL),
                importedCPUVolume: nil,
                importedFullVolume: nil,
                importedPreviewVolume: nil,
                importedVolumeInfo: nil,
                error: nil
            )
            stateQueue.sync { preparedSources[req.sourceFileHash] = ready }
            importSourceIntoWorkerSession(req: req, rawCacheURL: rawURL)
            return stateQueue.sync {
                makePrepareResponse(preparedSources[req.sourceFileHash] ?? ready)
            }
        }

        let running = PreparedSourceState(
            sourceFileHash: req.sourceFileHash,
            state: "running",
                progress: 0.0,
                message: "准备建立 Worker raw cache",
                rawCachePath: nil,
                mappedRawCacheData: nil,
                importedCPUVolume: nil,
                importedFullVolume: nil,
                importedPreviewVolume: nil,
                importedVolumeInfo: nil,
                error: nil
            )
        stateQueue.sync { preparedSources[req.sourceFileHash] = running }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runSourcePrepare(req, rawURL: rawURL)
        }

        log("[source.prepare] \(req.sourceFileHash) started")
        return makePrepareResponse(running)
    }

    private func runSourcePrepare(_ req: PrepareSourceRequest, rawURL: URL) {
        guard FileManager.default.fileExists(atPath: req.localSourcePath) else {
            updatePreparedSource(
                sourceHash: req.sourceFileHash,
                state: "failed",
                progress: 1.0,
                message: "源文件不存在",
                rawCachePath: nil,
                mappedRawCacheData: nil,
                importedCPUVolume: nil,
                importedFullVolume: nil,
                importedPreviewVolume: nil,
                importedVolumeInfo: nil,
                error: req.localSourcePath
            )
            return
        }

        do {
            let rawCacheURL = try VideoExportHelper.prepareDistributedRawFrameCache(
                sourceURL: URL(fileURLWithPath: req.localSourcePath),
                outputURL: rawURL,
                sourceWidth: req.sourceWidth,
                sourceHeight: req.sourceHeight,
                sourceFrameCount: req.sourceFrameCount,
                progress: { [weak self] progress, message in
                    self?.updatePreparedSource(
                sourceHash: req.sourceFileHash,
                state: "running",
                progress: progress,
                message: message ?? "正在建立 Worker raw cache",
                rawCachePath: rawURL.path,
                mappedRawCacheData: nil,
                importedCPUVolume: nil,
                importedFullVolume: nil,
                importedPreviewVolume: nil,
                importedVolumeInfo: nil,
                error: nil
            )
                }
            )

            updatePreparedSource(
                sourceHash: req.sourceFileHash,
                state: "ready",
                progress: 1.0,
                message: "Worker raw cache 已就绪，正在导入 Worker 会话",
                rawCachePath: rawCacheURL.path,
                mappedRawCacheData: mapPreparedRawCacheData(rawCacheURL),
                importedCPUVolume: nil,
                importedFullVolume: nil,
                importedPreviewVolume: nil,
                importedVolumeInfo: nil,
                error: nil
            )

            importSourceIntoWorkerSession(req: req, rawCacheURL: rawCacheURL)
            log("[source.prepare] \(req.sourceFileHash) ready -> \(rawCacheURL.path)")
        } catch {
            updatePreparedSource(
                sourceHash: req.sourceFileHash,
                state: "failed",
                progress: 1.0,
                message: "Worker raw cache 建立失败",
                rawCachePath: nil,
                mappedRawCacheData: nil,
                importedCPUVolume: nil,
                importedFullVolume: nil,
                importedPreviewVolume: nil,
                importedVolumeInfo: nil,
                error: error.localizedDescription
            )
            log("[source.prepare] \(req.sourceFileHash) failed: \(error.localizedDescription)")
        }
    }

    private func updatePreparedSource(
        sourceHash: String,
        state: String,
        progress: Double,
        message: String,
        rawCachePath: String?,
        mappedRawCacheData: Data?,
        importedCPUVolume: CPUVolume?,
        importedFullVolume: LoadedVolume?,
        importedPreviewVolume: LoadedVolume?,
        importedVolumeInfo: String?,
        error: String?
    ) {
        stateQueue.sync {
            let previous = preparedSources[sourceHash]
            preparedSources[sourceHash] = PreparedSourceState(
                sourceFileHash: sourceHash,
                state: state,
                progress: max(0.0, min(1.0, progress)),
                message: message,
                rawCachePath: rawCachePath,
                mappedRawCacheData: mappedRawCacheData,
                importedCPUVolume: importedCPUVolume ?? previous?.importedCPUVolume,
                importedFullVolume: importedFullVolume ?? previous?.importedFullVolume,
                importedPreviewVolume: importedPreviewVolume ?? previous?.importedPreviewVolume,
                importedVolumeInfo: importedVolumeInfo ?? previous?.importedVolumeInfo,
                error: error
            )
        }
        onJobStateChanged?(UUID(), state, progress, message)
    }

    private func importSourceIntoWorkerSession(req: PrepareSourceRequest, rawCacheURL: URL) {
        do {
            let package = try awaitBlockingVideoLoad(url: URL(fileURLWithPath: req.localSourcePath))
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
            let info = "\(full.width) × \(full.height) × \(full.depth)"

            updatePreparedSource(
                sourceHash: req.sourceFileHash,
                state: "ready",
                progress: 1.0,
                message: "Worker 已导入视频会话，raw cache 已就绪",
                rawCachePath: rawCacheURL.path,
                mappedRawCacheData: mapPreparedRawCacheData(rawCacheURL),
                importedCPUVolume: cpuVolume,
                importedFullVolume: full,
                importedPreviewVolume: preview,
                importedVolumeInfo: info,
                error: nil
            )
            log("[source.import] \(req.sourceFileHash) imported volume \(info)")
        } catch {
            updatePreparedSource(
                sourceHash: req.sourceFileHash,
                state: "ready",
                progress: 1.0,
                message: "Worker raw cache 已就绪，视频会话导入失败：\(error.localizedDescription)",
                rawCachePath: rawCacheURL.path,
                mappedRawCacheData: mapPreparedRawCacheData(rawCacheURL),
                importedCPUVolume: nil,
                importedFullVolume: nil,
                importedPreviewVolume: nil,
                importedVolumeInfo: nil,
                error: nil
            )
            log("[source.import] \(req.sourceFileHash) failed: \(error.localizedDescription)")
        }
    }

    private func awaitBlockingVideoLoad(url: URL) throws -> LoadedVideoPackage {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<LoadedVideoPackage, Error>!
        Task.detached(priority: .userInitiated) {
            do {
                let package = try await VideoVolumeLoader.load(
                    url: url,
                    maxWidth: 1024,
                    maxHeight: 1024,
                    previewMaxDepth: 256
                )
                result = .success(package)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    private func mapPreparedRawCacheData(_ url: URL) -> Data? {
        try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func handleSourcePrepareProgress(hash: String) -> PrepareSourceResponse {
        let state = stateQueue.sync { preparedSources[hash] }
        return makePrepareResponse(
            state ?? PreparedSourceState(
                sourceFileHash: hash,
                state: "missing",
                progress: 0.0,
                message: "未找到 Worker raw cache 预热任务",
                rawCachePath: nil,
                mappedRawCacheData: nil,
                importedCPUVolume: nil,
                importedFullVolume: nil,
                importedPreviewVolume: nil,
                importedVolumeInfo: nil,
                error: nil
            )
        )
    }

    private func handleSourcePrepareCheck(_ req: PrepareSourceRequest) -> PrepareSourceResponse {
        if let state = stateQueue.sync(execute: { preparedSources[req.sourceFileHash] }) {
            if state.state == "running" || state.state == "failed" {
                return makePrepareResponse(state)
            }
            if state.state == "ready" {
                if state.importedVolumeInfo == nil,
                   let rawCachePath = state.rawCachePath {
                    importSourceIntoWorkerSession(req: req, rawCacheURL: URL(fileURLWithPath: rawCachePath))
                    return stateQueue.sync {
                        makePrepareResponse(preparedSources[req.sourceFileHash] ?? state)
                    }
                }
                return makePrepareResponse(state)
            }
        }

        let rawURL = preparedRawCacheURL(
            sourceHash: req.sourceFileHash,
            sourceWidth: req.sourceWidth,
            sourceHeight: req.sourceHeight,
            sourceFrameCount: req.sourceFrameCount
        )
        let expectedBytes = req.sourceWidth * req.sourceHeight * 4 * req.sourceFrameCount

        if
            FileManager.default.fileExists(atPath: rawURL.path),
            let attrs = try? FileManager.default.attributesOfItem(atPath: rawURL.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue >= expectedBytes
        {
            let ready = PreparedSourceState(
                sourceFileHash: req.sourceFileHash,
                state: "ready",
                progress: 1.0,
                message: "Worker raw cache 已就绪",
                rawCachePath: rawURL.path,
                mappedRawCacheData: mapPreparedRawCacheData(rawURL),
                importedCPUVolume: nil,
                importedFullVolume: nil,
                importedPreviewVolume: nil,
                importedVolumeInfo: nil,
                error: nil
            )
            stateQueue.sync { preparedSources[req.sourceFileHash] = ready }
            importSourceIntoWorkerSession(req: req, rawCacheURL: rawURL)
            return stateQueue.sync {
                makePrepareResponse(preparedSources[req.sourceFileHash] ?? ready)
            }
        }

        return PrepareSourceResponse(
            sourceFileHash: req.sourceFileHash,
            state: "missing",
            progress: 0.0,
            message: "Worker raw cache 未建立",
            rawCachePath: nil,
            importedVolumeInfo: nil,
            error: nil
        )
    }

    private func makePrepareResponse(_ state: PreparedSourceState) -> PrepareSourceResponse {
        PrepareSourceResponse(
            sourceFileHash: state.sourceFileHash,
            state: state.state,
            progress: state.progress,
            message: state.message,
            rawCachePath: state.rawCachePath,
            importedVolumeInfo: state.importedVolumeInfo,
            error: state.error
        )
    }

    private func handleStartJob(_ req: StartDistributedJobRequest) throws -> GenericOKResponse {
        let jobID = req.job.jobID
        stateQueue.sync {
            jobs[jobID] = WorkerJobState(
                jobID: jobID,
                state: "queued",
                progress: 0.0,
                message: "任务已排队",
                segmentMetadata: nil,
                segmentPath: nil,
                error: nil
            )
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runJob(req)
        }

        log("[job.start] jobID=\(jobID.uuidString)")
        return GenericOKResponse(ok: true, message: "任务已启动")
    }

    private func runJob(_ req: StartDistributedJobRequest) {
        let jobID = req.job.jobID
        updateJob(jobID: jobID, state: "running", progress: 0.01, message: "准备执行高精度分段导出")
        var lastRenderMessage = "分段导出完成"

        do {
            let preparedSourceState = preparedSourceState(for: req)
            let localOutputRequest = StartDistributedJobRequest(
                job: req.job,
                localSourcePath: req.localSourcePath,
                outputDirectory: outputDirectory.path,
                preparedRawCachePath: preparedRawCachePath(for: req, preparedSourceState: preparedSourceState),
                localAlphaSourcePath: req.localAlphaSourcePath
            )

            let result = try executor.execute(
                request: localOutputRequest,
                preparedRawCacheData: preparedSourceState?.mappedRawCacheData,
                preparedCPUVolume: preparedSourceState?.importedCPUVolume
            ) { [weak self] progress, message in
                lastRenderMessage = message
                self?.updateJob(jobID: jobID, state: "running", progress: progress, message: message)
            }

            stateQueue.sync {
                jobs[jobID] = WorkerJobState(
                    jobID: jobID,
                    state: "completed",
                    progress: 1.0,
                    message: lastRenderMessage,
                    segmentMetadata: result.metadata,
                    segmentPath: result.segmentURL.path,
                    error: nil
                )
            }
            onJobStateChanged?(jobID, "completed", 1.0, lastRenderMessage)
        } catch {
            stateQueue.sync {
                jobs[jobID] = WorkerJobState(
                    jobID: jobID,
                    state: "failed",
                    progress: 1.0,
                    message: "分段导出失败",
                    segmentMetadata: nil,
                    segmentPath: nil,
                    error: error.localizedDescription
                )
            }
            onJobStateChanged?(jobID, "failed", 1.0, error.localizedDescription)
            }
    }

    private func handleStartJobBatch(_ req: StartDistributedJobBatchRequest) throws -> GenericOKResponse {
        guard !req.jobs.isEmpty else {
            return GenericOKResponse(ok: false, message: "批量任务为空")
        }

        stateQueue.sync {
            for job in req.jobs {
                jobs[job.jobID] = WorkerJobState(
                    jobID: job.jobID,
                    state: "queued",
                    progress: 0.0,
                    message: "批量任务已排队",
                    segmentMetadata: nil,
                    segmentPath: nil,
                    error: nil
                )
            }

            batches[req.batchID] = WorkerBatchState(
                batchID: req.batchID,
                state: "queued",
                progress: 0.0,
                message: "批量任务已排队（\(req.jobs.count) 个 chunk）",
                currentJobID: nil,
                completedJobIDs: [],
                jobIDs: req.jobs.map(\.jobID),
                error: nil
            )
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runJobBatch(req)
        }

        log("[job.batch.start] batchID=\(req.batchID.uuidString) jobs=\(req.jobs.count)")
        return GenericOKResponse(ok: true, message: "批量任务已启动")
    }

    private func runJobBatch(_ req: StartDistributedJobBatchRequest) {
        let batchID = req.batchID
        let totalFrames = max(1, req.jobs.reduce(0) { $0 + max(0, $1.outputEndFrame - $1.outputStartFrame + 1) })
        var completedFrames = 0
        var completedJobIDs: [UUID] = []
        var lastRenderMessage = "批量 chunk 全部完成"

        do {
            for (jobIndex, job) in req.jobs.enumerated() {
                let frameCount = max(0, job.outputEndFrame - job.outputStartFrame + 1)
                updateBatch(
                    batchID: batchID,
                    state: "running",
                    progress: Double(completedFrames) / Double(totalFrames),
                    message: "连续处理 chunk \(jobIndex + 1)/\(req.jobs.count)",
                    currentJobID: job.jobID,
                    completedJobIDs: completedJobIDs,
                    error: nil
                )
                updateJob(jobID: job.jobID, state: "running", progress: 0.01, message: "批量会话内执行高精度分段导出")

                let singleRequest = StartDistributedJobRequest(
                    job: job,
                    localSourcePath: req.localSourcePath,
                    outputDirectory: outputDirectory.path,
                    preparedRawCachePath: req.preparedRawCachePath,
                    localAlphaSourcePath: req.localAlphaSourcePath
                )
                let preparedSourceState = preparedSourceState(for: singleRequest)
                let localOutputRequest = StartDistributedJobRequest(
                    job: job,
                    localSourcePath: req.localSourcePath,
                    outputDirectory: outputDirectory.path,
                    preparedRawCachePath: preparedRawCachePath(
                        for: singleRequest,
                        preparedSourceState: preparedSourceState
                    ),
                    localAlphaSourcePath: req.localAlphaSourcePath
                )

                let result = try executor.execute(
                    request: localOutputRequest,
                    preparedRawCacheData: preparedSourceState?.mappedRawCacheData,
                    preparedCPUVolume: preparedSourceState?.importedCPUVolume
                ) { [weak self] progress, message in
                    lastRenderMessage = message
                    let clamped = max(0.0, min(1.0, progress))
                    let batchProgress = (Double(completedFrames) + Double(frameCount) * clamped) / Double(totalFrames)
                    self?.updateJob(
                        jobID: job.jobID,
                        state: "running",
                        progress: clamped,
                        message: message
                    )
                    self?.updateBatch(
                        batchID: batchID,
                        state: "running",
                        progress: batchProgress,
                        message: "chunk \(jobIndex + 1)/\(req.jobs.count)：\(message)",
                        currentJobID: job.jobID,
                        completedJobIDs: completedJobIDs,
                        error: nil
                    )
                }

                stateQueue.sync {
                    jobs[job.jobID] = WorkerJobState(
                        jobID: job.jobID,
                        state: "completed",
                        progress: 1.0,
                        message: lastRenderMessage,
                        segmentMetadata: result.metadata,
                        segmentPath: result.segmentURL.path,
                        error: nil
                    )
                }
                completedFrames += frameCount
                completedJobIDs.append(job.jobID)
                updateBatch(
                    batchID: batchID,
                    state: "running",
                    progress: Double(completedFrames) / Double(totalFrames),
                    message: "完成 chunk \(jobIndex + 1)/\(req.jobs.count)",
                    currentJobID: job.jobID,
                    completedJobIDs: completedJobIDs,
                    error: nil
                )
                onJobStateChanged?(job.jobID, "completed", 1.0, lastRenderMessage)
            }

            updateBatch(
                batchID: batchID,
                state: "completed",
                progress: 1.0,
                message: lastRenderMessage,
                currentJobID: nil,
                completedJobIDs: completedJobIDs,
                error: nil
            )
        } catch {
            let failedJobID = stateQueue.sync { batches[batchID]?.currentJobID }
            updateBatch(
                batchID: batchID,
                state: "failed",
                progress: 1.0,
                message: "批量分段失败",
                currentJobID: nil,
                completedJobIDs: completedJobIDs,
                error: error.localizedDescription
            )
            if let current = failedJobID {
                stateQueue.sync {
                    jobs[current] = WorkerJobState(
                        jobID: current,
                        state: "failed",
                        progress: 1.0,
                        message: "批量分段失败",
                        segmentMetadata: nil,
                        segmentPath: nil,
                        error: error.localizedDescription
                    )
                }
                onJobStateChanged?(current, "failed", 1.0, error.localizedDescription)
            }
            log("[job.batch] \(batchID.uuidString) failed: \(error.localizedDescription)")
        }
    }

    private func updateBatch(
        batchID: UUID,
        state: String,
        progress: Double,
        message: String,
        currentJobID: UUID?,
        completedJobIDs: [UUID],
        error: String?
    ) {
        stateQueue.sync {
            let previous = batches[batchID]
            batches[batchID] = WorkerBatchState(
                batchID: batchID,
                state: state,
                progress: max(0.0, min(1.0, progress)),
                message: message,
                currentJobID: currentJobID,
                completedJobIDs: completedJobIDs,
                jobIDs: previous?.jobIDs ?? [],
                error: error
            )
        }
    }

    private func preparedSourceState(for req: StartDistributedJobRequest) -> PreparedSourceState? {
        stateQueue.sync { preparedSources[req.job.sourceFileHash] }
    }

    private func preparedRawCachePath(
        for req: StartDistributedJobRequest,
        preparedSourceState: PreparedSourceState?
    ) -> String? {
        if let path = req.preparedRawCachePath, FileManager.default.fileExists(atPath: path) {
            return path
        }

        let expected = preparedRawCacheURL(
            sourceHash: req.job.sourceFileHash,
            sourceWidth: req.job.sourceWidth,
            sourceHeight: req.job.sourceHeight,
            sourceFrameCount: req.job.sourceFrameCount
        )
        if FileManager.default.fileExists(atPath: expected.path) {
            return expected.path
        }

        if let path = preparedSourceState?.rawCachePath,
           preparedSourceState?.state == "ready",
           FileManager.default.fileExists(atPath: path) {
            return path
        }

        return nil
    }

    private func handleJobProgress(id: UUID) -> JobProgressResponse {
        let state = stateQueue.sync { jobs[id] }
        return JobProgressResponse(
            jobID: id,
            state: state?.state ?? "unknown",
            progress: state?.progress ?? 0.0,
            message: state?.message ?? "未找到任务"
        )
    }

    private func handleJobResult(id: UUID) -> JobResultResponse {
        let state = stateQueue.sync { jobs[id] }
        return JobResultResponse(
            jobID: id,
            state: state?.state ?? "unknown",
            segmentMetadata: state?.segmentMetadata,
            segmentPath: state?.segmentPath,
            error: state?.error
        )
    }

    private func handleJobBatchProgress(id: UUID) -> JobBatchProgressResponse {
        let state = stateQueue.sync { batches[id] }
        return JobBatchProgressResponse(
            batchID: id,
            state: state?.state ?? "unknown",
            progress: state?.progress ?? 0.0,
            message: state?.message ?? "未找到批量任务",
            currentJobID: state?.currentJobID,
            completedJobIDs: state?.completedJobIDs ?? [],
            error: state?.error
        )
    }

    private func handleJobBatchResult(id: UUID) -> JobBatchResultResponse {
        let snapshot = stateQueue.sync { batches[id] }
        let results = (snapshot?.jobIDs ?? []).map { jobID in
            handleJobResult(id: jobID)
        }
        return JobBatchResultResponse(
            batchID: id,
            state: snapshot?.state ?? "unknown",
            results: results,
            error: snapshot?.error
        )
    }

    private func handleJobDownload(id: UUID) throws -> Data {
        guard let state = stateQueue.sync(execute: { jobs[id] }) else {
            return makeJSONErrorResponse("未找到任务")
        }

        guard state.state == "completed" else {
            return makeJSONErrorResponse("任务尚未完成")
        }

        guard let path = state.segmentPath,
              FileManager.default.fileExists(atPath: path) else {
            return makeJSONErrorResponse("segment 文件不存在")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return makeHTTPResponse(statusCode: 200, contentType: "video/quicktime", body: data)
    }

    private func handleJobCancel(_ req: CancelJobRequest) -> GenericOKResponse {
        stateQueue.sync {
            if var job = jobs[req.jobID] {
                job.state = "cancelled"
                job.message = "任务已取消"
                jobs[req.jobID] = job
            }
        }
        onJobStateChanged?(req.jobID, "cancelled", 1.0, "任务已取消")
        return GenericOKResponse(ok: true, message: "取消请求已接收")
    }

    private func updateJob(jobID: UUID, state: String, progress: Double, message: String) {
        stateQueue.sync {
            var job = jobs[jobID] ?? WorkerJobState(
                jobID: jobID,
                state: state,
                progress: progress,
                message: message,
                segmentMetadata: nil,
                segmentPath: nil,
                error: nil
            )
            job.state = state
            job.progress = progress
            job.message = message
            jobs[jobID] = job
        }
        onJobStateChanged?(jobID, state, progress, message)
    }

    private func jsonOK<T: Encodable>(_ value: T) -> Data {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return makeHTTPResponse(statusCode: 200, contentType: "application/json", body: body)
    }

    private func makeJSONErrorResponse(_ message: String) -> Data {
        let payload: [String: Any] = ["ok": false, "message": message]
        let body: Data
        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            body = data
        } else {
            body = Data("{\"ok\":false,\"message\":\"Unknown error\"}".utf8)
        }
        return makeHTTPResponse(statusCode: 400, contentType: "application/json", body: body)
    }

    private func makeHTTPResponse(statusCode: Int, contentType: String, body: Data) -> Data {
        let statusText = statusCode == 200 ? "OK" : "BAD REQUEST"
        let header =
            "HTTP/1.1 \(statusCode) \(statusText)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"

        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

private struct WorkerJobState {
    let jobID: UUID
    var state: String
    var progress: Double
    var message: String
    var segmentMetadata: SegmentMetadata?
    var segmentPath: String?
    var error: String?
}
