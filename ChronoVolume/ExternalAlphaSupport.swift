import Foundation

enum AlphaSourceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case embedded
    case external
    case opaque

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .embedded: return "内嵌 Alpha"
        case .external: return "外部 B_alpha"
        case .opaque: return "不透明"
        }
    }
}

enum ExternalAlphaChannel: String, Codable, CaseIterable, Sendable, Identifiable {
    case luma
    case red
    case green
    case blue
    case alpha

    var id: String { rawValue }
}

enum ExternalAlphaRange: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case full
    case limited

    var id: String { rawValue }
}

enum ExternalAlphaSyncPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case strict
    case nearestFrame
    case resampleToColorTimeline
    case trimToShortest

    var id: String { rawValue }
}

enum ExternalAlphaResizePolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case strict
    case scaleAlphaToColorSize

    var id: String { rawValue }
}

enum AlphaAssociation: String, Codable, CaseIterable, Sendable, Identifiable {
    case straight
    case premultiplied

    var id: String { rawValue }
}

enum ExternalAlphaPreviewMode: String, CaseIterable, Identifiable {
    case grayscaleMask = "灰度遮罩"
    case checkerboardTransparency = "棋盘格透明预览"
    case composite = "A_color + B_alpha 合成"

    var id: String { rawValue }
}

struct ExternalAlphaSettings: Codable, Equatable, Hashable, Sendable {
    var channel: ExternalAlphaChannel = .luma
    var invert: Bool = false
    var range: ExternalAlphaRange = .auto
    var syncPolicy: ExternalAlphaSyncPolicy = .strict
    var resizePolicy: ExternalAlphaResizePolicy = .strict
    var association: AlphaAssociation = .straight

    func applyingGeneratedWhiteColorSemantics(_ generatedWhiteColor: Bool) -> Self {
        guard generatedWhiteColor else { return self }
        var result = self
        result.syncPolicy = .strict
        result.resizePolicy = .strict
        result.association = .straight
        return result
    }
}

enum ExternalAlphaEditableSetting: String, CaseIterable, Sendable {
    case channel
    case invert
    case range
    case association
    case syncPolicy
    case resizePolicy
}

enum ExternalAlphaSettingsAvailability {
    static func editableSettings(for pair: VideoSourcePair) -> Set<ExternalAlphaEditableSetting> {
        var result: Set<ExternalAlphaEditableSetting> = [.channel, .invert, .range]
        if !pair.usesGeneratedWhiteColor {
            result.formUnion([.association, .syncPolicy, .resizePolicy])
        }
        return result
    }
}

struct VideoSourcePair: Codable, Equatable, Hashable, Sendable {
    var colorURL: URL
    var alphaURL: URL?
    var alphaSourceMode: AlphaSourceMode
    var externalAlphaSettings: ExternalAlphaSettings
    /// B_alpha-only imports use the alpha movie as the timeline/geometry carrier while
    /// the loader synthesizes straight, opaque-white RGB before applying its samples.
    var usesGeneratedWhiteColor: Bool

    init(
        colorURL: URL,
        alphaURL: URL? = nil,
        alphaSourceMode: AlphaSourceMode = .opaque,
        externalAlphaSettings: ExternalAlphaSettings = ExternalAlphaSettings(),
        usesGeneratedWhiteColor: Bool = false
    ) {
        self.colorURL = colorURL
        self.alphaURL = alphaURL
        self.alphaSourceMode = alphaURL == nil && alphaSourceMode == .external ? .opaque : alphaSourceMode
        self.usesGeneratedWhiteColor = alphaURL == nil ? false : usesGeneratedWhiteColor
        self.externalAlphaSettings = externalAlphaSettings.applyingGeneratedWhiteColorSemantics(
            self.usesGeneratedWhiteColor
        )
    }

