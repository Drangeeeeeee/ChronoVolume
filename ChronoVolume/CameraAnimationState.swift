import Foundation

enum VolumeBackgroundMode: String, CaseIterable, Identifiable, Codable {
    case color
    case checkerboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color:
            return "纯色"
        case .checkerboard:
            return "棋盘格"
        }
    }
}

struct VolumeBackgroundColor: Equatable, Codable {
    var red: Double = 0
    var green: Double = 0
    var blue: Double = 0
}

struct CameraRigState: Equatable, Codable {
    var yaw: Float = 0
    var pitch: Float = 0
    var roll: Float = 0
    var distance: Float = 2.2
    var positionX: Float = 0
    var positionY: Float = 0
    var positionZ: Float = 0
    var focusLockEnabled: Bool = false
    var focusTargetX: Float = 0
    var focusTargetY: Float = 0
    var focusTargetZ: Float = 0
    var focalLength: Float = 50
    var aperture: Float = 5.6
}

struct VolumeTransformState: Equatable, Codable {
    var positionX: Float = 0
    var positionY: Float = 0
    var positionZ: Float = 0
    var rotationX: Float = 0
    var rotationY: Float = 0
    var rotationZ: Float = 0
    var scaleX: Float = 1
    var scaleY: Float = 1
    var scaleZ: Float = 1
    var scaleXLinked: Bool = true
    var scaleYLinked: Bool = true
    var scaleZLinked: Bool = true

    var isScaleLinked: Bool {
        get { scaleXLinked && scaleYLinked && scaleZLinked }
        set {
            scaleXLinked = newValue
            scaleYLinked = newValue
            scaleZLinked = newValue
        }
    }

    var scale: Float {
        get { scaleX }
        set {
            let value = max(0.01, newValue)
            scaleX = value
            scaleY = value
            scaleZ = value
        }
    }

    private enum CodingKeys: String, CodingKey {
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
        case scaleXLinked
        case scaleYLinked
        case scaleZLinked
        case isScaleLinked
    }

    init(
        positionX: Float = 0,
        positionY: Float = 0,
        positionZ: Float = 0,
        rotationX: Float = 0,
        rotationY: Float = 0,
        rotationZ: Float = 0,
        scale: Float = 1,
        scaleX: Float? = nil,
        scaleY: Float? = nil,
        scaleZ: Float? = nil,
        isScaleLinked: Bool = true,
        scaleXLinked: Bool? = nil,
        scaleYLinked: Bool? = nil,
        scaleZLinked: Bool? = nil
    ) {
        self.positionX = positionX
        self.positionY = positionY
        self.positionZ = positionZ
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.rotationZ = rotationZ
        self.scaleX = max(0.01, scaleX ?? scale)
        self.scaleY = max(0.01, scaleY ?? scale)
        self.scaleZ = max(0.01, scaleZ ?? scale)
        self.scaleXLinked = scaleXLinked ?? isScaleLinked
        self.scaleYLinked = scaleYLinked ?? isScaleLinked
        self.scaleZLinked = scaleZLinked ?? isScaleLinked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        positionX = try container.decodeIfPresent(Float.self, forKey: .positionX) ?? 0
        positionY = try container.decodeIfPresent(Float.self, forKey: .positionY) ?? 0
        positionZ = try container.decodeIfPresent(Float.self, forKey: .positionZ) ?? 0
        rotationX = try container.decodeIfPresent(Float.self, forKey: .rotationX) ?? 0
        rotationY = try container.decodeIfPresent(Float.self, forKey: .rotationY) ?? 0
        rotationZ = try container.decodeIfPresent(Float.self, forKey: .rotationZ) ?? 0

        let legacyScale = max(0.01, try container.decodeIfPresent(Float.self, forKey: .scale) ?? 1)
        scaleX = max(0.01, try container.decodeIfPresent(Float.self, forKey: .scaleX) ?? legacyScale)
        scaleY = max(0.01, try container.decodeIfPresent(Float.self, forKey: .scaleY) ?? legacyScale)
        scaleZ = max(0.01, try container.decodeIfPresent(Float.self, forKey: .scaleZ) ?? legacyScale)
        let legacyLinked = try container.decodeIfPresent(Bool.self, forKey: .isScaleLinked) ?? true
        scaleXLinked = try container.decodeIfPresent(Bool.self, forKey: .scaleXLinked) ?? legacyLinked
        scaleYLinked = try container.decodeIfPresent(Bool.self, forKey: .scaleYLinked) ?? legacyLinked
        scaleZLinked = try container.decodeIfPresent(Bool.self, forKey: .scaleZLinked) ?? legacyLinked
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(positionX, forKey: .positionX)
        try container.encode(positionY, forKey: .positionY)
        try container.encode(positionZ, forKey: .positionZ)
        try container.encode(rotationX, forKey: .rotationX)
        try container.encode(rotationY, forKey: .rotationY)
        try container.encode(rotationZ, forKey: .rotationZ)
        try container.encode(scale, forKey: .scale)
        try container.encode(scaleX, forKey: .scaleX)
        try container.encode(scaleY, forKey: .scaleY)
        try container.encode(scaleZ, forKey: .scaleZ)
        try container.encode(scaleXLinked, forKey: .scaleXLinked)
        try container.encode(scaleYLinked, forKey: .scaleYLinked)
        try container.encode(scaleZLinked, forKey: .scaleZLinked)
        try container.encode(isScaleLinked, forKey: .isScaleLinked)
    }
}

