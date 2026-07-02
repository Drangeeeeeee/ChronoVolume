import Foundation
import AVFoundation
import CoreVideo
import Metal
import simd

struct CameraVideoExportRequest {
    let url: URL
    let width: Int
    let height: Int
    let fps: Double
    let frameCount: Int
    let volume: LoadedVolume
    let volumeScale: SIMD3<Float>
    let volumeTransform: VolumeTransformState
    let keyframes: [CameraKeyframe]
    let fallbackCamera: CameraRigState
    let functionDriver: CameraFunctionDriverState
    let useAlphaVolume: Bool
    let useVoxelBlockRendering: Bool
    let smoothEdges: Bool
    let preserveAlpha: Bool
    let backgroundMode: CameraExportBackgroundMode
    let backgroundColor: VolumeBackgroundColor
    let steps: Int
    let density: Float
    let brightness: Float
    let bitDepth: Int
    let colorProfile: VideoColorProfile
}

enum CameraVideoExporter {
    static func export(
        request: CameraVideoExportRequest,
        progress: @escaping ExportProgressHandler
    ) throws {
        let renderer = try OffscreenCameraRenderer(
            volume: request.volume,
            volumeScale: request.volumeScale,
            volumeTransform: request.volumeTransform,
            width: request.width,
            height: request.height,
            preserveAlpha: request.preserveAlpha,
            backgroundMode: request.backgroundMode,
            backgroundColor: request.backgroundColor
        )

        let (writer, input, adaptor) = try makeWriter(
            outputURL: request.url,
            width: request.width,
            height: request.height,
            preserveAlpha: request.preserveAlpha,
            bitDepth: request.bitDepth,
            colorProfile: request.colorProfile
        )
        let frameDuration = CMTime(seconds: 1.0 / max(0.05, request.fps), preferredTimescale: 600)
        let frameCount = max(1, request.frameCount)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }

            guard let pixelBuffer = makePixelBuffer(from: adaptor) else {
                throw VideoExportError.createPixelBufferFailed
            }

            let camera = interpolateCamera(
                at: frame,
                frameCount: frameCount,
                keyframes: request.keyframes,
                fallback: request.fallbackCamera,
                functionDriver: request.functionDriver
            )

            try renderer.render(
                to: pixelBuffer,
                camera: camera,
                useAlphaVolume: request.useAlphaVolume,
                useVoxelBlockRendering: request.useVoxelBlockRendering,
                smoothEdges: request.smoothEdges,
                steps: request.steps,
                density: request.density,
                brightness: request.brightness
            )

            let time = CMTimeMultiply(frameDuration, multiplier: Int32(frame))
            if !adaptor.append(pixelBuffer, withPresentationTime: time) {
                throw VideoExportError.appendFailed(writer.error?.localizedDescription ?? "append 失败")
            }

