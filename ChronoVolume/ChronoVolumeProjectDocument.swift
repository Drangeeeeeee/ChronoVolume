import Foundation

struct ChronoVolumeProjectDocument: Codable {
    static let fileExtension = "CV"
    static let legacyFileExtension = "chronovolume"
    static let currentFormatVersion = 2

    var formatVersion: Int = Self.currentFormatVersion
    var savedAt: Date = Date()
    var autosaveOriginalProjectPath: String?
    var autosaveCreatedAt: Date?
    var selectedTab: Int = 0
    var mainVideos: [MainVideoRecord] = []
    var selectedMainVideoID: UUID?
    var appState = AppProjectState()
    var exportOptions = ExportOptionsProjectState()
    var distributed = DistributedExportProjectState()
    var composition = CompositionProjectState()

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case savedAt
        case autosaveOriginalProjectPath
        case autosaveCreatedAt
        case selectedTab
        case mainVideos
        case selectedMainVideoID
        case appState
        case exportOptions
        case distributed
        case composition
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
        autosaveOriginalProjectPath = try container.decodeIfPresent(String.self, forKey: .autosaveOriginalProjectPath)
        autosaveCreatedAt = try container.decodeIfPresent(Date.self, forKey: .autosaveCreatedAt)
        selectedTab = try container.decodeIfPresent(Int.self, forKey: .selectedTab) ?? 0
        mainVideos = try container.decodeIfPresent([MainVideoRecord].self, forKey: .mainVideos) ?? []
        selectedMainVideoID = try container.decodeIfPresent(UUID.self, forKey: .selectedMainVideoID)
        appState = try container.decodeIfPresent(AppProjectState.self, forKey: .appState) ?? AppProjectState()
        exportOptions = try container.decodeIfPresent(ExportOptionsProjectState.self, forKey: .exportOptions) ?? ExportOptionsProjectState()
        distributed = try container.decodeIfPresent(DistributedExportProjectState.self, forKey: .distributed) ?? DistributedExportProjectState()
        composition = try container.decodeIfPresent(CompositionProjectState.self, forKey: .composition) ?? CompositionProjectState()
        try migrateToCurrentFormat()
    }

    private mutating func migrateToCurrentFormat() throws {
        guard formatVersion <= Self.currentFormatVersion else {
            throw ChronoVolumeProjectDocumentError.unsupportedFormatVersion(
                found: formatVersion,
                supported: Self.currentFormatVersion
            )
        }

        if formatVersion < 2 {
            autosaveOriginalProjectPath = nil
            autosaveCreatedAt = nil
        }
        formatVersion = Self.currentFormatVersion
    }

    struct MainVideoRecord: Identifiable, Codable, Hashable {
        var id: UUID
        var path: String
        var name: String

        var url: URL {
            URL(fileURLWithPath: path)
        }
    }

    struct CompositionAssetRecord: Identifiable, Codable, Equatable {
        var id: UUID
        var kind: CompositionAssetKind = .video
        var path: String
        var name: String
        var sourceWidth: Int
        var sourceHeight: Int
        var sourceFrameCount: Int
        var sourceFPS: Double
        var sourceBitDepth: Int
        var sourceColorProfile: VideoColorProfile
        var precomposition: CompositionDocumentState?

        var url: URL {
            URL(fileURLWithPath: path)
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case kind
            case path
            case name
            case sourceWidth
            case sourceHeight
            case sourceFrameCount
            case sourceFPS
            case sourceBitDepth
            case sourceColorProfile
            case precomposition
        }

        init(
            id: UUID,
            kind: CompositionAssetKind = .video,
            path: String,
            name: String,
            sourceWidth: Int,
            sourceHeight: Int,
            sourceFrameCount: Int,
            sourceFPS: Double,
            sourceBitDepth: Int,
            sourceColorProfile: VideoColorProfile = .rec709,
            precomposition: CompositionDocumentState? = nil
        ) {
            self.id = id
            self.kind = kind
            self.path = path
            self.name = name
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
            self.sourceFrameCount = sourceFrameCount
            self.sourceFPS = sourceFPS
            self.sourceBitDepth = sourceBitDepth
            self.sourceColorProfile = sourceColorProfile
            self.precomposition = precomposition
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            kind = try container.decodeIfPresent(CompositionAssetKind.self, forKey: .kind) ?? .video
            path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
            name = try container.decode(String.self, forKey: .name)
            sourceWidth = try container.decodeIfPresent(Int.self, forKey: .sourceWidth) ?? 0
            sourceHeight = try container.decodeIfPresent(Int.self, forKey: .sourceHeight) ?? 0
            sourceFrameCount = try container.decodeIfPresent(Int.self, forKey: .sourceFrameCount) ?? 0
            sourceFPS = try container.decodeIfPresent(Double.self, forKey: .sourceFPS) ?? 0
            sourceBitDepth = try container.decodeIfPresent(Int.self, forKey: .sourceBitDepth) ?? 8
            sourceColorProfile = try container.decodeIfPresent(VideoColorProfile.self, forKey: .sourceColorProfile)
                ?? .rec709
            precomposition = try container.decodeIfPresent(CompositionDocumentState.self, forKey: .precomposition)
        }
    }

    struct AppProjectState: Codable, Equatable {
        var useAlpha: Bool = true
        var steps: Int = 192
        var density: Double = 1.1
        var brightness: Double = 1.6
        var useVoxelBlockRendering: Bool = false
        var smoothVolumeEdges: Bool = false
        var volumeBackgroundMode: VolumeBackgroundMode = .color
        var volumeBackgroundColor = VolumeBackgroundColor()
        var volumeTransform = VolumeTransformState()
        var meshModifierState = MeshModifierState()
        var meshModifierStack: [MeshModifierItem] = []
        var cameraRig = CameraRigState()
        var cameraTimelineFrame: Int = 0
        var cameraTimelineFPS: Double = 30
        var cameraKeyframes: [CameraKeyframe] = []
        var cameraExportPreserveAlpha: Bool = false
        var cameraFunctionDriver = CameraFunctionDriverState()
        var cameraExportSizeMode: CameraExportSizeMode = .preview
        var cameraExportCustomWidth: Int = 1920
        var cameraExportCustomHeight: Int = 1080
        var cameraExportFPSMode: CameraExportFPSMode = .source
        var cameraExportCustomFPS: Double = 30
        var cameraExportBackgroundMode: CameraExportBackgroundMode = .white
        var cameraExportBackgroundColor = VolumeBackgroundColor(red: 1, green: 1, blue: 1)
        var sliceMode: SliceMode = .axis
        var playbackAxis: PlaybackAxis = .t
        var currentIndex: Int = 0
        var playbackRate: Double = 1.0
        var showCheckerboard: Bool = true
        var useFastPreviewWhilePlaying: Bool = true
        var reduceResolutionWhilePlaying: Bool = true
        var referencePlane = ReferencePlaneState()
        var showCornerAxesOverlay: Bool = true
        var showOriginAxesOverlay: Bool = true
        var showPlaneOverlay: Bool = true
        var showCameraOverlay: Bool = true

        private enum CodingKeys: String, CodingKey {
            case useAlpha
            case steps
            case density
            case brightness
            case useVoxelBlockRendering
            case smoothVolumeEdges
            case volumeBackgroundMode
            case volumeBackgroundColor
            case volumeTransform
            case meshModifierState
            case meshModifierStack
            case cameraRig
            case cameraTimelineFrame
            case cameraTimelineFPS
            case cameraKeyframes
            case cameraExportPreserveAlpha
            case cameraFunctionDriver
            case cameraExportSizeMode
            case cameraExportCustomWidth
            case cameraExportCustomHeight
            case cameraExportFPSMode
            case cameraExportCustomFPS
            case cameraExportBackgroundMode
            case cameraExportBackgroundColor
            case sliceMode
            case playbackAxis
            case currentIndex
            case playbackRate
            case showCheckerboard
            case useFastPreviewWhilePlaying
            case reduceResolutionWhilePlaying
            case referencePlane
            case showCornerAxesOverlay
            case showOriginAxesOverlay
            case showPlaneOverlay
            case showCameraOverlay
        }

        init(
            useAlpha: Bool = true,
            steps: Int = 192,
            density: Double = 1.1,
            brightness: Double = 1.6,
            useVoxelBlockRendering: Bool = false,
            smoothVolumeEdges: Bool = false,
            volumeBackgroundMode: VolumeBackgroundMode = .color,
            volumeBackgroundColor: VolumeBackgroundColor = VolumeBackgroundColor(),
            volumeTransform: VolumeTransformState = VolumeTransformState(),
            meshModifierState: MeshModifierState = MeshModifierState(),
            meshModifierStack: [MeshModifierItem] = [],
            cameraRig: CameraRigState = CameraRigState(),
            cameraTimelineFrame: Int = 0,
            cameraTimelineFPS: Double = 30,
            cameraKeyframes: [CameraKeyframe] = [],
            cameraExportPreserveAlpha: Bool = false,
            cameraFunctionDriver: CameraFunctionDriverState = CameraFunctionDriverState(),
            cameraExportSizeMode: CameraExportSizeMode = .preview,
            cameraExportCustomWidth: Int = 1920,
            cameraExportCustomHeight: Int = 1080,
            cameraExportFPSMode: CameraExportFPSMode = .source,
            cameraExportCustomFPS: Double = 30,
            cameraExportBackgroundMode: CameraExportBackgroundMode = .white,
            cameraExportBackgroundColor: VolumeBackgroundColor = VolumeBackgroundColor(red: 1, green: 1, blue: 1),
            sliceMode: SliceMode = .axis,
            playbackAxis: PlaybackAxis = .t,
            currentIndex: Int = 0,
            playbackRate: Double = 1.0,
            showCheckerboard: Bool = true,
            useFastPreviewWhilePlaying: Bool = true,
            reduceResolutionWhilePlaying: Bool = true,
            referencePlane: ReferencePlaneState = ReferencePlaneState(),
            showCornerAxesOverlay: Bool = true,
            showOriginAxesOverlay: Bool = true,
            showPlaneOverlay: Bool = true,
            showCameraOverlay: Bool = true
        ) {
            self.useAlpha = useAlpha
            self.steps = steps
            self.density = density
            self.brightness = brightness
            self.useVoxelBlockRendering = useVoxelBlockRendering
            self.smoothVolumeEdges = smoothVolumeEdges
            self.volumeBackgroundMode = volumeBackgroundMode
            self.volumeBackgroundColor = volumeBackgroundColor
            self.volumeTransform = volumeTransform
            self.meshModifierState = meshModifierState
            self.meshModifierStack = meshModifierStack
            self.cameraRig = cameraRig
            self.cameraTimelineFrame = cameraTimelineFrame
            self.cameraTimelineFPS = cameraTimelineFPS
            self.cameraKeyframes = cameraKeyframes
            self.cameraExportPreserveAlpha = cameraExportPreserveAlpha
            self.cameraFunctionDriver = cameraFunctionDriver
            self.cameraExportSizeMode = cameraExportSizeMode
            self.cameraExportCustomWidth = cameraExportCustomWidth
            self.cameraExportCustomHeight = cameraExportCustomHeight
            self.cameraExportFPSMode = cameraExportFPSMode
            self.cameraExportCustomFPS = cameraExportCustomFPS
            self.cameraExportBackgroundMode = cameraExportBackgroundMode
            self.cameraExportBackgroundColor = cameraExportBackgroundColor
            self.sliceMode = sliceMode
            self.playbackAxis = playbackAxis
            self.currentIndex = currentIndex
            self.playbackRate = playbackRate
            self.showCheckerboard = showCheckerboard
            self.useFastPreviewWhilePlaying = useFastPreviewWhilePlaying
            self.reduceResolutionWhilePlaying = reduceResolutionWhilePlaying
            self.referencePlane = referencePlane
            self.showCornerAxesOverlay = showCornerAxesOverlay
            self.showOriginAxesOverlay = showOriginAxesOverlay
            self.showPlaneOverlay = showPlaneOverlay
            self.showCameraOverlay = showCameraOverlay
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            useAlpha = try container.decodeIfPresent(Bool.self, forKey: .useAlpha) ?? true
            steps = try container.decodeIfPresent(Int.self, forKey: .steps) ?? 192
            density = try container.decodeIfPresent(Double.self, forKey: .density) ?? 1.1
            brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 1.6
            useVoxelBlockRendering = try container.decodeIfPresent(Bool.self, forKey: .useVoxelBlockRendering) ?? false
            smoothVolumeEdges = try container.decodeIfPresent(Bool.self, forKey: .smoothVolumeEdges) ?? false
            volumeBackgroundMode = try container.decodeIfPresent(VolumeBackgroundMode.self, forKey: .volumeBackgroundMode) ?? .color
            volumeBackgroundColor = try container.decodeIfPresent(VolumeBackgroundColor.self, forKey: .volumeBackgroundColor) ?? VolumeBackgroundColor()
            volumeTransform = try container.decodeIfPresent(VolumeTransformState.self, forKey: .volumeTransform) ?? VolumeTransformState()
            meshModifierState = try container.decodeIfPresent(MeshModifierState.self, forKey: .meshModifierState) ?? MeshModifierState()
            meshModifierStack = try container.decodeIfPresent([MeshModifierItem].self, forKey: .meshModifierStack) ?? []
            cameraRig = try container.decodeIfPresent(CameraRigState.self, forKey: .cameraRig) ?? CameraRigState()
            cameraTimelineFrame = try container.decodeIfPresent(Int.self, forKey: .cameraTimelineFrame) ?? 0
            cameraTimelineFPS = try container.decodeIfPresent(Double.self, forKey: .cameraTimelineFPS) ?? 30
            cameraKeyframes = try container.decodeIfPresent([CameraKeyframe].self, forKey: .cameraKeyframes) ?? []
            cameraExportPreserveAlpha = try container.decodeIfPresent(Bool.self, forKey: .cameraExportPreserveAlpha) ?? false
            cameraFunctionDriver = try container.decodeIfPresent(CameraFunctionDriverState.self, forKey: .cameraFunctionDriver) ?? CameraFunctionDriverState()
            cameraExportSizeMode = try container.decodeIfPresent(CameraExportSizeMode.self, forKey: .cameraExportSizeMode) ?? .preview
            cameraExportCustomWidth = try container.decodeIfPresent(Int.self, forKey: .cameraExportCustomWidth) ?? 1920
            cameraExportCustomHeight = try container.decodeIfPresent(Int.self, forKey: .cameraExportCustomHeight) ?? 1080
            cameraExportFPSMode = try container.decodeIfPresent(CameraExportFPSMode.self, forKey: .cameraExportFPSMode) ?? .source
            cameraExportCustomFPS = try container.decodeIfPresent(Double.self, forKey: .cameraExportCustomFPS) ?? 30
            cameraExportBackgroundMode = try container.decodeIfPresent(CameraExportBackgroundMode.self, forKey: .cameraExportBackgroundMode) ?? .white
            cameraExportBackgroundColor = try container.decodeIfPresent(VolumeBackgroundColor.self, forKey: .cameraExportBackgroundColor) ?? VolumeBackgroundColor(red: 1, green: 1, blue: 1)
            sliceMode = try container.decodeIfPresent(SliceMode.self, forKey: .sliceMode) ?? .axis
            playbackAxis = try container.decodeIfPresent(PlaybackAxis.self, forKey: .playbackAxis) ?? .t
            currentIndex = try container.decodeIfPresent(Int.self, forKey: .currentIndex) ?? 0
            playbackRate = try container.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1.0
            showCheckerboard = try container.decodeIfPresent(Bool.self, forKey: .showCheckerboard) ?? true
            useFastPreviewWhilePlaying = try container.decodeIfPresent(Bool.self, forKey: .useFastPreviewWhilePlaying) ?? true
            reduceResolutionWhilePlaying = try container.decodeIfPresent(Bool.self, forKey: .reduceResolutionWhilePlaying) ?? true
            referencePlane = try container.decodeIfPresent(ReferencePlaneState.self, forKey: .referencePlane) ?? ReferencePlaneState()
            showCornerAxesOverlay = try container.decodeIfPresent(Bool.self, forKey: .showCornerAxesOverlay) ?? true
            showOriginAxesOverlay = try container.decodeIfPresent(Bool.self, forKey: .showOriginAxesOverlay) ?? true
            showPlaneOverlay = try container.decodeIfPresent(Bool.self, forKey: .showPlaneOverlay) ?? true
            showCameraOverlay = try container.decodeIfPresent(Bool.self, forKey: .showCameraOverlay) ?? true
        }
    }

    struct ExportOptionsProjectState: Codable, Equatable {
        var preserveAlpha: Bool = false
        var highPrecision: Bool = true
        var padToEven: Bool = true
        var qualityScale: Double = 1.0
        var bitDepth: ExportBitDepth = .source
        var colorProfile: ExportColorProfile = .source

        private enum CodingKeys: String, CodingKey {
            case preserveAlpha
            case highPrecision
            case padToEven
            case qualityScale
            case bitDepth
            case colorProfile
        }

        init(
            preserveAlpha: Bool = false,
            highPrecision: Bool = true,
            padToEven: Bool = true,
            qualityScale: Double = 1.0,
            bitDepth: ExportBitDepth = .source,
            colorProfile: ExportColorProfile = .source
        ) {
            self.preserveAlpha = preserveAlpha
            self.highPrecision = highPrecision
            self.padToEven = padToEven
            self.qualityScale = qualityScale
            self.bitDepth = bitDepth
            self.colorProfile = colorProfile
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preserveAlpha = try container.decodeIfPresent(Bool.self, forKey: .preserveAlpha) ?? false
            highPrecision = try container.decodeIfPresent(Bool.self, forKey: .highPrecision) ?? true
            padToEven = try container.decodeIfPresent(Bool.self, forKey: .padToEven) ?? true
            qualityScale = try container.decodeIfPresent(Double.self, forKey: .qualityScale) ?? 1.0
            bitDepth = try container.decodeIfPresent(ExportBitDepth.self, forKey: .bitDepth) ?? .source
            colorProfile = try container.decodeIfPresent(ExportColorProfile.self, forKey: .colorProfile) ?? .source
        }
    }

    struct DistributedWorkerRecord: Identifiable, Codable, Hashable {
        var id: UUID
        var baseURL: String
        var name: String
    }

    struct DistributedExportProjectState: Codable, Equatable {
        var isEnabled: Bool = false
        var splitMode: DistributedSplitMode = .manual
        var localSharePercent: Double = 50.0
        var automaticSuggestedLocalSharePercent: Double = 60.0
        var offerUploadWhenSourceMissing: Bool = true
        var recordExportDiagnostics: Bool = false
        var workers: [DistributedWorkerRecord] = [
            DistributedWorkerRecord(
                id: UUID(),
                baseURL: "http://10.77.77.2:8787",
                name: "-"
            )
        ]
    }

    struct CompositionProjectState: Codable, Equatable {
        var assets: [CompositionAssetRecord] = []
        var composition = CompositionDocumentState()
        var compositionCamera = CameraRigState(positionZ: 3.0)
        var currentFrame: Int = 0
        var activeCompositionAssetID: UUID?
        var selectedLayerID: UUID?
        var selectedLayerIDs: [UUID] = []
        var selectedCameraClipID: UUID?
        var expandedLayerIDs: [UUID] = []
        var isCameraTrackExpanded: Bool = false
        var isTimelineSnappingEnabled: Bool = true
        var exportSettings = CompositionExportSettings()
        var workspaceLayout = CompositionWorkspaceLayoutState()
        var openCompositionTabIDs: [UUID] = []

        private enum CodingKeys: String, CodingKey {
            case assets
            case composition
            case compositionCamera
            case currentFrame
            case activeCompositionAssetID
            case selectedLayerID
            case selectedLayerIDs
            case selectedCameraClipID
            case expandedLayerIDs
            case isCameraTrackExpanded
            case isTimelineSnappingEnabled
            case exportSettings
            case workspaceLayout
            case openCompositionTabIDs
        }

        init() {}

        init(
            assets: [CompositionAssetRecord],
            composition: CompositionDocumentState,
            compositionCamera: CameraRigState,
            currentFrame: Int,
            activeCompositionAssetID: UUID?,
            selectedLayerID: UUID?,
            selectedLayerIDs: [UUID],
            selectedCameraClipID: UUID?,
            expandedLayerIDs: [UUID],
            isCameraTrackExpanded: Bool,
            isTimelineSnappingEnabled: Bool,
            exportSettings: CompositionExportSettings,
            workspaceLayout: CompositionWorkspaceLayoutState,
            openCompositionTabIDs: [UUID]
        ) {
            self.assets = assets
            self.composition = composition
            self.compositionCamera = compositionCamera
            self.currentFrame = currentFrame
            self.activeCompositionAssetID = activeCompositionAssetID
            self.selectedLayerID = selectedLayerID
            self.selectedLayerIDs = selectedLayerIDs
            self.selectedCameraClipID = selectedCameraClipID
            self.expandedLayerIDs = expandedLayerIDs
            self.isCameraTrackExpanded = isCameraTrackExpanded
            self.isTimelineSnappingEnabled = isTimelineSnappingEnabled
            self.exportSettings = exportSettings
            self.workspaceLayout = workspaceLayout
            self.openCompositionTabIDs = openCompositionTabIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            assets = try container.decodeIfPresent([CompositionAssetRecord].self, forKey: .assets) ?? []
            composition = try container.decodeIfPresent(CompositionDocumentState.self, forKey: .composition)
                ?? CompositionDocumentState()
            compositionCamera = try container.decodeIfPresent(CameraRigState.self, forKey: .compositionCamera)
                ?? CameraRigState(positionZ: 3.0)
            currentFrame = try container.decodeIfPresent(Int.self, forKey: .currentFrame) ?? 0
            activeCompositionAssetID = try container.decodeIfPresent(UUID.self, forKey: .activeCompositionAssetID)
            selectedLayerID = try container.decodeIfPresent(UUID.self, forKey: .selectedLayerID)
            selectedLayerIDs = try container.decodeIfPresent([UUID].self, forKey: .selectedLayerIDs) ?? []
            selectedCameraClipID = try container.decodeIfPresent(UUID.self, forKey: .selectedCameraClipID)
            expandedLayerIDs = try container.decodeIfPresent([UUID].self, forKey: .expandedLayerIDs) ?? []
            isCameraTrackExpanded = try container.decodeIfPresent(Bool.self, forKey: .isCameraTrackExpanded) ?? false
            isTimelineSnappingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTimelineSnappingEnabled) ?? true
            exportSettings = try container.decodeIfPresent(CompositionExportSettings.self, forKey: .exportSettings)
                ?? CompositionExportSettings()
            workspaceLayout = try container.decodeIfPresent(CompositionWorkspaceLayoutState.self, forKey: .workspaceLayout)
                ?? CompositionWorkspaceLayoutState()
            openCompositionTabIDs = try container.decodeIfPresent([UUID].self, forKey: .openCompositionTabIDs) ?? []
        }
    }
}

enum ChronoVolumeProjectDocumentError: LocalizedError {
    case unsupportedFormatVersion(found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let found, let supported):
            return "项目格式版本 \(found) 高于当前程序支持的版本 \(supported)，请使用更新版本的 ChronoVolume 打开。"
        }
    }
}

extension ChronoVolumeProjectDocument {
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> ChronoVolumeProjectDocument {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChronoVolumeProjectDocument.self, from: data)
    }
}
