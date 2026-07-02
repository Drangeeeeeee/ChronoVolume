import Foundation
import MetalKit
import simd
import AppKit

struct Uniforms {
    var modelViewProjectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var invModelMatrix: simd_float4x4
    var cameraPositionWorld: SIMD3<Float>
    var steps: UInt32
    var density: Float
    var brightness: Float
    var useAlpha: UInt32
    var useVoxelBlockRendering: UInt32
    var outputStraightAlpha: UInt32 = 0
    var smoothEdges: UInt32 = 0
    var layerOpacity: Float = 1
    var matteDiscardTransparent: UInt32 = 0
    var trackMatteEnabled: UInt32 = 0
    var trackMatteUseAlpha: UInt32 = 1
    var trackMatteOpacity: Float = 1
    var trackMatteInvModelMatrix: simd_float4x4 = matrix_identity_float4x4
    var volumeUVScale: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var volumeUVOffset: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
}

enum PlaneAxisLock {
    case x
    case y
    case t
}

enum VolumeCameraMode {
    case orbit
    case freeCamera
}

final class VolumeRenderer: NSObject, MTKViewDelegate, InteractiveMTKViewDelegate {
    private weak var view: MTKView?
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let meshSurfacePipeline: MTLRenderPipelineState
    private let planeOverlayPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let overlayDepthState: MTLDepthStencilState
    private var uniformBuffer: MTLBuffer
    private var vertexBuffer: MTLBuffer
    private var samplerState: MTLSamplerState

    private var volumeTexture: MTLTexture?
    private var meshSurfaceBuffer: MTLBuffer?
    private var meshSurfaceVertexCount = 0
    private var volumeScale = SIMD3<Float>(1, 1, 1)
    private var volumeTransform = VolumeTransformState()
    private var referencePlaneOverlayVertices: [SIMD3<Float>] = []
    private var showReferencePlaneOverlay = false

    var useAlpha: Bool = true
    var useVoxelBlockRendering: Bool = false
    var steps: Int = 192
    var density: Float = 1.1
    var brightness: Float = 1.6
    var focalLength: Float = 50
    var smoothEdges: Bool = false
    var cameraMode: VolumeCameraMode = .orbit

    var onCameraChanged: ((Float, Float, Float, Float, Float, Float, Float) -> Void)?
    var onReferencePlaneDelta: ((Float?, Float?, Float?) -> Void)?

    private var yaw: Float = 0
    private var pitch: Float = 0
    private var roll: Float = 0
    private var distance: Float = 2.2
    private var cameraPosition = SIMD3<Float>(0, 0, 0)
    private var focusLockEnabled = false
    private var focusTarget = SIMD3<Float>(0, 0, 0)
    private var backgroundColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    private var lastLeftPoint: CGPoint?
    private var lastRightPoint: CGPoint?
    private var planeAxisLock: PlaneAxisLock?

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

        guard let vertexFunc = library.makeFunction(name: "volumeVertex"),
              let fragmentFunc = library.makeFunction(name: "volumeFragment") else {
            fatalError("找不到 volumeVertex / volumeFragment")
        }
        guard let meshVertexFunc = library.makeFunction(name: "meshSurfaceVertex"),
              let meshFragmentFunc = library.makeFunction(name: "meshSurfaceFragment") else {
            fatalError("找不到 meshSurfaceVertex / meshSurfaceFragment")
        }
        guard let planeVertexFunc = library.makeFunction(name: "planeOverlayVertex"),
              let planeFragmentFunc = library.makeFunction(name: "planeOverlayFragment") else {
            fatalError("找不到 planeOverlayVertex / planeOverlayFragment")
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragmentFunc
        pipelineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipelineDesc.inputPrimitiveTopology = .triangle

        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            fatalError("创建 RenderPipelineState 失败：\(error)")
        }

        let meshPipelineDesc = MTLRenderPipelineDescriptor()
        meshPipelineDesc.vertexFunction = meshVertexFunc
        meshPipelineDesc.fragmentFunction = meshFragmentFunc
        meshPipelineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        meshPipelineDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        meshPipelineDesc.inputPrimitiveTopology = .triangle

        do {
            self.meshSurfacePipeline = try device.makeRenderPipelineState(descriptor: meshPipelineDesc)
        } catch {
            fatalError("创建 Mesh Surface Pipeline 失败：\(error)")
        }