            if frame % 4 == 0 || frame == frameCount - 1 {
                progress(Double(frame + 1) / Double(frameCount), "摄像机画面离屏导出")
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

    private static func makeWriter(
        outputURL: URL,
        width: Int,
        height: Int,
        preserveAlpha: Bool,
        bitDepth: Int,
        colorProfile: VideoColorProfile
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let codecValue = (preserveAlpha || bitDepth > 8 || colorProfile.isHDR)
            ? AVVideoCodecType.proRes4444.rawValue
            : AVVideoCodecType.h264.rawValue
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: codecValue,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        outputSettings[AVVideoColorPropertiesKey] = colorProfile.avVideoColorProperties
        if codecValue == AVVideoCodecType.h264.rawValue {
            outputSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * max(10, bitDepth)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
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

    private static func interpolateCamera(
        at frame: Int,
        frameCount: Int,
        keyframes: [CameraKeyframe],
        fallback: CameraRigState,
        functionDriver: CameraFunctionDriverState
    ) -> CameraRigState {
        let base = baseInterpolateCamera(at: frame, keyframes: keyframes, fallback: fallback)
        guard functionDriver.isEnabled, functionDriver.hasAnyExpression else { return base }

        let maxFrame = max(1, frameCount - 1)
        let x = Double(max(0, min(maxFrame, frame))) / Double(maxFrame)
        return CameraRigState(
            yaw: applyExpression(functionDriver.yawExpression, x: x, y: base.yaw),
            pitch: applyExpression(functionDriver.pitchExpression, x: x, y: base.pitch),
            roll: applyExpression(functionDriver.rollExpression, x: x, y: base.roll),
            distance: base.distance,
            positionX: applyExpression(functionDriver.positionXExpression, x: x, y: base.positionX),
            positionY: applyExpression(functionDriver.positionYExpression, x: x, y: base.positionY),
            positionZ: applyExpression(functionDriver.positionZExpression, x: x, y: base.positionZ),
            focusLockEnabled: base.focusLockEnabled,
            focusTargetX: base.focusTargetX,
            focusTargetY: base.focusTargetY,
            focusTargetZ: base.focusTargetZ,
            focalLength: applyExpression(functionDriver.focalLengthExpression, x: x, y: base.focalLength, lowerLimit: 1),
            aperture: applyExpression(functionDriver.apertureExpression, x: x, y: base.aperture, lowerLimit: 0.1)
        )
    }

    private static func baseInterpolateCamera(
        at frame: Int,
        keyframes: [CameraKeyframe],
        fallback: CameraRigState
    ) -> CameraRigState {
        let sorted = keyframes.sorted { $0.frame < $1.frame }
        guard let first = sorted.first else { return fallback }
        guard sorted.count > 1 else { return first.camera }
        if frame <= first.frame { return first.camera }
        if let last = sorted.last, frame >= last.frame { return last.camera }
        guard let upperIndex = sorted.firstIndex(where: { $0.frame >= frame }), upperIndex > 0 else {
            return first.camera
        }

        let lower = sorted[upperIndex - 1]
        let upper = sorted[upperIndex]
        let span = max(1, upper.frame - lower.frame)
        let t = Float(frame - lower.frame) / Float(span)
        return CameraRigState(
            yaw: lerp(lower.camera.yaw, upper.camera.yaw, t),
            pitch: lerp(lower.camera.pitch, upper.camera.pitch, t),
            roll: lerp(lower.camera.roll, upper.camera.roll, t),
            distance: lerp(lower.camera.distance, upper.camera.distance, t),
            positionX: lerp(lower.camera.positionX, upper.camera.positionX, t),
            positionY: lerp(lower.camera.positionY, upper.camera.positionY, t),
            positionZ: lerp(lower.camera.positionZ, upper.camera.positionZ, t),
            focusLockEnabled: t < 0.5 ? lower.camera.focusLockEnabled : upper.camera.focusLockEnabled,
            focusTargetX: lerp(lower.camera.focusTargetX, upper.camera.focusTargetX, t),
            focusTargetY: lerp(lower.camera.focusTargetY, upper.camera.focusTargetY, t),
            focusTargetZ: lerp(lower.camera.focusTargetZ, upper.camera.focusTargetZ, t),
            focalLength: lerp(lower.camera.focalLength, upper.camera.focalLength, t),
            aperture: lerp(lower.camera.aperture, upper.camera.aperture, t)
        )
    }

    private static func applyExpression(_ expression: String, x: Double, y: Float, lowerLimit: Float? = nil) -> Float {
        guard let value = CameraExpressionEvaluator.evaluate(expression, x: x, y: Double(y)),
              value.isFinite else {
            return y
        }
        let resolved = Float(value)
        if let lowerLimit {
            return max(lowerLimit, resolved)
        }
        return resolved
    }

    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * max(0, min(1, t))
    }
}

private struct CameraBackgroundUniforms {
    var color: SIMD3<Float>
    var tileSize: Float
}

private final class OffscreenCameraRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let alphaPipeline: MTLRenderPipelineState
    private let opaquePipeline: MTLRenderPipelineState
    private let checkerboardPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let textureCache: CVMetalTextureCache
    private let vertexBuffer: MTLBuffer
    private let uniformBuffer: MTLBuffer
    private let samplerState: MTLSamplerState
    private let volumeTexture: MTLTexture
    private let volumeScale: SIMD3<Float>
    private let volumeTransform: VolumeTransformState
    private let width: Int
    private let height: Int
    private let preserveAlpha: Bool
    private let backgroundMode: CameraExportBackgroundMode
    private let backgroundColor: VolumeBackgroundColor

    init(
        volume: LoadedVolume,
        volumeScale: SIMD3<Float>,
        volumeTransform: VolumeTransformState,
        width: Int,
        height: Int,
        preserveAlpha: Bool,
        backgroundMode: CameraExportBackgroundMode,
        backgroundColor: VolumeBackgroundColor
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw VideoExportError.metalUnavailable("无法创建摄像机导出 Metal 设备")
        }
        self.device = device
        self.queue = queue
        self.volumeScale = volumeScale
        self.volumeTransform = volumeTransform
        self.width = width
        self.height = height
        self.preserveAlpha = preserveAlpha
        self.backgroundMode = backgroundMode
        self.backgroundColor = backgroundColor

        let library = try device.makeDefaultLibrary(bundle: .main)
        guard let vertexFunc = library.makeFunction(name: "volumeVertex"),
              let fragmentFunc = library.makeFunction(name: "volumeFragment") else {
            throw VideoExportError.metalUnavailable("找不到摄像机导出 volume shader")
        }

        self.alphaPipeline = try Self.makePipeline(
            device: device,
            vertexFunc: vertexFunc,
            fragmentFunc: fragmentFunc,
            blending: false
        )
        self.opaquePipeline = try Self.makePipeline(
            device: device,
            vertexFunc: vertexFunc,
            fragmentFunc: fragmentFunc,
            blending: true
        )
        guard let backgroundVertexFunc = library.makeFunction(name: "cameraBackgroundVertex"),
              let checkerboardFragmentFunc = library.makeFunction(name: "cameraCheckerboardFragment") else {
            throw VideoExportError.metalUnavailable("找不到摄像机背景 shader")
        }
        self.checkerboardPipeline = try Self.makeBackgroundPipeline(
            device: device,
            vertexFunc: backgroundVertexFunc,
            fragmentFunc: checkerboardFragmentFunc
        )

        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.isDepthWriteEnabled = true
        depthDesc.depthCompareFunction = .lessEqual
        guard let depthState = device.makeDepthStencilState(descriptor: depthDesc) else {
            throw VideoExportError.metalUnavailable("无法创建摄像机导出 depth state")
        }
        self.depthState = depthState

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw VideoExportError.metalUnavailable("无法创建摄像机导出 texture cache")
        }
        self.textureCache = cache

