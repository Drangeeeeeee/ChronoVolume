import Foundation

enum DistributedAxis: String, Codable {
    case x
    case y
}

struct DistributedJobManifest: Codable {
    let jobID: UUID
    let sourceFileName: String
    let sourceFileHash: String
    var alphaSourceFileName: String? = nil
    var alphaSourceFileHash: String? = nil
    var alphaSourceMode: AlphaSourceMode? = nil
    var externalAlphaSettings: ExternalAlphaSettings? = nil
    var usesGeneratedWhiteColor: Bool? = nil
    var sourceColorBitDepth: Int? = nil
    var sourceAlphaBitDepth: Int? = nil
    var outputBitDepth: Int? = nil
    var sourcePresentationTimes: [Double]? = nil
    var alphaAssociation: AlphaAssociation? = nil
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceFrameCount: Int
    let fps: Double

    let mode: SliceMode
    let axis: DistributedAxis
    let referencePlane: ReferencePlaneState
    let preserveAlpha: Bool
    let padToEven: Bool
    let qualityScale: Double

    let outputWidth: Int
    let outputHeight: Int
    let totalOutputFrames: Int

    let outputStartFrame: Int
    let outputEndFrame: Int

    let codec: String
    let colorProfile: VideoColorProfile
    let createdAtISO8601: String
}
