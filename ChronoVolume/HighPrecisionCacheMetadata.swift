import Foundation

struct HighPrecisionCacheMetadata: Codable {
    let version: Int
    let sourcePath: String
    let sourceFileName: String
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceFrameCount: Int
    let fps: Double
    let durationSeconds: Double
    let preserveAlpha: Bool
    let codecName: String
    var colorProfile: VideoColorProfile = .rec709
    let createdAtISO8601: String

    private enum CodingKeys: String, CodingKey {
        case version
        case sourcePath
        case sourceFileName
        case sourceWidth
        case sourceHeight
        case sourceFrameCount
        case fps
        case durationSeconds
        case preserveAlpha
        case codecName
        case colorProfile
        case createdAtISO8601
    }

    init(
        version: Int,
        sourcePath: String,
        sourceFileName: String,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        fps: Double,
        durationSeconds: Double,
        preserveAlpha: Bool,
        codecName: String,
        colorProfile: VideoColorProfile = .rec709,
        createdAtISO8601: String
    ) {
        self.version = version
        self.sourcePath = sourcePath
        self.sourceFileName = sourceFileName
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceFrameCount = sourceFrameCount
        self.fps = fps
        self.durationSeconds = durationSeconds
        self.preserveAlpha = preserveAlpha
        self.codecName = codecName
        self.colorProfile = colorProfile
        self.createdAtISO8601 = createdAtISO8601
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        sourceFileName = try container.decodeIfPresent(String.self, forKey: .sourceFileName) ?? ""
        sourceWidth = try container.decodeIfPresent(Int.self, forKey: .sourceWidth) ?? 0
        sourceHeight = try container.decodeIfPresent(Int.self, forKey: .sourceHeight) ?? 0
        sourceFrameCount = try container.decodeIfPresent(Int.self, forKey: .sourceFrameCount) ?? 0
        fps = try container.decodeIfPresent(Double.self, forKey: .fps) ?? 0
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        preserveAlpha = try container.decodeIfPresent(Bool.self, forKey: .preserveAlpha) ?? false
        codecName = try container.decodeIfPresent(String.self, forKey: .codecName) ?? ""
        colorProfile = try container.decodeIfPresent(VideoColorProfile.self, forKey: .colorProfile) ?? .rec709
        createdAtISO8601 = try container.decodeIfPresent(String.self, forKey: .createdAtISO8601) ?? ""
    }
}

enum HighPrecisionCacheError: LocalizedError {
    case sourceNotFound
    case cacheNotFound
    case writerFailed(String)
    case readerFailed(String)
    case invalidSource(String)
    case metadataWriteFailed(String)
    case metadataReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "未找到源视频"
        case .cacheNotFound:
            return "未找到高精度缓存"
        case .writerFailed(let reason):
            return "高精度缓存写入失败：\(reason)"
        case .readerFailed(let reason):
            return "高精度缓存读取失败：\(reason)"
        case .invalidSource(let reason):
            return "源视频无效：\(reason)"
        case .metadataWriteFailed(let reason):
            return "缓存元数据写入失败：\(reason)"
        case .metadataReadFailed(let reason):
            return "缓存元数据读取失败：\(reason)"
        }
    }
}
