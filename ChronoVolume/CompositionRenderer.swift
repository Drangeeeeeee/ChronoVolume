import AppKit
import AVFoundation
import CoreVideo
import MetalKit
import simd

enum CompositionRendererInteractionMode {
    case orbit
    case freeCamera
}

struct CompositionRendererDiagnostics: Equatable {
    var previewFPS: Double
    var renderPathText: String
    var drawableWidth: Int
    var drawableHeight: Int
    var drawnLayerCount: Int
    var textureHitCount: Int
    var textureMissCount: Int
    var estimatedTextureMemoryBytes: Int64
    var updatedAt: Date

    var textureHitRate: Double {
        let total = textureHitCount + textureMissCount
        guard total > 0 else { return 1 }
        return Double(textureHitCount) / Double(total)
    }
}

struct CompositionModifiedTextureRefreshStatus: Equatable {
    var pendingCount: Int

    var isPending: Bool {
        pendingCount > 0
    }
}

private struct ModifiedTextureBuildRequest: Sendable {
    let textureID: UUID
    let modifiers: [MeshModifierItem]
    let baseVolume: LoadedVolume
    let baseScale: SIMD3<Float>
    let signature: String
}

private struct ModifiedTextureBuildResult {
    let textureID: UUID
    let texture: MTLTexture
    let baseScale: SIMD3<Float>
    let usesAlpha: Bool
    let signature: String
}

private struct ModifiedTextureRefreshPlan: Sendable {
    let requestedIDs: Set<UUID>
    let requests: [ModifiedTextureBuildRequest]
}

enum VolumeTextureUploadGuard {
    static let max3DTextureDimension = 2048
    static let max2DArrayTextureDimension = 16384
    static let max2DArrayTextureSlices = 2048
    private static let fallbackSingleTextureBudgetBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let minimumSingleTextureBudgetBytes: Int64 = 256 * 1024 * 1024
    private static let maximumSingleTextureBudgetBytes: Int64 = 8 * 1024 * 1024 * 1024
    private static let fallbackArrayTextureBudgetBytes: Int64 = 6 * 1024 * 1024 * 1024
    private static let minimumArrayTextureBudgetBytes: Int64 = 1024 * 1024 * 1024
    private static let maximumArrayTextureBudgetBytes: Int64 = 12 * 1024 * 1024 * 1024

    static func makeRGBA8Texture(
        device: MTLDevice,
        volume: LoadedVolume,
        context: String
    ) throws -> MTLTexture {
        if let cachedTexture = VolumeModifierRasterizer.cachedModifiedTexture(
            for: volume.textureCacheID,
            device: device
        ) {
            return cachedTexture
        }

        let byteCount = try validatedByteCount(device: device, volume: volume, context: context)
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba8Unorm
        desc.width = volume.width
        desc.height = volume.height
        desc.depth = volume.depth
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw VideoExportError.textureBottleneck(
                "\(context) 创建失败（\(volume.width) × \(volume.height) × \(volume.depth)，\(formattedBytes(byteCount))）。请改用代理预览，或降低素材分辨率/帧数/体素修改器复杂度。"
            )
        }
        texture.replace(
            region: MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth),
            mipmapLevel: 0,
            slice: 0,
            withBytes: volume.rgba,
            bytesPerRow: volume.width * 4,
            bytesPerImage: volume.width * volume.height * 4
        )
        return texture
    }

    static func makeRGBA8ArrayTexture(
        device: MTLDevice,
        volume: LoadedVolume,
        context: String
    ) throws -> MTLTexture {
        let byteCount = try validatedArrayByteCount(device: device, volume: volume, context: context)
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba8Unorm
        desc.width = volume.width
        desc.height = volume.height
        desc.arrayLength = volume.depth
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw VideoExportError.textureBottleneck(
                "\(context) 创建 2D 阵列纹理失败（\(volume.width) × \(volume.height) × \(volume.depth)，\(formattedBytes(byteCount))）。请改用代理预览，或降低素材分辨率/帧数。"
            )
        }

        let rowBytes = volume.width * 4
        let frameBytes = rowBytes * volume.height
        let region = MTLRegionMake2D(0, 0, volume.width, volume.height)
        try volume.rgba.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw VideoExportError.textureBottleneck("\(context) 数据为空，无法上传 2D 阵列纹理。")
            }
            for slice in 0..<volume.depth {
                texture.replace(
                    region: region,
                    mipmapLevel: 0,
                    slice: slice,
                    withBytes: baseAddress.advanced(by: slice * frameBytes),
                    bytesPerRow: rowBytes,
                    bytesPerImage: frameBytes
                )
            }
        }
        return texture
    }

    private static func validatedByteCount(
        device: MTLDevice,
        volume: LoadedVolume,
        context: String
    ) throws -> Int64 {
        guard volume.width > 0, volume.height > 0, volume.depth > 0 else {
            throw VideoExportError.textureBottleneck("\(context) 尺寸无效：\(volume.width) × \(volume.height) × \(volume.depth)")
        }
        guard volume.width <= max3DTextureDimension,
              volume.height <= max3DTextureDimension,
              volume.depth <= max3DTextureDimension else {
            throw VideoExportError.textureBottleneck(
                "\(context) 超过 Metal 3D 纹理尺寸上限：\(volume.width) × \(volume.height) × \(volume.depth)，单轴建议不超过 \(max3DTextureDimension)。"
            )
        }

        let byteCount = Int64(volume.width) * Int64(volume.height) * Int64(volume.depth) * 4
        guard Int64(volume.rgba.count) >= byteCount else {
            throw VideoExportError.textureBottleneck(
                "\(context) 数据不完整：需要 \(formattedBytes(byteCount))，实际 \(formattedBytes(Int64(volume.rgba.count)))。"
            )
        }

        let budget = singleTextureBudgetBytes(device: device)
        guard byteCount <= budget else {
            throw VideoExportError.textureBottleneck(
                "\(context) 单个 3D 体纹理过大：\(volume.width) × \(volume.height) × \(volume.depth)，约 \(formattedBytes(byteCount))，当前单纹理安全预算 \(formattedBytes(budget))。这个预算由 Metal 推荐工作集和统一内存估算，不等同于系统剩余内存。请尝试“高精度分段式导出”，或改用“代理预览”。"
            )
        }
        return byteCount
    }

    static func singleTextureBudgetBytes(device: MTLDevice) -> Int64 {
        let recommendedShare = recommendedWorkingSetShare(device: device, divisor: 3)
        let unifiedMemoryShare = unifiedSystemMemoryShare(device: device, divisor: 8)
        let candidate = max(fallbackSingleTextureBudgetBytes, recommendedShare, unifiedMemoryShare)
        return min(
            maximumSingleTextureBudgetBytes,
            max(minimumSingleTextureBudgetBytes, candidate)
        )
    }

    static func arrayTextureBudgetBytes(device: MTLDevice) -> Int64 {
        let recommendedShare = recommendedWorkingSetShare(device: device, divisor: 2)
        let unifiedMemoryShare = unifiedSystemMemoryShare(device: device, divisor: 5)
        let candidate = max(fallbackArrayTextureBudgetBytes, recommendedShare, unifiedMemoryShare)
        return min(
            maximumArrayTextureBudgetBytes,
            max(minimumArrayTextureBudgetBytes, candidate)
        )
    }

    private static func recommendedWorkingSetShare(device: MTLDevice, divisor: UInt64) -> Int64 {
        let recommended = device.recommendedMaxWorkingSetSize
        guard recommended > 0, divisor > 0 else { return 0 }
        return Int64(min(recommended / divisor, UInt64(Int64.max)))
    }

    private static func unifiedSystemMemoryShare(device: MTLDevice, divisor: UInt64) -> Int64 {
        guard device.hasUnifiedMemory, divisor > 0 else { return 0 }
        return Int64(min(ProcessInfo.processInfo.physicalMemory / divisor, UInt64(Int64.max)))
    }

    static func budgetDetailText(device: MTLDevice, budget: Int64) -> String {
        let recommended = device.recommendedMaxWorkingSetSize
        let recommendedText = recommended > 0
            ? formattedBytes(Int64(min(recommended, UInt64(Int64.max))))
            : "未知"
        let physicalText = formattedBytes(Int64(min(ProcessInfo.processInfo.physicalMemory, UInt64(Int64.max))))
        let memoryKind = device.hasUnifiedMemory ? "统一内存" : "独立显存/非统一内存"
        return "预算 \(formattedBytes(budget))；Metal 推荐工作集 \(recommendedText)；系统物理内存 \(physicalText)；\(memoryKind)"
    }

    static func formattedBytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        let gib = value / 1024 / 1024 / 1024
        if gib >= 1 {
            return String(format: "%.2f GB", gib)
        }
        let mib = value / 1024 / 1024
        return String(format: "%.0f MB", mib)
    }

    private static func validatedArrayByteCount(
        device: MTLDevice,
        volume: LoadedVolume,
        context: String
    ) throws -> Int64 {
        guard volume.width > 0, volume.height > 0, volume.depth > 0 else {
            throw VideoExportError.textureBottleneck("\(context) 尺寸无效：\(volume.width) × \(volume.height) × \(volume.depth)")
        }
        guard volume.width <= max2DArrayTextureDimension,
              volume.height <= max2DArrayTextureDimension,
              volume.depth <= max2DArrayTextureSlices else {
            throw VideoExportError.textureBottleneck(
                "\(context) 超过 Metal 2D 阵列纹理上限：\(volume.width) × \(volume.height) × \(volume.depth)，单帧建议不超过 \(max2DArrayTextureDimension)，帧数建议不超过 \(max2DArrayTextureSlices)。"
            )
        }

        let byteCount = Int64(volume.width) * Int64(volume.height) * Int64(volume.depth) * 4
        guard Int64(volume.rgba.count) >= byteCount else {
            throw VideoExportError.textureBottleneck(
                "\(context) 数据不完整：需要 \(formattedBytes(byteCount))，实际 \(formattedBytes(Int64(volume.rgba.count)))。"
            )
        }

        let budget = arrayTextureBudgetBytes(device: device)
        guard byteCount <= budget else {
            throw VideoExportError.textureBottleneck(
                "\(context) 2D 阵列纹理仍然过大：\(volume.width) × \(volume.height) × \(volume.depth)，约 \(formattedBytes(byteCount))，当前阵列纹理安全预算 \(formattedBytes(budget))。这个预算由 Metal 推荐工作集和统一内存估算，不等同于系统剩余内存。"
            )
        }
        return byteCount
    }

}