        let vertices = Self.cubeVertices
        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<SIMD3<Float>>.stride,
            options: .storageModeShared
        ) else {
            throw VideoExportError.metalUnavailable("无法创建摄像机导出 vertex buffer")
        }
        self.vertexBuffer = vertexBuffer

        guard let uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared) else {
            throw VideoExportError.metalUnavailable("无法创建摄像机导出 uniform buffer")
        }
        self.uniformBuffer = uniformBuffer

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        samplerDesc.rAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw VideoExportError.metalUnavailable("无法创建摄像机导出 sampler")
        }
        self.samplerState = sampler

        let volumeTexture = try VolumeTextureUploadGuard.makeRGBA8Texture(
            device: device,
            volume: volume,
            context: "摄像机导出体纹理"
        )
        self.volumeTexture = volumeTexture
    }

    func render(
        to pixelBuffer: CVPixelBuffer,
        camera: CameraRigState,
        useAlphaVolume: Bool,
        useVoxelBlockRendering: Bool,
        smoothEdges: Bool,
        steps: Int,
        density: Float,
        brightness: Float
    ) throws {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let targetTexture = CVMetalTextureGetTexture(cvTexture) else {
            throw VideoExportError.metalUnavailable("无法创建摄像机导出目标纹理")
        }

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDesc) else {
            throw VideoExportError.metalUnavailable("无法创建摄像机导出深度纹理")
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targetTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        if preserveAlpha {
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        } else {
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: backgroundColor.red,
                green: backgroundColor.green,
                blue: backgroundColor.blue,
                alpha: 1
            )
        }
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw VideoExportError.metalUnavailable("无法创建摄像机导出 command encoder")
        }

        if !preserveAlpha && backgroundMode == .checkerboard {
            var backgroundUniforms = CameraBackgroundUniforms(
                color: SIMD3<Float>(
                    Float(backgroundColor.red),
                    Float(backgroundColor.green),
                    Float(backgroundColor.blue)
                ),
                tileSize: 18
            )
            encoder.setRenderPipelineState(checkerboardPipeline)
            encoder.setDepthStencilState(nil)
            encoder.setFragmentBytes(
                &backgroundUniforms,
                length: MemoryLayout<CameraBackgroundUniforms>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        let aspect = Float(width) / Float(max(1, height))
        let fov = cameraFocalLengthToFOV(camera.focalLength)
        let proj = cameraPerspectiveFovRH(fovyRadians: cameraRadians(fov), aspect: aspect, nearZ: 0.1, farZ: 100)
        let rotY = cameraRotationMatrix(angle: camera.yaw, axis: SIMD3<Float>(0, 1, 0))
        let rotX = cameraRotationMatrix(angle: camera.pitch, axis: SIMD3<Float>(1, 0, 0))
        let rotZ = cameraRotationMatrix(angle: camera.roll, axis: SIMD3<Float>(0, 0, 1))
        let cameraPosition = SIMD3<Float>(camera.positionX, camera.positionY, camera.positionZ)
        let cameraWorld = camera.focusLockEnabled
            ? cameraLookAtCameraWorldMatrix(
                position: cameraPosition,
                target: SIMD3<Float>(camera.focusTargetX, camera.focusTargetY, camera.focusTargetZ),
                roll: camera.roll
            )
            : cameraTranslationMatrix(cameraPosition) * rotY * rotX * rotZ
        let camPos4 = cameraWorld * SIMD4<Float>(0, 0, 0, 1)
        let camPos = SIMD3<Float>(camPos4.x, camPos4.y, camPos4.z)
        let viewMat = cameraWorld.inverse
        let model = cameraVolumeTransformMatrix(volumeTransform) * cameraScaleMatrix(volumeScale)
        let mvp = proj * viewMat * model

        var uniforms = Uniforms(
            modelViewProjectionMatrix: mvp,
            modelMatrix: model,
            invModelMatrix: model.inverse,
            cameraPositionWorld: camPos,
            steps: UInt32(max(8, min(steps, 1024))),
            density: density,
            brightness: brightness,
            useAlpha: useAlphaVolume ? 1 : 0,
            useVoxelBlockRendering: useVoxelBlockRendering ? 1 : 0,
            outputStraightAlpha: preserveAlpha ? 1 : 0,
            smoothEdges: smoothEdges ? 1 : 0
        )
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        encoder.setRenderPipelineState(preserveAlpha ? alphaPipeline : opaquePipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(volumeTexture, index: 0)
        encoder.setFragmentTexture(volumeTexture, index: 1)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw VideoExportError.metalUnavailable("摄像机导出 GPU 渲染失败：\(error.localizedDescription)")
        }
    }

    private static func makePipeline(
        device: MTLDevice,
        vertexFunc: MTLFunction,
        fragmentFunc: MTLFunction,
        blending: Bool
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.depthAttachmentPixelFormat = .depth32Float
        desc.inputPrimitiveTopology = .triangle
        if blending {
            let color = desc.colorAttachments[0]!
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .sourceAlpha
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private static func makeBackgroundPipeline(
        device: MTLDevice,
        vertexFunc: MTLFunction,
        fragmentFunc: MTLFunction
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private static let cubeVertices: [SIMD3<Float>] = [
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
}

private func cameraRadians(_ degrees: Float) -> Float {
    degrees * .pi / 180
}

private func cameraFocalLengthToFOV(_ focalLength: Float) -> Float {
    let sensorHeight: Float = 24
    let clamped = max(1, focalLength)
    return 2 * atan(sensorHeight / (2 * clamped)) * 180 / .pi
}

private func cameraPerspectiveFovRH(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
    let yScale = 1 / tan(fovyRadians * 0.5)
    let xScale = yScale / aspect
    let zRange = farZ - nearZ
    let zScale = -(farZ + nearZ) / zRange
    let wzScale = -2 * farZ * nearZ / zRange
    return simd_float4x4(
        SIMD4<Float>(xScale, 0, 0, 0),
        SIMD4<Float>(0, yScale, 0, 0),
        SIMD4<Float>(0, 0, zScale, -1),
        SIMD4<Float>(0, 0, wzScale, 0)
    )
}

private func cameraTranslationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(t.x, t.y, t.z, 1)
    )
}

private func cameraScaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(s.x, 0, 0, 0),
        SIMD4<Float>(0, s.y, 0, 0),
        SIMD4<Float>(0, 0, s.z, 0),
        SIMD4<Float>(0, 0, 0, 1)
    )
}

