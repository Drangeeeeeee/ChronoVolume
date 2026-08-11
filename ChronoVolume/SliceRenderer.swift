import Foundation
import MetalKit
import simd

private struct SlicePlaneGeometryGPU {
    let u: SIMD3<Float>
    let v: SIMD3<Float>
    let n: SIMD3<Float>

    let uMin: Float
    let uMax: Float
    let vMin: Float
    let vMax: Float
    let nMin: Float
    let nMax: Float

    let width: Int
    let height: Int
    let sliceCount: Int
}

private struct SliceUniformsGPU {
    var mode: UInt32 = 0
    var axis: UInt32 = 0
    var currentIndex: UInt32 = 0
    var flags: UInt32 = 0

    var volumeSize: SIMD3<UInt32> = .zero
    var _pad0: UInt32 = 0

    var outputSize: SIMD2<UInt32> = .zero
    var logicalSize: SIMD2<UInt32> = .zero

    var planeU: SIMD3<Float> = .zero
    var planeUMin: Float = 0
    var planeV: SIMD3<Float> = .zero
    var planeVMin: Float = 0
    var planeN: SIMD3<Float> = .zero
    var planeNMin: Float = 0

    var planeUMax: Float = 0
    var planeVMax: Float = 0
    var planeNMax: Float = 0
    var _pad1: Float = 0
}

final class SliceRenderer: NSObject, MTKViewDelegate {
    private weak var view: MTKView?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let linearSampler: MTLSamplerState
    private let nearestSampler: MTLSamplerState

    private var volumeTexture: MTLTexture?
    private var volumeWidth: Int = 1
    private var volumeHeight: Int = 1
    private var volumeDepth: Int = 1

    private var sliceMode: SliceMode = .axis
    private var playbackAxis: PlaybackAxis = .t
    private var currentIndex: Int = 0
    private var showCheckerboard: Bool = true
    private var useAlpha: Bool = true
    private var referencePlane = ReferencePlaneState()
    private var fastPreview: Bool = false

    init(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metal 初始化失败")
        }