private func makeCompositionVolumePipeline(
    device: MTLDevice,
    library: MTLLibrary,
    colorPixelFormat: MTLPixelFormat,
    depthPixelFormat: MTLPixelFormat,
    blendMode: CompositionLayerBlendMode,
    fragmentFunctionName: String = "volumeFragment"
) throws -> MTLRenderPipelineState {
    guard let vertexFunc = library.makeFunction(name: "volumeVertex"),
          let fragmentFunc = library.makeFunction(name: fragmentFunctionName) else {
        throw VideoExportError.metalUnavailable("找不到合成 volume shader")
    }

    let pipelineDesc = MTLRenderPipelineDescriptor()
    pipelineDesc.vertexFunction = vertexFunc
    pipelineDesc.fragmentFunction = fragmentFunc
    pipelineDesc.colorAttachments[0].pixelFormat = colorPixelFormat
    pipelineDesc.depthAttachmentPixelFormat = depthPixelFormat
    pipelineDesc.inputPrimitiveTopology = .triangle
    configureCompositionBlend(pipelineDesc.colorAttachments[0], blendMode: blendMode)
    return try device.makeRenderPipelineState(descriptor: pipelineDesc)
}

private func configureCompositionBlend(
    _ attachment: MTLRenderPipelineColorAttachmentDescriptor,
    blendMode: CompositionLayerBlendMode
) {
    attachment.isBlendingEnabled = true
    attachment.rgbBlendOperation = .add
    attachment.alphaBlendOperation = .add

    switch blendMode {
    case .normal:
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    case .add:
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    case .screen:
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceColor
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    case .multiply:
        attachment.sourceRGBBlendFactor = .destinationColor
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    case .alphaTrackMatte:
        attachment.sourceRGBBlendFactor = .zero
        attachment.sourceAlphaBlendFactor = .zero
        attachment.destinationRGBBlendFactor = .sourceAlpha
        attachment.destinationAlphaBlendFactor = .sourceAlpha
    }
}

final class CompositionRenderer: NSObject, MTKViewDelegate, InteractiveMTKViewDelegate {
    private static let surfaceSDFPreviewMaxBytes = 8 * 1024 * 1024
    private static let fracturedSurfacePreviewMaxBytes = 4 * 1024 * 1024

    private weak var view: MTKView?
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [CompositionLayerBlendMode: MTLRenderPipelineState]
    private let depthState: MTLDepthStencilState
    private var uniformBuffer: MTLBuffer
    private var vertexBuffer: MTLBuffer
    private var samplerState: MTLSamplerState

    private var textures: [UUID: MTLTexture] = [:]
    private var assetVolumes: [UUID: LoadedVolume] = [:]
    private var assetTextureSourceIDs: [UUID: UUID] = [:]
    private var modifiedTextures: [UUID: MTLTexture] = [:]
    private var modifiedVolumeScales: [UUID: SIMD3<Float>] = [:]
    private var modifiedVolumeUsesAlpha: [UUID: Bool] = [:]
    private var modifiedTextureSignatures: [UUID: String] = [:]
    private var pendingModifiedTextureRefreshLayers: [CompositionRenderLayer]?
    private var modifiedTextureRefreshWorkItem: DispatchWorkItem?
    private var activeModifiedTextureRefreshSignature: String?
    private let modifiedTextureRefreshQueue = DispatchQueue(
        label: "ChronoVolume.CompositionRenderer.modifiedTextureRefresh",
        qos: .userInitiated
    )
    private var modifiedTextureRefreshGeneration = 0
    private var volumeScales: [UUID: SIMD3<Float>] = [:]
    private var volumeUsesAlpha: [UUID: Bool] = [:]
    private var estimatedTextureMemoryBytes: Int64 = 0
    private var renderLayers: [CompositionRenderLayer] = []
    private var backgroundColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    private var interactionMode: CompositionRendererInteractionMode = .freeCamera
    private var previewQuality: CompositionPreviewQuality = .automatic
    private var isPreviewPlaying = false
    private var frameTimestamps: [CFTimeInterval] = []
    private var lastDiagnosticsEmitTime: CFTimeInterval = 0

    private var yaw: Float = 0
    private var pitch: Float = 0
    private var roll: Float = 0
    private var distance: Float = 2.2
    private var cameraPosition = SIMD3<Float>(0, 0, 3)
    private var focusLockEnabled = false
    private var focusTarget = SIMD3<Float>(0, 0, 0)
    private var focalLength: Float = 50
    private var aperture: Float = 5.6
    private var lastPoint: CGPoint?
    var onCameraChanged: ((CameraRigState) -> Void)?
    var onCameraInteractionBegan: (() -> Void)?
    var onCameraInteractionEnded: (() -> Void)?
    var onPreviewDiagnosticsChanged: ((CompositionRendererDiagnostics) -> Void)?
    var onModifiedTextureRefreshStatusChanged: ((CompositionModifiedTextureRefreshStatus) -> Void)?

    init(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal 初始化失败")
        }