        let planePipelineDesc = MTLRenderPipelineDescriptor()
        planePipelineDesc.vertexFunction = planeVertexFunc
        planePipelineDesc.fragmentFunction = planeFragmentFunc
        planePipelineDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        planePipelineDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        planePipelineDesc.inputPrimitiveTopology = .triangle
        planePipelineDesc.colorAttachments[0].isBlendingEnabled = true
        planePipelineDesc.colorAttachments[0].rgbBlendOperation = .add
        planePipelineDesc.colorAttachments[0].alphaBlendOperation = .add
        planePipelineDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        planePipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        planePipelineDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        planePipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.planeOverlayPipeline = try device.makeRenderPipelineState(descriptor: planePipelineDesc)
        } catch {
            fatalError("创建参考面 Overlay Pipeline 失败：\(error)")
        }

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.isDepthWriteEnabled = true
        depthDesc.depthCompareFunction = .lessEqual
        guard let depthState = device.makeDepthStencilState(descriptor: depthDesc) else {
            fatalError("创建 DepthStencilState 失败")
        }
        self.depthState = depthState

        let overlayDepthDesc = MTLDepthStencilDescriptor()
        overlayDepthDesc.isDepthWriteEnabled = false
        overlayDepthDesc.depthCompareFunction = .always
        guard let overlayDepthState = device.makeDepthStencilState(descriptor: overlayDepthDesc) else {
            fatalError("创建 Overlay DepthStencilState 失败")
        }
        self.overlayDepthState = overlayDepthState

        guard let uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride,
                                                    options: .storageModeShared) else {
            fatalError("创建 uniformBuffer 失败")
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

        guard let vertexBuffer = device.makeBuffer(bytes: cubeVertices,
                                                   length: cubeVertices.count * MemoryLayout<SIMD3<Float>>.stride,
                                                   options: .storageModeShared) else {
            fatalError("创建 vertexBuffer 失败")
        }
        self.vertexBuffer = vertexBuffer

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        samplerDesc.rAddressMode = .clampToEdge

        guard let samplerState = device.makeSamplerState(descriptor: samplerDesc) else {
            fatalError("创建 samplerState 失败")
        }
        self.samplerState = samplerState

        super.init()
        notifyCameraChanged()
    }

    func requestRedraw() {
        view?.needsDisplay = true
    }

    func resetView() {
        yaw = 0
        pitch = 0
        roll = 0
        distance = 2.2
        cameraPosition = SIMD3<Float>(0, 0, 0)
        lastLeftPoint = nil
        lastRightPoint = nil
        planeAxisLock = nil
        notifyCameraChanged()
        requestRedraw()
    }

    func setCamera(
        yaw: Float,
        pitch: Float,
        roll: Float = 0,
        distance: Float,
        position: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        focusLockEnabled: Bool = false,
        focusTarget: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        notify: Bool = false
    ) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.distance = max(0.8, distance)
        self.cameraPosition = position
        self.focusLockEnabled = focusLockEnabled
        self.focusTarget = focusTarget
        if notify {
            notifyCameraChanged()
        }
        requestRedraw()
    }

    func setBackgroundColor(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        backgroundColor = MTLClearColor(
            red: max(0, min(1, red)),
            green: max(0, min(1, green)),
            blue: max(0, min(1, blue)),
            alpha: max(0, min(1, alpha))
        )
        view?.clearColor = backgroundColor
        view?.layer?.isOpaque = false
        requestRedraw()
    }

    func setDisplayScale(_ scale: SIMD3<Float>) {
        self.volumeScale = scale
        requestRedraw()
    }

    func setVolumeTransform(_ transform: VolumeTransformState) {
        self.volumeTransform = transform
        requestRedraw()
    }

    func setReferencePlaneOverlay(vertices: [SIMD3<Float>], visible: Bool) {
        self.referencePlaneOverlayVertices = vertices
        self.showReferencePlaneOverlay = visible
        requestRedraw()
    }

    func setMeshSurface(_ mesh: LoadedMesh?) {
        guard let mesh, !mesh.vertices.isEmpty else {
            meshSurfaceBuffer = nil
            meshSurfaceVertexCount = 0
            requestRedraw()
            return
        }

        meshSurfaceBuffer = device.makeBuffer(
            bytes: mesh.vertices,
            length: mesh.vertices.count * MemoryLayout<MeshSurfaceVertex>.stride,
            options: .storageModeShared
        )
        meshSurfaceVertexCount = meshSurfaceBuffer == nil ? 0 : mesh.vertices.count
        requestRedraw()
    }

    func setVolume(_ volume: LoadedVolume) {
        setMeshSurface(nil)
        if let cachedTexture = VolumeModifierRasterizer.cachedModifiedTexture(
            for: volume.textureCacheID,
            device: device
        ) {
            self.volumeTexture = cachedTexture
            applyVolumeScale(width: volume.width, height: volume.height, depth: volume.depth)
            requestRedraw()
            return
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba8Unorm
        desc.width = volume.width
        desc.height = volume.height
        desc.depth = volume.depth
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            print("makeTexture 失败")
            return
        }

        let region = MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth)
        texture.replace(
            region: region,
            mipmapLevel: 0,
            slice: 0,
            withBytes: volume.rgba,
            bytesPerRow: volume.width * 4,
            bytesPerImage: volume.width * volume.height * 4
        )

        self.volumeTexture = texture
        applyVolumeScale(width: volume.width, height: volume.height, depth: volume.depth)

        requestRedraw()
    }

    private func applyVolumeScale(width: Int, height: Int, depth: Int) {
        let maxDim = Float(max(width, max(height, depth)))
        self.volumeScale = SIMD3(
            Float(width) / maxDim,
            Float(height) / maxDim,
            Float(depth) / maxDim
        )
    }

    func clearVolume() {
        volumeTexture = nil
        meshSurfaceBuffer = nil
        meshSurfaceVertexCount = 0
        requestRedraw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            return
        }
        view.clearColor = backgroundColor

        guard volumeTexture != nil || meshSurfaceBuffer != nil else {
            encoder.endEncoding()
            cmd.present(drawable)
            cmd.commit()
            return
        }

        let aspect = max(0.1, Float(view.drawableSize.width / max(1.0, view.drawableSize.height)))
        let fov = focalLengthToFOV(focalLength)
        let proj = tvPerspectiveFovRH(fovyRadians: tvRadians(fov), aspect: aspect, nearZ: 0.1, farZ: 100.0)
        let rotY = tvRotationMatrix(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let rotX = tvRotationMatrix(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        let rotZ = tvRotationMatrix(angle: roll, axis: SIMD3<Float>(0, 0, 1))
        let volumeModel = tvVolumeTransformMatrix(volumeTransform) * tvScaleMatrix(volumeScale)
        let camPos: SIMD3<Float>
        let viewMat: simd_float4x4
        let model: simd_float4x4

        switch cameraMode {
        case .orbit:
            camPos = SIMD3<Float>(0, 0, distance)
            viewMat = tvTranslationMatrix(SIMD3<Float>(0, 0, -distance))
            model = rotY * rotX * volumeModel
        case .freeCamera:
            let cameraWorld = focusLockEnabled
                ? tvLookAtCameraWorldMatrix(position: cameraPosition, target: focusTarget, roll: roll)
                : tvTranslationMatrix(cameraPosition) * rotY * rotX * rotZ
            let camPos4 = cameraWorld * SIMD4<Float>(0, 0, 0, 1)
            camPos = SIMD3<Float>(camPos4.x, camPos4.y, camPos4.z)
            viewMat = cameraWorld.inverse
            model = volumeModel
        }

        let mvp = proj * viewMat * model
        let invModel = model.inverse

        var uniforms = Uniforms(
            modelViewProjectionMatrix: mvp,
            modelMatrix: model,
            invModelMatrix: invModel,
            cameraPositionWorld: camPos,
            steps: UInt32(max(8, min(steps, 1024))),
            density: density,
            brightness: brightness,
            useAlpha: useAlpha ? 1 : 0,
            useVoxelBlockRendering: useVoxelBlockRendering ? 1 : 0,
            outputStraightAlpha: 0,
            smoothEdges: smoothEdges ? 1 : 0
        )

        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        if let meshSurfaceBuffer, meshSurfaceVertexCount > 0, !useVoxelBlockRendering {
            encoder.setRenderPipelineState(meshSurfacePipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(meshSurfaceBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshSurfaceVertexCount)
        } else if let texture = volumeTexture {
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.back)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(texture, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
        }

        if showReferencePlaneOverlay, referencePlaneOverlayVertices.count >= 6,
           let planeBuffer = device.makeBuffer(
            bytes: referencePlaneOverlayVertices,
            length: referencePlaneOverlayVertices.count * MemoryLayout<SIMD3<Float>>.stride,
            options: .storageModeShared
           ) {
            encoder.setRenderPipelineState(planeOverlayPipeline)
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(planeBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: referencePlaneOverlayVertices.count)
        }
        encoder.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - 左键：视角

    func mouseDown(with event: NSEvent) {
        lastLeftPoint = event.locationInWindow
    }

    func mouseDragged(with event: NSEvent) {
        guard let last = lastLeftPoint else { return }
        let p = event.locationInWindow
        let dx = Float(p.x - last.x)
        let dy = Float(p.y - last.y)

        yaw += dx * 0.01
        pitch += dy * 0.01

        lastLeftPoint = p
        notifyCameraChanged()
        requestRedraw()
    }

    func mouseUp(with event: NSEvent) {
        lastLeftPoint = nil
    }

    // MARK: - 右键：参考面

    func rightMouseDown(with event: NSEvent) {
        lastRightPoint = event.locationInWindow
    }

    func rightMouseDragged(with event: NSEvent) {
        guard let last = lastRightPoint else { return }
        let p = event.locationInWindow
        let dx = Float(p.x - last.x)
        let dy = Float(p.y - last.y)

        let gain: Float = 0.25

        switch planeAxisLock {
        case .x:
            onReferencePlaneDelta?(nil, dy * gain, nil)
        case .y:
            onReferencePlaneDelta?(dx * gain, nil, nil)
        case .t:
            onReferencePlaneDelta?(nil, nil, dx * gain)
        case nil:
            onReferencePlaneDelta?(dx * gain, dy * gain, nil)
        }

        lastRightPoint = p
        requestRedraw()
    }

    func rightMouseUp(with event: NSEvent) {
        lastRightPoint = nil
    }

    // MARK: - 滚轮：缩放

    func scrollWheel(with event: NSEvent) {
        distance *= (1.0 + Float(event.deltaY) * 0.01)
        distance = max(0.8, distance)
        notifyCameraChanged()
        requestRedraw()
    }

    // MARK: - 键盘：Q/W/E 锁轴

    func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return }
        if chars == "q" {
            planeAxisLock = .x
        } else if chars == "w" {
            planeAxisLock = .y
        } else if chars == "e" {
            planeAxisLock = .t
        }
    }

    func keyUp(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return }
        if chars == "q" || chars == "w" || chars == "e" {
            planeAxisLock = nil
        }
    }

    private func notifyCameraChanged() {
        onCameraChanged?(yaw, pitch, roll, distance, cameraPosition.x, cameraPosition.y, cameraPosition.z)
    }
}

