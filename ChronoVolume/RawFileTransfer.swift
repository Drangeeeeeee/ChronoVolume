import Foundation
import Network

enum RawFileTransferError: LocalizedError {
    case invalidHost
    case invalidPort
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case badAck(String)
    case badHeader
    case fileMissing(String)
    case fileWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "文件传输目标主机无效"
        case .invalidPort:
            return "文件传输目标端口无效"
        case .connectionFailed(let reason):
            return "文件传输连接失败：\(reason)"
        case .sendFailed(let reason):
            return "文件发送失败：\(reason)"
        case .receiveFailed(let reason):
            return "文件接收失败：\(reason)"
        case .badAck(let reason):
            return "Worker 文件接收确认异常：\(reason)"
        case .badHeader:
            return "文件传输头格式无效"
        case .fileMissing(let path):
            return "源文件不存在：\(path)"
        case .fileWriteFailed(let reason):
            return "Worker 写入缓存文件失败：\(reason)"
        }
    }
}

struct RawFileTransferHeader: Codable {
    let sourceFileHash: String
    let sourceFileName: String
    let totalBytes: Int64
}

struct RawFileTransferAck: Codable {
    let ok: Bool
    let message: String
    let path: String?
}

enum RawFileTransferPort {
    static func transferPort(fromHTTPPort httpPort: UInt16) -> UInt16 {
        httpPort == UInt16.max ? httpPort : httpPort + 1
    }
}

// MARK: - Client

enum RawFileTransferClient {
    static let defaultChunkSize = 16 * 1024 * 1024

    static func uploadSourceToWorker(
        workerURL: URL,
        sourceURL: URL,
        sourceHash: String,
        chunkSize: Int = defaultChunkSize,
        progress: @escaping (Double, String) async -> Void = { _, _ in }
    ) async throws {
        guard let hostText = workerURL.host, !hostText.isEmpty else {
            throw RawFileTransferError.invalidHost
        }

        let httpPort = UInt16(workerURL.port ?? 8787)
        let transferPortValue = RawFileTransferPort.transferPort(fromHTTPPort: httpPort)

        guard let port = NWEndpoint.Port(rawValue: transferPortValue) else {
            throw RawFileTransferError.invalidPort
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw RawFileTransferError.fileMissing(sourceURL.path)
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let totalBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard totalBytes > 0 else {
            throw RawFileTransferError.fileMissing("源文件大小为 0：\(sourceURL.path)")
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(hostText),
            port: port,
            using: .tcp
        )

        let queue = DispatchQueue(label: "ChronoVolume.RawFileTransferClient")
        try await start(connection: connection, queue: queue)

        do {
            let header = RawFileTransferHeader(
                sourceFileHash: sourceHash,
                sourceFileName: sourceURL.lastPathComponent,
                totalBytes: totalBytes
            )

            let headerData = try JSONEncoder().encode(header)
            var headerLength = UInt64(headerData.count).bigEndian
            let lengthData = withUnsafeBytes(of: &headerLength) { Data($0) }

            try await send(connection: connection, data: lengthData)
            try await send(connection: connection, data: headerData)

            let fileHandle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? fileHandle.close() }

            let safeChunkSize = max(1024 * 1024, chunkSize)
            var sentBytes: Int64 = 0

            while sentBytes < totalBytes {
                let data = try fileHandle.read(upToCount: safeChunkSize) ?? Data()
                if data.isEmpty { break }

                try await send(connection: connection, data: data)

                sentBytes += Int64(data.count)
                let ratio = min(1.0, Double(sentBytes) / Double(totalBytes))
                let mbDone = Double(sentBytes) / 1024.0 / 1024.0
                let mbTotal = Double(totalBytes) / 1024.0 / 1024.0

                await progress(
                    ratio,
                    String(format: "TCP 流式发送 %.1f / %.1f MB", mbDone, mbTotal)
                )
            }

            guard sentBytes == totalBytes else {
                throw RawFileTransferError.sendFailed("发送未完成：\(sentBytes)/\(totalBytes) bytes")
            }

            let ackData = try await receiveAck(connection: connection)
            let ack = try JSONDecoder().decode(RawFileTransferAck.self, from: ackData)

            guard ack.ok else {
                throw RawFileTransferError.badAck(ack.message)
            }

            await progress(1.0, "源文件已通过 TCP 流式传输写入 Worker 缓存")
            connection.cancel()
        } catch {
            connection.cancel()
            throw error
        }
    }

    private static func start(
        connection: NWConnection,
        queue: DispatchQueue
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var resumed = false

            func resumeOnce(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true

                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(RawFileTransferError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    resumeOnce(.failure(RawFileTransferError.connectionFailed("连接已取消")))
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    private static func send(
        connection: NWConnection,
        data: Data
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: RawFileTransferError.sendFailed(error.localizedDescription))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    private static func receiveAck(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 4096
            ) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: RawFileTransferError.receiveFailed(error.localizedDescription))
                    return
                }

                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: RawFileTransferError.receiveFailed("Worker 未返回确认"))
                    return
                }

                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - Server

final class RawFileTransferServer {
    private let port: NWEndpoint.Port
    private let sourceCacheDirectory: URL
    private let onLog: ((String) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "ChronoVolume.RawFileTransferServer", qos: .userInitiated)