        self.view = view
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            fatalError("加载默认 Metal Library 失败：\(error)")
        }

        var builtPipelines: [CompositionLayerBlendMode: MTLRenderPipelineState] = [:]
        do {
            for blendMode in CompositionLayerBlendMode.allCases {
                builtPipelines[blendMode] = try makeCompositionVolumePipeline(
                    device: device,
                    library: library,
                    colorPixelFormat: view.colorPixelFormat,
                    depthPixelFormat: view.depthStencilPixelFormat,
                    blendMode: blendMode
                )
            }
        } catch {
            fatalError("创建合成 RenderPipelineState 失败：\(error)")
        }
        pipelines = builtPipelines

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.isDepthWriteEnabled = false
        depthDesc.depthCompareFunction = .always
        guard let depthState = device.makeDepthStencilState(descriptor: depthDesc) else {
            fatalError("创建合成 DepthStencilState 失败")
        }
        self.depthState = depthState

        guard let uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared) else {
            fatalError("创建合成 uniformBuffer 失败")
        }
        self.uniformBuffer = uniformBuffer

        let cubeVertices: [SIMD3<Float>] = [
            SIMD3(-0.5,-0.5,-0.5), SIMD3( 0.5,-0.5,-0.5), SIMD3( 0.5, 0.5,-0.5),
            SIMD3(-0.5,-0.5,-0.5), SIMD3( 0.5, 0.5,-0.5), SIMD3(-0.5, 0.5,-0.5),
            SIMD3(-0.5,-0.5, 0.5), SIMD3( 0.5, 0.5, 0.5), SIMD3( 0.5,-0.5, 0.5),
            SIMD3(-0.5,-0.5, 0.5), SIMD3(-0.5, 0.5, 0.5), SIMD3( 0.5, 0.5, 0.5),
            SIMD3(-0.5,-0.5,-0.5), SIMD3(-0.5, 0.5,-0.5), SIMD3(-0.5, 0.5, 0.5),
            SIMD3(-0.5,-0.5,-0.5), SIMD3(-0.5, 0.5, 0.5), SIMD3(-0.5,-0.5, 0.5),
            SIMD3( 0.5,-0.5,-0.5), SIMD3( 0.5,-0.5, 0.5), SIMD3( 0.5, 0.5, 0.5),
            SIMD3( 0.5,-0.5,-0.5), SIMD3( 0.5, 0.5, 0.5), SIMD3( 0.5, 0.5,-0.5),
            SIMD3(-0.5,-0.5,-0.5), SIMD3(-0.5,-0.5, 0.5), SIMD3( 0.5,-0.5, 0.5),
            SIMD3(-0.5,-0.5,-0.5), SIMD3( 0.5,-0.5, 0.5), SIMD3( 0.5,-0.5,-0.5),
            SIMD3(-0.5, 0.5,-0.5), SIMD3( 0.5, 0.5,-0.5), SIMD3( 0.5, 0.5, 0.5),
            SIMD3(-0.5, 0.5,-0.5), SIMD3( 0.5, 0.5, 0.5), SIMD3(-0.5, 0.5, 0.5)
        ]

        guard let vertexBuffer = device.makeBuffer(
            bytes: cubeVertices,
            length: cubeVertices.count * MemoryLayout<SIMD3<Float>>.stride,
            options: .storageModeShared
        ) else {
            fatalError("创建合成 vertexBuffer 失败")
        }
        self.vertexBuffer = vertexBuffer

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        samplerDesc.rAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDesc) else {
            fatalError("创建合成 samplerState 失败")
        }
        self.samplerState = samplerState

        super.init()
    }

    func setAssets(_ assets: [CompositionAsset]) {
        let validIDs = Set(assets.map(\.id))
        textures = textures.filter { validIDs.contains($0.key) }
        assetVolumes = assetVolumes.filter { validIDs.contains($0.key) }
        assetTextureSourceIDs = assetTextureSourceIDs.filter { validIDs.contains($0.key) }
        volumeScales = volumeScales.filter { validIDs.contains($0.key) }
        volumeUsesAlpha = volumeUsesAlpha.filter { validIDs.contains($0.key) }

        for asset in assets {
            guard let volume = asset.previewVolume else { continue }
            assetVolumes[asset.id] = volume
            if textures[asset.id] == nil || assetTextureSourceIDs[asset.id] != volume.textureCacheID {
                textures[asset.id] = makeTexture(from: volume)
                assetTextureSourceIDs[asset.id] = volume.textureCacheID
            }
            volumeScales[asset.id] = Self.normalizedVolumeScale(
                width: asset.sourceWidth,
                height: asset.sourceHeight,
                depth: asset.sourceFrameCount
            )
            volumeUsesAlpha[asset.id] = volume.hasMeaningfulAlpha
        }
        updateEstimatedTextureMemory()
        requestRedraw()
    }

    func setRenderLayers(
        _ layers: [CompositionRenderLayer],
        allowModifiedTextureRefresh: Bool = true
    ) {
        renderLayers = layers
        if allowModifiedTextureRefresh {
            scheduleModifiedLayerTextureRefresh(for: layers)
        } else {
            cancelPendingModifiedTextureRefresh()
        }
        updateEstimatedTextureMemory()
        requestRedraw()
    }

    func setInteractionMode(_ mode: CompositionRendererInteractionMode) {
        interactionMode = mode
        requestRedraw()
    }

    func setPreviewQuality(_ quality: CompositionPreviewQuality, isPlaying: Bool) {
        guard previewQuality != quality || isPreviewPlaying != isPlaying else { return }
        previewQuality = quality
        isPreviewPlaying = isPlaying
        requestRedraw()
    }

    func setBackgroundColor(_ color: VolumeBackgroundColor, transparent: Bool = false) {
        backgroundColor = MTLClearColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: transparent ? 0 : 1
        )
        view?.clearColor = backgroundColor
        requestRedraw()
    }

    func setCamera(_ camera: CameraRigState) {
        yaw = camera.yaw
        pitch = camera.pitch
        roll = camera.roll
        distance = max(0.8, camera.distance)
        cameraPosition = SIMD3<Float>(camera.positionX, camera.positionY, camera.positionZ)
        focusLockEnabled = camera.focusLockEnabled
        focusTarget = SIMD3<Float>(camera.focusTargetX, camera.focusTargetY, camera.focusTargetZ)
        focalLength = max(1, camera.focalLength)
        aperture = max(0.1, camera.aperture)
        requestRedraw()
    }

    func requestRedraw() {
        guard let view else { return }
        view.needsDisplay = true
        view.setNeedsDisplay(view.bounds)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            return
        }

        view.clearColor = backgroundColor

        let aspect = max(0.1, Float(view.drawableSize.width / max(1.0, view.drawableSize.height)))
        let proj = compositionPerspectiveFovRH(
            fovyRadians: compositionRadians(compositionFocalLengthToFOV(focalLength)),
            aspect: aspect,
            nearZ: 0.1,
            farZ: 100
        )
        let rotY = compositionRotationMatrix(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let rotX = compositionRotationMatrix(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        let rotZ = compositionRotationMatrix(angle: roll, axis: SIMD3<Float>(0, 0, 1))
        let viewMat: simd_float4x4
        let sceneRotation: simd_float4x4
        let cameraPositionWorld: SIMD3<Float>

        switch interactionMode {
        case .orbit:
            viewMat = compositionTranslationMatrix(SIMD3<Float>(0, 0, -distance))
            sceneRotation = rotY * rotX
            cameraPositionWorld = SIMD3<Float>(0, 0, distance)
        case .freeCamera:
            let cameraWorld = focusLockEnabled
                ? compositionLookAtCameraWorldMatrix(position: cameraPosition, target: focusTarget, roll: roll)
                : compositionTranslationMatrix(cameraPosition) * rotY * rotX * rotZ
            let cameraPosition4 = cameraWorld * SIMD4<Float>(0, 0, 0, 1)
            cameraPositionWorld = SIMD3<Float>(cameraPosition4.x, cameraPosition4.y, cameraPosition4.z)
            viewMat = cameraWorld.inverse
            sceneRotation = matrix_identity_float4x4
        }

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        var textureHitCount = 0
        var textureMissCount = 0
        var drawnLayerCount = 0

        for layer in renderLayers {
            guard let texture = texture(for: layer.textureID, fallbackAssetID: layer.assetID),
                  let volumeScale = scale(for: layer.textureID, fallbackAssetID: layer.assetID) else {
                textureMissCount += 1
                continue
            }
            textureHitCount += 1
            let useAlpha = usesAlpha(for: layer.textureID, fallbackAssetID: layer.assetID)
            let blendMode = layer.blendMode == .alphaTrackMatte ? .normal : layer.blendMode
            guard let pipeline = pipelines[blendMode] ?? pipelines[.normal] else { continue }

            let layerModel = sceneRotation * layer.transformMatrix * compositionScaleMatrix(volumeScale)
            let model = layerModel
            let mvp = proj * viewMat * model
            var uniforms = Uniforms(
                modelViewProjectionMatrix: mvp,
                modelMatrix: model,
                invModelMatrix: model.inverse,
                cameraPositionWorld: cameraPositionWorld,
                steps: UInt32(previewQuality.rayStepCount(isPlaying: isPreviewPlaying)),
                density: 1.1,
                brightness: 1.6,
                useAlpha: useAlpha ? 1 : 0,
                useVoxelBlockRendering: layer.volumeRenderMode == .pixelVolume ? 1 : 0,
                outputStraightAlpha: 0,
                smoothEdges: 1,
                layerOpacity: max(0, min(1, layer.opacity)),
                matteDiscardTransparent: 0
            )
            var matteTexture = texture
            if let matteTextureID = layer.trackMatteTextureID,
               let matteTransformMatrix = layer.trackMatteTransformMatrix,
               let candidateTexture = self.texture(for: matteTextureID, fallbackAssetID: layer.trackMatteAssetID),
               let matteScale = scale(for: matteTextureID, fallbackAssetID: layer.trackMatteAssetID) {
                textureHitCount += 1
                let matteModel = sceneRotation
                    * matteTransformMatrix
                    * compositionScaleMatrix(matteScale)
                uniforms.trackMatteEnabled = 1
                uniforms.trackMatteUseAlpha = usesAlpha(for: matteTextureID, fallbackAssetID: layer.trackMatteAssetID) ? 1 : 0
                uniforms.trackMatteOpacity = max(0, min(1, layer.trackMatteOpacity))
                uniforms.trackMatteInvModelMatrix = matteModel.inverse
                matteTexture = candidateTexture
            } else if layer.trackMatteAssetID != nil {
                textureMissCount += 1
            }

            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(matteTexture, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
            drawnLayerCount += 1
        }

        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        emitDiagnostics(
            view: view,
            drawnLayerCount: drawnLayerCount,
            textureHitCount: textureHitCount,
            textureMissCount: textureMissCount
        )
    }

    func mouseDown(with event: NSEvent) {
        lastPoint = event.locationInWindow
        beginCameraInteractionIfNeeded()
    }

    func mouseDragged(with event: NSEvent) {
        guard let lastPoint else { return }
        let point = event.locationInWindow
        yaw += Float(point.x - lastPoint.x) * 0.01
        pitch += Float(point.y - lastPoint.y) * 0.01
        self.lastPoint = point
        notifyCameraChanged()
        requestRedraw()
    }

    func mouseUp(with event: NSEvent) {
        lastPoint = nil
        endCameraInteractionIfNeeded()
    }

    func rightMouseDown(with event: NSEvent) {}
    func rightMouseDragged(with event: NSEvent) {}
    func rightMouseUp(with event: NSEvent) {}

    func scrollWheel(with event: NSEvent) {
        let factor = max(0.2, 1.0 + Float(event.deltaY) * 0.01)
        switch interactionMode {
        case .orbit:
            distance = max(0.8, distance * factor)
        case .freeCamera:
            beginCameraInteractionIfNeeded()
            cameraPosition.z = max(0.2, cameraPosition.z * factor)
        }
        notifyCameraChanged()
        if interactionMode == .freeCamera {
            endCameraInteractionIfNeeded()
        }
        requestRedraw()
    }

    func keyDown(with event: NSEvent) {}
    func keyUp(with event: NSEvent) {}

    private func makeTexture(from volume: LoadedVolume) -> MTLTexture? {
        Self.makeTexture(device: device, volume: volume)
    }

    private static func makeTexture(device: MTLDevice, volume: LoadedVolume) -> MTLTexture? {
        try? VolumeTextureUploadGuard.makeRGBA8Texture(
            device: device,
            volume: volume,
            context: "合成预览体纹理"
        )
    }

    private func refreshModifiedLayerTextures(for layers: [CompositionRenderLayer]) {
        cancelPendingModifiedTextureRefresh()

        var requestedIDs = Set<UUID>()

        func refresh(
            textureID: UUID,
            assetID: UUID,
            modifiers: [MeshModifierItem]
        ) {
            guard textureID != assetID,
                  VolumeModifierRasterizer.hasActiveModifiers(modifiers),
                  let baseVolume = assetVolumes[assetID],
                  let baseScale = volumeScales[assetID] else {
                return
            }
            requestedIDs.insert(textureID)
            let signature = modifiedTextureSignature(base: baseVolume, modifiers: modifiers)
            if modifiedTextureSignatures[textureID] == signature,
               modifiedTextures[textureID] != nil {
                return
            }

            let previewVolume = Self.previewVolumeForModifierRefresh(
                baseVolume: baseVolume,
                modifiers: modifiers
            )
            let modifiedVolume = VolumeModifierRasterizer.applyingForInteractivePreview(
                modifiers,
                to: previewVolume
            )
            guard let texture = makeTexture(from: modifiedVolume) else { return }
            modifiedTextures[textureID] = texture
            modifiedVolumeScales[textureID] = baseScale
            modifiedVolumeUsesAlpha[textureID] = modifiedVolume.hasMeaningfulAlpha
            modifiedTextureSignatures[textureID] = signature
        }

        for layer in layers {
            refresh(
                textureID: layer.textureID,
                assetID: layer.assetID,
                modifiers: layer.modifiers
            )
            if let matteAssetID = layer.trackMatteAssetID,
               let matteTextureID = layer.trackMatteTextureID {
                refresh(
                    textureID: matteTextureID,
                    assetID: matteAssetID,
                    modifiers: layer.trackMatteModifiers
                )
            }
        }

        modifiedTextures = modifiedTextures.filter { requestedIDs.contains($0.key) }
        modifiedVolumeScales = modifiedVolumeScales.filter { requestedIDs.contains($0.key) }
        modifiedVolumeUsesAlpha = modifiedVolumeUsesAlpha.filter { requestedIDs.contains($0.key) }
        modifiedTextureSignatures = modifiedTextureSignatures.filter { requestedIDs.contains($0.key) }
    }

    private func scheduleModifiedLayerTextureRefresh(for layers: [CompositionRenderLayer]) {
        pendingModifiedTextureRefreshLayers = layers
        let plan = modifiedTextureRefreshPlan(for: layers)
        guard !plan.requests.isEmpty else {
            modifiedTextureRefreshWorkItem?.cancel()
            modifiedTextureRefreshWorkItem = nil
            activeModifiedTextureRefreshSignature = nil
            pruneModifiedTextures(requestedIDs: plan.requestedIDs)
            onModifiedTextureRefreshStatusChanged?(
                CompositionModifiedTextureRefreshStatus(pendingCount: 0)
            )
            updateEstimatedTextureMemory()
            requestRedraw()
            return
        }

        let refreshSignature = modifiedTextureRefreshPlanSignature(plan)
        if refreshSignature == activeModifiedTextureRefreshSignature {
            return
        }

        modifiedTextureRefreshWorkItem?.cancel()
        modifiedTextureRefreshGeneration &+= 1
        activeModifiedTextureRefreshSignature = refreshSignature
        let generation = modifiedTextureRefreshGeneration

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.modifiedTextureRefreshGeneration else { return }
            guard refreshSignature == self.activeModifiedTextureRefreshSignature else { return }

            let device = self.device
            self.onModifiedTextureRefreshStatusChanged?(
                CompositionModifiedTextureRefreshStatus(pendingCount: plan.requests.count)
            )
            self.modifiedTextureRefreshQueue.async { [weak self] in
                let results = plan.requests.compactMap { request -> ModifiedTextureBuildResult? in
                    let previewVolume = Self.previewVolumeForModifierRefresh(
                        baseVolume: request.baseVolume,
                        modifiers: request.modifiers
                    )
                    let modifiedVolume = VolumeModifierRasterizer.applyingForInteractivePreview(
                        request.modifiers,
                        to: previewVolume
                    )
                    guard let texture = Self.makeTexture(device: device, volume: modifiedVolume) else {
                        return nil
                    }
                    return ModifiedTextureBuildResult(
                        textureID: request.textureID,
                        texture: texture,
                        baseScale: request.baseScale,
                        usesAlpha: modifiedVolume.hasMeaningfulAlpha,
                        signature: request.signature
                    )
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard generation == self.modifiedTextureRefreshGeneration else { return }
                    guard refreshSignature == self.activeModifiedTextureRefreshSignature else { return }
                    self.applyModifiedTextureRefreshResults(
                        results,
                        requestedIDs: plan.requestedIDs
                    )
                    self.activeModifiedTextureRefreshSignature = nil
                    self.onModifiedTextureRefreshStatusChanged?(
                        CompositionModifiedTextureRefreshStatus(pendingCount: 0)
                    )
                    self.updateEstimatedTextureMemory()
                    self.requestRedraw()
                }
            }
        }
        modifiedTextureRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func cancelPendingModifiedTextureRefresh() {
        modifiedTextureRefreshGeneration &+= 1
        modifiedTextureRefreshWorkItem?.cancel()
        modifiedTextureRefreshWorkItem = nil
        activeModifiedTextureRefreshSignature = nil
        pendingModifiedTextureRefreshLayers = nil
        onModifiedTextureRefreshStatusChanged?(
            CompositionModifiedTextureRefreshStatus(pendingCount: 0)
        )
    }

    private func modifiedTextureRefreshPlan(for layers: [CompositionRenderLayer]) -> ModifiedTextureRefreshPlan {
        var requestedIDs = Set<UUID>()
        var requests: [ModifiedTextureBuildRequest] = []

        func check(
            textureID: UUID,
            assetID: UUID,
            modifiers: [MeshModifierItem]
        ) {
            guard textureID != assetID,
                  VolumeModifierRasterizer.hasActiveModifiers(modifiers),
                  let baseVolume = assetVolumes[assetID],
                  let baseScale = volumeScales[assetID] else {
                return
            }
            requestedIDs.insert(textureID)
            let signature = modifiedTextureSignature(base: baseVolume, modifiers: modifiers)
            if modifiedTextureSignatures[textureID] != signature ||
                modifiedTextures[textureID] == nil {
                requests.append(
                    ModifiedTextureBuildRequest(
                        textureID: textureID,
                        modifiers: modifiers,
                        baseVolume: baseVolume,
                        baseScale: baseScale,
                        signature: signature
                    )
                )
            }
        }

        for layer in layers {
            check(
                textureID: layer.textureID,
                assetID: layer.assetID,
                modifiers: layer.modifiers
            )
            if let matteAssetID = layer.trackMatteAssetID,
               let matteTextureID = layer.trackMatteTextureID {
                check(
                    textureID: matteTextureID,
                    assetID: matteAssetID,
                    modifiers: layer.trackMatteModifiers
                )
            }
        }

        return ModifiedTextureRefreshPlan(requestedIDs: requestedIDs, requests: requests)
    }

    private func modifiedTextureRefreshPlanSignature(_ plan: ModifiedTextureRefreshPlan) -> String {
        let requested = plan.requestedIDs
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
        let requests = plan.requests
            .map { "\($0.textureID.uuidString)|\($0.signature)" }
            .sorted()
            .joined(separator: ",")
        return "requested=\(requested)#requests=\(requests)"
    }

    private func applyModifiedTextureRefreshResults(
        _ results: [ModifiedTextureBuildResult],
        requestedIDs: Set<UUID>
    ) {
        for result in results {
            guard requestedIDs.contains(result.textureID) else {
                continue
            }
            modifiedTextures[result.textureID] = result.texture
            modifiedVolumeScales[result.textureID] = result.baseScale
            modifiedVolumeUsesAlpha[result.textureID] = result.usesAlpha
            modifiedTextureSignatures[result.textureID] = result.signature
        }
        pruneModifiedTextures(requestedIDs: requestedIDs)
    }

    private func pruneModifiedTextures(requestedIDs: Set<UUID>) {
        modifiedTextures = modifiedTextures.filter { requestedIDs.contains($0.key) }
        modifiedVolumeScales = modifiedVolumeScales.filter { requestedIDs.contains($0.key) }
        modifiedVolumeUsesAlpha = modifiedVolumeUsesAlpha.filter { requestedIDs.contains($0.key) }
        modifiedTextureSignatures = modifiedTextureSignatures.filter { requestedIDs.contains($0.key) }
    }

    private static func previewVolumeForModifierRefresh(
        baseVolume: LoadedVolume,
        modifiers: [MeshModifierItem]
    ) -> LoadedVolume {
        guard VolumeModifierRasterizer.usesSurfaceSDFMode(modifiers) else {
            return baseVolume
        }
        let maxBytes = modifiers.contains { modifier in
            modifier.isEnabled && modifier.state.inflateMode == .fracturedSurface
        }
            ? fracturedSurfacePreviewMaxBytes
            : surfaceSDFPreviewMaxBytes
        return VolumeModifierRasterizer.downsampledPreviewVolumeForModifierEditing(
            from: baseVolume,
            maxBytes: maxBytes
        )
    }

    private func texture(for id: UUID, fallbackAssetID: UUID? = nil) -> MTLTexture? {
        if let texture = modifiedTextures[id] ?? textures[id] {
            return texture
        }
        guard let fallbackAssetID, fallbackAssetID != id else {
            return nil
        }
        return textures[fallbackAssetID]
    }

    private func scale(for id: UUID, fallbackAssetID: UUID? = nil) -> SIMD3<Float>? {
        if let scale = modifiedVolumeScales[id] ?? volumeScales[id] {
            return scale
        }
        guard let fallbackAssetID, fallbackAssetID != id else {
            return nil
        }
        return volumeScales[fallbackAssetID]
    }

    private func usesAlpha(for id: UUID, fallbackAssetID: UUID? = nil) -> Bool {
        if let usesAlpha = modifiedVolumeUsesAlpha[id] ?? volumeUsesAlpha[id] {
            return usesAlpha
        }
        guard let fallbackAssetID, fallbackAssetID != id else {
            return true
        }
        return volumeUsesAlpha[fallbackAssetID] ?? true
    }

    private func updateEstimatedTextureMemory() {
        let baseBytes = textures.values.reduce(Int64(0)) {
            $0 + Self.estimatedTextureMemoryBytes($1)
        }
        let modifiedBytes = modifiedTextures.values.reduce(Int64(0)) {
            $0 + Self.estimatedTextureMemoryBytes($1)
        }
        estimatedTextureMemoryBytes = baseBytes + modifiedBytes
    }

    private func modifiedTextureSignature(
        base: LoadedVolume,
        modifiers: [MeshModifierItem]
    ) -> String {
        var parts: [String] = [
            base.textureCacheID.uuidString,
            "\(base.width)x\(base.height)x\(base.depth)"
        ]
        for modifier in modifiers {
            let state = modifier.state
            parts.append([
                modifier.id.uuidString,
                modifier.name,
                modifier.isEnabled ? "1" : "0",
                state.positionX.description,
                state.positionY.description,
                state.positionZ.description,
                state.rotationX.description,
                state.rotationY.description,
                state.rotationZ.description,
                state.scaleX.description,
                state.scaleY.description,
                state.scaleZ.description,
                state.inflate.description,
                state.inflateMode.rawValue,
                state.twistY.description,
                state.taperX.description,
                state.taperZ.description,
                state.mirrorX ? "1" : "0",
                state.mirrorY ? "1" : "0",
                state.mirrorZ ? "1" : "0"
            ].joined(separator: "|"))
        }
        return parts.joined(separator: "#")
    }

    private func notifyCameraChanged() {
        onCameraChanged?(CameraRigState(
            yaw: yaw,
            pitch: pitch,
            roll: roll,
            distance: distance,
            positionX: cameraPosition.x,
            positionY: cameraPosition.y,
            positionZ: cameraPosition.z,
            focusLockEnabled: focusLockEnabled,
            focusTargetX: focusTarget.x,
            focusTargetY: focusTarget.y,
            focusTargetZ: focusTarget.z,
            focalLength: focalLength,
            aperture: aperture
        ))
    }

    private func beginCameraInteractionIfNeeded() {
        guard interactionMode == .freeCamera else { return }
        onCameraInteractionBegan?()
    }

    private func endCameraInteractionIfNeeded() {
        guard interactionMode == .freeCamera else { return }
        onCameraInteractionEnded?()
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

    private func emitDiagnostics(
        view: MTKView,
        drawnLayerCount: Int,
        textureHitCount: Int,
        textureMissCount: Int
    ) {
        let now = CACurrentMediaTime()
        frameTimestamps.append(now)
        frameTimestamps.removeAll { now - $0 > 1.5 }

        let elapsed = max(0.001, now - (frameTimestamps.first ?? now))
        let fps = Double(frameTimestamps.count) / elapsed
        guard now - lastDiagnosticsEmitTime >= 0.25 else { return }
        lastDiagnosticsEmitTime = now

        onPreviewDiagnosticsChanged?(
            CompositionRendererDiagnostics(
                previewFPS: fps.isFinite ? fps : 0,
                renderPathText: "Metal GPU · \(device.name) · \(previewQualityDiagnosticsText)",
                drawableWidth: Int(view.drawableSize.width.rounded()),
                drawableHeight: Int(view.drawableSize.height.rounded()),
                drawnLayerCount: drawnLayerCount,
                textureHitCount: textureHitCount,
                textureMissCount: textureMissCount,
                estimatedTextureMemoryBytes: estimatedTextureMemoryBytes,
                updatedAt: Date()
            )
        )
    }

    private static func estimatedTextureMemoryBytes(_ texture: MTLTexture) -> Int64 {
        let bytesPerPixel: Int64
        switch texture.pixelFormat {
        case .rgba8Unorm, .bgra8Unorm, .rgba8Unorm_srgb, .bgra8Unorm_srgb:
            bytesPerPixel = 4
        case .rgba16Float:
            bytesPerPixel = 8
        case .rgba32Float:
            bytesPerPixel = 16
        default:
            bytesPerPixel = 4
        }
        let width = Int64(max(1, texture.width))
        let height = Int64(max(1, texture.height))
        let depth = Int64(max(1, texture.depth))
        return width * height * depth * bytesPerPixel
    }

    private var previewQualityDiagnosticsText: String {
        let effective = previewQuality.resolved(isPlaying: isPreviewPlaying)
        let steps = previewQuality.rayStepCount(isPlaying: isPreviewPlaying)
        let scale = previewQuality.drawableScale(isPlaying: isPreviewPlaying)
        if previewQuality == .automatic {
            return "自动→\(effective.title) · \(Int(scale * 100))% · \(steps) steps"
        }
        return "\(effective.title) · \(Int(scale * 100))% · \(steps) steps"
    }
}

private func compositionRadians(_ degrees: Float) -> Float {
    degrees * .pi / 180
}

private func compositionFocalLengthToFOV(_ focalLength: Float) -> Float {
    let sensorHeight: Float = 24
    let clamped = max(1, focalLength)
    return 2 * atan(sensorHeight / (2 * clamped)) * 180 / .pi
}

private func compositionPerspectiveFovRH(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
    let yScale = 1.0 / tan(fovyRadians * 0.5)
    let xScale = yScale / aspect
    let zRange = farZ - nearZ
    let zScale = -(farZ + nearZ) / zRange
    let wzScale = -2.0 * farZ * nearZ / zRange

    return simd_float4x4(
        SIMD4<Float>( xScale, 0,      0,       0),
        SIMD4<Float>( 0,      yScale, 0,       0),
        SIMD4<Float>( 0,      0,      zScale, -1),
        SIMD4<Float>( 0,      0,      wzScale, 0)
    )
}

func compositionTranslationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(t.x, t.y, t.z, 1)
    )
}

func compositionScaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(s.x, 0,   0,   0),
        SIMD4<Float>(0,   s.y, 0,   0),
        SIMD4<Float>(0,   0,   s.z, 0),
        SIMD4<Float>(0,   0,   0,   1)
    )
}

func compositionRotationMatrix(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let a = simd_normalize(axis)
    let x = a.x
    let y = a.y
    let z = a.z
    let c = cos(angle)
    let s = sin(angle)
    let mc = 1 - c

    return simd_float4x4(
        SIMD4<Float>(c + x*x*mc,     x*y*mc + z*s,   x*z*mc - y*s,   0),
        SIMD4<Float>(x*y*mc - z*s,   c + y*y*mc,     y*z*mc + x*s,   0),
        SIMD4<Float>(x*z*mc + y*s,   y*z*mc - x*s,   c + z*z*mc,     0),
        SIMD4<Float>(0,              0,              0,              1)
    )
}

private func compositionLookAtCameraWorldMatrix(position: SIMD3<Float>, target: SIMD3<Float>, roll: Float) -> simd_float4x4 {
    let toTarget = target - position
    let fallbackForward = SIMD3<Float>(0, 0, -1)
    let forward = simd_length_squared(toTarget) > 0.000001 ? simd_normalize(toTarget) : fallbackForward
    let worldUp = abs(simd_dot(forward, SIMD3<Float>(0, 1, 0))) > 0.98
        ? SIMD3<Float>(1, 0, 0)
        : SIMD3<Float>(0, 1, 0)

    var right = simd_normalize(simd_cross(forward, worldUp))
    var up = simd_normalize(simd_cross(right, forward))

    if abs(roll) > 0.000001 {
        let rollMat = compositionRotationMatrix(angle: roll, axis: forward)
        right = compositionTransformVector(rollMat, right)
        up = compositionTransformVector(rollMat, up)
    }

    return simd_float4x4(
        SIMD4<Float>(right.x, right.y, right.z, 0),
        SIMD4<Float>(up.x, up.y, up.z, 0),
        SIMD4<Float>(-forward.x, -forward.y, -forward.z, 0),
        SIMD4<Float>(position.x, position.y, position.z, 1)
    )
}