    private enum CodingKeys: String, CodingKey {
        case colorURL
        case alphaURL
        case alphaSourceMode
        case externalAlphaSettings
        case usesGeneratedWhiteColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let colorURL = try container.decode(URL.self, forKey: .colorURL)
        let alphaURL = try container.decodeIfPresent(URL.self, forKey: .alphaURL)
        self.init(
            colorURL: colorURL,
            alphaURL: alphaURL,
            alphaSourceMode: try container.decodeIfPresent(AlphaSourceMode.self, forKey: .alphaSourceMode) ?? (alphaURL == nil ? .opaque : .external),
            externalAlphaSettings: try container.decodeIfPresent(ExternalAlphaSettings.self, forKey: .externalAlphaSettings) ?? ExternalAlphaSettings(),
            usesGeneratedWhiteColor: try container.decodeIfPresent(Bool.self, forKey: .usesGeneratedWhiteColor) ?? false
        )
    }
}

enum ExternalPairedRenderPolicy {
    static let generatedWhiteHighBitDepthReason =
        "B_alpha 可以用于交互式 RGBA8 白模预览，但当前分布式 paired renderer 仅支持不超过 8-bit 的 B_alpha。"

    static let generatedWhiteDistributedNotice =
        "B_alpha 可用于交互式 RGBA8 白模预览和普通本机 RGBA8 导出；当前分布式 paired renderer 仅支持不超过 8-bit 的 B_alpha 与不超过 8-bit 的输出，gray10/12/16le 会在传输前明确拒绝。"

    static func rejectionReason(
        sourceColorBitDepth: Int,
        sourceAlphaBitDepth: Int,
        outputBitDepth: Int,
        usesGeneratedWhiteColor: Bool = false
    ) -> String? {
        if usesGeneratedWhiteColor,
           sourceAlphaBitDepth > 8 || outputBitDepth > 8 {
            return "\(generatedWhiteHighBitDepthReason) 当前 B_alpha 为 \(sourceAlphaBitDepth)-bit，输出为 \(outputBitDepth)-bit；任务未开始传输或建立 Worker 作业。"
        }
        guard sourceColorBitDepth <= 8,
              sourceAlphaBitDepth <= 8,
              outputBitDepth <= 8 else {
            return "external paired renderer 为 RGBA8；输出 \(outputBitDepth)-bit、颜色 \(sourceColorBitDepth)-bit、Alpha \(sourceAlphaBitDepth)-bit 的组合不受支持，已在调度前拒绝。"
        }
        return nil
    }
}

struct VideoSourceMetadata: Codable, Equatable, Sendable {
    var fileName: String
    var container: String
    var codec: String
    var width: Int
    var height: Int
    var rotationDegrees: Int
    var fps: Double
    var durationSeconds: Double
    var frameCount: Int
    var startTimeSeconds: Double
    var timeBase: String
    var pixelFormat: String
    var bitDepth: Int
    var range: ExternalAlphaRange
    var colorPrimaries: String
    var transfer: String
    var matrix: String
    var hasEmbeddedAlpha: Bool

    var displayWidth: Int {
        abs(rotationDegrees) % 180 == 90 ? height : width
    }

    var displayHeight: Int {
        abs(rotationDegrees) % 180 == 90 ? width : height
    }

    var summary: String {
        "\(fileName) · \(container)/\(codec) · \(displayWidth)×\(displayHeight) · \(String(format: "%.3f", fps)) fps · \(frameCount) 帧 · \(pixelFormat) \(bitDepth)-bit"
    }
}

struct HighPrecisionAlphaVolume: Sendable {
    let width: Int
    let height: Int
    let depth: Int
    let samples: [UInt16]
    let sourceBitDepth: Int
    let sourceRange: ExternalAlphaRange
    let presentationTimes: [Double]

    func sample(frame: Int, x: Int, y: Int) -> UInt16 {
        samples[(frame * height + y) * width + x]
    }
}