    init(
        port: UInt16,
        sourceCacheDirectory: URL,
        onLog: ((String) -> Void)? = nil
    ) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.sourceCacheDirectory = sourceCacheDirectory
        self.onLog = onLog
    }

    func start() throws {
        try FileManager.default.createDirectory(
            at: sourceCacheDirectory,
            withIntermediateDirectories: true
        )

        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener.start(queue: queue)
        self.listener = listener

        log("[RawFileTransferServer] listening on port \(port.rawValue)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        log("[RawFileTransferServer] stopped")
    }

    private func log(_ text: String) {
        onLog?(text)
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)

        receiveExactly(connection: connection, count: 8) { [weak self] lengthData in
            guard let self else {
                connection.cancel()
                return
            }

            guard let lengthData, lengthData.count == 8 else {
                self.sendAck(connection: connection, ok: false, message: "传输头长度读取失败", path: nil)
                return
            }

            let headerLength = self.uint64FromBigEndianData(lengthData)
            guard headerLength > 0, headerLength < 1024 * 1024 else {
                self.sendAck(connection: connection, ok: false, message: "传输头长度异常：\(headerLength)", path: nil)
                return
            }

            self.receiveExactly(connection: connection, count: Int(headerLength)) { headerData in
                guard let headerData else {
                    self.sendAck(connection: connection, ok: false, message: "传输头读取失败", path: nil)
                    return
                }

                do {
                    let header = try JSONDecoder().decode(RawFileTransferHeader.self, from: headerData)
                    try self.receiveFileBody(connection: connection, header: header)
                } catch {
                    self.sendAck(connection: connection, ok: false, message: error.localizedDescription, path: nil)
                }
            }
        }
    }

    private func receiveExactly(
        connection: NWConnection,
        count: Int,
        accumulated: Data = Data(),
        completion: @escaping (Data?) -> Void
    ) {
        if accumulated.count >= count {
            completion(accumulated)
            return
        }

        let remaining = count - accumulated.count
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: remaining
        ) { [weak self] data, _, _, error in
            guard let self else {
                completion(nil)
                return
            }

            if let error {
                self.log("[RawFileTransferServer] receive error: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let data, !data.isEmpty else {
                completion(nil)
                return
            }

            var next = accumulated
            next.append(data)
            self.receiveExactly(
                connection: connection,
                count: count,
                accumulated: next,
                completion: completion
            )
        }
    }

    private func receiveFileBody(
        connection: NWConnection,
        header: RawFileTransferHeader
    ) throws {
        let finalURL = sourceCacheDirectory
            .appendingPathComponent(header.sourceFileHash + "_" + header.sourceFileName)

        let tempURL = sourceCacheDirectory
            .appendingPathComponent(header.sourceFileHash + "_" + header.sourceFileName + ".streaming")

        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: tempURL)
        let totalBytes = max(0, header.totalBytes)

        log("[RawFileTransferServer] receiving \(header.sourceFileName), \(totalBytes) bytes")

        receiveFileChunks(
            connection: connection,
            handle: handle,
            receivedBytes: 0,
            totalBytes: totalBytes,
            tempURL: tempURL,
            finalURL: finalURL
        )
    }

    private func receiveFileChunks(
        connection: NWConnection,
        handle: FileHandle,
        receivedBytes: Int64,
        totalBytes: Int64,
        tempURL: URL,
        finalURL: URL
    ) {
        if receivedBytes >= totalBytes {
            do {
                try handle.close()

                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }

                try FileManager.default.moveItem(at: tempURL, to: finalURL)
                log("[RawFileTransferServer] completed -> \(finalURL.path)")
                sendAck(connection: connection, ok: true, message: "文件接收完成", path: finalURL.path)
            } catch {
                sendAck(connection: connection, ok: false, message: error.localizedDescription, path: nil)
            }
            return
        }

        let remaining = Int(max(1, min(Int64(16 * 1024 * 1024), totalBytes - receivedBytes)))

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: remaining
        ) { [weak self] data, _, _, error in
            guard let self else {
                try? handle.close()
                return
            }

            if let error {
                try? handle.close()
                self.sendAck(connection: connection, ok: false, message: error.localizedDescription, path: nil)
                return
            }

            guard let data, !data.isEmpty else {
                try? handle.close()
                self.sendAck(connection: connection, ok: false, message: "连接提前结束", path: nil)
                return
            }

            do {
                try handle.write(contentsOf: data)
                let nextReceived = receivedBytes + Int64(data.count)

                if totalBytes > 0 {
                    let pct = Int(Double(nextReceived) / Double(totalBytes) * 100.0)
                    if pct % 10 == 0 {
                        self.log("[RawFileTransferServer] receiving \(pct)% \(nextReceived)/\(totalBytes)")
                    }
                }

                self.receiveFileChunks(
                    connection: connection,
                    handle: handle,
                    receivedBytes: nextReceived,
                    totalBytes: totalBytes,
                    tempURL: tempURL,
                    finalURL: finalURL
                )
            } catch {
                try? handle.close()
                self.sendAck(connection: connection, ok: false, message: error.localizedDescription, path: nil)
            }
        }
    }

    private func sendAck(
        connection: NWConnection,
        ok: Bool,
        message: String,
        path: String?
    ) {
        let ack = RawFileTransferAck(ok: ok, message: message, path: path)
        let data = (try? JSONEncoder().encode(ack)) ?? Data()
        connection.send(
            content: data,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func uint64FromBigEndianData(_ data: Data) -> UInt64 {
        var value: UInt64 = 0
        for byte in data {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}