        self.view = view
        self.device = device
        self.commandQueue = commandQueue

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            fatalError("加载默认 Metal Library 失败：\(error)")
        }

        guard let kernel = library.makeFunction(name: "sliceKernel") else {
            fatalError("找不到 sliceKernel")
        }

        do {
            self.pipeline = try device.makeComputePipelineState(function: kernel)
        } catch {
            fatalError("创建 Slice Compute Pipeline 失败：\(error)")
        }

        let linearDesc = MTLSamplerDescriptor()
        linearDesc.minFilter = .linear
        linearDesc.magFilter = .linear
        linearDesc.mipFilter = .notMipmapped
        linearDesc.sAddressMode = .clampToEdge
        linearDesc.tAddressMode = .clampToEdge
        linearDesc.rAddressMode = .clampToEdge
        guard let linearSampler = device.makeSamplerState(descriptor: linearDesc) else {
            fatalError("创建 linearSampler 失败")
        }
        self.linearSampler = linearSampler

        let nearestDesc = MTLSamplerDescriptor()
        nearestDesc.minFilter = .nearest
        nearestDesc.magFilter = .nearest
        nearestDesc.mipFilter = .notMipmapped
        nearestDesc.sAddressMode = .clampToEdge
        nearestDesc.tAddressMode = .clampToEdge
        nearestDesc.rAddressMode = .clampToEdge
        guard let nearestSampler = device.makeSamplerState(descriptor: nearestDesc) else {
            fatalError("创建 nearestSampler 失败")
        }
        self.nearestSampler = nearestSampler

        super.init()
    }

    func setVolume(_ volume: LoadedVolume) {
        if let cachedTexture = VolumeModifierRasterizer.cachedModifiedTexture(
            for: volume.textureCacheID,
            device: device
        ) {
            self.volumeTexture = cachedTexture
            self.volumeWidth = volume.width
            self.volumeHeight = volume.height
            self.volumeDepth = volume.depth
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
            print("SliceRenderer: makeTexture 失败")
            return
        }

        let region = MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth)
        texture.replace(region: region,
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: volume.rgba,
                        bytesPerRow: volume.width * 4,
                        bytesPerImage: volume.width * volume.height * 4)

        self.volumeTexture = texture
        self.volumeWidth = volume.width
        self.volumeHeight = volume.height
        self.volumeDepth = volume.depth
        requestRedraw()
    }

    func clearVolume() {
        volumeTexture = nil
        volumeWidth = 1
        volumeHeight = 1
        volumeDepth = 1
        requestRedraw()
    }

    func updateParams(
        sliceMode: SliceMode,
        playbackAxis: PlaybackAxis,
        currentIndex: Int,
        showCheckerboard: Bool,
        useAlpha: Bool,
        referencePlane: ReferencePlaneState,
        fastPreview: Bool
    ) {
        self.sliceMode = sliceMode
        self.playbackAxis = playbackAxis
        self.currentIndex = currentIndex
        self.showCheckerboard = showCheckerboard
        self.useAlpha = useAlpha
        self.referencePlane = referencePlane
        self.fastPreview = fastPreview
    }

    func requestRedraw() {
        view?.needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let volumeTexture,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        var uniforms = makeUniforms(outputWidth: drawable.texture.width, outputHeight: drawable.texture.height)

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(volumeTexture, index: 0)
        encoder.setTexture(drawable.texture, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<SliceUniformsGPU>.stride, index: 0)
        encoder.setSamplerState(linearSampler, index: 0)
        encoder.setSamplerState(nearestSampler, index: 1)

        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        let threadsPerThreadgroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadsPerGrid = MTLSize(width: drawable.texture.width, height: drawable.texture.height, depth: 1)

        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeUniforms(outputWidth: Int, outputHeight: Int) -> SliceUniformsGPU {
        var u = SliceUniformsGPU()
        u.mode = sliceMode == .axis ? 0 : 1
        u.axis = playbackAxis == .t ? 0 : (playbackAxis == .x ? 1 : 2)
        u.currentIndex = UInt32(max(0, currentIndex))

        var flags: UInt32 = 0
        if showCheckerboard { flags |= 1 << 0 }
        if useAlpha { flags |= 1 << 1 }
        if fastPreview { flags |= 1 << 2 }
        u.flags = flags

        u.volumeSize = SIMD3(UInt32(volumeWidth), UInt32(volumeHeight), UInt32(volumeDepth))
        u.outputSize = SIMD2(UInt32(max(1, outputWidth)), UInt32(max(1, outputHeight)))

        switch sliceMode {
        case .axis:
            let logical = logicalAxisSize()
            u.logicalSize = SIMD2(UInt32(logical.width), UInt32(logical.height))
        case .plane:
            let g = planeGeometry()
            u.logicalSize = SIMD2(UInt32(g.width), UInt32(g.height))
            u.planeU = g.u
            u.planeUMin = g.uMin
            u.planeV = g.v
            u.planeVMin = g.vMin
            u.planeN = g.n
            u.planeNMin = g.nMin
            u.planeUMax = g.uMax
            u.planeVMax = g.vMax
            u.planeNMax = g.nMax
        }

        return u
    }

    private func logicalAxisSize() -> (width: Int, height: Int) {
        switch playbackAxis {
        case .t:
            return (max(1, volumeWidth), max(1, volumeHeight))
        case .x:
            return (max(1, volumeDepth), max(1, volumeHeight))
        case .y:
            return (max(1, volumeWidth), max(1, volumeDepth))
        }
    }

    private func planeGeometry(maxLongSide: Int = 1400) -> SlicePlaneGeometryGPU {
        let halfX = Float(volumeWidth - 1) * 0.5
        let halfY = Float(volumeHeight - 1) * 0.5
        let halfT = Float(volumeDepth - 1) * 0.5

        let u = simd_normalize(referencePlane.uAxis)
        let v = simd_normalize(referencePlane.vAxis)
        let n = simd_normalize(referencePlane.normalAxis)

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

        let fullW = max(1, Int(ceil(uMax - uMin)) + 1)
        let fullH = max(1, Int(ceil(vMax - vMin)) + 1)
        let fullSlices = max(1, Int(ceil(nMax - nMin)) + 1)

        let longSide = max(fullW, fullH)
        let scale = longSide > maxLongSide ? Float(maxLongSide) / Float(longSide) : 1.0

        let outW = max(1, Int(round(Float(fullW) * scale)))
        let outH = max(1, Int(round(Float(fullH) * scale)))

        return SlicePlaneGeometryGPU(
            u: u,
            v: v,
            n: n,
            uMin: uMin,
            uMax: uMax,
            vMin: vMin,
            vMax: vMax,
            nMin: nMin,
            nMax: nMax,
            width: outW,
            height: outH,
            sliceCount: fullSlices
        )
    }
}