// MARK: - 数学工具

private func tvRadians(_ degrees: Float) -> Float {
    degrees * .pi / 180.0
}

private func focalLengthToFOV(_ focalLength: Float) -> Float {
    let sensorHeight: Float = 24
    let clamped = max(1, focalLength)
    return 2 * atan(sensorHeight / (2 * clamped)) * 180 / .pi
}

private func tvPerspectiveFovRH(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
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

private func tvTranslationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(t.x, t.y, t.z, 1)
    )
}

private func tvScaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(s.x, 0,   0,   0),
        SIMD4<Float>(0,   s.y, 0,   0),
        SIMD4<Float>(0,   0,   s.z, 0),
        SIMD4<Float>(0,   0,   0,   1)
    )
}

private func tvVolumeTransformMatrix(_ transform: VolumeTransformState) -> simd_float4x4 {
    let translation = tvTranslationMatrix(
        SIMD3<Float>(transform.positionX, transform.positionY, transform.positionZ)
    )
    let rotX = tvRotationMatrix(angle: transform.rotationX, axis: SIMD3<Float>(1, 0, 0))
    let rotY = tvRotationMatrix(angle: transform.rotationY, axis: SIMD3<Float>(0, 1, 0))
    let rotZ = tvRotationMatrix(angle: transform.rotationZ, axis: SIMD3<Float>(0, 0, 1))
    let scale = tvScaleMatrix(SIMD3<Float>(
        max(0.01, transform.scaleX),
        max(0.01, transform.scaleY),
        max(0.01, transform.scaleZ)
    ))
    return translation * rotZ * rotY * rotX * scale
}

