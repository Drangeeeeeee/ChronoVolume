import Foundation
import AVFoundation
import CoreVideo
import Metal
import simd

typealias ExportProgressHandler = (Double, String?) -> Void

struct VideoExportRequest {
    let url: URL
    let width: Int
    let height: Int
    let fps: Double
    let frameCount: Int
    let mode: SliceMode
    let axis: PlaybackAxis
    let showCheckerboard: Bool
    let useAlpha: Bool
    let preserveAlpha: Bool
    let padToEven: Bool
    let highPrecision: Bool
    let sourceFrameCount: Int
    let playbackRate: Double
    let sourceURL: URL?
    let referencePlane: ReferencePlaneState

    /// nil 表示导完整轴；有值表示只导该段输出帧
    let outputStartFrame: Int?
    let outputEndFrame: Int?
    let highPrecisionBatchByteBudget: Int?
    let bitDepth: Int
    let colorProfile: VideoColorProfile
    let mesh: LoadedMesh?
    let meshSupersampleScale: Int
    let volumeTextureCacheID: UUID?
    let usesModifiedVolumeTexture: Bool

    init(
        url: URL,
        width: Int,
        height: Int,
        fps: Double,
        frameCount: Int,
        mode: SliceMode,
        axis: PlaybackAxis,
        showCheckerboard: Bool,
        useAlpha: Bool,
        preserveAlpha: Bool,
        padToEven: Bool,
        highPrecision: Bool,
        sourceFrameCount: Int,
        playbackRate: Double,
        sourceURL: URL?,
        referencePlane: ReferencePlaneState,
        outputStartFrame: Int? = nil,
        outputEndFrame: Int? = nil,
        highPrecisionBatchByteBudget: Int? = nil,
        bitDepth: Int = 8,
        colorProfile: VideoColorProfile = .rec709,
        mesh: LoadedMesh? = nil,
        meshSupersampleScale: Int = 1,
        volumeTextureCacheID: UUID? = nil,
        usesModifiedVolumeTexture: Bool = false
    ) {
        self.url = url
        self.width = width
        self.height = height
        self.fps = fps
        self.frameCount = frameCount
        self.mode = mode
        self.axis = axis
        self.showCheckerboard = showCheckerboard
        self.useAlpha = useAlpha
        self.preserveAlpha = preserveAlpha
        self.padToEven = padToEven
        self.highPrecision = highPrecision
        self.sourceFrameCount = sourceFrameCount
        self.playbackRate = playbackRate
        self.sourceURL = sourceURL
        self.referencePlane = referencePlane
        self.outputStartFrame = outputStartFrame
        self.outputEndFrame = outputEndFrame
        self.highPrecisionBatchByteBudget = highPrecisionBatchByteBudget
        self.bitDepth = max(8, bitDepth)
        self.colorProfile = colorProfile
        self.mesh = mesh
        self.meshSupersampleScale = max(1, min(3, meshSupersampleScale))
        self.volumeTextureCacheID = volumeTextureCacheID
        self.usesModifiedVolumeTexture = usesModifiedVolumeTexture
    }
}

enum VideoExportError: LocalizedError {
    case createWriterFailed(String)
    case createReaderFailed(String)
    case createInputFailed
    case createPixelBufferPoolFailed
    case createPixelBufferFailed
    case appendFailed(String)
    case finishFailed(String)
    case metalUnavailable(String)
    case textureBottleneck(String)

    var errorDescription: String? {
        switch self {
        case .createWriterFailed(let message):
            return "无法创建 AVAssetWriter：\(message)"
        case .createReaderFailed(let message):
            return "无法创建 AVAssetReader：\(message)"
        case .createInputFailed:
            return "无法创建导出输入"
        case .createPixelBufferPoolFailed:
            return "无法创建像素缓冲池"
        case .createPixelBufferFailed:
            return "无法创建像素缓冲区"
        case .appendFailed(let message):
            return "写入视频帧失败：\(message)"
        case .finishFailed(let message):
            return "结束写入失败：\(message)"
        case .metalUnavailable(let message):
            return "GPU 导出不可用：\(message)"
        case .textureBottleneck(let message):
            return message
        }
    }

    var isTextureBottleneck: Bool {
        if case .textureBottleneck = self {
            return true
        }
        return false
    }
}

// MARK: - GPU uniforms (must match *.metal files)

private struct AxisSliceUniforms {
    var outWidth: UInt32
    var outHeight: UInt32
    var useAlpha: UInt32
    var showCheckerboard: UInt32
    var fastPreview: UInt32
    var axisType: UInt32
    var fixedIndex: UInt32
    var _pad0: UInt32 = 0

    var volumeWidth: UInt32
    var volumeHeight: UInt32
    var volumeDepth: UInt32
    var _pad1: UInt32 = 0

    var contentX: Float
    var contentY: Float
    var contentW: Float
    var contentH: Float
}

private struct PlaneSliceUniforms {
    var outWidth: UInt32
    var outHeight: UInt32
    var useAlpha: UInt32
    var showCheckerboard: UInt32
    var fastPreview: UInt32
    var volumeWidth: UInt32
    var volumeHeight: UInt32
    var volumeDepth: UInt32

    var contentX: Float
    var contentY: Float
    var contentW: Float
    var contentH: Float

    var u: SIMD3<Float>
    var _pad1: Float = 0
    var v: SIMD3<Float>
    var _pad2: Float = 0
    var n: SIMD3<Float>
    var d: Float
    var uMin: Float
    var uMax: Float
    var vMin: Float
    var vMax: Float
}

private struct AxisExportCache {
    let outWidth: Int
    let outHeight: Int
    let xMap: [Int]
    let yMap: [Int]
    let tMapX: [Int]
    let tMapY: [Int]
}

private struct PlaneExportCache {
    let outWidth: Int
    let outHeight: Int
    let baseCentered: [SIMD3<Float>]
    let n: SIMD3<Float>
    let dBase: Float
    let dStep: Float
}

private struct MeshExportTriangle {
    let a: SIMD3<Float>
    let b: SIMD3<Float>
    let c: SIMD3<Float>
    let normal: SIMD3<Float>
}

private struct MeshSliceSegment {
    let u0: Float
    let v0: Float
    let u1: Float
    let v1: Float
    let shade: Float
}

private struct MeshSliceCache {
    let outWidth: Int
    let outHeight: Int
    let triangles: [MeshExportTriangle]
    let trianglePlaneRanges: [(min: Float, max: Float)]
    let u: SIMD3<Float>
    let v: SIMD3<Float>
    let n: SIMD3<Float>
    let uMin: Float
    let uMax: Float
    let vMin: Float
    let vMax: Float
    let dBase: Float
    let dStep: Float
}

private struct MeshSliceGPUUniforms {
    var triangleCount: UInt32
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
    var planeN: SIMD3<Float>
    var d: Float
    var planeU: SIMD3<Float>
    var _padFloat0: Float = 0
    var planeV: SIMD3<Float>
    var _padFloat1: Float = 0
    var lightDirection: SIMD3<Float>
    var epsilon: Float
}

private struct MeshSliceGPUOutput {
    var u0: Float
    var v0: Float
    var u1: Float
    var v1: Float
    var shade: Float
    var active: UInt32
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
}

private struct RawPlaneExportCache {
    let outWidth: Int
    let outHeight: Int
    let sliceCount: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceDepth: Int
    let frameBytes: Int
    let baseCentered: [SIMD3<Float>]
    let u: SIMD3<Float>
    let v: SIMD3<Float>
    let n: SIMD3<Float>
    let uMin: Float
    let uMax: Float
    let vMin: Float
    let vMax: Float
    let dBase: Float
    let dStep: Float
}


private struct HighPrecisionAssembleUniforms {
    var batchStart: UInt32
    var batchCount: UInt32
    var frameIndex: UInt32
    var sourceWidth: UInt32
    var sourceHeight: UInt32
    var useAlpha: UInt32
    var preserveAlpha: UInt32
    var checkerboard: UInt32
}

private struct HighPrecisionPlaneRawUniforms {
    var contentWidth: UInt32
    var contentHeight: UInt32
    var sourceWidth: UInt32
    var sourceHeight: UInt32
    var sourceDepth: UInt32
    var rawDepth: UInt32
    var rawFrameOffset: UInt32
    var frameBytes: UInt32
    var frameIndex: UInt32
    var sliceCount: UInt32
    var useAlpha: UInt32
    var preserveAlpha: UInt32
    var checkerboard: UInt32
    var pad0: UInt32 = 0
    var pad1a: UInt32 = 0
    var pad1b: UInt32 = 0
    var planeU: SIMD3<Float>
    var uMin: Float
    var planeV: SIMD3<Float>
    var vMin: Float
    var planeN: SIMD3<Float>
    var dBase: Float
    var uMax: Float
    var vMax: Float
    var dStep: Float
    var pad1: Float = 0
}

private final class HighPrecisionXYGPUAssembler {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let xPipeline: MTLComputePipelineState
    private let yPipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw VideoExportError.metalUnavailable("无法创建设备或命令队列")
        }
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            throw VideoExportError.metalUnavailable("无法加载默认 Metal Library：\(error.localizedDescription)")
        }

        guard let xFn = library.makeFunction(name: "highPrecisionAssembleXKernel"),
              let yFn = library.makeFunction(name: "highPrecisionAssembleYKernel") else {
            throw VideoExportError.metalUnavailable("找不到高精度导出所需的 Metal kernel")
        }

        do {
            self.xPipeline = try device.makeComputePipelineState(function: xFn)
            self.yPipeline = try device.makeComputePipelineState(function: yFn)
        } catch {
            throw VideoExportError.metalUnavailable("无法创建高精度导出 compute pipeline：\(error.localizedDescription)")
        }

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw VideoExportError.metalUnavailable("无法创建 CVMetalTextureCache")
        }
        self.textureCache = cache
    }

    func makeBatchTexture(width: Int, height: Int, slices: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .bgra8Unorm
        desc.width = width
        desc.height = height
        desc.arrayLength = max(1, slices)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared

        guard let tex = device.makeTexture(descriptor: desc) else {
            throw VideoExportError.metalUnavailable("无法创建高精度批次纹理")
        }
        return tex
    }

    struct SourceFrameTexture {
        let texture: MTLTexture
        let backing: CVMetalTexture?
    }

    func makeSourceTexture(from pixelBuffer: CVPixelBuffer) throws -> SourceFrameTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

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
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw VideoExportError.metalUnavailable("无法从像素缓冲创建高精度源纹理")
        }

        return SourceFrameTexture(texture: texture, backing: cvTexture)
    }

    func makeSourceTexture(fromBGRABytes bytes: UnsafeRawPointer, width: Int, height: Int) throws -> SourceFrameTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw VideoExportError.metalUnavailable("无法创建高精度源纹理（BGRA）")
        }

        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return SourceFrameTexture(texture: texture, backing: nil)
    }

    func makeReusableSourceTexturePool(width: Int, height: Int, capacity: Int) throws -> [MTLTexture] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        var textures: [MTLTexture] = []
        textures.reserveCapacity(capacity)

        for _ in 0..<capacity {
            guard let texture = device.makeTexture(descriptor: desc) else {
                throw VideoExportError.metalUnavailable("无法创建可复用高精度源纹理池")
            }
            textures.append(texture)
        }
        return textures
    }

    func uploadBGRABytes(_ bytes: UnsafeRawPointer, to texture: MTLTexture, width: Int, height: Int) {
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
    }

    struct DestinationPixelBufferTexture {
        let backing: CVMetalTexture
        let texture: MTLTexture
    }

    func makeDestinationPixelBufferTexture(_ pixelBuffer: CVPixelBuffer) throws -> DestinationPixelBufferTexture {
        let dstWidth = CVPixelBufferGetWidth(pixelBuffer)
        let dstHeight = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            dstWidth,
            dstHeight,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess,
              let cvTexture,
              let dstTexture = CVMetalTextureGetTexture(cvTexture) else {
            throw VideoExportError.metalUnavailable("无法为像素缓冲创建目标纹理")
        }

        return DestinationPixelBufferTexture(backing: cvTexture, texture: dstTexture)
    }

    func copyBatchSlicesToPixelBuffers(
        batchTexture: MTLTexture,
        sliceCount: Int,
        destinations: [DestinationPixelBufferTexture],
        contentWidth: Int,
        contentHeight: Int
    ) throws {
        guard sliceCount <= destinations.count else {
            throw VideoExportError.metalUnavailable("高精度导出目标 PixelBuffer 数量不足")
        }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw VideoExportError.metalUnavailable("无法创建高精度导出 blit encoder")
        }

        let srcSize = MTLSize(width: contentWidth, height: contentHeight, depth: 1)

        for i in 0..<sliceCount {
            blit.copy(
                from: batchTexture,
                sourceSlice: i,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: srcSize,
                to: destinations[i].texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
        }

        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw VideoExportError.metalUnavailable("高精度导出 GPU→PixelBuffer 批量拷贝失败：\(error.localizedDescription)")
        }
    }

    func copySingleSliceToPixelBuffer(
        batchTexture: MTLTexture,
        slice: Int,
        destination: DestinationPixelBufferTexture,
        contentWidth: Int,
        contentHeight: Int
    ) throws {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw VideoExportError.metalUnavailable("无法创建高精度导出单帧 blit encoder")
        }

        blit.copy(
            from: batchTexture,
            sourceSlice: slice,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: contentWidth, height: contentHeight, depth: 1),
            to: destination.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )

        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw VideoExportError.metalUnavailable("高精度导出 GPU→PixelBuffer 单帧拷贝失败：\(error.localizedDescription)")
        }
    }

    func encodeX(
        sourceTexture: MTLTexture,
        outputTexture: MTLTexture,
        batchStart: Int,
        batchCount: Int,
        frameIndex: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        useAlpha: Bool,
        preserveAlpha: Bool,
        checkerboard: Bool
    ) throws {
        try dispatch(
            pipeline: xPipeline,
            sourceTexture: sourceTexture,
            outputTexture: outputTexture,
            uniforms: HighPrecisionAssembleUniforms(
                batchStart: UInt32(batchStart),
                batchCount: UInt32(batchCount),
                frameIndex: UInt32(frameIndex),
                sourceWidth: UInt32(sourceWidth),
                sourceHeight: UInt32(sourceHeight),
                useAlpha: useAlpha ? 1 : 0,
                preserveAlpha: preserveAlpha ? 1 : 0,
                checkerboard: checkerboard ? 1 : 0
            ),
            gridWidth: batchCount,
            gridHeight: sourceHeight
        )
    }

    func encodeY(
        sourceTexture: MTLTexture,
        outputTexture: MTLTexture,
        batchStart: Int,
        batchCount: Int,
        frameIndex: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        useAlpha: Bool,
        preserveAlpha: Bool,
        checkerboard: Bool
    ) throws {
        try dispatch(
            pipeline: yPipeline,
            sourceTexture: sourceTexture,
            outputTexture: outputTexture,
            uniforms: HighPrecisionAssembleUniforms(
                batchStart: UInt32(batchStart),
                batchCount: UInt32(batchCount),
                frameIndex: UInt32(frameIndex),
                sourceWidth: UInt32(sourceWidth),
                sourceHeight: UInt32(sourceHeight),
                useAlpha: useAlpha ? 1 : 0,
                preserveAlpha: preserveAlpha ? 1 : 0,
                checkerboard: checkerboard ? 1 : 0
            ),
            gridWidth: batchCount,
            gridHeight: sourceWidth
        )
    }

    func encodeXChunk(
        sourceFrames: [SourceFrameTexture],
        outputTexture: MTLTexture,
        batchStart: Int,
        frameStartIndex: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        useAlpha: Bool,
        preserveAlpha: Bool,
        checkerboard: Bool
    ) throws {
        try dispatchChunk(
            pipeline: xPipeline,
            sourceFrames: sourceFrames,
            outputTexture: outputTexture,
            batchStart: batchStart,
            frameStartIndex: frameStartIndex,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            useAlpha: useAlpha,
            preserveAlpha: preserveAlpha,
            checkerboard: checkerboard,
            gridWidth: outputTexture.arrayLength,
            gridHeight: sourceHeight
        )
    }

    func encodeYChunk(
        sourceFrames: [SourceFrameTexture],
        outputTexture: MTLTexture,
        batchStart: Int,
        frameStartIndex: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        useAlpha: Bool,
        preserveAlpha: Bool,
        checkerboard: Bool
    ) throws {
        try dispatchChunk(
            pipeline: yPipeline,
            sourceFrames: sourceFrames,
            outputTexture: outputTexture,
            batchStart: batchStart,
            frameStartIndex: frameStartIndex,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            useAlpha: useAlpha,
            preserveAlpha: preserveAlpha,
            checkerboard: checkerboard,
            gridWidth: outputTexture.arrayLength,
            gridHeight: sourceWidth
        )
    }

    func extractBGRA(textureArray: MTLTexture, slice: Int, width: Int, height: Int) -> [UInt8] {
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        let region = MTLRegionMake2D(0, 0, width, height)
        bgra.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            textureArray.getBytes(
                ptr,
                bytesPerRow: width * 4,
                bytesPerImage: width * height * 4,
                from: region,
                mipmapLevel: 0,
                slice: slice
            )
        }
        return bgra
    }

    private func dispatchChunk(
        pipeline: MTLComputePipelineState,
        sourceFrames: [SourceFrameTexture],
        outputTexture: MTLTexture,
        batchStart: Int,
        frameStartIndex: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        useAlpha: Bool,
        preserveAlpha: Bool,
        checkerboard: Bool,
        gridWidth: Int,
        gridHeight: Int
    ) throws {
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw VideoExportError.metalUnavailable("无法创建高精度导出命令缓冲")
        }

        let uniformSize = MemoryLayout<HighPrecisionAssembleUniforms>.stride
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let tg = MTLSize(width: w, height: h, depth: 1)
        let threads = MTLSize(width: max(1, gridWidth), height: max(1, gridHeight), depth: 1)

        for (localIndex, frame) in sourceFrames.enumerated() {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw VideoExportError.metalUnavailable("无法创建高精度导出 encoder")
            }

            guard let uniformBuffer = device.makeBuffer(length: uniformSize, options: .storageModeShared) else {
                encoder.endEncoding()
                throw VideoExportError.metalUnavailable("无法创建高精度导出 uniformBuffer")
            }

            var uniforms = HighPrecisionAssembleUniforms(
                batchStart: UInt32(batchStart),
                batchCount: UInt32(outputTexture.arrayLength),
                frameIndex: UInt32(frameStartIndex + localIndex),
                sourceWidth: UInt32(sourceWidth),
                sourceHeight: UInt32(sourceHeight),
                useAlpha: useAlpha ? 1 : 0,
                preserveAlpha: preserveAlpha ? 1 : 0,
                checkerboard: checkerboard ? 1 : 0
            )
            memcpy(uniformBuffer.contents(), &uniforms, uniformSize)

            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(frame.texture, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.dispatchThreads(threads, threadsPerThreadgroup: tg)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw VideoExportError.metalUnavailable("高精度导出 GPU 批处理失败：\(error.localizedDescription)")
        }
    }

    private func dispatch(
        pipeline: MTLComputePipelineState,
        sourceTexture: MTLTexture,
        outputTexture: MTLTexture,
        uniforms: HighPrecisionAssembleUniforms,
        gridWidth: Int,
        gridHeight: Int
    ) throws {
        let uniformSize = MemoryLayout<HighPrecisionAssembleUniforms>.stride
        guard let uniformBuffer = device.makeBuffer(length: uniformSize, options: .storageModeShared) else {
            throw VideoExportError.metalUnavailable("无法创建高精度导出 uniformBuffer")
        }
        var localUniforms = uniforms
        memcpy(uniformBuffer.contents(), &localUniforms, uniformSize)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VideoExportError.metalUnavailable("无法创建高精度导出命令缓冲或 encoder")
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let tg = MTLSize(width: w, height: h, depth: 1)
        let threads = MTLSize(width: max(1, gridWidth), height: max(1, gridHeight), depth: 1)

        encoder.dispatchThreads(threads, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw VideoExportError.metalUnavailable("高精度导出 GPU 汇编失败：\(error.localizedDescription)")
        }
    }
}