private func compositionTransformVector(_ matrix: simd_float4x4, _ vector: SIMD3<Float>) -> SIMD3<Float> {
    let v = matrix * SIMD4<Float>(vector.x, vector.y, vector.z, 0)
    return SIMD3<Float>(v.x, v.y, v.z)
}

func compositionVolumeTransformMatrix(_ transform: VolumeTransformState) -> simd_float4x4 {
    let translation = compositionTranslationMatrix(
        SIMD3<Float>(transform.positionX, transform.positionY, transform.positionZ)
    )
    let rotX = compositionRotationMatrix(angle: transform.rotationX, axis: SIMD3<Float>(1, 0, 0))
    let rotY = compositionRotationMatrix(angle: transform.rotationY, axis: SIMD3<Float>(0, 1, 0))
    let rotZ = compositionRotationMatrix(angle: transform.rotationZ, axis: SIMD3<Float>(0, 0, 1))
    let scale = SIMD3<Float>(
        max(0.01, transform.scaleX),
        max(0.01, transform.scaleY),
        max(0.01, transform.scaleZ)
    )
    return translation * rotZ * rotY * rotX * compositionScaleMatrix(scale)
}

struct CompositionVideoExportAsset {
    let id: UUID
    let volume: LoadedVolume
    let volumeScale: SIMD3<Float>
    let usesAlpha: Bool
}

enum CompositionTextureUploadMode {
    case strict
    case segmented
}

struct CompositionVideoExportRequest {
    var url: URL
    let width: Int
    let height: Int
    let fps: Double
    var startFrame: Int
    var frameCount: Int
    let bitDepth: Int
    let colorProfile: VideoColorProfile
    let backgroundColor: VolumeBackgroundColor
    let preserveAlpha: Bool
    let assets: [CompositionVideoExportAsset]
    let precompositions: [UUID: CompositionDocumentState]
    let layers: [CompositionLayer]
    let cameraClips: [CompositionCameraClip]
    let fallbackCamera: CameraRigState
    var textureUploadMode: CompositionTextureUploadMode = .strict
}

enum CompositionVideoExporter {
    static func export(
        request: CompositionVideoExportRequest,
        progress: @escaping ExportProgressHandler
    ) throws {
        let renderer = try OffscreenCompositionRenderer(
            assets: request.assets,
            width: request.width,
            height: request.height,
            bitDepth: request.bitDepth,
            preserveAlpha: request.preserveAlpha,
            backgroundColor: request.backgroundColor,
            textureUploadMode: request.textureUploadMode
        )
        let (writer, input, adaptor) = try makeWriter(
            outputURL: request.url,
            width: request.width,
            height: request.height,
            bitDepth: request.bitDepth,
            preserveAlpha: request.preserveAlpha,
            colorProfile: request.colorProfile
         )
        let frameDuration = CMTime(seconds: 1.0 / max(0.05, request.fps), preferredTimescale: 600)
        let frameCount = max(1, request.frameCount)

        for outputFrame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }

            if outputFrame % 4 == 0 {
                progress(
                    Double(outputFrame) / Double(frameCount),
                    "合成导出 第 \(outputFrame + 1)/\(frameCount) 帧"
                )
            }

            guard let pixelBuffer = makePixelBuffer(from: adaptor) else {
                throw VideoExportError.createPixelBufferFailed
            }

            let frame = request.startFrame + outputFrame
            let camera = renderCamera(
                at: frame,
                cameraClips: request.cameraClips,
                fallback: request.fallbackCamera
            )
            let layers = renderLayers(
                from: request.layers,
                precompositions: request.precompositions,
                at: frame,
                parentMatrix: matrix_identity_float4x4,
                opacityMultiplier: 1,
                seenPrecompositions: []
            )
            try renderer.render(to: pixelBuffer, layers: layers, camera: camera)

            let time = CMTimeMultiply(frameDuration, multiplier: Int32(outputFrame))
            if !adaptor.append(pixelBuffer, withPresentationTime: time) {
                throw VideoExportError.appendFailed(writer.error?.localizedDescription ?? "append 失败")
            }

            if outputFrame % 4 == 0 || outputFrame == frameCount - 1 {
                progress(Double(outputFrame + 1) / Double(frameCount), "合成导出")
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            if writer.status != .completed {
                finishError = writer.error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let finishError {
            throw VideoExportError.finishFailed(finishError.localizedDescription)
        }
    }

    static func exportInSegments(
        request: CompositionVideoExportRequest,
        framesPerSegment: Int = 48,
        progress: @escaping ExportProgressHandler
    ) async throws {
        let totalFrames = max(1, request.frameCount)
        let segmentSize = max(1, min(framesPerSegment, totalFrames))
        let segmentCount = Int(ceil(Double(totalFrames) / Double(segmentSize)))
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoVolumeCompositionSegments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        var segmentURLs: [URL] = []
        segmentURLs.reserveCapacity(segmentCount)
        for segmentIndex in 0..<segmentCount {
            let localStart = segmentIndex * segmentSize
            let count = min(segmentSize, totalFrames - localStart)
            let segmentURL = tempRoot.appendingPathComponent(
                String(format: "composition-segment-%04d.mov", segmentIndex)
            )
            var segmentRequest = request
            segmentRequest.url = segmentURL
            segmentRequest.startFrame = request.startFrame + localStart
            segmentRequest.frameCount = count
            segmentRequest.textureUploadMode = .segmented

            try export(request: segmentRequest) { segmentProgress, route in
                let combined = (Double(segmentIndex) + segmentProgress) / Double(segmentCount)
                progress(
                    min(0.98, combined),
                    "\(route ?? "高精度分段导出") \(segmentIndex + 1)/\(segmentCount)"
                )
            }
            segmentURLs.append(segmentURL)
        }

        progress(0.99, "正在自动合成分段")
        try await SegmentStitcher.stitch(segmentURLs: segmentURLs, outputURL: request.url)
        progress(1, "高精度分段导出完成")
    }

    private static func makeWriter(
        outputURL: URL,
        width: Int,
        height: Int,
        bitDepth: Int,
        preserveAlpha: Bool,
        colorProfile: VideoColorProfile
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let highBitDepth = bitDepth > 8
        let codec = (preserveAlpha || highBitDepth || colorProfile.isHDR)
            ? AVVideoCodecType.proRes4444.rawValue
            : AVVideoCodecType.h264.rawValue
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        settings[AVVideoColorPropertiesKey] = colorProfile.avVideoColorProperties
        if codec == AVVideoCodecType.h264.rawValue {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(4_000_000, width * height * 12),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )

        guard writer.canAdd(input) else {
            throw VideoExportError.createInputFailed
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoExportError.createWriterFailed(writer.error?.localizedDescription ?? "writer.startWriting 失败")
        }
        writer.startSession(atSourceTime: .zero)
        guard adaptor.pixelBufferPool != nil else {
            throw VideoExportError.createPixelBufferPoolFailed
        }
        return (writer, input, adaptor)
    }

    private static func makePixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return pb
    }