private func tvRotationMatrix(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
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

private func tvLookAtCameraWorldMatrix(position: SIMD3<Float>, target: SIMD3<Float>, roll: Float) -> simd_float4x4 {
    let toTarget = target - position
    let fallbackForward = SIMD3<Float>(0, 0, -1)
    let forward = simd_length_squared(toTarget) > 0.000001 ? simd_normalize(toTarget) : fallbackForward
    let worldUp = abs(simd_dot(forward, SIMD3<Float>(0, 1, 0))) > 0.98
        ? SIMD3<Float>(1, 0, 0)
        : SIMD3<Float>(0, 1, 0)

    var right = simd_normalize(simd_cross(forward, worldUp))
    var up = simd_normalize(simd_cross(right, forward))

    if abs(roll) > 0.000001 {
        let rollMat = tvRotationMatrix(angle: roll, axis: forward)
        right = tvTransformVector(rollMat, right)
        up = tvTransformVector(rollMat, up)
    }

    return simd_float4x4(
        SIMD4<Float>(right.x, right.y, right.z, 0),
        SIMD4<Float>(up.x, up.y, up.z, 0),
        SIMD4<Float>(-forward.x, -forward.y, -forward.z, 0),
        SIMD4<Float>(position.x, position.y, position.z, 1)
    )
}

private func tvTransformVector(_ matrix: simd_float4x4, _ vector: SIMD3<Float>) -> SIMD3<Float> {
    let v = matrix * SIMD4<Float>(vector.x, vector.y, vector.z, 0)
    return SIMD3<Float>(v.x, v.y, v.z)
}