enum VoxelInflateMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case alphaBounds
    case surfaceSDF
    case fracturedSurface
    case volumeCenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphaBounds: return "Alpha边界"
        case .surfaceSDF: return "SDF表面"
        case .fracturedSurface: return "破碎表面"
        case .volumeCenter: return "体中心"
        }
    }
}

struct MeshModifierState: Equatable, Codable, Sendable {
    var positionX: Float = 0
    var positionY: Float = 0
    var positionZ: Float = 0
    var rotationX: Float = 0
    var rotationY: Float = 0
    var rotationZ: Float = 0
    var scaleX: Float = 1
    var scaleY: Float = 1
    var scaleZ: Float = 1
    var inflate: Float = 0
    var inflateMode: VoxelInflateMode = .alphaBounds
    var twistY: Float = 0
    var taperX: Float = 0
    var taperZ: Float = 0
    var mirrorX: Bool = false
    var mirrorY: Bool = false
    var mirrorZ: Bool = false

    var isIdentity: Bool {
        abs(positionX) < 0.000_001 &&
        abs(positionY) < 0.000_001 &&
        abs(positionZ) < 0.000_001 &&
        abs(rotationX) < 0.000_001 &&
        abs(rotationY) < 0.000_001 &&
        abs(rotationZ) < 0.000_001 &&
        abs(scaleX - 1) < 0.000_001 &&
        abs(scaleY - 1) < 0.000_001 &&
        abs(scaleZ - 1) < 0.000_001 &&
        abs(inflate) < 0.000_001 &&
        abs(twistY) < 0.000_001 &&
        abs(taperX) < 0.000_001 &&
        abs(taperZ) < 0.000_001 &&
        !mirrorX &&
        !mirrorY &&
        !mirrorZ
    }

    private enum CodingKeys: String, CodingKey {
        case positionX
        case positionY
        case positionZ
        case rotationX
        case rotationY
        case rotationZ
        case scaleX
        case scaleY
        case scaleZ
        case inflate
        case inflateMode
        case twistY
        case taperX
        case taperZ
        case mirrorX
        case mirrorY
        case mirrorZ
    }