    private static func renderLayers(
        from layers: [CompositionLayer],
        precompositions: [UUID: CompositionDocumentState],
        at frame: Int,
        parentMatrix: simd_float4x4,
        opacityMultiplier: Float,
        seenPrecompositions: Set<UUID>
    ) -> [CompositionRenderLayer] {
        let hasSolo = layers.contains(where: \.isSolo)
        let activeLayers = layers.filter {
            $0.isVisible
                && (!hasSolo || $0.isSolo)
                && frame >= $0.startFrame
                && frame < $0.startFrame + $0.duration
        }

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
                        precompositions: precompositions,
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
                    precompositions: precompositions,
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

    private static func contentsOrRenderLayer(
        from layer: CompositionLayer,
        precompositions: [UUID: CompositionDocumentState],
        at frame: Int,
        parentMatrix: simd_float4x4,
        opacityMultiplier: Float,
        seenPrecompositions: Set<UUID>,
        trackMatte: CompositionLayer?
    ) -> [CompositionRenderLayer] {
        guard trackMatte == nil,
              let nested = precompositions[layer.assetID],
              !seenPrecompositions.contains(layer.assetID) else {
            return [
                renderLayer(
                    from: layer,
                    at: frame,
                    parentMatrix: parentMatrix,
                    opacityMultiplier: opacityMultiplier,
                    precompositions: precompositions,
                    trackMatte: trackMatte
                )
            ]
        }

        let resolved = resolvedLayer(layer, at: frame)
        var nextSeen = seenPrecompositions
        nextSeen.insert(layer.assetID)
        return renderLayers(
            from: nested.layers,
            precompositions: precompositions,
            at: frame - layer.startFrame,
            parentMatrix: parentMatrix * compositionVolumeTransformMatrix(resolved.transform),
            opacityMultiplier: opacityMultiplier * resolved.opacity,
            seenPrecompositions: nextSeen
        )
    }

    private static func renderLayer(
        from layer: CompositionLayer,
        at frame: Int,
        parentMatrix: simd_float4x4,
        opacityMultiplier: Float,
        precompositions: [UUID: CompositionDocumentState],
        trackMatte: CompositionLayer?
    ) -> CompositionRenderLayer {
        let resolved = resolvedLayer(layer, at: frame)
        let resolvedMatte = trackMatte.map { resolvedLayer($0, at: frame) }
        let modifierStates = resolvedModifiers(resolved.modifiers, at: frame)
        let matteModifierStates = resolvedMatte.map { resolvedModifiers($0.modifiers, at: frame) } ?? []
        let usesModifiedTexture = precompositions[resolved.assetID] == nil &&
            VolumeModifierRasterizer.hasActiveModifiers(modifierStates)
        let matteUsesModifiedTexture = resolvedMatte.map {
            precompositions[$0.assetID] == nil && VolumeModifierRasterizer.hasActiveModifiers(matteModifierStates)
        } ?? false
        return CompositionRenderLayer(
            id: resolved.id,
            assetID: resolved.assetID,
            textureID: usesModifiedTexture ? resolved.id : resolved.assetID,
            modifiers: modifierStates,
            transform: resolved.transform,
            transformMatrix: parentMatrix * compositionVolumeTransformMatrix(resolved.transform),
            blendMode: resolved.blendMode,
            volumeRenderMode: resolved.volumeRenderMode,
            opacity: opacityMultiplier * resolved.opacity,
            trackMatteAssetID: resolvedMatte?.assetID,
            trackMatteTextureID: resolvedMatte.map { matteUsesModifiedTexture ? $0.id : $0.assetID },
            trackMatteModifiers: matteModifierStates,
            trackMatteTransform: resolvedMatte?.transform,
            trackMatteTransformMatrix: resolvedMatte.map {
                parentMatrix * compositionVolumeTransformMatrix($0.transform)
            },
            trackMatteOpacity: resolvedMatte?.opacity ?? 1
        )
    }

    private static func resolvedLayer(_ layer: CompositionLayer, at frame: Int) -> CompositionLayer {
        var resolved = layer
        for property in CompositionLayerKeyframeProperty.allCases {
            guard let value = interpolatedLayerValue(layer: layer, property: property, at: frame) else {
                continue
            }
            setLayerValue(value, property: property, layer: &resolved)
        }
        return resolved
    }

    private static func resolvedModifiers(
        _ modifiers: [MeshModifierItem],
        at frame: Int
    ) -> [MeshModifierItem] {
        modifiers.map { modifier in
            var copy = modifier
            copy.state = resolvedModifierState(modifier, at: frame)
            return copy
        }
    }

    private static func resolvedModifierState(
        _ modifier: MeshModifierItem,
        at frame: Int
    ) -> MeshModifierState {
        var state = modifier.state
        for property in MeshModifierKeyframeProperty.allCases {
            if let value = interpolatedModifierValue(modifier: modifier, property: property, at: frame) {
                property.set(value, in: &state)
            }
        }
        return state
    }

    private static func interpolatedModifierValue(
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
        return lower.value + (upper.value - lower.value) * t
    }

    private static func interpolatedLayerValue(
        layer: CompositionLayer,
        property: CompositionLayerKeyframeProperty,
        at frame: Int
    ) -> Float? {
        let sorted = layer.keyframes.filter { $0.property == property }.sorted { $0.frame < $1.frame }
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first.value }
        if frame <= first.frame { return first.value }
        if let last = sorted.last, frame >= last.frame { return last.value }
        guard let upperIndex = sorted.firstIndex(where: { $0.frame >= frame }), upperIndex > 0 else {
            return first.value
        }
        let lower = sorted[upperIndex - 1]
        let upper = sorted[upperIndex]
        let t = Float(frame - lower.frame) / Float(max(1, upper.frame - lower.frame))
        return lower.value + (upper.value - lower.value) * t
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

    private static func interpolationAmount(
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
            return cubicBezierY(forX: linear, curve: sanitizedBezierCurve(curve))
        }
    }

    private static func cubicBezierY(forX x: Float, curve: CompositionBezierCurve) -> Float {
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

    private static func cubicBezierValue(_ t: Float, p1: Float, p2: Float) -> Float {
        let oneMinusT = 1 - t
        return 3 * oneMinusT * oneMinusT * t * p1
            + 3 * oneMinusT * t * t * p2
            + t * t * t
    }

    private static func sanitizedBezierCurve(_ curve: CompositionBezierCurve) -> CompositionBezierCurve {
        CompositionBezierCurve(
            controlPoint1X: max(0, min(1, curve.controlPoint1X)),
            controlPoint1Y: max(-3, min(3, curve.controlPoint1Y)),
            controlPoint2X: max(0, min(1, curve.controlPoint2X)),
            controlPoint2Y: max(-3, min(3, curve.controlPoint2Y))
        )
    }

    private static func renderCamera(
        at frame: Int,
        cameraClips: [CompositionCameraClip],
        fallback: CameraRigState
    ) -> CameraRigState {
        guard let clip = cameraClips.first(where: {
            frame >= $0.startFrame && frame < $0.startFrame + $0.duration
        }) ?? cameraClips.first else {
            return fallback
        }
        var camera = clip.camera
        for property in CompositionCameraKeyframeProperty.allCases {
            if let value = interpolatedCameraValue(property: property, at: frame, keyframes: clip.keyframes) {
                setCameraValue(value, property: property, camera: &camera)
            }
        }
        return camera
    }

    private static func interpolatedCameraValue(
        property: CompositionCameraKeyframeProperty,
        at frame: Int,
        keyframes: [CompositionCameraKeyframe]
    ) -> Float? {
        let sorted = keyframes.filter { $0.property == property }.sorted { $0.frame < $1.frame }
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first.value }
        if frame <= first.frame { return first.value }
        if let last = sorted.last, frame >= last.frame { return last.value }
        guard let upperIndex = sorted.firstIndex(where: { $0.frame >= frame }), upperIndex > 0 else {
            return first.value
        }
        let lower = sorted[upperIndex - 1]
        let upper = sorted[upperIndex]
        let t = Float(frame - lower.frame) / Float(max(1, upper.frame - lower.frame))
        return lower.value + (upper.value - lower.value) * t
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
}

private final class OffscreenCompositionRenderer {
    private struct DynamicModifierBaseKey: Hashable {
        let assetID: UUID
        let maxBytes: Int
    }

    private enum LayerTextureShape {
        case texture3D
        case texture2DArray
    }

    private struct LayerTexturePart {
        let texture: MTLTexture
        let shape: LayerTextureShape
        let volumeScale: SIMD3<Float>
        let volumeOffset: SIMD3<Float>
        let usesAlpha: Bool
    }

    private struct LayerTextureInfo {
        let parts: [LayerTexturePart]

        var primaryPart: LayerTexturePart? {
            parts.first
        }
    }

    private static let dynamicFracturedSurfaceExportMaxBytes = 16 * 1024 * 1024
    private static let dynamicSurfaceSDFExportMaxBytes = 32 * 1024 * 1024

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [CompositionLayerBlendMode: MTLRenderPipelineState]
    private let arrayPipelines: [CompositionLayerBlendMode: MTLRenderPipelineState]
    private let depthState: MTLDepthStencilState
    private let textureCache: CVMetalTextureCache
    private let vertexBuffer: MTLBuffer
    private let samplerState: MTLSamplerState
    private let width: Int
    private let height: Int
    private let targetPixelFormat: MTLPixelFormat
    private let preserveAlpha: Bool
    private let backgroundColor: VolumeBackgroundColor
    private let textureUploadMode: CompositionTextureUploadMode
    private let volumes: [UUID: LoadedVolume]
    private var textureInfos: [UUID: LayerTextureInfo]
    private var volumeScales: [UUID: SIMD3<Float>]
    private var dynamicModifiedTextureSignatures: [UUID: String] = [:]
    private var dynamicModifierBaseVolumes: [DynamicModifierBaseKey: LoadedVolume] = [:]

    init(
        assets: [CompositionVideoExportAsset],
        width: Int,
        height: Int,
        bitDepth: Int,
        preserveAlpha: Bool,
        backgroundColor: VolumeBackgroundColor,
        textureUploadMode: CompositionTextureUploadMode = .strict
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw VideoExportError.metalUnavailable("无法创建合成导出 Metal 设备")
        }
        self.device = device
        self.queue = queue
        self.width = width
        self.height = height
        self.targetPixelFormat = .bgra8Unorm
        self.preserveAlpha = preserveAlpha
        self.backgroundColor = backgroundColor
        self.textureUploadMode = textureUploadMode

        let library = try device.makeDefaultLibrary(bundle: .main)
        var builtPipelines: [CompositionLayerBlendMode: MTLRenderPipelineState] = [:]
        var builtArrayPipelines: [CompositionLayerBlendMode: MTLRenderPipelineState] = [:]
        for blendMode in CompositionLayerBlendMode.allCases {
            builtPipelines[blendMode] = try makeCompositionVolumePipeline(
                device: device,
                library: library,
                colorPixelFormat: targetPixelFormat,
                depthPixelFormat: .depth32Float,
                blendMode: blendMode
            )
            builtArrayPipelines[blendMode] = try makeCompositionVolumePipeline(
                device: device,
                library: library,
                colorPixelFormat: targetPixelFormat,
                depthPixelFormat: .depth32Float,
                blendMode: blendMode,
                fragmentFunctionName: "volumeArrayFragment"
            )
        }
        pipelines = builtPipelines
        arrayPipelines = builtArrayPipelines

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.isDepthWriteEnabled = false
        depthDesc.depthCompareFunction = .always
        guard let depthState = device.makeDepthStencilState(descriptor: depthDesc) else {
            throw VideoExportError.metalUnavailable("无法创建合成导出 depth state")
        }
        self.depthState = depthState

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            throw VideoExportError.metalUnavailable("无法创建合成导出 texture cache")
        }
        textureCache = cache