enum ExternalAlphaError: LocalizedError, Equatable {
    case unsupportedPixelFormat(String)
    case invalidBitDepth(Int)
    case resolutionMismatch(colorWidth: Int, colorHeight: Int, alphaWidth: Int, alphaHeight: Int)
    case frameRateMismatch(color: Double, alpha: Double)
    case timeBaseMismatch(color: String, alpha: String)
    case durationMismatch(color: Double, alpha: Double, firstUnpairedTime: Double)
    case frameCountMismatch(color: Int, alpha: Int, firstUnpairedTime: Double)
    case timestampMismatch(colorIndex: Int, colorTime: Double, alphaIndex: Int, alphaTime: Double)
    case noTimestamp
    case ffmpegNotFound
    case ffprobeFailed(String)
    case ffmpegFailed(String)
    case decodedByteCountMismatch(expectedMultiple: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedPixelFormat(let format):
            return "B_alpha 像素格式不受支持：\(format)。支持 gray8/10/12/16le 及可解码的 RGB(A) 通道。"
        case .invalidBitDepth(let depth):
            return "B_alpha 位深无效：\(depth) bit"
        case let .resolutionMismatch(cw, ch, aw, ah):
            return "分辨率不一致：A_color 为 \(cw)×\(ch)，B_alpha 为 \(aw)×\(ah)。请选择“缩放 B_alpha”兼容策略后重试。"
        case let .frameRateMismatch(color, alpha):
            return "帧率不一致：A_color 为 \(String(format: "%.6f", color)) fps，B_alpha 为 \(String(format: "%.6f", alpha)) fps。请选择显式同步兼容策略后重试。"
        case let .timeBaseMismatch(color, alpha):
            return "时间基不一致：A_color 为 \(color)，B_alpha 为 \(alpha)。请选择显式同步兼容策略后重试。"
        case let .durationMismatch(color, alpha, time):
            return "时长不一致：A_color 为 \(String(format: "%.6f", color)) 秒，B_alpha 为 \(String(format: "%.6f", alpha)) 秒；首个无法严格配对的时间为 \(String(format: "%.6f", time)) 秒。"
        case let .frameCountMismatch(color, alpha, time):
            return "帧数不一致：A_color 为 \(color) 帧，B_alpha 为 \(alpha) 帧；首个无法配对的时间为 \(String(format: "%.6f", time)) 秒。"
        case let .timestampMismatch(ci, ct, ai, at):
            return "时间戳不匹配：A_color 第 \(ci) 帧 PTS=\(String(format: "%.6f", ct))，最近的 B_alpha 第 \(ai) 帧 PTS=\(String(format: "%.6f", at))。"
        case .noTimestamp:
            return "无法取得逐帧 presentation timestamp，不能执行严格双源同步。"
        case .ffmpegNotFound:
            return "未找到 FFmpeg/ffprobe；FFV1、MKV 或高位深 B_alpha 需要安装 FFmpeg。"
        case .ffprobeFailed(let reason):
            return "ffprobe 探测 B_alpha 失败：\(reason)"
        case .ffmpegFailed(let reason):
            return "FFmpeg 解码 B_alpha 失败：\(reason)"
        case let .decodedByteCountMismatch(expected, actual):
            return "B_alpha 原始解码数据损坏：字节数 \(actual) 不是单帧 \(expected) 字节的整数倍。"
        }
    }
}

enum ExternalAlphaNormalizer {
    static func normalized(
        codeValue: UInt16,
        bitDepth: Int,
        range: ExternalAlphaRange,
        invert: Bool = false
    ) throws -> Double {
        guard (1...16).contains(bitDepth) else {
            throw ExternalAlphaError.invalidBitDepth(bitDepth)
        }

        let maxCode = Double((UInt32(1) << UInt32(bitDepth)) - 1)
        let value = Double(codeValue)
        let result: Double
        switch range {
        case .auto, .full:
            result = value / maxCode
        case .limited:
            let scale = pow(2.0, Double(bitDepth - 8))
            let black = 16.0 * scale
            let white = 235.0 * scale
            result = (value - black) / (white - black)
        }
        let clamped = min(1.0, max(0.0, result))
        return invert ? 1.0 - clamped : clamped
    }