private func cameraVolumeTransformMatrix(_ transform: VolumeTransformState) -> simd_float4x4 {
    let translation = cameraTranslationMatrix(
        SIMD3<Float>(transform.positionX, transform.positionY, transform.positionZ)
    )
    let rotX = cameraRotationMatrix(angle: transform.rotationX, axis: SIMD3<Float>(1, 0, 0))
    let rotY = cameraRotationMatrix(angle: transform.rotationY, axis: SIMD3<Float>(0, 1, 0))
    let rotZ = cameraRotationMatrix(angle: transform.rotationZ, axis: SIMD3<Float>(0, 0, 1))
    let scale = SIMD3<Float>(
        max(0.01, transform.scaleX),
        max(0.01, transform.scaleY),
        max(0.01, transform.scaleZ)
    )
    return translation * rotZ * rotY * rotX * cameraScaleMatrix(scale)
}

private func cameraRotationMatrix(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let a = simd_normalize(axis)
    let x = a.x
    let y = a.y
    let z = a.z
    let c = cos(angle)
    let s = sin(angle)
    let mc = 1 - c
    return simd_float4x4(
        SIMD4<Float>(c + x*x*mc, x*y*mc + z*s, x*z*mc - y*s, 0),
        SIMD4<Float>(x*y*mc - z*s, c + y*y*mc, y*z*mc + x*s, 0),
        SIMD4<Float>(x*z*mc + y*s, y*z*mc - x*s, c + z*z*mc, 0),
        SIMD4<Float>(0, 0, 0, 1)
    )
}

