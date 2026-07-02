import Foundation
import MetalKit
import simd

struct PlaneSliceParameters {
    let outWidth: Int
    let outHeight: Int
    let u: SIMD3<Float>
    let v: SIMD3<Float>
    let n: SIMD3<Float>
    let uMin: Float
    let uMax: Float
    let vMin: Float
    let vMax: Float
    let d: Float
    let volumeWidth: Int
    let volumeHeight: Int
    let volumeDepth: Int
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

final class PlaneSliceRenderer: NSObject, MTKViewDelegate {
    private weak var view: MTKView?
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var uniformBuffer: MTLBuffer

    private var volumeTexture: MTLTexture?
    private var params: PlaneSliceParameters?
    private var useAlpha: Bool = true
    private var showCheckerboard: Bool = true
    private var fastPreview: Bool = false

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

        guard let fn = library.makeFunction(name: "planeSliceKernel") else {
            fatalError("找不到 planeSliceKernel")
        }

        do {
            self.pipeline = try device.makeComputePipelineState(function: fn)
        } catch {
            fatalError("创建 planeSlice compute pipeline 失败：\(error)")
        }

        guard let uniformBuffer = device.makeBuffer(length: MemoryLayout<PlaneSliceUniforms>.stride, options: .storageModeShared) else {
            fatalError("创建 uniformBuffer 失败")
        }
        self.uniformBuffer = uniformBuffer

        super.init()
    }

    func setVolume(_ volume: LoadedVolume) {
        if let cachedTexture = VolumeModifierRasterizer.cachedModifiedTexture(
            for: volume.textureCacheID,
            device: device
        ) {
            self.volumeTexture = cachedTexture
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

        guard let texture = device.makeTexture(descriptor: desc) else { return }

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
        requestRedraw()
    }

    func clearVolume() {
        volumeTexture = nil
        requestRedraw()
    }

    func update(params: PlaneSliceParameters?, useAlpha: Bool, showCheckerboard: Bool, fastPreview: Bool) {
        self.params = params
        self.useAlpha = useAlpha
        self.showCheckerboard = showCheckerboard
        self.fastPreview = fastPreview
        requestRedraw()
    }

    func requestRedraw() {
        view?.needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let volumeTexture = volumeTexture,
              let params = params,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        let drawableW = Float(drawable.texture.width)
        let drawableH = Float(drawable.texture.height)
        let contentAspect = Float(max(1, params.outWidth)) / Float(max(1, params.outHeight))
        let viewAspect = drawableW / max(1.0, drawableH)

        let contentW: Float
        let contentH: Float
        let contentX: Float
        let contentY: Float

        if contentAspect > viewAspect {
            contentW = drawableW
            contentH = drawableW / max(contentAspect, 1e-6)
            contentX = 0
            contentY = (drawableH - contentH) * 0.5
        } else {
            contentH = drawableH
            contentW = drawableH * contentAspect
            contentY = 0
            contentX = (drawableW - contentW) * 0.5
        }

        var uniforms = PlaneSliceUniforms(
            outWidth: UInt32(max(1, params.outWidth)),
            outHeight: UInt32(max(1, params.outHeight)),
            useAlpha: useAlpha ? 1 : 0,
            showCheckerboard: showCheckerboard ? 1 : 0,
            fastPreview: fastPreview ? 1 : 0,
            volumeWidth: UInt32(params.volumeWidth),
            volumeHeight: UInt32(params.volumeHeight),
            volumeDepth: UInt32(params.volumeDepth),
            contentX: contentX,
            contentY: contentY,
            contentW: contentW,
            contentH: contentH,
            u: params.u,
            v: params.v,
            n: params.n,
            d: params.d,
            uMin: params.uMin,
            uMax: params.uMax,
            vMin: params.vMin,
            vMax: params.vMax
        )

        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<PlaneSliceUniforms>.stride)

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(volumeTexture, index: 0)
        encoder.setTexture(drawable.texture, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let tg = MTLSize(width: w, height: h, depth: 1)
        let threads = MTLSize(width: Int(drawable.texture.width), height: Int(drawable.texture.height), depth: 1)

        encoder.dispatchThreads(threads, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