    static func previewByte(
        codeValue: UInt16,
        bitDepth: Int,
        range: ExternalAlphaRange,
        invert: Bool = false
    ) throws -> UInt8 {
        let value = try normalized(codeValue: codeValue, bitDepth: bitDepth, range: range, invert: invert)
        return UInt8(min(255, max(0, Int((value * 255.0).rounded()))))
    }

    static func highPrecisionUInt16(
        codeValue: UInt16,
        bitDepth: Int,
        range: ExternalAlphaRange,
        invert: Bool = false
    ) throws -> UInt16 {
        let value = try normalized(codeValue: codeValue, bitDepth: bitDepth, range: range, invert: invert)
        return UInt16(min(65535, max(0, Int((value * 65535.0).rounded()))))
    }

    static func selectedCodeValue(
        rgba: (UInt16, UInt16, UInt16, UInt16),
        channel: ExternalAlphaChannel,
        bitDepth: Int,
        lumaCoefficients: (Double, Double, Double) = (0.2126, 0.7152, 0.0722)
    ) -> UInt16 {
        switch channel {
        case .red: return rgba.0
        case .green: return rgba.1
        case .blue: return rgba.2
        case .alpha: return rgba.3
        case .luma:
            let maxCode = Double((UInt32(1) << UInt32(min(16, max(1, bitDepth)))) - 1)
            let y = lumaCoefficients.0 * Double(rgba.0)
                + lumaCoefficients.1 * Double(rgba.1)
                + lumaCoefficients.2 * Double(rgba.2)
            return UInt16(min(maxCode, max(0, y.rounded())))
        }
    }

    static func lumaCoefficients(matrix: String, primaries: String) -> (Double, Double, Double) {
        let value = (matrix + " " + primaries).lowercased()
        if value.contains("2020") { return (0.2627, 0.6780, 0.0593) }
        if value.contains("601") || value.contains("170m") || value.contains("470") {
            return (0.2990, 0.5870, 0.1140)
        }
        return (0.2126, 0.7152, 0.0722)
    }
}

enum ExternalAlphaFrameSynchronizer {
    struct Match: Equatable, Sendable {
        let color: Int
        let alpha0: Int
        let alpha1: Int
        let fraction: Double

        var nearestAlpha: Int { fraction < 0.5 ? alpha0 : alpha1 }
    }

    static func pair(
        colorTimes: [Double],
        alphaTimes: [Double],
        policy: ExternalAlphaSyncPolicy,
        colorFPS: Double = 0,
        alphaFPS: Double = 0,
        colorDuration: Double? = nil,
        alphaDuration: Double? = nil,
        colorTimeBase: String? = nil,
        alphaTimeBase: String? = nil,
        colorHasRealPTS: Bool = true,
        alphaHasRealPTS: Bool = true
    ) throws -> [(color: Int, alpha: Int)] {
        try matches(
            colorTimes: colorTimes,
            alphaTimes: alphaTimes,
            policy: policy,
            colorFPS: colorFPS,
            alphaFPS: alphaFPS,
            colorDuration: colorDuration,
            alphaDuration: alphaDuration,
            colorTimeBase: colorTimeBase,
            alphaTimeBase: alphaTimeBase,
            colorHasRealPTS: colorHasRealPTS,
            alphaHasRealPTS: alphaHasRealPTS
        ).map { ($0.color, $0.nearestAlpha) }
    }