private func cameraLookAtCameraWorldMatrix(position: SIMD3<Float>, target: SIMD3<Float>, roll: Float) -> simd_float4x4 {
    let toTarget = target - position
    let fallbackForward = SIMD3<Float>(0, 0, -1)
    let forward = simd_length_squared(toTarget) > 0.000001 ? simd_normalize(toTarget) : fallbackForward
    let worldUp = abs(simd_dot(forward, SIMD3<Float>(0, 1, 0))) > 0.98
        ? SIMD3<Float>(1, 0, 0)
        : SIMD3<Float>(0, 1, 0)

    var right = simd_normalize(simd_cross(forward, worldUp))
    var up = simd_normalize(simd_cross(right, forward))

    if abs(roll) > 0.000001 {
        let rollMat = cameraRotationMatrix(angle: roll, axis: forward)
        right = cameraTransformVector(rollMat, right)
        up = cameraTransformVector(rollMat, up)
    }

    return simd_float4x4(
        SIMD4<Float>(right.x, right.y, right.z, 0),
        SIMD4<Float>(up.x, up.y, up.z, 0),
        SIMD4<Float>(-forward.x, -forward.y, -forward.z, 0),
        SIMD4<Float>(position.x, position.y, position.z, 1)
    )
}

private func cameraTransformVector(_ matrix: simd_float4x4, _ vector: SIMD3<Float>) -> SIMD3<Float> {
    let v = matrix * SIMD4<Float>(vector.x, vector.y, vector.z, 0)
    return SIMD3<Float>(v.x, v.y, v.z)
}
