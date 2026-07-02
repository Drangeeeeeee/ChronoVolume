import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics

enum ExportBitDepth: String, CaseIterable, Identifiable, Codable {
    case source
    case bit8
    case bit16
    case bit32

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source:
            return "跟随源视频"
        case .bit8:
            return "8-bit"
        case .bit16:
            return "16-bit"
        case .bit32:
            return "32-bit"
        }
    }

    func resolved(sourceBitDepth: Int) -> Int {
        switch self {
        case .source:
            return max(8, sourceBitDepth)
        case .bit8:
            return 8
        case .bit16:
            return 16
        case .bit32:
            return 32
        }
    }
}

enum SourceBitDepthDetector {
    static func detect(from track: AVAssetTrack) -> Int {
        for description in track.formatDescriptions {
            let formatDescription = description as! CMFormatDescription
            if let detected = detect(from: formatDescription) {
                return detected
            }
        }
        return 8
    }

    private static func detect(from formatDescription: CMFormatDescription) -> Int? {
        if let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any],
           let depth = findBitDepth(in: extensions) {
            return depth
        }

        let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
        let fourCC = fourCharacterCodeString(subtype).lowercased()
        if fourCC.contains("10") || fourCC.contains("x420") || fourCC.contains("x422") || fourCC.contains("xf20") {
            return 10
        }
        if fourCC.contains("16") {
            return 16
        }
        return nil
    }

    private static func findBitDepth(in value: Any) -> Int? {
        if let number = value as? NSNumber {
            let depth = number.intValue
            if depth == 8 || depth == 10 || depth == 12 || depth == 16 || depth == 32 {
                return depth
            }
        }

        if let string = value as? String {
            let lower = string.lowercased()
            if lower.contains("32") { return 32 }
            if lower.contains("16") { return 16 }
            if lower.contains("12") { return 12 }
            if lower.contains("10") { return 10 }
            if lower.contains("8") { return 8 }
        }

        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let lowerKey = key.lowercased()
                if lowerKey.contains("bit") || lowerKey.contains("depth") {
                    if let depth = findBitDepth(in: child) {
                        return depth
                    }
                }
            }
            for child in dictionary.values {
                if let depth = findBitDepth(in: child) {
                    return depth
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let depth = findBitDepth(in: child) {
                    return depth
                }
            }
        }

        return nil
    }

    private static func fourCharacterCodeString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
    }
}

struct VideoColorProfile: Equatable, Codable, Sendable {
    var primaries: String
    var transferFunction: String
    var yCbCrMatrix: String
    var isHDR: Bool

    static let rec709 = VideoColorProfile(
        primaries: AVVideoColorPrimaries_ITU_R_709_2,
        transferFunction: AVVideoTransferFunction_ITU_R_709_2,
        yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
        isHDR: false
    )

    static let displayP3 = VideoColorProfile(
        primaries: AVVideoColorPrimaries_P3_D65,
        transferFunction: AVVideoTransferFunction_ITU_R_709_2,
        yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
        isHDR: false
    )

    static let hdrPQ = VideoColorProfile(
        primaries: AVVideoColorPrimaries_ITU_R_2020,
        transferFunction: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
        yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020,
        isHDR: true
    )

    var title: String {
        if isHDR { return "HDR Rec.2020 PQ" }
        if primaries == AVVideoColorPrimaries_P3_D65 { return "Display P3" }
        return "Rec.709"
    }

    var detailText: String {
        let gammaText: String
        if transferFunction == AVVideoTransferFunction_SMPTE_ST_2084_PQ {
            gammaText = "PQ"
        } else if transferFunction == AVVideoTransferFunction_ITU_R_2100_HLG {
            gammaText = "HLG"
        } else {
            gammaText = "SDR Gamma"
        }
        return "\(title) / \(gammaText)"
    }

    var avVideoColorProperties: [String: Any] {
        [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transferFunction,
            AVVideoYCbCrMatrixKey: yCbCrMatrix
        ]
    }

    var renderColorSpace: CGColorSpace {
        if primaries == AVVideoColorPrimaries_P3_D65 {
            return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        }
        if primaries == AVVideoColorPrimaries_ITU_R_2020 {
            return CGColorSpace(name: CGColorSpace.itur_2020) ?? CGColorSpaceCreateDeviceRGB()
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
}

enum ExportColorProfile: String, CaseIterable, Identifiable, Codable {
    case source
    case rec709
    case displayP3
    case hdrPQ

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source:
            return "跟随源视频"
        case .rec709:
            return "Rec.709"
        case .displayP3:
            return "Display P3"
        case .hdrPQ:
            return "HDR Rec.2020 PQ"
        }
    }

    func resolved(source: VideoColorProfile) -> VideoColorProfile {
        switch self {
        case .source:
            return source
        case .rec709:
            return .rec709
        case .displayP3:
            return .displayP3
        case .hdrPQ:
            return .hdrPQ
        }
    }
}

enum SourceColorProfileDetector {
    static func detect(from track: AVAssetTrack) -> VideoColorProfile {
        for description in track.formatDescriptions {
            let formatDescription = description as! CMFormatDescription
            if let detected = detect(from: formatDescription) {
                return detected
            }
        }
        return .rec709
    }

    private static func detect(from formatDescription: CMFormatDescription) -> VideoColorProfile? {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary? else {
            return nil
        }

        let primaries = stringValue(extensions[kCMFormatDescriptionExtension_ColorPrimaries])
        let transfer = stringValue(extensions[kCMFormatDescriptionExtension_TransferFunction])
        let matrix = stringValue(extensions[kCMFormatDescriptionExtension_YCbCrMatrix])

        let resolvedPrimaries = mapPrimaries(primaries)
        let resolvedTransfer = mapTransferFunction(transfer)
        let resolvedMatrix = mapYCbCrMatrix(matrix, primaries: resolvedPrimaries)
        let hdr = resolvedTransfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ
            || resolvedTransfer == AVVideoTransferFunction_ITU_R_2100_HLG
            || resolvedPrimaries == AVVideoColorPrimaries_ITU_R_2020

        return VideoColorProfile(
            primaries: resolvedPrimaries,
            transferFunction: resolvedTransfer,
            yCbCrMatrix: resolvedMatrix,
            isHDR: hdr
        )
    }

    private static func mapPrimaries(_ value: String?) -> String {
        if same(value, kCMFormatDescriptionColorPrimaries_P3_D65) {
            return AVVideoColorPrimaries_P3_D65
        }
        if same(value, kCMFormatDescriptionColorPrimaries_ITU_R_2020) {
            return AVVideoColorPrimaries_ITU_R_2020
        }
        return AVVideoColorPrimaries_ITU_R_709_2
    }

    private static func mapTransferFunction(_ value: String?) -> String {
        if same(value, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ) {
            return AVVideoTransferFunction_SMPTE_ST_2084_PQ
        }
        if same(value, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG) {
            return AVVideoTransferFunction_ITU_R_2100_HLG
        }
        return AVVideoTransferFunction_ITU_R_709_2
    }

    private static func mapYCbCrMatrix(_ value: String?, primaries: String) -> String {
        if same(value, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020) {
            return AVVideoYCbCrMatrix_ITU_R_2020
        }
        if primaries == AVVideoColorPrimaries_ITU_R_2020 {
            return AVVideoYCbCrMatrix_ITU_R_2020
        }
        return AVVideoYCbCrMatrix_ITU_R_709_2
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        guard let value else { return nil }
        return String(describing: value)
    }

    private static func same(_ value: String?, _ constant: CFString) -> Bool {
        value == (constant as String)
    }
}