    init(
        positionX: Float = 0,
        positionY: Float = 0,
        positionZ: Float = 0,
        rotationX: Float = 0,
        rotationY: Float = 0,
        rotationZ: Float = 0,
        scaleX: Float = 1,
        scaleY: Float = 1,
        scaleZ: Float = 1,
        inflate: Float = 0,
        inflateMode: VoxelInflateMode = .alphaBounds,
        twistY: Float = 0,
        taperX: Float = 0,
        taperZ: Float = 0,
        mirrorX: Bool = false,
        mirrorY: Bool = false,
        mirrorZ: Bool = false
    ) {
        self.positionX = positionX
        self.positionY = positionY
        self.positionZ = positionZ
        self.rotationX = rotationX
        self.rotationY = rotationY
        self.rotationZ = rotationZ
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.scaleZ = scaleZ
        self.inflate = inflate
        self.inflateMode = inflateMode
        self.twistY = twistY
        self.taperX = taperX
        self.taperZ = taperZ
        self.mirrorX = mirrorX
        self.mirrorY = mirrorY
        self.mirrorZ = mirrorZ
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        positionX = try container.decodeIfPresent(Float.self, forKey: .positionX) ?? 0
        positionY = try container.decodeIfPresent(Float.self, forKey: .positionY) ?? 0
        positionZ = try container.decodeIfPresent(Float.self, forKey: .positionZ) ?? 0
        rotationX = try container.decodeIfPresent(Float.self, forKey: .rotationX) ?? 0
        rotationY = try container.decodeIfPresent(Float.self, forKey: .rotationY) ?? 0
        rotationZ = try container.decodeIfPresent(Float.self, forKey: .rotationZ) ?? 0
        scaleX = try container.decodeIfPresent(Float.self, forKey: .scaleX) ?? 1
        scaleY = try container.decodeIfPresent(Float.self, forKey: .scaleY) ?? 1
        scaleZ = try container.decodeIfPresent(Float.self, forKey: .scaleZ) ?? 1
        inflate = try container.decodeIfPresent(Float.self, forKey: .inflate) ?? 0
        inflateMode = try container.decodeIfPresent(VoxelInflateMode.self, forKey: .inflateMode) ?? .alphaBounds
        twistY = try container.decodeIfPresent(Float.self, forKey: .twistY) ?? 0
        taperX = try container.decodeIfPresent(Float.self, forKey: .taperX) ?? 0
        taperZ = try container.decodeIfPresent(Float.self, forKey: .taperZ) ?? 0
        mirrorX = try container.decodeIfPresent(Bool.self, forKey: .mirrorX) ?? false
        mirrorY = try container.decodeIfPresent(Bool.self, forKey: .mirrorY) ?? false
        mirrorZ = try container.decodeIfPresent(Bool.self, forKey: .mirrorZ) ?? false
    }
}

enum MeshModifierKeyframeProperty: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case positionX
    case positionY
    case positionZ
    case rotationX
    case rotationY
    case rotationZ
    case scaleX
    case scaleY
    case scaleZ
    case inflate
    case twistY
    case taperX
    case taperZ
    case mirrorX
    case mirrorY
    case mirrorZ

    var id: String { rawValue }

    var title: String {
        switch self {
        case .positionX: return "位置 X"
        case .positionY: return "位置 Y"
        case .positionZ: return "位置 Z"
        case .rotationX: return "旋转 X"
        case .rotationY: return "旋转 Y"
        case .rotationZ: return "旋转 Z"
        case .scaleX: return "缩放 X"
        case .scaleY: return "缩放 Y"
        case .scaleZ: return "缩放 Z"
        case .inflate: return "膨胀"
        case .twistY: return "扭转 Y"
        case .taperX: return "锥形 X"
        case .taperZ: return "锥形 Z"
        case .mirrorX: return "镜像 X"
        case .mirrorY: return "镜像 Y"
        case .mirrorZ: return "镜像 Z"
        }
    }

    var isAngle: Bool {
        switch self {
        case .rotationX, .rotationY, .rotationZ, .twistY:
            return true
        default:
            return false
        }
    }

    var isBoolean: Bool {
        switch self {
        case .mirrorX, .mirrorY, .mirrorZ:
            return true
        default:
            return false
        }
    }

    func value(from state: MeshModifierState) -> Float {
        switch self {
        case .positionX: return state.positionX
        case .positionY: return state.positionY
        case .positionZ: return state.positionZ
        case .rotationX: return state.rotationX
        case .rotationY: return state.rotationY
        case .rotationZ: return state.rotationZ
        case .scaleX: return state.scaleX
        case .scaleY: return state.scaleY
        case .scaleZ: return state.scaleZ
        case .inflate: return state.inflate
        case .twistY: return state.twistY
        case .taperX: return state.taperX
        case .taperZ: return state.taperZ
        case .mirrorX: return state.mirrorX ? 1 : 0
        case .mirrorY: return state.mirrorY ? 1 : 0
        case .mirrorZ: return state.mirrorZ ? 1 : 0
        }
    }

    func set(_ value: Float, in state: inout MeshModifierState) {
        switch self {
        case .positionX: state.positionX = value
        case .positionY: state.positionY = value
        case .positionZ: state.positionZ = value
        case .rotationX: state.rotationX = value
        case .rotationY: state.rotationY = value
        case .rotationZ: state.rotationZ = value
        case .scaleX: state.scaleX = max(0.01, value)
        case .scaleY: state.scaleY = max(0.01, value)
        case .scaleZ: state.scaleZ = max(0.01, value)
        case .inflate: state.inflate = value
        case .twistY: state.twistY = value
        case .taperX: state.taperX = value
        case .taperZ: state.taperZ = value
        case .mirrorX: state.mirrorX = value >= 0.5
        case .mirrorY: state.mirrorY = value >= 0.5
        case .mirrorZ: state.mirrorZ = value >= 0.5
        }
    }
}