    static func matches(
        colorTimes: [Double],
        alphaTimes: [Double],
        policy: ExternalAlphaSyncPolicy,
        colorFPS: Double = 0,
        alphaFPS: Double = 0,
        colorDuration: Double? = nil,
        alphaDuration: Double? = nil,
        colorTimeBase: String? = nil,
        alphaTimeBase: String? = nil,
        colorHasRealPTS: Bool = true,
        alphaHasRealPTS: Bool = true
    ) throws -> [Match] {
        guard !colorTimes.isEmpty, !alphaTimes.isEmpty else {
            throw ExternalAlphaError.noTimestamp
        }

        if policy == .strict {
            guard colorHasRealPTS, alphaHasRealPTS else {
                throw ExternalAlphaError.noTimestamp
            }
            if colorFPS > 0, alphaFPS > 0,
               abs(colorFPS - alphaFPS) > fpsTolerance(colorFPS, alphaFPS) {
                throw ExternalAlphaError.frameRateMismatch(color: colorFPS, alpha: alphaFPS)
            }
            // Container time_base is diagnostic only. PTS values below are already normalized to seconds.
            _ = colorTimeBase
            _ = alphaTimeBase
            if let colorDuration, let alphaDuration, abs(colorDuration - alphaDuration) > strictTolerance(fps: max(colorFPS, alphaFPS)) {
                throw ExternalAlphaError.durationMismatch(
                    color: colorDuration,
                    alpha: alphaDuration,
                    firstUnpairedTime: min(colorDuration, alphaDuration)
                )
            }
            guard colorTimes.count == alphaTimes.count else {
                let common = min(colorTimes.count, alphaTimes.count)
                let first = common < colorTimes.count ? colorTimes[common] : alphaTimes[common]
                throw ExternalAlphaError.frameCountMismatch(
                    color: colorTimes.count,
                    alpha: alphaTimes.count,
                    firstUnpairedTime: first
                )
            }

            let tolerance = strictTolerance(fps: max(colorFPS, alphaFPS))
            return try colorTimes.indices.map { index in
                let delta = abs(colorTimes[index] - alphaTimes[index])
                guard delta <= tolerance else {
                    let nearest = nearestIndex(to: colorTimes[index], in: alphaTimes)
                    throw ExternalAlphaError.timestampMismatch(
                        colorIndex: index,
                        colorTime: colorTimes[index],
                        alphaIndex: nearest,
                        alphaTime: alphaTimes[nearest]
                    )
                }
                return Match(color: index, alpha0: index, alpha1: index, fraction: 0)
            }
        }

        switch policy {
        case .nearestFrame:
            return colorTimes.indices.map { index in
                let alpha = nearestIndex(to: colorTimes[index], in: alphaTimes)
                return Match(color: index, alpha0: alpha, alpha1: alpha, fraction: 0)
            }
        case .resampleToColorTimeline:
            return colorTimes.indices.map { index in
                interpolatedMatch(colorIndex: index, time: colorTimes[index], alphaTimes: alphaTimes)
            }
        case .trimToShortest:
            let intervalStart = max(colorTimes.first!, alphaTimes.first!)
            let intervalEnd = min(colorTimes.last!, alphaTimes.last!)
            guard intervalEnd >= intervalStart else { return [] }
            return colorTimes.indices.compactMap { index in
                let time = colorTimes[index]
                guard time >= intervalStart, time <= intervalEnd else { return nil }
                let alpha = nearestIndex(to: time, in: alphaTimes)
                return Match(color: index, alpha0: alpha, alpha1: alpha, fraction: 0)
            }
        case .strict:
            return []
        }
    }

    private static func strictTolerance(fps: Double) -> Double {
        guard fps > 0 else { return 0.000_5 }
        return max(0.000_5, (1.0 / fps) * 0.02)
    }

    private static func fpsTolerance(_ lhs: Double, _ rhs: Double) -> Double {
        max(0.01, max(lhs, rhs) * 0.001)
    }

