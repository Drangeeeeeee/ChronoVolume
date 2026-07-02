import Foundation

struct SegmentMetadata: Codable {
    let jobID: UUID
    let segmentIndex: Int
    let axis: String
    let outputStartFrame: Int
    let outputEndFrame: Int
    let outputWidth: Int
    let outputHeight: Int
    let fps: Double
    let preserveAlpha: Bool
    let codec: String
    let fileName: String
    let fileSizeBytes: Int64
}
