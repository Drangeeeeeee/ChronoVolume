
import Foundation
import AppKit
import AVFoundation
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import simd

enum CompositionAssetKind: String, Codable, Equatable {
    case video
    case mesh
    case precomposition
}

struct CompositionAsset: Identifiable {
    let id: UUID
    var kind: CompositionAssetKind
    var url: URL
    var name: String
    var status: String
    var sourceFileMissing: Bool
    var sourceWidth: Int
    var sourceHeight: Int
    var sourceFrameCount: Int
    var sourceFPS: Double
    var sourceBitDepth: Int
    var sourceColorProfile: VideoColorProfile
    var previewVolume: LoadedVolume?
    var proxyCacheBuiltAt: Date?
    var precomposition: CompositionDocumentState?
    var exportCacheState: CompositionExportCacheState
    var exportCacheMessage: String

    var isPrecomposition: Bool { kind == .precomposition }
    var isVideo: Bool { kind == .video }
    var isMesh: Bool { kind == .mesh }
    var isFileBackedMedia: Bool { isVideo || isMesh }
    var isReady: Bool { isPrecomposition || previewVolume != nil }
    var infoText: String {
        if let precomposition {
            return "预合成\n\(precomposition.width) × \(precomposition.height) × \(precomposition.frameCount) / \(String(format: "%.2f", precomposition.fps)) fps\n\(precomposition.layers.count) 个图层"
        }
        let missingPrefix = sourceFileMissing ? "源文件丢失\n" : ""
        guard isReady else { return missingPrefix + status }
        let proxySize = previewVolume.map { "代理 \($0.width) × \($0.height) × \($0.depth)" } ?? "代理未就绪"
        if isMesh {
            return "\(missingPrefix)3D 模型体素代理\n\(sourceWidth) × \(sourceHeight) × \(sourceFrameCount)\n\(proxySize)"
        }
        return "\(missingPrefix)\(sourceWidth) × \(sourceHeight) × \(sourceFrameCount) / \(String(format: "%.2f", sourceFPS)) fps / \(sourceBitDepth)-bit / \(sourceColorProfile.title)\n\(proxySize)"
    }

    var exportCacheText: String {
        exportCacheMessage
    }

    var isExportCacheBusy: Bool {
        exportCacheState == .building || exportCacheState == .loading
    }
}

enum CompositionExportCacheState: String, Equatable {
    case unknown
    case missing
    case building
    case loading
    case ready
    case failed
}

struct CompositionMediaManagerItem: Identifiable {
    let id: UUID
    var name: String
    var path: String
    var fileStatusText: String
    var isMissing: Bool
    var sourceText: String
    var bitDepthText: String
    var alphaText: String
    var rawCacheStatusText: String
    var rawCacheSizeBytes: Int64
    var rawCacheSizeText: String
    var exportCacheState: CompositionExportCacheState
}

struct CompositionCachePolicyItem: Identifiable {
    let id: UUID
    var name: String
    var path: String
    var sourceText: String
    var sourceMissing: Bool
    var proxyStatusText: String
    var proxyDetailText: String
    var proxyNeedsBuild: Bool
    var proxyIsExpired: Bool
    var highPrecisionStatusText: String
    var highPrecisionDetailText: String
    var highPrecisionNeedsBuild: Bool
    var highPrecisionIsExpired: Bool
    var requiredHighPrecisionAlpha: Bool
    var cacheSizeBytes: Int64
    var cacheSizeText: String
}

struct CompositionPerformanceSnapshot: Equatable {
    var previewFPS: Double = 0
    var previewPathText: String = "Metal GPU（等待首帧）"
    var sourcePathText: String = "预览：代理 3D texture"
    var drawableText: String = "-"
    var activeLayerCount: Int = 0
    var textureHitCount: Int = 0
    var textureMissCount: Int = 0
    var rawCacheHitCount: Int = 0
    var rawCacheMissCount: Int = 0
    var estimatedTextureMemoryBytes: Int64 = 0
    var appMemoryBytes: UInt64 = 0
    var physicalMemoryBytes: UInt64 = 0
    var memoryPressureText: String = "未知"
    var memoryPressureLevel: Double = 0
    var updatedAt: Date = Date()

    var textureHitRate: Double {
        let total = textureHitCount + textureMissCount
        guard total > 0 else { return 1 }
        return Double(textureHitCount) / Double(total)
    }

    var rawCacheHitRate: Double {
        let total = rawCacheHitCount + rawCacheMissCount
        guard total > 0 else { return 1 }
        return Double(rawCacheHitCount) / Double(total)
    }
}

enum CompositionRenderQueueJobStatus: String, CaseIterable, Identifiable {
    case queued
    case running
    case completed
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queued: return "等待"
        case .running: return "渲染中"
        case .completed: return "完成"
        case .failed: return "失败"
        }
    }
}

struct CompositionRenderQueueJob: Identifiable {
    let id: UUID
    var title: String
    var outputURL: URL
    var settings: CompositionExportSettings
    var layers: [CompositionLayer]
    var cameraClips: [CompositionCameraClip]
    var fallbackCamera: CameraRigState
    var precompositions: [UUID: CompositionDocumentState]
    var assetIDs: [UUID]
    var status: CompositionRenderQueueJobStatus
    var progress: Double
    var route: String
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var errorMessage: String?
    var logURL: URL?
    var logLines: [String]
}

struct CompositionRenderQueueLogDocument: Codable {
    var jobID: UUID
    var title: String
    var status: String
    var outputPath: String
    var logCreatedAt: Date
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var durationSeconds: Double?
    var progress: Double
    var route: String
    var errorMessage: String?
    var settings: CompositionExportSettings
    var compositionName: String
    var layerCount: Int
    var cameraCount: Int
    var assetIDs: [UUID]
    var assetSummaries: [AssetSummary]
    var performance: PerformanceSummary
    var logLines: [String]

    struct AssetSummary: Codable {
        var id: UUID
        var name: String
        var path: String
        var width: Int
        var height: Int
        var frameCount: Int
        var bitDepth: Int
        var hasAlpha: Bool
        var rawCacheReady: Bool
    }

    struct PerformanceSummary: Codable {
        var previewFPS: Double
        var textureHitRate: Double
        var rawCacheHitRate: Double
        var estimatedTextureMemoryBytes: Int64
        var appMemoryBytes: UInt64
        var memoryPressureText: String
    }
}

struct CompositionDiagnosticEvent: Identifiable, Codable {
    let id: UUID
    var date: Date
    var severity: String
    var category: String
    var message: String
    var details: String?
    var callStack: [String]
}

struct CompositionDiagnosticsDocument: Codable {
    var generatedAt: Date
    var appName: String
    var appVersion: String
    var buildVersion: String
    var projectSummary: ProjectSummary
    var assets: [AssetSummary]
    var cache: [CacheSummary]
    var exportSettings: CompositionExportSettings
    var renderQueue: [RenderQueueSummary]
    var recentErrors: [CompositionDiagnosticEvent]
    var performance: PerformanceSummary
    var environment: EnvironmentSummary
    var projectSnapshot: ChronoVolumeProjectDocument.CompositionProjectState

    struct ProjectSummary: Codable {
        var projectFilePath: String?
        var status: String
        var activeCompositionName: String
        var isEditingRootComposition: Bool
        var width: Int
        var height: Int
        var frameCount: Int
        var fps: Double
        var currentFrame: Int
        var assetCount: Int
        var videoAssetCount: Int
        var precompositionCount: Int
        var layerCount: Int
        var cameraClipCount: Int
        var layerKeyframeCount: Int
        var cameraKeyframeCount: Int
        var selectedLayerIDs: [UUID]
        var selectedCameraClipID: UUID?
        var renderQueueSummary: String
    }

    struct AssetSummary: Codable {
        var id: UUID
        var kind: String
        var name: String
        var path: String
        var fileExists: Bool
        var sourceFileMissing: Bool
        var sourceWidth: Int
        var sourceHeight: Int
        var sourceFrameCount: Int
        var sourceFPS: Double
        var sourceBitDepth: Int
        var alphaStatus: String
        var proxyStatus: String
        var rawCacheStatus: String
        var rawCacheSizeBytes: Int64
        var rawCacheSizeText: String
        var exportCacheState: String
        var exportCacheMessage: String
    }

    struct CacheSummary: Codable {
        var assetID: UUID
        var name: String
        var path: String
        var sourceText: String
        var sourceMissing: Bool
        var proxyStatusText: String
        var proxyDetailText: String
        var proxyNeedsBuild: Bool
        var proxyIsExpired: Bool
        var highPrecisionStatusText: String
        var highPrecisionDetailText: String
        var highPrecisionNeedsBuild: Bool
        var highPrecisionIsExpired: Bool
        var requiredHighPrecisionAlpha: Bool
        var cacheSizeBytes: Int64
        var cacheSizeText: String
    }

    struct RenderQueueSummary: Codable {
        var id: UUID
        var title: String
        var outputPath: String
        var settings: CompositionExportSettings
        var status: String
        var progress: Double
        var route: String
        var createdAt: Date
        var startedAt: Date?
        var completedAt: Date?
        var errorMessage: String?
        var logPath: String?
        var logLines: [String]
    }

    struct PerformanceSummary: Codable {
        var previewFPS: Double
        var previewPathText: String
        var sourcePathText: String
        var drawableText: String
        var activeLayerCount: Int
        var textureHitCount: Int
        var textureMissCount: Int
        var textureHitRate: Double
        var rawCacheHitCount: Int
        var rawCacheMissCount: Int
        var rawCacheHitRate: Double
        var estimatedTextureMemoryBytes: Int64
        var appMemoryBytes: UInt64
        var appMemoryText: String
        var physicalMemoryBytes: UInt64
        var physicalMemoryText: String
        var memoryPressureText: String
        var memoryPressureLevel: Double
        var updatedAt: Date
    }

    struct EnvironmentSummary: Codable {
        var operatingSystemVersion: String
        var hostName: String
        var processorCount: Int
        var activeProcessorCount: Int
        var physicalMemoryBytes: UInt64
        var physicalMemoryText: String
    }
}

enum CompositionLayerBlendMode: String, CaseIterable, Identifiable, Codable {
    case normal
    case add
    case screen
    case multiply
    case alphaTrackMatte

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:
            return "正常"
        case .add:
            return "相加"
        case .screen:
            return "屏幕"
        case .multiply:
            return "正片叠底"
        case .alphaTrackMatte:
            return "遮罩/轨道遮罩"
        }
    }

    var helpText: String {
        switch self {
        case .normal:
            return "按 Alpha 正常叠加到下方内容。"
        case .add:
            return "把颜色加到下方内容，适合光效、发光素材。"
        case .screen:
            return "变亮型混合，常用于叠光、烟雾、光斑。"
        case .multiply:
            return "变暗型混合，常用于阴影或纹理压暗。"
        case .alphaTrackMatte:
            return "当前层不显示颜色，只用 Alpha 裁切时间线上紧挨着它下方的图层。"
        }
    }
}

enum CompositionLayerVolumeRenderMode: String, CaseIterable, Identifiable, Codable {
    case alphaVolume
    case pixelVolume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphaVolume:
            return "Alpha体"
        case .pixelVolume:
            return "像素体"
        }
    }
}

struct CompositionPropertyExpression: Equatable, Codable {
    var isEnabled: Bool
    var source: String

    init(isEnabled: Bool = false, source: String = "") {
        self.isEnabled = isEnabled
        self.source = source
    }

    var isActive: Bool {
        isEnabled && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CompositionLayer: Identifiable, Equatable, Codable {
    let id: UUID
    var assetID: UUID
    var name: String
    var startFrame: Int
    var duration: Int
    var isVisible: Bool
    var isLocked: Bool
    var isSolo: Bool
    var blendMode: CompositionLayerBlendMode
    var volumeRenderMode: CompositionLayerVolumeRenderMode
    var transform: VolumeTransformState
    var opacity: Float
    var modifiers: [MeshModifierItem]
    var keyframes: [CompositionLayerKeyframe]
    var expressions: [String: CompositionPropertyExpression]

    private enum CodingKeys: String, CodingKey {
        case id
        case assetID
        case name
        case startFrame
        case duration
        case isVisible
        case isLocked
        case isSolo
        case blendMode
        case volumeRenderMode
        case transform
        case opacity
        case modifiers
        case keyframes
        case expressions
    }

    init(
        id: UUID = UUID(),
        assetID: UUID,
        name: String,
        startFrame: Int,
        duration: Int,
        isVisible: Bool = true,
        isLocked: Bool = false,
        isSolo: Bool = false,
        blendMode: CompositionLayerBlendMode = .normal,
        volumeRenderMode: CompositionLayerVolumeRenderMode = .alphaVolume,
        transform: VolumeTransformState = VolumeTransformState(),
        opacity: Float = 1,
        modifiers: [MeshModifierItem] = [],
        keyframes: [CompositionLayerKeyframe] = [],
        expressions: [String: CompositionPropertyExpression] = [:]
    ) {
        self.id = id
        self.assetID = assetID
        self.name = name
        self.startFrame = startFrame
        self.duration = duration
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.isSolo = isSolo
        self.blendMode = blendMode
        self.volumeRenderMode = volumeRenderMode
        self.transform = transform
        self.opacity = opacity
        self.modifiers = modifiers
        self.keyframes = Self.migratedScaleKeyframes(keyframes)
        self.expressions = Self.migratedScaleExpressions(expressions)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        assetID = try container.decode(UUID.self, forKey: .assetID)
        name = try container.decode(String.self, forKey: .name)
        startFrame = try container.decode(Int.self, forKey: .startFrame)
        duration = try container.decode(Int.self, forKey: .duration)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isSolo = try container.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false
        blendMode = try container.decodeIfPresent(CompositionLayerBlendMode.self, forKey: .blendMode) ?? .normal
        volumeRenderMode = try container.decodeIfPresent(CompositionLayerVolumeRenderMode.self, forKey: .volumeRenderMode) ?? .alphaVolume
        transform = try container.decodeIfPresent(VolumeTransformState.self, forKey: .transform) ?? VolumeTransformState()
        opacity = try container.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        modifiers = try container.decodeIfPresent([MeshModifierItem].self, forKey: .modifiers) ?? []
        let decodedKeyframes = try container.decodeIfPresent([CompositionLayerKeyframe].self, forKey: .keyframes) ?? []
        keyframes = Self.migratedScaleKeyframes(decodedKeyframes)
        let decodedExpressions = try container.decodeIfPresent([String: CompositionPropertyExpression].self, forKey: .expressions) ?? [:]
        expressions = Self.migratedScaleExpressions(decodedExpressions)
    }

    private static func migratedScaleKeyframes(
        _ keyframes: [CompositionLayerKeyframe]
    ) -> [CompositionLayerKeyframe] {
        var migrated = keyframes.filter { $0.property != .scale }
        var existingAxisKeys = Set(migrated.map { "\($0.property.rawValue)-\($0.frame)" })
        for keyframe in keyframes where keyframe.property == .scale {
            for property in [CompositionLayerKeyframeProperty.scaleX, .scaleY, .scaleZ] {
                let key = "\(property.rawValue)-\(keyframe.frame)"
                guard !existingAxisKeys.contains(key) else { continue }
                existingAxisKeys.insert(key)
                migrated.append(
                    CompositionLayerKeyframe(
                        frame: keyframe.frame,
                        property: property,
                        value: keyframe.value,
                        interpolation: keyframe.interpolation,
                        bezierCurve: keyframe.bezierCurve
                    )
                )
            }
        }
        return migrated.sorted { lhs, rhs in
            lhs.frame == rhs.frame
                ? lhs.property.rawValue < rhs.property.rawValue
                : lhs.frame < rhs.frame
        }
    }

    private static func migratedScaleExpressions(
        _ expressions: [String: CompositionPropertyExpression]
    ) -> [String: CompositionPropertyExpression] {
        guard let scaleExpression = expressions[CompositionLayerKeyframeProperty.scale.rawValue] else {
            return expressions
        }
        var migrated = expressions
        for property in [CompositionLayerKeyframeProperty.scaleX, .scaleY, .scaleZ]
        where migrated[property.rawValue] == nil {
            migrated[property.rawValue] = scaleExpression
        }
        migrated.removeValue(forKey: CompositionLayerKeyframeProperty.scale.rawValue)
        return migrated
    }
}

struct CompositionCameraClip: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var startFrame: Int
    var duration: Int
    var isVisible: Bool
    var camera: CameraRigState
    var keyframes: [CompositionCameraKeyframe]
    var expressions: [String: CompositionPropertyExpression]

    init(
        id: UUID = UUID(),
        name: String = "摄像机",
        startFrame: Int,
        duration: Int,
        isVisible: Bool = true,
        camera: CameraRigState = CameraRigState(positionZ: 3.0),
        keyframes: [CompositionCameraKeyframe] = [],
        expressions: [String: CompositionPropertyExpression] = [:]
    ) {
        self.id = id
        self.name = name
        self.startFrame = startFrame
        self.duration = duration
        self.isVisible = isVisible
        self.camera = camera
        self.keyframes = keyframes
        self.expressions = expressions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case startFrame
        case duration
        case isVisible
        case camera
        case keyframes
        case expressions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        startFrame = try container.decode(Int.self, forKey: .startFrame)
        duration = try container.decode(Int.self, forKey: .duration)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        camera = try container.decode(CameraRigState.self, forKey: .camera)
        keyframes = try container.decodeIfPresent([CompositionCameraKeyframe].self, forKey: .keyframes) ?? []
        expressions = try container.decodeIfPresent([String: CompositionPropertyExpression].self, forKey: .expressions) ?? [:]
    }
}

enum CompositionLayerKeyframeProperty: String, CaseIterable, Identifiable, Hashable, Codable {
    case positionX
    case positionY
    case positionZ
    case rotationX
    case rotationY
    case rotationZ
    case scale
    case scaleX
    case scaleY
    case scaleZ
    case opacity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .positionX: return "位置X"
        case .positionY: return "位置Y"
        case .positionZ: return "位置Z"
        case .rotationX: return "旋转X"
        case .rotationY: return "旋转Y"
        case .rotationZ: return "旋转Z"
        case .scale: return "缩放"
        case .scaleX: return "缩放X"
        case .scaleY: return "缩放Y"
        case .scaleZ: return "缩放T"
        case .opacity: return "不透明度"
        }
    }

    var isScaleAxis: Bool {
        switch self {
        case .scaleX, .scaleY, .scaleZ:
            return true
        default:
            return false
        }
    }
}

enum CompositionKeyframeInterpolation: String, CaseIterable, Identifiable, Codable, Sendable {
    case linear
    case easeInOut
    case hold
    case bezier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: return "线性"
        case .easeInOut: return "缓入缓出"
        case .hold: return "保持"
        case .bezier: return "贝塞尔"
        }
    }

    var explanation: String {
        switch self {
        case .linear:
            return "以固定速度从当前关键帧过渡到下一个关键帧。"
        case .easeInOut:
            return "开始和结束更慢，中间更快，适合更自然的运动。"
        case .hold:
            return "一直保持当前关键帧的值，到下一个关键帧时瞬间跳变。适合硬切、闪现、开关类动画。"
        case .bezier:
            return "用控制点自定义速度曲线，可以做更细的加速、减速和过冲感。"
        }
    }
}

struct CompositionBezierCurve: Equatable, Hashable, Codable, Sendable {
    var controlPoint1X: Float
    var controlPoint1Y: Float
    var controlPoint2X: Float
    var controlPoint2Y: Float

    static let `default` = CompositionBezierCurve(
        controlPoint1X: 0.25,
        controlPoint1Y: 0,
        controlPoint2X: 0.75,
        controlPoint2Y: 1
    )
}

struct CompositionLayerKeyframe: Identifiable, Equatable, Codable {
    var id: String { "\(property.rawValue)-\(frame)" }
    var frame: Int
    var property: CompositionLayerKeyframeProperty
    var value: Float
    var interpolation: CompositionKeyframeInterpolation
    var bezierCurve: CompositionBezierCurve

    private enum CodingKeys: String, CodingKey {
        case frame
        case property
        case value
        case interpolation
        case bezierCurve
    }

    init(
        frame: Int,
        property: CompositionLayerKeyframeProperty,
        value: Float,
        interpolation: CompositionKeyframeInterpolation = .linear,
        bezierCurve: CompositionBezierCurve = .default
    ) {
        self.frame = frame
        self.property = property
        self.value = value
        self.interpolation = interpolation
        self.bezierCurve = bezierCurve
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frame = try container.decode(Int.self, forKey: .frame)
        property = try container.decode(CompositionLayerKeyframeProperty.self, forKey: .property)
        value = try container.decode(Float.self, forKey: .value)
        interpolation = try container.decodeIfPresent(CompositionKeyframeInterpolation.self, forKey: .interpolation) ?? .linear
        bezierCurve = try container.decodeIfPresent(CompositionBezierCurve.self, forKey: .bezierCurve) ?? .default
    }

    func moved(to frame: Int) -> CompositionLayerKeyframe {
        var copy = self
        copy.frame = frame
        return copy
    }
}

enum CompositionCameraKeyframeProperty: String, CaseIterable, Identifiable, Hashable, Codable {
    case yaw
    case pitch
    case roll
    case positionX
    case positionY
    case positionZ
    case focusTargetX
    case focusTargetY
    case focusTargetZ
    case focalLength
    case aperture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yaw: return "Yaw 偏航"
        case .pitch: return "Pitch 俯仰"
        case .roll: return "Roll 翻滚"
        case .positionX: return "位置X"
        case .positionY: return "位置Y"
        case .positionZ: return "位置Z"
        case .focusTargetX: return "焦点X"
        case .focusTargetY: return "焦点Y"
        case .focusTargetZ: return "焦点Z"
        case .focalLength: return "焦段"
        case .aperture: return "光圈"
        }
    }
}

struct CompositionCameraKeyframe: Identifiable, Equatable, Codable {
    var id: String { "\(property.rawValue)-\(frame)" }
    var frame: Int
    var property: CompositionCameraKeyframeProperty
    var value: Float
    var interpolation: CompositionKeyframeInterpolation
    var bezierCurve: CompositionBezierCurve

    private enum CodingKeys: String, CodingKey {
        case frame
        case property
        case value
        case interpolation
        case bezierCurve
    }

    init(
        frame: Int,
        property: CompositionCameraKeyframeProperty,
        value: Float,
        interpolation: CompositionKeyframeInterpolation = .linear,
        bezierCurve: CompositionBezierCurve = .default
    ) {
        self.frame = frame
        self.property = property
        self.value = value
        self.interpolation = interpolation
        self.bezierCurve = bezierCurve
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frame = try container.decode(Int.self, forKey: .frame)
        property = try container.decode(CompositionCameraKeyframeProperty.self, forKey: .property)
        value = try container.decode(Float.self, forKey: .value)
        interpolation = try container.decodeIfPresent(CompositionKeyframeInterpolation.self, forKey: .interpolation) ?? .linear
        bezierCurve = try container.decodeIfPresent(CompositionBezierCurve.self, forKey: .bezierCurve) ?? .default
    }

    func moved(to frame: Int) -> CompositionCameraKeyframe {
        var copy = self
        copy.frame = frame
        return copy
    }
}

struct CompositionTimelineMarker: Identifiable, Equatable, Codable {
    let id: UUID
    var frame: Int
    var name: String

    init(id: UUID = UUID(), frame: Int, name: String) {
        self.id = id
        self.frame = frame
        self.name = name
    }
}

struct CompositionLayerKeyframeSelection: Hashable {
    var layerID: UUID
    var property: CompositionLayerKeyframeProperty
    var frame: Int
}

struct CompositionCameraKeyframeSelection: Hashable {
    var property: CompositionCameraKeyframeProperty
    var frame: Int
}

private struct CompositionKeyframeDragSnapshot {
    struct CameraItem {
        var property: CompositionCameraKeyframeProperty
        var frame: Int
        var value: Float
        var interpolation: CompositionKeyframeInterpolation
        var bezierCurve: CompositionBezierCurve
    }

    struct LayerItem {
        var layerID: UUID
        var property: CompositionLayerKeyframeProperty
        var frame: Int
        var value: Float
        var interpolation: CompositionKeyframeInterpolation
        var bezierCurve: CompositionBezierCurve
    }

    var cameraClipID: UUID?
    var cameraKeyframes: [CompositionCameraKeyframe]
    var layerKeyframesByLayerID: [UUID: [CompositionLayerKeyframe]]
    var cameraItems: [CameraItem]
    var layerItems: [LayerItem]
    var undoSnapshot: CompositionUndoSnapshot
}

private enum CompositionLayerStackOperation {
    case top
    case up
    case down
    case bottom
}

struct CompositionDocumentState: Equatable, Codable {
    var name: String = "未命名合成"
    var width: Int = 1920
    var height: Int = 1080
    var frameCount: Int = 300
    var fps: Double = 30
    var backgroundColor = VolumeBackgroundColor(red: 0, green: 0, blue: 0)
    var backgroundTransparent: Bool = true
    var layers: [CompositionLayer] = []
    var cameraClips: [CompositionCameraClip] = [
        CompositionCameraClip(name: "摄像机 1", startFrame: 0, duration: 300)
    ]
    var markers: [CompositionTimelineMarker] = []

    private enum CodingKeys: String, CodingKey {
        case name
        case width
        case height
        case frameCount
        case fps
        case backgroundColor
        case backgroundTransparent
        case layers
        case cameraClips
        case markers
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名合成"
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        frameCount = try container.decodeIfPresent(Int.self, forKey: .frameCount) ?? 300
        fps = try container.decodeIfPresent(Double.self, forKey: .fps) ?? 30
        backgroundColor = try container.decodeIfPresent(VolumeBackgroundColor.self, forKey: .backgroundColor)
            ?? VolumeBackgroundColor(red: 0, green: 0, blue: 0)
        backgroundTransparent = try container.decodeIfPresent(Bool.self, forKey: .backgroundTransparent) ?? true
        layers = try container.decodeIfPresent([CompositionLayer].self, forKey: .layers) ?? []
        cameraClips = try container.decodeIfPresent([CompositionCameraClip].self, forKey: .cameraClips)
            ?? [CompositionCameraClip(name: "摄像机 1", startFrame: 0, duration: frameCount)]
        markers = try container.decodeIfPresent([CompositionTimelineMarker].self, forKey: .markers) ?? []
    }
}

struct CompositionRenderLayer {
    let id: UUID
    let assetID: UUID
    let textureID: UUID
    let modifiers: [MeshModifierItem]
    let transform: VolumeTransformState
    let transformMatrix: simd_float4x4
    let blendMode: CompositionLayerBlendMode
    let volumeRenderMode: CompositionLayerVolumeRenderMode
    let opacity: Float
    let trackMatteAssetID: UUID?
    let trackMatteTextureID: UUID?
    let trackMatteModifiers: [MeshModifierItem]
    let trackMatteTransform: VolumeTransformState?
    let trackMatteTransformMatrix: simd_float4x4?
    let trackMatteOpacity: Float
}

enum CompositionExportSourceMode: String, CaseIterable, Identifiable, Codable {
    case highPrecision
    case proxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highPrecision:
            return "高精度 raw cache"
        case .proxy:
            return "代理预览"
        }
    }
}

enum CompositionPreviewQuality: String, CaseIterable, Identifiable, Codable {
    case draft
    case half
    case full
    case highPrecision
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draft: return "草稿"
        case .half: return "半分辨率"
        case .full: return "全分辨率"
        case .highPrecision: return "高精度"
        case .automatic: return "自动"
        }
    }

    var detailText: String {
        switch self {
        case .draft:
            return "低 drawable + 少步数，适合拖动和播放。"
        case .half:
            return "半分辨率 drawable，保留较好的交互手感。"
        case .full:
            return "完整 drawable 和标准步数。"
        case .highPrecision:
            return "完整 drawable + 更高采样步数，用于暂停检查细节。"
        case .automatic:
            return "播放时用草稿，暂停时用高精度。"
        }
    }

    func resolved(isPlaying: Bool) -> CompositionPreviewQuality {
        guard self == .automatic else { return self }
        return isPlaying ? .draft : .highPrecision
    }

    func drawableScale(isPlaying: Bool) -> Double {
        switch resolved(isPlaying: isPlaying) {
        case .draft: return 0.35
        case .half: return 0.5
        case .full: return 1
        case .highPrecision: return 1
        case .automatic: return 1
        }
    }

    func rayStepCount(isPlaying: Bool) -> Int {
        switch resolved(isPlaying: isPlaying) {
        case .draft: return 56
        case .half: return 104
        case .full: return 192
        case .highPrecision: return 320
        case .automatic: return 192
        }
    }
}

enum CompositionExportBackgroundMode: String, CaseIterable, Identifiable, Codable {
    case composition
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .composition:
            return "跟随合成"
        case .custom:
            return "自定义"
        }
    }
}

enum CompositionExportRangeMode: String, CaseIterable, Identifiable, Codable {
    case full
    case currentToEnd
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full:
            return "完整合成"
        case .currentToEnd:
            return "当前帧到结束"
        case .custom:
            return "自定义"
        }
    }
}

struct CompositionExportSettings: Equatable, Codable {
    var width: Int = 1920
    var height: Int = 1080
    var fps: Double = 30
    var bitDepth: ExportBitDepth = .source
    var colorProfile: ExportColorProfile = .source
    var preserveAlpha: Bool = false
    var backgroundMode: CompositionExportBackgroundMode = .composition
    var backgroundColor = VolumeBackgroundColor(red: 0, green: 0, blue: 0)
    var sourceMode: CompositionExportSourceMode = .highPrecision
    var rangeMode: CompositionExportRangeMode = .full
    var startFrame: Int = 0
    var endFrame: Int = 299

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case fps
        case bitDepth
        case colorProfile
        case preserveAlpha
        case backgroundMode
        case backgroundColor
        case sourceMode
        case rangeMode
        case startFrame
        case endFrame
    }

    init(
        width: Int = 1920,
        height: Int = 1080,
        fps: Double = 30,
        bitDepth: ExportBitDepth = .source,
        colorProfile: ExportColorProfile = .source,
        preserveAlpha: Bool = false,
        backgroundMode: CompositionExportBackgroundMode = .composition,
        backgroundColor: VolumeBackgroundColor = VolumeBackgroundColor(red: 0, green: 0, blue: 0),
        sourceMode: CompositionExportSourceMode = .highPrecision,
        rangeMode: CompositionExportRangeMode = .full,
        startFrame: Int = 0,
        endFrame: Int = 299
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitDepth = bitDepth
        self.colorProfile = colorProfile
        self.preserveAlpha = preserveAlpha
        self.backgroundMode = backgroundMode
        self.backgroundColor = backgroundColor
        self.sourceMode = sourceMode
        self.rangeMode = rangeMode
        self.startFrame = startFrame
        self.endFrame = endFrame
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        fps = try container.decodeIfPresent(Double.self, forKey: .fps) ?? 30
        bitDepth = try container.decodeIfPresent(ExportBitDepth.self, forKey: .bitDepth) ?? .source
        colorProfile = try container.decodeIfPresent(ExportColorProfile.self, forKey: .colorProfile) ?? .source
        preserveAlpha = try container.decodeIfPresent(Bool.self, forKey: .preserveAlpha) ?? false
        backgroundMode = try container.decodeIfPresent(CompositionExportBackgroundMode.self, forKey: .backgroundMode) ?? .composition
        backgroundColor = try container.decodeIfPresent(VolumeBackgroundColor.self, forKey: .backgroundColor)
            ?? VolumeBackgroundColor(red: 0, green: 0, blue: 0)
        sourceMode = try container.decodeIfPresent(CompositionExportSourceMode.self, forKey: .sourceMode) ?? .highPrecision
        rangeMode = try container.decodeIfPresent(CompositionExportRangeMode.self, forKey: .rangeMode) ?? .full
        startFrame = try container.decodeIfPresent(Int.self, forKey: .startFrame) ?? 0
        endFrame = try container.decodeIfPresent(Int.self, forKey: .endFrame) ?? 299
    }
}

struct CompositionWorkspaceLayoutState: Equatable, Codable {
    var projectSidebarWidth: Double = 390
    var previewHeightRatio: Double = 0.52
    var timelineHeaderWidth: Double = 320
    var timelineZoom: Double = 1
    var previewQuality: CompositionPreviewQuality = .automatic
    var curveEditorZoom: Double = 1
    var curveEditorPanX: Double = 0
    var curveEditorPanY: Double = 0
    var normalizeCurveValues: Bool = true
    var snapCurveHandles: Bool = true
    var showDetachedInspector: Bool = false
    var detachedInspectorWidth: Double = 360
    var timelineLayerSearchText: String = ""
    var timelineFilterVisibleOnly: Bool = false
    var timelineFilterLockedOnly: Bool = false
    var timelineFilterKeyframedOnly: Bool = false

    private enum CodingKeys: String, CodingKey {
        case projectSidebarWidth
        case previewHeightRatio
        case timelineHeaderWidth
        case timelineZoom
        case previewQuality
        case curveEditorZoom
        case curveEditorPanX
        case curveEditorPanY
        case normalizeCurveValues
        case snapCurveHandles
        case showDetachedInspector
        case detachedInspectorWidth
        case timelineLayerSearchText
        case timelineFilterVisibleOnly
        case timelineFilterLockedOnly
        case timelineFilterKeyframedOnly
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectSidebarWidth = try container.decodeIfPresent(Double.self, forKey: .projectSidebarWidth) ?? 390
        previewHeightRatio = try container.decodeIfPresent(Double.self, forKey: .previewHeightRatio) ?? 0.52
        timelineHeaderWidth = try container.decodeIfPresent(Double.self, forKey: .timelineHeaderWidth) ?? 320
        timelineZoom = try container.decodeIfPresent(Double.self, forKey: .timelineZoom) ?? 1
        previewQuality = try container.decodeIfPresent(CompositionPreviewQuality.self, forKey: .previewQuality) ?? .automatic
        curveEditorZoom = try container.decodeIfPresent(Double.self, forKey: .curveEditorZoom) ?? 1
        curveEditorPanX = try container.decodeIfPresent(Double.self, forKey: .curveEditorPanX) ?? 0
        curveEditorPanY = try container.decodeIfPresent(Double.self, forKey: .curveEditorPanY) ?? 0
        normalizeCurveValues = try container.decodeIfPresent(Bool.self, forKey: .normalizeCurveValues) ?? true
        snapCurveHandles = try container.decodeIfPresent(Bool.self, forKey: .snapCurveHandles) ?? true
        showDetachedInspector = try container.decodeIfPresent(Bool.self, forKey: .showDetachedInspector) ?? false
        detachedInspectorWidth = try container.decodeIfPresent(Double.self, forKey: .detachedInspectorWidth) ?? 360
        timelineLayerSearchText = try container.decodeIfPresent(String.self, forKey: .timelineLayerSearchText) ?? ""
        timelineFilterVisibleOnly = try container.decodeIfPresent(Bool.self, forKey: .timelineFilterVisibleOnly) ?? false
        timelineFilterLockedOnly = try container.decodeIfPresent(Bool.self, forKey: .timelineFilterLockedOnly) ?? false
        timelineFilterKeyframedOnly = try container.decodeIfPresent(Bool.self, forKey: .timelineFilterKeyframedOnly) ?? false
    }
}

private struct CompositionUndoSnapshot {
    var composition: CompositionDocumentState
    var compositionCamera: CameraRigState
    var currentFrame: Int
    var precompositionAssets: [CompositionAsset]
}

private enum CompositionClipboardPayload {
    case layers([CompositionLayer])
    case layerKeyframes([(layerID: UUID, keyframes: [CompositionLayerKeyframe])])
    case cameraClips([CompositionCameraClip])
    case cameraKeyframes([CompositionCameraKeyframe])
}

private struct CompositionEasingClipboard {
    var interpolation: CompositionKeyframeInterpolation
    var bezierCurve: CompositionBezierCurve
}

@MainActor
final class CompositionModel: ObservableObject {
    static let rootCompositionAssetID = UUID(uuidString: "00000000-0000-0000-0000-00000000c001")!

