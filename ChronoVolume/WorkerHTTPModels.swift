import Foundation

struct WorkerHelloResponse: Codable {
    let name: String
    let status: String
}

struct SourceCheckRequest: Codable {
    let sourceFileHash: String
    let sourceFileName: String
}

struct SourceCheckResponse: Codable {
    let exists: Bool
    let localPath: String?
}

struct StartDistributedJobRequest: Codable {
    let job: DistributedJobManifest
    let localSourcePath: String
    let outputDirectory: String
    let preparedRawCachePath: String?
}

struct StartDistributedJobBatchRequest: Codable {
    let batchID: UUID
    let jobs: [DistributedJobManifest]
    let localSourcePath: String
    let outputDirectory: String
    let preparedRawCachePath: String?
}

struct PrepareSourceRequest: Codable {
    let sourceFileHash: String
    let sourceFileName: String
    let localSourcePath: String
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceFrameCount: Int
}

struct PrepareSourceResponse: Codable {
    let sourceFileHash: String
    let state: String
    let progress: Double
    let message: String
    let rawCachePath: String?
    let importedVolumeInfo: String?
    let error: String?
}

struct JobProgressResponse: Codable {
    let jobID: UUID
    let state: String
    let progress: Double
    let message: String
}

struct JobResultResponse: Codable {
    let jobID: UUID
    let state: String
    let segmentMetadata: SegmentMetadata?
    let segmentPath: String?
    let error: String?
}

struct JobBatchProgressResponse: Codable {
    let batchID: UUID
    let state: String
    let progress: Double
    let message: String
    let currentJobID: UUID?
    let completedJobIDs: [UUID]
    let error: String?
}

struct JobBatchResultResponse: Codable {
    let batchID: UUID
    let state: String
    let results: [JobResultResponse]
    let error: String?
}

struct CancelJobRequest: Codable {
    let jobID: UUID
}

struct GenericOKResponse: Codable {
    let ok: Bool
    let message: String
}
