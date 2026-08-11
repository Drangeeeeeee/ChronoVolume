import Foundation

struct DistributedRangeExportRequest {
    let jobID: UUID
    let localSourcePath: String
    var localAlphaSourcePath: String? = nil
    var externalAlphaSettings: ExternalAlphaSettings? = nil

    let mode: SliceMode
    let axis: DistributedAxis
    let referencePlane: ReferencePlaneState
    let preserveAlpha: Bool
    let padToEven: Bool
    let qualityScale: Double

    let sourceWidth: Int
    let sourceHeight: Int
    let sourceFrameCount: Int
    let fps: Double

    let outputWidth: Int
    let outputHeight: Int
    let outputStartFrame: Int
    let outputEndFrame: Int

    let codec: String
    let colorProfile: VideoColorProfile
    var bitDepth: Int = 8
    let outputDirectory: URL
    let preparedRawCacheURL: URL?
    let preparedRawCacheData: Data?
    let preparedCPUVolume: CPUVolume?
    let highPrecisionBatchByteBudget: Int?

    var frameCount: Int {
        max(0, outputEndFrame - outputStartFrame + 1)
    }
}