struct MeshModifierKeyframe: Identifiable, Equatable, Codable, Sendable {
    var id: String { "\(modifierID.uuidString)-\(property.rawValue)-\(frame)" }
    var modifierID: UUID
    var frame: Int
    var property: MeshModifierKeyframeProperty
    var value: Float
    var interpolation: CompositionKeyframeInterpolation
    var bezierCurve: CompositionBezierCurve

    private enum CodingKeys: String, CodingKey {
        case modifierID
        case frame
        case property
        case value
        case interpolation
        case bezierCurve
    }

    init(
        modifierID: UUID,
        frame: Int,
        property: MeshModifierKeyframeProperty,
        value: Float,
        interpolation: CompositionKeyframeInterpolation = .linear,
        bezierCurve: CompositionBezierCurve = .default
    ) {
        self.modifierID = modifierID
        self.frame = frame
        self.property = property
        self.value = value
        self.interpolation = interpolation
        self.bezierCurve = bezierCurve
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modifierID = try container.decode(UUID.self, forKey: .modifierID)
        frame = try container.decode(Int.self, forKey: .frame)
        property = try container.decode(MeshModifierKeyframeProperty.self, forKey: .property)
        value = try container.decode(Float.self, forKey: .value)
        interpolation = try container.decodeIfPresent(CompositionKeyframeInterpolation.self, forKey: .interpolation) ?? .linear
        bezierCurve = try container.decodeIfPresent(CompositionBezierCurve.self, forKey: .bezierCurve) ?? .default
    }

    func moved(to frame: Int) -> MeshModifierKeyframe {
        var copy = self
        copy.frame = frame
        return copy
    }
}

struct MeshModifierItem: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var state: MeshModifierState
    var keyframes: [MeshModifierKeyframe]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled
        case state
        case keyframes
    }

    init(
        id: UUID = UUID(),
        name: String = "变换",
        isEnabled: Bool = true,
        state: MeshModifierState = MeshModifierState(),
        keyframes: [MeshModifierKeyframe] = []
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.state = state
        self.keyframes = keyframes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "变换"
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        state = try container.decodeIfPresent(MeshModifierState.self, forKey: .state) ?? MeshModifierState()
        keyframes = try container.decodeIfPresent([MeshModifierKeyframe].self, forKey: .keyframes) ?? []
    }
}

struct CameraKeyframe: Identifiable, Equatable, Codable {
    let id: UUID
    var frame: Int
    var camera: CameraRigState

    init(id: UUID = UUID(), frame: Int, camera: CameraRigState) {
        self.id = id
        self.frame = frame
        self.camera = camera
    }
}

enum CameraExportSizeMode: String, CaseIterable, Identifiable, Codable {
    case preview
    case source
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview:
            return "摄像机视图尺寸"
        case .source:
            return "源视频尺寸"
        case .custom:
            return "自定义"
        }
    }
}

enum CameraExportFPSMode: String, CaseIterable, Identifiable, Codable {
    case source
    case timeline
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source:
            return "源视频 FPS"
        case .timeline:
            return "时间线 FPS"
        case .custom:
            return "自定义"
        }
    }
}

enum CameraExportBackgroundMode: String, CaseIterable, Identifiable, Codable {
    case white
    case current
    case color
    case checkerboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white:
            return "白色"
        case .current:
            return "当前3D背景"
        case .color:
            return "自定义颜色"
        case .checkerboard:
            return "棋盘格"
        }
    }
}