    private static func interpolatedMatch(colorIndex: Int, time: Double, alphaTimes: [Double]) -> Match {
        if time <= alphaTimes[0] {
            return Match(color: colorIndex, alpha0: 0, alpha1: 0, fraction: 0)
        }
        if time >= alphaTimes[alphaTimes.count - 1] {
            let last = alphaTimes.count - 1
            return Match(color: colorIndex, alpha0: last, alpha1: last, fraction: 0)
        }
        var low = 0
        var high = alphaTimes.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if alphaTimes[mid] <= time { low = mid } else { high = mid }
        }
        let span = alphaTimes[high] - alphaTimes[low]
        let fraction = span > 0 ? min(1, max(0, (time - alphaTimes[low]) / span)) : 0
        return Match(color: colorIndex, alpha0: low, alpha1: high, fraction: fraction)
    }

    private static func nearestIndex(to time: Double, in times: [Double]) -> Int {
        var low = 0
        var high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < time { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return 0 }
        if low == times.count { return times.count - 1 }
        return abs(times[low] - time) < abs(times[low - 1] - time) ? low : low - 1
    }
}

enum ExternalAlphaCompatibilityValidator {
    static func validateDimensions(
        color: VideoSourceMetadata,
        alpha: VideoSourceMetadata,
        policy: ExternalAlphaResizePolicy
    ) throws {
        guard policy == .strict else { return }
        guard color.displayWidth == alpha.displayWidth,
              color.displayHeight == alpha.displayHeight else {
            throw ExternalAlphaError.resolutionMismatch(
                colorWidth: color.displayWidth,
                colorHeight: color.displayHeight,
                alphaWidth: alpha.displayWidth,
                alphaHeight: alpha.displayHeight
            )
        }
    }
}

enum ExternalAlphaMerger {
    static func mergePreview(
        colorRGBA: [UInt8],
        alphaCodeValues: [UInt16],
        bitDepth: Int,
        range: ExternalAlphaRange,
        invert: Bool
    ) throws -> [UInt8] {
        guard colorRGBA.count == alphaCodeValues.count * 4 else {
            throw ExternalAlphaError.decodedByteCountMismatch(
                expectedMultiple: alphaCodeValues.count * 4,
                actual: colorRGBA.count
            )
        }
        var result = colorRGBA
        for index in alphaCodeValues.indices {
            result[index * 4 + 3] = try ExternalAlphaNormalizer.previewByte(
                codeValue: alphaCodeValues[index],
                bitDepth: bitDepth,
                range: range,
                invert: invert
            )
        }
        return result
    }

    static func unpremultiplyRGB(
        rgba: inout [UInt8],
        normalizedAlpha: [UInt16]
    ) -> Int {
        precondition(rgba.count == normalizedAlpha.count * 4)
        var unrecoverable = 0
        for pixel in normalizedAlpha.indices {
            let alpha16 = normalizedAlpha[pixel]
            if alpha16 == 0 {
                unrecoverable += 1
                continue
            }
            let alpha = Double(alpha16) / 65535.0
            for channel in 0..<3 {
                let offset = pixel * 4 + channel
                rgba[offset] = UInt8(min(255, max(0, Int((Double(rgba[offset]) / alpha).rounded()))))
            }
        }
        return unrecoverable
    }
}

enum VideoSourcePairDiscovery {
    enum Role: String, Sendable {
        case color
        case alpha
    }

    struct AlphaCheaterGroup: Equatable, Sendable {
        let pairingKey: String
        var colorURL: URL?
        var alphaURL: URL?

        var sourcePair: VideoSourcePair {
            if let colorURL {
                return VideoSourcePair(
                    colorURL: colorURL,
                    alphaURL: alphaURL,
                    alphaSourceMode: alphaURL == nil ? .opaque : .external
                )
            }
            let alphaURL = alphaURL!
            return VideoSourcePair(
                colorURL: alphaURL,
                alphaURL: alphaURL,
                alphaSourceMode: .external,
                usesGeneratedWhiteColor: true
            )
        }
    }

    struct AlphaCheaterImportClassification: Sendable {
        let groups: [AlphaCheaterGroup]
        let unrecognized: [URL]
        let roleConflicts: [RoleConflict]

        var duplicateRoles: [URL] { roleConflicts.map(\.incomingURL) }
    }