        let vertices: [SIMD3<Float>] = [
            SIMD3(-0.5,-0.5,-0.5), SIMD3( 0.5,-0.5,-0.5), SIMD3( 0.5, 0.5,-0.5),
            SIMD3(-0.5,-0.5,-0.5), SIMD3( 0.5, 0.5,-0.5), SIMD3(-0.5, 0.5,-0.5),
            SIMD3(-0.5,-0.5, 0.5), SIMD3( 0.5, 0.5, 0.5), SIMD3( 0.5,-0.5, 0.5),
            SIMD3(-0.5,-0.5, 0.5), SIMD3(-0.5, 0.5, 0.5), SIMD3( 0.5, 0.5, 0.5),
            SIMD3(-0.5,-0.5,-0.5), SIMD3(-0.5, 0.5,-0.5), SIMD3(-0.5, 0.5, 0.5),
            SIMD3(-0.5,-0.5,-0.5), SIMD3(-0.5, 0.5, 0.5), SIMD3(-0.5,-0.5, 0.5),
            SIMD3( 0.5,-0.5,-0.5), SIMD3( 0.5,-0.5, 0.5), SIMD3( 0.5, 0.5, 0.5),
            SIMD3( 0.5,-0.5,-0.5), SIMD3( 0.5, 0.5, 0.5), SIMD3( 0.5, 0.5,-0.5),
            SIMD3(-0.5,-0.5,-0.5), SIMD3(-0.5,-0.5, 0.5), SIMD3( 0.5,-0.5, 0.5),
            SIMD3(-0.5,-0.5,-0.5), SIMD3( 0.5,-0.5, 0.5), SIMD3( 0.5,-0.5,-0.5),
            SIMD3(-0.5, 0.5,-0.5), SIMD3( 0.5, 0.5,-0.5), SIMD3( 0.5, 0.5, 0.5),
            SIMD3(-0.5, 0.5,-0.5), SIMD3( 0.5, 0.5, 0.5), SIMD3(-0.5, 0.5, 0.5)
        ]
        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<SIMD3<Float>>.stride,
            options: .storageModeShared
        ) else {
            throw VideoExportError.metalUnavailable("无法创建合成导出 vertex buffer")
        }
        self.vertexBuffer = vertexBuffer

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        samplerDesc.rAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw VideoExportError.metalUnavailable("无法创建合成导出 sampler")
        }
        samplerState = sampler

        var textureInfos: [UUID: LayerTextureInfo] = [:]
        var scales: [UUID: SIMD3<Float>] = [:]
        var volumes: [UUID: LoadedVolume] = [:]
        for asset in assets {
            volumes[asset.id] = asset.volume
            let textureInfo = try Self.makeTextureInfo(
                device: device,
                volume: asset.volume,
                volumeScale: asset.volumeScale,
                usesAlpha: asset.usesAlpha,
                uploadMode: textureUploadMode,
                context: "合成导出素材体纹理"
            )
            textureInfos[asset.id] = textureInfo
            scales[asset.id] = asset.volumeScale
        }
        self.volumes = volumes
        self.textureInfos = textureInfos
        self.volumeScales = scales
    }

    func render(to pixelBuffer: CVPixelBuffer, layers: [CompositionRenderLayer], camera: CameraRigState) throws {
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            targetPixelFormat,
            width,
            height,
            0,
            &cvTexture
        ) == kCVReturnSuccess,
              let cvTexture,
              let targetTexture = CVMetalTextureGetTexture(cvTexture) else {
            throw VideoExportError.metalUnavailable("无法创建合成导出目标纹理")
        }

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDesc.usage = [.renderTarget]
        guard let depthTexture = device.makeTexture(descriptor: depthDesc) else {
            throw VideoExportError.metalUnavailable("无法创建合成导出深度纹理")
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targetTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = preserveAlpha
            ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            : MTLClearColor(red: backgroundColor.red, green: backgroundColor.green, blue: backgroundColor.blue, alpha: 1)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw VideoExportError.metalUnavailable("无法创建合成导出 command encoder")
        }

        let aspect = Float(width) / Float(max(1, height))
        let proj = compositionPerspectiveFovRH(
            fovyRadians: compositionRadians(compositionFocalLengthToFOV(camera.focalLength)),
            aspect: aspect,
            nearZ: 0.1,
            farZ: 100
        )
        let rotY = compositionRotationMatrix(angle: camera.yaw, axis: SIMD3<Float>(0, 1, 0))
        let rotX = compositionRotationMatrix(angle: camera.pitch, axis: SIMD3<Float>(1, 0, 0))
        let rotZ = compositionRotationMatrix(angle: camera.roll, axis: SIMD3<Float>(0, 0, 1))
        let cameraPosition = SIMD3<Float>(camera.positionX, camera.positionY, camera.positionZ)
        let cameraWorld = camera.focusLockEnabled
            ? compositionLookAtCameraWorldMatrix(
                position: cameraPosition,
                target: SIMD3<Float>(camera.focusTargetX, camera.focusTargetY, camera.focusTargetZ),
                roll: camera.roll
            )
            : compositionTranslationMatrix(cameraPosition) * rotY * rotX * rotZ
        let camPos4 = cameraWorld * SIMD4<Float>(0, 0, 0, 1)
        let cameraPositionWorld = SIMD3<Float>(camPos4.x, camPos4.y, camPos4.z)
        let viewMat = cameraWorld.inverse

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        do {
            for layer in layers {
                guard let layerTexture = try textureInfo(
                    textureID: layer.textureID,
                    fallbackAssetID: layer.assetID,
                    modifiers: layer.modifiers
                ) else {
                    continue
                }
                let blendMode = layer.blendMode == .alphaTrackMatte ? .normal : layer.blendMode
                var mattePart: LayerTexturePart?
                if let matteTextureID = layer.trackMatteTextureID,
                   let matteAssetID = layer.trackMatteAssetID,
                   layer.trackMatteTransformMatrix != nil,
                   let matteTextureInfo = try textureInfo(
                    textureID: matteTextureID,
                    fallbackAssetID: matteAssetID,
                    modifiers: layer.trackMatteModifiers
                   ) {
                    guard matteTextureInfo.parts.count == 1,
                          let onlyMattePart = matteTextureInfo.primaryPart else {
                        throw VideoExportError.textureBottleneck(
                            "高精度分段导出暂不支持超大轨道遮罩体纹理。请先改用代理预览，或降低遮罩素材分辨率/帧数。"
                        )
                    }
                    mattePart = onlyMattePart
                }

                for part in sortedTextureParts(layerTexture.parts, transformMatrix: layer.transformMatrix, cameraPosition: cameraPositionWorld) {
                    let pipelineSource = part.shape == .texture2DArray ? arrayPipelines : pipelines
                    guard let pipeline = pipelineSource[blendMode] ?? pipelineSource[.normal] else { continue }
                    let model = layer.transformMatrix
                        * compositionTranslationMatrix(part.volumeOffset)
                        * compositionScaleMatrix(part.volumeScale)
                    let mvp = proj * viewMat * model
                    var uniforms = Uniforms(
                        modelViewProjectionMatrix: mvp,
                        modelMatrix: model,
                        invModelMatrix: model.inverse,
                        cameraPositionWorld: cameraPositionWorld,
                        steps: 192,
                        density: 1.1,
                        brightness: 1.6,
                        useAlpha: part.usesAlpha ? 1 : 0,
                        useVoxelBlockRendering: layer.volumeRenderMode == .pixelVolume ? 1 : 0,
                        outputStraightAlpha: preserveAlpha ? 1 : 0,
                        smoothEdges: 1,
                        layerOpacity: max(0, min(1, layer.opacity)),
                        matteDiscardTransparent: 0
                    )
                    var matteTexture = part.texture
                    if let mattePart,
                       let matteTransformMatrix = layer.trackMatteTransformMatrix {
                        guard mattePart.shape == part.shape else {
                            throw VideoExportError.textureBottleneck(
                                "高精度分段导出暂不支持 3D 纹理和 2D 阵列纹理混合的轨道遮罩。请先关闭遮罩或改用代理预览。"
                            )
                        }
                        let matteModel = matteTransformMatrix
                            * compositionTranslationMatrix(mattePart.volumeOffset)
                            * compositionScaleMatrix(mattePart.volumeScale)
                        uniforms.trackMatteEnabled = 1
                        uniforms.trackMatteUseAlpha = mattePart.usesAlpha ? 1 : 0
                        uniforms.trackMatteOpacity = max(0, min(1, layer.trackMatteOpacity))
                        uniforms.trackMatteInvModelMatrix = matteModel.inverse
                        matteTexture = mattePart.texture
                    }
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                    encoder.setFragmentTexture(part.texture, index: 0)
                    encoder.setFragmentTexture(matteTexture, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
                }
            }
        } catch {
            encoder.endEncoding()
            throw error
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func textureInfo(
        textureID: UUID,
        fallbackAssetID: UUID,
        modifiers: [MeshModifierItem]
    ) throws -> LayerTextureInfo? {
        let hasActiveModifiers = textureID != fallbackAssetID &&
            VolumeModifierRasterizer.hasActiveModifiers(modifiers)
        if hasActiveModifiers {
            let hasModifierKeyframes = modifiers.contains { !$0.keyframes.isEmpty }
            if !hasModifierKeyframes, let precomputed = cachedTextureInfo(for: textureID) {
                return precomputed
            }
            if let generated = try generatedModifiedTextureInfo(
                textureID: textureID,
                fallbackAssetID: fallbackAssetID,
                modifiers: modifiers
            ) {
                return generated
            }
        }

        if let textureInfo = cachedTextureInfo(for: textureID) {
            return textureInfo
        }
        guard textureID != fallbackAssetID else { return nil }
        return cachedTextureInfo(for: fallbackAssetID)
    }

    private func generatedModifiedTextureInfo(
        textureID: UUID,
        fallbackAssetID: UUID,
        modifiers: [MeshModifierItem]
    ) throws -> LayerTextureInfo? {
        guard let baseVolume = volumes[fallbackAssetID],
              let baseScale = volumeScales[fallbackAssetID] else {
            return nil
        }

        let sourceVolume = dynamicModifierSourceVolume(
            fallbackAssetID: fallbackAssetID,
            baseVolume: baseVolume,
            modifiers: modifiers
        )
        let signature = Self.modifiedTextureSignature(base: sourceVolume, modifiers: modifiers)
        if dynamicModifiedTextureSignatures[textureID] != signature || textureInfos[textureID] == nil {
            let modifiedVolume = VolumeModifierRasterizer.applyingForInteractivePreview(modifiers, to: sourceVolume)
            let modifiedTextureInfo = try Self.makeTextureInfo(
                device: device,
                volume: modifiedVolume,
                volumeScale: baseScale,
                usesAlpha: modifiedVolume.hasMeaningfulAlpha,
                uploadMode: textureUploadMode,
                context: "合成导出动态修改体纹理"
            )
            textureInfos[textureID] = modifiedTextureInfo
            volumeScales[textureID] = baseScale
            dynamicModifiedTextureSignatures[textureID] = signature
        }

        return cachedTextureInfo(for: textureID)
    }

    private func dynamicModifierSourceVolume(
        fallbackAssetID: UUID,
        baseVolume: LoadedVolume,
        modifiers: [MeshModifierItem]
    ) -> LoadedVolume {
        guard let maxBytes = Self.dynamicModifierExportMaxBytes(for: modifiers) else {
            return baseVolume
        }
        let key = DynamicModifierBaseKey(assetID: fallbackAssetID, maxBytes: maxBytes)
        if let cached = dynamicModifierBaseVolumes[key] {
            return cached
        }
        let reduced = VolumeModifierRasterizer.downsampledPreviewVolumeForModifierEditing(
            from: baseVolume,
            maxBytes: maxBytes
        )
        dynamicModifierBaseVolumes[key] = reduced
        return reduced
    }

    private static func dynamicModifierExportMaxBytes(for modifiers: [MeshModifierItem]) -> Int? {
        guard modifiers.contains(where: { !$0.keyframes.isEmpty }),
              VolumeModifierRasterizer.usesSurfaceSDFMode(modifiers) else {
            return nil
        }
        let usesFracturedSurface = modifiers.contains {
            $0.isEnabled && $0.state.inflateMode == .fracturedSurface
        }
        return usesFracturedSurface
            ? dynamicFracturedSurfaceExportMaxBytes
            : dynamicSurfaceSDFExportMaxBytes
    }

    private func cachedTextureInfo(for id: UUID) -> LayerTextureInfo? {
        textureInfos[id]
    }

    private func sortedTextureParts(
        _ parts: [LayerTexturePart],
        transformMatrix: simd_float4x4,
        cameraPosition: SIMD3<Float>
    ) -> [LayerTexturePart] {
        parts.sorted { lhs, rhs in
            let lhsCenter4 = transformMatrix * SIMD4<Float>(
                lhs.volumeOffset.x,
                lhs.volumeOffset.y,
                lhs.volumeOffset.z,
                1
            )
            let rhsCenter4 = transformMatrix * SIMD4<Float>(
                rhs.volumeOffset.x,
                rhs.volumeOffset.y,
                rhs.volumeOffset.z,
                1
            )
            let lhsCenter = SIMD3<Float>(lhsCenter4.x, lhsCenter4.y, lhsCenter4.z)
            let rhsCenter = SIMD3<Float>(rhsCenter4.x, rhsCenter4.y, rhsCenter4.z)
            return simd_length_squared(lhsCenter - cameraPosition) > simd_length_squared(rhsCenter - cameraPosition)
        }
    }

    private static func makeTextureInfo(
        device: MTLDevice,
        volume: LoadedVolume,
        volumeScale: SIMD3<Float>,
        usesAlpha: Bool,
        uploadMode: CompositionTextureUploadMode,
        context: String
    ) throws -> LayerTextureInfo {
        do {
            let texture = try VolumeTextureUploadGuard.makeRGBA8Texture(
                device: device,
                volume: volume,
                context: context
            )
            return LayerTextureInfo(parts: [
                LayerTexturePart(
                    texture: texture,
                    shape: .texture3D,
                    volumeScale: volumeScale,
                    volumeOffset: SIMD3<Float>(repeating: 0),
                    usesAlpha: usesAlpha
                )
            ])
        } catch {
            guard uploadMode == .segmented,
                  (error as? VideoExportError)?.isTextureBottleneck == true else {
                throw error
            }
            do {
                return try makeArrayTextureInfo(
                    device: device,
                    volume: volume,
                    volumeScale: volumeScale,
                    usesAlpha: usesAlpha,
                    context: context
                )
            } catch {
                if volume.width > VolumeTextureUploadGuard.max3DTextureDimension ||
                    volume.height > VolumeTextureUploadGuard.max3DTextureDimension {
                    throw error
                }
            }
            return try makeSegmentedTextureInfo(
                device: device,
                volume: volume,
                volumeScale: volumeScale,
                usesAlpha: usesAlpha,
                context: context
            )
        }
    }

    private static func makeArrayTextureInfo(
        device: MTLDevice,
        volume: LoadedVolume,
        volumeScale: SIMD3<Float>,
        usesAlpha: Bool,
        context: String
    ) throws -> LayerTextureInfo {
        let texture = try VolumeTextureUploadGuard.makeRGBA8ArrayTexture(
            device: device,
            volume: volume,
            context: "\(context) 2D 阵列"
        )
        return LayerTextureInfo(parts: [
            LayerTexturePart(
                texture: texture,
                shape: .texture2DArray,
                volumeScale: volumeScale,
                volumeOffset: SIMD3<Float>(repeating: 0),
                usesAlpha: usesAlpha
            )
        ])
    }

    private static func makeSegmentedTextureInfo(
        device: MTLDevice,
        volume: LoadedVolume,
        volumeScale: SIMD3<Float>,
        usesAlpha: Bool,
        context: String
    ) throws -> LayerTextureInfo {
        let budget = max(1, VolumeTextureUploadGuard.singleTextureBudgetBytes(device: device))
        let maxDimension = VolumeTextureUploadGuard.max3DTextureDimension
        let xRanges = segmentedRanges(total: volume.width, maxCount: maxDimension)
        let yRanges = segmentedRanges(total: volume.height, maxCount: maxDimension)
        let originalWidth = max(1, volume.width)
        let originalHeight = max(1, volume.height)
        let originalDepth = max(1, volume.depth)
        var parts: [LayerTexturePart] = []

        for yRange in yRanges {
            for xRange in xRanges {
                let tileFrameBytes = Int64(xRange.count) * Int64(yRange.count) * 4
                guard tileFrameBytes > 0 else {
                    throw VideoExportError.textureBottleneck("\(context) 无法分块：单块数据大小无效。")
                }
                let maxDepthPerPart = max(1, min(maxDimension, Int(budget / tileFrameBytes)))
                guard maxDepthPerPart > 0 else {
                    throw VideoExportError.textureBottleneck(
                        "\(context) 无法分块到安全大小：单块单层约 \(VolumeTextureUploadGuard.formattedBytes(tileFrameBytes))，安全预算 \(VolumeTextureUploadGuard.formattedBytes(budget))。"
                    )
                }

                var zStart = 0
                while zStart < volume.depth {
                    let zCount = min(maxDepthPerPart, volume.depth - zStart)
                    let tileRGBA = segmentedRGBA(
                        volume: volume,
                        xRange: xRange,
                        yRange: yRange,
                        zStart: zStart,
                        zCount: zCount
                    )
                    let tileVolume = LoadedVolume(
                        width: xRange.count,
                        height: yRange.count,
                        depth: zCount,
                        rgba: tileRGBA,
                        hasMeaningfulAlpha: volume.hasMeaningfulAlpha,
                        sourceFPS: volume.sourceFPS,
                        sourceDurationSeconds: volume.sourceDurationSeconds,
                        sourceFrameCountEstimate: volume.sourceFrameCountEstimate,
                        sourceColorProfile: volume.sourceColorProfile
                    )
                    let texture = try VolumeTextureUploadGuard.makeRGBA8Texture(
                        device: device,
                        volume: tileVolume,
                        context: "\(context) 分块 \(parts.count + 1)"
                    )

                    let xRatio = Float(xRange.count) / Float(originalWidth)
                    let yRatio = Float(yRange.count) / Float(originalHeight)
                    let zRatio = Float(zCount) / Float(originalDepth)
                    let xOffsetRatio = (Float(xRange.start) + Float(xRange.count) * 0.5 - Float(originalWidth) * 0.5) / Float(originalWidth)
                    let yOffsetRatio = (Float(originalHeight) * 0.5 - (Float(yRange.start) + Float(yRange.count) * 0.5)) / Float(originalHeight)
                    let zOffsetRatio = (Float(zStart) + Float(zCount) * 0.5 - Float(originalDepth) * 0.5) / Float(originalDepth)

                    parts.append(
                        LayerTexturePart(
                            texture: texture,
                            shape: .texture3D,
                            volumeScale: SIMD3<Float>(
                                max(0.0001, volumeScale.x * xRatio),
                                max(0.0001, volumeScale.y * yRatio),
                                max(0.0001, volumeScale.z * zRatio)
                            ),
                            volumeOffset: SIMD3<Float>(
                                volumeScale.x * xOffsetRatio,
                                volumeScale.y * yOffsetRatio,
                                volumeScale.z * zOffsetRatio
                            ),
                            usesAlpha: usesAlpha
                        )
                    )
                    zStart += zCount
                }
            }
        }

        guard !parts.isEmpty else {
            throw VideoExportError.textureBottleneck("\(context) 分块失败：没有生成任何分块。")
        }
        return LayerTextureInfo(parts: parts)
    }

    private static func segmentedRanges(
        total: Int,
        maxCount: Int
    ) -> [(start: Int, count: Int)] {
        let safeTotal = max(1, total)
        let safeMax = max(1, maxCount)
        var ranges: [(start: Int, count: Int)] = []
        var start = 0
        while start < safeTotal {
            let count = min(safeMax, safeTotal - start)
            ranges.append((start, count))
            start += count
        }
        return ranges
    }

    private static func segmentedRGBA(
        volume: LoadedVolume,
        xRange: (start: Int, count: Int),
        yRange: (start: Int, count: Int),
        zStart: Int,
        zCount: Int
    ) -> [UInt8] {
        let rowBytes = volume.width * 4
        let tileRowBytes = xRange.count * 4
        let frameBytes = volume.width * volume.height * 4
        var rgba: [UInt8] = []
        rgba.reserveCapacity(xRange.count * yRange.count * zCount * 4)

        for z in zStart..<(zStart + zCount) {
            let frameBase = z * frameBytes
            for y in yRange.start..<(yRange.start + yRange.count) {
                let rowStart = frameBase + y * rowBytes + xRange.start * 4
                let rowEnd = rowStart + tileRowBytes
                rgba.append(contentsOf: volume.rgba[rowStart..<rowEnd])
            }
        }
        return rgba
    }

    private static func modifiedTextureSignature(
        base: LoadedVolume,
        modifiers: [MeshModifierItem]
    ) -> String {
        var parts: [String] = [
            base.textureCacheID.uuidString,
            "\(base.width)x\(base.height)x\(base.depth)"
        ]
        for modifier in modifiers {
            let state = modifier.state
            parts.append([
                modifier.id.uuidString,
                modifier.name,
                modifier.isEnabled ? "1" : "0",
                state.positionX.description,
                state.positionY.description,
                state.positionZ.description,
                state.rotationX.description,
                state.rotationY.description,
                state.rotationZ.description,
                state.scaleX.description,
                state.scaleY.description,
                state.scaleZ.description,
                state.inflate.description,
                state.inflateMode.rawValue,
                state.twistY.description,
                state.taperX.description,
                state.taperZ.description,
                state.mirrorX ? "1" : "0",
                state.mirrorY ? "1" : "0",
                state.mirrorZ ? "1" : "0"
            ].joined(separator: "|"))
        }
        return parts.joined(separator: "#")
    }
}