    @Published var assets: [CompositionAsset] = []
    @Published private(set) var rootComposition = CompositionDocumentState()
    @Published private(set) var activeCompositionAssetID: UUID?
    @Published var composition = CompositionDocumentState()
    @Published var compositionCamera = CompositionModel.defaultCompositionCamera()
    @Published var compositionCameraKeyframes: [CompositionCameraKeyframe] = []
    @Published var newCompositionDraft = CompositionDocumentState()
    @Published var isShowingNewCompositionSheet = false
    @Published var isShowingCompositionSettingsSheet = false
    @Published var isShowingCompositionExportSettingsSheet = false
    @Published var isShowingMediaManagerSheet = false
    @Published var isShowingCachePolicyCenterSheet = false
    @Published var isShowingPerformanceDiagnosticsSheet = false
    @Published var compositionExportSettings = CompositionExportSettings()
    @Published var currentFrame: Int = 0
    @Published var selectedLayerID: UUID?
    @Published var selectedLayerIDs: Set<UUID> = []
    @Published var selectedLayerModifierIDs: [UUID: UUID] = [:]
    @Published var selectedLayerKeyframes: Set<CompositionLayerKeyframeSelection> = []
    @Published var selectedCameraKeyframes: Set<CompositionCameraKeyframeSelection> = []
    @Published var selectedCameraClipID: UUID?
    @Published var expandedLayerIDs: Set<UUID> = []
    @Published var openedPrecompositionLayerIDs: Set<UUID> = []
    @Published var isCameraTrackExpanded = false
    @Published var isCompositionPlaying = false
    @Published var isCompositionExporting = false
    @Published var isTimelineSnappingEnabled = true
    @Published private(set) var isCompositionValueDragging = false
    @Published private(set) var performanceSnapshot = CompositionPerformanceSnapshot()
    @Published var compositionRenderQueue: [CompositionRenderQueueJob] = []
    @Published var isCompositionRenderQueuePaused = false
    @Published var isBuildingCachePolicyCaches = false
    @Published var status: String = "合成就绪"
    @Published var workspaceLayout = CompositionWorkspaceLayoutState()
    @Published var openCompositionTabIDs: [UUID] = [
        UUID(uuidString: "00000000-0000-0000-0000-00000000c001")!
    ]

    var onVideoPackageLoaded: ((URL, LoadedVideoPackage) -> Void)?
    var onMeshPackageLoaded: ((URL, LoadedMeshPackage) -> Void)?
    var projectFilePathForDiagnostics: String?
    private var latestRendererDiagnostics: CompositionRendererDiagnostics?
    private var recentDiagnosticEvents: [CompositionDiagnosticEvent] = []
    private var playbackTimer: Timer?
    private var keyframeDragSnapshot: CompositionKeyframeDragSnapshot?
    private var keyframeDragCurrentCameraSelections: Set<CompositionCameraKeyframeSelection> = []
    private var keyframeDragCurrentLayerSelections: Set<CompositionLayerKeyframeSelection> = []
    private var keyframeDragDidMove = false
    private var keyframeDragLastResolvedDelta = 0
    private var undoStack: [CompositionUndoSnapshot] = []
    private var redoStack: [CompositionUndoSnapshot] = []
    private var clipboardPayload: CompositionClipboardPayload?
    private var easingClipboard: CompositionEasingClipboard?
    private var isRestoringHistory = false
    private var isCoalescingValueDrag = false
    private var didRecordValueDragUndo = false

    var selectedKeyframeCount: Int {
        selectedCameraKeyframes.count + selectedLayerKeyframes.count
    }

    var isEditingRootComposition: Bool {
        activeCompositionAssetID == nil
    }

    var activeCompositionTabID: UUID {
        activeCompositionAssetID ?? Self.rootCompositionAssetID
    }

    var activeCompositionName: String {
        composition.name
    }

    var precompositionAssets: [CompositionAsset] {
        assets.filter(\.isPrecomposition)
    }

    var videoAssets: [CompositionAsset] {
        assets.filter(\.isVideo)
    }

    var meshAssets: [CompositionAsset] {
        assets.filter(\.isMesh)
    }

    var mediaAssets: [CompositionAsset] {
        assets.filter(\.isFileBackedMedia)
    }

    var mediaManagerItems: [CompositionMediaManagerItem] {
        mediaAssets.map { mediaManagerItem(for: $0) }
    }

    var mediaManagerTotalCacheSizeBytes: Int64 {
        mediaManagerItems.reduce(Int64(0)) { $0 + $1.rawCacheSizeBytes }
    }

    var mediaManagerTotalCacheSizeText: String {
        byteCountText(mediaManagerTotalCacheSizeBytes)
    }

    var effectiveCompositionPreviewQuality: CompositionPreviewQuality {
        workspaceLayout.previewQuality.resolved(isPlaying: isCompositionPlaying)
    }

    var compositionPreviewQualityStatusText: String {
        let requested = workspaceLayout.previewQuality
        let effective = effectiveCompositionPreviewQuality
        if requested == .automatic {
            return "预览质量：自动 → \(effective.title)"
        }
        return "预览质量：\(effective.title)"
    }

    var cachePolicyItems: [CompositionCachePolicyItem] {
        videoAssets.map { cachePolicyItem(for: $0) }
    }

    var cachePolicyTotalSizeBytes: Int64 {
        cachePolicyItems.reduce(Int64(0)) { $0 + $1.cacheSizeBytes }
    }

    var cachePolicyTotalSizeText: String {
        byteCountText(cachePolicyTotalSizeBytes)
    }

    var cachePolicyNeedsWorkCount: Int {
        cachePolicyItems.filter { $0.proxyNeedsBuild || $0.highPrecisionNeedsBuild }.count
    }

    var canAddRootCompositionToActive: Bool {
        canAddCompositionReference(Self.rootCompositionAssetID)
    }

    var isCompositionRenderQueueRunning: Bool {
        compositionRenderQueue.contains { $0.status == .running }
    }

    var compositionRenderQueueSummaryText: String {
        let queued = compositionRenderQueue.filter { $0.status == .queued }.count
        let running = compositionRenderQueue.filter { $0.status == .running }.count
        let completed = compositionRenderQueue.filter { $0.status == .completed }.count
        let failed = compositionRenderQueue.filter { $0.status == .failed }.count
        return "等待 \(queued)｜运行 \(running)｜完成 \(completed)｜失败 \(failed)"
    }

    deinit {
        playbackTimer?.invalidate()
    }

    static func defaultCompositionCamera() -> CameraRigState {
        var camera = CameraRigState()
        camera.positionZ = 3.0
        return camera
    }

    private func makeHistorySnapshot() -> CompositionUndoSnapshot {
        CompositionUndoSnapshot(
            composition: composition,
            compositionCamera: compositionCamera,
            currentFrame: currentFrame,
            precompositionAssets: assets.filter(\.isPrecomposition)
        )
    }

    private func recordUndo() {
        recordUndo(snapshot: makeHistorySnapshot())
    }

    private func recordUndo(snapshot: CompositionUndoSnapshot) {
        guard !isRestoringHistory else { return }
        undoStack.append(snapshot)
        if undoStack.count > 80 {
            undoStack.removeFirst(undoStack.count - 80)
        }
        redoStack.removeAll()
    }

    private func recordUndoForPropertyEdit() {
        if isCoalescingValueDrag {
            guard !didRecordValueDragUndo else { return }
            didRecordValueDragUndo = true
        }
        recordUndo()
    }

    private func syncActiveCompositionIntoStorage() {
        sanitize(document: &composition)
        if let activeCompositionAssetID,
           let index = assets.firstIndex(where: { $0.id == activeCompositionAssetID }) {
            assets[index].name = composition.name
            assets[index].sourceWidth = composition.width
            assets[index].sourceHeight = composition.height
            assets[index].sourceFrameCount = composition.frameCount
            assets[index].sourceFPS = composition.fps
            assets[index].sourceBitDepth = sourceBitDepthForPrecomposition(composition)
            assets[index].precomposition = composition
            assets[index].exportCacheState = .ready
            assets[index].exportCacheMessage = "预合成：无需单独缓存"
        } else {
            rootComposition = composition
        }
    }

    func commitActiveCompositionChanges() {
        syncActiveCompositionIntoStorage()
    }

    private func resetCompositionEditorState(keepCurrentFrame: Bool = false) {
        stopPlayback()
        selectedLayerID = nil
        selectedLayerIDs = []
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        selectedCameraClipID = nil
        expandedLayerIDs = []
        openedPrecompositionLayerIDs = []
        isCameraTrackExpanded = false
        if !keepCurrentFrame {
            currentFrame = 0
        }
        undoStack.removeAll()
        redoStack.removeAll()
        clipboardPayload = nil
        recentDiagnosticEvents.removeAll()
        resetKeyframeDragState()
    }

    private func compositionDocument(forReferenceID id: UUID) -> CompositionDocumentState? {
        if id == Self.rootCompositionAssetID {
            return activeCompositionAssetID == nil ? composition : rootComposition
        }
        if activeCompositionAssetID == id {
            return composition
        }
        return assets.first(where: { $0.id == id })?.precomposition
    }

    private func currentCompositionReferenceID() -> UUID {
        activeCompositionAssetID ?? Self.rootCompositionAssetID
    }

    private func normalizeCompositionTabIDs(_ ids: [UUID], activeID: UUID?) -> [UUID] {
        var result: [UUID] = []
        func append(_ id: UUID) {
            guard !result.contains(id) else { return }
            if id == Self.rootCompositionAssetID ||
                assets.contains(where: { $0.id == id && $0.isPrecomposition }) {
                result.append(id)
            }
        }

        append(Self.rootCompositionAssetID)
        ids.forEach(append)
        append(activeID ?? Self.rootCompositionAssetID)
        return result
    }

    private func ensureCompositionTabOpen(_ id: UUID) {
        openCompositionTabIDs = normalizeCompositionTabIDs(openCompositionTabIDs + [id], activeID: id)
    }

    func compositionTabTitle(for id: UUID) -> String {
        if id == Self.rootCompositionAssetID {
            return activeCompositionAssetID == nil ? composition.name : rootComposition.name
        }
        if activeCompositionAssetID == id {
            return composition.name
        }
        return assets.first(where: { $0.id == id })?.name ?? "预合成"
    }

    func compositionTabDetail(for id: UUID) -> String {
        let document: CompositionDocumentState?
        if id == Self.rootCompositionAssetID {
            document = activeCompositionAssetID == nil ? composition : rootComposition
        } else if activeCompositionAssetID == id {
            document = composition
        } else {
            document = assets.first(where: { $0.id == id })?.precomposition
        }
        guard let document else { return "-" }
        return "\(document.width) × \(document.height) × \(document.frameCount)"
    }

    func openCompositionTab(id: UUID) {
        if id == Self.rootCompositionAssetID {
            openRootComposition()
        } else {
            openPrecompositionAsset(id: id)
        }
    }

    func closeCompositionTab(id: UUID) {
        guard id != Self.rootCompositionAssetID else {
            status = "主合成标签不能关闭"
            return
        }
        let wasActive = activeCompositionAssetID == id
        openCompositionTabIDs.removeAll { $0 == id }
        let nextID = openCompositionTabIDs.last ?? Self.rootCompositionAssetID
        openCompositionTabIDs = normalizeCompositionTabIDs(
            openCompositionTabIDs,
            activeID: wasActive ? nextID : activeCompositionAssetID
        )
        if wasActive {
            let nextID = openCompositionTabIDs.last ?? Self.rootCompositionAssetID
            openCompositionTab(id: nextID)
        }
    }

    private func compositionReferenceContains(
        sourceID: UUID,
        targetID: UUID,
        seen: Set<UUID>
    ) -> Bool {
        guard !seen.contains(sourceID),
              let document = compositionDocument(forReferenceID: sourceID) else {
            return false
        }

        var nextSeen = seen
        nextSeen.insert(sourceID)
        for layer in document.layers {
            let childID = layer.assetID
            if childID == targetID {
                return true
            }
            if childID == Self.rootCompositionAssetID || assets.first(where: { $0.id == childID })?.isPrecomposition == true {
                if compositionReferenceContains(sourceID: childID, targetID: targetID, seen: nextSeen) {
                    return true
                }
            }
        }
        return false
    }

    private func canAddCompositionReference(_ sourceID: UUID) -> Bool {
        let targetID = currentCompositionReferenceID()
        guard sourceID != targetID else { return false }
        return !compositionReferenceContains(sourceID: sourceID, targetID: targetID, seen: [])
    }

    private func activateComposition(_ nextComposition: CompositionDocumentState, assetID: UUID?) {
        var document = nextComposition
        sanitize(document: &document)
        composition = document
        activeCompositionAssetID = assetID
        ensureCompositionTabOpen(assetID ?? Self.rootCompositionAssetID)
        currentFrame = max(0, min(currentFrame, composition.frameCount - 1))
        ensureCameraClips()
        selectedCameraClipID = activeCameraClip(at: currentFrame)?.id ?? composition.cameraClips.first?.id
        compositionCamera = selectedCameraClip()?.camera ?? composition.cameraClips.first?.camera ?? Self.defaultCompositionCamera()
        compositionCameraKeyframes = selectedCameraClip()?.keyframes ?? []
        resetCompositionExportSettingsToComposition()
        syncEditableCameraFromSelection()
    }

    private func restoreHistorySnapshot(_ snapshot: CompositionUndoSnapshot) {
        isRestoringHistory = true
        composition = snapshot.composition
        compositionCamera = snapshot.compositionCamera
        currentFrame = max(0, min(snapshot.currentFrame, composition.frameCount - 1))
        assets.removeAll(where: \.isPrecomposition)
        assets.append(contentsOf: snapshot.precompositionAssets)
        ensureCameraClips()
        if let selectedLayerID,
           !composition.layers.contains(where: { $0.id == selectedLayerID }) {
            self.selectedLayerID = nil
            selectedLayerIDs = []
        }
        openedPrecompositionLayerIDs = openedPrecompositionLayerIDs.intersection(Set(composition.layers.map(\.id)))
        if let selectedCameraClipID,
           !composition.cameraClips.contains(where: { $0.id == selectedCameraClipID }) {
            self.selectedCameraClipID = activeCameraClip(at: currentFrame)?.id ?? composition.cameraClips.first?.id
        }
        isRestoringHistory = false
    }

    func undoCompositionEdit() {
        guard let snapshot = undoStack.popLast() else {
            status = "没有可撤销的操作"
            return
        }
        redoStack.append(makeHistorySnapshot())
        restoreHistorySnapshot(snapshot)
        applyInterpolatedPropertiesToEditableState()
        status = "已撤销"
    }

    func redoCompositionEdit() {
        guard let snapshot = redoStack.popLast() else {
            status = "没有可重做的操作"
            return
        }
        undoStack.append(makeHistorySnapshot())
        restoreHistorySnapshot(snapshot)
        applyInterpolatedPropertiesToEditableState()
        status = "已重做"
    }

    func updateCompositionCamera(
        syncFocusOrientation: Bool = true,
        _ update: (inout CameraRigState) -> Void
    ) {
        update(&compositionCamera)
        if syncFocusOrientation {
            syncCompositionCameraFocusOrientation()
        }
        if let index = selectedCameraClipIndex() {
            composition.cameraClips[index].camera = compositionCamera
        }
    }

    func setCompositionCameraFocusLock(_ enabled: Bool) {
        guard let index = selectedCameraClipIndex() else { return }
        guard compositionCamera.focusLockEnabled != enabled else { return }
        recordUndo()
        compositionCamera.focusLockEnabled = enabled
        if enabled {
            syncCompositionCameraFocusOrientation()
        }
        composition.cameraClips[index].camera = compositionCamera
        status = enabled ? "摄像机焦点锁定已开启" : "摄像机焦点锁定已关闭"
    }

    func resetSelectedCompositionCamera() {
        guard let index = selectedCameraClipIndex() else { return }
        recordUndo()
        compositionCamera = Self.defaultCompositionCamera()
        composition.cameraClips[index].camera = compositionCamera
        let animatedProperties = Set(composition.cameraClips[index].keyframes.map(\.property))
        for property in animatedProperties {
            upsertCompositionCameraKeyframe(property, recordHistory: false)
        }
        status = "已复位摄像机"
    }

    func syncCompositionCameraFocusOrientation() {
        guard compositionCamera.focusLockEnabled else { return }
        guard let orientation = AppModel.cameraYawPitchForFocus(
            position: SIMD3<Float>(
                compositionCamera.positionX,
                compositionCamera.positionY,
                compositionCamera.positionZ
            ),
            target: SIMD3<Float>(
                compositionCamera.focusTargetX,
                compositionCamera.focusTargetY,
                compositionCamera.focusTargetZ
            )
        ) else { return }

        compositionCamera.yaw = orientation.yaw
        compositionCamera.pitch = orientation.pitch
    }

    func setCurrentFrame(_ frame: Int) {
        currentFrame = max(0, min(frame, composition.frameCount - 1))
        applyInterpolatedPropertiesToEditableState()
    }

    func nearestKeyframeFrame(to frame: Int, tolerance: Int = 4) -> Int? {
        let allFrames = Set(
            composition.cameraClips.flatMap { $0.keyframes.map(\.frame) } +
            composition.layers.flatMap { $0.keyframes.map(\.frame) }
        )
        guard let nearest = allFrames.min(by: { abs($0 - frame) < abs($1 - frame) }) else {
            return nil
        }
        return abs(nearest - frame) <= tolerance ? nearest : nil
    }

    func nearestTimelineSnapFrame(to frame: Int, tolerance: Int = 4) -> Int? {
        var frames = Set<Int>()
        frames.formUnion(composition.markers.map(\.frame))
        frames.formUnion(composition.cameraClips.flatMap { [$0.startFrame, $0.startFrame + $0.duration] })
        frames.formUnion(composition.layers.flatMap { [$0.startFrame, $0.startFrame + $0.duration] })
        frames.formUnion(composition.cameraClips.flatMap { $0.keyframes.map(\.frame) })
        frames.formUnion(composition.layers.flatMap { $0.keyframes.map(\.frame) })
        frames.insert(0)
        frames.insert(max(0, composition.frameCount - 1))

        guard let nearest = frames.min(by: { abs($0 - frame) < abs($1 - frame) }) else {
            return nil
        }
        return abs(nearest - frame) <= tolerance ? nearest : nil
    }

    func snappedTimelineFrame(_ frame: Int, tolerance: Int = 4, force: Bool = false) -> Int {
        let clamped = max(0, min(max(0, composition.frameCount - 1), frame))
        guard force || isTimelineSnappingEnabled else { return clamped }
        return nearestTimelineSnapFrame(to: clamped, tolerance: tolerance) ?? clamped
    }

    func beginNewComposition() {
        newCompositionDraft = CompositionDocumentState()
        isShowingNewCompositionSheet = true
    }

    func confirmNewComposition() {
        sanitize(document: &newCompositionDraft)
        syncActiveCompositionIntoStorage()
        let assetID = UUID()
        appendPrecompositionAsset(
            id: assetID,
            name: newCompositionDraft.name,
            composition: newCompositionDraft
        )
        resetCompositionEditorState()
        activateComposition(newCompositionDraft, assetID: assetID)
        isShowingNewCompositionSheet = false
        status = "已新建并打开合成：\(composition.name)"
    }

    func cancelNewComposition() {
        isShowingNewCompositionSheet = false
    }

    func newComposition() {
        beginNewComposition()
    }

    func importVideos(urls: [URL]) {
        importAssets(urls: urls)
    }

    func importAssets(urls: [URL]) {
        guard !urls.isEmpty else { return }

        var videoCount = 0
        var meshCount = 0
        for url in urls {
            if MeshVolumeLoader.isSupportedModelURL(url) {
                appendMeshAssetAndLoad(id: UUID(), url: url, name: url.lastPathComponent)
                meshCount += 1
            } else {
                appendAssetAndLoad(
                    id: UUID(),
                    url: url,
                    name: url.lastPathComponent,
                    sourceWidth: 0,
                    sourceHeight: 0,
                    sourceFrameCount: 0,
                    sourceFPS: 0,
                    sourceBitDepth: 8,
                    sourceColorProfile: .rec709
                )
                videoCount += 1
            }
        }

        if meshCount > 0, videoCount > 0 {
            status = "正在导入 \(videoCount) 个视频和 \(meshCount) 个模型…"
        } else if meshCount > 0 {
            status = "正在导入 \(meshCount) 个 3D 模型…"
        } else {
            status = "正在导入 \(videoCount) 个视频…"
        }
    }

    func refreshExportCacheStates() {
        for index in assets.indices {
            refreshExportCacheState(at: index)
        }
        status = "已刷新合成导出缓存状态"
    }

    func checkCompositionAssetFiles() {
        guard !assets.isEmpty else {
            status = "没有合成素材可检查"
            return
        }

        var missingNames: [String] = []
        for index in assets.indices {
            guard assets[index].isFileBackedMedia else {
                assets[index].sourceFileMissing = false
                continue
            }
            let exists = FileManager.default.fileExists(atPath: assets[index].url.path)
            assets[index].sourceFileMissing = !exists
            if exists {
                if assets[index].status == "源文件丢失" || assets[index].status.hasPrefix("文件不存在") {
                    assets[index].status = assets[index].previewVolume == nil ? "等待导入" : "已导入"
                }
            } else {
                missingNames.append(assets[index].name)
                if assets[index].previewVolume == nil {
                    assets[index].status = "源文件丢失"
                }
            }
        }

        if missingNames.isEmpty {
            status = "素材检查完成：没有丢失文件"
        } else {
            let shown = missingNames.prefix(3).joined(separator: "、")
            let suffix = missingNames.count > 3 ? " 等 \(missingNames.count) 个" : ""
            status = "素材检查：丢失 \(shown)\(suffix)"
        }
    }

    func relinkCompositionAssetInteractively(id: UUID) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else {
            status = "没有找到要重新链接的素材"
            return
        }