    struct RoleConflict: Equatable, Sendable {
        let pairingKey: String
        let role: Role
        let keptURL: URL
        let incomingURL: URL

        var diagnostic: String {
            let roleName = role == .color ? "A_color" : "B_alpha"
            return "\(roleName) 冲突：保留 \(keptURL.lastPathComponent)，未覆盖为 \(incomingURL.lastPathComponent)"
        }
    }

    struct PairingIdentityResolution: Equatable, Sendable {
        let pairingKey: String?
        let diagnostic: String?
    }

    static func classifyAlphaCheaterURLs(_ urls: [URL]) -> AlphaCheaterImportClassification {
        var groups: [String: AlphaCheaterGroup] = [:]
        var order: [String] = []
        var unrecognized: [URL] = []
        var conflicts: [RoleConflict] = []

        for url in urls {
            guard let identity = alphaCheaterIdentity(for: url) else {
                unrecognized.append(url)
                continue
            }
            if groups[identity.key] == nil {
                groups[identity.key] = AlphaCheaterGroup(
                    pairingKey: identity.key,
                    colorURL: nil,
                    alphaURL: nil
                )
                order.append(identity.key)
            }
            var group = groups[identity.key]!
            switch identity.role {
            case .color:
                if let keptURL = group.colorURL {
                    if !urlsReferToSameFile(keptURL, url) {
                        conflicts.append(RoleConflict(
                            pairingKey: identity.key,
                            role: .color,
                            keptURL: keptURL,
                            incomingURL: url
                        ))
                    }
                } else {
                    group.colorURL = url
                }
            case .alpha:
                if let keptURL = group.alphaURL {
                    if !urlsReferToSameFile(keptURL, url) {
                        conflicts.append(RoleConflict(
                            pairingKey: identity.key,
                            role: .alpha,
                            keptURL: keptURL,
                            incomingURL: url
                        ))
                    }
                } else {
                    group.alphaURL = url
                }
            }
            groups[identity.key] = group
        }

        return AlphaCheaterImportClassification(
            groups: order.compactMap { groups[$0] },
            unrecognized: unrecognized,
            roleConflicts: conflicts
        )
    }

    static func pairingKey(for url: URL) -> String? {
        alphaCheaterIdentity(for: url)?.key
    }

    static func pairingKey(for pair: VideoSourcePair) -> String? {
        if pair.usesGeneratedWhiteColor, let alphaURL = pair.alphaURL {
            return pairingKey(for: alphaURL)
        }
        return pairingKey(for: pair.colorURL) ?? pair.alphaURL.flatMap(pairingKey(for:))
    }

    static func restoredPairingIdentity(
        for pair: VideoSourcePair,
        persistedKey: String?
    ) -> PairingIdentityResolution {
        let currentColorKey = pair.usesGeneratedWhiteColor ? nil : pairingKey(for: pair.colorURL)
        let currentAlphaKey = pair.alphaURL.flatMap { pairingKey(for: $0) }

        if pair.usesGeneratedWhiteColor {
            return PairingIdentityResolution(
                pairingKey: currentAlphaKey ?? persistedKey,
                diagnostic: nil
            )
        }
        guard pair.alphaURL != nil else {
            return PairingIdentityResolution(
                pairingKey: currentColorKey ?? persistedKey,
                diagnostic: nil
            )
        }

        switch (currentColorKey, currentAlphaKey) {
        case let (colorKey?, alphaKey?) where colorKey == alphaKey:
            return PairingIdentityResolution(pairingKey: colorKey, diagnostic: nil)
        case let (colorKey?, nil):
            return PairingIdentityResolution(pairingKey: colorKey, diagnostic: nil)
        case let (nil, alphaKey?):
            return PairingIdentityResolution(pairingKey: alphaKey, diagnostic: nil)
        case (nil, nil):
            return PairingIdentityResolution(pairingKey: persistedKey, diagnostic: nil)
        case let (colorKey?, alphaKey?):
            if let persistedKey {
                return PairingIdentityResolution(pairingKey: persistedKey, diagnostic: nil)
            }
            let compatibilityKey = min(colorKey, alphaKey)
            let diagnostic = "AlphaCheater 完整配对的 A_color（\(pair.colorURL.lastPathComponent)）与 B_alpha（\(pair.alphaURL?.lastPathComponent ?? "未知")）属于不同分组，且工程未保存 pairingKey；兼容模式采用两个规范化 key 中按字典序较小者。请重新保存工程以固定身份。"
            return PairingIdentityResolution(
                pairingKey: compatibilityKey,
                diagnostic: diagnostic
            )
        }
    }