private final class HighPrecisionPlaneRawGPUAssembler {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw VideoExportError.metalUnavailable("无法创建参考面 raw GPU 设备或命令队列")
        }
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            throw VideoExportError.metalUnavailable("无法加载参考面 raw Metal Library：\(error.localizedDescription)")
        }

        guard let fn = library.makeFunction(name: "highPrecisionPlaneRawKernel") else {
            throw VideoExportError.metalUnavailable("找不到参考面 raw GPU kernel")
        }

        do {
            self.pipeline = try device.makeComputePipelineState(function: fn)
        } catch {
            throw VideoExportError.metalUnavailable("无法创建参考面 raw GPU pipeline：\(error.localizedDescription)")
        }

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw VideoExportError.metalUnavailable("无法创建参考面 raw CVMetalTextureCache")
        }
        self.textureCache = cache
    }

    func makeRawBufferNoCopy(baseAddress: UnsafeRawPointer, length: Int) -> MTLBuffer? {
        guard length > 0 else { return nil }
        let mutableBase = UnsafeMutableRawPointer(mutating: baseAddress)
        return device.makeBuffer(
            bytesNoCopy: mutableBase,
            length: length,
            options: .storageModeShared,
            deallocator: nil
        )
    }

    func render(
        rawBuffer: MTLBuffer,
        cache: RawPlaneExportCache,
        pixelBuffer: CVPixelBuffer,
        frameIndex: Int,
        rawFrameOffset: Int = 0,
        rawDepth: Int? = nil,
        preserveAlpha: Bool,
        useAlpha: Bool,
        showCheckerboard: Bool
    ) -> Bool {
        let dstWidth = CVPixelBufferGetWidth(pixelBuffer)
        let dstHeight = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            dstWidth,
            dstHeight,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess,
              let cvTexture,
              let dstTexture = CVMetalTextureGetTexture(cvTexture) else {
            return false
        }

        var uniforms = HighPrecisionPlaneRawUniforms(
            contentWidth: UInt32(cache.outWidth),
            contentHeight: UInt32(cache.outHeight),
            sourceWidth: UInt32(cache.sourceWidth),
            sourceHeight: UInt32(cache.sourceHeight),
            sourceDepth: UInt32(cache.sourceDepth),
            rawDepth: UInt32(rawDepth ?? cache.sourceDepth),
            rawFrameOffset: UInt32(rawFrameOffset),
            frameBytes: UInt32(cache.frameBytes),
            frameIndex: UInt32(max(0, min(frameIndex, cache.sliceCount - 1))),
            sliceCount: UInt32(cache.sliceCount),
            useAlpha: useAlpha ? 1 : 0,
            preserveAlpha: preserveAlpha ? 1 : 0,
            checkerboard: (showCheckerboard && useAlpha && !preserveAlpha) ? 1 : 0,
            planeU: cache.u,
            uMin: cache.uMin,
            planeV: cache.v,
            vMin: cache.vMin,
            planeN: cache.n,
            dBase: cache.dBase,
            uMax: cache.uMax,
            vMax: cache.vMax,
            dStep: cache.dStep
        )

        let uniformSize = MemoryLayout<HighPrecisionPlaneRawUniforms>.stride
        guard let uniformBuffer = device.makeBuffer(length: uniformSize, options: .storageModeShared) else {
            return false
        }
        memcpy(uniformBuffer.contents(), &uniforms, uniformSize)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(rawBuffer, offset: 0, index: 0)
        encoder.setTexture(dstTexture, index: 0)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 1)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let tg = MTLSize(width: w, height: h, depth: 1)
        let threads = MTLSize(width: max(1, dstWidth), height: max(1, dstHeight), depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            _ = error
            return false
        }
        return true
    }
}

private final class MeshSliceGPUIntersector {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let triangleBuffer: MTLBuffer
    private let rangeBuffer: MTLBuffer
    private let outputBuffer: MTLBuffer
    private let outputCountBuffer: MTLBuffer
    private let triangleCount: Int

    init(triangles: [MeshExportTriangle], planeRanges: [(min: Float, max: Float)]) throws {
        guard !triangles.isEmpty else {
            throw VideoExportError.metalUnavailable("模型三角形为空")
        }
        guard triangles.count == planeRanges.count else {
            throw VideoExportError.metalUnavailable("模型切片预剔除范围数量不匹配")
        }

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw VideoExportError.metalUnavailable("无法创建模型切片 GPU 设备或命令队列")
        }
        self.device = device
        self.queue = queue
        self.triangleCount = triangles.count

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            throw VideoExportError.metalUnavailable("无法加载模型切片 Metal Library：\(error.localizedDescription)")
        }

        guard let fn = library.makeFunction(name: "meshSliceIntersectKernel") else {
            throw VideoExportError.metalUnavailable("找不到模型切片 GPU kernel")
        }

        do {
            self.pipeline = try device.makeComputePipelineState(function: fn)
        } catch {
            throw VideoExportError.metalUnavailable("无法创建模型切片 GPU pipeline：\(error.localizedDescription)")
        }

        let triangleBytes = triangles.count * MemoryLayout<MeshExportTriangle>.stride
        guard let triangleBuffer = triangles.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: triangleBytes, options: .storageModeShared)
        }) else {
            throw VideoExportError.metalUnavailable("无法创建模型三角形 GPU buffer")
        }

        let ranges = planeRanges.map { SIMD2<Float>($0.min, $0.max) }
        let rangeBytes = ranges.count * MemoryLayout<SIMD2<Float>>.stride
        guard let rangeBuffer = ranges.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: rangeBytes, options: .storageModeShared)
        }) else {
            throw VideoExportError.metalUnavailable("无法创建模型切片预剔除 GPU buffer")
        }

        let outputBytes = triangles.count * MemoryLayout<MeshSliceGPUOutput>.stride
        guard let outputBuffer = device.makeBuffer(length: outputBytes, options: .storageModeShared) else {
            throw VideoExportError.metalUnavailable("无法创建模型切片输出 GPU buffer")
        }
        guard let outputCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            throw VideoExportError.metalUnavailable("无法创建模型切片输出计数 GPU buffer")
        }

        self.triangleBuffer = triangleBuffer
        self.rangeBuffer = rangeBuffer
        self.outputBuffer = outputBuffer
        self.outputCountBuffer = outputCountBuffer
    }

    func segments(cache: MeshSliceCache, d: Float) -> [MeshSliceSegment]? {
        guard triangleCount == cache.triangles.count else { return nil }

        var uniforms = MeshSliceGPUUniforms(
            triangleCount: UInt32(triangleCount),
            planeN: cache.n,
            d: d,
            planeU: cache.u,
            planeV: cache.v,
            lightDirection: simd_normalize(SIMD3<Float>(-0.35, 0.65, 0.68)),
            epsilon: 0.000_01
        )

        guard let uniformBuffer = device.makeBuffer(
            bytes: &uniforms,
            length: MemoryLayout<MeshSliceGPUUniforms>.stride,
            options: .storageModeShared
        ),
        let commandBuffer = queue.makeCommandBuffer(),
        let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        outputCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(triangleBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 2)
        encoder.setBuffer(rangeBuffer, offset: 0, index: 3)
        encoder.setBuffer(outputCountBuffer, offset: 0, index: 4)

        let threads = MTLSize(width: triangleCount, height: 1, depth: 1)
        let groupWidth = min(max(1, pipeline.threadExecutionWidth), max(1, triangleCount))
        let threadgroup = MTLSize(width: groupWidth, height: 1, depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.error == nil else { return nil }

        let outputCount = min(
            triangleCount,
            Int(outputCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        )
        let pointer = outputBuffer.contents().bindMemory(to: MeshSliceGPUOutput.self, capacity: triangleCount)
        var segments: [MeshSliceSegment] = []
        segments.reserveCapacity(outputCount)

        for index in 0..<outputCount {
            let output = pointer[index]
            guard output.active != 0 else { continue }
            segments.append(MeshSliceSegment(
                u0: output.u0,
                v0: output.v0,
                u1: output.u1,
                v1: output.v1,
                shade: output.shade
            ))
        }

        return segments
    }
}

private final class GPUExportContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let axisPipeline: MTLComputePipelineState
    let planePipeline: MTLComputePipelineState
    let volumeTexture: MTLTexture
    let textureCache: CVMetalTextureCache
    let usedPreferredTexture: Bool

    convenience init(volume: CPUVolume, preferredTextureCacheID: UUID? = nil) throws {
        try self.init(
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            preferredTextureCacheID: preferredTextureCacheID
        ) { volumeTexture in
            let region = MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth)
            if let raw = Mirror(reflecting: volume).descendant("rgba") as? [UInt8] {
                volumeTexture.replace(
                    region: region,
                    mipmapLevel: 0,
                    slice: 0,
                    withBytes: raw,
                    bytesPerRow: volume.width * 4,
                    bytesPerImage: volume.width * volume.height * 4
                )
            } else {
                var raw = [UInt8](repeating: 0, count: volume.width * volume.height * volume.depth * 4)
                for t in 0..<volume.depth {
                    for y in 0..<volume.height {
                        for x in 0..<volume.width {
                            let (r, g, b, a) = volume.rgbaAt(t: t, y: y, x: x)
                            let idx = ((t * volume.height + y) * volume.width + x) * 4
                            raw[idx] = r
                            raw[idx + 1] = g
                            raw[idx + 2] = b
                            raw[idx + 3] = a
                        }
                    }
                }
                volumeTexture.replace(
                    region: region,
                    mipmapLevel: 0,
                    slice: 0,
                    withBytes: raw,
                    bytesPerRow: volume.width * 4,
                    bytesPerImage: volume.width * volume.height * 4
                )
            }
        }
    }

    convenience init(rawCacheData: Data, width: Int, height: Int, depth: Int) throws {
        let expectedBytes = width * height * depth * 4
        guard rawCacheData.count >= expectedBytes else {
            throw VideoExportError.createReaderFailed("参考面 raw cache 数据不完整")
        }

        try self.init(width: width, height: height, depth: depth) { volumeTexture in
            let region = MTLRegionMake3D(0, 0, 0, width, height, depth)
            try rawCacheData.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw VideoExportError.createReaderFailed("参考面 raw cache 数据不可读")
                }
                volumeTexture.replace(
                    region: region,
                    mipmapLevel: 0,
                    slice: 0,
                    withBytes: baseAddress,
                    bytesPerRow: width * 4,
                    bytesPerImage: width * height * 4
                )
            }
        }
    }

    private init(
        width: Int,
        height: Int,
        depth: Int,
        preferredTextureCacheID: UUID? = nil,
        uploadVolume: (MTLTexture) throws -> Void
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw VideoExportError.metalUnavailable("无法创建设备或命令队列")
        }
        self.device = device
        self.queue = queue

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            throw VideoExportError.metalUnavailable("无法加载默认 Metal Library：\(error.localizedDescription)")
        }

        guard let axisFn = library.makeFunction(name: "axisSliceKernel"),
              let planeFn = library.makeFunction(name: "planeSliceKernel") else {
            throw VideoExportError.metalUnavailable("找不到导出所需的 Metal kernel")
        }

        do {
            self.axisPipeline = try device.makeComputePipelineState(function: axisFn)
            self.planePipeline = try device.makeComputePipelineState(function: planeFn)
        } catch {
            throw VideoExportError.metalUnavailable("无法创建 compute pipeline：\(error.localizedDescription)")
        }

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let textureCache = cache else {
            throw VideoExportError.metalUnavailable("无法创建 CVMetalTextureCache")
        }
        self.textureCache = textureCache

        if let preferredTextureCacheID,
           let cachedTexture = VolumeModifierRasterizer.cachedModifiedTexture(
            for: preferredTextureCacheID,
            device: device
           ),
           cachedTexture.width == width,
           cachedTexture.height == height,
           cachedTexture.depth == depth {
            self.volumeTexture = cachedTexture
            self.usedPreferredTexture = true
            return
        }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba8Unorm
        desc.width = width
        desc.height = height
        desc.depth = depth
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        guard let volumeTexture = device.makeTexture(descriptor: desc) else {
            throw VideoExportError.metalUnavailable("无法创建 3D 体纹理")
        }

        try uploadVolume(volumeTexture)
        self.volumeTexture = volumeTexture
        self.usedPreferredTexture = false
    }

    func renderAxisDirectToPixelBuffer(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        axis: PlaybackAxis,
        index: Int,
        showCheckerboard: Bool,
        useAlpha: Bool
    ) throws {
        let texture = try makeTexture(from: pixelBuffer, width: width, height: height)
        let uniformSize = MemoryLayout<AxisSliceUniforms>.stride
        guard let uniformBuffer = device.makeBuffer(length: uniformSize, options: .storageModeShared) else {
            throw VideoExportError.metalUnavailable("无法创建 Axis uniformBuffer")
        }

        var uniforms = AxisSliceUniforms(
            outWidth: UInt32(width),
            outHeight: UInt32(height),
            useAlpha: useAlpha ? 1 : 0,
            showCheckerboard: showCheckerboard ? 1 : 0,
            fastPreview: 0,
            axisType: axis == .x ? 0 : (axis == .y ? 1 : 2),
            fixedIndex: UInt32(max(0, index)),
            volumeWidth: UInt32(volumeTexture.width),
            volumeHeight: UInt32(volumeTexture.height),
            volumeDepth: UInt32(volumeTexture.depth),
            contentX: 0,
            contentY: 0,
            contentW: Float(width),
            contentH: Float(height)
        )
        memcpy(uniformBuffer.contents(), &uniforms, uniformSize)
        try dispatch(pipeline: axisPipeline, uniformBuffer: uniformBuffer, outputTexture: texture)
    }

    func renderPlaneDirectToPixelBuffer(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        params: PlaneSliceUniforms
    ) throws {
        let texture = try makeTexture(from: pixelBuffer, width: width, height: height)
        let uniformSize = MemoryLayout<PlaneSliceUniforms>.stride
        guard let uniformBuffer = device.makeBuffer(length: uniformSize, options: .storageModeShared) else {
            throw VideoExportError.metalUnavailable("无法创建 Plane uniformBuffer")
        }

        var uniforms = params
        memcpy(uniformBuffer.contents(), &uniforms, uniformSize)
        try dispatch(pipeline: planePipeline, uniformBuffer: uniformBuffer, outputTexture: texture)
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> MTLTexture {
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
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw VideoExportError.metalUnavailable("无法从像素缓冲创建 Metal 纹理")
        }

        return texture
    }

    private func dispatch(
        pipeline: MTLComputePipelineState,
        uniformBuffer: MTLBuffer,
        outputTexture: MTLTexture
    ) throws {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw VideoExportError.metalUnavailable("无法创建命令缓冲或 encoder")
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(volumeTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let tg = MTLSize(width: w, height: h, depth: 1)
        let threads = MTLSize(width: outputTexture.width, height: outputTexture.height, depth: 1)

        encoder.dispatchThreads(threads, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw VideoExportError.metalUnavailable("GPU 渲染失败：\(error.localizedDescription)")
        }
    }
}

enum VideoExportHelper {
    static func export(
        volume: CPUVolume,
        request: VideoExportRequest,
        progress: @escaping ExportProgressHandler
    ) throws {
        if request.highPrecision, request.mode == .axis, request.sourceURL != nil {
            try exportHighPrecisionAxisFromSource(request: request, progress: progress)
            return
        }

        if request.highPrecision, request.mode == .plane, request.sourceURL != nil {
            try exportHighPrecisionPlaneFromSource(request: request, progress: progress)
            return
        }

        if try tryFastTExport(request: request, progress: progress) {
            return
        }

        try exportRendered(volume: volume, request: request, progress: progress)
    }

    // MARK: - T axis fast export

    private static func tryFastTExport(
        request: VideoExportRequest,
        progress: @escaping ExportProgressHandler
    ) throws -> Bool {
        guard request.mode == .axis, request.axis == .t else { return false }
        guard !request.usesModifiedVolumeTexture else { return false }
        guard abs(request.playbackRate - 1.0) < 0.0001 else { return false }
        guard let sourceURL = request.sourceURL else { return false }

        let asset = AVURLAsset(url: sourceURL)

        guard let track = asset.tracks(withMediaType: .video).first else { return false }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        let srcW = Int(abs(transformed.width).rounded())
        let srcH = Int(abs(transformed.height).rounded())
        guard srcW == request.width, srcH == request.height else { return false }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }

        if FileManager.default.fileExists(atPath: request.url.path) {
            try FileManager.default.removeItem(at: request.url)
        }

        exportSession.outputURL = request.url
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        progress(0.05, "T轴直通导出")

        let sem = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            sem.signal()
        }
        sem.wait()

        switch exportSession.status {
        case .completed:
            progress(1.0, "T轴直通导出")
            return true
        case .failed, .cancelled:
            return false
        default:
            return false
        }
    }

    // MARK: - Render export

    private static func exportRendered(
        volume: CPUVolume,
        request: VideoExportRequest,
        progress: @escaping ExportProgressHandler
    ) throws {
        let outW = request.padToEven ? even(request.width) : request.width
        let outH = request.padToEven ? even(request.height) : request.height

        let actualPreserveAlpha = request.preserveAlpha && request.useAlpha
        let codecValue = codecValueForExport(
            preserveAlpha: actualPreserveAlpha,
            bitDepth: request.bitDepth,
            colorProfile: request.colorProfile
        )

        try prepareOutputURLForAssetWriter(request.url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: request.url, fileType: .mov)
        } catch {
            throw VideoExportError.createWriterFailed(error.localizedDescription)
        }

        writer.shouldOptimizeForNetworkUse = false
        writer.movieTimeScale = 600

        var outputSettings: [String: Any] = [
            AVVideoCodecKey: codecValue,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH
        ]
        outputSettings[AVVideoColorPropertiesKey] = request.colorProfile.avVideoColorProperties

        if codecValue == AVVideoCodecType.h264.rawValue {
            outputSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(2_000_000, outW * outH * max(10, request.bitDepth)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 600

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else {
            throw VideoExportError.createInputFailed
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw VideoExportError.createWriterFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            throw VideoExportError.createPixelBufferPoolFailed
        }

        let frameDuration = CMTime(seconds: 1.0 / max(0.05, request.fps), preferredTimescale: 600)

        let meshSliceCache = request.mesh.flatMap {
            buildMeshSliceCache(mesh: $0, volume: volume, request: request)
        }
        let meshIntersector = meshSliceCache.flatMap {
            try? MeshSliceGPUIntersector(
                triangles: $0.triangles,
                planeRanges: $0.trianglePlaneRanges
            )
        }
        let shouldBuildCPUFallbackCache = !request.usesModifiedVolumeTexture
        let axisCache = shouldBuildCPUFallbackCache && meshSliceCache == nil && request.mode == .axis
            ? buildAxisExportCache(volume: volume, request: request)
            : nil
        let planeCache = shouldBuildCPUFallbackCache && meshSliceCache == nil && request.mode == .plane
            ? buildPlaneExportCache(volume: volume, request: request)
            : nil

        let shouldUseGPU = meshSliceCache == nil
            && (request.mode == .plane || request.mode == .axis)
        let gpuContext: GPUExportContext? = shouldUseGPU
            ? (try? GPUExportContext(
                volume: volume,
                preferredTextureCacheID: request.volumeTextureCacheID
            ))
            : nil

        if request.usesModifiedVolumeTexture {
            guard let gpuContext, gpuContext.usedPreferredTexture else {
                throw VideoExportError.metalUnavailable("修改后的 GPU 体缓存不可用，请等待体素修改器完成或重新应用修改器")
            }
        }

        let routeText: String
        if meshSliceCache != nil {
            let aaSuffix = request.meshSupersampleScale > 1 ? " · \(request.meshSupersampleScale)x 抗锯齿" : ""
            let gpuSuffix = meshIntersector == nil ? " · 并行栅格" : " · GPU求交/预剔除/压缩 · 并行栅格"
            routeText = actualPreserveAlpha ? "模型直接切片（带 Alpha）\(aaSuffix)\(gpuSuffix)" : "模型直接切片\(aaSuffix)\(gpuSuffix)"
        } else if gpuContext != nil {
            let modifiedSuffix = request.usesModifiedVolumeTexture ? " · 修改体" : ""
            routeText = actualPreserveAlpha ? "GPU导出（带 Alpha）\(modifiedSuffix)" : "GPU导出\(modifiedSuffix)"
        } else {
            routeText = actualPreserveAlpha ? "CPU导出（带 Alpha）" : "CPU导出"
        }
        progress(0.0, routeText)

        var lastReportedPercent = -1
        let firstOutputFrame = request.outputStartFrame ?? 0

        for frameIndex in 0..<request.frameCount {
            let renderFrameIndex = firstOutputFrame + frameIndex
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }

            var pb: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
            guard status == kCVReturnSuccess, let pixelBuffer = pb else {
                throw VideoExportError.createPixelBufferFailed
            }

            if let meshSliceCache {
                let rgba = renderMeshSliceRGBA(
                    cache: meshSliceCache,
                    request: request,
                    frameIndex: renderFrameIndex,
                    preserveAlpha: actualPreserveAlpha,
                    intersector: meshIntersector
                )
                fillPixelBufferFromRGBA(
                    pixelBuffer: pixelBuffer,
                    width: outW,
                    height: outH,
                    rgba: rgba,
                    srcWidth: request.width,
                    srcHeight: request.height,
                    keepAlpha: actualPreserveAlpha
                )
            } else if let gpuContext {
                switch request.mode {
                case .axis:
                    try gpuContext.renderAxisDirectToPixelBuffer(
                        pixelBuffer: pixelBuffer,
                        width: request.width,
                        height: request.height,
                        axis: request.axis,
                        index: renderFrameIndex,
                        showCheckerboard: request.showCheckerboard && request.useAlpha && !actualPreserveAlpha,
                        useAlpha: request.useAlpha
                    )

                case .plane:
                    let uniforms = buildPlaneUniforms(
                        volume: volume,
                        request: request,
                        frameIndex: renderFrameIndex,
                        preserveAlpha: actualPreserveAlpha
                    )
                    try gpuContext.renderPlaneDirectToPixelBuffer(
                        pixelBuffer: pixelBuffer,
                        width: request.width,
                        height: request.height,
                        params: uniforms
                    )
                }
            } else {
                let rgba = renderCPU_RGBA(
                    volume: volume,
                    request: request,
                    frameIndex: renderFrameIndex,
                    preserveAlpha: actualPreserveAlpha,
                    axisCache: axisCache,
                    planeCache: planeCache
                )
                fillPixelBufferFromRGBA(
                    pixelBuffer: pixelBuffer,
                    width: outW,
                    height: outH,
                    rgba: rgba,
                    srcWidth: request.width,
                    srcHeight: request.height,
                    keepAlpha: actualPreserveAlpha
                )
            }

            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
            if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
                throw VideoExportError.appendFailed(writer.error?.localizedDescription ?? "unknown")
            }

            let percent = Int(((Double(frameIndex + 1) / Double(max(1, request.frameCount))) * 100.0).rounded(.down))
            if percent >= lastReportedPercent + 2 || frameIndex == request.frameCount - 1 {
                lastReportedPercent = percent
                progress(Double(frameIndex + 1) / Double(max(1, request.frameCount)), routeText)
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


    // MARK: - High precision export (T/X/Y from original source size)

    private static func normalizedOutputRange(
        start requestedStart: Int?,
        end requestedEnd: Int?,
        upperBound: Int
    ) -> (start: Int, end: Int) {
        let start = max(0, requestedStart ?? 0)
        let end = min(upperBound, requestedEnd ?? upperBound)
        if end < start {
            return (start, start - 1)
        }
        return (start, end)
    }

    private static func localPresentationTime(
        globalIndex: Int,
        segmentStart: Int,
        frameDuration: CMTime
    ) -> CMTime {
        let localIndex = max(0, globalIndex - segmentStart)
        return CMTimeMultiply(frameDuration, multiplier: Int32(localIndex))
    }

    private static func exportHighPrecisionAxisFromSource(
        request: VideoExportRequest,
        preparedRawCacheURL: URL? = nil,
        preparedRawCacheData: Data? = nil,
        progress: @escaping ExportProgressHandler
    ) throws {
        guard let sourceURL = request.sourceURL else {
            progress(0.0, "高精度导出回退")
            throw VideoExportError.createReaderFailed("缺少源视频 URL")
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VideoExportError.createReaderFailed("找不到视频轨道")
        }

        let natural = track.naturalSize.applying(track.preferredTransform)
        let sourceWidth = max(1, Int(abs(natural.width).rounded()))
        let sourceHeight = max(1, Int(abs(natural.height).rounded()))
        let sourceFrameCount = max(1, request.sourceFrameCount > 0 ? request.sourceFrameCount : estimateFrameCount(asset: asset, track: track))

        switch request.axis {
        case .t:
            try exportHighPrecisionT(
                asset: asset,
                track: track,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                request: request,
                progress: progress
            )
        case .x:
            try exportHighPrecisionX(
                asset: asset,
                track: track,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                request: request,
                preparedRawCacheURL: preparedRawCacheURL,
                preparedRawCacheData: preparedRawCacheData,
                progress: progress
            )
        case .y:
            try exportHighPrecisionY(
                asset: asset,
                track: track,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                request: request,
                preparedRawCacheURL: preparedRawCacheURL,
                preparedRawCacheData: preparedRawCacheData,
                progress: progress
            )
        }
    }

    private static func exportHighPrecisionPlaneFromSource(
        request: VideoExportRequest,
        preparedRawCacheURL: URL? = nil,
        preparedRawCacheData: Data? = nil,
        progress: @escaping ExportProgressHandler
    ) throws {
        guard let sourceURL = request.sourceURL else {
            progress(0.0, "高精度参考面导出回退")
            throw VideoExportError.createReaderFailed("缺少源视频 URL")
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VideoExportError.createReaderFailed("找不到视频轨道")
        }

        let natural = track.naturalSize.applying(track.preferredTransform)
        let sourceWidth = max(1, Int(abs(natural.width).rounded()))
        let sourceHeight = max(1, Int(abs(natural.height).rounded()))
        let sourceFrameCount = max(1, request.sourceFrameCount > 0 ? request.sourceFrameCount : estimateFrameCount(asset: asset, track: track))
        let preserveAlpha = request.preserveAlpha && request.useAlpha
        let routeText = preserveAlpha ? "高精度参考面原尺寸 raw cache（带 Alpha）" : "高精度参考面原尺寸 raw cache"

        progress(0.0, routeText)

        let rawCache: TempRawFrameCache
        let shouldRemoveRawCache: Bool
        if let preparedRawCacheURL {
            rawCache = TempRawFrameCache(
                url: preparedRawCacheURL,
                width: sourceWidth,
                height: sourceHeight,
                frameCount: sourceFrameCount,
                frameBytes: sourceWidth * sourceHeight * 4
            )
            shouldRemoveRawCache = false
            progress(0.10, routeText + "·复用已预热 raw cache")
        } else {
            rawCache = try buildTempRawFrameCache(
                asset: asset,
                track: track,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                progress: progress,
                routeText: routeText,
                tempDirectory: request.url.deletingLastPathComponent()
            )
            shouldRemoveRawCache = true
        }
        defer {
            if shouldRemoveRawCache {
                try? FileManager.default.removeItem(at: rawCache.url)
            }
        }

        let cache = buildRawPlaneExportCache(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceFrameCount: rawCache.frameCount,
            request: request
        )
        let outW = request.padToEven ? even(cache.outWidth) : cache.outWidth
        let outH = request.padToEven ? even(cache.outHeight) : cache.outHeight
        let range = normalizedOutputRange(
            start: request.outputStartFrame,
            end: request.outputEndFrame,
            upperBound: max(0, cache.sliceCount - 1)
        )
        guard range.end >= range.start else {
            throw VideoExportError.createWriterFailed("高精度参考面输出范围无效")
        }

        let mapped = try mappedRawFrameCache(rawCache, preparedRawCacheData: preparedRawCacheData)
        let (writer, input, adaptor) = try createWriter(
            outputURL: request.url,
            width: outW,
            height: outH,
            preserveAlpha: preserveAlpha,
            bitDepth: request.bitDepth,
            colorProfile: request.colorProfile
        )
        let frameDuration = CMTime(seconds: 1.0 / max(0.05, request.fps), preferredTimescale: 600)

        var lastReportedPercent = -1
        try mapped.data.withUnsafeBytes { raw in
            guard let rawBase = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw VideoExportError.createReaderFailed("原始帧临时缓存映射无效")
            }
            var gpuRenderer: HighPrecisionPlaneRawGPUAssembler?
            var gpuRawBuffer: MTLBuffer?
            if let rawBaseAddress = raw.baseAddress {
                gpuRenderer = try? HighPrecisionPlaneRawGPUAssembler()
                if let renderer = gpuRenderer {
                    gpuRawBuffer = renderer.makeRawBufferNoCopy(
                        baseAddress: rawBaseAddress,
                        length: mapped.data.count
                    )
                }
            }
            var useRawGPU = gpuRenderer != nil && gpuRawBuffer != nil
            var allowSlabGPU = gpuRenderer != nil
            var lastFrameUsedGPU = useRawGPU
            let cpuRouteText = routeText + " CPU"
            let gpuRouteText = routeText + " GPU"

            for outIndex in range.start...range.end {
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.001)
                }

                guard let dstPB = makePixelBuffer(from: adaptor) else {
                    throw VideoExportError.createPixelBufferFailed
                }
                lastFrameUsedGPU = false
                if useRawGPU, let gpuRenderer, let gpuRawBuffer {
                    if gpuRenderer.render(
                        rawBuffer: gpuRawBuffer,
                        cache: cache,
                        pixelBuffer: dstPB,
                        frameIndex: outIndex,
                        preserveAlpha: preserveAlpha,
                        useAlpha: request.useAlpha,
                        showCheckerboard: request.showCheckerboard
                    ) {
                        lastFrameUsedGPU = true
                    } else {
                        useRawGPU = false
                    }
                }

                if !lastFrameUsedGPU, allowSlabGPU, let gpuRenderer {
                    let bounds = rawPlaneTimeBounds(cache: cache, frameIndex: outIndex)
                    let slabBase = rawBase.advanced(by: bounds.start * cache.frameBytes)
                    if let slabBuffer = gpuRenderer.makeRawBufferNoCopy(
                        baseAddress: UnsafeRawPointer(slabBase),
                        length: bounds.depth * cache.frameBytes
                    ) {
                        lastFrameUsedGPU = gpuRenderer.render(
                            rawBuffer: slabBuffer,
                            cache: cache,
                            pixelBuffer: dstPB,
                            frameIndex: outIndex,
                            rawFrameOffset: bounds.start,
                            rawDepth: bounds.depth,
                            preserveAlpha: preserveAlpha,
                            useAlpha: request.useAlpha,
                            showCheckerboard: request.showCheckerboard
                        )
                    } else {
                        allowSlabGPU = false
                    }
                }

                if !lastFrameUsedGPU {
                    renderRawPlanePixelBuffer(
                        rawBase: rawBase,
                        cache: cache,
                        pixelBuffer: dstPB,
                        pixelBufferWidth: outW,
                        pixelBufferHeight: outH,
                        frameIndex: outIndex,
                        preserveAlpha: preserveAlpha,
                        useAlpha: request.useAlpha,
                        showCheckerboard: request.showCheckerboard
                    )
                }

                let time = localPresentationTime(
                    globalIndex: outIndex,
                    segmentStart: range.start,
                    frameDuration: frameDuration
                )
                if !adaptor.append(dstPB, withPresentationTime: time) {
                    throw VideoExportError.appendFailed(writer.error?.localizedDescription ?? "append 失败")
                }

                let done = outIndex - range.start + 1
                let total = max(1, range.end - range.start + 1)
                let percent = Int((Double(done) / Double(total) * 100.0).rounded(.down))
                if percent >= lastReportedPercent + 2 || outIndex == range.end {
                    lastReportedPercent = percent
                    progress(0.12 + Double(done) / Double(total) * 0.88, lastFrameUsedGPU ? gpuRouteText : cpuRouteText)
                }
            }
        }

        input.markAsFinished()
        try finishWriter(writer)
        progress(1.0, routeText)
    }

    private static func exportHighPrecisionT(
        asset: AVURLAsset,
        track: AVAssetTrack,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        request: VideoExportRequest,
        progress: @escaping ExportProgressHandler
    ) throws {
        let contentW = sourceWidth
        let contentH = sourceHeight
        let outW = request.padToEven ? even(contentW) : contentW
        let outH = request.padToEven ? even(contentH) : contentH
        let preserveAlpha = request.preserveAlpha && request.useAlpha

        if abs(request.playbackRate - 1.0) < 0.0001,
           !preserveAlpha,
           outW == sourceWidth,
           outH == sourceHeight {
            if try passthroughSource(asset: asset, request: request, routeText: "高精度T轴原尺寸直通导出", progress: progress) {
                return
            }
        }

        progress(0.0, preserveAlpha ? "高精度T轴原尺寸重编码（带 Alpha）" : "高精度T轴原尺寸重编码")

        let (writer, input, adaptor) = try createWriter(
            outputURL: request.url,
            width: outW,
            height: outH,
            preserveAlpha: preserveAlpha,
            bitDepth: request.bitDepth,
            colorProfile: request.colorProfile
        )
        let frameDuration = CMTime(seconds: 1.0 / max(0.05, request.fps), preferredTimescale: 600)

        let (reader, output) = try makeBGRAReader(asset: asset, track: track)
        guard reader.startReading() else {
            throw VideoExportError.createReaderFailed(reader.error?.localizedDescription ?? "reader.startReading 失败")
        }

        var frameIndex = 0
        let routeText = preserveAlpha ? "高精度T轴原尺寸重编码（带 Alpha）" : "高精度T轴原尺寸重编码"

        while let sample = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }

            guard let srcPB = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }

            guard let dstPB = makePixelBuffer(from: adaptor) else {
                throw VideoExportError.createPixelBufferFailed
            }

            copyPixelBuffer(
                src: srcPB,
                dst: dstPB,
                dstWidth: outW,
                dstHeight: outH,
                preserveAlpha: preserveAlpha,
                useAlpha: request.useAlpha,
                checkerboard: request.showCheckerboard && request.useAlpha && !preserveAlpha
            )

            let time = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
            if !adaptor.append(dstPB, withPresentationTime: time) {
                throw VideoExportError.appendFailed(writer.error?.localizedDescription ?? "append 失败")
            }

            frameIndex += 1
            if frameIndex % 8 == 0 || frameIndex == sourceFrameCount {
                progress(Double(frameIndex) / Double(max(1, sourceFrameCount)), routeText)
            }
        }

        input.markAsFinished()
        try finishWriter(writer)
        progress(1.0, routeText)
    }

    private static func exportHighPrecisionX(
        asset: AVURLAsset,
        track: AVAssetTrack,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        request: VideoExportRequest,
        preparedRawCacheURL: URL? = nil,
        preparedRawCacheData: Data? = nil,
        progress: @escaping ExportProgressHandler
    ) throws {
        do {
            try exportHighPrecisionXGPU(
                asset: asset,
                track: track,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                request: request,
                preparedRawCacheURL: preparedRawCacheURL,
                preparedRawCacheData: preparedRawCacheData,
                progress: progress
            )
            return
        } catch {
            // GPU 路径失败时，回退到原来的 CPU 重建
        }

        let contentW = sourceFrameCount
        let contentH = sourceHeight
        let outW = request.padToEven ? even(contentW) : contentW
        let outH = request.padToEven ? even(contentH) : contentH
        let preserveAlpha = request.preserveAlpha && request.useAlpha
        let routeText = preserveAlpha ? "高精度X轴原尺寸CPU重建（带 Alpha）" : "高精度X轴原尺寸CPU重建"

        progress(0.0, routeText)

        let (writer, input, adaptor) = try createWriter(
            outputURL: request.url,
            width: outW,
            height: outH,
            preserveAlpha: preserveAlpha,
            bitDepth: request.bitDepth,
            colorProfile: request.colorProfile
        )
        let frameDuration = CMTime(seconds: 1.0 / max(0.05, request.fps), preferredTimescale: 600)

        let bytesPerFrame = contentW * contentH * 4
        let batchSize = recommendedBatchSize(bytesPerOutputFrame: bytesPerFrame)

        let range = normalizedOutputRange(
            start: request.outputStartFrame,
            end: request.outputEndFrame,
            upperBound: sourceWidth - 1
        )
        guard range.end >= range.start else {
            throw VideoExportError.createWriterFailed("高精度X轴输出范围无效")
        }

        var batchStart = range.start
        while batchStart <= range.end {
            let count = min(batchSize, range.end - batchStart + 1)
            var batchFrames = [UInt8](repeating: 0, count: count * bytesPerFrame)

            let (reader, output) = try makeBGRAReader(asset: asset, track: track)
            guard reader.startReading() else {
                throw VideoExportError.createReaderFailed(reader.error?.localizedDescription ?? "reader.startReading 失败")
            }

            var t = 0
            while let sample = output.copyNextSampleBuffer(), t < sourceFrameCount {
                guard let srcPB = CMSampleBufferGetImageBuffer(sample) else {
                    continue
                }

                CVPixelBufferLockBaseAddress(srcPB, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(srcPB) {
                    let srcBytesPerRow = CVPixelBufferGetBytesPerRow(srcPB)
                    let src = base.bindMemory(to: UInt8.self, capacity: srcBytesPerRow * sourceHeight)

                    for local in 0..<count {
                        let srcX = batchStart + local
                        let frameBase = local * bytesPerFrame
                        for y in 0..<sourceHeight {
                            let srcPix = src.advanced(by: y * srcBytesPerRow + srcX * 4)
                            let dstOffset = frameBase + ((y * contentW + t) * 4)
                            writeConvertedBGRA(
                                into: &batchFrames,
                                at: dstOffset,
                                srcB: srcPix[0],
                                srcG: srcPix[1],
                                srcR: srcPix[2],
                                srcA: srcPix[3],
                                preserveAlpha: preserveAlpha,
                                useAlpha: request.useAlpha,
                                checkerboard: request.showCheckerboard && request.useAlpha && !preserveAlpha,
                                checkerX: t,
                                checkerY: y
                            )
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(srcPB, .readOnly)
                t += 1
            }

            for local in 0..<count {
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                guard let dstPB = makePixelBuffer(from: adaptor) else {
                    throw VideoExportError.createPixelBufferFailed
                }
                fillPixelBufferFromBGRA(
                    pixelBuffer: dstPB,
                    width: outW,
                    height: outH,
                    bgra: batchFrames,
                    bgraOffset: local * bytesPerFrame,
                    srcWidth: contentW,
                    srcHeight: contentH
                )

                let outIndex = batchStart + local
                let time = localPresentationTime(
                    globalIndex: outIndex,
                    segmentStart: range.start,
                    frameDuration: frameDuration
                )
                if !adaptor.append(dstPB, withPresentationTime: time) {
                    throw VideoExportError.appendFailed(writer.error?.localizedDescription ?? "append 失败")
                }
            }

            batchStart += count
            let done = batchStart - range.start
            let total = max(1, range.end - range.start + 1)
            progress(Double(done) / Double(total), routeText)
        }

        input.markAsFinished()
        try finishWriter(writer)
        progress(1.0, routeText)
    }

    private static func exportHighPrecisionY(
        asset: AVURLAsset,
        track: AVAssetTrack,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        request: VideoExportRequest,
        preparedRawCacheURL: URL? = nil,
        preparedRawCacheData: Data? = nil,
        progress: @escaping ExportProgressHandler
    ) throws {
        do {
            try exportHighPrecisionYGPU(
                asset: asset,
                track: track,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                request: request,
                preparedRawCacheURL: preparedRawCacheURL,
                preparedRawCacheData: preparedRawCacheData,
                progress: progress
            )
            return
        } catch {
            // GPU 路径失败时，回退到原来的 CPU 重建
        }

        let contentW = sourceWidth
        let contentH = sourceFrameCount
        let outW = request.padToEven ? even(contentW) : contentW
        let outH = request.padToEven ? even(contentH) : contentH
        let preserveAlpha = request.preserveAlpha && request.useAlpha
        let routeText = preserveAlpha ? "高精度Y轴原尺寸CPU重建（带 Alpha）" : "高精度Y轴原尺寸CPU重建"

        progress(0.0, routeText)

        let (writer, input, adaptor) = try createWriter(
            outputURL: request.url,
            width: outW,
            height: outH,
            preserveAlpha: preserveAlpha,
            bitDepth: request.bitDepth,
            colorProfile: request.colorProfile
        )
        let frameDuration = CMTime(seconds: 1.0 / max(0.05, request.fps), preferredTimescale: 600)

        let bytesPerFrame = contentW * contentH * 4
        let batchSize = recommendedBatchSize(bytesPerOutputFrame: bytesPerFrame)

        let range = normalizedOutputRange(
            start: request.outputStartFrame,
            end: request.outputEndFrame,
            upperBound: sourceHeight - 1
        )
        guard range.end >= range.start else {
            throw VideoExportError.createWriterFailed("高精度Y轴输出范围无效")
        }

        var batchStart = range.start
        while batchStart <= range.end {
            let count = min(batchSize, range.end - batchStart + 1)
            var batchFrames = [UInt8](repeating: 0, count: count * bytesPerFrame)

            let (reader, output) = try makeBGRAReader(asset: asset, track: track)
            guard reader.startReading() else {
                throw VideoExportError.createReaderFailed(reader.error?.localizedDescription ?? "reader.startReading 失败")
            }

            var t = 0
            while let sample = output.copyNextSampleBuffer(), t < sourceFrameCount {
                guard let srcPB = CMSampleBufferGetImageBuffer(sample) else {
                    continue
                }

                CVPixelBufferLockBaseAddress(srcPB, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(srcPB) {
                    let srcBytesPerRow = CVPixelBufferGetBytesPerRow(srcPB)
                    let src = base.bindMemory(to: UInt8.self, capacity: srcBytesPerRow * sourceHeight)

                    for local in 0..<count {
                        let srcY = batchStart + local
                        let frameBase = local * bytesPerFrame
                        let srcRow = src.advanced(by: srcY * srcBytesPerRow)
                        for x in 0..<sourceWidth {
                            let srcPix = srcRow.advanced(by: x * 4)
                            let dstOffset = frameBase + ((t * contentW + x) * 4)
                            writeConvertedBGRA(
                                into: &batchFrames,
                                at: dstOffset,
                                srcB: srcPix[0],
                                srcG: srcPix[1],
                                srcR: srcPix[2],
                                srcA: srcPix[3],
                                preserveAlpha: preserveAlpha,
                                useAlpha: request.useAlpha,
                                checkerboard: request.showCheckerboard && request.useAlpha && !preserveAlpha,
                                checkerX: x,
                                checkerY: t
                            )
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(srcPB, .readOnly)
                t += 1
            }

            for local in 0..<count {
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                guard let dstPB = makePixelBuffer(from: adaptor) else {
                    throw VideoExportError.createPixelBufferFailed
                }
                fillPixelBufferFromBGRA(
                    pixelBuffer: dstPB,
                    width: outW,
                    height: outH,
                    bgra: batchFrames,
                    bgraOffset: local * bytesPerFrame,
                    srcWidth: contentW,
                    srcHeight: contentH
                )

                let outIndex = batchStart + local
                let time = localPresentationTime(
                    globalIndex: outIndex,
                    segmentStart: range.start,
                    frameDuration: frameDuration
                )
                if !adaptor.append(dstPB, withPresentationTime: time) {
                    throw VideoExportError.appendFailed(writer.error?.localizedDescription ?? "append 失败")
                }
            }

            batchStart += count
            let done = batchStart - range.start
            let total = max(1, range.end - range.start + 1)
            progress(Double(done) / Double(total), routeText)
        }

        input.markAsFinished()
        try finishWriter(writer)
        progress(1.0, routeText)
    }

    private static func passthroughSource(
        asset: AVURLAsset,
        request: VideoExportRequest,
        routeText: String,
        progress: @escaping ExportProgressHandler
    ) throws -> Bool {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }

        if FileManager.default.fileExists(atPath: request.url.path) {
            try FileManager.default.removeItem(at: request.url)
        }

        exportSession.outputURL = request.url
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        progress(0.05, routeText)

        let sem = DispatchSemaphore(value: 0)
        exportSession.exportAsynchronously {
            sem.signal()
        }
        sem.wait()

        switch exportSession.status {
        case .completed:
            progress(1.0, routeText)
            return true
        case .failed, .cancelled:
            return false
        default:
            return false
        }
    }

    private static func createWriter(
        outputURL: URL,
        width: Int,
        height: Int,
        preserveAlpha: Bool,
        bitDepth: Int = 8,
        colorProfile: VideoColorProfile = .rec709
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        try prepareOutputURLForAssetWriter(outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false
        writer.movieTimeScale = 600

        let codecValue = codecValueForExport(
            preserveAlpha: preserveAlpha,
            bitDepth: bitDepth,
            colorProfile: colorProfile
        )

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
        input.mediaTimeScale = 600

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
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

    private static func prepareOutputURLForAssetWriter(_ outputURL: URL) throws {
        let fileManager = FileManager.default
        let directory = outputURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw VideoExportError.createWriterFailed("无法创建输出目录：\(error.localizedDescription)")
            }
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw VideoExportError.createWriterFailed("输出路径是文件夹，不能写入 mov 文件")
            }
            do {
                try fileManager.removeItem(at: outputURL)
            } catch {
                throw VideoExportError.createWriterFailed("无法覆盖旧文件：\(error.localizedDescription)")
            }
        }
    }

    private static func codecValueForExport(
        preserveAlpha: Bool,
        bitDepth: Int,
        colorProfile: VideoColorProfile
    ) -> String {
        if preserveAlpha || bitDepth > 8 || colorProfile.isHDR {
            return AVVideoCodecType.proRes4444.rawValue
        }
        return AVVideoCodecType.h264.rawValue
    }


    private struct TempRawFrameCache {
        let url: URL
        let width: Int
        let height: Int
        let frameCount: Int
        let frameBytes: Int
    }

    private struct MappedRawFrameCache {
        let cache: TempRawFrameCache
        let data: Data
    }

    private static func buildTempRawFrameCache(
        asset: AVURLAsset,
        track: AVAssetTrack,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        progress: @escaping ExportProgressHandler,
        routeText: String,
        tempDirectory: URL? = nil
    ) throws -> TempRawFrameCache {
        let frameBytes = sourceWidth * sourceHeight * 4
        let tempURL = (tempDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("rawframes")

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let out = OutputStream(url: tempURL, append: false) else {
            throw VideoExportError.createReaderFailed("无法创建原始帧临时缓存")
        }
        out.open()
        defer { out.close() }

        let (reader, output) = try makeBGRAReader(asset: asset, track: track)
        guard reader.startReading() else {
            throw VideoExportError.createReaderFailed(reader.error?.localizedDescription ?? "reader.startReading 失败")
        }

        var compact = [UInt8](repeating: 0, count: frameBytes)
        var t = 0
        while let sample = output.copyNextSampleBuffer(), t < sourceFrameCount {
            guard let srcPB = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(srcPB, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(srcPB) {
                let srcBytesPerRow = CVPixelBufferGetBytesPerRow(srcPB)
                let src = base.bindMemory(to: UInt8.self, capacity: srcBytesPerRow * sourceHeight)
                compact.withUnsafeMutableBytes { raw in
                    guard let dstBase = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for y in 0..<sourceHeight {
                        let srcRow = src.advanced(by: y * srcBytesPerRow)
                        let dstRow = dstBase.advanced(by: y * sourceWidth * 4)
                        dstRow.update(from: srcRow, count: sourceWidth * 4)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(srcPB, .readOnly)

            let written = compact.withUnsafeBytes { raw -> Int in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return out.write(ptr, maxLength: frameBytes)
            }
            if written != frameBytes {
                throw VideoExportError.createReaderFailed("写入原始帧临时缓存失败")
            }
            t += 1
            if t % 32 == 0 || t == sourceFrameCount {
                progress(min(0.12, Double(t) / Double(max(1, sourceFrameCount)) * 0.12), routeText + "·准备原始帧缓存")
            }
        }
        if reader.status == .failed {
            throw VideoExportError.createReaderFailed(reader.error?.localizedDescription ?? "构建原始帧缓存失败")
        }

        return TempRawFrameCache(url: tempURL, width: sourceWidth, height: sourceHeight, frameCount: t, frameBytes: frameBytes)
    }

    static func prepareDistributedRawFrameCache(
        sourceURL: URL,
        outputURL: URL,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        progress: @escaping ExportProgressHandler
    ) throws -> URL {
        let expectedBytes = sourceWidth * sourceHeight * 4 * sourceFrameCount
        if
            FileManager.default.fileExists(atPath: outputURL.path),
            let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
            let size = attrs[.size] as? NSNumber,
            size.intValue >= expectedBytes
        {
            progress(1.0, "Worker raw cache 已就绪")
            return outputURL
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: sourceURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VideoExportError.createReaderFailed("找不到视频轨道")
        }

        let tempCache = try buildTempRawFrameCache(
            asset: asset,
            track: track,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceFrameCount: sourceFrameCount,
            progress: progress,
            routeText: "Worker 预热 raw cache",
            tempDirectory: outputURL.deletingLastPathComponent()
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: tempCache.url, to: outputURL)
        progress(1.0, "Worker raw cache 已建立")
        return outputURL
    }


    private static func mapRawFrameCache(_ cache: TempRawFrameCache) throws -> MappedRawFrameCache {
        do {
            let data = try Data(contentsOf: cache.url, options: [.mappedIfSafe])
            return MappedRawFrameCache(cache: cache, data: data)
        } catch {
            throw VideoExportError.createReaderFailed("映射原始帧临时缓存失败：\(error.localizedDescription)")
        }
    }

    private static func mappedRawFrameCache(
        _ cache: TempRawFrameCache,
        preparedRawCacheData: Data?
    ) throws -> MappedRawFrameCache {
        if let preparedRawCacheData {
            let expectedBytes = cache.frameBytes * cache.frameCount
            guard preparedRawCacheData.count >= expectedBytes else {
                throw VideoExportError.createReaderFailed("Worker SourceSession raw cache 数据不完整")
            }
            return MappedRawFrameCache(cache: cache, data: preparedRawCacheData)
        }

        return try mapRawFrameCache(cache)
    }

    private static func withMappedRawFrameChunk<R>(
        mapped: MappedRawFrameCache,
        startFrame: Int,
        count: Int,
        _ body: (UnsafeRawPointer) throws -> R
    ) throws -> R {
        let start = startFrame * mapped.cache.frameBytes
        let length = count * mapped.cache.frameBytes
        guard start >= 0, length >= 0, start + length <= mapped.data.count else {
            throw VideoExportError.createReaderFailed("访问原始帧临时缓存越界")
        }

        return try mapped.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw VideoExportError.createReaderFailed("原始帧临时缓存映射无效")
            }
            return try body(base.advanced(by: start))
        }
    }

    private static func readRawFrameChunk(
        handle: FileHandle,
        frameBytes: Int,
        startFrame: Int,
        count: Int
    ) throws -> Data {
        try handle.seek(toOffset: UInt64(startFrame * frameBytes))
        let need = count * frameBytes
        let data = handle.readData(ofLength: need)
        if data.count != need {
            throw VideoExportError.createReaderFailed("读取原始帧临时缓存失败")
        }
        return data
    }

    private static func makeBGRAReader(
        asset: AVURLAsset,
        track: AVAssetTrack
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw VideoExportError.createReaderFailed("reader 无法添加 track output")
        }
        reader.add(output)
        return (reader, output)
    }

    private static func finishWriter(_ writer: AVAssetWriter) throws {
        let sem = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            if writer.status != .completed {
                finishError = writer.error
            }
            sem.signal()
        }
        sem.wait()
        if let finishError {
            throw VideoExportError.finishFailed(finishError.localizedDescription)
        }
    }

    private static func makePixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard status == kCVReturnSuccess else { return nil }
        return pb
    }

    private static func estimateFrameCount(asset: AVURLAsset, track: AVAssetTrack) -> Int {
        let fps = track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 30.0
        let sec = CMTimeGetSeconds(asset.duration)
        if sec.isFinite, sec > 0 {
            return max(1, Int((sec * fps).rounded()))
        }
        return 1
    }

    private struct HighPrecisionGPUStageTiming {
        var upload: Double = 0
        var kernel: Double = 0
        var copy: Double = 0
        var appendWait: Double = 0
        var append: Double = 0
        var finish: Double = 0

        func summary() -> String {
            String(
                format: "upload %.1fs｜kernel %.1fs｜copy %.1fs｜append %.1fs｜finish %.1fs",
                upload,
                kernel,
                copy,
                appendWait + append,
                finish
            )
        }
    }

    private static func timed<T>(_ body: () throws -> T, addTo elapsed: inout Double) rethrows -> T {
        let start = Date()
        defer {
            elapsed += max(0.0, Date().timeIntervalSince(start))
        }
        return try body()
    }


    private static func exportHighPrecisionXGPU(
        asset: AVURLAsset,
        track: AVAssetTrack,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        request: VideoExportRequest,
        preparedRawCacheURL: URL? = nil,
        preparedRawCacheData: Data? = nil,
        progress: @escaping ExportProgressHandler
    ) throws {
        let contentW = sourceFrameCount
        let contentH = sourceHeight
        let outW = request.padToEven ? even(contentW) : contentW
        let outH = request.padToEven ? even(contentH) : contentH
        let preserveAlpha = request.preserveAlpha && request.useAlpha
        let routeText = preserveAlpha ? "高精度X轴原尺寸GPU重建（带 Alpha）" : "高精度X轴原尺寸GPU重建"

        progress(0.0, routeText)

        let assembler = try HighPrecisionXYGPUAssembler()
        let (writer, input, adaptor) = try createWriter(
            outputURL: request.url,
            width: outW,
            height: outH,
            preserveAlpha: preserveAlpha,
            bitDepth: request.bitDepth,
            colorProfile: request.colorProfile
        )
        let frameDuration = CMTime(seconds: 1.0 / max(0.05, request.fps), preferredTimescale: 600)

        let rawCache: TempRawFrameCache
        let shouldRemoveRawCache: Bool
        if let preparedRawCacheURL {
            rawCache = TempRawFrameCache(
                url: preparedRawCacheURL,
                width: sourceWidth,
                height: sourceHeight,
                frameCount: sourceFrameCount,
                frameBytes: sourceWidth * sourceHeight * 4
            )
            shouldRemoveRawCache = false
            progress(0.10, routeText + "·复用已预热 raw cache")
        } else {
            rawCache = try buildTempRawFrameCache(
                asset: asset,
                track: track,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                progress: progress,
                routeText: routeText,
                tempDirectory: request.url.deletingLastPathComponent()
            )
            shouldRemoveRawCache = true
        }
        defer {
            if shouldRemoveRawCache {
                try? FileManager.default.removeItem(at: rawCache.url)
            }
        }

        let mapped = try mappedRawFrameCache(rawCache, preparedRawCacheData: preparedRawCacheData)

        let bytesPerFrame = contentW * contentH * 4
        let batchSize = highPrecisionOutputBatchSize(
            bytesPerOutputFrame: bytesPerFrame,
            request: request,
            minimum: 24,
            maximum: 512
        )
        let frameChunkSize = 64
        let reusableTextures = try assembler.makeReusableSourceTexturePool(
            width: sourceWidth,
            height: sourceHeight,
            capacity: frameChunkSize
        )
        var stageTiming = HighPrecisionGPUStageTiming()

        let range = normalizedOutputRange(
            start: request.outputStartFrame,
            end: request.outputEndFrame,
            upperBound: sourceWidth - 1
        )
        guard range.end >= range.start else {
            throw VideoExportError.metalUnavailable("高精度X轴输出范围无效")
        }

        var batchStart = range.start
        while batchStart <= range.end {
            let desiredCount = min(batchSize, range.end - batchStart + 1)
            let (batchTexture, count) = try makeBatchTextureWithFallback(
                assembler: assembler,
                width: contentW,
                height: contentH,
                desiredSlices: desiredCount
            )

            var frameStart = 0
            while frameStart < sourceFrameCount {
                let fcount = min(frameChunkSize, sourceFrameCount - frameStart)

                var chunkFrames: [HighPrecisionXYGPUAssembler.SourceFrameTexture] = []
                chunkFrames.reserveCapacity(fcount)

                try withMappedRawFrameChunk(mapped: mapped, startFrame: frameStart, count: fcount) { basePtr in
                    timed({
                        for i in 0..<fcount {
                            let ptr = basePtr.advanced(by: i * rawCache.frameBytes)
                            let texture = reusableTextures[i]
                            assembler.uploadBGRABytes(ptr, to: texture, width: sourceWidth, height: sourceHeight)
                            chunkFrames.append(HighPrecisionXYGPUAssembler.SourceFrameTexture(texture: texture, backing: nil))
                        }
                    }, addTo: &stageTiming.upload)
                }

                try timed({
                    try assembler.encodeXChunk(
                        sourceFrames: chunkFrames,
                        outputTexture: batchTexture,
                        batchStart: batchStart,
                        frameStartIndex: frameStart,
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight,
                        useAlpha: request.useAlpha,
                        preserveAlpha: preserveAlpha,
                        checkerboard: request.showCheckerboard && request.useAlpha && !preserveAlpha
                    )
                }, addTo: &stageTiming.kernel)
                frameStart += fcount
            }

            for local in 0..<count {
                timed({
                    while !input.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.0005)
                    }
                }, addTo: &stageTiming.appendWait)

                guard let dstPB = makePixelBuffer(from: adaptor) else {
                    throw VideoExportError.createPixelBufferFailed
                }

                if outW != contentW || outH != contentH {
                    clearPixelBuffer(dstPB)
                }

                let destination = try timed({
                    try assembler.makeDestinationPixelBufferTexture(dstPB)
                }, addTo: &stageTiming.copy)
                try timed({
                    try assembler.copySingleSliceToPixelBuffer(
                        batchTexture: batchTexture,
                        slice: local,
                        destination: destination,
                        contentWidth: contentW,
                        contentHeight: contentH
                    )
                }, addTo: &stageTiming.copy)

                let outIndex = batchStart + local
                let time = localPresentationTime(
                    globalIndex: outIndex,
                    segmentStart: range.start,
                    frameDuration: frameDuration
                )
                try timed({
                    if !adaptor.append(dstPB, withPresentationTime: time) {
                        throw VideoExportError.appendFailed(writer.error?.localizedDescription ?? "append 失败")
                    }
                }, addTo: &stageTiming.append)
            }

            batchStart += count
            let done = batchStart - range.start
            let total = max(1, range.end - range.start + 1)
            let p = 0.10 + (Double(done) / Double(total)) * 0.90
            progress(min(1.0, p), routeText + "｜" + stageTiming.summary())
        }

        input.markAsFinished()
        try timed({
            try finishWriter(writer)
        }, addTo: &stageTiming.finish)
        progress(1.0, routeText + "｜" + stageTiming.summary())
    }

    private static func exportHighPrecisionYGPU(
        asset: AVURLAsset,
        track: AVAssetTrack,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        request: VideoExportRequest,
        preparedRawCacheURL: URL? = nil,
        preparedRawCacheData: Data? = nil,
        progress: @escaping ExportProgressHandler
    ) throws {
        let contentW = sourceWidth
        let contentH = sourceFrameCount
        let outW = request.padToEven ? even(contentW) : contentW
        let outH = request.padToEven ? even(contentH) : contentH
        let preserveAlpha = request.preserveAlpha && request.useAlpha
        let routeText = preserveAlpha ? "高精度Y轴原尺寸GPU重建（带 Alpha）" : "高精度Y轴原尺寸GPU重建"

        progress(0.0, routeText)

        let assembler = try HighPrecisionXYGPUAssembler()
        let (writer, input, adaptor) = try createWriter(
            outputURL: request.url,
            width: outW,
            height: outH,
            preserveAlpha: preserveAlpha,
            bitDepth: request.bitDepth,
            colorProfile: request.colorProfile
        )
        let frameDuration = CMTime(seconds: 1.0 / max(0.05, request.fps), preferredTimescale: 600)

        let rawCache: TempRawFrameCache
        let shouldRemoveRawCache: Bool
        if let preparedRawCacheURL {
            rawCache = TempRawFrameCache(
                url: preparedRawCacheURL,
                width: sourceWidth,
                height: sourceHeight,
                frameCount: sourceFrameCount,
                frameBytes: sourceWidth * sourceHeight * 4
            )
            shouldRemoveRawCache = false
            progress(0.10, routeText + "·复用已预热 raw cache")
        } else {
            rawCache = try buildTempRawFrameCache(
                asset: asset,
                track: track,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                progress: progress,
                routeText: routeText,
                tempDirectory: request.url.deletingLastPathComponent()
            )
            shouldRemoveRawCache = true
        }
        defer {
            if shouldRemoveRawCache {
                try? FileManager.default.removeItem(at: rawCache.url)
            }
        }

        let mapped = try mappedRawFrameCache(rawCache, preparedRawCacheData: preparedRawCacheData)

        let bytesPerFrame = contentW * contentH * 4
        let batchSize = highPrecisionOutputBatchSize(
            bytesPerOutputFrame: bytesPerFrame,
            request: request,
            minimum: 20,
            maximum: 512
        )
        let frameChunkSize = 64
        let reusableTextures = try assembler.makeReusableSourceTexturePool(
            width: sourceWidth,
            height: sourceHeight,
            capacity: frameChunkSize
        )
        var stageTiming = HighPrecisionGPUStageTiming()

        let range = normalizedOutputRange(
            start: request.outputStartFrame,
            end: request.outputEndFrame,
            upperBound: sourceHeight - 1
        )
        guard range.end >= range.start else {
            throw VideoExportError.metalUnavailable("高精度Y轴输出范围无效")
        }

        var batchStart = range.start
        while batchStart <= range.end {
            let desiredCount = min(batchSize, range.end - batchStart + 1)
            let (batchTexture, count) = try makeBatchTextureWithFallback(
                assembler: assembler,
                width: contentW,
                height: contentH,
                desiredSlices: desiredCount
            )

            var frameStart = 0
            while frameStart < sourceFrameCount {
                let fcount = min(frameChunkSize, sourceFrameCount - frameStart)

                var chunkFrames: [HighPrecisionXYGPUAssembler.SourceFrameTexture] = []
                chunkFrames.reserveCapacity(fcount)

                try withMappedRawFrameChunk(mapped: mapped, startFrame: frameStart, count: fcount) { basePtr in
                    timed({
                        for i in 0..<fcount {
                            let ptr = basePtr.advanced(by: i * rawCache.frameBytes)
                            let texture = reusableTextures[i]
                            assembler.uploadBGRABytes(ptr, to: texture, width: sourceWidth, height: sourceHeight)
                            chunkFrames.append(HighPrecisionXYGPUAssembler.SourceFrameTexture(texture: texture, backing: nil))
                        }
                    }, addTo: &stageTiming.upload)
                }

                try timed({
                    try assembler.encodeYChunk(
                        sourceFrames: chunkFrames,
                        outputTexture: batchTexture,
                        batchStart: batchStart,
                        frameStartIndex: frameStart,
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight,
                        useAlpha: request.useAlpha,
                        preserveAlpha: preserveAlpha,
                        checkerboard: request.showCheckerboard && request.useAlpha && !preserveAlpha
                    )
                }, addTo: &stageTiming.kernel)
                frameStart += fcount
            }

            for local in 0..<count {
                timed({
                    while !input.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.0005)
                    }
                }, addTo: &stageTiming.appendWait)

                guard let dstPB = makePixelBuffer(from: adaptor) else {
                    throw VideoExportError.createPixelBufferFailed
                }

                if outW != contentW || outH != contentH {
                    clearPixelBuffer(dstPB)
                }

                let destination = try timed({
                    try assembler.makeDestinationPixelBufferTexture(dstPB)
                }, addTo: &stageTiming.copy)
                try timed({
                    try assembler.copySingleSliceToPixelBuffer(
                        batchTexture: batchTexture,
                        slice: local,
                        destination: destination,
                        contentWidth: contentW,
                        contentHeight: contentH
                    )
                }, addTo: &stageTiming.copy)

                let outIndex = batchStart + local
                let time = localPresentationTime(
                    globalIndex: outIndex,
                    segmentStart: range.start,
                    frameDuration: frameDuration
                )
                try timed({
                    if !adaptor.append(dstPB, withPresentationTime: time) {
                        throw VideoExportError.appendFailed(writer.error?.localizedDescription ?? "append 失败")
                    }
                }, addTo: &stageTiming.append)
            }

            batchStart += count
            let done = batchStart - range.start
            let total = max(1, range.end - range.start + 1)
            let p = 0.10 + (Double(done) / Double(total)) * 0.90
            progress(min(1.0, p), routeText + "｜" + stageTiming.summary())
        }

        input.markAsFinished()
        try timed({
            try finishWriter(writer)
        }, addTo: &stageTiming.finish)
        progress(1.0, routeText + "｜" + stageTiming.summary())
    }

    private static func recommendedBatchSize(bytesPerOutputFrame: Int) -> Int {
        let targetBytes = 320 * 1024 * 1024
        let count = max(1, targetBytes / max(1, bytesPerOutputFrame))
        return min(64, count)
    }

    private static func highPrecisionOutputBatchSize(
        bytesPerOutputFrame: Int,
        request: VideoExportRequest,
        minimum: Int,
        maximum: Int
    ) -> Int {
        guard let budget = request.highPrecisionBatchByteBudget else {
            return min(max(recommendedBatchSize(bytesPerOutputFrame: bytesPerOutputFrame), minimum), maximum)
        }

        let count = max(1, budget / max(1, bytesPerOutputFrame))
        return min(max(count, minimum), maximum)
    }

    private static func makeBatchTextureWithFallback(
        assembler: HighPrecisionXYGPUAssembler,
        width: Int,
        height: Int,
        desiredSlices: Int
    ) throws -> (MTLTexture, Int) {
        var slices = max(1, desiredSlices)
        var lastError: Error?

        while slices >= 1 {
            do {
                return (try assembler.makeBatchTexture(width: width, height: height, slices: slices), slices)
            } catch {
                lastError = error
                if slices == 1 { break }
                slices = max(1, slices / 2)
            }
        }

        if let lastError {
            throw lastError
        }
        throw VideoExportError.metalUnavailable("无法创建高精度批次纹理")
    }

    private static func copyPixelBuffer(
        src: CVPixelBuffer,
        dst: CVPixelBuffer,
        dstWidth: Int,
        dstHeight: Int,
        preserveAlpha: Bool,
        useAlpha: Bool,
        checkerboard: Bool
    ) {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else { return }

        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        let srcBpr = CVPixelBufferGetBytesPerRow(src)
        let dstBpr = CVPixelBufferGetBytesPerRow(dst)

        let srcPtr = srcBase.bindMemory(to: UInt8.self, capacity: srcBpr * srcH)
        let dstPtr = dstBase.bindMemory(to: UInt8.self, capacity: dstBpr * dstHeight)

        for y in 0..<dstHeight {
            let dstRow = dstPtr.advanced(by: y * dstBpr)
            for i in 0..<dstBpr { dstRow[i] = 0 }
        }

        let copyW = min(srcW, dstWidth)
        let copyH = min(srcH, dstHeight)

        for y in 0..<copyH {
            let srcRow = srcPtr.advanced(by: y * srcBpr)
            let dstRow = dstPtr.advanced(by: y * dstBpr)
            for x in 0..<copyW {
                let s = srcRow.advanced(by: x * 4)
                let d = x * 4
                var temp = [UInt8](repeating: 0, count: 4)
                writeConvertedBGRA(
                    into: &temp,
                    at: 0,
                    srcB: s[0], srcG: s[1], srcR: s[2], srcA: s[3],
                    preserveAlpha: preserveAlpha,
                    useAlpha: useAlpha,
                    checkerboard: checkerboard,
                    checkerX: x,
                    checkerY: y
                )
                dstRow[d] = temp[0]
                dstRow[d + 1] = temp[1]
                dstRow[d + 2] = temp[2]
                dstRow[d + 3] = temp[3]
            }
        }
    }

    private static func clearPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        memset(base, 0, bytesPerRow * height)
    }

    private static func fillPixelBufferFromBGRA(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        bgra: [UInt8],
        bgraOffset: Int,
        srcWidth: Int,
        srcHeight: Int
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dst = base.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        for y in 0..<height {
            let row = dst.advanced(by: y * bytesPerRow)
            for i in 0..<bytesPerRow { row[i] = 0 }
        }

        let copyRows = min(srcHeight, height)
        let copyColsBytes = min(srcWidth, width) * 4

        for y in 0..<copyRows {
            let srcRowStart = bgraOffset + y * srcWidth * 4
            let dstRow = dst.advanced(by: y * bytesPerRow)
            bgra.withUnsafeBytes { raw in
                let srcBase = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: srcRowStart)
                memcpy(dstRow, srcBase, copyColsBytes)
            }
        }
    }

    private static func writeConvertedBGRA(
        into out: inout [UInt8],
        at dst: Int,
        srcB: UInt8,
        srcG: UInt8,
        srcR: UInt8,
        srcA: UInt8,
        preserveAlpha: Bool,
        useAlpha: Bool,
        checkerboard: Bool,
        checkerX: Int,
        checkerY: Int
    ) {
        if preserveAlpha {
            out[dst] = srcB
            out[dst + 1] = srcG
            out[dst + 2] = srcR
            out[dst + 3] = srcA
            return
        }

        if !useAlpha {
            out[dst] = srcB
            out[dst + 1] = srcG
            out[dst + 2] = srcR
            out[dst + 3] = 255
            return
        }

        let alpha = Float(srcA) / 255.0
        if checkerboard {
            let tile = 12
            let isDark = ((checkerX / tile) + (checkerY / tile)) % 2 == 0
            let bg: UInt8 = isDark ? 180 : 235

            out[dst] = UInt8(Float(bg) * (1 - alpha) + Float(srcB) * alpha)
            out[dst + 1] = UInt8(Float(bg) * (1 - alpha) + Float(srcG) * alpha)
            out[dst + 2] = UInt8(Float(bg) * (1 - alpha) + Float(srcR) * alpha)
            out[dst + 3] = 255
        } else {
            out[dst] = UInt8(Float(srcB) * alpha)
            out[dst + 1] = UInt8(Float(srcG) * alpha)
            out[dst + 2] = UInt8(Float(srcR) * alpha)
            out[dst + 3] = 255
        }
    }

    private static func even(_ value: Int) -> Int {
        value % 2 == 0 ? value : value + 1
    }

    private static func buildAxisExportCache(volume: CPUVolume, request: VideoExportRequest) -> AxisExportCache {
        AxisExportCache(
            outWidth: request.width,
            outHeight: request.height,
            xMap: sampleCoordMap(outCount: request.width, srcCount: volume.width),
            yMap: sampleCoordMap(outCount: request.height, srcCount: volume.height),
            tMapX: sampleCoordMap(outCount: request.width, srcCount: volume.depth),
            tMapY: sampleCoordMap(outCount: request.height, srcCount: volume.depth)
        )
    }

    private static func buildPlaneExportCache(volume: CPUVolume, request: VideoExportRequest) -> PlaneExportCache {
        let g = volume.planeGeometry(for: request.referencePlane)
        let basis = correctedBasis(g)
        let outW = request.width
        let outH = request.height

        var baseCentered = [SIMD3<Float>](repeating: .zero, count: outW * outH)
        for j in 0..<outH {
            let fv = g.vMin + (Float(j) + 0.5) / Float(outH) * (g.vMax - g.vMin)
            for i in 0..<outW {
                let fu = g.uMin + (Float(i) + 0.5) / Float(outW) * (g.uMax - g.uMin)
                baseCentered[j * outW + i] = basis.u * fu + basis.v * fv
            }
        }

        let sliceCount = max(1, g.sliceCount)
        let dBase: Float
        let dStep: Float
        if sliceCount == 1 {
            dBase = (g.nMin + g.nMax) * 0.5
            dStep = 0
        } else {
            dBase = g.nMin
            dStep = (g.nMax - g.nMin) / Float(sliceCount - 1)
        }

        return PlaneExportCache(
            outWidth: outW,
            outHeight: outH,
            baseCentered: baseCentered,
            n: basis.n,
            dBase: dBase,
            dStep: dStep
        )
    }

    private static func buildMeshSliceCache(mesh: LoadedMesh, volume: CPUVolume, request: VideoExportRequest) -> MeshSliceCache? {
        guard mesh.vertices.count >= 3 else { return nil }

        let volumeExtent = SIMD3<Float>(
            Float(max(1, volume.width - 1)),
            Float(max(1, volume.height - 1)),
            Float(max(1, volume.depth - 1))
        )

        var triangles: [MeshExportTriangle] = []
        triangles.reserveCapacity(mesh.vertices.count / 3)
        var index = 0
        while index + 2 < mesh.vertices.count {
            let a = mesh.vertices[index].position * volumeExtent
            let b = mesh.vertices[index + 1].position * volumeExtent
            let c = mesh.vertices[index + 2].position * volumeExtent
            let normal = normalizedOrDefault(simd_cross(b - a, c - a), fallback: mesh.vertices[index].normal)
            if simd_length_squared(b - a) > 0.000_001,
               simd_length_squared(c - a) > 0.000_001 {
                triangles.append(MeshExportTriangle(a: a, b: b, c: c, normal: normal))
            }
            index += 3
        }
        guard !triangles.isEmpty else { return nil }

        let halfX = Float(volume.width - 1) * 0.5
        let halfY = Float(volume.height - 1) * 0.5
        let halfT = Float(volume.depth - 1) * 0.5
        let outputSliceCount = max(1, request.frameCount)

        func sliceRange(_ minD: Float, _ maxD: Float) -> (base: Float, step: Float) {
            if outputSliceCount == 1 {
                return ((minD + maxD) * 0.5, 0)
            }
            return (minD, (maxD - minD) / Float(outputSliceCount - 1))
        }

        let u: SIMD3<Float>
        let v: SIMD3<Float>
        let n: SIMD3<Float>
        let uMin: Float
        let uMax: Float
        let vMin: Float
        let vMax: Float
        let dBase: Float
        let dStep: Float

        switch request.mode {
        case .axis:
            switch request.axis {
            case .t:
                u = SIMD3<Float>(1, 0, 0)
                v = SIMD3<Float>(0, 1, 0)
                n = SIMD3<Float>(0, 0, 1)
                uMin = -halfX
                uMax = halfX
                vMin = -halfY
                vMax = halfY
                let range = sliceRange(-halfT, halfT)
                dBase = range.base
                dStep = range.step
            case .x:
                u = SIMD3<Float>(0, 0, 1)
                v = SIMD3<Float>(0, 1, 0)
                n = SIMD3<Float>(1, 0, 0)
                uMin = -halfT
                uMax = halfT
                vMin = -halfY
                vMax = halfY
                let range = sliceRange(-halfX, halfX)
                dBase = range.base
                dStep = range.step
            case .y:
                u = SIMD3<Float>(1, 0, 0)
                v = SIMD3<Float>(0, 0, 1)
                n = SIMD3<Float>(0, 1, 0)
                uMin = -halfX
                uMax = halfX
                vMin = -halfT
                vMax = halfT
                let range = sliceRange(-halfY, halfY)
                dBase = range.base
                dStep = range.step
            }
        case .plane:
            let g = volume.planeGeometry(for: request.referencePlane)
            let basis = correctedBasis(g)
            u = basis.u
            v = basis.v
            n = basis.n
            uMin = g.uMin
            uMax = g.uMax
            vMin = g.vMin
            vMax = g.vMax

            let range = sliceRange(g.nMin, g.nMax)
            dBase = range.base
            dStep = range.step
        }

        guard uMax > uMin, vMax > vMin else { return nil }
        let trianglePlaneRanges = triangles.map { triangle -> (min: Float, max: Float) in
            let da = simd_dot(triangle.a, n)
            let db = simd_dot(triangle.b, n)
            let dc = simd_dot(triangle.c, n)
            return (min(da, db, dc), max(da, db, dc))
        }

        return MeshSliceCache(
            outWidth: max(1, request.width),
            outHeight: max(1, request.height),
            triangles: triangles,
            trianglePlaneRanges: trianglePlaneRanges,
            u: u,
            v: v,
            n: n,
            uMin: uMin,
            uMax: uMax,
            vMin: vMin,
            vMax: vMax,
            dBase: dBase,
            dStep: dStep
        )
    }

    private static func sourcePlaneGeometry(
        width: Int,
        height: Int,
        depth: Int,
        referencePlane: ReferencePlaneState,
        maxLongSide: Int = Int.max
    ) -> PlaneGeometry {
        let halfX = Float(width - 1) * 0.5
        let halfY = Float(height - 1) * 0.5
        let halfT = Float(depth - 1) * 0.5
        let u = referencePlane.uAxis
        let v = referencePlane.vAxis
        let n = referencePlane.normalAxis
        let corners: [SIMD3<Float>] = [
            SIMD3(-halfX, -halfY, -halfT),
            SIMD3( halfX, -halfY, -halfT),
            SIMD3(-halfX,  halfY, -halfT),
            SIMD3( halfX,  halfY, -halfT),
            SIMD3(-halfX, -halfY,  halfT),
            SIMD3( halfX, -halfY,  halfT),
            SIMD3(-halfX,  halfY,  halfT),
            SIMD3( halfX,  halfY,  halfT)
        ]

        var uMin = Float.greatestFiniteMagnitude
        var uMax = -Float.greatestFiniteMagnitude
        var vMin = Float.greatestFiniteMagnitude
        var vMax = -Float.greatestFiniteMagnitude
        var nMin = Float.greatestFiniteMagnitude
        var nMax = -Float.greatestFiniteMagnitude

        for c in corners {
            let pu = simd_dot(c, u)
            let pv = simd_dot(c, v)
            let pn = simd_dot(c, n)
            uMin = min(uMin, pu)
            uMax = max(uMax, pu)
            vMin = min(vMin, pv)
            vMax = max(vMax, pv)
            nMin = min(nMin, pn)
            nMax = max(nMax, pn)
        }

        let fullW = max(1, Int(ceil(uMax - uMin)))
        let fullH = max(1, Int(ceil(vMax - vMin)))
        let fullSlices = max(1, Int(ceil(nMax - nMin)))
        let longSide = max(fullW, fullH)
        let scale = longSide > maxLongSide ? Float(maxLongSide) / Float(longSide) : 1.0

        return PlaneGeometry(
            u: u,
            v: v,
            n: n,
            uMin: uMin,
            uMax: uMax,
            vMin: vMin,
            vMax: vMax,
            nMin: nMin,
            nMax: nMax,
            outWidth: max(1, Int(round(Float(fullW) * scale))),
            outHeight: max(1, Int(round(Float(fullH) * scale))),
            sliceCount: fullSlices
        )
    }

    private static func rawPlaneSliceCount(
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        referencePlane: ReferencePlaneState
    ) -> Int {
        sourcePlaneGeometry(
            width: sourceWidth,
            height: sourceHeight,
            depth: sourceFrameCount,
            referencePlane: referencePlane
        ).sliceCount
    }

    static func highPrecisionPlaneOutputMetrics(
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        referencePlane: ReferencePlaneState,
        qualityScale: Double = 1.0,
        padToEven: Bool = true
    ) -> (width: Int, height: Int, sliceCount: Int) {
        let g = sourcePlaneGeometry(
            width: sourceWidth,
            height: sourceHeight,
            depth: sourceFrameCount,
            referencePlane: referencePlane
        )
        return (
            scaledDistributedDimension(g.outWidth, qualityScale: qualityScale, padToEven: padToEven),
            scaledDistributedDimension(g.outHeight, qualityScale: qualityScale, padToEven: padToEven),
            scaledPlaneSliceCount(g.sliceCount, qualityScale: qualityScale)
        )
    }

    private static func scaledPlaneSliceCount(_ value: Int, qualityScale: Double) -> Int {
        let scale = min(1.0, max(0.05, qualityScale))
        return max(1, Int((Double(value) * scale).rounded()))
    }

    private static func buildRawPlaneExportCache(
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        request: VideoExportRequest
    ) -> RawPlaneExportCache {
        let g = sourcePlaneGeometry(
            width: sourceWidth,
            height: sourceHeight,
            depth: sourceFrameCount,
            referencePlane: request.referencePlane
        )
        let basis = correctedBasis(g)
        let outW = max(1, request.width)
        let outH = max(1, request.height)
        let inferredQualityScale = min(
            1.0,
            max(
                0.05,
                min(
                    Double(outW) / Double(max(1, g.outWidth)),
                    Double(outH) / Double(max(1, g.outHeight))
                )
            )
        )

        var baseCentered = [SIMD3<Float>](repeating: .zero, count: outW * outH)
        for j in 0..<outH {
            let fv = g.vMin + (Float(j) + 0.5) / Float(outH) * (g.vMax - g.vMin)
            for i in 0..<outW {
                let fu = g.uMin + (Float(i) + 0.5) / Float(outW) * (g.uMax - g.uMin)
                baseCentered[j * outW + i] = basis.u * fu + basis.v * fv
            }
        }

        let sliceCount = scaledPlaneSliceCount(g.sliceCount, qualityScale: inferredQualityScale)
        let dBase: Float
        let dStep: Float
        if sliceCount == 1 {
            dBase = (g.nMin + g.nMax) * 0.5
            dStep = 0
        } else {
            dBase = g.nMin
            dStep = (g.nMax - g.nMin) / Float(sliceCount - 1)
        }

        return RawPlaneExportCache(
            outWidth: outW,
            outHeight: outH,
            sliceCount: sliceCount,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceDepth: sourceFrameCount,
            frameBytes: sourceWidth * sourceHeight * 4,
            baseCentered: baseCentered,
            u: basis.u,
            v: basis.v,
            n: basis.n,
            uMin: g.uMin,
            uMax: g.uMax,
            vMin: g.vMin,
            vMax: g.vMax,
            dBase: dBase,
            dStep: dStep
        )
    }

    private static func buildPlaneUniforms(
        volume: CPUVolume,
        request: VideoExportRequest,
        frameIndex: Int,
        preserveAlpha: Bool
    ) -> PlaneSliceUniforms {
        let g = volume.planeGeometry(for: request.referencePlane)
        let basis = correctedBasis(g)
        let sliceCount = max(1, g.sliceCount)
        let sliceIndex = max(0, min(frameIndex, sliceCount - 1))

        let d: Float
        if sliceCount == 1 {
            d = (g.nMin + g.nMax) * 0.5
        } else {
            d = g.nMin + (g.nMax - g.nMin) * (Float(sliceIndex) / Float(sliceCount - 1))
        }

        return PlaneSliceUniforms(
            outWidth: UInt32(request.width),
            outHeight: UInt32(request.height),
            useAlpha: request.useAlpha ? 1 : 0,
            showCheckerboard: (request.showCheckerboard && request.useAlpha && !preserveAlpha) ? 1 : 0,
            fastPreview: 0,
            volumeWidth: UInt32(volume.width),
            volumeHeight: UInt32(volume.height),
            volumeDepth: UInt32(volume.depth),
            contentX: 0,
            contentY: 0,
            contentW: Float(request.width),
            contentH: Float(request.height),
            u: basis.u,
            v: basis.v,
            n: basis.n,
            d: d,
            uMin: g.uMin,
            uMax: g.uMax,
            vMin: g.vMin,
            vMax: g.vMax
        )
    }

    private static func fillPixelBufferFromRGBA(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        rgba: [UInt8],
        srcWidth: Int,
        srcHeight: Int,
        keepAlpha: Bool
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dst = base.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        for y in 0..<height {
            let row = dst.advanced(by: y * bytesPerRow)
            row.initialize(repeating: 0, count: bytesPerRow)
        }

        for y in 0..<min(srcHeight, height) {
            let srcRow = y * srcWidth * 4
            let dstRow = dst.advanced(by: y * bytesPerRow)
            for x in 0..<min(srcWidth, width) {
                let s = srcRow + x * 4
                let d = x * 4
                dstRow[d] = rgba[s + 2]
                dstRow[d + 1] = rgba[s + 1]
                dstRow[d + 2] = rgba[s]
                dstRow[d + 3] = keepAlpha ? rgba[s + 3] : 255
            }
        }
    }

    private static func sampleCoordMap(outCount: Int, srcCount: Int) -> [Int] {
        guard outCount > 0 else { return [] }
        if srcCount <= 1 { return Array(repeating: 0, count: outCount) }
        if outCount == 1 { return [0] }

        return (0..<outCount).map { i in
            let x = (Float(i) + 0.5) / Float(outCount) * Float(srcCount)
            return max(0, min(srcCount - 1, Int(floor(x))))
        }
    }

    private static func downsampleRGBA(
        _ src: [UInt8],
        srcWidth: Int,
        srcHeight: Int,
        dstWidth: Int,
        dstHeight: Int,
        scale: Int
    ) -> [UInt8] {
        guard scale > 1, srcWidth >= dstWidth, srcHeight >= dstHeight else { return src }

        var dst = [UInt8](repeating: 0, count: dstWidth * dstHeight * 4)
        let sampleCount = max(1, scale * scale)

        src.withUnsafeBufferPointer { srcBuffer in
            guard let srcBase = srcBuffer.baseAddress else { return }
            dst.withUnsafeMutableBufferPointer { dstBuffer in
                guard let dstBase = dstBuffer.baseAddress else { return }
                if dstWidth * dstHeight < 120_000 || dstHeight < 2 {
                    for y in 0..<dstHeight {
                        downsampleRGBARow(
                            srcBase: srcBase,
                            srcWidth: srcWidth,
                            srcHeight: srcHeight,
                            dstBase: dstBase,
                            dstWidth: dstWidth,
                            y: y,
                            scale: scale,
                            sampleCount: sampleCount
                        )
                    }
                } else {
                    DispatchQueue.concurrentPerform(iterations: dstHeight) { y in
                        downsampleRGBARow(
                            srcBase: srcBase,
                            srcWidth: srcWidth,
                            srcHeight: srcHeight,
                            dstBase: dstBase,
                            dstWidth: dstWidth,
                            y: y,
                            scale: scale,
                            sampleCount: sampleCount
                        )
                    }
                }
            }
        }

        return dst
    }

    private static func downsampleRGBARow(
        srcBase: UnsafePointer<UInt8>,
        srcWidth: Int,
        srcHeight: Int,
        dstBase: UnsafeMutablePointer<UInt8>,
        dstWidth: Int,
        y: Int,
        scale: Int,
        sampleCount: Int
    ) {
        for x in 0..<dstWidth {
            var r = 0
            var g = 0
            var b = 0
            var a = 0

            for sy in 0..<scale {
                let sourceY = min(srcHeight - 1, y * scale + sy)
                for sx in 0..<scale {
                    let sourceX = min(srcWidth - 1, x * scale + sx)
                    let s = (sourceY * srcWidth + sourceX) * 4
                    r += Int(srcBase[s])
                    g += Int(srcBase[s + 1])
                    b += Int(srcBase[s + 2])
                    a += Int(srcBase[s + 3])
                }
            }

            let d = (y * dstWidth + x) * 4
            dstBase[d] = UInt8(clamping: (r + sampleCount / 2) / sampleCount)
            dstBase[d + 1] = UInt8(clamping: (g + sampleCount / 2) / sampleCount)
            dstBase[d + 2] = UInt8(clamping: (b + sampleCount / 2) / sampleCount)
            dstBase[d + 3] = UInt8(clamping: (a + sampleCount / 2) / sampleCount)
        }
    }

    private static func fillCheckerboardRGBA(into out: inout [UInt8], width: Int, height: Int) {
        let tile = 12
        out.withUnsafeMutableBufferPointer { outBuffer in
            guard let outBase = outBuffer.baseAddress else { return }
            let renderRow: (Int) -> Void = { y in
                for x in 0..<width {
                    let isDark = ((x / tile) + (y / tile)) % 2 == 0
                    let bg: UInt8 = isDark ? 180 : 235
                    let dst = (y * width + x) * 4
                    outBase[dst] = bg
                    outBase[dst + 1] = bg
                    outBase[dst + 2] = bg
                    outBase[dst + 3] = 255
                }
            }
            if width * height < 120_000 || height < 2 {
                for y in 0..<height {
                    renderRow(y)
                }
            } else {
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    renderRow(y)
                }
            }
        }
    }

    private static func renderMeshSliceRGBA(
        cache: MeshSliceCache,
        request: VideoExportRequest,
        frameIndex: Int,
        preserveAlpha: Bool,
        intersector: MeshSliceGPUIntersector?
    ) -> [UInt8] {
        let scale = max(1, min(3, request.meshSupersampleScale))
        guard scale > 1 else {
            return renderMeshSliceRasterRGBA(
                cache: cache,
                request: request,
                frameIndex: frameIndex,
                preserveAlpha: preserveAlpha,
                intersector: intersector
            )
        }

        let highCache = MeshSliceCache(
            outWidth: max(1, cache.outWidth * scale),
            outHeight: max(1, cache.outHeight * scale),
            triangles: cache.triangles,
            trianglePlaneRanges: cache.trianglePlaneRanges,
            u: cache.u,
            v: cache.v,
            n: cache.n,
            uMin: cache.uMin,
            uMax: cache.uMax,
            vMin: cache.vMin,
            vMax: cache.vMax,
            dBase: cache.dBase,
            dStep: cache.dStep
        )

        let highRGBA = renderMeshSliceRasterRGBA(
            cache: highCache,
            request: request,
            frameIndex: frameIndex,
            preserveAlpha: preserveAlpha,
            intersector: intersector
        )

        return downsampleRGBA(
            highRGBA,
            srcWidth: highCache.outWidth,
            srcHeight: highCache.outHeight,
            dstWidth: cache.outWidth,
            dstHeight: cache.outHeight,
            scale: scale
        )
    }

    private static func renderMeshSliceRasterRGBA(
        cache: MeshSliceCache,
        request: VideoExportRequest,
        frameIndex: Int,
        preserveAlpha: Bool,
        intersector: MeshSliceGPUIntersector?
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cache.outWidth * cache.outHeight * 4)
        let d = cache.dBase + Float(frameIndex) * cache.dStep
        let segments = meshSliceSegments(cache: cache, d: d, intersector: intersector)
        let blendChecker = request.showCheckerboard && request.useAlpha && !preserveAlpha
        if blendChecker {
            fillCheckerboardRGBA(into: &out, width: cache.outWidth, height: cache.outHeight)
        }
        guard !segments.isEmpty else { return out }

        let rowHits = buildMeshRowHits(cache: cache, segments: segments)

        out.withUnsafeMutableBufferPointer { outBuffer in
            guard let outBase = outBuffer.baseAddress else { return }
            let renderRow: (Int) -> Void = { y in
                renderMeshSliceRasterRow(
                    y: y,
                    rowHits: rowHits[y],
                    outBase: outBase,
                    outWidth: cache.outWidth,
                    blendChecker: blendChecker,
                    preserveAlpha: preserveAlpha
                )
            }
            if cache.outWidth * cache.outHeight < 120_000 || cache.outHeight < 2 {
                for y in 0..<cache.outHeight {
                    renderRow(y)
                }
            } else {
                DispatchQueue.concurrentPerform(iterations: cache.outHeight) { y in
                    renderRow(y)
                }
            }
        }

        return out
    }

    private static func renderMeshSliceRasterRow(
        y: Int,
        rowHits: [(x: Float, shade: Float)],
        outBase: UnsafeMutablePointer<UInt8>,
        outWidth: Int,
        blendChecker: Bool,
        preserveAlpha: Bool
    ) {
        guard !rowHits.isEmpty else { return }
        var hits = rowHits.sorted { $0.x < $1.x }
        hits = compactMeshRowHits(hits)
        guard hits.count >= 2 else { return }

        var hitIndex = 0
        while hitIndex + 1 < hits.count {
            let left = hits[hitIndex]
            let right = hits[hitIndex + 1]
            let x0 = min(left.x, right.x)
            let x1 = max(left.x, right.x)
            let start = max(0, Int(ceil(x0)))
            let end = min(outWidth, Int(floor(x1)))
            if start < end {
                let shade = UInt8(max(150, min(255, Int(((left.shade + right.shade) * 0.5 * 255).rounded()))))
                let blue = UInt8(clamping: Int(shade) + 6)
                for x in start..<end {
                    let dst = (y * outWidth + x) * 4
                    writePixel(
                        into: outBase,
                        at: dst,
                        x: x,
                        y: y,
                        r: shade,
                        g: shade,
                        b: blue,
                        a: 255,
                        checkerboard: blendChecker,
                        preserveAlpha: preserveAlpha
                    )
                }
            }
            hitIndex += 2
        }
    }

    private static func buildMeshRowHits(
        cache: MeshSliceCache,
        segments: [MeshSliceSegment]
    ) -> [[(x: Float, shade: Float)]] {
        let height = cache.outHeight
        let segmentCount = segments.count
        let workerCount = min(
            max(1, ProcessInfo.processInfo.activeProcessorCount),
            max(1, segmentCount / 700)
        )

        let uSpan = max(0.000_001, cache.uMax - cache.uMin)
        let vSpan = max(0.000_001, cache.vMax - cache.vMin)

        guard workerCount > 1 else {
            var rowHits = Array(repeating: [(x: Float, shade: Float)](), count: height)
            for segment in segments {
                appendMeshSegmentHits(
                    segment,
                    cache: cache,
                    uSpan: uSpan,
                    vSpan: vSpan,
                    rowHits: &rowHits
                )
            }
            return rowHits
        }

        let chunkSize = max(1, (segmentCount + workerCount - 1) / workerCount)
        var partials = Array(repeating: [[(x: Float, shade: Float)]](), count: workerCount)
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
            let start = workerIndex * chunkSize
            let end = min(segmentCount, start + chunkSize)
            guard start < end else { return }

            var local = Array(repeating: [(x: Float, shade: Float)](), count: height)
            for index in start..<end {
                appendMeshSegmentHits(
                    segments[index],
                    cache: cache,
                    uSpan: uSpan,
                    vSpan: vSpan,
                    rowHits: &local
                )
            }

            lock.lock()
            partials[workerIndex] = local
            lock.unlock()
        }

        var rowHits = Array(repeating: [(x: Float, shade: Float)](), count: height)
        for partial in partials where !partial.isEmpty {
            for y in 0..<height where !partial[y].isEmpty {
                rowHits[y].append(contentsOf: partial[y])
            }
        }
        return rowHits
    }

    private static func appendMeshSegmentHits(
        _ segment: MeshSliceSegment,
        cache: MeshSliceCache,
        uSpan: Float,
        vSpan: Float,
        rowHits: inout [[(x: Float, shade: Float)]]
    ) {
        guard abs(segment.v1 - segment.v0) > 0.000_001 else { return }
        let lower = min(segment.v0, segment.v1)
        let upper = max(segment.v0, segment.v1)
        let minRow = max(0, Int(floor(((lower - cache.vMin) / vSpan) * Float(cache.outHeight) - 1)))
        let maxRow = min(cache.outHeight - 1, Int(ceil(((upper - cache.vMin) / vSpan) * Float(cache.outHeight) + 1)))
        guard minRow <= maxRow else { return }

        for y in minRow...maxRow {
            let vLine = cache.vMin + (Float(y) + 0.5) / Float(cache.outHeight) * vSpan
            guard vLine >= lower, vLine < upper else { continue }
            let t = (vLine - segment.v0) / (segment.v1 - segment.v0)
            let uHit = segment.u0 + (segment.u1 - segment.u0) * t
            let x = (uHit - cache.uMin) / uSpan * Float(cache.outWidth)
            rowHits[y].append((x, segment.shade))
        }
    }

    private static func meshSliceSegments(
        cache: MeshSliceCache,
        d: Float,
        intersector: MeshSliceGPUIntersector?
    ) -> [MeshSliceSegment] {
        if let gpuSegments = intersector?.segments(cache: cache, d: d) {
            return gpuSegments
        }

        let lightDirection = simd_normalize(SIMD3<Float>(-0.35, 0.65, 0.68))
        let triangleCount = cache.triangles.count
        let workerCount = min(max(1, ProcessInfo.processInfo.activeProcessorCount), max(1, triangleCount / 1_500))
        guard workerCount > 1 else {
            return meshSliceSegments(
                cache: cache,
                d: d,
                triangleRange: 0..<triangleCount,
                lightDirection: lightDirection
            )
        }

        let chunkSize = max(1, (triangleCount + workerCount - 1) / workerCount)
        var segments: [MeshSliceSegment] = []
        segments.reserveCapacity(triangleCount / 8)
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
            let start = workerIndex * chunkSize
            let end = min(triangleCount, start + chunkSize)
            guard start < end else { return }

            let local = meshSliceSegments(
                cache: cache,
                d: d,
                triangleRange: start..<end,
                lightDirection: lightDirection
            )

            guard !local.isEmpty else { return }
            lock.lock()
            segments.append(contentsOf: local)
            lock.unlock()
        }

        return segments
    }

    private static func meshSliceSegments(
        cache: MeshSliceCache,
        d: Float,
        triangleRange: Range<Int>,
        lightDirection: SIMD3<Float>
    ) -> [MeshSliceSegment] {
        let epsilon: Float = 0.000_01
        var segments: [MeshSliceSegment] = []
        segments.reserveCapacity(max(16, triangleRange.count / 8))

        for index in triangleRange {
            let range = cache.trianglePlaneRanges[index]
            guard d >= range.min - epsilon, d <= range.max + epsilon else { continue }

            let triangle = cache.triangles[index]
            guard let pair = trianglePlaneIntersection(
                triangle: triangle,
                normal: cache.n,
                d: d
            ) else { continue }

            let p0 = pair.0
            let p1 = pair.1
            let u0 = simd_dot(p0, cache.u)
            let v0 = simd_dot(p0, cache.v)
            let u1 = simd_dot(p1, cache.u)
            let v1 = simd_dot(p1, cache.v)
            guard abs(u1 - u0) + abs(v1 - v0) > 0.000_1 else { continue }

            let shade = max(0.68, min(1.0, 0.72 + 0.28 * abs(simd_dot(triangle.normal, lightDirection))))
            segments.append(MeshSliceSegment(u0: u0, v0: v0, u1: u1, v1: v1, shade: shade))
        }

        return segments
    }

    private static func trianglePlaneIntersection(
        triangle: MeshExportTriangle,
        normal: SIMD3<Float>,
        d: Float
    ) -> (SIMD3<Float>, SIMD3<Float>)? {
        let points = [triangle.a, triangle.b, triangle.c]
        let distances = points.map { simd_dot($0, normal) - d }
        let epsilon: Float = 0.000_01
        if distances.allSatisfy({ $0 > epsilon }) || distances.allSatisfy({ $0 < -epsilon }) {
            return nil
        }

        var intersections: [SIMD3<Float>] = []

        func appendUnique(_ point: SIMD3<Float>) {
            if intersections.contains(where: { simd_length_squared($0 - point) < 0.000_001 }) {
                return
            }
            intersections.append(point)
        }

        for edge in 0..<3 {
            let next = (edge + 1) % 3
            let p0 = points[edge]
            let p1 = points[next]
            let d0 = distances[edge]
            let d1 = distances[next]

            if abs(d0) <= epsilon, abs(d1) <= epsilon {
                appendUnique(p0)
                appendUnique(p1)
            } else if abs(d0) <= epsilon {
                appendUnique(p0)
            } else if abs(d1) <= epsilon {
                appendUnique(p1)
            } else if d0 * d1 < 0 {
                let t = d0 / (d0 - d1)
                appendUnique(p0 + (p1 - p0) * t)
            }
        }

        guard intersections.count >= 2 else { return nil }
        if intersections.count == 2 {
            return (intersections[0], intersections[1])
        }

        var bestPair = (intersections[0], intersections[1])
        var bestDistance = simd_length_squared(intersections[1] - intersections[0])
        for i in 0..<intersections.count {
            for j in (i + 1)..<intersections.count {
                let distance = simd_length_squared(intersections[j] - intersections[i])
                if distance > bestDistance {
                    bestDistance = distance
                    bestPair = (intersections[i], intersections[j])
                }
            }
        }
        return bestDistance > 0.000_001 ? bestPair : nil
    }

    private static func compactMeshRowHits(_ hits: [(x: Float, shade: Float)]) -> [(x: Float, shade: Float)] {
        guard let first = hits.first else { return [] }
        var compacted: [(x: Float, shade: Float)] = [first]
        for hit in hits.dropFirst() {
            let lastIndex = compacted.count - 1
            if abs(hit.x - compacted[lastIndex].x) <= 0.35 {
                compacted[lastIndex] = (
                    x: (compacted[lastIndex].x + hit.x) * 0.5,
                    shade: max(compacted[lastIndex].shade, hit.shade)
                )
            } else {
                compacted.append(hit)
            }
        }
        return compacted
    }

    private static func normalizedOrDefault(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(value)
        guard length > 0.000_001 else {
            let fallbackLength = simd_length(fallback)
            return fallbackLength > 0.000_001 ? fallback / fallbackLength : SIMD3<Float>(0, 0, 1)
        }
        return value / length
    }

    private static func renderCPU_RGBA(
        volume: CPUVolume,
        request: VideoExportRequest,
        frameIndex: Int,
        preserveAlpha: Bool,
        axisCache: AxisExportCache?,
        planeCache: PlaneExportCache?
    ) -> [UInt8] {
        switch request.mode {
        case .axis:
            return renderAxisRGBA(
                volume: volume,
                request: request,
                frameIndex: frameIndex,
                preserveAlpha: preserveAlpha,
                cache: axisCache!
            )
        case .plane:
            return renderPlaneRGBA(
                volume: volume,
                request: request,
                frameIndex: frameIndex,
                preserveAlpha: preserveAlpha,
                cache: planeCache!
            )
        }
    }

    private static func renderAxisRGBA(
        volume: CPUVolume,
        request: VideoExportRequest,
        frameIndex: Int,
        preserveAlpha: Bool,
        cache: AxisExportCache
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cache.outWidth * cache.outHeight * 4)
        let blendChecker = request.showCheckerboard && request.useAlpha && !preserveAlpha && volume.hasMeaningfulAlpha

        switch request.axis {
        case .t:
            let t = max(0, min(frameIndex, volume.depth - 1))
            for y in 0..<cache.outHeight {
                let sy = cache.yMap[y]
                for x in 0..<cache.outWidth {
                    let sx = cache.xMap[x]
                    let (r, g, b, a) = volume.rgbaAt(t: t, y: sy, x: sx)
                    let dst = (y * cache.outWidth + x) * 4
                    writePixel(into: &out, at: dst, outWidth: cache.outWidth, r: r, g: g, b: b, a: a,
                               checkerboard: blendChecker, preserveAlpha: preserveAlpha)
                }
            }

        case .x:
            let fixedX = max(0, min(frameIndex, volume.width - 1))
            for y in 0..<cache.outHeight {
                let sy = cache.yMap[y]
                for x in 0..<cache.outWidth {
                    let st = cache.tMapX[x]
                    let (r, g, b, a) = volume.rgbaAt(t: st, y: sy, x: fixedX)
                    let dst = (y * cache.outWidth + x) * 4
                    writePixel(into: &out, at: dst, outWidth: cache.outWidth, r: r, g: g, b: b, a: a,
                               checkerboard: blendChecker, preserveAlpha: preserveAlpha)
                }
            }

        case .y:
            let fixedY = max(0, min(frameIndex, volume.height - 1))
            for y in 0..<cache.outHeight {
                let st = cache.tMapY[y]
                for x in 0..<cache.outWidth {
                    let sx = cache.xMap[x]
                    let (r, g, b, a) = volume.rgbaAt(t: st, y: fixedY, x: sx)
                    let dst = (y * cache.outWidth + x) * 4
                    writePixel(into: &out, at: dst, outWidth: cache.outWidth, r: r, g: g, b: b, a: a,
                               checkerboard: blendChecker, preserveAlpha: preserveAlpha)
                }
            }
        }

        return out
    }

    private static func correctedBasis(_ g: PlaneGeometry) -> (u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>) {
        let u = simd_length(g.u) > 1e-6 ? simd_normalize(g.u) : SIMD3<Float>(1, 0, 0)
        var n = simd_cross(u, g.v)
        if simd_length(n) <= 1e-6 {
            n = simd_length(g.n) > 1e-6 ? simd_normalize(g.n) : SIMD3<Float>(0, 0, 1)
        } else {
            n = simd_normalize(n)
            if simd_dot(n, g.n) < 0 { n = -n }
        }
        var v = simd_cross(n, u)
        if simd_length(v) <= 1e-6 {
            v = simd_length(g.v) > 1e-6 ? simd_normalize(g.v) : SIMD3<Float>(0, 1, 0)
        } else {
            v = simd_normalize(v)
        }
        n = simd_normalize(simd_cross(u, v))
        if simd_dot(n, g.n) < 0 {
            n = -n
            v = -v
        }
        return (u, v, n)
    }

    private static func renderPlaneRGBA(
        volume: CPUVolume,
        request: VideoExportRequest,
        frameIndex: Int,
        preserveAlpha: Bool,
        cache: PlaneExportCache
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cache.outWidth * cache.outHeight * 4)
        let blendChecker = request.showCheckerboard && request.useAlpha && !preserveAlpha && volume.hasMeaningfulAlpha
        let d = cache.dBase + Float(frameIndex) * cache.dStep

        for j in 0..<cache.outHeight {
            let row = j * cache.outWidth
            for i in 0..<cache.outWidth {
                let centered = cache.baseCentered[row + i] + cache.n * d
                let voxel = volume.centeredToVoxel(centered)
                let (r, g, b, a) = volume.sampleLinearRGBA(x: voxel.x, y: voxel.y, t: voxel.z)
                let dst = (row + i) * 4
                writePixel(into: &out, at: dst, outWidth: cache.outWidth, r: r, g: g, b: b, a: a,
                           checkerboard: blendChecker, preserveAlpha: preserveAlpha)
            }
        }

        return out
    }

    private static func renderRawPlaneRGBA(
        rawBase: UnsafePointer<UInt8>,
        cache: RawPlaneExportCache,
        frameIndex: Int,
        preserveAlpha: Bool,
        useAlpha: Bool,
        showCheckerboard: Bool
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cache.outWidth * cache.outHeight * 4)
        let blendChecker = showCheckerboard && useAlpha && !preserveAlpha
        let halfX = Float(cache.sourceWidth - 1) * 0.5
        let halfY = Float(cache.sourceHeight - 1) * 0.5
        let halfT = Float(cache.sourceDepth - 1) * 0.5
        let d = cache.dBase + Float(frameIndex) * cache.dStep

        out.withUnsafeMutableBufferPointer { outBuffer in
            guard let outBase = outBuffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: cache.outHeight) { j in
                let row = j * cache.outWidth
                for i in 0..<cache.outWidth {
                    let centered = cache.baseCentered[row + i] + cache.n * d
                    let (r, g, b, a) = sampleRawLinearRGBA(
                        rawBase: rawBase,
                        cache: cache,
                        x: centered.x + halfX,
                        y: centered.y + halfY,
                        t: centered.z + halfT
                    )
                    writePixel(
                        into: outBase,
                        at: (row + i) * 4,
                        x: i,
                        y: j,
                        r: r,
                        g: g,
                        b: b,
                        a: a,
                        checkerboard: blendChecker,
                        preserveAlpha: preserveAlpha
                    )
                }
            }
        }

        return out
    }

    private static func renderRawPlanePixelBuffer(
        rawBase: UnsafePointer<UInt8>,
        cache: RawPlaneExportCache,
        pixelBuffer: CVPixelBuffer,
        pixelBufferWidth: Int,
        pixelBufferHeight: Int,
        frameIndex: Int,
        preserveAlpha: Bool,
        useAlpha: Bool,
        showCheckerboard: Bool
    ) {
        let blendChecker = showCheckerboard && useAlpha && !preserveAlpha
        let halfX = Float(cache.sourceWidth - 1) * 0.5
        let halfY = Float(cache.sourceHeight - 1) * 0.5
        let halfT = Float(cache.sourceDepth - 1) * 0.5
        let d = cache.dBase + Float(frameIndex) * cache.dStep
        let renderWidth = min(cache.outWidth, pixelBufferWidth)
        let renderHeight = min(cache.outHeight, pixelBufferHeight)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dstBase = base.bindMemory(to: UInt8.self, capacity: bytesPerRow * pixelBufferHeight)

        DispatchQueue.concurrentPerform(iterations: pixelBufferHeight) { j in
            let rowPtr = dstBase.advanced(by: j * bytesPerRow)
            rowPtr.initialize(repeating: 0, count: bytesPerRow)
            guard j < renderHeight else { return }

            let row = j * cache.outWidth
            for i in 0..<renderWidth {
                let centered = cache.baseCentered[row + i] + cache.n * d
                let (r, g, b, a) = sampleRawLinearRGBA(
                    rawBase: rawBase,
                    cache: cache,
                    x: centered.x + halfX,
                    y: centered.y + halfY,
                    t: centered.z + halfT
                )
                writePixelBGRA(
                    into: rowPtr,
                    at: i * 4,
                    x: i,
                    y: j,
                    r: r,
                    g: g,
                    b: b,
                    a: a,
                    checkerboard: blendChecker,
                    preserveAlpha: preserveAlpha
                )
            }
        }
    }

    private static func rawPlaneTimeBounds(
        cache: RawPlaneExportCache,
        frameIndex: Int
    ) -> (start: Int, depth: Int) {
        let halfT = Float(cache.sourceDepth - 1) * 0.5
        let d = cache.dBase + Float(frameIndex) * cache.dStep
        let uValues = [cache.uMin, cache.uMax]
        let vValues = [cache.vMin, cache.vMax]
        var minT = Float.greatestFiniteMagnitude
        var maxT = -Float.greatestFiniteMagnitude

        for fu in uValues {
            for fv in vValues {
                let centeredT = cache.u.z * fu + cache.v.z * fv + cache.n.z * d + halfT
                minT = min(minT, centeredT)
                maxT = max(maxT, centeredT)
            }
        }

        let start = max(0, min(cache.sourceDepth - 1, Int(floor(minT)) - 1))
        let end = max(0, min(cache.sourceDepth - 1, Int(ceil(maxT)) + 1))
        return (start, max(1, end - start + 1))
    }

    private static func sampleRawLinearRGBA(
        rawBase: UnsafePointer<UInt8>,
        cache: RawPlaneExportCache,
        x: Float,
        y: Float,
        t: Float
    ) -> (UInt8, UInt8, UInt8, UInt8) {
        if x < 0 || x > Float(cache.sourceWidth - 1) ||
           y < 0 || y > Float(cache.sourceHeight - 1) ||
           t < 0 || t > Float(cache.sourceDepth - 1) {
            return (0, 0, 0, 0)
        }

        let x0 = Int(floor(x))
        let x1 = min(x0 + 1, cache.sourceWidth - 1)
        let y0 = Int(floor(y))
        let y1 = min(y0 + 1, cache.sourceHeight - 1)
        let t0 = Int(floor(t))
        let t1 = min(t0 + 1, cache.sourceDepth - 1)
        let fx = x - Float(x0)
        let fy = y - Float(y0)
        let ft = t - Float(t0)

        func sample(_ tt: Int, _ yy: Int, _ xx: Int) -> (Float, Float, Float, Float) {
            let offset = tt * cache.frameBytes + (yy * cache.sourceWidth + xx) * 4
            let b = rawBase[offset]
            let g = rawBase[offset + 1]
            let r = rawBase[offset + 2]
            let a = rawBase[offset + 3]
            return (Float(r), Float(g), Float(b), Float(a))
        }

        let c000 = sample(t0, y0, x0)
        let c100 = sample(t0, y0, x1)
        let c010 = sample(t0, y1, x0)
        let c110 = sample(t0, y1, x1)
        let c001 = sample(t1, y0, x0)
        let c101 = sample(t1, y0, x1)
        let c011 = sample(t1, y1, x0)
        let c111 = sample(t1, y1, x1)

        func lerp(_ a: Float, _ b: Float, _ f: Float) -> Float {
            a + (b - a) * f
        }

        func channel(_ c000: Float, _ c100: Float, _ c010: Float, _ c110: Float, _ c001: Float, _ c101: Float, _ c011: Float, _ c111: Float) -> Float {
            let c00 = lerp(c000, c100, fx)
            let c10 = lerp(c010, c110, fx)
            let c01 = lerp(c001, c101, fx)
            let c11 = lerp(c011, c111, fx)
            let c0 = lerp(c00, c10, fy)
            let c1 = lerp(c01, c11, fy)
            return lerp(c0, c1, ft)
        }

        let r = channel(c000.0, c100.0, c010.0, c110.0, c001.0, c101.0, c011.0, c111.0)
        let g = channel(c000.1, c100.1, c010.1, c110.1, c001.1, c101.1, c011.1, c111.1)
        let b = channel(c000.2, c100.2, c010.2, c110.2, c001.2, c101.2, c011.2, c111.2)
        let a = channel(c000.3, c100.3, c010.3, c110.3, c001.3, c101.3, c011.3, c111.3)

        return (
            UInt8(max(0, min(255, Int(round(r))))),
            UInt8(max(0, min(255, Int(round(g))))),
            UInt8(max(0, min(255, Int(round(b))))),
            UInt8(max(0, min(255, Int(round(a)))))
        )
    }

    private static func writePixel(
        into out: UnsafeMutablePointer<UInt8>,
        at dst: Int,
        x: Int,
        y: Int,
        r: UInt8,
        g: UInt8,
        b: UInt8,
        a: UInt8,
        checkerboard: Bool,
        preserveAlpha: Bool
    ) {
        if preserveAlpha {
            out[dst] = r
            out[dst + 1] = g
            out[dst + 2] = b
            out[dst + 3] = a
            return
        }

        let alpha = Float(a) / 255.0
        if checkerboard {
            let tile = 12
            let isDark = ((x / tile) + (y / tile)) % 2 == 0
            let bg: UInt8 = isDark ? 180 : 235
            out[dst] = UInt8(Float(bg) * (1 - alpha) + Float(r) * alpha)
            out[dst + 1] = UInt8(Float(bg) * (1 - alpha) + Float(g) * alpha)
            out[dst + 2] = UInt8(Float(bg) * (1 - alpha) + Float(b) * alpha)
            out[dst + 3] = 255
        } else {
            out[dst] = UInt8(Float(r) * alpha)
            out[dst + 1] = UInt8(Float(g) * alpha)
            out[dst + 2] = UInt8(Float(b) * alpha)
            out[dst + 3] = 255
        }
    }

    private static func writePixelBGRA(
        into out: UnsafeMutablePointer<UInt8>,
        at dst: Int,
        x: Int,
        y: Int,
        r: UInt8,
        g: UInt8,
        b: UInt8,
        a: UInt8,
        checkerboard: Bool,
        preserveAlpha: Bool
    ) {
        if preserveAlpha {
            out[dst] = b
            out[dst + 1] = g
            out[dst + 2] = r
            out[dst + 3] = a
            return
        }

        let alpha = Float(a) / 255.0
        if checkerboard {
            let tile = 12
            let isDark = ((x / tile) + (y / tile)) % 2 == 0
            let bg: UInt8 = isDark ? 180 : 235
            out[dst] = UInt8(Float(bg) * (1 - alpha) + Float(b) * alpha)
            out[dst + 1] = UInt8(Float(bg) * (1 - alpha) + Float(g) * alpha)
            out[dst + 2] = UInt8(Float(bg) * (1 - alpha) + Float(r) * alpha)
            out[dst + 3] = 255
        } else {
            out[dst] = UInt8(Float(b) * alpha)
            out[dst + 1] = UInt8(Float(g) * alpha)
            out[dst + 2] = UInt8(Float(r) * alpha)
            out[dst + 3] = 255
        }
    }

    private static func writePixel(
        into out: inout [UInt8],
        at dst: Int,
        outWidth: Int,
        r: UInt8,
        g: UInt8,
        b: UInt8,
        a: UInt8,
        checkerboard: Bool,
        preserveAlpha: Bool
    ) {
        let alpha = Float(a) / 255.0

        if preserveAlpha {
            out[dst] = r
            out[dst + 1] = g
            out[dst + 2] = b
            out[dst + 3] = a
            return
        }

        if checkerboard {
            let pixelIndex = dst / 4
            let x = pixelIndex % max(1, outWidth)
            let y = pixelIndex / max(1, outWidth)
            let tile = 12
            let isDark = ((x / tile) + (y / tile)) % 2 == 0
            let bg: UInt8 = isDark ? 180 : 235

            out[dst] = UInt8(Float(bg) * (1 - alpha) + Float(r) * alpha)
            out[dst + 1] = UInt8(Float(bg) * (1 - alpha) + Float(g) * alpha)
            out[dst + 2] = UInt8(Float(bg) * (1 - alpha) + Float(b) * alpha)
            out[dst + 3] = 255
        } else {
            out[dst] = UInt8(Float(r) * alpha)
            out[dst + 1] = UInt8(Float(g) * alpha)
            out[dst + 2] = UInt8(Float(b) * alpha)
            out[dst + 3] = 255
        }
    }

    static func exportHighPrecisionDistributedSegment(
        outputURL: URL,
        sourceURL: URL,
        mode: SliceMode = .axis,
        axis: PlaybackAxis,
        referencePlane: ReferencePlaneState = ReferencePlaneState(),
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        fps: Double,
        preserveAlpha: Bool,
        padToEven: Bool,
        qualityScale: Double = 1.0,
        outputStartFrame: Int,
        outputEndFrame: Int,
        preparedRawCacheURL: URL? = nil,
        preparedRawCacheData: Data? = nil,
        preparedCPUVolume: CPUVolume? = nil,
        highPrecisionBatchByteBudget: Int? = nil,
        bitDepth: Int = 8,
        colorProfile: VideoColorProfile = .rec709,
        progress: @escaping ExportProgressHandler
    ) throws {
        if mode == .plane {
            try exportHighPrecisionDistributedPlaneSegment(
                outputURL: outputURL,
                sourceURL: sourceURL,
                referencePlane: referencePlane,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                fps: fps,
                preserveAlpha: preserveAlpha,
                padToEven: padToEven,
                qualityScale: qualityScale,
                outputStartFrame: outputStartFrame,
                outputEndFrame: outputEndFrame,
                preparedRawCacheURL: preparedRawCacheURL,
                preparedRawCacheData: preparedRawCacheData,
                preparedCPUVolume: preparedCPUVolume,
                highPrecisionBatchByteBudget: highPrecisionBatchByteBudget,
                bitDepth: bitDepth,
                colorProfile: colorProfile,
                progress: progress
            )
            return
        }

        let baseOutW: Int
        let baseOutH: Int

        switch axis {
        case .x:
            baseOutW = sourceFrameCount
            baseOutH = sourceHeight
        case .y:
            baseOutW = sourceWidth
            baseOutH = sourceFrameCount
        case .t:
            throw VideoExportError.createWriterFailed("分布式高精度分段当前仅支持 X / Y / 参考面")
        }

        let outW = scaledDistributedDimension(
            baseOutW,
            qualityScale: qualityScale,
            padToEven: padToEven
        )

        let outH = scaledDistributedDimension(
            baseOutH,
            qualityScale: qualityScale,
            padToEven: padToEven
        )

        let rangedRequest = VideoExportRequest(
            url: outputURL,
            width: outW,
            height: outH,
            fps: fps,
            frameCount: max(0, outputEndFrame - outputStartFrame + 1),
            mode: .axis,
            axis: axis,
            showCheckerboard: false,
            useAlpha: preserveAlpha,
            preserveAlpha: preserveAlpha,
            padToEven: padToEven,
            highPrecision: true,
            sourceFrameCount: sourceFrameCount,
            playbackRate: 1.0,
            sourceURL: sourceURL,
            referencePlane: ReferencePlaneState(),
            outputStartFrame: outputStartFrame,
            outputEndFrame: outputEndFrame,
            highPrecisionBatchByteBudget: highPrecisionBatchByteBudget,
            bitDepth: bitDepth,
            colorProfile: colorProfile
        )

        try exportHighPrecisionAxisFromSource(
            request: rangedRequest,
            preparedRawCacheURL: preparedRawCacheURL,
            preparedRawCacheData: preparedRawCacheData,
            progress: progress
        )
    }

    private static func exportHighPrecisionDistributedPlaneSegment(
        outputURL: URL,
        sourceURL: URL,
        referencePlane: ReferencePlaneState,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        fps: Double,
        preserveAlpha: Bool,
        padToEven: Bool,
        qualityScale: Double,
        outputStartFrame: Int,
        outputEndFrame: Int,
        preparedRawCacheURL: URL?,
        preparedRawCacheData: Data?,
        preparedCPUVolume: CPUVolume?,
        highPrecisionBatchByteBudget: Int?,
        bitDepth: Int,
        colorProfile: VideoColorProfile,
        progress: @escaping ExportProgressHandler
    ) throws {
        _ = preparedCPUVolume
        let metrics = highPrecisionPlaneOutputMetrics(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceFrameCount: sourceFrameCount,
            referencePlane: referencePlane,
            qualityScale: qualityScale,
            padToEven: padToEven
        )
        let request = VideoExportRequest(
            url: outputURL,
            width: metrics.width,
            height: metrics.height,
            fps: fps,
            frameCount: max(0, outputEndFrame - outputStartFrame + 1),
            mode: .plane,
            axis: .t,
            showCheckerboard: false,
            useAlpha: preserveAlpha,
            preserveAlpha: preserveAlpha,
            padToEven: padToEven,
            highPrecision: true,
            sourceFrameCount: sourceFrameCount,
            playbackRate: 1.0,
            sourceURL: sourceURL,
            referencePlane: referencePlane,
            outputStartFrame: outputStartFrame,
            outputEndFrame: outputEndFrame,
            highPrecisionBatchByteBudget: highPrecisionBatchByteBudget,
            bitDepth: bitDepth,
            colorProfile: colorProfile
        )

        try exportHighPrecisionPlaneFromSource(
            request: request,
            preparedRawCacheURL: preparedRawCacheURL,
            preparedRawCacheData: preparedRawCacheData,
            progress: progress
        )
    }

    static func exportDistributedPlaneSegmentFromVolume(
        volume: CPUVolume,
        outputURL: URL,
        referencePlane: ReferencePlaneState,
        fps: Double,
        preserveAlpha: Bool,
        padToEven: Bool,
        qualityScale: Double,
        outputStartFrame: Int,
        outputEndFrame: Int,
        progress: @escaping ExportProgressHandler
    ) throws {
        let geometry = volume.planeGeometry(for: referencePlane)
        let outW = scaledDistributedDimension(
            geometry.outWidth,
            qualityScale: qualityScale,
            padToEven: padToEven
        )
        let outH = scaledDistributedDimension(
            geometry.outHeight,
            qualityScale: qualityScale,
            padToEven: padToEven
        )
        let range = normalizedOutputRange(
            start: outputStartFrame,
            end: outputEndFrame,
            upperBound: max(0, geometry.sliceCount - 1)
        )
        guard range.end >= range.start else {
            throw VideoExportError.createWriterFailed("参考面输出范围无效")
        }

        let request = VideoExportRequest(
            url: outputURL,
            width: outW,
            height: outH,
            fps: fps,
            frameCount: max(0, range.end - range.start + 1),
            mode: .plane,
            axis: .t,
            showCheckerboard: false,
            useAlpha: preserveAlpha,
            preserveAlpha: preserveAlpha,
            padToEven: padToEven,
            highPrecision: true,
            sourceFrameCount: volume.depth,
            playbackRate: 1.0,
            sourceURL: nil,
            referencePlane: referencePlane,
            outputStartFrame: range.start,
            outputEndFrame: range.end,
            colorProfile: volume.sourceColorProfile
        )

        let routeText = preserveAlpha ? "参考面视频会话导出（带 Alpha）" : "参考面视频会话导出"
        progress(0.0, routeText)
        try exportRendered(volume: volume, request: request) { p, text in
            progress(p, text ?? routeText)
        }
    }

    private static func scaledDistributedDimension(
        _ value: Int,
        qualityScale: Double,
        padToEven: Bool
    ) -> Int {
        let scale = min(1.0, max(0.05, qualityScale))
        var v = max(1, Int((Double(value) * scale).rounded()))

        if padToEven && v % 2 != 0 {
            v += 1
        }

        return max(1, v)
    }

}