        let panel = NSOpenPanel()
        panel.title = "查找脱机素材"
        panel.prompt = "重新链接"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = importableAssetContentTypes()
        panel.directoryURL = assets[index].url.deletingLastPathComponent()
        panel.nameFieldStringValue = assets[index].name

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "已取消重新链接素材"
            return
        }

        relinkAsset(at: index, to: url, updateName: true)
        status = "已重新链接素材：\(assets[index].name)"
    }

    func findOfflineCompositionAssetsInteractively() {
        checkCompositionAssetFiles()
        let missingIndices = assets.indices.filter { assets[$0].isFileBackedMedia && assets[$0].sourceFileMissing }
        guard !missingIndices.isEmpty else {
            status = "没有需要查找的脱机素材"
            return
        }

        let panel = NSOpenPanel()
        panel.title = "选择脱机素材所在文件夹"
        panel.prompt = "查找"
        panel.message = "会按文件名在此文件夹及其子文件夹中查找丢失的素材。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else {
            status = "已取消查找脱机素材"
            return
        }

        let candidates = offlineAssetCandidates(in: folderURL)
        var relinkedCount = 0
        var stillMissingNames: [String] = []

        for index in missingIndices {
            let keys = offlineLookupKeys(for: assets[index])
            guard let match = keys.compactMap({ candidates[$0] }).first else {
                stillMissingNames.append(assets[index].name)
                continue
            }
            relinkAsset(at: index, to: match, updateName: false)
            relinkedCount += 1
        }

        if stillMissingNames.isEmpty {
            status = "已找回 \(relinkedCount) 个脱机素材，正在重新导入代理…"
        } else {
            let shown = stillMissingNames.prefix(3).joined(separator: "、")
            let suffix = stillMissingNames.count > 3 ? " 等 \(stillMissingNames.count) 个" : ""
            status = "已找回 \(relinkedCount) 个素材；仍缺少 \(shown)\(suffix)"
        }
    }

    func prepareCompositionExportCachesInteractively() {
        guard !isCompositionExporting else { return }
        let ids = exportPreparationAssetIDs()
        guard !ids.isEmpty else {
            status = "没有可预渲染的合成素材"
            return
        }

        Task {
            do {
                try await ensureHighPrecisionDiskCaches(assetIDs: ids)
                status = "合成导出缓存已就绪"
            } catch {
                recordDiagnosticEvent(
                    severity: "error",
                    category: "缓存",
                    message: "合成导出缓存建立失败",
                    details: error.localizedDescription,
                    includeCallStack: true
                )
                status = "合成导出缓存建立失败：\(error.localizedDescription)"
            }
        }
    }

    func rebuildMeshVolumeCacheInteractively(id: UUID) {
        guard let index = assets.firstIndex(where: { $0.id == id && $0.isMesh }) else {
            status = "没有找到要重建的模型素材"
            return
        }
        guard FileManager.default.fileExists(atPath: assets[index].url.path) else {
            assets[index].sourceFileMissing = true
            assets[index].status = "源文件丢失"
            assets[index].exportCacheState = .failed
            assets[index].exportCacheMessage = "模型代理：源文件不存在"
            status = "模型源文件丢失"
            return
        }

        let url = assets[index].url
        assets[index].status = "正在建立高精度模型体…"
        assets[index].exportCacheState = .building
        assets[index].exportCacheMessage = "模型代理：正在高精度体素化"
        status = "正在建立模型高精度体：\(assets[index].name)"
        loadMeshAssetPreview(
            id: id,
            url: url,
            maxResolution: 256,
            finishedStatus: "高精度模型体已建立"
        )
    }

    func removeCompositionExportCachesInteractively() {
        let ids = exportPreparationAssetIDs(includeAllAssetsWhenNoLayers: true)
        guard !ids.isEmpty else {
            status = "没有可清理的合成素材缓存"
            return
        }

        for id in ids {
            guard let asset = assets.first(where: { $0.id == id && $0.isVideo }) else { continue }
            HighPrecisionCacheHelper.removeCache(for: asset.url)
            setExportCacheState(
                assetID: id,
                state: asset.previewVolume == nil ? .unknown : .missing,
                message: asset.previewVolume == nil ? "导出缓存：等待代理导入" : "导出缓存：未建立"
            )
        }
        status = "已清理合成导出缓存"
    }

    func openMediaManager() {
        checkCompositionAssetFiles()
        refreshExportCacheStates()
        isShowingMediaManagerSheet = true
    }

    func refreshMediaManager() {
        checkCompositionAssetFiles()
        refreshExportCacheStates()
    }

    func clearMediaManagerCache(assetID: UUID) {
        guard let asset = assets.first(where: { $0.id == assetID && $0.isVideo }) else {
            status = "没有找到要清理缓存的素材"
            return
        }

        HighPrecisionCacheHelper.removeCache(for: asset.url)
        if let index = assets.firstIndex(where: { $0.id == assetID }) {
            refreshExportCacheState(at: index)
        }
        status = "已清理 \(asset.name) 的 raw cache"
    }

    func clearAllMediaManagerCaches() {
        let videos = videoAssets
        guard !videos.isEmpty else {
            status = "没有可清理缓存的视频素材"
            return
        }

        for asset in videos {
            HighPrecisionCacheHelper.removeCache(for: asset.url)
            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                refreshExportCacheState(at: index)
            }
        }
        status = "已清理 \(videos.count) 个素材的 raw cache"
    }

    func openCachePolicyCenter() {
        refreshCachePolicyCenter()
        isShowingCachePolicyCenterSheet = true
    }

    func refreshCachePolicyCenter() {
        checkCompositionAssetFiles()
        refreshExportCacheStates()
        status = "已刷新缓存策略中心"
    }

    func prebuildProjectCachesFromPolicy(includeProxy: Bool, includeHighPrecision: Bool) {
        startCachePolicyPrebuild(
            assetIDs: videoAssets.map(\.id),
            title: "项目",
            includeProxy: includeProxy,
            includeHighPrecision: includeHighPrecision
        )
    }

    func prebuildCurrentCompositionCachesFromPolicy(includeProxy: Bool, includeHighPrecision: Bool) {
        let ids = exportPreparationAssetIDs(includeAllAssetsWhenNoLayers: false)
        startCachePolicyPrebuild(
            assetIDs: ids,
            title: "当前合成",
            includeProxy: includeProxy,
            includeHighPrecision: includeHighPrecision
        )
    }

    func prebuildAssetCachesFromPolicy(assetID: UUID, includeProxy: Bool, includeHighPrecision: Bool) {
        let title = assets.first(where: { $0.id == assetID })?.name ?? "素材"
        startCachePolicyPrebuild(
            assetIDs: [assetID],
            title: title,
            includeProxy: includeProxy,
            includeHighPrecision: includeHighPrecision
        )
    }

    func clearProjectCachesFromPolicy() {
        clearCachesFromPolicy(assetIDs: videoAssets.map(\.id), title: "项目")
    }

    func clearCurrentCompositionCachesFromPolicy() {
        let ids = exportPreparationAssetIDs(includeAllAssetsWhenNoLayers: false)
        clearCachesFromPolicy(assetIDs: ids, title: "当前合成")
    }

    func clearAssetCachesFromPolicy(assetID: UUID) {
        let title = assets.first(where: { $0.id == assetID })?.name ?? "素材"
        clearCachesFromPolicy(assetIDs: [assetID], title: title)
    }

    private func startCachePolicyPrebuild(
        assetIDs: [UUID],
        title: String,
        includeProxy: Bool,
        includeHighPrecision: Bool
    ) {
        guard includeProxy || includeHighPrecision else {
            status = "请选择要预构建的缓存类型"
            return
        }
        guard !isBuildingCachePolicyCaches else {
            status = "缓存策略中心已有后台预构建任务"
            return
        }

        let ids = assetIDs.filter { id in
            assets.contains { $0.id == id && $0.isVideo }
        }
        guard !ids.isEmpty else {
            status = "\(title) 没有可预构建的素材"
            return
        }

        isBuildingCachePolicyCaches = true
        status = "正在后台预构建\(title)缓存…"

        Task {
            do {
                var builtProxyCount = 0
                var builtHighPrecisionCount = 0

                for id in ids {
                    guard let asset = assets.first(where: { $0.id == id && $0.isVideo }) else { continue }
                    if includeProxy, proxyCacheInspection(for: asset).needsBuild {
                        try await rebuildProxyCacheForAsset(assetID: id)
                        builtProxyCount += 1
                    }

                    guard let refreshedAsset = assets.first(where: { $0.id == id && $0.isVideo }) else { continue }
                    if includeHighPrecision, highPrecisionCacheInspection(for: refreshedAsset).needsBuild {
                        try await ensureHighPrecisionDiskCaches(assetIDs: [id])
                        builtHighPrecisionCount += 1
                    }
                }

                isBuildingCachePolicyCaches = false
                refreshExportCacheStates()
                status = "缓存预构建完成：代理 \(builtProxyCount) 个，高精度 \(builtHighPrecisionCount) 个"
            } catch {
                isBuildingCachePolicyCaches = false
                refreshExportCacheStates()
                recordDiagnosticEvent(
                    severity: "error",
                    category: "缓存",
                    message: "缓存预构建失败",
                    details: error.localizedDescription,
                    includeCallStack: true
                )
                status = "缓存预构建失败：\(error.localizedDescription)"
            }
        }
    }

    private func clearCachesFromPolicy(assetIDs: [UUID], title: String) {
        let ids = assetIDs.filter { id in
            assets.contains { $0.id == id && $0.isVideo }
        }
        guard !ids.isEmpty else {
            status = "\(title) 没有可清理的缓存"
            return
        }

        for id in ids {
            guard let index = assets.firstIndex(where: { $0.id == id && $0.isVideo }) else { continue }
            HighPrecisionCacheHelper.removeCache(for: assets[index].url)
            assets[index].previewVolume = nil
            assets[index].proxyCacheBuiltAt = nil
            if assets[index].sourceFileMissing || !FileManager.default.fileExists(atPath: assets[index].url.path) {
                assets[index].sourceFileMissing = true
                assets[index].status = "源文件丢失"
                assets[index].exportCacheState = .failed
                assets[index].exportCacheMessage = "导出缓存：源文件不存在"
            } else {
                assets[index].status = "代理缓存未建立"
                assets[index].exportCacheState = .unknown
                assets[index].exportCacheMessage = "导出缓存：等待代理导入"
            }
        }

        status = "已清理\(title)缓存：\(ids.count) 个素材"
    }

    func openPerformanceDiagnostics() {
        refreshPerformanceDiagnostics()
        isShowingPerformanceDiagnosticsSheet = true
    }

    func refreshPerformanceDiagnostics() {
        performanceSnapshot = makePerformanceSnapshot()
    }

    func updateCompositionRendererDiagnostics(_ diagnostics: CompositionRendererDiagnostics) {
        latestRendererDiagnostics = diagnostics
        refreshPerformanceDiagnostics()
    }

    func updateCompositionModifierPreviewStatus(_ refreshStatus: CompositionModifiedTextureRefreshStatus) {
        if refreshStatus.isPending {
            let nextStatus = refreshStatus.pendingCount == 1
                ? "正在生成图层修改器预览…"
                : "正在生成 \(refreshStatus.pendingCount) 个图层修改器预览…"
            if status != nextStatus {
                status = nextStatus
            }
        } else if status.hasPrefix("正在生成图层修改器预览") ||
                    (status.hasPrefix("正在生成 ") && status.contains("个图层修改器预览")) {
            status = "图层修改器预览已更新"
        }
    }

    func generateDiagnosticsPackageInteractively() {
        refreshPerformanceDiagnostics()

        let panel = NSSavePanel()
        panel.title = "保存诊断包"
        panel.prompt = "生成诊断包"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(Self.safeDiagnosticsFileStem(activeCompositionName))_diagnostics_\(Self.queueLogFileTimestamp()).cvdiagnostics"

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "已取消生成诊断包"
            return
        }

        do {
            let packageURL = try writeDiagnosticsPackage(to: url)
            status = "诊断包已生成：\(packageURL.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([packageURL])
        } catch {
            recordDiagnosticEvent(
                severity: "error",
                category: "诊断包",
                message: "生成诊断包失败",
                details: error.localizedDescription,
                includeCallStack: true
            )
            status = "诊断包生成失败：\(error.localizedDescription)"
        }
    }

    func enqueueCurrentCompositionExportInteractively() {
        syncActiveCompositionIntoStorage()
        guard composition.layers.contains(where: { $0.isVisible && (!composition.layers.contains(where: \.isSolo) || $0.isSolo) }) else {
            status = "没有可见图层可加入渲染队列"
            return
        }

        clampCompositionExportSettings()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(composition.name)_composition.mov"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            status = "已取消加入渲染队列"
            return
        }

        isShowingCompositionExportSettingsSheet = false
        enqueueCompositionExport(url: url, settings: compositionExportSettings)
    }

    func pauseCompositionRenderQueue() {
        isCompositionRenderQueuePaused = true
        status = isCompositionRenderQueueRunning
            ? "渲染队列已暂停，当前任务完成后停止"
            : "渲染队列已暂停"
    }

    func resumeCompositionRenderQueue() {
        isCompositionRenderQueuePaused = false
        status = "渲染队列继续"
        runCompositionRenderQueueIfNeeded()
    }

    func retryCompositionRenderQueueJob(id: UUID) {
        guard let index = compositionRenderQueue.firstIndex(where: { $0.id == id }) else { return }
        guard compositionRenderQueue[index].status == .failed || compositionRenderQueue[index].status == .completed else { return }
        compositionRenderQueue[index].status = .queued
        compositionRenderQueue[index].progress = 0
        compositionRenderQueue[index].route = "等待重试"
        compositionRenderQueue[index].startedAt = nil
        compositionRenderQueue[index].completedAt = nil
        compositionRenderQueue[index].errorMessage = nil
        compositionRenderQueue[index].logURL = nil
        appendRenderQueueLog(jobID: id, "已重新加入队列")
        runCompositionRenderQueueIfNeeded()
    }

    func removeCompositionRenderQueueJob(id: UUID) {
        guard let index = compositionRenderQueue.firstIndex(where: { $0.id == id }) else { return }
        guard compositionRenderQueue[index].status != .running else {
            status = "正在渲染的任务不能移除"
            return
        }
        compositionRenderQueue.remove(at: index)
    }

    func clearFinishedCompositionRenderQueueJobs() {
        compositionRenderQueue.removeAll { $0.status == .completed || $0.status == .failed }
    }

    private func relinkAsset(at index: Int, to url: URL, updateName: Bool) {
        guard assets.indices.contains(index) else { return }
        guard assets[index].isFileBackedMedia else {
            status = "预合成素材不需要重新链接"
            return
        }
        let isMesh = MeshVolumeLoader.isSupportedModelURL(url)
        let assetID = assets[index].id
        let oldName = assets[index].name
        let newName = updateName ? url.lastPathComponent : oldName

        assets[index].url = url
        assets[index].name = newName
        assets[index].kind = isMesh ? .mesh : .video
        assets[index].status = isMesh ? "正在导入模型…" : "正在重新导入…"
        assets[index].sourceFileMissing = false
        assets[index].previewVolume = nil
        assets[index].proxyCacheBuiltAt = nil
        assets[index].exportCacheState = .unknown
        assets[index].exportCacheMessage = isMesh ? "模型代理：等待体素化" : "导出缓存：等待代理导入"

        if updateName, oldName != newName {
            for layerIndex in composition.layers.indices
            where composition.layers[layerIndex].assetID == assetID
                && composition.layers[layerIndex].name == oldName {
                composition.layers[layerIndex].name = newName
            }
        }

        if isMesh {
            loadMeshAssetPreview(id: assetID, url: url)
        } else {
            loadAssetPreview(id: assetID, url: url)
        }
    }

    private func offlineAssetCandidates(in folderURL: URL) -> [String: URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: options
        ) else {
            return [:]
        }

        var candidates: [String: URL] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  isSupportedImportAssetURL(url) else {
                continue
            }
            let key = normalizedAssetLookupKey(url.lastPathComponent)
            candidates[key] = candidates[key] ?? url
        }
        return candidates
    }

    private func offlineLookupKeys(for asset: CompositionAsset) -> [String] {
        Array(
            Set([
                normalizedAssetLookupKey(asset.name),
                normalizedAssetLookupKey(asset.url.lastPathComponent)
            ])
        )
    }

    private func normalizedAssetLookupKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isSupportedMovieURL(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .movie) {
            return true
        }
        return ["mov", "mp4", "m4v", "avi", "mkv"].contains(url.pathExtension.lowercased())
    }

    private func isSupportedImportAssetURL(_ url: URL) -> Bool {
        isSupportedMovieURL(url) || MeshVolumeLoader.isSupportedModelURL(url)
    }

    private func importableAssetContentTypes() -> [UTType] {
        var types: [UTType] = [.movie]
        for ext in MeshVolumeLoader.supportedFileExtensions.sorted() {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    private func nextPrecompositionName() -> String {
        let existing = Set(assets.map(\.name) + composition.layers.map(\.name))
        var index = 1
        while existing.contains("预合成 \(index)") {
            index += 1
        }
        return "预合成 \(index)"
    }

    func makeProjectState() -> ChronoVolumeProjectDocument.CompositionProjectState {
        syncActiveCompositionIntoStorage()
        return ChronoVolumeProjectDocument.CompositionProjectState(
            assets: assets.map {
                ChronoVolumeProjectDocument.CompositionAssetRecord(
                    id: $0.id,
                    kind: $0.kind,
                    path: $0.url.path,
                    name: $0.name,
                    sourceWidth: $0.sourceWidth,
                    sourceHeight: $0.sourceHeight,
                    sourceFrameCount: $0.sourceFrameCount,
                    sourceFPS: $0.sourceFPS,
                    sourceBitDepth: $0.sourceBitDepth,
                    sourceColorProfile: $0.sourceColorProfile,
                    precomposition: $0.precomposition
                )
            },
            composition: rootComposition,
            compositionCamera: compositionCamera,
            currentFrame: currentFrame,
            activeCompositionAssetID: activeCompositionAssetID,
            selectedLayerID: selectedLayerID,
            selectedLayerIDs: Array(selectedLayerIDs),
            selectedCameraClipID: selectedCameraClipID,
            expandedLayerIDs: Array(expandedLayerIDs),
            isCameraTrackExpanded: isCameraTrackExpanded,
            isTimelineSnappingEnabled: isTimelineSnappingEnabled,
            exportSettings: compositionExportSettings,
            workspaceLayout: workspaceLayout,
            openCompositionTabIDs: openCompositionTabIDs
        )
    }

    func restoreProjectState(_ state: ChronoVolumeProjectDocument.CompositionProjectState) {
        stopPlayback()
        assets.removeAll()
        rootComposition = state.composition
        sanitize(document: &rootComposition)
        composition = rootComposition
        activeCompositionAssetID = nil
        compositionCamera = state.compositionCamera
        currentFrame = max(0, min(state.currentFrame, composition.frameCount - 1))
        selectedLayerID = state.selectedLayerID
        selectedLayerIDs = Set(state.selectedLayerIDs)
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        selectedCameraClipID = state.selectedCameraClipID
        expandedLayerIDs = Set(state.expandedLayerIDs)
        isCameraTrackExpanded = state.isCameraTrackExpanded
        isTimelineSnappingEnabled = state.isTimelineSnappingEnabled
        compositionExportSettings = state.exportSettings
        workspaceLayout = state.workspaceLayout
        clampCompositionExportSettings()
        isCompositionPlaying = false
        isCompositionExporting = false
        undoStack.removeAll()
        redoStack.removeAll()
        clipboardPayload = nil
        resetKeyframeDragState()
        ensureCameraClips()
        clampCompositionSettings()

        let validLayerIDs = Set(composition.layers.map(\.id))
        selectedLayerIDs = selectedLayerIDs.intersection(validLayerIDs)
        openedPrecompositionLayerIDs = openedPrecompositionLayerIDs.intersection(validLayerIDs)
        if let selectedLayerID, !validLayerIDs.contains(selectedLayerID) {
            self.selectedLayerID = selectedLayerIDs.first
        }
        let validCameraIDs = Set(composition.cameraClips.map(\.id))
        if let selectedCameraClipID, !validCameraIDs.contains(selectedCameraClipID) {
            self.selectedCameraClipID = activeCameraClip(at: currentFrame)?.id ?? composition.cameraClips.first?.id
        }
        syncEditableCameraFromSelection()

        for record in state.assets {
            switch record.kind {
            case .video:
                appendAssetAndLoad(
                    id: record.id,
                    url: record.url,
                    name: record.name,
                    sourceWidth: record.sourceWidth,
                    sourceHeight: record.sourceHeight,
                    sourceFrameCount: record.sourceFrameCount,
                    sourceFPS: record.sourceFPS,
                    sourceBitDepth: record.sourceBitDepth,
                    sourceColorProfile: record.sourceColorProfile
                )
            case .mesh:
                appendMeshAssetAndLoad(
                    id: record.id,
                    url: record.url,
                    name: record.name
                )
            case .precomposition:
                appendPrecompositionAsset(
                    id: record.id,
                    name: record.name,
                    composition: record.precomposition ?? CompositionDocumentState()
                )
            }
        }

        openCompositionTabIDs = normalizeCompositionTabIDs(
            state.openCompositionTabIDs,
            activeID: state.activeCompositionAssetID
        )

        if let activeID = state.activeCompositionAssetID,
           let asset = assets.first(where: { $0.id == activeID }),
           asset.isPrecomposition,
           let nested = asset.precomposition {
            composition = nested
            sanitize(document: &composition)
            activeCompositionAssetID = activeID
        }
        openCompositionTabIDs = normalizeCompositionTabIDs(openCompositionTabIDs, activeID: activeCompositionAssetID)

        ensureCameraClips()
        clampCompositionSettings()
        if activeCompositionAssetID == nil {
            rootComposition = composition
        }

        let currentValidLayerIDs = Set(composition.layers.map(\.id))
        selectedLayerIDs = selectedLayerIDs.intersection(currentValidLayerIDs)
        if let selectedLayerID, !currentValidLayerIDs.contains(selectedLayerID) {
            self.selectedLayerID = selectedLayerIDs.first
        }
        let currentValidCameraIDs = Set(composition.cameraClips.map(\.id))
        if let selectedCameraClipID, !currentValidCameraIDs.contains(selectedCameraClipID) {
            self.selectedCameraClipID = activeCameraClip(at: currentFrame)?.id ?? composition.cameraClips.first?.id
        }
        syncEditableCameraFromSelection()
        status = state.assets.isEmpty ? "项目已打开" : "正在恢复项目素材…"
    }

    func addLayer(assetID: UUID, at frame: Int? = nil) {
        if assetID == Self.rootCompositionAssetID {
            addRootCompositionLayer(at: frame)
            return
        }
        guard let asset = assets.first(where: { $0.id == assetID }), asset.isReady else { return }
        if asset.isPrecomposition && !canAddCompositionReference(asset.id) {
            status = "无法加入此合成：会形成循环引用"
            return
        }
        recordUndo()
        let start = frame ?? currentFrame
        let available = max(1, composition.frameCount - start)
        let sourceDuration = asset.isMesh
            ? max(1, composition.frameCount)
            : max(1, asset.previewVolume?.depth ?? asset.sourceFrameCount)
        let duration = max(1, min(available, sourceDuration))
        let layer = CompositionLayer(
            assetID: assetID,
            name: asset.name,
            startFrame: start,
            duration: duration
        )
        composition.layers.append(layer)
        selectedLayerID = layer.id
        selectedLayerIDs = [layer.id]
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        status = "已加入时间线：\(asset.name)"
    }

    func addRootCompositionLayer(at frame: Int? = nil) {
        syncActiveCompositionIntoStorage()
        guard canAddRootCompositionToActive else {
            status = "无法加入主合成：会形成循环引用"
            return
        }

        recordUndo()
        let start = frame ?? currentFrame
        let available = max(1, composition.frameCount - start)
        let sourceDuration = max(1, rootComposition.frameCount)
        let duration = max(1, min(available, sourceDuration))
        let layer = CompositionLayer(
            assetID: Self.rootCompositionAssetID,
            name: rootComposition.name,
            startFrame: start,
            duration: duration
        )
        composition.layers.append(layer)
        selectedLayerID = layer.id
        selectedLayerIDs = [layer.id]
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        status = "已加入时间线：\(rootComposition.name)"
    }

    func precomposeSelectedLayers() {
        var ids = selectedLayerIDs
        if ids.isEmpty, let selectedLayerID {
            ids = [selectedLayerID]
        }
        guard ids.count >= 2 else {
            status = "请选择至少两个图层进行预合成"
            return
        }

        let selectedIndices = composition.layers.indices.filter { ids.contains(composition.layers[$0].id) }
        guard selectedIndices.count >= 2 else {
            status = "请选择至少两个有效图层进行预合成"
            return
        }
        let locked = selectedIndices.filter { composition.layers[$0].isLocked }
        guard locked.isEmpty else {
            status = "选中图层包含锁定层，无法预合成"
            return
        }

        let selectedLayers = selectedIndices.map { composition.layers[$0] }
        let precompStart = selectedLayers.map(\.startFrame).min() ?? currentFrame
        let precompEnd = selectedLayers.map { $0.startFrame + $0.duration }.max() ?? (precompStart + 1)
        let precompDuration = max(1, precompEnd - precompStart)
        let precompName = nextPrecompositionName()

        var nested = CompositionDocumentState()
        nested.name = precompName
        nested.width = composition.width
        nested.height = composition.height
        nested.frameCount = precompDuration
        nested.fps = composition.fps
        nested.backgroundColor = composition.backgroundColor
        nested.backgroundTransparent = true
        nested.cameraClips = [
            CompositionCameraClip(name: "摄像机 1", startFrame: 0, duration: precompDuration)
        ]
        nested.layers = selectedLayers.map { layer in
            CompositionLayer(
                assetID: layer.assetID,
                name: layer.name,
                startFrame: layer.startFrame - precompStart,
                duration: layer.duration,
                isVisible: layer.isVisible,
                isLocked: false,
                isSolo: false,
                blendMode: layer.blendMode,
                volumeRenderMode: layer.volumeRenderMode,
                transform: layer.transform,
                opacity: layer.opacity,
                modifiers: layer.modifiers,
                keyframes: layer.keyframes.map { $0.moved(to: $0.frame - precompStart) },
                expressions: layer.expressions
            )
        }
        sanitize(document: &nested)

        recordUndo()
        let assetID = UUID()
        appendPrecompositionAsset(id: assetID, name: precompName, composition: nested)
        ensureCompositionTabOpen(assetID)

        let insertionIndex = selectedIndices.min() ?? 0
        composition.layers.removeAll { ids.contains($0.id) }
        let targetIndex = max(0, min(insertionIndex, composition.layers.count))
        let precompLayer = CompositionLayer(
            assetID: assetID,
            name: precompName,
            startFrame: precompStart,
            duration: precompDuration
        )
        composition.layers.insert(precompLayer, at: targetIndex)
        selectedLayerID = precompLayer.id
        selectedLayerIDs = [precompLayer.id]
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        selectedCameraClipID = nil
        expandedLayerIDs.subtract(ids)
        expandedLayerIDs.insert(precompLayer.id)
        status = "已预合成 \(selectedLayers.count) 个图层：\(precompName)"
    }

    func addLayer(assetIDString: String) {
        guard let id = UUID(uuidString: assetIDString) else { return }
        addLayer(assetID: id)
    }

    func deleteSelectedLayer() {
        if !selectedLayerIDs.isEmpty {
            deleteLayers(ids: selectedLayerIDs)
            return
        }
        guard let selectedLayerID else { return }
        deleteLayers(ids: [selectedLayerID])
    }

    func deleteCompositionTimelineSelection() {
        if !selectedCameraKeyframes.isEmpty || !selectedLayerKeyframes.isEmpty {
            deleteSelectedKeyframes()
            return
        }
        if let selectedCameraClipID {
            deleteCameraClip(id: selectedCameraClipID)
            return
        }
        deleteSelectedLayer()
    }

    func copyCompositionSelection() {
        if !selectedLayerKeyframes.isEmpty {
            let groups = Dictionary(grouping: selectedLayerKeyframes, by: \.layerID)
                .compactMap { layerID, selections -> (layerID: UUID, keyframes: [CompositionLayerKeyframe])? in
                    guard let layer = composition.layers.first(where: { $0.id == layerID }) else { return nil }
                    let keys = layer.keyframes.filter { keyframe in
                        selections.contains(
                            CompositionLayerKeyframeSelection(
                                layerID: layerID,
                                property: keyframe.property,
                                frame: keyframe.frame
                            )
                        )
                    }
                    return keys.isEmpty ? nil : (layerID, keys)
                }
            guard !groups.isEmpty else { return }
            clipboardPayload = .layerKeyframes(groups)
            status = "已复制 \(groups.reduce(0) { $0 + $1.keyframes.count }) 个图层关键帧"
            return
        }

        if !selectedCameraKeyframes.isEmpty,
           let clip = selectedCameraClip() {
            let keys = clip.keyframes.filter { keyframe in
                selectedCameraKeyframes.contains(
                    CompositionCameraKeyframeSelection(property: keyframe.property, frame: keyframe.frame)
                )
            }
            guard !keys.isEmpty else { return }
            clipboardPayload = .cameraKeyframes(keys)
            status = "已复制 \(keys.count) 个摄像机关键帧"
            return
        }

        if let selectedCameraClipID,
           let clip = composition.cameraClips.first(where: { $0.id == selectedCameraClipID }) {
            clipboardPayload = .cameraClips([clip])
            status = "已复制摄像机：\(clip.name)"
            return
        }

        var ids = selectedLayerIDs
        if ids.isEmpty, let selectedLayerID {
            ids = [selectedLayerID]
        }
        let layers = composition.layers.filter { ids.contains($0.id) }
        guard !layers.isEmpty else {
            status = "没有可复制的时间线内容"
            return
        }
        clipboardPayload = .layers(layers)
        status = "已复制 \(layers.count) 个图层"
    }

    func pasteCompositionClipboard() {
        guard let clipboardPayload else {
            status = "剪贴板为空"
            return
        }
        recordUndo()
        switch clipboardPayload {
        case .layers(let layers):
            pasteLayers(layers)
        case .layerKeyframes(let groups):
            pasteLayerKeyframes(groups)
        case .cameraClips(let clips):
            pasteCameraClips(clips)
        case .cameraKeyframes(let keyframes):
            pasteCameraKeyframes(keyframes)
        }
    }

    func selectOnlyLayer(_ id: UUID) {
        selectedLayerID = id
        selectedLayerIDs = [id]
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        selectedCameraClipID = nil
    }

    func toggleLayerSelection(_ id: UUID) {
        if selectedLayerIDs.contains(id) {
            selectedLayerIDs.remove(id)
            if selectedLayerID == id {
                selectedLayerID = selectedLayerIDs.first
            }
        } else {
            selectedLayerIDs.insert(id)
            selectedLayerID = id
        }
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        selectedCameraClipID = nil
        status = selectedLayerIDs.isEmpty ? "未选中图层" : "已选择 \(selectedLayerIDs.count) 个图层"
    }

    func selectLayerRange(to id: UUID) {
        let anchorID = selectedLayerID ?? selectedLayerIDs.first ?? id
        guard let anchorIndex = composition.layers.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = composition.layers.firstIndex(where: { $0.id == id }) else {
            selectOnlyLayer(id)
            return
        }

        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        selectedLayerIDs = Set(composition.layers[lower...upper].map(\.id))
        selectedLayerID = id
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        selectedCameraClipID = nil
        status = "已连选 \(selectedLayerIDs.count) 个图层"
    }

    func selectCameraClip(_ id: UUID) {
        selectedCameraClipID = id
        selectedLayerID = nil
        selectedLayerIDs = []
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        syncEditableCameraFromSelection()
    }

    func setBoxSelectedLayers(_ ids: Set<UUID>) {
        selectedLayerIDs = ids
        selectedLayerID = ids.first
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        selectedCameraClipID = nil
        status = ids.isEmpty ? "未选中图层" : "已框选 \(ids.count) 个图层"
    }

    func openRootComposition() {
        syncActiveCompositionIntoStorage()
        resetCompositionEditorState()
        activateComposition(rootComposition, assetID: nil)
        status = "已打开主合成：\(composition.name)"
    }

    func openPrecompositionAsset(id: UUID) {
        syncActiveCompositionIntoStorage()
        guard let asset = assets.first(where: { $0.id == id }),
              asset.isPrecomposition,
              let nested = asset.precomposition else {
            status = "找不到可打开的预合成"
            return
        }

        resetCompositionEditorState()
        activateComposition(nested, assetID: id)
        status = "已打开合成：\(composition.name)"
    }

    func openPrecompositionLayer(id layerID: UUID) {
        guard let layer = composition.layers.first(where: { $0.id == layerID }) else {
            status = "找不到图层"
            return
        }
        if layer.assetID == Self.rootCompositionAssetID {
            openRootComposition()
            return
        }
        openPrecompositionAsset(id: layer.assetID)
    }

    func openSelectedPrecomposition() {
        let orderedIDs = [selectedLayerID].compactMap { $0 } + selectedLayerIDs.filter { $0 != selectedLayerID }
        guard let layerID = orderedIDs.first(where: { precompositionContent(for: $0) != nil }) else {
            status = "请选择一个预合成图层"
            return
        }
        openPrecompositionLayer(id: layerID)
    }

    func precompositionContent(for layerID: UUID) -> CompositionDocumentState? {
        guard let layer = composition.layers.first(where: { $0.id == layerID }) else { return nil }
        if layer.assetID == Self.rootCompositionAssetID {
            return activeCompositionAssetID == nil ? composition : rootComposition
        }
        if activeCompositionAssetID == layer.assetID {
            return composition
        }
        return assets.first(where: { $0.id == layer.assetID })?.precomposition
    }

    func isPrecompositionLayer(_ layer: CompositionLayer) -> Bool {
        layer.assetID == Self.rootCompositionAssetID ||
            assets.first(where: { $0.id == layer.assetID })?.isPrecomposition == true
    }

    var selectedPrecompositionLayerIDs: Set<UUID> {
        selectedLayerIDs.filter { precompositionContent(for: $0) != nil }
    }

    func togglePrecompositionContent(layerID: UUID) {
        guard precompositionContent(for: layerID) != nil else {
            openedPrecompositionLayerIDs.remove(layerID)
            status = "此图层不是预合成"
            return
        }

        if openedPrecompositionLayerIDs.contains(layerID) {
            openedPrecompositionLayerIDs.remove(layerID)
            status = "已关闭预合成内容"
        } else {
            openedPrecompositionLayerIDs.insert(layerID)
            status = "已打开预合成内容"
        }
    }

    func toggleSelectedPrecompositionContents() {
        let ids = selectedPrecompositionLayerIDs
        guard !ids.isEmpty else {
            status = "请选择预合成图层"
            return
        }

        if ids.allSatisfy({ openedPrecompositionLayerIDs.contains($0) }) {
            openedPrecompositionLayerIDs.subtract(ids)
            status = "已关闭 \(ids.count) 个预合成内容"
        } else {
            openedPrecompositionLayerIDs.formUnion(ids)
            status = "已打开 \(ids.count) 个预合成内容"
        }
    }

    private func pasteLayers(_ layers: [CompositionLayer]) {
        guard let firstStart = layers.map(\.startFrame).min() else { return }
        let offset = currentFrame - firstStart
        var newIDs: Set<UUID> = []
        for layer in layers {
            let newID = UUID()
            var clone = layer
            clone = CompositionLayer(
                id: newID,
                assetID: layer.assetID,
                name: "\(layer.name) 副本",
                startFrame: layer.startFrame + offset,
                duration: layer.duration,
                isVisible: layer.isVisible,
                isLocked: layer.isLocked,
                isSolo: layer.isSolo,
                blendMode: layer.blendMode,
                volumeRenderMode: layer.volumeRenderMode,
                transform: layer.transform,
                opacity: layer.opacity,
                modifiers: layer.modifiers,
                keyframes: layer.keyframes.map {
                    $0.moved(to: $0.frame + offset)
                },
                expressions: layer.expressions
            )
            composition.layers.append(clone)
            newIDs.insert(newID)
        }
        selectedLayerIDs = newIDs
        selectedLayerID = newIDs.first
        selectedCameraClipID = nil
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        status = "已粘贴 \(newIDs.count) 个图层"
    }

    private func pasteLayerKeyframes(
        _ groups: [(layerID: UUID, keyframes: [CompositionLayerKeyframe])]
    ) {
        let allKeyframes = groups.flatMap(\.keyframes)
        guard let minFrame = allKeyframes.map(\.frame).min() else { return }
        let offset = currentFrame - minFrame
        let singleTarget = selectedLayerID
        var pasted = 0

        for group in groups {
            let targetID = groups.count == 1 ? (singleTarget ?? group.layerID) : group.layerID
            guard let layerIndex = composition.layers.firstIndex(where: { $0.id == targetID }) else { continue }
            for keyframe in group.keyframes {
                let frame = keyframe.frame + offset
                composition.layers[layerIndex].keyframes.removeAll {
                    $0.property == keyframe.property && $0.frame == frame
                }
                composition.layers[layerIndex].keyframes.append(
                    keyframe.moved(to: frame)
                )
                pasted += 1
            }
        }
        deduplicateLayerKeyframes()
        status = "已粘贴 \(pasted) 个图层关键帧"
    }

    private func pasteCameraClips(_ clips: [CompositionCameraClip]) {
        guard let firstStart = clips.map(\.startFrame).min() else { return }
        let offset = currentFrame - firstStart
        var newIDs: Set<UUID> = []
        for clip in clips {
            let newID = UUID()
            let clone = CompositionCameraClip(
                id: newID,
                name: "\(clip.name) 副本",
                startFrame: clip.startFrame + offset,
                duration: clip.duration,
                isVisible: clip.isVisible,
                camera: clip.camera,
                keyframes: clip.keyframes.map {
                    $0.moved(to: $0.frame + offset)
                },
                expressions: clip.expressions
            )
            composition.cameraClips.insert(clone, at: 0)
            newIDs.insert(newID)
        }
        selectedCameraClipID = newIDs.first
        selectedLayerID = nil
        selectedLayerIDs = []
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        syncEditableCameraFromSelection()
        status = "已粘贴 \(newIDs.count) 个摄像机"
    }

    private func pasteCameraKeyframes(_ keyframes: [CompositionCameraKeyframe]) {
        guard let clipIndex = selectedCameraClipIndex(),
              let minFrame = keyframes.map(\.frame).min() else { return }
        let offset = currentFrame - minFrame
        var pasted = 0
        for keyframe in keyframes {
            let frame = keyframe.frame + offset
            composition.cameraClips[clipIndex].keyframes.removeAll {
                $0.property == keyframe.property && $0.frame == frame
            }
            composition.cameraClips[clipIndex].keyframes.append(
                keyframe.moved(to: frame)
            )
            pasted += 1
        }
        deduplicateCameraKeyframes()
        status = "已粘贴 \(pasted) 个摄像机关键帧"
    }

    func selectCameraKeyframe(
        property: CompositionCameraKeyframeProperty,
        frame: Int,
        extending: Bool
    ) {
        let selection = CompositionCameraKeyframeSelection(property: property, frame: frame)
        if extending {
            if selectedCameraKeyframes.contains(selection) {
                selectedCameraKeyframes.remove(selection)
            } else {
                selectedCameraKeyframes.insert(selection)
            }
        } else {
            selectedCameraKeyframes = [selection]
            selectedLayerKeyframes = []
            selectedLayerIDs = []
            selectedLayerID = nil
            selectedCameraClipID = nil
        }
    }

    func selectLayerKeyframe(
        layerID: UUID,
        property: CompositionLayerKeyframeProperty,
        frame: Int,
        extending: Bool
    ) {
        let selection = CompositionLayerKeyframeSelection(layerID: layerID, property: property, frame: frame)
        if extending {
            if selectedLayerKeyframes.contains(selection) {
                selectedLayerKeyframes.remove(selection)
            } else {
                selectedLayerKeyframes.insert(selection)
            }
        } else {
            selectedLayerKeyframes = [selection]
            selectedCameraKeyframes = []
            selectedLayerIDs = []
            selectedLayerID = layerID
            selectedCameraClipID = nil
        }
    }

    func setBoxSelectedCameraKeyframes(
        property: CompositionCameraKeyframeProperty,
        frames: Set<Int>,
        extending: Bool
    ) {
        if !extending {
            selectedCameraKeyframes = []
            selectedLayerKeyframes = []
            selectedLayerIDs = []
            selectedLayerID = nil
            selectedCameraClipID = nil
        }
        for frame in frames {
            selectedCameraKeyframes.insert(CompositionCameraKeyframeSelection(property: property, frame: frame))
        }
        status = "已框选 \(selectedCameraKeyframes.count + selectedLayerKeyframes.count) 个关键帧"
    }

    func setBoxSelectedCameraKeyframes(
        _ selections: Set<CompositionCameraKeyframeSelection>,
        extending: Bool
    ) {
        if !extending {
            selectedCameraKeyframes = []
            selectedLayerKeyframes = []
            selectedLayerIDs = []
            selectedLayerID = nil
            selectedCameraClipID = nil
        }
        selectedCameraKeyframes.formUnion(selections)
        status = "已框选 \(selectedCameraKeyframes.count + selectedLayerKeyframes.count) 个关键帧"
    }

    func shiftSelectedLayers(by deltaFrames: Int) {
        guard deltaFrames != 0, !selectedLayerIDs.isEmpty else { return }
        recordUndo()
        var movedCount = 0
        for id in selectedLayerIDs {
            guard let index = composition.layers.firstIndex(where: { $0.id == id }) else { continue }
            guard !composition.layers[index].isLocked else { continue }
            let oldStart = composition.layers[index].startFrame
            let newStart = oldStart + deltaFrames
            let resolvedDelta = newStart - oldStart
            composition.layers[index].startFrame = newStart
            for keyIndex in composition.layers[index].keyframes.indices {
                composition.layers[index].keyframes[keyIndex].frame += resolvedDelta
            }
            clampLayer(at: index)
            movedCount += 1
        }
        if movedCount == 0 {
            status = "选中图层已锁定，无法移动"
        }
    }

    func shiftSelectedKeyframes(by deltaFrames: Int) {
        guard deltaFrames != 0 else { return }
        recordUndo()
        let minFrame = 0
        let maxFrame = max(0, composition.frameCount - 1)

        if !selectedCameraKeyframes.isEmpty {
            let oldSelections = selectedCameraKeyframes
            var newSelections: Set<CompositionCameraKeyframeSelection> = []
            if let clipIndex = selectedCameraClipIndex() {
                for selection in oldSelections {
                    guard let index = composition.cameraClips[clipIndex].keyframes.firstIndex(where: {
                        $0.property == selection.property && $0.frame == selection.frame
                    }) else { continue }
                    let newFrame = max(minFrame, min(maxFrame, composition.cameraClips[clipIndex].keyframes[index].frame + deltaFrames))
                    composition.cameraClips[clipIndex].keyframes[index].frame = newFrame
                    newSelections.insert(CompositionCameraKeyframeSelection(property: selection.property, frame: newFrame))
                }
            }
            selectedCameraKeyframes = newSelections
            deduplicateCameraKeyframes()
        }

        if !selectedLayerKeyframes.isEmpty {
            let oldSelections = selectedLayerKeyframes
            var newSelections: Set<CompositionLayerKeyframeSelection> = []
            for selection in oldSelections {
                guard let layerIndex = composition.layers.firstIndex(where: { $0.id == selection.layerID }),
                      let keyIndex = composition.layers[layerIndex].keyframes.firstIndex(where: {
                          $0.property == selection.property && $0.frame == selection.frame
                      }) else { continue }

                let newFrame = max(minFrame, min(maxFrame, composition.layers[layerIndex].keyframes[keyIndex].frame + deltaFrames))
                composition.layers[layerIndex].keyframes[keyIndex].frame = newFrame
                newSelections.insert(
                    CompositionLayerKeyframeSelection(
                        layerID: selection.layerID,
                        property: selection.property,
                        frame: newFrame
                    )
                )
            }
            selectedLayerKeyframes = newSelections
            deduplicateLayerKeyframes()
        }
    }

    func beginSelectedKeyframeDrag() {
        guard keyframeDragSnapshot == nil else { return }
        let clip = selectedCameraClip()
        let cameraItems = selectedCameraKeyframes.compactMap { selection -> CompositionKeyframeDragSnapshot.CameraItem? in
            guard let keyframe = clip?.keyframes.first(where: {
                $0.property == selection.property && $0.frame == selection.frame
            }) else { return nil }
            return CompositionKeyframeDragSnapshot.CameraItem(
                property: keyframe.property,
                frame: keyframe.frame,
                value: keyframe.value,
                interpolation: keyframe.interpolation,
                bezierCurve: keyframe.bezierCurve
            )
        }

        let layerItems = selectedLayerKeyframes.compactMap { selection -> CompositionKeyframeDragSnapshot.LayerItem? in
            guard let layer = composition.layers.first(where: { $0.id == selection.layerID }),
                  let keyframe = layer.keyframes.first(where: {
                      $0.property == selection.property && $0.frame == selection.frame
                  }) else { return nil }
            return CompositionKeyframeDragSnapshot.LayerItem(
                layerID: selection.layerID,
                property: keyframe.property,
                frame: keyframe.frame,
                value: keyframe.value,
                interpolation: keyframe.interpolation,
                bezierCurve: keyframe.bezierCurve
            )
        }

        guard !cameraItems.isEmpty || !layerItems.isEmpty else { return }
        let layerKeyframesByLayerID = Dictionary(
            uniqueKeysWithValues: Set(layerItems.map(\.layerID)).compactMap { layerID -> (UUID, [CompositionLayerKeyframe])? in
                guard let layer = composition.layers.first(where: { $0.id == layerID }) else {
                    return nil
                }
                return (layerID, layer.keyframes)
            }
        )

        keyframeDragSnapshot = CompositionKeyframeDragSnapshot(
            cameraClipID: cameraItems.isEmpty ? nil : clip?.id,
            cameraKeyframes: cameraItems.isEmpty ? [] : clip?.keyframes ?? [],
            layerKeyframesByLayerID: layerKeyframesByLayerID,
            cameraItems: cameraItems,
            layerItems: layerItems,
            undoSnapshot: makeHistorySnapshot()
        )
        keyframeDragCurrentCameraSelections = selectedCameraKeyframes
        keyframeDragCurrentLayerSelections = selectedLayerKeyframes
        keyframeDragDidMove = false
        keyframeDragLastResolvedDelta = 0
    }

    func updateSelectedKeyframeDrag(by deltaFrames: Int) {
        guard let snapshot = keyframeDragSnapshot else {
            shiftSelectedKeyframes(by: deltaFrames)
            return
        }

        let resolvedDelta = resolvedKeyframeDragDelta(deltaFrames, snapshot: snapshot)
        guard keyframeDragDidMove || resolvedDelta != 0 else { return }
        guard !keyframeDragDidMove || resolvedDelta != keyframeDragLastResolvedDelta else { return }

        var newCameraSelections: Set<CompositionCameraKeyframeSelection> = []
        var newLayerSelections: Set<CompositionLayerKeyframeSelection> = []

        if !snapshot.cameraItems.isEmpty,
           let clipID = snapshot.cameraClipID,
           let clipIndex = composition.cameraClips.firstIndex(where: { $0.id == clipID }) {
            let selectedKeys = Set(snapshot.cameraItems.map {
                cameraKeyframeKey(property: $0.property, frame: $0.frame)
            })
            var keyframes = snapshot.cameraKeyframes.filter {
                !selectedKeys.contains(cameraKeyframeKey(property: $0.property, frame: $0.frame))
            }
            for item in snapshot.cameraItems {
                let newFrame = item.frame + resolvedDelta
                keyframes.removeAll {
                    $0.property == item.property && $0.frame == newFrame
                }
                keyframes.append(
                    CompositionCameraKeyframe(
                        frame: newFrame,
                        property: item.property,
                        value: item.value,
                        interpolation: item.interpolation,
                        bezierCurve: item.bezierCurve
                    )
                )
                newCameraSelections.insert(
                    CompositionCameraKeyframeSelection(property: item.property, frame: newFrame)
                )
            }
            composition.cameraClips[clipIndex].keyframes = keyframes.sorted { lhs, rhs in
                lhs.frame == rhs.frame
                    ? lhs.property.rawValue < rhs.property.rawValue
                    : lhs.frame < rhs.frame
            }
            selectedCameraClipID = clipID
        }

        let layerItemsByLayerID = Dictionary(grouping: snapshot.layerItems, by: \.layerID)
        for (layerID, originalKeyframes) in snapshot.layerKeyframesByLayerID {
            guard let layerIndex = composition.layers.firstIndex(where: { $0.id == layerID }) else { continue }
            let items = layerItemsByLayerID[layerID] ?? []
            let selectedKeys = Set(items.map {
                layerKeyframeKey(property: $0.property, frame: $0.frame)
            })
            var keyframes = originalKeyframes.filter {
                !selectedKeys.contains(layerKeyframeKey(property: $0.property, frame: $0.frame))
            }
            for item in items {
                let newFrame = item.frame + resolvedDelta
                keyframes.removeAll {
                    $0.property == item.property && $0.frame == newFrame
                }
                keyframes.append(
                    CompositionLayerKeyframe(
                        frame: newFrame,
                        property: item.property,
                        value: item.value,
                        interpolation: item.interpolation,
                        bezierCurve: item.bezierCurve
                    )
                )
                newLayerSelections.insert(
                    CompositionLayerKeyframeSelection(
                        layerID: item.layerID,
                        property: item.property,
                        frame: newFrame
                    )
                )
            }
            composition.layers[layerIndex].keyframes = keyframes.sorted { lhs, rhs in
                lhs.frame == rhs.frame
                    ? lhs.property.rawValue < rhs.property.rawValue
                    : lhs.frame < rhs.frame
            }
        }

        selectedCameraKeyframes = newCameraSelections
        selectedLayerKeyframes = newLayerSelections
        if let layerID = newLayerSelections.first?.layerID {
            selectedLayerID = layerID
        }
        keyframeDragCurrentCameraSelections = newCameraSelections
        keyframeDragCurrentLayerSelections = newLayerSelections
        deduplicateCameraKeyframes()
        deduplicateLayerKeyframes()
        keyframeDragDidMove = true
        keyframeDragLastResolvedDelta = resolvedDelta
        applyInterpolatedPropertiesToEditableState()
    }

    func endSelectedKeyframeDrag() {
        let count = keyframeDragCurrentCameraSelections.count + keyframeDragCurrentLayerSelections.count
        let finalDelta = keyframeDragLastResolvedDelta
        if finalDelta != 0, let snapshot = keyframeDragSnapshot {
            recordUndo(snapshot: snapshot.undoSnapshot)
        }
        resetKeyframeDragState()
        if count > 0, finalDelta != 0 {
            status = "已移动 \(count) 个关键帧"
        }
    }

    private func resolvedKeyframeDragDelta(
        _ deltaFrames: Int,
        snapshot: CompositionKeyframeDragSnapshot
    ) -> Int {
        let frames = snapshot.cameraItems.map(\.frame) + snapshot.layerItems.map(\.frame)
        guard let minSelectedFrame = frames.min(),
              let maxSelectedFrame = frames.max() else {
            return 0
        }
        let minDelta = -minSelectedFrame
        let maxDelta = max(0, composition.frameCount - 1) - maxSelectedFrame
        return max(minDelta, min(maxDelta, deltaFrames))
    }

    private func resetKeyframeDragState() {
        keyframeDragSnapshot = nil
        keyframeDragCurrentCameraSelections = []
        keyframeDragCurrentLayerSelections = []
        keyframeDragDidMove = false
        keyframeDragLastResolvedDelta = 0
    }

    private func cameraKeyframeKey(
        property: CompositionCameraKeyframeProperty,
        frame: Int
    ) -> String {
        "\(property.rawValue)-\(frame)"
    }

    private func layerKeyframeKey(
        property: CompositionLayerKeyframeProperty,
        frame: Int
    ) -> String {
        "\(property.rawValue)-\(frame)"
    }

    private func deleteLayers(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let lockedNames = composition.layers
            .filter { ids.contains($0.id) && $0.isLocked }
            .map(\.name)
        let unlockedIDs = ids.subtracting(Set(composition.layers.filter(\.isLocked).map(\.id)))
        guard !unlockedIDs.isEmpty else {
            status = "选中图层已锁定，无法删除"
            return
        }
        recordUndo()
        let deletedCount = composition.layers.filter { unlockedIDs.contains($0.id) }.count
        composition.layers.removeAll { unlockedIDs.contains($0.id) }
        expandedLayerIDs.subtract(unlockedIDs)
        openedPrecompositionLayerIDs.subtract(unlockedIDs)
        selectedLayerIDs = []
        selectedLayerKeyframes = selectedLayerKeyframes.filter { !unlockedIDs.contains($0.layerID) }
        selectedCameraKeyframes = []
        selectedLayerID = composition.layers.first?.id
        status = lockedNames.isEmpty
            ? "已删除 \(deletedCount) 个图层"
            : "已删除 \(deletedCount) 个图层，跳过 \(lockedNames.count) 个锁定图层"
    }

    private func deleteSelectedKeyframes() {
        let cameraSelections = selectedCameraKeyframes
        let layerSelections = selectedLayerKeyframes
        guard !cameraSelections.isEmpty || !layerSelections.isEmpty else { return }
        recordUndo()

        if !cameraSelections.isEmpty {
            if let clipIndex = selectedCameraClipIndex() {
                composition.cameraClips[clipIndex].keyframes.removeAll { keyframe in
                    cameraSelections.contains(
                        CompositionCameraKeyframeSelection(
                            property: keyframe.property,
                            frame: keyframe.frame
                        )
                    )
                }
            }
        }

        if !layerSelections.isEmpty {
            for index in composition.layers.indices {
                guard !composition.layers[index].isLocked else { continue }
                let layerID = composition.layers[index].id
                composition.layers[index].keyframes.removeAll { keyframe in
                    layerSelections.contains(
                        CompositionLayerKeyframeSelection(
                            layerID: layerID,
                            property: keyframe.property,
                            frame: keyframe.frame
                        )
                    )
                }
            }
        }

        let count = cameraSelections.count + layerSelections.count
        selectedCameraKeyframes = []
        selectedLayerKeyframes = []
        status = "已删除 \(count) 个关键帧"
    }

    func setBoxSelectedLayerKeyframes(
        layerID: UUID,
        property: CompositionLayerKeyframeProperty,
        frames: Set<Int>,
        extending: Bool
    ) {
        if !extending {
            selectedLayerKeyframes = []
            selectedCameraKeyframes = []
            selectedLayerIDs = []
            selectedCameraClipID = nil
        }
        selectedLayerID = layerID
        for frame in frames {
            selectedLayerKeyframes.insert(
                CompositionLayerKeyframeSelection(layerID: layerID, property: property, frame: frame)
            )
        }
        status = "已框选 \(selectedCameraKeyframes.count + selectedLayerKeyframes.count) 个关键帧"
    }

    func setBoxSelectedLayerKeyframes(
        _ selections: Set<CompositionLayerKeyframeSelection>,
        extending: Bool
    ) {
        if !extending {
            selectedLayerKeyframes = []
            selectedCameraKeyframes = []
            selectedLayerIDs = []
            selectedCameraClipID = nil
        }
        if let layerID = selections.first?.layerID {
            selectedLayerID = layerID
        }
        selectedLayerKeyframes.formUnion(selections)
        status = "已框选 \(selectedCameraKeyframes.count + selectedLayerKeyframes.count) 个关键帧"
    }

    func splitSelectedLayerAtCurrentFrame() {
        if let selectedCameraClipID {
            splitCameraClip(id: selectedCameraClipID)
            return
        }

        guard let selectedID = selectedLayerID,
              let index = composition.layers.firstIndex(where: { $0.id == selectedID }) else {
            status = "没有选中的层可分割"
            return
        }

        let layer = composition.layers[index]
        guard !layer.isLocked else {
            status = "图层已锁定，无法分割"
            return
        }
        let splitFrame = currentFrame
        let start = layer.startFrame
        let end = layer.startFrame + layer.duration

        guard splitFrame > start && splitFrame < end else {
            status = "播放头需要位于选中层内部才能分割"
            return
        }

        recordUndo()
        let leftKeyframes = layer.keyframes.filter { $0.frame < splitFrame }
        let rightKeyframes = layer.keyframes.filter { $0.frame >= splitFrame && $0.frame < end }
        composition.layers[index].duration = splitFrame - start
        composition.layers[index].keyframes = leftKeyframes
        let rightLayer = CompositionLayer(
            assetID: layer.assetID,
            name: layer.name,
            startFrame: splitFrame,
            duration: end - splitFrame,
            isVisible: layer.isVisible,
            isLocked: layer.isLocked,
            isSolo: layer.isSolo,
            blendMode: layer.blendMode,
            volumeRenderMode: layer.volumeRenderMode,
            transform: layer.transform,
            opacity: layer.opacity,
            modifiers: layer.modifiers,
            keyframes: rightKeyframes,
            expressions: layer.expressions
        )
        composition.layers.insert(rightLayer, at: index + 1)
        selectedLayerID = rightLayer.id
        selectedLayerIDs = [rightLayer.id]
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        if expandedLayerIDs.contains(layer.id) {
            expandedLayerIDs.insert(rightLayer.id)
        }
        status = "已分割层：\(layer.name)"
    }

    func toggleLayerVisibility(id: UUID) {
        guard let index = composition.layers.firstIndex(where: { $0.id == id }) else { return }
        recordUndo()
        composition.layers[index].isVisible.toggle()
        let state = composition.layers[index].isVisible ? "显示" : "隐藏"
        status = "\(state)图层：\(composition.layers[index].name)"
    }

    func toggleLayerLock(id: UUID) {
        guard let index = composition.layers.firstIndex(where: { $0.id == id }) else { return }
        recordUndo()
        composition.layers[index].isLocked.toggle()
        let state = composition.layers[index].isLocked ? "锁定" : "解锁"
        status = "已\(state)图层：\(composition.layers[index].name)"
    }

    func setLayerBlendMode(layerID: UUID, blendMode: CompositionLayerBlendMode) {
        guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard composition.layers[index].blendMode != blendMode else { return }
        recordUndo()
        composition.layers[index].blendMode = blendMode
        status = "已设置混合模式：\(composition.layers[index].name) → \(blendMode.title)"
    }

    func setLayerVolumeRenderMode(
        layerID: UUID,
        mode: CompositionLayerVolumeRenderMode
    ) {
        guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard composition.layers[index].volumeRenderMode != mode else { return }
        recordUndo()
        composition.layers[index].volumeRenderMode = mode
        status = "已设置体显示：\(composition.layers[index].name) → \(mode.title)"
    }

    func canUseLayerModifiers(layerID: UUID) -> Bool {
        guard let layer = composition.layers.first(where: { $0.id == layerID }) else { return false }
        guard layer.assetID != Self.rootCompositionAssetID else { return false }
        return assets.first(where: { $0.id == layer.assetID })?.isFileBackedMedia == true
    }

    func selectedLayerModifierState(layerID: UUID) -> MeshModifierState {
        guard let layer = composition.layers.first(where: { $0.id == layerID }),
              let index = selectedLayerModifierIndex(in: layer) else {
            return MeshModifierState()
        }
        return resolvedModifierState(layer.modifiers[index], at: currentFrame)
    }

    func selectedLayerModifierValue(
        layerID: UUID,
        property: MeshModifierKeyframeProperty
    ) -> Float {
        property.value(from: selectedLayerModifierState(layerID: layerID))
    }

    func setSelectedLayerModifierValue(
        layerID: UUID,
        property: MeshModifierKeyframeProperty,
        value: Float
    ) {
        guard canUseLayerModifiers(layerID: layerID),
              let layerIndex = composition.layers.firstIndex(where: { $0.id == layerID }) else {
            return
        }
        guard !composition.layers[layerIndex].isLocked else {
            status = "图层已锁定，无法修改修改器"
            return
        }
        let modifierIndex = ensureSelectedLayerModifier(layerIndex: layerIndex)
        guard let modifierIndex else { return }

        let modifier = composition.layers[layerIndex].modifiers[modifierIndex]
        let resolvedState = resolvedModifierState(modifier, at: currentFrame)
        var nextState = modifier.state
        let resolvedValue = resolvedModifierValue(value, property: property)
        property.set(resolvedValue, in: &nextState)
        guard !Self.nearlyEqual(property.value(from: resolvedState), resolvedValue) else { return }

        let shouldUpdateKeyframe = modifier.keyframes.contains { $0.property == property }
        recordUndoForPropertyEdit()
        composition.layers[layerIndex].modifiers[modifierIndex].state = nextState
        selectedLayerModifierIDs[layerID] = modifier.id

        if shouldUpdateKeyframe {
            upsertSelectedLayerModifierKeyframe(
                layerIndex: layerIndex,
                modifierIndex: modifierIndex,
                property: property,
                value: resolvedValue,
                recordHistory: false
            )
        }
        selectedLayerID = layerID
        selectedLayerIDs = [layerID]
    }

    func toggleSelectedLayerModifierPropertyKeyframes(
        layerID: UUID,
        property: MeshModifierKeyframeProperty
    ) {
        guard let layerIndex = composition.layers.firstIndex(where: { $0.id == layerID }),
              let modifierIndex = selectedLayerModifierIndex(in: composition.layers[layerIndex]) else {
            return
        }
        guard !composition.layers[layerIndex].isLocked else {
            status = "图层已锁定，无法修改修改器关键帧"
            return
        }
        let modifier = composition.layers[layerIndex].modifiers[modifierIndex]
        if modifier.keyframes.contains(where: { $0.property == property }) {
            clearSelectedLayerModifierKeyframes(
                layerIndex: layerIndex,
                modifierIndex: modifierIndex,
                property: property
            )
        } else {
            upsertSelectedLayerModifierKeyframe(
                layerIndex: layerIndex,
                modifierIndex: modifierIndex,
                property: property,
                value: property.value(from: resolvedModifierState(modifier, at: currentFrame)),
                recordHistory: true
            )
        }
    }

    func hasSelectedLayerModifierKeyframe(
        layerID: UUID,
        property: MeshModifierKeyframeProperty,
        at frame: Int? = nil
    ) -> Bool {
        let frame = frame ?? currentFrame
        guard let layer = composition.layers.first(where: { $0.id == layerID }),
              let modifierIndex = selectedLayerModifierIndex(in: layer) else {
            return false
        }
        return layer.modifiers[modifierIndex].keyframes.contains {
            $0.frame == frame && $0.property == property
        }
    }

    func hasAnySelectedLayerModifierKeyframes(
        layerID: UUID,
        property: MeshModifierKeyframeProperty
    ) -> Bool {
        guard let layer = composition.layers.first(where: { $0.id == layerID }),
              let modifierIndex = selectedLayerModifierIndex(in: layer) else {
            return false
        }
        return layer.modifiers[modifierIndex].keyframes.contains { $0.property == property }
    }

    func selectedLayerModifierKeyframes(
        layerID: UUID,
        property: MeshModifierKeyframeProperty
    ) -> [MeshModifierKeyframe] {
        guard let layer = composition.layers.first(where: { $0.id == layerID }),
              let modifierIndex = selectedLayerModifierIndex(in: layer) else {
            return []
        }
        return layer.modifiers[modifierIndex].keyframes
            .filter { $0.property == property }
            .sorted { lhs, rhs in
                lhs.frame == rhs.frame
                    ? lhs.property.rawValue < rhs.property.rawValue
                    : lhs.frame < rhs.frame
            }
    }

    func addLayerModifier(layerID: UUID) {
        guard canUseLayerModifiers(layerID: layerID),
              let index = composition.layers.firstIndex(where: { $0.id == layerID }) else {
            status = "预合成层暂不支持直接添加体素修改器"
            return
        }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法添加修改器"
            return
        }
        recordUndo()
        let modifier = MeshModifierItem(name: "变换 \(composition.layers[index].modifiers.count + 1)")
        composition.layers[index].modifiers.append(modifier)
        selectedLayerModifierIDs[layerID] = modifier.id
        status = "已添加图层修改器：\(composition.layers[index].name)"
    }

    func selectLayerModifier(layerID: UUID, modifierID: UUID) {
        guard let layer = composition.layers.first(where: { $0.id == layerID }),
              layer.modifiers.contains(where: { $0.id == modifierID }) else {
            selectedLayerModifierIDs[layerID] = nil
            return
        }
        selectedLayerModifierIDs[layerID] = modifierID
    }

    func setLayerModifierEnabled(layerID: UUID, modifierID: UUID, isEnabled: Bool) {
        guard let layerIndex = composition.layers.firstIndex(where: { $0.id == layerID }),
              let modifierIndex = composition.layers[layerIndex].modifiers.firstIndex(where: { $0.id == modifierID }),
              composition.layers[layerIndex].modifiers[modifierIndex].isEnabled != isEnabled else {
            return
        }
        guard !composition.layers[layerIndex].isLocked else {
            status = "图层已锁定，无法修改修改器"
            return
        }
        recordUndo()
        composition.layers[layerIndex].modifiers[modifierIndex].isEnabled = isEnabled
        selectedLayerModifierIDs[layerID] = modifierID
        status = "\(isEnabled ? "启用" : "停用")图层修改器：\(composition.layers[layerIndex].modifiers[modifierIndex].name)"
    }

    func updateSelectedLayerModifierState(
        layerID: UUID,
        _ update: (inout MeshModifierState) -> Void
    ) {
        guard canUseLayerModifiers(layerID: layerID),
              let layerIndex = composition.layers.firstIndex(where: { $0.id == layerID }) else {
            return
        }
        guard !composition.layers[layerIndex].isLocked else {
            status = "图层已锁定，无法修改修改器"
            return
        }
        let modifierIndex = ensureSelectedLayerModifier(layerIndex: layerIndex)
        guard let modifierIndex else { return }
        var state = composition.layers[layerIndex].modifiers[modifierIndex].state
        update(&state)
        guard state != composition.layers[layerIndex].modifiers[modifierIndex].state else { return }
        recordUndoForPropertyEdit()
        composition.layers[layerIndex].modifiers[modifierIndex].state = state
        selectedLayerModifierIDs[layerID] = composition.layers[layerIndex].modifiers[modifierIndex].id
    }

    private func clearSelectedLayerModifierKeyframes(
        layerIndex: Int,
        modifierIndex: Int,
        property: MeshModifierKeyframeProperty
    ) {
        let modifier = composition.layers[layerIndex].modifiers[modifierIndex]
        let currentValue = interpolatedModifierValue(
            modifier: modifier,
            property: property,
            at: currentFrame
        ) ?? property.value(from: modifier.state)

        recordUndo()
        var state = composition.layers[layerIndex].modifiers[modifierIndex].state
        property.set(currentValue, in: &state)
        composition.layers[layerIndex].modifiers[modifierIndex].state = state
        composition.layers[layerIndex].modifiers[modifierIndex].keyframes.removeAll {
            $0.property == property
        }
        selectedLayerID = composition.layers[layerIndex].id
        selectedLayerIDs = [composition.layers[layerIndex].id]
        status = "已清空修改器关键帧：\(composition.layers[layerIndex].name) \(property.title)"
    }

    private func upsertSelectedLayerModifierKeyframe(
        layerIndex: Int,
        modifierIndex: Int,
        property: MeshModifierKeyframeProperty,
        value: Float,
        recordHistory: Bool
    ) {
        guard isLayer(composition.layers[layerIndex], activeAt: currentFrame) else {
            status = "播放头需要位于层范围内才能记录修改器关键帧"
            return
        }
        if recordHistory {
            recordUndo()
        }

        let modifierID = composition.layers[layerIndex].modifiers[modifierIndex].id
        let didReplace: Bool
        if let existing = composition.layers[layerIndex].modifiers[modifierIndex].keyframes.firstIndex(where: {
            $0.frame == currentFrame && $0.property == property
        }) {
            let current = composition.layers[layerIndex].modifiers[modifierIndex].keyframes[existing]
            composition.layers[layerIndex].modifiers[modifierIndex].keyframes[existing] = MeshModifierKeyframe(
                modifierID: modifierID,
                frame: currentFrame,
                property: property,
                value: resolvedModifierValue(value, property: property),
                interpolation: current.interpolation,
                bezierCurve: current.bezierCurve
            )
            didReplace = true
        } else {
            composition.layers[layerIndex].modifiers[modifierIndex].keyframes.append(
                MeshModifierKeyframe(
                    modifierID: modifierID,
                    frame: currentFrame,
                    property: property,
                    value: resolvedModifierValue(value, property: property)
                )
            )
            didReplace = false
        }

        composition.layers[layerIndex].modifiers[modifierIndex].keyframes.sort { lhs, rhs in
            lhs.frame == rhs.frame
                ? lhs.property.rawValue < rhs.property.rawValue
                : lhs.frame < rhs.frame
        }
        selectedLayerID = composition.layers[layerIndex].id
        selectedLayerIDs = [composition.layers[layerIndex].id]
        selectedLayerModifierIDs[composition.layers[layerIndex].id] = modifierID
        status = didReplace
            ? "已更新修改器关键帧：\(property.title) @ \(currentFrame)"
            : "已记录修改器关键帧：\(property.title) @ \(currentFrame)"
    }

    func moveSelectedLayerModifier(layerID: UUID, up: Bool) {
        guard let layerIndex = composition.layers.firstIndex(where: { $0.id == layerID }),
              let modifierIndex = selectedLayerModifierIndex(in: composition.layers[layerIndex]) else {
            return
        }
        let target = up ? modifierIndex - 1 : modifierIndex + 1
        guard composition.layers[layerIndex].modifiers.indices.contains(target) else { return }
        recordUndo()
        composition.layers[layerIndex].modifiers.swapAt(modifierIndex, target)
        selectedLayerModifierIDs[layerID] = composition.layers[layerIndex].modifiers[target].id
        status = "已调整图层修改器顺序"
    }

    func deleteSelectedLayerModifier(layerID: UUID) {
        guard let layerIndex = composition.layers.firstIndex(where: { $0.id == layerID }),
              let modifierIndex = selectedLayerModifierIndex(in: composition.layers[layerIndex]) else {
            return
        }
        recordUndo()
        composition.layers[layerIndex].modifiers.remove(at: modifierIndex)
        if composition.layers[layerIndex].modifiers.isEmpty {
            selectedLayerModifierIDs[layerID] = nil
        } else {
            let next = min(modifierIndex, composition.layers[layerIndex].modifiers.count - 1)
            selectedLayerModifierIDs[layerID] = composition.layers[layerIndex].modifiers[next].id
        }
        status = "已删除图层修改器"
    }

    func resetSelectedLayerModifier(layerID: UUID) {
        updateSelectedLayerModifierState(layerID: layerID) { state in
            state = MeshModifierState()
        }
    }

    private func ensureSelectedLayerModifier(layerIndex: Int) -> Int? {
        let layerID = composition.layers[layerIndex].id
        if let selectedID = selectedLayerModifierIDs[layerID],
           let index = composition.layers[layerIndex].modifiers.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        if !composition.layers[layerIndex].modifiers.isEmpty {
            selectedLayerModifierIDs[layerID] = composition.layers[layerIndex].modifiers[0].id
            return 0
        }
        let modifier = MeshModifierItem(name: "变换 1")
        composition.layers[layerIndex].modifiers.append(modifier)
        selectedLayerModifierIDs[layerID] = modifier.id
        return composition.layers[layerIndex].modifiers.indices.last
    }

    private func selectedLayerModifierIndex(in layer: CompositionLayer) -> Int? {
        if let selectedID = selectedLayerModifierIDs[layer.id],
           let index = layer.modifiers.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        return layer.modifiers.isEmpty ? nil : 0
    }

    private func layerIDsForStackMove() -> Set<UUID> {
        if !selectedLayerIDs.isEmpty {
            return selectedLayerIDs
        }
        if let selectedLayerID {
            return [selectedLayerID]
        }
        return []
    }

    private func moveLayerStack(ids: Set<UUID>, operation: CompositionLayerStackOperation) {
        let movableIDs = ids.filter { id in
            guard let layer = composition.layers.first(where: { $0.id == id }) else { return false }
            return !layer.isLocked
        }
        guard !movableIDs.isEmpty else {
            status = "没有可调整层级的图层"
            return
        }

        let before = composition.layers.map(\.id)
        var layers = composition.layers

        switch operation {
        case .top:
            let moving = layers.filter { movableIDs.contains($0.id) }
            let rest = layers.filter { !movableIDs.contains($0.id) }
            layers = moving + rest
        case .bottom:
            let moving = layers.filter { movableIDs.contains($0.id) }
            let rest = layers.filter { !movableIDs.contains($0.id) }
            layers = rest + moving
        case .up:
            guard layers.count > 1 else { return }
            for index in layers.indices.dropFirst() {
                guard movableIDs.contains(layers[index].id),
                      !movableIDs.contains(layers[index - 1].id) else { continue }
                layers.swapAt(index, index - 1)
            }
        case .down:
            guard layers.count > 1 else { return }
            for index in layers.indices.dropLast().reversed() {
                guard movableIDs.contains(layers[index].id),
                      !movableIDs.contains(layers[index + 1].id) else { continue }
                layers.swapAt(index, index + 1)
            }
        }

        guard layers.map(\.id) != before else {
            status = "图层层级没有变化"
            return
        }

        recordUndo()
        composition.layers = layers
        selectedLayerIDs = movableIDs
        selectedLayerID = movableIDs.first
        status = "已调整 \(movableIDs.count) 个图层的层级"
    }

    func moveSelectedLayersToTop() {
        moveLayerStack(ids: layerIDsForStackMove(), operation: .top)
    }

    func moveSelectedLayersUp() {
        moveLayerStack(ids: layerIDsForStackMove(), operation: .up)
    }

    func moveSelectedLayersDown() {
        moveLayerStack(ids: layerIDsForStackMove(), operation: .down)
    }

    func moveSelectedLayersToBottom() {
        moveLayerStack(ids: layerIDsForStackMove(), operation: .bottom)
    }

    func moveLayerToTop(id: UUID) {
        moveLayerStack(ids: [id], operation: .top)
    }

    func moveLayerUp(id: UUID) {
        moveLayerStack(ids: [id], operation: .up)
    }

    func moveLayerDown(id: UUID) {
        moveLayerStack(ids: [id], operation: .down)
    }

    func moveLayerToBottom(id: UUID) {
        moveLayerStack(ids: [id], operation: .bottom)
    }

    func beginLayerReorder(id: UUID) {
        guard let layer = composition.layers.first(where: { $0.id == id }) else { return }
        guard !layer.isLocked else {
            status = "图层已锁定，无法调整层级"
            return
        }
        recordUndo()
        selectedLayerID = id
        selectedLayerIDs = [id]
        selectedCameraClipID = nil
        status = "正在拖动调整图层层级：\(layer.name)"
    }

    func reorderLayer(id: UUID, toVisualIndex targetIndex: Int, recordUndoStep: Bool = true) {
        guard let oldIndex = composition.layers.firstIndex(where: { $0.id == id }) else { return }
        guard !composition.layers[oldIndex].isLocked else {
            status = "图层已锁定，无法调整层级"
            return
        }
        let clampedIndex = max(0, min(targetIndex, composition.layers.count - 1))
        guard oldIndex != clampedIndex else { return }

        if recordUndoStep {
            recordUndo()
        }
        let layer = composition.layers.remove(at: oldIndex)
        composition.layers.insert(layer, at: clampedIndex)
        selectedLayerID = id
        selectedLayerIDs = [id]
        selectedCameraClipID = nil
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        status = "已拖动调整图层层级：\(layer.name)"
    }

    func toggleLayerSolo(id: UUID) {
        guard let index = composition.layers.firstIndex(where: { $0.id == id }) else { return }
        recordUndo()
        composition.layers[index].isSolo.toggle()
        let state = composition.layers[index].isSolo ? "独显" : "取消独显"
        status = "\(state)：\(composition.layers[index].name)"
    }

    func toggleCameraVisibility(id: UUID) {
        guard let index = composition.cameraClips.firstIndex(where: { $0.id == id }) else { return }
        recordUndo()
        composition.cameraClips[index].isVisible.toggle()
        let state = composition.cameraClips[index].isVisible ? "显示" : "隐藏"
        status = "\(state)摄像机：\(composition.cameraClips[index].name)"
    }

    func clearLayerSolo() {
        guard composition.layers.contains(where: \.isSolo) else { return }
        recordUndo()
        for index in composition.layers.indices {
            composition.layers[index].isSolo = false
        }
        status = "已取消所有 Solo"
    }

    func setSelectedLayersVisible(_ visible: Bool) {
        var ids = selectedLayerIDs
        if ids.isEmpty, let selectedLayerID {
            ids = [selectedLayerID]
        }
        guard !ids.isEmpty else {
            status = "没有选中的图层"
            return
        }
        recordUndo()
        var count = 0
        for index in composition.layers.indices where ids.contains(composition.layers[index].id) {
            composition.layers[index].isVisible = visible
            count += 1
        }
        status = "\(visible ? "显示" : "隐藏") \(count) 个选中图层"
    }

    func setAllLayersVisible(_ visible: Bool) {
        guard !composition.layers.isEmpty else { return }
        recordUndo()
        for index in composition.layers.indices {
            composition.layers[index].isVisible = visible
        }
        status = "\(visible ? "显示" : "隐藏")全部图层"
    }

    func setSelectedLayersLocked(_ locked: Bool) {
        var ids = selectedLayerIDs
        if ids.isEmpty, let selectedLayerID {
            ids = [selectedLayerID]
        }
        guard !ids.isEmpty else {
            status = "没有选中的图层"
            return
        }
        recordUndo()
        var count = 0
        for index in composition.layers.indices where ids.contains(composition.layers[index].id) {
            composition.layers[index].isLocked = locked
            count += 1
        }
        status = "\(locked ? "锁定" : "解锁") \(count) 个选中图层"
    }

    func addTimelineMarkerAtCurrentFrame() {
        let frame = max(0, min(currentFrame, max(0, composition.frameCount - 1)))
        if composition.markers.contains(where: { $0.frame == frame }) {
            status = "当前时间码已有标记"
            return
        }
        recordUndo()
        let marker = CompositionTimelineMarker(
            frame: frame,
            name: "标记 \(composition.markers.count + 1)"
        )
        composition.markers.append(marker)
        composition.markers.sort { $0.frame < $1.frame }
        status = "已添加时间线标记 @ \(frame)"
    }

    func deleteTimelineMarkerAtCurrentFrame() {
        guard composition.markers.contains(where: { $0.frame == currentFrame }) else {
            status = "当前时间码没有标记"
            return
        }
        recordUndo()
        composition.markers.removeAll { $0.frame == currentFrame }
        status = "已删除当前时间线标记"
    }

    func addCameraClipAtCurrentFrame() {
        ensureCameraClips()
        recordUndo()
        let frame = currentFrame
        let clip = CompositionCameraClip(
            name: "摄像机 \(composition.cameraClips.count + 1)",
            startFrame: frame,
            duration: max(1, composition.frameCount - frame),
            camera: compositionCamera
        )
        composition.cameraClips.insert(clip, at: 0)
        selectedCameraClipID = clip.id
        selectedLayerID = nil
        selectedLayerIDs = []
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        syncEditableCameraFromSelection()
        status = "已添加摄像机"
    }

    func splitCameraClip(id: UUID) {
        ensureCameraClips()
        guard let index = composition.cameraClips.firstIndex(where: { $0.id == id }) else {
            status = "没有选中的摄像机可分割"
            return
        }
        let clip = composition.cameraClips[index]
        let start = clip.startFrame
        let end = clip.startFrame + clip.duration
        let splitFrame = currentFrame
        guard splitFrame > start && splitFrame < end else {
            status = "播放头需要位于摄像机片段内部才能分割"
            return
        }

        recordUndo()
        let leftKeyframes = clip.keyframes.filter { $0.frame < splitFrame }
        let rightKeyframes = clip.keyframes.filter { $0.frame >= splitFrame && $0.frame < end }
        composition.cameraClips[index].duration = splitFrame - start
        composition.cameraClips[index].keyframes = leftKeyframes
        let rightClip = CompositionCameraClip(
            name: "\(clip.name) 分割",
            startFrame: splitFrame,
            duration: end - splitFrame,
            isVisible: clip.isVisible,
            camera: renderCamera(clipID: clip.id, at: splitFrame),
            keyframes: rightKeyframes,
            expressions: clip.expressions
        )
        composition.cameraClips.insert(rightClip, at: index + 1)
        selectedCameraClipID = rightClip.id
        selectedLayerID = nil
        selectedLayerIDs = []
        selectedLayerKeyframes = []
        selectedCameraKeyframes = []
        syncEditableCameraFromSelection()
        status = "已分割摄像机"
    }

    private func deleteCameraClip(id: UUID) {
        recordUndo()
        composition.cameraClips.removeAll { $0.id == id }
        ensureCameraClips()
        selectedCameraClipID = activeCameraClip(at: currentFrame)?.id ?? composition.cameraClips.first?.id
        syncEditableCameraFromSelection()
        status = "已删除摄像机"
    }

    func toggleLayerExpanded(id: UUID) {
        if expandedLayerIDs.contains(id) {
            expandedLayerIDs.remove(id)
        } else {
            expandedLayerIDs.insert(id)
        }
        selectOnlyLayer(id)
    }

    func toggleCameraTrackExpanded() {
        isCameraTrackExpanded.toggle()
        if selectedCameraClipID == nil {
            selectedCameraClipID = activeCameraClip(at: currentFrame)?.id ?? composition.cameraClips.first?.id
        }
        syncEditableCameraFromSelection()
    }

    func togglePlayback() {
        isCompositionPlaying ? stopPlayback() : startPlayback()
    }

    func startPlayback() {
        stopPlayback()
        isCompositionPlaying = true
        let interval = 1.0 / max(0.05, composition.fps)
        playbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advancePlaybackFrame()
            }
        }
    }

    func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        isCompositionPlaying = false
    }

    private func advancePlaybackFrame() {
        guard isCompositionPlaying else { return }
        if currentFrame >= composition.frameCount - 1 {
            setCurrentFrame(0)
        } else {
            setCurrentFrame(currentFrame + 1)
        }
    }

    func setCompositionCameraProperty(
        _ property: CompositionCameraKeyframeProperty,
        value: Float,
        syncFocusOrientation: Bool = true,
        recordHistory: Bool = true
    ) {
        guard let clipIndex = selectedCameraClipIndex() else { return }
        let resolvedValue = Self.resolvedCameraValue(value, property: property)
        guard !Self.nearlyEqual(Self.cameraValue(property, camera: compositionCamera), resolvedValue) else { return }
        if recordHistory {
            recordUndoForPropertyEdit()
        }
        let shouldUpdateKeyframe = hasAnyCameraKeyframes(for: property)
        updateCompositionCamera(syncFocusOrientation: syncFocusOrientation) {
            Self.setCameraValue(resolvedValue, property: property, camera: &$0)
        }
        composition.cameraClips[clipIndex].camera = compositionCamera
        if shouldUpdateKeyframe {
            upsertCompositionCameraKeyframe(property, recordHistory: false)
        }
    }

    func setCompositionCameraFromView(
        _ camera: CameraRigState,
        recordHistory: Bool = true
    ) {
        guard let clipIndex = selectedCameraClipIndex() else { return }
        let oldCamera = compositionCamera
        guard oldCamera != camera else { return }
        if recordHistory {
            recordUndoForPropertyEdit()
        }

        let changedProperties = CompositionCameraKeyframeProperty.allCases.filter {
            !Self.nearlyEqual(Self.cameraValue($0, camera: oldCamera), Self.cameraValue($0, camera: camera))
        }
        let animatedProperties = Set(composition.cameraClips[clipIndex].keyframes.map(\.property))

        compositionCamera = camera
        composition.cameraClips[clipIndex].camera = compositionCamera
        for property in changedProperties where animatedProperties.contains(property) {
            upsertCompositionCameraKeyframe(property, recordHistory: false)
        }
    }

    func setCompositionCameraKeyframe(_ property: CompositionCameraKeyframeProperty) {
        upsertCompositionCameraKeyframe(property, recordHistory: true)
    }

    func toggleCompositionCameraPropertyKeyframes(_ property: CompositionCameraKeyframeProperty) {
        guard hasAnyCameraKeyframes(for: property) else {
            setCompositionCameraKeyframe(property)
            return
        }
        clearCompositionCameraKeyframes(property)
    }

    private func clearCompositionCameraKeyframes(_ property: CompositionCameraKeyframeProperty) {
        guard let clipIndex = selectedCameraClipIndex() else { return }
        let keyframes = composition.cameraClips[clipIndex].keyframes
        let currentValue = interpolatedCameraValue(
            keyframes: keyframes,
            property: property,
            at: currentFrame
        ) ?? Self.cameraValue(property, camera: compositionCamera)

        recordUndo()
        Self.setCameraValue(currentValue, property: property, camera: &compositionCamera)
        composition.cameraClips[clipIndex].camera = compositionCamera
        composition.cameraClips[clipIndex].keyframes.removeAll { $0.property == property }
        selectedCameraKeyframes = selectedCameraKeyframes.filter { $0.property != property }
        selectedLayerKeyframes = []
        status = "已清空总摄像机关键帧：\(property.title)，保留当前时间码状态"
    }

    private func upsertCompositionCameraKeyframe(
        _ property: CompositionCameraKeyframeProperty,
        recordHistory: Bool
    ) {
        guard let clipIndex = selectedCameraClipIndex() else { return }
        if recordHistory {
            recordUndo()
        }
        let didReplace: Bool
        if let index = composition.cameraClips[clipIndex].keyframes.firstIndex(where: {
            $0.frame == currentFrame && $0.property == property
        }) {
            let existing = composition.cameraClips[clipIndex].keyframes[index]
            let keyframe = CompositionCameraKeyframe(
                frame: currentFrame,
                property: property,
                value: Self.cameraValue(property, camera: compositionCamera),
                interpolation: existing.interpolation,
                bezierCurve: existing.bezierCurve
            )
            composition.cameraClips[clipIndex].keyframes[index] = keyframe
            didReplace = true
        } else {
            let keyframe = CompositionCameraKeyframe(
                frame: currentFrame,
                property: property,
                value: Self.cameraValue(property, camera: compositionCamera)
            )
            composition.cameraClips[clipIndex].keyframes.append(keyframe)
            composition.cameraClips[clipIndex].keyframes.sort { lhs, rhs in
                lhs.frame == rhs.frame
                    ? lhs.property.rawValue < rhs.property.rawValue
                    : lhs.frame < rhs.frame
            }
            didReplace = false
        }
        selectedCameraKeyframes = [CompositionCameraKeyframeSelection(property: property, frame: currentFrame)]
        selectedLayerKeyframes = []
        status = didReplace
            ? "已更新总摄像机关键帧：\(property.title) @ \(currentFrame)"
            : "已记录总摄像机关键帧：\(property.title) @ \(currentFrame)"
    }

    func hasCompositionCameraKeyframe(property: CompositionCameraKeyframeProperty, at frame: Int? = nil) -> Bool {
        let frame = frame ?? currentFrame
        return selectedCameraClip()?.keyframes.contains { $0.frame == frame && $0.property == property } ?? false
    }

    func compositionCameraKeyframes(for property: CompositionCameraKeyframeProperty) -> [CompositionCameraKeyframe] {
        selectedCameraClip()?.keyframes.filter { $0.property == property } ?? []
    }

    func compositionCameraExpression(for property: CompositionCameraKeyframeProperty) -> CompositionPropertyExpression {
        selectedCameraClip()?.expressions[property.rawValue] ?? CompositionPropertyExpression()
    }

    func setCompositionCameraExpressionEnabled(
        _ property: CompositionCameraKeyframeProperty,
        enabled: Bool
    ) {
        guard let clipIndex = selectedCameraClipIndex() else { return }
        var expression = composition.cameraClips[clipIndex].expressions[property.rawValue] ?? CompositionPropertyExpression()
        guard expression.isEnabled != enabled else { return }
        recordUndo()
        expression.isEnabled = enabled
        composition.cameraClips[clipIndex].expressions[property.rawValue] = expression
        syncEditableCameraFromSelection()
        status = enabled
            ? "已启用总摄像机表达式：\(property.title)"
            : "已关闭总摄像机表达式：\(property.title)"
    }

    func setCompositionCameraExpressionSource(
        _ property: CompositionCameraKeyframeProperty,
        source: String
    ) {
        guard let clipIndex = selectedCameraClipIndex() else { return }
        var expression = composition.cameraClips[clipIndex].expressions[property.rawValue] ?? CompositionPropertyExpression()
        guard expression.source != source else { return }
        recordUndoForPropertyEdit()
        expression.source = source
        composition.cameraClips[clipIndex].expressions[property.rawValue] = expression
        syncEditableCameraFromSelection()
    }

    func setLayerProperty(
        layerID: UUID,
        property: CompositionLayerKeyframeProperty,
        value: Float,
        recordHistory: Bool = true
    ) {
        guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法修改属性"
            return
        }
        let resolvedValue = Self.resolvedLayerValue(value, property: property)
        if property.isScaleAxis {
            let linkedProperties = Self.linkedScaleAxisProperties(
                for: property,
                transform: composition.layers[index].transform
            )
            if linkedProperties.count > 1 {
                setLinkedLayerScaleProperty(
                    layerID: layerID,
                    layerIndex: index,
                    property: property,
                    value: resolvedValue,
                    linkedProperties: linkedProperties,
                    recordHistory: recordHistory
                )
                return
            }
        }
        guard !Self.nearlyEqual(Self.layerValue(property, layer: composition.layers[index]), resolvedValue) else { return }
        guard isLayer(composition.layers[index], activeAt: currentFrame) else {
            if recordHistory {
                recordUndoForPropertyEdit()
            }
            Self.setLayerValue(resolvedValue, property: property, layer: &composition.layers[index])
            clampLayer(at: index)
            return
        }

        let shouldUpdateKeyframe = hasAnyLayerKeyframes(layer: composition.layers[index], property: property)
        if recordHistory {
            recordUndoForPropertyEdit()
        }
        Self.setLayerValue(resolvedValue, property: property, layer: &composition.layers[index])
        clampLayer(at: index)

        if shouldUpdateKeyframe {
            upsertLayerKeyframe(layerID: layerID, property: property, recordHistory: false)
        }
        selectedLayerID = layerID
    }

    private func setLinkedLayerScaleProperty(
        layerID: UUID,
        layerIndex index: Int,
        property: CompositionLayerKeyframeProperty,
        value: Float,
        linkedProperties: [CompositionLayerKeyframeProperty],
        recordHistory: Bool
    ) {
        let currentLayer = composition.layers[index]
        let currentValue = max(0.01, Self.layerValue(property, layer: currentLayer))
        let factor = max(0.01, value) / currentValue
        let targets = linkedProperties.map { axisProperty in
            (
                axisProperty,
                Self.resolvedLayerValue(
                    Self.layerValue(axisProperty, layer: currentLayer) * factor,
                    property: axisProperty
                )
            )
        }
        guard targets.contains(where: { target in
            !Self.nearlyEqual(Self.layerValue(target.0, layer: currentLayer), target.1)
        }) else { return }

        let isActive = isLayer(currentLayer, activeAt: currentFrame)
        let shouldUpdateKeyframes = isActive && (
            linkedProperties.contains { scaleProperty in
                hasAnyLayerKeyframes(layer: currentLayer, property: scaleProperty)
            }
            || hasAnyLayerKeyframes(layer: currentLayer, property: .scale)
        )

        if recordHistory {
            recordUndoForPropertyEdit()
        }
        for target in targets {
            Self.setLayerValue(target.1, property: target.0, layer: &composition.layers[index])
        }
        clampLayer(at: index)

        if shouldUpdateKeyframes {
            for scaleProperty in linkedProperties {
                upsertLayerKeyframe(layerID: layerID, property: scaleProperty, recordHistory: false)
            }
        }
        selectedLayerID = layerID
        selectedLayerIDs = [layerID]
    }

    func setLayerScaleAxisLinked(
        layerID: UUID,
        property: CompositionLayerKeyframeProperty,
        isLinked: Bool
    ) {
        guard property.isScaleAxis else { return }
        guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法修改缩放关联"
            return
        }
        guard Self.isScaleAxisLinked(property, transform: composition.layers[index].transform) != isLinked else { return }
        recordUndo()
        Self.setScaleAxisLinked(isLinked, property: property, transform: &composition.layers[index].transform)
        selectedLayerID = layerID
        selectedLayerIDs = [layerID]
        status = isLinked ? "已开启缩放关联：\(property.title)" : "已关闭缩放关联：\(property.title)"
    }

    func layerExpression(
        layerID: UUID,
        property: CompositionLayerKeyframeProperty
    ) -> CompositionPropertyExpression {
        composition.layers.first(where: { $0.id == layerID })?.expressions[property.rawValue]
            ?? CompositionPropertyExpression()
    }

    func setLayerExpressionEnabled(
        layerID: UUID,
        property: CompositionLayerKeyframeProperty,
        enabled: Bool
    ) {
        guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法修改表达式"
            return
        }
        var expression = composition.layers[index].expressions[property.rawValue] ?? CompositionPropertyExpression()
        guard expression.isEnabled != enabled else { return }
        recordUndo()
        expression.isEnabled = enabled
        composition.layers[index].expressions[property.rawValue] = expression
        applyInterpolatedPropertiesToEditableState()
        status = enabled
            ? "已启用层表达式：\(composition.layers[index].name) \(property.title)"
            : "已关闭层表达式：\(composition.layers[index].name) \(property.title)"
    }

    func setLayerExpressionSource(
        layerID: UUID,
        property: CompositionLayerKeyframeProperty,
        source: String
    ) {
        guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法修改表达式"
            return
        }
        var expression = composition.layers[index].expressions[property.rawValue] ?? CompositionPropertyExpression()
        guard expression.source != source else { return }
        recordUndoForPropertyEdit()
        expression.source = source
        composition.layers[index].expressions[property.rawValue] = expression
        applyInterpolatedPropertiesToEditableState()
    }

    func beginCompositionGizmoEdit() {
        recordUndo()
    }

    func beginCompositionValueDrag() {
        isCoalescingValueDrag = true
        didRecordValueDragUndo = false
        isCompositionValueDragging = true
    }

    func endCompositionValueDrag() {
        isCoalescingValueDrag = false
        didRecordValueDragUndo = false
        isCompositionValueDragging = false
    }

    func setLayerKeyframe(layerID: UUID, property: CompositionLayerKeyframeProperty) {
        upsertLayerKeyframe(layerID: layerID, property: property, recordHistory: true)
    }

    func toggleLayerPropertyKeyframes(layerID: UUID, property: CompositionLayerKeyframeProperty) {
        guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard hasAnyLayerKeyframes(layer: composition.layers[index], property: property) else {
            setLayerKeyframe(layerID: layerID, property: property)
            return
        }
        clearLayerKeyframes(layerID: layerID, property: property)
    }

    private func clearLayerKeyframes(layerID: UUID, property: CompositionLayerKeyframeProperty) {
        guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法清空关键帧"
            return
        }
        let layer = composition.layers[index]
        let currentValue = interpolatedLayerValue(
            layer: layer,
            property: property,
            at: currentFrame
        ) ?? Self.layerValue(property, layer: layer)

        recordUndo()
        Self.setLayerValue(currentValue, property: property, layer: &composition.layers[index])
        composition.layers[index].keyframes.removeAll { $0.property == property }
        selectedLayerKeyframes = selectedLayerKeyframes.filter {
            !($0.layerID == layerID && $0.property == property)
        }
        selectedCameraKeyframes = []
        selectedLayerID = layerID
        selectedLayerIDs = [layerID]
        clampLayer(at: index)
        status = "已清空层关键帧：\(composition.layers[index].name) \(property.title)，保留当前时间码状态"
    }

    private func upsertLayerKeyframe(
        layerID: UUID,
        property: CompositionLayerKeyframeProperty,
        recordHistory: Bool
    ) {
        guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法记录关键帧"
            return
        }
        guard isLayer(composition.layers[index], activeAt: currentFrame) else {
            status = "播放头需要位于层范围内才能记录关键帧"
            return
        }

        if recordHistory {
            recordUndo()
        }
        let didReplace: Bool
        if let existing = composition.layers[index].keyframes.firstIndex(where: {
            $0.frame == currentFrame && $0.property == property
        }) {
            let current = composition.layers[index].keyframes[existing]
            let keyframe = CompositionLayerKeyframe(
                frame: currentFrame,
                property: property,
                value: Self.layerValue(property, layer: composition.layers[index]),
                interpolation: current.interpolation,
                bezierCurve: current.bezierCurve
            )
            composition.layers[index].keyframes[existing] = keyframe
            didReplace = true
        } else {
            let keyframe = CompositionLayerKeyframe(
                frame: currentFrame,
                property: property,
                value: Self.layerValue(property, layer: composition.layers[index])
            )
            composition.layers[index].keyframes.append(keyframe)
            composition.layers[index].keyframes.sort { lhs, rhs in
                lhs.frame == rhs.frame
                    ? lhs.property.rawValue < rhs.property.rawValue
                    : lhs.frame < rhs.frame
            }
            didReplace = false
        }
        selectedLayerID = layerID
        selectedLayerIDs = [layerID]
        selectedLayerKeyframes = [CompositionLayerKeyframeSelection(layerID: layerID, property: property, frame: currentFrame)]
        selectedCameraKeyframes = []
        status = didReplace
            ? "已更新层关键帧：\(composition.layers[index].name) \(property.title) @ \(currentFrame)"
            : "已记录层关键帧：\(composition.layers[index].name) \(property.title) @ \(currentFrame)"
    }

    func deleteLayerKeyframeAtCurrentFrame(layerID: UUID, property: CompositionLayerKeyframeProperty) {
        guard let index = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法删除关键帧"
            return
        }
        recordUndo()
        composition.layers[index].keyframes.removeAll { $0.frame == currentFrame && $0.property == property }
        selectedLayerKeyframes.remove(
            CompositionLayerKeyframeSelection(layerID: layerID, property: property, frame: currentFrame)
        )
        selectedLayerID = layerID
        status = "已删除当前帧层关键帧"
    }

    func hasLayerKeyframe(layerID: UUID, property: CompositionLayerKeyframeProperty, at frame: Int? = nil) -> Bool {
        let frame = frame ?? currentFrame
        return composition.layers
            .first(where: { $0.id == layerID })?
            .keyframes
            .contains { $0.frame == frame && $0.property == property } ?? false
    }

    func layerKeyframes(layerID: UUID, property: CompositionLayerKeyframeProperty) -> [CompositionLayerKeyframe] {
        return composition.layers
            .first(where: { $0.id == layerID })?
            .keyframes
            .filter { $0.property == property } ?? []
    }

    func selectedKeyframeInterpolation() -> CompositionKeyframeInterpolation {
        selectedKeyframes().first?.interpolation ?? .linear
    }

    func selectedKeyframeBezierCurve() -> CompositionBezierCurve {
        selectedKeyframes().first?.bezierCurve ?? .default
    }

    func selectedKeyframeVelocityText() -> String {
        if let selection = selectedCameraKeyframes.sorted(by: { lhs, rhs in
            lhs.frame == rhs.frame
                ? lhs.property.rawValue < rhs.property.rawValue
                : lhs.frame < rhs.frame
        }).first,
           let clip = selectedCameraClip() {
            let keys = clip.keyframes
                .filter { $0.property == selection.property }
                .map { (frame: $0.frame, value: $0.value, interpolation: $0.interpolation) }
            return keyframeVelocityText(
                title: selection.property.title,
                frame: selection.frame,
                keyframes: keys
            )
        }

        if let selection = selectedLayerKeyframes.sorted(by: { lhs, rhs in
            if lhs.layerID != rhs.layerID {
                return lhs.layerID.uuidString < rhs.layerID.uuidString
            }
            if lhs.frame != rhs.frame {
                return lhs.frame < rhs.frame
            }
            return lhs.property.rawValue < rhs.property.rawValue
        }).first,
           let layer = composition.layers.first(where: { $0.id == selection.layerID }) {
            let keys = layer.keyframes
                .filter { $0.property == selection.property }
                .map { (frame: $0.frame, value: $0.value, interpolation: $0.interpolation) }
            return keyframeVelocityText(
                title: "\(layer.name) \(selection.property.title)",
                frame: selection.frame,
                keyframes: keys
            )
        }

        return "速度：选择关键帧后显示"
    }

    func setSelectedKeyframeInterpolation(_ interpolation: CompositionKeyframeInterpolation) {
        let selected = selectedKeyframes()
        guard !selected.isEmpty else { return }
        guard selected.contains(where: { $0.interpolation != interpolation }) else { return }
        recordUndo()
        var changed = 0
        if !selectedCameraKeyframes.isEmpty, let clipIndex = selectedCameraClipIndex() {
            for selection in selectedCameraKeyframes {
                guard let keyIndex = composition.cameraClips[clipIndex].keyframes.firstIndex(where: {
                    $0.property == selection.property && $0.frame == selection.frame
                }) else { continue }
                composition.cameraClips[clipIndex].keyframes[keyIndex].interpolation = interpolation
                changed += 1
            }
        }

        for selection in selectedLayerKeyframes {
            guard let layerIndex = composition.layers.firstIndex(where: { $0.id == selection.layerID }),
                  !composition.layers[layerIndex].isLocked,
                  let keyIndex = composition.layers[layerIndex].keyframes.firstIndex(where: {
                      $0.property == selection.property && $0.frame == selection.frame
                  }) else {
                continue
            }
            composition.layers[layerIndex].keyframes[keyIndex].interpolation = interpolation
            changed += 1
        }

        status = "已设置 \(changed) 个关键帧插值：\(interpolation.title)"
        applyInterpolatedPropertiesToEditableState()
    }

    func setSelectedKeyframeBezierCurve(_ curve: CompositionBezierCurve) {
        guard selectedKeyframeCount > 0 else { return }
        let resolvedCurve = Self.sanitizedBezierCurve(curve)
        recordUndoForPropertyEdit()
        var changed = 0
        if !selectedCameraKeyframes.isEmpty, let clipIndex = selectedCameraClipIndex() {
            for selection in selectedCameraKeyframes {
                guard let keyIndex = composition.cameraClips[clipIndex].keyframes.firstIndex(where: {
                    $0.property == selection.property && $0.frame == selection.frame
                }) else { continue }
                composition.cameraClips[clipIndex].keyframes[keyIndex].interpolation = .bezier
                composition.cameraClips[clipIndex].keyframes[keyIndex].bezierCurve = resolvedCurve
                changed += 1
            }
        }

        for selection in selectedLayerKeyframes {
            guard let layerIndex = composition.layers.firstIndex(where: { $0.id == selection.layerID }),
                  !composition.layers[layerIndex].isLocked,
                  let keyIndex = composition.layers[layerIndex].keyframes.firstIndex(where: {
                      $0.property == selection.property && $0.frame == selection.frame
                  }) else {
                continue
            }
            composition.layers[layerIndex].keyframes[keyIndex].interpolation = .bezier
            composition.layers[layerIndex].keyframes[keyIndex].bezierCurve = resolvedCurve
            changed += 1
        }

        status = "已更新 \(changed) 个贝塞尔关键帧"
        applyInterpolatedPropertiesToEditableState()
    }

    func copySelectedKeyframeEasing() {
        guard let easing = selectedKeyframes().first else {
            status = "请选择一个关键帧来复制 easing"
            return
        }
        easingClipboard = CompositionEasingClipboard(
            interpolation: easing.interpolation,
            bezierCurve: easing.bezierCurve
        )
        status = "已复制 easing：\(easing.interpolation.title)"
    }

    func pasteSelectedKeyframeEasing() {
        guard selectedKeyframeCount > 0 else {
            status = "请选择要粘贴 easing 的关键帧"
            return
        }
        guard let easingClipboard else {
            status = "还没有复制 easing"
            return
        }

        recordUndo()
        let resolvedCurve = Self.sanitizedBezierCurve(easingClipboard.bezierCurve)
        var changed = 0
        if !selectedCameraKeyframes.isEmpty, let clipIndex = selectedCameraClipIndex() {
            for selection in selectedCameraKeyframes {
                guard let keyIndex = composition.cameraClips[clipIndex].keyframes.firstIndex(where: {
                    $0.property == selection.property && $0.frame == selection.frame
                }) else { continue }
                composition.cameraClips[clipIndex].keyframes[keyIndex].interpolation = easingClipboard.interpolation
                composition.cameraClips[clipIndex].keyframes[keyIndex].bezierCurve = resolvedCurve
                changed += 1
            }
        }

        for selection in selectedLayerKeyframes {
            guard let layerIndex = composition.layers.firstIndex(where: { $0.id == selection.layerID }),
                  !composition.layers[layerIndex].isLocked,
                  let keyIndex = composition.layers[layerIndex].keyframes.firstIndex(where: {
                      $0.property == selection.property && $0.frame == selection.frame
                  }) else {
                continue
            }
            composition.layers[layerIndex].keyframes[keyIndex].interpolation = easingClipboard.interpolation
            composition.layers[layerIndex].keyframes[keyIndex].bezierCurve = resolvedCurve
            changed += 1
        }

        status = "已粘贴 easing 到 \(changed) 个关键帧：\(easingClipboard.interpolation.title)"
        applyInterpolatedPropertiesToEditableState()
    }

    func setCameraKeyframeBezierCurve(
        property: CompositionCameraKeyframeProperty,
        frame: Int,
        curve: CompositionBezierCurve,
        recordHistory: Bool = true
    ) {
        guard let clipIndex = selectedCameraClipIndex(),
              let keyIndex = composition.cameraClips[clipIndex].keyframes.firstIndex(where: {
                  $0.property == property && $0.frame == frame
              }) else {
            return
        }
        if recordHistory {
            recordUndo()
        }
        let resolvedCurve = Self.sanitizedBezierCurve(curve)
        composition.cameraClips[clipIndex].keyframes[keyIndex].interpolation = .bezier
        composition.cameraClips[clipIndex].keyframes[keyIndex].bezierCurve = resolvedCurve
        selectedCameraKeyframes = [CompositionCameraKeyframeSelection(property: property, frame: frame)]
        selectedLayerKeyframes = []
        status = "已更新总摄像机贝塞尔曲线：\(property.title) @ \(frame)"
        applyInterpolatedPropertiesToEditableState()
    }

    func setLayerKeyframeBezierCurve(
        layerID: UUID,
        property: CompositionLayerKeyframeProperty,
        frame: Int,
        curve: CompositionBezierCurve,
        recordHistory: Bool = true
    ) {
        guard let layerIndex = composition.layers.firstIndex(where: { $0.id == layerID }) else { return }
        guard !composition.layers[layerIndex].isLocked else {
            status = "图层已锁定，无法修改贝塞尔曲线"
            return
        }
        guard let keyIndex = composition.layers[layerIndex].keyframes.firstIndex(where: {
            $0.property == property && $0.frame == frame
        }) else {
            return
        }
        if recordHistory {
            recordUndo()
        }
        let resolvedCurve = Self.sanitizedBezierCurve(curve)
        composition.layers[layerIndex].keyframes[keyIndex].interpolation = .bezier
        composition.layers[layerIndex].keyframes[keyIndex].bezierCurve = resolvedCurve
        selectedLayerID = layerID
        selectedLayerIDs = [layerID]
        selectedLayerKeyframes = [CompositionLayerKeyframeSelection(layerID: layerID, property: property, frame: frame)]
        selectedCameraKeyframes = []
        status = "已更新层贝塞尔曲线：\(composition.layers[layerIndex].name) \(property.title) @ \(frame)"
        applyInterpolatedPropertiesToEditableState()
    }

    private func selectedKeyframes() -> [(interpolation: CompositionKeyframeInterpolation, bezierCurve: CompositionBezierCurve)] {
        var result: [(interpolation: CompositionKeyframeInterpolation, bezierCurve: CompositionBezierCurve)] = []
        if !selectedCameraKeyframes.isEmpty, let clipIndex = selectedCameraClipIndex() {
            for selection in selectedCameraKeyframes {
                if let keyframe = composition.cameraClips[clipIndex].keyframes.first(where: {
                    $0.property == selection.property && $0.frame == selection.frame
                }) {
                    result.append((keyframe.interpolation, keyframe.bezierCurve))
                }
            }
        }

        for selection in selectedLayerKeyframes {
            if let keyframe = composition.layers
                .first(where: { $0.id == selection.layerID })?
                .keyframes
                .first(where: { $0.property == selection.property && $0.frame == selection.frame }) {
                result.append((keyframe.interpolation, keyframe.bezierCurve))
            }
        }
        return result
    }

    private func keyframeVelocityText(
        title: String,
        frame: Int,
        keyframes: [(frame: Int, value: Float, interpolation: CompositionKeyframeInterpolation)]
    ) -> String {
        let sorted = keyframes.sorted { lhs, rhs in
            lhs.frame == rhs.frame ? lhs.value < rhs.value : lhs.frame < rhs.frame
        }
        guard let index = sorted.firstIndex(where: { $0.frame == frame }) else {
            return "速度：未找到所选关键帧"
        }
        let current = sorted[index]
        if let next = sorted.dropFirst(index + 1).first {
            let deltaFrame = max(1, next.frame - current.frame)
            let velocity = (next.value - current.value) / Float(deltaFrame)
            if current.interpolation == .hold {
                return "\(title) | 保持到 \(next.frame) 帧后跳变 \(formatVelocityDelta(next.value - current.value))"
            }
            return "\(title) | → \(next.frame) | 平均速度 \(formatVelocity(velocity))/帧"
        }
        if index > 0 {
            let previous = sorted[index - 1]
            let deltaFrame = max(1, current.frame - previous.frame)
            let velocity = (current.value - previous.value) / Float(deltaFrame)
            if previous.interpolation == .hold {
                return "\(title) | ← \(previous.frame) | 前段为保持/跳变"
            }
            return "\(title) | ← \(previous.frame) | 平均速度 \(formatVelocity(velocity))/帧"
        }
        return "\(title) | 单个关键帧，暂无速度"
    }

    private func formatVelocity(_ value: Float) -> String {
        let absolute = abs(value)
        if absolute >= 100 {
            return String(format: "%.1f", value)
        }
        if absolute >= 1 {
            return String(format: "%.3f", value)
        }
        return String(format: "%.5f", value)
    }

    private func formatVelocityDelta(_ value: Float) -> String {
        let absolute = abs(value)
        if absolute >= 100 {
            return String(format: "%.1f", value)
        }
        if absolute >= 1 {
            return String(format: "%.3f", value)
        }
        return String(format: "%.5f", value)
    }

    func moveLayer(id: UUID, startFrame: Int) {
        guard let index = composition.layers.firstIndex(where: { $0.id == id }) else { return }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法移动"
            return
        }
        recordUndo()
        let oldStart = composition.layers[index].startFrame
        composition.layers[index].startFrame = startFrame
        let delta = composition.layers[index].startFrame - oldStart
        if delta != 0 {
            for keyIndex in composition.layers[index].keyframes.indices {
                composition.layers[index].keyframes[keyIndex].frame += delta
            }
        }
        clampLayer(at: index)
        selectedLayerID = id
        selectedLayerIDs = [id]
    }

    func trimLayerStart(id: UUID, startFrame: Int) {
        guard let index = composition.layers.firstIndex(where: { $0.id == id }) else { return }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法调整起点"
            return
        }
        recordUndo()
        let oldStart = composition.layers[index].startFrame
        let oldEnd = oldStart + composition.layers[index].duration
        let newStart = min(startFrame, oldEnd - 1)
        composition.layers[index].startFrame = newStart
        composition.layers[index].duration = max(1, oldEnd - newStart)
        clampLayer(at: index)
        selectedLayerID = id
    }

    func trimLayerEnd(id: UUID, endFrame: Int) {
        guard let index = composition.layers.firstIndex(where: { $0.id == id }) else { return }
        guard !composition.layers[index].isLocked else {
            status = "图层已锁定，无法调整时长"
            return
        }
        recordUndo()
        let start = composition.layers[index].startFrame
        let newEnd = max(start + 1, endFrame)
        composition.layers[index].duration = newEnd - start
        clampLayer(at: index)
        selectedLayerID = id
    }

    func moveCameraClip(id: UUID, startFrame: Int) {
        guard let index = composition.cameraClips.firstIndex(where: { $0.id == id }) else { return }
        recordUndo()
        let oldStart = composition.cameraClips[index].startFrame
        let delta = startFrame - oldStart
        composition.cameraClips[index].startFrame = startFrame
        for keyIndex in composition.cameraClips[index].keyframes.indices {
            composition.cameraClips[index].keyframes[keyIndex].frame += delta
        }
        clampCameraClips()
        selectedCameraClipID = id
        syncEditableCameraFromSelection()
    }

    func trimCameraClipStart(id: UUID, startFrame: Int) {
        guard let index = composition.cameraClips.firstIndex(where: { $0.id == id }) else { return }
        recordUndo()
        let oldStart = composition.cameraClips[index].startFrame
        let oldEnd = oldStart + composition.cameraClips[index].duration
        composition.cameraClips[index].startFrame = min(startFrame, oldEnd - 1)
        composition.cameraClips[index].duration = max(1, oldEnd - composition.cameraClips[index].startFrame)
        clampCameraClips()
        selectedCameraClipID = id
        syncEditableCameraFromSelection()
    }

    func trimCameraClipEnd(id: UUID, endFrame: Int) {
        guard let index = composition.cameraClips.firstIndex(where: { $0.id == id }) else { return }
        recordUndo()
        let start = composition.cameraClips[index].startFrame
        composition.cameraClips[index].duration = max(1, endFrame - start)
        clampCameraClips()
        selectedCameraClipID = id
        syncEditableCameraFromSelection()
    }

    func clampCompositionSettings() {
        sanitize(document: &composition)
        currentFrame = max(0, min(currentFrame, composition.frameCount - 1))
        let validLayerIDs = Set(composition.layers.map(\.id))
        openedPrecompositionLayerIDs = openedPrecompositionLayerIDs.intersection(validLayerIDs)
        for index in composition.layers.indices {
            clampLayer(at: index)
        }
        clampCameraClips()
        clampCompositionExportSettings()
    }

    func resetCompositionExportSettingsToComposition() {
        compositionExportSettings.width = composition.width
        compositionExportSettings.height = composition.height
        compositionExportSettings.fps = composition.fps
        compositionExportSettings.preserveAlpha = composition.backgroundTransparent
        compositionExportSettings.backgroundColor = composition.backgroundColor
        compositionExportSettings.startFrame = 0
        compositionExportSettings.endFrame = max(0, composition.frameCount - 1)
        clampCompositionExportSettings()
    }

    func clampCompositionExportSettings() {
        compositionExportSettings.width = max(1, compositionExportSettings.width)
        compositionExportSettings.height = max(1, compositionExportSettings.height)
        compositionExportSettings.fps = max(0.05, compositionExportSettings.fps)

        let lastFrame = max(0, composition.frameCount - 1)
        switch compositionExportSettings.rangeMode {
        case .full:
            compositionExportSettings.startFrame = 0
            compositionExportSettings.endFrame = lastFrame
        case .currentToEnd:
            compositionExportSettings.startFrame = max(0, min(currentFrame, lastFrame))
            compositionExportSettings.endFrame = lastFrame
        case .custom:
            compositionExportSettings.startFrame = max(0, min(compositionExportSettings.startFrame, lastFrame))
            compositionExportSettings.endFrame = max(0, min(compositionExportSettings.endFrame, lastFrame))
            if compositionExportSettings.endFrame < compositionExportSettings.startFrame {
                compositionExportSettings.endFrame = compositionExportSettings.startFrame
            }
        }
    }

    func bindingForSelectedLayer() -> Binding<CompositionLayer>? {
        guard let selectedLayerID,
              let selectedLayer = composition.layers.first(where: { $0.id == selectedLayerID }) else {
            return nil
        }
        let fallback = selectedLayer
        return Binding(
            get: {
                self.composition.layers.first(where: { $0.id == selectedLayerID }) ?? fallback
            },
            set: { newValue in
                guard let index = self.composition.layers.firstIndex(where: { $0.id == selectedLayerID }) else {
                    return
                }
                guard !self.composition.layers[index].isLocked else {
                    self.status = "图层已锁定，无法修改"
                    return
                }
                self.composition.layers[index] = newValue
                self.clampLayer(at: index)
            }
        )
    }

    func bindingForLayer(id: UUID) -> Binding<CompositionLayer>? {
        guard let selectedLayer = composition.layers.first(where: { $0.id == id }) else {
            return nil
        }
        let fallback = selectedLayer
        return Binding(
            get: {
                self.composition.layers.first(where: { $0.id == id }) ?? fallback
            },
            set: { newValue in
                guard let index = self.composition.layers.firstIndex(where: { $0.id == id }) else {
                    return
                }
                guard !self.composition.layers[index].isLocked else {
                    self.status = "图层已锁定，无法修改"
                    return
                }
                self.composition.layers[index] = newValue
                self.clampLayer(at: index)
            }
        )
    }

    func activeRenderLayers() -> [CompositionRenderLayer] {
        renderLayers(at: currentFrame)
    }

    func renderLayers(at frame: Int) -> [CompositionRenderLayer] {
        renderLayers(
            from: composition.layers,
            at: frame,
            parentMatrix: matrix_identity_float4x4,
            opacityMultiplier: 1,
            seenPrecompositions: []
        )
    }

    private func renderLayers(
        from layers: [CompositionLayer],
        at frame: Int,
        parentMatrix: simd_float4x4,
        opacityMultiplier: Float,
        seenPrecompositions: Set<UUID>
    ) -> [CompositionRenderLayer] {
        let hasSolo = layers.contains(where: \.isSolo)
        let activeLayers = layers
            .filter { $0.isVisible && (!hasSolo || $0.isSolo) && isLayer($0, activeAt: frame) }

        var renderLayers: [CompositionRenderLayer] = []
        var skipTargetIDs = Set<UUID>()

        for index in activeLayers.indices {
            let layer = activeLayers[index]
            guard !skipTargetIDs.contains(layer.id) else { continue }

            if layer.blendMode == .alphaTrackMatte {
                guard index + 1 < activeLayers.count else { continue }
                let target = activeLayers[index + 1]
                guard target.blendMode != .alphaTrackMatte else { continue }
                skipTargetIDs.insert(target.id)
                renderLayers.append(
                    contentsOf: contentsOrRenderLayer(
                        from: target,
                        at: frame,
                        parentMatrix: parentMatrix,
                        opacityMultiplier: opacityMultiplier,
                        seenPrecompositions: seenPrecompositions,
                        trackMatte: layer
                    )
                )
                continue
            }

            renderLayers.append(
                contentsOf: contentsOrRenderLayer(
                    from: layer,
                    at: frame,
                    parentMatrix: parentMatrix,
                    opacityMultiplier: opacityMultiplier,
                    seenPrecompositions: seenPrecompositions,
                    trackMatte: nil
                )
            )
        }

        return Array(renderLayers.reversed())
    }

    private func contentsOrRenderLayer(
        from layer: CompositionLayer,
        at frame: Int,
        parentMatrix: simd_float4x4,
        opacityMultiplier: Float,
        seenPrecompositions: Set<UUID>,
        trackMatte: CompositionLayer?
    ) -> [CompositionRenderLayer] {
        guard trackMatte == nil,
              let nested = compositionDocument(forReferenceID: layer.assetID),
              !seenPrecompositions.contains(layer.assetID),
              layer.assetID == Self.rootCompositionAssetID || assets.first(where: { $0.id == layer.assetID })?.isPrecomposition == true else {
            return [
                makeRenderLayer(
                    from: layer,
                    at: frame,
                    parentMatrix: parentMatrix,
                    opacityMultiplier: opacityMultiplier,
                    trackMatte: trackMatte
                )
            ]
        }

        let resolved = resolvedLayer(layer, at: frame)
        var nextSeen = seenPrecompositions
        nextSeen.insert(layer.assetID)
        let localFrame = frame - layer.startFrame
        let nextParentMatrix = parentMatrix * compositionVolumeTransformMatrix(resolved.transform)
        let nextOpacityMultiplier = opacityMultiplier * resolved.opacity
        return renderLayers(
            from: nested.layers,
            at: localFrame,
            parentMatrix: nextParentMatrix,
            opacityMultiplier: nextOpacityMultiplier,
            seenPrecompositions: nextSeen
        )
    }

    private func resolvedLayer(_ layer: CompositionLayer, at frame: Int) -> CompositionLayer {
        var resolved = layer
        resolved.transform = interpolatedTransform(for: layer, at: frame)
        resolved.opacity = interpolatedOpacity(for: layer, at: frame)
        return resolved
    }

    private func makeRenderLayer(
        from layer: CompositionLayer,
        at frame: Int,
        parentMatrix: simd_float4x4,
        opacityMultiplier: Float,
        trackMatte: CompositionLayer?
    ) -> CompositionRenderLayer {
        let transform = interpolatedTransform(for: layer, at: frame)
        let matteTransform = trackMatte.map { interpolatedTransform(for: $0, at: frame) }
        let modifiers = resolvedModifiers(layer.modifiers, at: frame)
        let matteModifiers = trackMatte.map { resolvedModifiers($0.modifiers, at: frame) } ?? []
        let usesModifiedTexture = !isPrecompositionLayer(layer) &&
            VolumeModifierRasterizer.hasActiveModifiers(modifiers)
        let matteUsesModifiedTexture = trackMatte.map {
            !isPrecompositionLayer($0) && VolumeModifierRasterizer.hasActiveModifiers(matteModifiers)
        } ?? false
        return CompositionRenderLayer(
            id: layer.id,
            assetID: layer.assetID,
            textureID: usesModifiedTexture ? layer.id : layer.assetID,
            modifiers: modifiers,
            transform: transform,
            transformMatrix: parentMatrix * compositionVolumeTransformMatrix(transform),
            blendMode: layer.blendMode,
            volumeRenderMode: layer.volumeRenderMode,
            opacity: opacityMultiplier * interpolatedOpacity(for: layer, at: frame),
            trackMatteAssetID: trackMatte?.assetID,
            trackMatteTextureID: trackMatte.map { matteUsesModifiedTexture ? $0.id : $0.assetID },
            trackMatteModifiers: matteModifiers,
            trackMatteTransform: matteTransform,
            trackMatteTransformMatrix: matteTransform.map {
                parentMatrix * compositionVolumeTransformMatrix($0)
            },
            trackMatteOpacity: trackMatte.map { interpolatedOpacity(for: $0, at: frame) } ?? 1
        )
    }

    func renderCamera() -> CameraRigState {
        renderCamera(at: currentFrame)
    }

    func renderCamera(at frame: Int) -> CameraRigState {
        renderCamera(clipID: nil, at: frame)
    }

    func renderCamera(clipID: UUID?, at frame: Int) -> CameraRigState {
        let requestedClip = clipID.flatMap { id in
            composition.cameraClips.first { $0.id == id && $0.isVisible }
        }
        let selectedClip = clipID == nil
            ? selectedCameraClipID.flatMap { id in
                composition.cameraClips.first { $0.id == id && $0.isVisible }
            }
            : nil
        guard let clip = requestedClip
                ?? selectedClip
                ?? activeCameraClip(at: frame)
                ?? composition.cameraClips.first(where: { $0.isVisible }) else {
            return compositionCamera
        }
        return interpolatedCamera(clip: clip, at: frame) ?? clip.camera
    }

    func activeCameraClips(at frame: Int? = nil) -> [CompositionCameraClip] {
        let frame = frame ?? currentFrame
        return composition.cameraClips.filter { $0.isVisible && isCameraClip($0, activeAt: frame) }
    }

    func activeCameraClip(at frame: Int? = nil) -> CompositionCameraClip? {
        activeCameraClips(at: frame).first
    }

    func visibleCameraClips() -> [CompositionCameraClip] {
        composition.cameraClips.filter(\.isVisible)
    }

    func isCameraClipVisible(id: UUID) -> Bool {
        composition.cameraClips.first(where: { $0.id == id })?.isVisible ?? false
    }

    func cameraClipName(id: UUID) -> String {
        composition.cameraClips.first(where: { $0.id == id })?.name ?? "摄像机"
    }

    func exportCompositionInteractively() {
        guard !isCompositionExporting || isCompositionRenderQueueRunning else { return }
        syncActiveCompositionIntoStorage()
        guard composition.layers.contains(where: { $0.isVisible && (!composition.layers.contains(where: \.isSolo) || $0.isSolo) }) else {
            status = "没有可见图层可导出"
            return
        }

        clampCompositionExportSettings()
        isShowingCompositionExportSettingsSheet = true
    }

    func confirmCompositionExportSettings() {
        guard !isCompositionExporting else { return }
        clampCompositionExportSettings()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(composition.name)_composition.mov"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            status = "合成导出已取消"
            return
        }
        isShowingCompositionExportSettingsSheet = false
        startCompositionExport(url: url, settings: compositionExportSettings)
    }

    private func startCompositionExport(url: URL, settings: CompositionExportSettings) {
        stopPlayback()
        isCompositionExporting = true
        let sourceDescription = settings.sourceMode == .highPrecision ? "检查高精度缓存" : "准备代理素材"
        status = "合成导出准备中：\(sourceDescription)"

        Task {
            do {
                let request = try await makeCompositionVideoExportRequest(url: url, settings: settings)

                try await Task.detached(priority: .userInitiated) {
                    try CompositionVideoExporter.export(request: request) { progress, route in
                        Task { @MainActor in
                            self.status = "\(route ?? "合成导出") \(Int((progress * 100).rounded()))%"
                        }
                    }
                }.value

                isCompositionExporting = false
                status = "合成导出完成：\(url.lastPathComponent)"
            } catch {
                if handleCompositionTextureBottleneck(error, url: url, settings: settings) {
                    return
                }
                isCompositionExporting = false
                recordDiagnosticEvent(
                    severity: "error",
                    category: "合成导出",
                    message: "合成导出失败",
                    details: error.localizedDescription,
                    includeCallStack: true
                )
                status = "合成导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func startSegmentedCompositionExport(url: URL, settings: CompositionExportSettings) {
        stopPlayback()
        isCompositionExporting = true
        status = "高精度分段式导出准备中"

        Task {
            do {
                var request = try await makeCompositionVideoExportRequest(url: url, settings: settings)
                request.textureUploadMode = .segmented

                try await Task.detached(priority: .userInitiated) {
                    try await CompositionVideoExporter.exportInSegments(request: request) { progress, route in
                        Task { @MainActor in
                            self.status = "\(route ?? "高精度分段式导出") \(Int((progress * 100).rounded()))%"
                        }
                    }
                }.value

                isCompositionExporting = false
                status = "高精度分段式导出完成：\(url.lastPathComponent)"
            } catch {
                isCompositionExporting = false
                recordDiagnosticEvent(
                    severity: "error",
                    category: "合成导出",
                    message: "高精度分段式导出失败",
                    details: error.localizedDescription,
                    includeCallStack: true
                )
                status = "高精度分段式导出失败：\(error.localizedDescription)"
            }
        }
    }

    private func makeCompositionVideoExportRequest(
        url: URL,
        settings: CompositionExportSettings
    ) async throws -> CompositionVideoExportRequest {
        let exportAssets: [CompositionVideoExportAsset]
        switch settings.sourceMode {
        case .highPrecision:
            exportAssets = try await prepareHighPrecisionExportAssets()
        case .proxy:
            exportAssets = prepareProxyExportAssets()
        }
        guard !exportAssets.isEmpty else {
            throw VideoExportError.createReaderFailed("没有已导入完成的素材可导出")
        }

        let bitDepth = settings.bitDepth.resolved(sourceBitDepth: sourceBitDepthForCompositionExport())
        let colorProfile = settings.colorProfile.resolved(source: sourceColorProfileForCompositionExport())
        let backgroundColor = settings.backgroundMode == .composition
            ? composition.backgroundColor
            : settings.backgroundColor
        let frameCount = max(1, settings.endFrame - settings.startFrame + 1)
        return CompositionVideoExportRequest(
            url: url,
            width: settings.width,
            height: settings.height,
            fps: settings.fps,
            startFrame: settings.startFrame,
            frameCount: frameCount,
            bitDepth: bitDepth,
            colorProfile: colorProfile,
            backgroundColor: backgroundColor,
            preserveAlpha: settings.preserveAlpha,
            assets: exportAssets,
            precompositions: precompositionMap(),
            layers: composition.layers,
            cameraClips: composition.cameraClips,
            fallbackCamera: compositionCamera
        )
    }

    private func handleCompositionTextureBottleneck(
        _ error: Error,
        url: URL,
        settings: CompositionExportSettings
    ) -> Bool {
        guard let exportError = error as? VideoExportError,
              exportError.isTextureBottleneck else {
            return false
        }
        isCompositionExporting = false

        let alert = NSAlert()
        alert.messageText = "高精度导出遇到体纹理瓶颈"
        alert.informativeText = "\(error.localizedDescription)\n\n请选择接下来的处理方式。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "停止")
        alert.addButton(withTitle: "降采样")
        alert.addButton(withTitle: "高精度分段式导出")
        let response = alert.runModal()

        switch response {
        case .alertSecondButtonReturn:
            guard settings.sourceMode != .proxy else {
                status = "合成导出已停止：代理预览体纹理仍然过大"
                return true
            }
            var proxySettings = settings
            proxySettings.sourceMode = .proxy
            status = "已选择降采样：改用代理预览导出"
            startCompositionExport(url: url, settings: proxySettings)
        case .alertThirdButtonReturn:
            var segmentedSettings = settings
            segmentedSettings.sourceMode = .highPrecision
            status = "已选择高精度分段式导出"
            startSegmentedCompositionExport(url: url, settings: segmentedSettings)
        default:
            status = "合成导出已停止：遇到体纹理瓶颈"
        }
        return true
    }

    private func enqueueCompositionExport(url: URL, settings: CompositionExportSettings) {
        let precompositions = precompositionMap()
        let assetIDs = exportPreparationAssetIDs(
            from: composition.layers,
            precompositions: precompositions,
            includeAllAssetsWhenNoLayers: false
        )
        let job = CompositionRenderQueueJob(
            id: UUID(),
            title: composition.name,
            outputURL: url,
            settings: settings,
            layers: composition.layers,
            cameraClips: composition.cameraClips,
            fallbackCamera: compositionCamera,
            precompositions: precompositions,
            assetIDs: assetIDs,
            status: .queued,
            progress: 0,
            route: "等待开始",
            createdAt: Date(),
            startedAt: nil,
            completedAt: nil,
            errorMessage: nil,
            logURL: nil,
            logLines: ["\(Self.queueLogTimestamp()) 已加入队列：\(url.lastPathComponent)"]
        )
        compositionRenderQueue.append(job)
        status = "已加入渲染队列：\(url.lastPathComponent)"
        runCompositionRenderQueueIfNeeded()
    }

    private func runCompositionRenderQueueIfNeeded() {
        guard !isCompositionRenderQueuePaused,
              !isCompositionExporting,
              !isCompositionRenderQueueRunning,
              let nextID = compositionRenderQueue.first(where: { $0.status == .queued })?.id else {
            return
        }
        startCompositionRenderQueueJob(id: nextID)
    }

    private func startCompositionRenderQueueJob(id: UUID) {
        guard let index = compositionRenderQueue.firstIndex(where: { $0.id == id }),
              compositionRenderQueue[index].status == .queued else {
            return
        }

        stopPlayback()
        isCompositionExporting = true
        compositionRenderQueue[index].status = .running
        compositionRenderQueue[index].progress = 0
        compositionRenderQueue[index].startedAt = Date()
        compositionRenderQueue[index].route = "准备素材"
        appendRenderQueueLog(jobID: id, "开始渲染")
        status = "渲染队列：\(compositionRenderQueue[index].title) 准备中"

        let job = compositionRenderQueue[index]
        Task {
            do {
                let exportAssets: [CompositionVideoExportAsset]
                switch job.settings.sourceMode {
                case .highPrecision:
                    updateRenderQueueJobRoute(id: id, route: "检查高精度 raw cache")
                    exportAssets = try await prepareHighPrecisionExportAssets(assetIDs: job.assetIDs)
                case .proxy:
                    updateRenderQueueJobRoute(id: id, route: "准备代理素材")
                    exportAssets = prepareProxyExportAssets(assetIDs: job.assetIDs)
                }

                guard !exportAssets.isEmpty else {
                    throw VideoExportError.createReaderFailed("没有已导入完成的素材可导出")
                }

                let bitDepth = job.settings.bitDepth.resolved(sourceBitDepth: sourceBitDepthForCompositionExport(assetIDs: job.assetIDs))
                let colorProfile = job.settings.colorProfile.resolved(source: sourceColorProfileForCompositionExport(assetIDs: job.assetIDs))
                let backgroundColor = job.settings.backgroundMode == .composition
                    ? (job.precompositions[Self.rootCompositionAssetID]?.backgroundColor ?? composition.backgroundColor)
                    : job.settings.backgroundColor
                let frameCount = max(1, job.settings.endFrame - job.settings.startFrame + 1)
                let request = CompositionVideoExportRequest(
                    url: job.outputURL,
                    width: job.settings.width,
                    height: job.settings.height,
                    fps: job.settings.fps,
                    startFrame: job.settings.startFrame,
                    frameCount: frameCount,
                    bitDepth: bitDepth,
                    colorProfile: colorProfile,
                    backgroundColor: backgroundColor,
                    preserveAlpha: job.settings.preserveAlpha,
                    assets: exportAssets,
                    precompositions: job.precompositions,
                    layers: job.layers,
                    cameraClips: job.cameraClips,
                    fallbackCamera: job.fallbackCamera
                )

                let startTime = Date()
                try await Task.detached(priority: .userInitiated) {
                    try CompositionVideoExporter.export(request: request) { progress, route in
                        Task { @MainActor in
                            self.updateRenderQueueJobProgress(
                                id: id,
                                progress: progress,
                                route: route ?? "合成导出"
                            )
                        }
                    }
                }.value

                finishCompositionRenderQueueJob(
                    id: id,
                    status: .completed,
                    errorMessage: nil,
                    renderSeconds: Date().timeIntervalSince(startTime)
                )
            } catch {
                finishCompositionRenderQueueJob(
                    id: id,
                    status: .failed,
                    errorMessage: error.localizedDescription,
                    renderSeconds: nil
                )
            }
        }
    }

    private func updateRenderQueueJobProgress(id: UUID, progress: Double, route: String) {
        guard let index = compositionRenderQueue.firstIndex(where: { $0.id == id }) else { return }
        compositionRenderQueue[index].progress = min(1, max(0, progress))
        compositionRenderQueue[index].route = route
        status = "渲染队列：\(compositionRenderQueue[index].title) \(Int((progress * 100).rounded()))%"
    }

    private func updateRenderQueueJobRoute(id: UUID, route: String) {
        guard let index = compositionRenderQueue.firstIndex(where: { $0.id == id }) else { return }
        compositionRenderQueue[index].route = route
        status = "渲染队列：\(compositionRenderQueue[index].title) \(route)"
        appendRenderQueueLog(jobID: id, route)
    }

    private func finishCompositionRenderQueueJob(
        id: UUID,
        status finalStatus: CompositionRenderQueueJobStatus,
        errorMessage: String?,
        renderSeconds: TimeInterval?
    ) {
        guard let index = compositionRenderQueue.firstIndex(where: { $0.id == id }) else {
            isCompositionExporting = false
            runCompositionRenderQueueIfNeeded()
            return
        }

        compositionRenderQueue[index].status = finalStatus
        compositionRenderQueue[index].progress = finalStatus == .completed ? 1 : compositionRenderQueue[index].progress
        compositionRenderQueue[index].completedAt = Date()
        compositionRenderQueue[index].errorMessage = errorMessage
        compositionRenderQueue[index].route = finalStatus == .completed ? "完成" : "失败"
        appendRenderQueueLog(
            jobID: id,
            finalStatus == .completed
                ? "渲染完成，用时 \(Self.queueDurationText(renderSeconds ?? 0))"
                : "渲染失败：\(errorMessage ?? "未知错误")"
        )
        if finalStatus == .failed {
            recordDiagnosticEvent(
                severity: "error",
                category: "渲染队列",
                message: "渲染队列任务失败：\(compositionRenderQueue[index].title)",
                details: errorMessage,
                includeCallStack: true
            )
        }

        if let logURL = writeCompositionRenderQueueLog(job: compositionRenderQueue[index]) {
            compositionRenderQueue[index].logURL = logURL
            appendRenderQueueLog(jobID: id, "诊断日志已保存：\(logURL.lastPathComponent)")
        }

        isCompositionExporting = false
        self.status = finalStatus == .completed
            ? "渲染队列完成：\(compositionRenderQueue[index].outputURL.lastPathComponent)"
            : "渲染队列失败：\(errorMessage ?? "未知错误")"

        runCompositionRenderQueueIfNeeded()
    }

    private func appendRenderQueueLog(jobID: UUID, _ message: String) {
        guard let index = compositionRenderQueue.firstIndex(where: { $0.id == jobID }) else { return }
        compositionRenderQueue[index].logLines.append("\(Self.queueLogTimestamp()) \(message)")
    }

    private func writeCompositionRenderQueueLog(job: CompositionRenderQueueJob) -> URL? {
        let baseName = job.outputURL.deletingPathExtension().lastPathComponent
        let stamp = Self.queueLogFileTimestamp()
        let logURL = job.outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName)_render_queue_log_\(stamp).json")

        let document = CompositionRenderQueueLogDocument(
            jobID: job.id,
            title: job.title,
            status: job.status.title,
            outputPath: job.outputURL.path,
            logCreatedAt: Date(),
            createdAt: job.createdAt,
            startedAt: job.startedAt,
            completedAt: job.completedAt,
            durationSeconds: job.startedAt.flatMap { started in job.completedAt?.timeIntervalSince(started) },
            progress: job.progress,
            route: job.route,
            errorMessage: job.errorMessage,
            settings: job.settings,
            compositionName: job.title,
            layerCount: job.layers.count,
            cameraCount: job.cameraClips.count,
            assetIDs: job.assetIDs,
            assetSummaries: renderQueueAssetSummaries(assetIDs: job.assetIDs),
            performance: CompositionRenderQueueLogDocument.PerformanceSummary(
                previewFPS: performanceSnapshot.previewFPS,
                textureHitRate: performanceSnapshot.textureHitRate,
                rawCacheHitRate: performanceSnapshot.rawCacheHitRate,
                estimatedTextureMemoryBytes: performanceSnapshot.estimatedTextureMemoryBytes,
                appMemoryBytes: performanceSnapshot.appMemoryBytes,
                memoryPressureText: performanceSnapshot.memoryPressureText
            ),
            logLines: job.logLines
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: logURL, options: .atomic)
            return logURL
        } catch {
            recordDiagnosticEvent(
                severity: "warning",
                category: "渲染队列",
                message: "渲染队列日志写入失败",
                details: error.localizedDescription,
                includeCallStack: true
            )
            return nil
        }
    }

    private func renderQueueAssetSummaries(assetIDs: [UUID]) -> [CompositionRenderQueueLogDocument.AssetSummary] {
        assetIDs.compactMap { id in
            guard let asset = assets.first(where: { $0.id == id && $0.isVideo }) else { return nil }
            let preserveAlpha = requiredHighPrecisionCachePreserveAlpha(for: asset)
            return CompositionRenderQueueLogDocument.AssetSummary(
                id: asset.id,
                name: asset.name,
                path: asset.url.path,
                width: asset.sourceWidth,
                height: asset.sourceHeight,
                frameCount: asset.sourceFrameCount,
                bitDepth: asset.sourceBitDepth,
                hasAlpha: asset.previewVolume?.hasMeaningfulAlpha ?? false,
                rawCacheReady: HighPrecisionCacheHelper.hasCache(for: asset.url, preserveAlpha: preserveAlpha)
            )
        }
    }

    private func writeDiagnosticsPackage(to requestedURL: URL) throws -> URL {
        syncActiveCompositionIntoStorage()
        refreshPerformanceDiagnostics()

        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: requestedURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NSError(
                    domain: "ChronoVolume.Diagnostics",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "目标路径已经是文件，请选择新的诊断包名称"]
                )
            }
        } else {
            try fileManager.createDirectory(at: requestedURL, withIntermediateDirectories: true)
        }

        let document = makeDiagnosticsDocument()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try encoder.encode(document)
            .write(to: requestedURL.appendingPathComponent("diagnostics.json"), options: .atomic)
        try encoder.encode(document.projectSummary)
            .write(to: requestedURL.appendingPathComponent("project-summary.json"), options: .atomic)
        try encoder.encode(document.projectSnapshot)
            .write(to: requestedURL.appendingPathComponent("project-snapshot.json"), options: .atomic)
        try makeDiagnosticsPlainText(document)
            .write(to: requestedURL.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try makeRecentErrorsText(document.recentErrors)
            .write(to: requestedURL.appendingPathComponent("recent-errors.log"), atomically: true, encoding: .utf8)
        return requestedURL
    }

    private func makeDiagnosticsDocument() -> CompositionDiagnosticsDocument {
        let projectSnapshot = makeProjectState()
        let snapshot = performanceSnapshot
        let projectSummary = CompositionDiagnosticsDocument.ProjectSummary(
            projectFilePath: projectFilePathForDiagnostics,
            status: status,
            activeCompositionName: activeCompositionName,
            isEditingRootComposition: isEditingRootComposition,
            width: composition.width,
            height: composition.height,
            frameCount: composition.frameCount,
            fps: composition.fps,
            currentFrame: currentFrame,
            assetCount: assets.count,
            videoAssetCount: videoAssets.count,
            precompositionCount: precompositionAssets.count,
            layerCount: composition.layers.count,
            cameraClipCount: composition.cameraClips.count,
            layerKeyframeCount: composition.layers.reduce(0) { $0 + $1.keyframes.count },
            cameraKeyframeCount: composition.cameraClips.reduce(0) { $0 + $1.keyframes.count },
            selectedLayerIDs: Array(selectedLayerIDs),
            selectedCameraClipID: selectedCameraClipID,
            renderQueueSummary: compositionRenderQueueSummaryText
        )

        let assetSummaries = assets.map { asset in
            let fileExists = asset.isPrecomposition || FileManager.default.fileExists(atPath: asset.url.path)
            let alphaStatus: String
            if let previewVolume = asset.previewVolume {
                alphaStatus = previewVolume.hasMeaningfulAlpha ? "检测到有效 Alpha" : "无有效 Alpha"
            } else if asset.isPrecomposition {
                alphaStatus = "预合成"
            } else {
                alphaStatus = "未检测"
            }

            let proxyStatus: String
            let rawCacheStatus: String
            let rawCacheSizeBytes: Int64
            let rawCacheSizeText: String
            if asset.isVideo {
                proxyStatus = proxyCacheInspection(for: asset).statusText
                let raw = highPrecisionCacheInspection(for: asset)
                rawCacheStatus = raw.statusText
                rawCacheSizeBytes = raw.sizeBytes
                rawCacheSizeText = byteCountText(raw.sizeBytes)
            } else {
                proxyStatus = "预合成：无需代理缓存"
                rawCacheStatus = "预合成：无需 raw cache"
                rawCacheSizeBytes = 0
                rawCacheSizeText = "0 KB"
            }

            return CompositionDiagnosticsDocument.AssetSummary(
                id: asset.id,
                kind: asset.kind.rawValue,
                name: asset.name,
                path: asset.url.path,
                fileExists: fileExists,
                sourceFileMissing: asset.sourceFileMissing,
                sourceWidth: asset.sourceWidth,
                sourceHeight: asset.sourceHeight,
                sourceFrameCount: asset.sourceFrameCount,
                sourceFPS: asset.sourceFPS,
                sourceBitDepth: asset.sourceBitDepth,
                alphaStatus: alphaStatus,
                proxyStatus: proxyStatus,
                rawCacheStatus: rawCacheStatus,
                rawCacheSizeBytes: rawCacheSizeBytes,
                rawCacheSizeText: rawCacheSizeText,
                exportCacheState: asset.exportCacheState.rawValue,
                exportCacheMessage: asset.exportCacheMessage
            )
        }

        let cacheSummaries = cachePolicyItems.map {
            CompositionDiagnosticsDocument.CacheSummary(
                assetID: $0.id,
                name: $0.name,
                path: $0.path,
                sourceText: $0.sourceText,
                sourceMissing: $0.sourceMissing,
                proxyStatusText: $0.proxyStatusText,
                proxyDetailText: $0.proxyDetailText,
                proxyNeedsBuild: $0.proxyNeedsBuild,
                proxyIsExpired: $0.proxyIsExpired,
                highPrecisionStatusText: $0.highPrecisionStatusText,
                highPrecisionDetailText: $0.highPrecisionDetailText,
                highPrecisionNeedsBuild: $0.highPrecisionNeedsBuild,
                highPrecisionIsExpired: $0.highPrecisionIsExpired,
                requiredHighPrecisionAlpha: $0.requiredHighPrecisionAlpha,
                cacheSizeBytes: $0.cacheSizeBytes,
                cacheSizeText: $0.cacheSizeText
            )
        }

        let renderQueueSummaries = compositionRenderQueue.map {
            CompositionDiagnosticsDocument.RenderQueueSummary(
                id: $0.id,
                title: $0.title,
                outputPath: $0.outputURL.path,
                settings: $0.settings,
                status: $0.status.rawValue,
                progress: $0.progress,
                route: $0.route,
                createdAt: $0.createdAt,
                startedAt: $0.startedAt,
                completedAt: $0.completedAt,
                errorMessage: $0.errorMessage,
                logPath: $0.logURL?.path,
                logLines: $0.logLines
            )
        }

        let performance = CompositionDiagnosticsDocument.PerformanceSummary(
            previewFPS: snapshot.previewFPS,
            previewPathText: snapshot.previewPathText,
            sourcePathText: snapshot.sourcePathText,
            drawableText: snapshot.drawableText,
            activeLayerCount: snapshot.activeLayerCount,
            textureHitCount: snapshot.textureHitCount,
            textureMissCount: snapshot.textureMissCount,
            textureHitRate: snapshot.textureHitRate,
            rawCacheHitCount: snapshot.rawCacheHitCount,
            rawCacheMissCount: snapshot.rawCacheMissCount,
            rawCacheHitRate: snapshot.rawCacheHitRate,
            estimatedTextureMemoryBytes: snapshot.estimatedTextureMemoryBytes,
            appMemoryBytes: snapshot.appMemoryBytes,
            appMemoryText: byteCountText(snapshot.appMemoryBytes),
            physicalMemoryBytes: snapshot.physicalMemoryBytes,
            physicalMemoryText: byteCountText(snapshot.physicalMemoryBytes),
            memoryPressureText: snapshot.memoryPressureText,
            memoryPressureLevel: snapshot.memoryPressureLevel,
            updatedAt: snapshot.updatedAt
        )

        let processInfo = ProcessInfo.processInfo
        let environment = CompositionDiagnosticsDocument.EnvironmentSummary(
            operatingSystemVersion: processInfo.operatingSystemVersionString,
            hostName: Host.current().localizedName ?? "-",
            processorCount: processInfo.processorCount,
            activeProcessorCount: processInfo.activeProcessorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            physicalMemoryText: byteCountText(processInfo.physicalMemory)
        )

        return CompositionDiagnosticsDocument(
            generatedAt: Date(),
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ChronoVolume",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-",
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-",
            projectSummary: projectSummary,
            assets: assetSummaries,
            cache: cacheSummaries,
            exportSettings: compositionExportSettings,
            renderQueue: renderQueueSummaries,
            recentErrors: recentDiagnosticEvents,
            performance: performance,
            environment: environment,
            projectSnapshot: projectSnapshot
        )
    }

    private func makeDiagnosticsPlainText(_ document: CompositionDiagnosticsDocument) -> String {
        var lines: [String] = []
        lines.append("ChronoVolume 诊断包")
        lines.append("生成时间：\(document.generatedAt)")
        lines.append("")
        lines.append("项目摘要")
        lines.append("- 项目文件：\(document.projectSummary.projectFilePath ?? "未保存或未知")")
        lines.append("- 当前状态：\(document.projectSummary.status)")
        lines.append("- 当前合成：\(document.projectSummary.activeCompositionName)")
        lines.append("- 尺寸/帧数/FPS：\(document.projectSummary.width) × \(document.projectSummary.height) / \(document.projectSummary.frameCount) / \(String(format: "%.2f", document.projectSummary.fps))")
        lines.append("- 当前时间码：\(document.projectSummary.currentFrame)")
        lines.append("- 素材/预合成/图层/摄像机：\(document.projectSummary.videoAssetCount) / \(document.projectSummary.precompositionCount) / \(document.projectSummary.layerCount) / \(document.projectSummary.cameraClipCount)")
        lines.append("- 关键帧：图层 \(document.projectSummary.layerKeyframeCount)，摄像机 \(document.projectSummary.cameraKeyframeCount)")
        lines.append("")
        lines.append("素材路径状态")
        for asset in document.assets {
            lines.append("- \(asset.name) [\(asset.kind)] \(asset.fileExists ? "存在" : "丢失")")
            lines.append("  \(asset.path)")
            lines.append("  源：\(asset.sourceWidth) × \(asset.sourceHeight) × \(asset.sourceFrameCount), \(asset.sourceBitDepth)-bit, \(asset.alphaStatus)")
            lines.append("  代理：\(asset.proxyStatus)")
            lines.append("  raw cache：\(asset.rawCacheStatus)，\(asset.rawCacheSizeText)")
        }
        lines.append("")
        lines.append("导出设置")
        lines.append("- 尺寸/FPS：\(document.exportSettings.width) × \(document.exportSettings.height) / \(String(format: "%.2f", document.exportSettings.fps))")
        lines.append("- Bit/Alpha/素材：\(document.exportSettings.bitDepth.rawValue) / \(document.exportSettings.preserveAlpha) / \(document.exportSettings.sourceMode.rawValue)")
        lines.append("- 范围：\(document.exportSettings.rangeMode.rawValue) \(document.exportSettings.startFrame)...\(document.exportSettings.endFrame)")
        lines.append("")
        lines.append("性能诊断")
        lines.append("- 预览 FPS：\(String(format: "%.1f", document.performance.previewFPS))")
        lines.append("- 路径：\(document.performance.previewPathText)")
        lines.append("- 缓存命中：纹理 \(String(format: "%.1f%%", document.performance.textureHitRate * 100))，raw \(String(format: "%.1f%%", document.performance.rawCacheHitRate * 100))")
        lines.append("- 内存：\(document.performance.appMemoryText) / \(document.performance.physicalMemoryText)，\(document.performance.memoryPressureText)")
        lines.append("")
        lines.append("最近错误")
        if document.recentErrors.isEmpty {
            lines.append("- 暂无捕获到的错误事件")
        } else {
            for event in document.recentErrors {
                lines.append("- [\(event.severity)] \(event.date) \(event.category)：\(event.message)")
                if let details = event.details, !details.isEmpty {
                    lines.append("  \(details)")
                }
            }
        }
        lines.append("")
        lines.append("完整机器可读数据见 diagnostics.json；项目快照见 project-snapshot.json。")
        return lines.joined(separator: "\n") + "\n"
    }

    private func makeRecentErrorsText(_ events: [CompositionDiagnosticEvent]) -> String {
        guard !events.isEmpty else {
            return "暂无捕获到的错误事件。\n"
        }

        return events.map { event in
            var lines: [String] = []
            lines.append("[\(event.severity)] \(event.date) \(event.category)：\(event.message)")
            if let details = event.details, !details.isEmpty {
                lines.append(details)
            }
            if !event.callStack.isEmpty {
                lines.append("Call Stack:")
                lines.append(contentsOf: event.callStack)
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n---\n\n") + "\n"
    }

    private func recordDiagnosticEvent(
        severity: String,
        category: String,
        message: String,
        details: String? = nil,
        includeCallStack: Bool = false
    ) {
        recentDiagnosticEvents.insert(
            CompositionDiagnosticEvent(
                id: UUID(),
                date: Date(),
                severity: severity,
                category: category,
                message: message,
                details: details,
                callStack: includeCallStack ? Thread.callStackSymbols : []
            ),
            at: 0
        )
        if recentDiagnosticEvents.count > 80 {
            recentDiagnosticEvents.removeLast(recentDiagnosticEvents.count - 80)
        }
    }

    private static func queueLogTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static func queueLogFileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func safeDiagnosticsFileStem(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let stem = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "ChronoVolume" : stem
    }

    private static func queueDurationText(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1f 秒", seconds)
        }
        return String(format: "%.1f 分", seconds / 60)
    }

    private func sourceBitDepthForCompositionExport() -> Int {
        let ids = Set(exportPreparationAssetIDs(includeAllAssetsWhenNoLayers: false))
        let usedAssets = assets.filter { ids.contains($0.id) }
        return usedAssets.map(\.sourceBitDepth).max() ?? 8
    }

    private func sourceBitDepthForCompositionExport(assetIDs: [UUID]) -> Int {
        let usedAssets = assets.filter { assetIDs.contains($0.id) }
        return usedAssets.map(\.sourceBitDepth).max() ?? 8
    }

    private func sourceColorProfileForCompositionExport() -> VideoColorProfile {
        let ids = Set(exportPreparationAssetIDs(includeAllAssetsWhenNoLayers: false))
        let usedAssets = assets.filter { ids.contains($0.id) }
        return preferredColorProfile(from: usedAssets)
    }

    private func sourceColorProfileForCompositionExport(assetIDs: [UUID]) -> VideoColorProfile {
        let usedAssets = assets.filter { assetIDs.contains($0.id) }
        return preferredColorProfile(from: usedAssets)
    }

    private func sourceBitDepthForPrecomposition(_ document: CompositionDocumentState) -> Int {
        let ids = collectMediaAssetIDs(from: document.layers, seenPrecompositions: [])
        return assets.filter { ids.contains($0.id) }.map(\.sourceBitDepth).max() ?? 8
    }

    private func sourceColorProfileForPrecomposition(_ document: CompositionDocumentState) -> VideoColorProfile {
        let ids = collectMediaAssetIDs(from: document.layers, seenPrecompositions: [])
        return preferredColorProfile(from: assets.filter { ids.contains($0.id) })
    }

    private func preferredColorProfile(from assets: [CompositionAsset]) -> VideoColorProfile {
        if let hdr = assets.first(where: { $0.sourceColorProfile.isHDR })?.sourceColorProfile {
            return hdr
        }
        if let p3 = assets.first(where: { $0.sourceColorProfile.primaries == AVVideoColorPrimaries_P3_D65 })?.sourceColorProfile {
            return p3
        }
        return assets.first?.sourceColorProfile ?? .rec709
    }

    private func precompositionMap() -> [UUID: CompositionDocumentState] {
        var map: [UUID: CompositionDocumentState] = Dictionary(
            uniqueKeysWithValues: assets.compactMap { asset in
                guard let nested = asset.precomposition else { return nil }
                return (asset.id, nested)
            }
        )
        map[Self.rootCompositionAssetID] = activeCompositionAssetID == nil ? composition : rootComposition
        return map
    }

    private func prepareHighPrecisionExportAssets(assetIDs explicitAssetIDs: [UUID]? = nil) async throws -> [CompositionVideoExportAsset] {
        let ids = explicitAssetIDs ?? exportPreparationAssetIDs(includeAllAssetsWhenNoLayers: false)
        try await ensureHighPrecisionDiskCaches(assetIDs: ids)

        var exportAssets: [CompositionVideoExportAsset] = []
        for id in ids {
            guard let asset = assets.first(where: { $0.id == id }),
                  let previewVolume = asset.previewVolume else {
                continue
            }

            if asset.isMesh {
                exportAssets.append(
                    CompositionVideoExportAsset(
                        id: id,
                        volume: previewVolume,
                        volumeScale: Self.normalizedVolumeScale(
                            width: asset.sourceWidth,
                            height: asset.sourceHeight,
                            depth: asset.sourceFrameCount
                        ),
                        usesAlpha: previewVolume.hasMeaningfulAlpha
                    )
                )
                setExportCacheState(
                    assetID: id,
                    state: .ready,
                    message: "模型代理：导出使用体素模型（\(previewVolume.width) × \(previewVolume.height) × \(previewVolume.depth)）"
                )
                continue
            }

            let preserveAlpha = requiredHighPrecisionCachePreserveAlpha(for: asset)
            let cacheURL = try await HighPrecisionCacheHelper.validatedCacheURL(
                for: asset.url,
                preserveAlpha: preserveAlpha
            )
            setExportCacheState(assetID: id, state: .loading, message: "导出缓存：正在载入高精度体")

            let volume = try await Self.loadHighPrecisionExportVolume(
                cacheURL: cacheURL,
                sourceWidth: max(1, asset.sourceWidth),
                sourceHeight: max(1, asset.sourceHeight),
                sourceFrameCount: max(1, asset.sourceFrameCount)
            )
            exportAssets.append(
                CompositionVideoExportAsset(
                    id: id,
                    volume: volume,
                    volumeScale: Self.normalizedVolumeScale(
                        width: asset.sourceWidth,
                        height: asset.sourceHeight,
                        depth: asset.sourceFrameCount
                    ),
                    usesAlpha: volume.hasMeaningfulAlpha
                )
            )
            setExportCacheState(
                assetID: id,
                state: .ready,
                message: "导出缓存：高精度缓存已就绪（\(volume.width) × \(volume.height) × \(volume.depth)）"
            )
        }
        exportAssets.append(contentsOf: modifiedLayerExportAssets(from: exportAssets))
        return exportAssets
    }

    private func prepareProxyExportAssets(assetIDs explicitAssetIDs: [UUID]? = nil) -> [CompositionVideoExportAsset] {
        let ids = explicitAssetIDs ?? exportPreparationAssetIDs(includeAllAssetsWhenNoLayers: false)
        var exportAssets: [CompositionVideoExportAsset] = []
        for id in ids {
            guard let asset = assets.first(where: { $0.id == id }),
                  let volume = asset.previewVolume else {
                continue
            }
            exportAssets.append(
                CompositionVideoExportAsset(
                    id: id,
                    volume: volume,
                    volumeScale: Self.normalizedVolumeScale(
                        width: asset.sourceWidth,
                        height: asset.sourceHeight,
                        depth: asset.sourceFrameCount
                    ),
                    usesAlpha: volume.hasMeaningfulAlpha
                )
            )
        }
        exportAssets.append(contentsOf: modifiedLayerExportAssets(from: exportAssets))
        return exportAssets
    }

    private func modifiedLayerExportAssets(
        from baseAssets: [CompositionVideoExportAsset]
    ) -> [CompositionVideoExportAsset] {
        let baseByID = Dictionary(uniqueKeysWithValues: baseAssets.map { ($0.id, $0) })
        let precompositions = precompositionMap()
        let layers = allMediaLayersForModifiedExport(
            from: composition.layers,
            precompositions: precompositions,
            seenPrecompositions: []
        )
        var exportedIDs = Set<UUID>()
        var result: [CompositionVideoExportAsset] = []

        for layer in layers {
            guard exportedIDs.insert(layer.id).inserted,
                  !layer.modifiers.contains(where: { !$0.keyframes.isEmpty }),
                  VolumeModifierRasterizer.hasActiveModifiers(layer.modifiers),
                  let base = baseByID[layer.assetID] else {
                continue
            }
            let modifiedVolume = VolumeModifierRasterizer.applying(layer.modifiers, to: base.volume)
            result.append(
                CompositionVideoExportAsset(
                    id: layer.id,
                    volume: modifiedVolume,
                    volumeScale: base.volumeScale,
                    usesAlpha: modifiedVolume.hasMeaningfulAlpha
                )
            )
        }

        return result
    }

    private func allMediaLayersForModifiedExport(
        from layers: [CompositionLayer],
        precompositions: [UUID: CompositionDocumentState],
        seenPrecompositions: Set<UUID>
    ) -> [CompositionLayer] {
        layers.flatMap { layer -> [CompositionLayer] in
            guard let nested = precompositions[layer.assetID],
                  !seenPrecompositions.contains(layer.assetID) else {
                return [layer]
            }
            var nextSeen = seenPrecompositions
            nextSeen.insert(layer.assetID)
            return allMediaLayersForModifiedExport(
                from: nested.layers,
                precompositions: precompositions,
                seenPrecompositions: nextSeen
            )
        }
    }

    private func ensureHighPrecisionDiskCaches(assetIDs: [UUID]) async throws {
        for id in assetIDs {
            guard let asset = assets.first(where: { $0.id == id }) else { continue }
            if asset.isMesh {
                setExportCacheState(assetID: id, state: .ready, message: "模型代理：无需 raw cache")
                continue
            }
            guard FileManager.default.fileExists(atPath: asset.url.path) else {
                setExportCacheState(assetID: id, state: .failed, message: "导出缓存：源文件不存在")
                throw HighPrecisionCacheError.sourceNotFound
            }

            let preserveAlpha = requiredHighPrecisionCachePreserveAlpha(for: asset)
            let inspection = highPrecisionCacheInspection(for: asset)
            if inspection.isReady {
                setExportCacheState(assetID: id, state: .ready, message: cacheReadyMessage(for: asset))
                continue
            }

            let rebuildReason = inspection.isExpired ? "（\(inspection.detailText)）" : ""
            setExportCacheState(assetID: id, state: .building, message: "导出缓存：正在建立高精度缓存\(rebuildReason)")
            do {
                _ = try await HighPrecisionCacheHelper.buildCache(
                    from: asset.url,
                    preserveAlpha: preserveAlpha
                ) { progress, message in
                    Task { @MainActor in
                        self.setExportCacheState(
                            assetID: id,
                            state: .building,
                            message: "导出缓存：\(message) \(Int((progress * 100).rounded()))%"
                        )
                    }
                }
                setExportCacheState(assetID: id, state: .ready, message: cacheReadyMessage(for: asset))
            } catch {
                setExportCacheState(
                    assetID: id,
                    state: .failed,
                    message: "导出缓存：建立失败 \(error.localizedDescription)"
                )
                throw error
            }
        }
    }

    func frameForDrop(x: CGFloat, width: CGFloat) -> Int {
        guard width > 1 else { return currentFrame }
        let progress = max(0, min(1, x / width))
        let frame = Int((progress * CGFloat(max(0, composition.frameCount - 1))).rounded())
        let tolerance = max(2, Int((CGFloat(max(1, composition.frameCount)) / max(1, width) * 10).rounded()))
        return snappedTimelineFrame(frame, tolerance: tolerance)
    }

    private func exportPreparationAssetIDs(includeAllAssetsWhenNoLayers: Bool = true) -> [UUID] {
        var result: [UUID] = []
        var seen: Set<UUID> = []
        let activeLayers = composition.layers
            .filter { $0.isVisible && (!composition.layers.contains(where: \.isSolo) || $0.isSolo) }
        let layerAssetIDs = collectMediaAssetIDs(from: activeLayers, seenPrecompositions: [])

        let sourceIDs = layerAssetIDs.isEmpty && includeAllAssetsWhenNoLayers
            ? mediaAssets.map(\.id)
            : layerAssetIDs
        for id in sourceIDs where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    private func exportPreparationAssetIDs(
        from layers: [CompositionLayer],
        precompositions: [UUID: CompositionDocumentState],
        includeAllAssetsWhenNoLayers: Bool
    ) -> [UUID] {
        var result: [UUID] = []
        var seen: Set<UUID> = []
        let hasSolo = layers.contains(where: \.isSolo)
        let activeLayers = layers.filter { $0.isVisible && (!hasSolo || $0.isSolo) }
        let sourceIDs = collectMediaAssetIDs(
            from: activeLayers,
            precompositions: precompositions,
            seenPrecompositions: []
        )

        let ids = sourceIDs.isEmpty && includeAllAssetsWhenNoLayers
            ? mediaAssets.map(\.id)
            : sourceIDs
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    private func collectMediaAssetIDs(
        from layers: [CompositionLayer],
        seenPrecompositions: Set<UUID>
    ) -> [UUID] {
        var result: [UUID] = []
        var seenAssets: Set<UUID> = []
        func append(_ id: UUID) {
            guard !seenAssets.contains(id) else { return }
            seenAssets.insert(id)
            result.append(id)
        }

        func walk(_ layers: [CompositionLayer], seenPrecompositions: Set<UUID>) {
            for layer in layers {
                if layer.assetID == Self.rootCompositionAssetID {
                    guard !seenPrecompositions.contains(Self.rootCompositionAssetID) else { continue }
                    var nextSeen = seenPrecompositions
                    nextSeen.insert(Self.rootCompositionAssetID)
                    let nested = activeCompositionAssetID == nil ? composition : rootComposition
                    walk(nested.layers, seenPrecompositions: nextSeen)
                    continue
                }
                guard let asset = assets.first(where: { $0.id == layer.assetID }) else { continue }
                switch asset.kind {
                case .video, .mesh:
                    append(asset.id)
                case .precomposition:
                    guard !seenPrecompositions.contains(asset.id),
                          let nested = asset.precomposition else { continue }
                    var nextSeen = seenPrecompositions
                    nextSeen.insert(asset.id)
                    walk(nested.layers, seenPrecompositions: nextSeen)
                }
            }
        }

        walk(layers, seenPrecompositions: seenPrecompositions)
        return result
    }

    private func collectMediaAssetIDs(
        from layers: [CompositionLayer],
        precompositions: [UUID: CompositionDocumentState],
        seenPrecompositions: Set<UUID>
    ) -> [UUID] {
        var result: [UUID] = []
        var seenAssets: Set<UUID> = []
        func append(_ id: UUID) {
            guard !seenAssets.contains(id) else { return }
            seenAssets.insert(id)
            result.append(id)
        }

        func walk(_ layers: [CompositionLayer], seenPrecompositions: Set<UUID>) {
            for layer in layers {
                if let nested = precompositions[layer.assetID] {
                    guard !seenPrecompositions.contains(layer.assetID) else { continue }
                    var nextSeen = seenPrecompositions
                    nextSeen.insert(layer.assetID)
                    walk(nested.layers, seenPrecompositions: nextSeen)
                    continue
                }

                guard let asset = assets.first(where: { $0.id == layer.assetID }) else { continue }
                switch asset.kind {
                case .video, .mesh:
                    append(asset.id)
                case .precomposition:
                    guard !seenPrecompositions.contains(asset.id),
                          let nested = asset.precomposition else { continue }
                    var nextSeen = seenPrecompositions
                    nextSeen.insert(asset.id)
                    walk(nested.layers, seenPrecompositions: nextSeen)
                }
            }
        }

        walk(layers, seenPrecompositions: seenPrecompositions)
        return result
    }

    private struct ProxyCacheInspection {
        var statusText: String
        var detailText: String
        var needsBuild: Bool
        var isExpired: Bool
    }

    private struct HighPrecisionCacheInspection {
        var statusText: String
        var detailText: String
        var needsBuild: Bool
        var isExpired: Bool
        var isReady: Bool
        var sizeBytes: Int64
    }

    private func cachePolicyItem(for asset: CompositionAsset) -> CompositionCachePolicyItem {
        let proxy = proxyCacheInspection(for: asset)
        let highPrecision = highPrecisionCacheInspection(for: asset)
        let sourceText: String
        if asset.sourceWidth > 0 || asset.sourceHeight > 0 || asset.sourceFrameCount > 0 {
            sourceText = "\(asset.sourceWidth) × \(asset.sourceHeight) × \(asset.sourceFrameCount) / \(asset.sourceBitDepth)-bit"
        } else {
            sourceText = "等待读取源信息"
        }

        return CompositionCachePolicyItem(
            id: asset.id,
            name: asset.name,
            path: asset.url.path,
            sourceText: sourceText,
            sourceMissing: asset.sourceFileMissing,
            proxyStatusText: proxy.statusText,
            proxyDetailText: proxy.detailText,
            proxyNeedsBuild: proxy.needsBuild,
            proxyIsExpired: proxy.isExpired,
            highPrecisionStatusText: highPrecision.statusText,
            highPrecisionDetailText: highPrecision.detailText,
            highPrecisionNeedsBuild: highPrecision.needsBuild,
            highPrecisionIsExpired: highPrecision.isExpired,
            requiredHighPrecisionAlpha: requiredHighPrecisionCachePreserveAlpha(for: asset),
            cacheSizeBytes: highPrecision.sizeBytes,
            cacheSizeText: byteCountText(highPrecision.sizeBytes)
        )
    }

    private func proxyCacheInspection(for asset: CompositionAsset) -> ProxyCacheInspection {
        guard !asset.sourceFileMissing,
              FileManager.default.fileExists(atPath: asset.url.path) else {
            return ProxyCacheInspection(
                statusText: "源文件丢失",
                detailText: "无法建立代理缓存",
                needsBuild: false,
                isExpired: false
            )
        }

        guard asset.previewVolume != nil else {
            return ProxyCacheInspection(
                statusText: "未建立",
                detailText: "需要后台导入代理体",
                needsBuild: true,
                isExpired: false
            )
        }

        if let builtAt = asset.proxyCacheBuiltAt,
           let sourceModifiedAt = fileModificationDate(at: asset.url),
           sourceModifiedAt > builtAt {
            return ProxyCacheInspection(
                statusText: "已过期",
                detailText: "源文件比代理缓存更新",
                needsBuild: true,
                isExpired: true
            )
        }

        let size = asset.previewVolume.map { "\($0.width) × \($0.height) × \($0.depth)" } ?? "-"
        return ProxyCacheInspection(
            statusText: "已就绪",
            detailText: "代理体 \(size)",
            needsBuild: false,
            isExpired: false
        )
    }

    private func highPrecisionCacheInspection(for asset: CompositionAsset) -> HighPrecisionCacheInspection {
        if asset.isMesh {
            return HighPrecisionCacheInspection(
                statusText: asset.previewVolume == nil ? "模型代理未就绪" : "模型代理已就绪",
                detailText: "3D 模型导出使用体素代理，无需 raw cache",
                needsBuild: false,
                isExpired: false,
                isReady: asset.previewVolume != nil,
                sizeBytes: 0
            )
        }

        let size = rawCacheSizeBytes(for: asset)
        guard !asset.sourceFileMissing,
              FileManager.default.fileExists(atPath: asset.url.path) else {
            return HighPrecisionCacheInspection(
                statusText: "源文件丢失",
                detailText: "无法判断或重建 raw cache",
                needsBuild: false,
                isExpired: false,
                isReady: false,
                sizeBytes: size
            )
        }

        let preserveAlpha = requiredHighPrecisionCachePreserveAlpha(for: asset)
        let modeText = preserveAlpha ? "带 Alpha" : "不带 Alpha"
        let movieURL = HighPrecisionCacheHelper.cacheMovieURL(for: asset.url, preserveAlpha: preserveAlpha)
        let metadataURL = HighPrecisionCacheHelper.cacheMetadataURL(for: asset.url, preserveAlpha: preserveAlpha)
        let movieExists = FileManager.default.fileExists(atPath: movieURL.path)
        let metadataExists = FileManager.default.fileExists(atPath: metadataURL.path)

        guard movieExists || metadataExists else {
            let otherModeExists = HighPrecisionCacheHelper.hasCache(for: asset.url, preserveAlpha: !preserveAlpha)
            let detail = otherModeExists
                ? "有另一种 Alpha 模式的缓存，但当前需要 \(modeText)"
                : "导出前需要建立 \(modeText) raw cache"
            return HighPrecisionCacheInspection(
                statusText: "未建立",
                detailText: detail,
                needsBuild: true,
                isExpired: false,
                isReady: false,
                sizeBytes: size
            )
        }

        guard movieExists && metadataExists else {
            return HighPrecisionCacheInspection(
                statusText: "缓存不完整",
                detailText: "缺少 \(movieExists ? "元数据" : "视频缓存")，需要重建",
                needsBuild: true,
                isExpired: true,
                isReady: false,
                sizeBytes: size
            )
        }

        let metadata: HighPrecisionCacheMetadata
        do {
            metadata = try HighPrecisionCacheHelper.loadMetadata(for: asset.url, preserveAlpha: preserveAlpha)
        } catch {
            return HighPrecisionCacheInspection(
                statusText: "元数据不可读",
                detailText: "需要重建：\(error.localizedDescription)",
                needsBuild: true,
                isExpired: true,
                isReady: false,
                sizeBytes: size
            )
        }

        var staleReasons: [String] = []
        if metadata.version != 1 {
            staleReasons.append("缓存版本不匹配")
        }
        if metadata.sourcePath != asset.url.path {
            staleReasons.append("源文件路径已变化")
        }
        if metadata.preserveAlpha != preserveAlpha {
            staleReasons.append("Alpha 模式不匹配")
        }
        if asset.sourceWidth > 0 && metadata.sourceWidth != asset.sourceWidth {
            staleReasons.append("宽度不匹配")
        }
        if asset.sourceHeight > 0 && metadata.sourceHeight != asset.sourceHeight {
            staleReasons.append("高度不匹配")
        }
        if asset.sourceFrameCount > 0 && metadata.sourceFrameCount != asset.sourceFrameCount {
            staleReasons.append("帧数不匹配")
        }
        if asset.sourceFPS > 0 && abs(metadata.fps - asset.sourceFPS) > 0.5 {
            staleReasons.append("FPS 不匹配")
        }
        if let sourceModifiedAt = fileModificationDate(at: asset.url),
           let cacheModifiedAt = minFileModificationDate([movieURL, metadataURL]),
           sourceModifiedAt > cacheModifiedAt {
            staleReasons.append("源文件比缓存更新")
        }

        if !staleReasons.isEmpty {
            return HighPrecisionCacheInspection(
                statusText: "已过期",
                detailText: staleReasons.joined(separator: "、"),
                needsBuild: true,
                isExpired: true,
                isReady: false,
                sizeBytes: size
            )
        }

        let createdText = metadata.createdAtISO8601.isEmpty ? "" : "，创建于 \(metadata.createdAtISO8601)"
        return HighPrecisionCacheInspection(
            statusText: "已就绪（\(modeText)）",
            detailText: "\(metadata.codecName)\(createdText)",
            needsBuild: false,
            isExpired: false,
            isReady: true,
            sizeBytes: size
        )
    }

    private func mediaManagerItem(for asset: CompositionAsset) -> CompositionMediaManagerItem {
        let exists = FileManager.default.fileExists(atPath: asset.url.path)
        let alphaText: String
        if let previewVolume = asset.previewVolume {
            alphaText = previewVolume.hasMeaningfulAlpha ? "检测到有效 Alpha" : "无有效 Alpha"
        } else {
            alphaText = "未检测"
        }

        let cacheInfo = rawCacheInfo(for: asset)
        let sourceText: String
        if asset.sourceWidth > 0 || asset.sourceHeight > 0 || asset.sourceFrameCount > 0 {
            sourceText = "\(asset.sourceWidth) × \(asset.sourceHeight) × \(asset.sourceFrameCount)"
        } else {
            sourceText = "等待读取"
        }

        return CompositionMediaManagerItem(
            id: asset.id,
            name: asset.name,
            path: asset.url.path,
            fileStatusText: exists ? "文件存在" : "源文件丢失",
            isMissing: !exists,
            sourceText: sourceText,
            bitDepthText: "\(asset.sourceBitDepth)-bit",
            alphaText: alphaText,
            rawCacheStatusText: cacheInfo.statusText,
            rawCacheSizeBytes: cacheInfo.sizeBytes,
            rawCacheSizeText: byteCountText(cacheInfo.sizeBytes),
            exportCacheState: asset.exportCacheState
        )
    }

    private func rawCacheInfo(for asset: CompositionAsset) -> (statusText: String, sizeBytes: Int64) {
        let inspection = highPrecisionCacheInspection(for: asset)
        return (inspection.statusText, inspection.sizeBytes)
    }

    private func rawCacheSizeBytes(for asset: CompositionAsset) -> Int64 {
        if asset.isMesh { return 0 }

        var paths = Set<String>()
        var urls: [URL] = []
        for preserveAlpha in [false, true] {
            let movieURL = HighPrecisionCacheHelper.cacheMovieURL(for: asset.url, preserveAlpha: preserveAlpha)
            let metadataURL = HighPrecisionCacheHelper.cacheMetadataURL(for: asset.url, preserveAlpha: preserveAlpha)
            for url in [movieURL, metadataURL] where paths.insert(url.path).inserted {
                urls.append(url)
            }
        }
        return urls.reduce(Int64(0)) { $0 + fileSizeBytes(at: $1) }
    }

    private func fileSizeBytes(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]),
              values.isRegularFile == true else {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }

    private func fileModificationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func minFileModificationDate(_ urls: [URL]) -> Date? {
        let dates = urls.compactMap { fileModificationDate(at: $0) }
        return dates.min()
    }

    private func byteCountText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func byteCountText(_ bytes: UInt64) -> String {
        let clamped = min(bytes, UInt64(Int64.max))
        return byteCountText(Int64(clamped))
    }

    private func makePerformanceSnapshot() -> CompositionPerformanceSnapshot {
        let renderLayers = activeRenderLayers()
        let renderer = latestRendererDiagnostics
        let rawStats = rawCacheHitStats(for: renderLayers)
        let appMemory = currentResidentMemoryBytes()
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let memoryRatio = physicalMemory > 0 ? Double(appMemory) / Double(physicalMemory) : 0

        return CompositionPerformanceSnapshot(
            previewFPS: renderer?.previewFPS ?? performanceSnapshot.previewFPS,
            previewPathText: renderer?.renderPathText ?? "Metal GPU（等待首帧）",
            sourcePathText: "预览：代理 3D texture｜\(compositionPreviewQualityStatusText)｜导出：\(compositionExportSettings.sourceMode.title)",
            drawableText: renderer.map { "\($0.drawableWidth) × \($0.drawableHeight)" } ?? "-",
            activeLayerCount: renderLayers.count,
            textureHitCount: renderer?.textureHitCount ?? 0,
            textureMissCount: renderer?.textureMissCount ?? 0,
            rawCacheHitCount: rawStats.hit,
            rawCacheMissCount: rawStats.miss,
            estimatedTextureMemoryBytes: renderer?.estimatedTextureMemoryBytes ?? estimatedPreviewTextureBytes(),
            appMemoryBytes: appMemory,
            physicalMemoryBytes: physicalMemory,
            memoryPressureText: memoryPressureText(for: memoryRatio),
            memoryPressureLevel: memoryRatio,
            updatedAt: Date()
        )
    }

    private func rawCacheHitStats(for renderLayers: [CompositionRenderLayer]) -> (hit: Int, miss: Int) {
        var ids = Set<UUID>()
        for layer in renderLayers {
            ids.insert(layer.assetID)
            if let matteAssetID = layer.trackMatteAssetID {
                ids.insert(matteAssetID)
            }
        }
        if ids.isEmpty {
            ids = Set(videoAssets.map(\.id))
        }

        var hit = 0
        var miss = 0
        for id in ids {
            guard let asset = assets.first(where: { $0.id == id && $0.isVideo }) else { continue }
            guard asset.previewVolume != nil else {
                miss += 1
                continue
            }
            let preserveAlpha = requiredHighPrecisionCachePreserveAlpha(for: asset)
            if HighPrecisionCacheHelper.hasCache(for: asset.url, preserveAlpha: preserveAlpha) {
                hit += 1
            } else {
                miss += 1
            }
        }
        return (hit, miss)
    }

    private func estimatedPreviewTextureBytes() -> Int64 {
        mediaAssets.reduce(Int64(0)) { total, asset in
            guard let volume = asset.previewVolume else { return total }
            return total + Int64(max(1, volume.width))
                * Int64(max(1, volume.height))
                * Int64(max(1, volume.depth))
                * 4
        }
    }

    private func memoryPressureText(for ratio: Double) -> String {
        if ratio >= 0.75 { return "高" }
        if ratio >= 0.50 { return "中" }
        return "低"
    }

    private func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { pointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    pointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private func requiredHighPrecisionCachePreserveAlpha(for asset: CompositionAsset) -> Bool {
        asset.previewVolume?.hasMeaningfulAlpha ?? false
    }

    private func cacheReadyMessage(for asset: CompositionAsset) -> String {
        let alphaText = requiredHighPrecisionCachePreserveAlpha(for: asset) ? "带 Alpha" : "不带 Alpha"
        return "导出缓存：高精度缓存已就绪（\(alphaText)）"
    }

    private func refreshExportCacheState(at index: Int) {
        guard assets.indices.contains(index) else { return }
        if assets[index].isMesh {
            if let volume = assets[index].previewVolume {
                assets[index].exportCacheState = .ready
                assets[index].exportCacheMessage = "模型代理：已体素化（\(volume.width) × \(volume.height) × \(volume.depth)）"
            } else {
                assets[index].exportCacheState = .unknown
                assets[index].exportCacheMessage = "模型代理：等待体素化"
            }
            return
        }
        guard assets[index].isVideo else {
            assets[index].exportCacheState = .ready
            assets[index].exportCacheMessage = "预合成：无需单独缓存"
            return
        }
        guard assets[index].previewVolume != nil else {
            assets[index].exportCacheState = .unknown
            assets[index].exportCacheMessage = "导出缓存：等待代理导入"
            return
        }

        let inspection = highPrecisionCacheInspection(for: assets[index])
        if inspection.isReady {
            assets[index].exportCacheState = .ready
            assets[index].exportCacheMessage = cacheReadyMessage(for: assets[index])
        } else if inspection.isExpired {
            assets[index].exportCacheState = .missing
            assets[index].exportCacheMessage = "导出缓存：已过期，需要重建"
        } else {
            assets[index].exportCacheState = .missing
            assets[index].exportCacheMessage = "导出缓存：未建立"
        }
    }

    private func setExportCacheState(
        assetID: UUID,
        state: CompositionExportCacheState,
        message: String
    ) {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        assets[index].exportCacheState = state
        assets[index].exportCacheMessage = message
    }

    nonisolated private static func loadHighPrecisionExportVolume(
        cacheURL: URL,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int
    ) async throws -> LoadedVolume {
        let package = try await VideoVolumeLoader.load(
            url: cacheURL,
            maxWidth: max(1, sourceWidth),
            maxHeight: max(1, sourceHeight),
            previewMaxDepth: max(1, sourceFrameCount)
        )
        return package.fullTemporalVolume
    }

    private func appendAssetAndLoad(
        id: UUID,
        url: URL,
        name: String,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        sourceFPS: Double,
        sourceBitDepth: Int,
        sourceColorProfile: VideoColorProfile
    ) {
        guard !assets.contains(where: { $0.id == id }) else { return }

        let exists = FileManager.default.fileExists(atPath: url.path)
        let asset = CompositionAsset(
            id: id,
            kind: .video,
            url: url,
            name: name.isEmpty ? url.lastPathComponent : name,
            status: exists ? "正在导入…" : "文件不存在",
            sourceFileMissing: !exists,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceFrameCount: sourceFrameCount,
            sourceFPS: sourceFPS,
            sourceBitDepth: max(8, sourceBitDepth),
            sourceColorProfile: sourceColorProfile,
            previewVolume: nil,
            proxyCacheBuiltAt: nil,
            precomposition: nil,
            exportCacheState: exists ? .unknown : .failed,
            exportCacheMessage: exists ? "导出缓存：等待代理导入" : "导出缓存：源文件不存在"
        )
        assets.append(asset)

        guard exists else {
            status = "有素材文件不存在"
            return
        }

        loadAssetPreview(id: id, url: url)
    }

    private func appendMeshAssetAndLoad(id: UUID, url: URL, name: String) {
        guard !assets.contains(where: { $0.id == id }) else { return }

        let exists = FileManager.default.fileExists(atPath: url.path)
        let asset = CompositionAsset(
            id: id,
            kind: .mesh,
            url: url,
            name: name.isEmpty ? url.lastPathComponent : name,
            status: exists ? "正在导入模型…" : "文件不存在",
            sourceFileMissing: !exists,
            sourceWidth: 0,
            sourceHeight: 0,
            sourceFrameCount: 0,
            sourceFPS: 30,
            sourceBitDepth: 8,
            sourceColorProfile: .rec709,
            previewVolume: nil,
            proxyCacheBuiltAt: nil,
            precomposition: nil,
            exportCacheState: exists ? .unknown : .failed,
            exportCacheMessage: exists ? "模型代理：等待体素化" : "模型代理：源文件不存在"
        )
        assets.append(asset)

        guard exists else {
            status = "有模型文件不存在"
            return
        }

        loadMeshAssetPreview(id: id, url: url)
    }

    private func rebuildProxyCacheForAsset(assetID: UUID) async throws {
        guard let index = assets.firstIndex(where: { $0.id == assetID && $0.isVideo }) else { return }
        let asset = assets[index]
        guard FileManager.default.fileExists(atPath: asset.url.path) else {
            assets[index].sourceFileMissing = true
            assets[index].status = "源文件丢失"
            throw HighPrecisionCacheError.sourceNotFound
        }

        assets[index].status = "正在建立代理缓存…"
        assets[index].exportCacheState = .unknown
        assets[index].exportCacheMessage = "导出缓存：等待代理导入"

        let url = asset.url
        let package = try await Task.detached(priority: .userInitiated) {
            try await VideoVolumeLoader.load(
                url: url,
                maxWidth: 1024,
                maxHeight: 1024,
                previewMaxDepth: 256
            )
        }.value
        let renderPreviewVolume = Self.makeRenderPreviewVolume(from: package.previewVolume)
        updateAsset(
            id: assetID,
            status: "已导入",
            width: package.sourceWidth,
            height: package.sourceHeight,
            frameCount: package.sourceFrameCount,
            fps: package.sourceFPS,
            bitDepth: package.sourceBitDepth,
            colorProfile: package.sourceColorProfile,
            previewVolume: renderPreviewVolume
        )
        onVideoPackageLoaded?(url, package)
    }

    private func appendPrecompositionAsset(
        id: UUID,
        name: String,
        composition: CompositionDocumentState
    ) {
        guard !assets.contains(where: { $0.id == id }) else { return }
        var nested = composition
        sanitize(document: &nested)
        let asset = CompositionAsset(
            id: id,
            kind: .precomposition,
            url: URL(fileURLWithPath: ""),
            name: name.isEmpty ? nested.name : name,
            status: "预合成",
            sourceFileMissing: false,
            sourceWidth: nested.width,
            sourceHeight: nested.height,
            sourceFrameCount: nested.frameCount,
            sourceFPS: nested.fps,
            sourceBitDepth: sourceBitDepthForPrecomposition(nested),
            sourceColorProfile: sourceColorProfileForPrecomposition(nested),
            previewVolume: nil,
            proxyCacheBuiltAt: nil,
            precomposition: nested,
            exportCacheState: .ready,
            exportCacheMessage: "预合成：无需单独缓存"
        )
        assets.append(asset)
        openCompositionTabIDs = normalizeCompositionTabIDs(openCompositionTabIDs, activeID: activeCompositionAssetID)
    }

    private func loadAssetPreview(id: UUID, url: URL) {
        Task.detached(priority: .userInitiated) { [url, id] in
            do {
                let package = try await VideoVolumeLoader.load(
                    url: url,
                    maxWidth: 1024,
                    maxHeight: 1024,
                    previewMaxDepth: 256
                )
                let renderPreviewVolume = Self.makeRenderPreviewVolume(from: package.previewVolume)

                await MainActor.run {
                    self.updateAsset(
                        id: id,
                        status: "已导入",
                        width: package.sourceWidth,
                        height: package.sourceHeight,
                        frameCount: package.sourceFrameCount,
                        fps: package.sourceFPS,
                        bitDepth: package.sourceBitDepth,
                        colorProfile: package.sourceColorProfile,
                        previewVolume: renderPreviewVolume
                    )
                    self.onVideoPackageLoaded?(url, package)
                }
            } catch {
                await MainActor.run {
                    self.updateAssetFailure(id: id, message: error.localizedDescription)
                }
            }
        }
    }

    private func loadMeshAssetPreview(
        id: UUID,
        url: URL,
        maxResolution: Int = 160,
        finishedStatus: String = "模型已导入"
    ) {
        Task.detached(priority: .userInitiated) { [url, id, maxResolution, finishedStatus] in
            do {
                let package = try MeshVolumeLoader.load(url: url, maxResolution: maxResolution)
                let volume = package.volume
                await MainActor.run {
                    self.updateAsset(
                        id: id,
                        status: finishedStatus,
                        width: volume.width,
                        height: volume.height,
                        frameCount: volume.depth,
                        fps: volume.sourceFPS,
                        bitDepth: 8,
                        colorProfile: volume.sourceColorProfile,
                        previewVolume: volume
                    )
                    if let index = self.assets.firstIndex(where: { $0.id == id }) {
                        self.assets[index].exportCacheState = .ready
                        let quality = maxResolution >= 256 ? "高精度" : "预览"
                        self.assets[index].exportCacheMessage = "模型代理：\(quality)体已就绪（\(volume.width) × \(volume.height) × \(volume.depth)，\(package.triangleCount) 面）"
                    }
                    self.onMeshPackageLoaded?(url, package)
                }
            } catch {
                await MainActor.run {
                    self.updateAssetFailure(id: id, message: error.localizedDescription)
                }
            }
        }
    }

    private func updateAsset(
        id: UUID,
        status: String,
        width: Int,
        height: Int,
        frameCount: Int,
        fps: Double,
        bitDepth: Int,
        colorProfile: VideoColorProfile,
        previewVolume: LoadedVolume
    ) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        assets[index].status = status
        assets[index].sourceWidth = width
        assets[index].sourceHeight = height
        assets[index].sourceFrameCount = frameCount
        assets[index].sourceFPS = fps
        assets[index].sourceBitDepth = bitDepth
        assets[index].sourceColorProfile = colorProfile
        assets[index].sourceFileMissing = false
        assets[index].previewVolume = previewVolume
        assets[index].proxyCacheBuiltAt = Date()
        refreshExportCacheState(at: index)
        self.status = assets.allSatisfy { $0.isReady || $0.status.hasPrefix("导入失败") } ? "导入完成" : "正在导入…"
    }

    private func updateAssetFailure(id: UUID, message: String) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        assets[index].status = "导入失败：\(message)"
        assets[index].proxyCacheBuiltAt = nil
        assets[index].exportCacheState = .failed
        assets[index].exportCacheMessage = "导出缓存：代理导入失败"
        recordDiagnosticEvent(
            severity: "error",
            category: "素材导入",
            message: "素材导入失败：\(assets[index].name)",
            details: message,
            includeCallStack: true
        )
        self.status = "有素材导入失败"
    }

    nonisolated private static func makeRenderPreviewVolume(from source: LoadedVolume) -> LoadedVolume {
        let maxWidth = 512
        let maxHeight = 512
        let maxDepth = 160

        let scale = min(
            1.0,
            Double(maxWidth) / Double(max(1, source.width)),
            Double(maxHeight) / Double(max(1, source.height)),
            Double(maxDepth) / Double(max(1, source.depth))
        )

        let targetWidth = max(1, Int((Double(source.width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(source.height) * scale).rounded()))
        let targetDepth = max(1, Int((Double(source.depth) * scale).rounded()))

        guard targetWidth != source.width || targetHeight != source.height || targetDepth != source.depth else {
            return source
        }

        var rgba = [UInt8](repeating: 0, count: targetWidth * targetHeight * targetDepth * 4)

        for z in 0..<targetDepth {
            let sourceZ = min(source.depth - 1, Int((Double(z) / Double(targetDepth)) * Double(source.depth)))
            for y in 0..<targetHeight {
                let sourceY = min(source.height - 1, Int((Double(y) / Double(targetHeight)) * Double(source.height)))
                for x in 0..<targetWidth {
                    let sourceX = min(source.width - 1, Int((Double(x) / Double(targetWidth)) * Double(source.width)))
                    let sourceIndex = ((sourceZ * source.height + sourceY) * source.width + sourceX) * 4
                    let targetIndex = ((z * targetHeight + y) * targetWidth + x) * 4
                    rgba[targetIndex] = source.rgba[sourceIndex]
                    rgba[targetIndex + 1] = source.rgba[sourceIndex + 1]
                    rgba[targetIndex + 2] = source.rgba[sourceIndex + 2]
                    rgba[targetIndex + 3] = source.rgba[sourceIndex + 3]
                }
            }
        }

        return LoadedVolume(
            width: targetWidth,
            height: targetHeight,
            depth: targetDepth,
            rgba: rgba,
            hasMeaningfulAlpha: source.hasMeaningfulAlpha,
            sourceFPS: source.sourceFPS,
            sourceDurationSeconds: source.sourceDurationSeconds,
            sourceFrameCountEstimate: source.sourceFrameCountEstimate,
            sourceColorProfile: source.sourceColorProfile
        )
    }

    private func sanitize(document: inout CompositionDocumentState) {
        document.name = document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未命名合成"
            : document.name
        document.width = max(1, document.width)
        document.height = max(1, document.height)
        document.frameCount = max(1, document.frameCount)
        document.fps = max(0.05, document.fps)
        document.backgroundColor.red = max(0, min(1, document.backgroundColor.red))
        document.backgroundColor.green = max(0, min(1, document.backgroundColor.green))
        document.backgroundColor.blue = max(0, min(1, document.backgroundColor.blue))
        document.markers = document.markers
            .map {
                CompositionTimelineMarker(
                    id: $0.id,
                    frame: max(0, min(document.frameCount - 1, $0.frame)),
                    name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "标记"
                        : $0.name
                )
            }
            .sorted { $0.frame < $1.frame }
        if document.cameraClips.isEmpty {
            document.cameraClips = [
                CompositionCameraClip(name: "摄像机 1", startFrame: 0, duration: document.frameCount)
            ]
        }
    }

    private func clampLayer(at index: Int) {
        guard composition.layers.indices.contains(index) else { return }
        composition.layers[index].duration = max(1, composition.layers[index].duration)
        composition.layers[index].opacity = max(0, min(1, composition.layers[index].opacity))
        composition.layers[index].transform.scaleX = max(0.01, composition.layers[index].transform.scaleX)
        composition.layers[index].transform.scaleY = max(0.01, composition.layers[index].transform.scaleY)
        composition.layers[index].transform.scaleZ = max(0.01, composition.layers[index].transform.scaleZ)
        composition.layers[index].keyframes.sort { $0.frame < $1.frame }
    }

    private func ensureCameraClips() {
        if composition.cameraClips.isEmpty {
            composition.cameraClips = [
                CompositionCameraClip(name: "摄像机 1", startFrame: 0, duration: composition.frameCount)
            ]
        }
    }

    private func clampCameraClips() {
        ensureCameraClips()
        composition.cameraClips = composition.cameraClips
            .map { clip in
                var resolved = clip
                resolved.duration = max(1, resolved.duration)
                resolved.camera.focalLength = max(1, resolved.camera.focalLength)
                resolved.camera.aperture = max(0.1, resolved.camera.aperture)
                resolved.keyframes.sort { $0.frame < $1.frame }
                return resolved
            }
        if composition.cameraClips.isEmpty {
            composition.cameraClips = [CompositionCameraClip(name: "摄像机 1", startFrame: 0, duration: composition.frameCount)]
        }
        if let selectedCameraClipID,
           !composition.cameraClips.contains(where: { $0.id == selectedCameraClipID }) {
            self.selectedCameraClipID = composition.cameraClips.first?.id
        }
    }

    private func deduplicateCameraKeyframes() {
        for index in composition.cameraClips.indices {
            var seen: Set<String> = []
            composition.cameraClips[index].keyframes = composition.cameraClips[index].keyframes
                .sorted { lhs, rhs in
                    lhs.frame == rhs.frame
                        ? lhs.property.rawValue < rhs.property.rawValue
                        : lhs.frame < rhs.frame
                }
                .filter { keyframe in
                    let key = "\(keyframe.property.rawValue)-\(keyframe.frame)"
                    if seen.contains(key) {
                        return false
                    }
                    seen.insert(key)
                    return true
                }
        }
    }

    private func deduplicateLayerKeyframes() {
        for index in composition.layers.indices {
            var seen: Set<String> = []
            composition.layers[index].keyframes = composition.layers[index].keyframes
                .sorted { lhs, rhs in
                    lhs.frame == rhs.frame
                        ? lhs.property.rawValue < rhs.property.rawValue
                        : lhs.frame < rhs.frame
                }
                .filter { keyframe in
                    let key = "\(keyframe.property.rawValue)-\(keyframe.frame)"
                    if seen.contains(key) {
                        return false
                    }
                    seen.insert(key)
                    return true
                }
        }
    }

    private func isLayer(_ layer: CompositionLayer, activeAt frame: Int) -> Bool {
        frame >= layer.startFrame && frame < layer.startFrame + layer.duration
    }

    private func isCameraClip(_ clip: CompositionCameraClip, activeAt frame: Int) -> Bool {
        frame >= clip.startFrame && frame < clip.startFrame + clip.duration
    }

    private func selectedCameraClipIndex() -> Int? {
        if let selectedCameraClipID,
           let index = composition.cameraClips.firstIndex(where: { $0.id == selectedCameraClipID }) {
            return index
        }
        if let active = activeCameraClip(at: currentFrame),
           let index = composition.cameraClips.firstIndex(where: { $0.id == active.id }) {
            selectedCameraClipID = active.id
            return index
        }
        if composition.cameraClips.indices.contains(0) {
            selectedCameraClipID = composition.cameraClips[0].id
            return 0
        }
        return nil
    }

    private func selectedCameraClip() -> CompositionCameraClip? {
        guard let index = selectedCameraClipIndex() else { return nil }
        return composition.cameraClips[index]
    }

    private func syncEditableCameraFromSelection() {
        guard let clip = selectedCameraClip()
                ?? activeCameraClip(at: currentFrame)
                ?? composition.cameraClips.first else {
            compositionCamera = Self.defaultCompositionCamera()
            return
        }
        compositionCamera = interpolatedCamera(clip: clip, at: currentFrame) ?? clip.camera
    }

    private func applyInterpolatedPropertiesToEditableState() {
        syncEditableCameraFromSelection()

        for index in composition.layers.indices {
            var layer = composition.layers[index]
            for property in CompositionLayerKeyframeProperty.allCases
            where hasAnyLayerKeyframes(layer: layer, property: property)
                || hasActiveLayerExpression(layer: layer, property: property) {
                if let value = evaluatedLayerValue(layer: layer, property: property, at: currentFrame) {
                    Self.setLayerValue(value, property: property, layer: &layer)
                }
            }
            if layer.modifiers.contains(where: { !$0.keyframes.isEmpty }) {
                layer.modifiers = resolvedModifiers(layer.modifiers, at: currentFrame)
            }
            composition.layers[index] = layer
        }
    }

    private func interpolatedTransform(for layer: CompositionLayer, at frame: Int) -> VolumeTransformState {
        var transform = layer.transform
        for property in [
            CompositionLayerKeyframeProperty.positionX,
            .positionY,
            .positionZ,
            .rotationX,
            .rotationY,
            .rotationZ,
            .scale,
            .scaleX,
            .scaleY,
            .scaleZ
        ] {
            if let value = evaluatedLayerValue(layer: layer, property: property, at: frame) {
                Self.setLayerTransformValue(value, property: property, transform: &transform)
            }
        }
        return transform
    }

    private func interpolatedOpacity(for layer: CompositionLayer, at frame: Int) -> Float {
        evaluatedLayerValue(layer: layer, property: .opacity, at: frame) ?? layer.opacity
    }

    private func resolvedModifiers(
        _ modifiers: [MeshModifierItem],
        at frame: Int
    ) -> [MeshModifierItem] {
        modifiers.map { modifier in
            var copy = modifier
            copy.state = resolvedModifierState(modifier, at: frame)
            return copy
        }
    }

    private func resolvedModifierState(
        _ modifier: MeshModifierItem,
        at frame: Int
    ) -> MeshModifierState {
        var state = modifier.state
        for property in MeshModifierKeyframeProperty.allCases {
            if let value = interpolatedModifierValue(
                modifier: modifier,
                property: property,
                at: frame
            ) {
                property.set(value, in: &state)
            }
        }
        return state
    }

    private func interpolatedModifierValue(
        modifier: MeshModifierItem,
        property: MeshModifierKeyframeProperty,
        at frame: Int
    ) -> Float? {
        let sorted = modifier.keyframes
            .filter { $0.property == property }
            .sorted { $0.frame < $1.frame }
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first.value }
        if frame <= first.frame { return first.value }
        if let last = sorted.last, frame >= last.frame { return last.value }
        guard let upperIndex = sorted.firstIndex(where: { $0.frame >= frame }),
              upperIndex > 0 else {
            return first.value
        }
        let lower = sorted[upperIndex - 1]
        let upper = sorted[upperIndex]
        if lower.property.isBoolean {
            return frame < upper.frame ? lower.value : upper.value
        }
        let t = interpolationAmount(
            frame: frame,
            lower: lower.frame,
            upper: upper.frame,
            interpolation: lower.interpolation,
            curve: lower.bezierCurve
        )
        return lerp(lower.value, upper.value, t)
    }

    private func resolvedModifierValue(
        _ value: Float,
        property: MeshModifierKeyframeProperty
    ) -> Float {
        switch property {
        case .scaleX, .scaleY, .scaleZ:
            return max(0.01, value)
        case .mirrorX, .mirrorY, .mirrorZ:
            return value >= 0.5 ? 1 : 0
        default:
            return value
        }
    }

    private func interpolatedCamera(clip: CompositionCameraClip, at frame: Int) -> CameraRigState? {
        guard !clip.keyframes.isEmpty || hasActiveCameraExpressions(clip: clip) else { return nil }
        var camera = clip.camera
        for property in CompositionCameraKeyframeProperty.allCases {
            if let value = evaluatedCameraValue(clip: clip, property: property, at: frame) {
                Self.setCameraValue(value, property: property, camera: &camera)
            }
        }
        return camera
    }

    private func hasActiveLayerExpression(
        layer: CompositionLayer,
        property: CompositionLayerKeyframeProperty
    ) -> Bool {
        layer.expressions[property.rawValue]?.isActive == true
    }

    private func hasActiveCameraExpressions(clip: CompositionCameraClip) -> Bool {
        CompositionCameraKeyframeProperty.allCases.contains {
            clip.expressions[$0.rawValue]?.isActive == true
        }
    }

    private func hasActiveCameraExpression(
        clip: CompositionCameraClip,
        property: CompositionCameraKeyframeProperty
    ) -> Bool {
        clip.expressions[property.rawValue]?.isActive == true
    }

    private func evaluatedLayerValue(
        layer: CompositionLayer,
        property: CompositionLayerKeyframeProperty,
        at frame: Int,
        stack: Set<String> = []
    ) -> Float? {
        let keyframed = interpolatedLayerValue(layer: layer, property: property, at: frame)
        let baseInternal = keyframed ?? Self.layerValue(property, layer: layer)
        guard let expression = layer.expressions[property.rawValue], expression.isActive else {
            return keyframed
        }

        let key = expressionKey(scope: "layer", id: layer.id, property: property.rawValue)
        guard !stack.contains(key) else { return baseInternal }
        let baseDisplay = expressionDisplayValue(baseInternal, layerProperty: property)
        guard let value = evaluateExpression(
            expression.source,
            baseValue: baseDisplay,
            frame: frame,
            stack: stack.union([key])
        ) else {
            return baseInternal
        }
        return expressionInternalValue(value, layerProperty: property)
    }

    private func evaluatedCameraValue(
        clip: CompositionCameraClip,
        property: CompositionCameraKeyframeProperty,
        at frame: Int,
        stack: Set<String> = []
    ) -> Float? {
        let keyframed = interpolatedCameraValue(
            keyframes: clip.keyframes,
            property: property,
            at: frame
        )
        let baseInternal = keyframed ?? Self.cameraValue(property, camera: clip.camera)
        guard let expression = clip.expressions[property.rawValue], expression.isActive else {
            return keyframed
        }

        let key = expressionKey(scope: "camera", id: clip.id, property: property.rawValue)
        guard !stack.contains(key) else { return baseInternal }
        let baseDisplay = expressionDisplayValue(baseInternal, cameraProperty: property)
        guard let value = evaluateExpression(
            expression.source,
            baseValue: baseDisplay,
            frame: frame,
            stack: stack.union([key])
        ) else {
            return baseInternal
        }
        return expressionInternalValue(value, cameraProperty: property)
    }

    private func expressionKey(scope: String, id: UUID, property: String) -> String {
        "\(scope):\(id.uuidString):\(property)"
    }

    private func evaluateExpression(
        _ source: String,
        baseValue: Double,
        frame: Int,
        stack: Set<String>
    ) -> Double? {
        let fps = max(0.0001, composition.fps)
        let time = Double(frame) / fps
        let evaluator = CompositionExpressionEvaluator(
            source: source,
            variable: { name in
                switch name.lowercased() {
                case "frame", "x":
                    return Double(frame)
                case "time", "t":
                    return time
                case "fps":
                    return fps
                case "value", "this":
                    return baseValue
                case "pi":
                    return Double.pi
                case "e":
                    return Darwin.M_E
                default:
                    return nil
                }
            },
            function: { [weak self] name, arguments in
                self?.evaluateExpressionFunction(
                    name: name,
                    arguments: arguments,
                    frame: frame,
                    stack: stack
                )
            }
        )
        return try? evaluator.evaluate()
    }

    private func evaluateExpressionFunction(
        name: String,
        arguments: [CompositionExpressionValue],
        frame: Int,
        stack: Set<String>
    ) -> Double? {
        let numbers = arguments.compactMap(\.number)
        switch name.lowercased() {
        case "sin": return numbers.first.map(Darwin.sin)
        case "cos": return numbers.first.map(Darwin.cos)
        case "tan": return numbers.first.map(Darwin.tan)
        case "asin": return numbers.first.map(Darwin.asin)
        case "acos": return numbers.first.map(Darwin.acos)
        case "atan": return numbers.first.map(Darwin.atan)
        case "abs": return numbers.first.map(Darwin.fabs)
        case "sqrt": return numbers.first.map { Darwin.sqrt(max(0, $0)) }
        case "floor": return numbers.first.map(Darwin.floor)
        case "ceil": return numbers.first.map(Darwin.ceil)
        case "round": return numbers.first.map(Darwin.round)
        case "pow":
            guard numbers.count >= 2 else { return nil }
            return Darwin.pow(numbers[0], numbers[1])
        case "min":
            return numbers.min()
        case "max":
            return numbers.max()
        case "clamp":
            guard numbers.count >= 3 else { return nil }
            return max(numbers[1], min(numbers[2], numbers[0]))
        case "lerp", "mix":
            guard numbers.count >= 3 else { return nil }
            return numbers[0] + (numbers[1] - numbers[0]) * numbers[2]
        case "noise":
            guard let x = numbers.first else { return nil }
            let seed = numbers.dropFirst().first ?? 0
            return deterministicNoise(x: x, seed: seed)
        case "layer", "prop":
            guard arguments.count >= 2,
                  let layerName = arguments[0].string,
                  let propertyName = arguments[1].string else { return nil }
            return expressionLayerValue(
                layerName: layerName,
                propertyName: propertyName,
                frame: frame,
                stack: stack
            )
        case "opacity":
            guard let layerName = arguments.first?.string else { return nil }
            return expressionLayerValue(
                layerName: layerName,
                propertyName: CompositionLayerKeyframeProperty.opacity.rawValue,
                frame: frame,
                stack: stack
            )
        case "camera":
            if arguments.count >= 2,
               let cameraName = arguments[0].string,
               let propertyName = arguments[1].string {
                return expressionCameraValue(
                    cameraName: cameraName,
                    propertyName: propertyName,
                    frame: frame,
                    stack: stack
                )
            }
            guard let propertyName = arguments.first?.string else { return nil }
            return expressionCameraValue(
                cameraName: nil,
                propertyName: propertyName,
                frame: frame,
                stack: stack
            )
        case "audio", "audiospectrum", "spectrum":
            return 0
        default:
            return nil
        }
    }

    private func expressionLayerValue(
        layerName: String,
        propertyName: String,
        frame: Int,
        stack: Set<String>
    ) -> Double? {
        guard let property = layerProperty(named: propertyName),
              let layer = expressionLayer(named: layerName) else { return nil }
        let internalValue = evaluatedLayerValue(
            layer: layer,
            property: property,
            at: frame,
            stack: stack
        ) ?? Self.layerValue(property, layer: layer)
        return expressionDisplayValue(internalValue, layerProperty: property)
    }

    private func expressionCameraValue(
        cameraName: String?,
        propertyName: String,
        frame: Int,
        stack: Set<String>
    ) -> Double? {
        guard let property = cameraProperty(named: propertyName) else { return nil }
        let clip: CompositionCameraClip?
        if let cameraName {
            clip = expressionCameraClip(named: cameraName)
        } else {
            clip = selectedCameraClip() ?? activeCameraClip(at: frame) ?? composition.cameraClips.first
        }
        guard let clip else { return nil }
        let internalValue = evaluatedCameraValue(
            clip: clip,
            property: property,
            at: frame,
            stack: stack
        ) ?? Self.cameraValue(property, camera: clip.camera)
        return expressionDisplayValue(internalValue, cameraProperty: property)
    }

    private func expressionLayer(named name: String) -> CompositionLayer? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed),
           let layer = composition.layers.first(where: { $0.id == id }) {
            return layer
        }
        return composition.layers.first { $0.name == trimmed }
            ?? composition.layers.first { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func expressionCameraClip(named name: String) -> CompositionCameraClip? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed),
           let clip = composition.cameraClips.first(where: { $0.id == id }) {
            return clip
        }
        return composition.cameraClips.first { $0.name == trimmed }
            ?? composition.cameraClips.first { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func layerProperty(named name: String) -> CompositionLayerKeyframeProperty? {
        let normalized = normalizedExpressionName(name)
        if let property = CompositionLayerKeyframeProperty.allCases.first(where: {
            normalizedExpressionName($0.rawValue) == normalized
                || normalizedExpressionName($0.title) == normalized
        }) {
            return property
        }
        switch normalized {
        case "x", "posx": return .positionX
        case "y", "posy": return .positionY
        case "z", "posz": return .positionZ
        case "rx", "rotx": return .rotationX
        case "ry", "roty": return .rotationY
        case "rz", "rotz": return .rotationZ
        case "s": return .scale
        case "sx", "scalex": return .scaleX
        case "sy", "scaley": return .scaleY
        case "sz", "scalez": return .scaleZ
        case "st", "scalet": return .scaleZ
        case "alpha": return .opacity
        default: return nil
        }
    }

    private func cameraProperty(named name: String) -> CompositionCameraKeyframeProperty? {
        let normalized = normalizedExpressionName(name)
        if let property = CompositionCameraKeyframeProperty.allCases.first(where: {
            normalizedExpressionName($0.rawValue) == normalized
                || normalizedExpressionName($0.title) == normalized
        }) {
            return property
        }
        switch normalized {
        case "x", "posx": return .positionX
        case "y", "posy": return .positionY
        case "z", "posz": return .positionZ
        case "focusx", "targetx": return .focusTargetX
        case "focusy", "targety": return .focusTargetY
        case "focusz", "targetz": return .focusTargetZ
        case "focal", "focallength": return .focalLength
        case "fstop", "aperture": return .aperture
        default: return nil
        }
    }

    private func normalizedExpressionName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private func expressionDisplayValue(
        _ value: Float,
        layerProperty property: CompositionLayerKeyframeProperty
    ) -> Double {
        switch property {
        case .rotationX, .rotationY, .rotationZ:
            return Double(value) * 180.0 / .pi
        default:
            return Double(value)
        }
    }

    private func expressionInternalValue(
        _ value: Double,
        layerProperty property: CompositionLayerKeyframeProperty
    ) -> Float {
        let converted: Float
        switch property {
        case .rotationX, .rotationY, .rotationZ:
            converted = Float(value * .pi / 180.0)
        default:
            converted = Float(value)
        }
        return Self.resolvedLayerValue(converted, property: property)
    }

    private func expressionDisplayValue(
        _ value: Float,
        cameraProperty property: CompositionCameraKeyframeProperty
    ) -> Double {
        switch property {
        case .yaw, .pitch, .roll:
            return Double(value) * 180.0 / .pi
        default:
            return Double(value)
        }
    }

    private func expressionInternalValue(
        _ value: Double,
        cameraProperty property: CompositionCameraKeyframeProperty
    ) -> Float {
        let converted: Float
        switch property {
        case .yaw, .pitch, .roll:
            converted = Float(value * .pi / 180.0)
        default:
            converted = Float(value)
        }
        return Self.resolvedCameraValue(converted, property: property)
    }

    private func deterministicNoise(x: Double, seed: Double) -> Double {
        let floorX = Darwin.floor(x)
        let fraction = x - floorX
        let a = rawNoise(floorX, seed: seed)
        let b = rawNoise(floorX + 1, seed: seed)
        let smooth = fraction * fraction * (3 - 2 * fraction)
        return a + (b - a) * smooth
    }

    private func rawNoise(_ x: Double, seed: Double) -> Double {
        let v = Darwin.sin(x * 12.9898 + seed * 78.233) * 43758.5453
        return (v - Darwin.floor(v)) * 2 - 1
    }

    private func interpolatedLayerValue(
        layer: CompositionLayer,
        property: CompositionLayerKeyframeProperty,
        at frame: Int
    ) -> Float? {
        let keyframes = layer.keyframes.filter { $0.property == property }
        guard let pair = layerKeyframePair(keyframes, at: frame) else { return nil }
        guard let upper = pair.upper else { return pair.lower.value }
        let t = interpolationAmount(
            frame: frame,
            lower: pair.lower.frame,
            upper: upper.frame,
            interpolation: pair.lower.interpolation,
            curve: pair.lower.bezierCurve
        )
        return lerp(pair.lower.value, upper.value, t)
    }

    private func interpolatedCameraValue(
        keyframes: [CompositionCameraKeyframe],
        property: CompositionCameraKeyframeProperty,
        at frame: Int
    ) -> Float? {
        let matching = keyframes.filter { $0.property == property }
        guard let pair = cameraKeyframePair(matching, at: frame) else { return nil }
        guard let upper = pair.upper else { return pair.lower.value }
        let t = interpolationAmount(
            frame: frame,
            lower: pair.lower.frame,
            upper: upper.frame,
            interpolation: pair.lower.interpolation,
            curve: pair.lower.bezierCurve
        )
        return lerp(pair.lower.value, upper.value, t)
    }

    private func layerKeyframePair(
        _ keyframes: [CompositionLayerKeyframe],
        at frame: Int
    ) -> (lower: CompositionLayerKeyframe, upper: CompositionLayerKeyframe?)? {
        let sorted = keyframes.sorted { $0.frame < $1.frame }
        guard let first = sorted.first else { return nil }
        if sorted.count == 1 || frame <= first.frame {
            return (first, nil)
        }
        if let last = sorted.last, frame >= last.frame {
            return (last, nil)
        }
        guard let upperIndex = sorted.firstIndex(where: { $0.frame >= frame }) else {
            return sorted.last.map { ($0, nil) }
        }
        if sorted[upperIndex].frame == frame {
            return (sorted[upperIndex], nil)
        }
        return (sorted[max(0, upperIndex - 1)], sorted[upperIndex])
    }

    private func cameraKeyframePair(
        _ keyframes: [CompositionCameraKeyframe],
        at frame: Int
    ) -> (lower: CompositionCameraKeyframe, upper: CompositionCameraKeyframe?)? {
        let sorted = keyframes.sorted { $0.frame < $1.frame }
        guard let first = sorted.first else { return nil }
        if sorted.count == 1 || frame <= first.frame {
            return (first, nil)
        }
        if let last = sorted.last, frame >= last.frame {
            return (last, nil)
        }
        guard let upperIndex = sorted.firstIndex(where: { $0.frame >= frame }) else {
            return sorted.last.map { ($0, nil) }
        }
        if sorted[upperIndex].frame == frame {
            return (sorted[upperIndex], nil)
        }
        return (sorted[max(0, upperIndex - 1)], sorted[upperIndex])
    }

    private func interpolationAmount(
        frame: Int,
        lower: Int,
        upper: Int,
        interpolation: CompositionKeyframeInterpolation,
        curve: CompositionBezierCurve
    ) -> Float {
        let span = max(1, upper - lower)
        let linear = max(0, min(1, Float(frame - lower) / Float(span)))
        switch interpolation {
        case .linear:
            return linear
        case .easeInOut:
            return linear * linear * (3 - 2 * linear)
        case .hold:
            return 0
        case .bezier:
            return cubicBezierY(forX: linear, curve: Self.sanitizedBezierCurve(curve))
        }
    }

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    private func cubicBezierY(forX x: Float, curve: CompositionBezierCurve) -> Float {
        let epsilon: Float = 0.0001
        var lower: Float = 0
        var upper: Float = 1
        var t = x

        for _ in 0..<12 {
            let currentX = cubicBezierValue(t, p1: curve.controlPoint1X, p2: curve.controlPoint2X)
            let delta = currentX - x
            if abs(delta) < epsilon { break }
            if delta > 0 {
                upper = t
            } else {
                lower = t
            }
            t = (lower + upper) * 0.5
        }

        return cubicBezierValue(t, p1: curve.controlPoint1Y, p2: curve.controlPoint2Y)
    }

    private func cubicBezierValue(_ t: Float, p1: Float, p2: Float) -> Float {
        let oneMinusT = 1 - t
        return 3 * oneMinusT * oneMinusT * t * p1
            + 3 * oneMinusT * t * t * p2
            + t * t * t
    }

    private func hasAnyCameraKeyframes(for property: CompositionCameraKeyframeProperty) -> Bool {
        selectedCameraClip()?.keyframes.contains { $0.property == property } ?? false
    }

    private func hasAnyLayerKeyframes(
        layer: CompositionLayer,
        property: CompositionLayerKeyframeProperty
    ) -> Bool {
        layer.keyframes.contains { $0.property == property }
    }

    private static func cameraValue(
        _ property: CompositionCameraKeyframeProperty,
        camera: CameraRigState
    ) -> Float {
        switch property {
        case .yaw: return camera.yaw
        case .pitch: return camera.pitch
        case .roll: return camera.roll
        case .positionX: return camera.positionX
        case .positionY: return camera.positionY
        case .positionZ: return camera.positionZ
        case .focusTargetX: return camera.focusTargetX
        case .focusTargetY: return camera.focusTargetY
        case .focusTargetZ: return camera.focusTargetZ
        case .focalLength: return camera.focalLength
        case .aperture: return camera.aperture
        }
    }

    private static func setCameraValue(
        _ value: Float,
        property: CompositionCameraKeyframeProperty,
        camera: inout CameraRigState
    ) {
        switch property {
        case .yaw: camera.yaw = value
        case .pitch: camera.pitch = value
        case .roll: camera.roll = value
        case .positionX: camera.positionX = value
        case .positionY: camera.positionY = value
        case .positionZ: camera.positionZ = value
        case .focusTargetX: camera.focusTargetX = value
        case .focusTargetY: camera.focusTargetY = value
        case .focusTargetZ: camera.focusTargetZ = value
        case .focalLength: camera.focalLength = max(1, value)
        case .aperture: camera.aperture = max(0.1, value)
        }
    }

    private static func resolvedCameraValue(
        _ value: Float,
        property: CompositionCameraKeyframeProperty
    ) -> Float {
        switch property {
        case .focalLength:
            return max(1, value)
        case .aperture:
            return max(0.1, value)
        default:
            return value
        }
    }

    private static func layerValue(
        _ property: CompositionLayerKeyframeProperty,
        layer: CompositionLayer
    ) -> Float {
        switch property {
        case .positionX: return layer.transform.positionX
        case .positionY: return layer.transform.positionY
        case .positionZ: return layer.transform.positionZ
        case .rotationX: return layer.transform.rotationX
        case .rotationY: return layer.transform.rotationY
        case .rotationZ: return layer.transform.rotationZ
        case .scale: return layer.transform.scale
        case .scaleX: return layer.transform.scaleX
        case .scaleY: return layer.transform.scaleY
        case .scaleZ: return layer.transform.scaleZ
        case .opacity: return layer.opacity
        }
    }

    private static let scaleAxisProperties: [CompositionLayerKeyframeProperty] = [
        .scaleX,
        .scaleY,
        .scaleZ
    ]

    private static func isScaleAxisLinked(
        _ property: CompositionLayerKeyframeProperty,
        transform: VolumeTransformState
    ) -> Bool {
        switch property {
        case .scaleX:
            return transform.scaleXLinked
        case .scaleY:
            return transform.scaleYLinked
        case .scaleZ:
            return transform.scaleZLinked
        default:
            return false
        }
    }

    private static func setScaleAxisLinked(
        _ isLinked: Bool,
        property: CompositionLayerKeyframeProperty,
        transform: inout VolumeTransformState
    ) {
        switch property {
        case .scaleX:
            transform.scaleXLinked = isLinked
        case .scaleY:
            transform.scaleYLinked = isLinked
        case .scaleZ:
            transform.scaleZLinked = isLinked
        default:
            break
        }
    }

    private static func linkedScaleAxisProperties(
        for property: CompositionLayerKeyframeProperty,
        transform: VolumeTransformState
    ) -> [CompositionLayerKeyframeProperty] {
        guard property.isScaleAxis,
              isScaleAxisLinked(property, transform: transform) else {
            return [property]
        }
        let linked = scaleAxisProperties.filter {
            isScaleAxisLinked($0, transform: transform)
        }
        return linked.isEmpty ? [property] : linked
    }

    private static func resolvedLayerValue(
        _ value: Float,
        property: CompositionLayerKeyframeProperty
    ) -> Float {
        switch property {
        case .scale, .scaleX, .scaleY, .scaleZ:
            return max(0.01, value)
        case .opacity:
            return max(0, min(1, value))
        default:
            return value
        }
    }

    private static func nearlyEqual(_ lhs: Float, _ rhs: Float, epsilon: Float = 0.00001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    private static func sanitizedBezierCurve(_ curve: CompositionBezierCurve) -> CompositionBezierCurve {
        CompositionBezierCurve(
            controlPoint1X: max(0, min(1, curve.controlPoint1X)),
            controlPoint1Y: max(-3, min(3, curve.controlPoint1Y)),
            controlPoint2X: max(0, min(1, curve.controlPoint2X)),
            controlPoint2Y: max(-3, min(3, curve.controlPoint2Y))
        )
    }

    private static func normalizedVolumeScale(width: Int, height: Int, depth: Int) -> SIMD3<Float> {
        let w = max(1, width)
        let h = max(1, height)
        let d = max(1, depth)
        let maxDim = Float(max(w, max(h, d)))
        return SIMD3<Float>(
            Float(w) / maxDim,
            Float(h) / maxDim,
            Float(d) / maxDim
        )
    }

    private static func setLayerValue(
        _ value: Float,
        property: CompositionLayerKeyframeProperty,
        layer: inout CompositionLayer
    ) {
        switch property {
        case .positionX: layer.transform.positionX = value
        case .positionY: layer.transform.positionY = value
        case .positionZ: layer.transform.positionZ = value
        case .rotationX: layer.transform.rotationX = value
        case .rotationY: layer.transform.rotationY = value
        case .rotationZ: layer.transform.rotationZ = value
        case .scale: layer.transform.scale = max(0.01, value)
        case .scaleX: layer.transform.scaleX = max(0.01, value)
        case .scaleY: layer.transform.scaleY = max(0.01, value)
        case .scaleZ: layer.transform.scaleZ = max(0.01, value)
        case .opacity: layer.opacity = max(0, min(1, value))
        }
    }

    private static func setLayerTransformValue(
        _ value: Float,
        property: CompositionLayerKeyframeProperty,
        transform: inout VolumeTransformState
    ) {
        switch property {
        case .positionX: transform.positionX = value
        case .positionY: transform.positionY = value
        case .positionZ: transform.positionZ = value
        case .rotationX: transform.rotationX = value
        case .rotationY: transform.rotationY = value
        case .rotationZ: transform.rotationZ = value
        case .scale: transform.scale = max(0.01, value)
        case .scaleX: transform.scaleX = max(0.01, value)
        case .scaleY: transform.scaleY = max(0.01, value)
        case .scaleZ: transform.scaleZ = max(0.01, value)
        case .opacity: break
        }
    }
}

private enum CompositionExpressionValue {
    case number(Double)
    case string(String)

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

private struct CompositionExpressionEvaluator {
    enum EvaluationError: Error {
        case invalidToken
        case expectedExpression
        case expectedToken
        case unknownIdentifier(String)
        case unknownFunction(String)
        case nonNumericValue
    }

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case string(String)
        case plus
        case minus
        case star
        case slash
        case percent
        case caret
        case leftParen
        case rightParen
        case comma
        case eof
    }

    let source: String
    let variable: (String) -> Double?
    let function: (String, [CompositionExpressionValue]) -> Double?

    func evaluate() throws -> Double {
        var parser = Parser(
            tokens: try tokenize(source),
            variable: variable,
            function: function
        )
        let value = try parser.parseExpression().numberValue()
        try parser.expectEnd()
        return value
    }

    private func tokenize(_ source: String) throws -> [Token] {
        let characters = Array(source)
        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }

            if character.isNumber || character == "." {
                let start = index
                var sawDot = character == "."
                index += 1
                while index < characters.count {
                    let next = characters[index]
                    if next.isNumber {
                        index += 1
                    } else if next == ".", !sawDot {
                        sawDot = true
                        index += 1
                    } else {
                        break
                    }
                }
                let text = String(characters[start..<index])
                guard let value = Double(text) else { throw EvaluationError.invalidToken }
                tokens.append(.number(value))
                continue
            }

            if character.isLetter || character == "_" {
                let start = index
                index += 1
                while index < characters.count {
                    let next = characters[index]
                    if next.isLetter || next.isNumber || next == "_" {
                        index += 1
                    } else {
                        break
                    }
                }
                tokens.append(.identifier(String(characters[start..<index])))
                continue
            }

            if character == "\"" || character == "'" {
                let quote = character
                index += 1
                var value = ""
                while index < characters.count {
                    let next = characters[index]
                    if next == quote {
                        index += 1
                        tokens.append(.string(value))
                        value = ""
                        break
                    }
                    if next == "\\", index + 1 < characters.count {
                        index += 1
                        value.append(characters[index])
                    } else {
                        value.append(next)
                    }
                    index += 1
                }
                guard value.isEmpty else { throw EvaluationError.invalidToken }
                continue
            }

            switch character {
            case "+": tokens.append(.plus)
            case "-": tokens.append(.minus)
            case "*": tokens.append(.star)
            case "/": tokens.append(.slash)
            case "%": tokens.append(.percent)
            case "^": tokens.append(.caret)
            case "(": tokens.append(.leftParen)
            case ")": tokens.append(.rightParen)
            case ",": tokens.append(.comma)
            default: throw EvaluationError.invalidToken
            }
            index += 1
        }

        tokens.append(.eof)
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        let variable: (String) -> Double?
        let function: (String, [CompositionExpressionValue]) -> Double?
        var index: Int = 0

        mutating func parseExpression() throws -> CompositionExpressionValue {
            try parseAddition()
        }

        mutating func expectEnd() throws {
            guard peek == .eof else { throw EvaluationError.expectedToken }
        }

        private mutating func parseAddition() throws -> CompositionExpressionValue {
            var value = try parseMultiplication().numberValue()
            while true {
                if match(.plus) {
                    value += try parseMultiplication().numberValue()
                } else if match(.minus) {
                    value -= try parseMultiplication().numberValue()
                } else {
                    break
                }
            }
            return .number(value)
        }

        private mutating func parseMultiplication() throws -> CompositionExpressionValue {
            var value = try parsePower().numberValue()
            while true {
                if match(.star) {
                    value *= try parsePower().numberValue()
                } else if match(.slash) {
                    value /= try parsePower().numberValue()
                } else if match(.percent) {
                    value = value.truncatingRemainder(dividingBy: try parsePower().numberValue())
                } else {
                    break
                }
            }
            return .number(value)
        }

        private mutating func parsePower() throws -> CompositionExpressionValue {
            var value = try parseUnary().numberValue()
            if match(.caret) {
                value = Darwin.pow(value, try parsePower().numberValue())
            }
            return .number(value)
        }

        private mutating func parseUnary() throws -> CompositionExpressionValue {
            if match(.plus) {
                return try parseUnary()
            }
            if match(.minus) {
                return .number(-(try parseUnary().numberValue()))
            }
            return try parsePrimary()
        }

        private mutating func parsePrimary() throws -> CompositionExpressionValue {
            switch advance() {
            case .number(let value):
                return .number(value)
            case .string(let value):
                return .string(value)
            case .identifier(let name):
                if match(.leftParen) {
                    var arguments: [CompositionExpressionValue] = []
                    if !match(.rightParen) {
                        repeat {
                            arguments.append(try parseExpression())
                        } while match(.comma)
                        guard match(.rightParen) else { throw EvaluationError.expectedToken }
                    }
                    guard let value = function(name, arguments) else {
                        throw EvaluationError.unknownFunction(name)
                    }
                    return .number(value)
                }
                guard let value = variable(name) else {
                    throw EvaluationError.unknownIdentifier(name)
                }
                return .number(value)
            case .leftParen:
                let value = try parseExpression()
                guard match(.rightParen) else { throw EvaluationError.expectedToken }
                return value
            default:
                throw EvaluationError.expectedExpression
            }
        }

        private var peek: Token {
            tokens[min(index, tokens.count - 1)]
        }

        private mutating func advance() -> Token {
            let token = peek
            index = min(index + 1, tokens.count)
            return token
        }

        private mutating func match(_ token: Token) -> Bool {
            guard peek == token else { return false }
            index = min(index + 1, tokens.count)
            return true
        }
    }
}

private extension CompositionExpressionValue {
    func numberValue() throws -> Double {
        guard let number else { throw CompositionExpressionEvaluator.EvaluationError.nonNumericValue }
        return number
    }
}

extension LoadedVolume {
    func normalizedVolumeScale() -> SIMD3<Float> {
        let maxDim = Float(max(width, max(height, depth)))
        return SIMD3<Float>(
            Float(width) / maxDim,
            Float(height) / maxDim,
            Float(depth) / maxDim
        )
    }
}