    static func role(for url: URL) -> Role? {
        alphaCheaterIdentity(for: url)?.role
    }

    static func matchingAlphaURL(for colorURL: URL) -> URL? {
        let directory = colorURL.deletingLastPathComponent()
        let stem = colorURL.deletingPathExtension().lastPathComponent
        let lower = stem.lowercased()
        let alphaStem: String
        if lower.hasSuffix("_a_color") {
            alphaStem = String(stem.dropLast("_A_color".count)) + "_B_alpha"
        } else if lower.hasSuffix("-a_color") {
            alphaStem = String(stem.dropLast("-A_color".count)) + "-B_alpha"
        } else if lower == "a_color" {
            alphaStem = "B_alpha"
        } else {
            return nil
        }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files.first {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(alphaStem) == .orderedSame
        }
    }

    static func matchingColorURL(for alphaURL: URL) -> URL? {
        let directory = alphaURL.deletingLastPathComponent()
        let stem = alphaURL.deletingPathExtension().lastPathComponent
        let lower = stem.lowercased()
        let colorStem: String
        if lower.hasSuffix("_b_alpha") {
            colorStem = String(stem.dropLast("_B_alpha".count)) + "_A_color"
        } else if lower.hasSuffix("-b_alpha") {
            colorStem = String(stem.dropLast("-B_alpha".count)) + "-A_color"
        } else if lower == "b_alpha" {
            colorStem = "A_color"
        } else {
            return nil
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return files.first {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(colorStem) == .orderedSame
        }
    }

    private static func alphaCheaterIdentity(for url: URL) -> (role: Role, key: String)? {
        let stem = url.deletingPathExtension().lastPathComponent
        let lower = stem.lowercased()
        let role: Role
        let prefix: String
        if lower.hasSuffix("_a_color") {
            role = .color
            prefix = String(lower.dropLast("_a_color".count))
        } else if lower.hasSuffix("-a_color") {
            role = .color
            prefix = String(lower.dropLast("-a_color".count))
        } else if lower == "a_color" {
            role = .color
            prefix = ""
        } else if lower.hasSuffix("_b_alpha") {
            role = .alpha
            prefix = String(lower.dropLast("_b_alpha".count))
        } else if lower.hasSuffix("-b_alpha") {
            role = .alpha
            prefix = String(lower.dropLast("-b_alpha".count))
        } else if lower == "b_alpha" {
            role = .alpha
            prefix = ""
        } else {
            return nil
        }
        let directory = normalizedFileURL(url.deletingLastPathComponent()).path
        return (role, directory + "\u{0}" + prefix)
    }

    static func urlsReferToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let normalizedLHS = normalizedFileURL(lhs)
        let normalizedRHS = normalizedFileURL(rhs)
        if let lhsIdentifier = fileResourceIdentifier(for: normalizedLHS),
           let rhsIdentifier = fileResourceIdentifier(for: normalizedRHS) {
            return lhsIdentifier.isEqual(rhsIdentifier)
        }
        return normalizedLHS.path == normalizedRHS.path
    }

    private static func normalizedFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func fileResourceIdentifier(for url: URL) -> NSObject? {
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let identifier = values.fileResourceIdentifier as? NSObject else {
            return nil
        }
        return identifier
    }
}
