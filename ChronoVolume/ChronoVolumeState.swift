import Foundation
import simd

enum PlaybackAxis: String, CaseIterable, Identifiable, Codable {
    case t = "T"
    case x = "X"
    case y = "Y"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .t: return "时间轴 = T"
        case .x: return "时间轴 = X"
        case .y: return "时间轴 = Y"
        }
    }
}

enum SliceMode: String, CaseIterable, Identifiable, Codable {
    case axis = "轴切片"
    case plane = "参考面切片"

    var id: String { rawValue }
}

struct ReferencePlaneState: Codable, Equatable, Sendable {
    var yawDegrees: Float = 0
    var pitchDegrees: Float = 0
    var rollDegrees: Float = 0

    mutating func reset() {
        yawDegrees = 0
        pitchDegrees = 0
        rollDegrees = 0
    }

    var rotationMatrix: simd_float3x3 {
        let yaw = yawDegrees * .pi / 180
        let pitch = pitchDegrees * .pi / 180
        let roll = rollDegrees * .pi / 180

        let cy = cos(yaw), sy = sin(yaw)
        let cx = cos(pitch), sx = sin(pitch)
        let cz = cos(roll), sz = sin(roll)

        let ry = simd_float3x3(
            SIMD3<Float>( cy, 0, sy),
            SIMD3<Float>(  0, 1,  0),
            SIMD3<Float>(-sy, 0, cy)
        )
        let rx = simd_float3x3(
            SIMD3<Float>(1,  0,   0),
            SIMD3<Float>(0, cx, -sx),
            SIMD3<Float>(0, sx,  cx)
        )
        let rz = simd_float3x3(
            SIMD3<Float>( cz, -sz, 0),
            SIMD3<Float>( sz,  cz, 0),
            SIMD3<Float>(  0,   0, 1)
        )

        return rz * rx * ry
    }

    var uAxis: SIMD3<Float> { simd_normalize(rotationMatrix * SIMD3<Float>(1, 0, 0)) }
    var vAxis: SIMD3<Float> { simd_normalize(rotationMatrix * SIMD3<Float>(0, 1, 0)) }
    var normalAxis: SIMD3<Float> { simd_normalize(rotationMatrix * SIMD3<Float>(0, 0, 1)) }
}

struct PlaneGeometry {
    let u: SIMD3<Float>
    let v: SIMD3<Float>
    let n: SIMD3<Float>

    let uMin: Float
    let uMax: Float
    let vMin: Float
    let vMax: Float
    let nMin: Float
    let nMax: Float

    let outWidth: Int
    let outHeight: Int
    let sliceCount: Int
}

struct VolumeVoxelBounds: Sendable {
    let minX: Float
    let maxX: Float
    let minY: Float
    let maxY: Float
    let minT: Float
    let maxT: Float
}

func makePlaneGeometry(
    width: Int,
    height: Int,
    depth: Int,
    plane: ReferencePlaneState,
    maxLongSide: Int = 1400
) -> PlaneGeometry {
    let halfX = Float(width - 1) * 0.5
    let halfY = Float(height - 1) * 0.5
    let halfT = Float(depth - 1) * 0.5
    let u = plane.uAxis
    let v = plane.vAxis
    let n = plane.normalAxis

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

func makePlaneGeometry(
    bounds: VolumeVoxelBounds,
    plane: ReferencePlaneState,
    maxLongSide: Int = 1400
) -> PlaneGeometry {
    let u = plane.uAxis
    let v = plane.vAxis
    let n = plane.normalAxis
    let corners: [SIMD3<Float>] = [
        SIMD3(bounds.minX, bounds.minY, bounds.minT),
        SIMD3(bounds.maxX, bounds.minY, bounds.minT),
        SIMD3(bounds.minX, bounds.maxY, bounds.minT),
        SIMD3(bounds.maxX, bounds.maxY, bounds.minT),
        SIMD3(bounds.minX, bounds.minY, bounds.maxT),
        SIMD3(bounds.maxX, bounds.minY, bounds.maxT),
        SIMD3(bounds.minX, bounds.maxY, bounds.maxT),
        SIMD3(bounds.maxX, bounds.maxY, bounds.maxT)
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

struct CPUVolume: Sendable {
    let width: Int
    let height: Int
    let depth: Int
    let rgba: [UInt8]   // [t][y][x][rgba]
    let hasMeaningfulAlpha: Bool
    var sourceColorProfile: VideoColorProfile = .rec709

    private var halfX: Float { Float(width - 1) * 0.5 }
    private var halfY: Float { Float(height - 1) * 0.5 }
    private var halfT: Float { Float(depth - 1) * 0.5 }

    func rgbaAt(t: Int, y: Int, x: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let idx = ((t * height + y) * width + x) * 4
        return (rgba[idx], rgba[idx + 1], rgba[idx + 2], rgba[idx + 3])
    }

    func timeCount(for axis: PlaybackAxis) -> Int {
        switch axis {
        case .t: return depth
        case .x: return width
        case .y: return height
        }
    }

    func imageSize(for axis: PlaybackAxis) -> (width: Int, height: Int) {
        switch axis {
        case .t:
            return (width, height)
        case .x:
            return (depth, height)
        case .y:
            return (width, depth)
        }
    }

    func planeGeometry(for plane: ReferencePlaneState, maxLongSide: Int = 1400) -> PlaneGeometry {
        makePlaneGeometry(width: width, height: height, depth: depth, plane: plane, maxLongSide: maxLongSide)
    }

    func sampleNearestRGBA(x: Float, y: Float, t: Float) -> (UInt8, UInt8, UInt8, UInt8) {
        let xi = Int(round(x))
        let yi = Int(round(y))
        let ti = Int(round(t))

        if xi < 0 || xi >= width || yi < 0 || yi >= height || ti < 0 || ti >= depth {
            return (0, 0, 0, 0)
        }
        return rgbaAt(t: ti, y: yi, x: xi)
    }

    func sampleLinearRGBA(x: Float, y: Float, t: Float) -> (UInt8, UInt8, UInt8, UInt8) {
        if x < 0 || x > Float(width - 1) ||
           y < 0 || y > Float(height - 1) ||
           t < 0 || t > Float(depth - 1) {
            return (0, 0, 0, 0)
        }

        let x0 = Int(floor(x))
        let x1 = min(x0 + 1, width - 1)
        let y0 = Int(floor(y))
        let y1 = min(y0 + 1, height - 1)
        let t0 = Int(floor(t))
        let t1 = min(t0 + 1, depth - 1)

        let fx = x - Float(x0)
        let fy = y - Float(y0)
        let ft = t - Float(t0)

        func sample(_ tt: Int, _ yy: Int, _ xx: Int) -> SIMD4<Float> {
            let (r, g, b, a) = rgbaAt(t: tt, y: yy, x: xx)
            return SIMD4(Float(r), Float(g), Float(b), Float(a))
        }

        let c000 = sample(t0, y0, x0)
        let c100 = sample(t0, y0, x1)
        let c010 = sample(t0, y1, x0)
        let c110 = sample(t0, y1, x1)
        let c001 = sample(t1, y0, x0)
        let c101 = sample(t1, y0, x1)
        let c011 = sample(t1, y1, x0)
        let c111 = sample(t1, y1, x1)

        let c00 = simd_mix(c000, c100, SIMD4<Float>(repeating: fx))
        let c10 = simd_mix(c010, c110, SIMD4<Float>(repeating: fx))
        let c01 = simd_mix(c001, c101, SIMD4<Float>(repeating: fx))
        let c11 = simd_mix(c011, c111, SIMD4<Float>(repeating: fx))

        let c0 = simd_mix(c00, c10, SIMD4<Float>(repeating: fy))
        let c1 = simd_mix(c01, c11, SIMD4<Float>(repeating: fy))
        let c = simd_mix(c0, c1, SIMD4<Float>(repeating: ft))

        return (
            UInt8(max(0, min(255, Int(round(c.x))))),
            UInt8(max(0, min(255, Int(round(c.y))))),
            UInt8(max(0, min(255, Int(round(c.z))))),
            UInt8(max(0, min(255, Int(round(c.w)))))
        )
    }

    func centeredToVoxel(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(p.x + halfX, p.y + halfY, p.z + halfT)
    }

    func normalizedVolumeScale() -> SIMD3<Float> {
        let maxDim = Float(max(width, max(height, depth)))
        return SIMD3<Float>(
            Float(width) / maxDim,
            Float(height) / maxDim,
            Float(depth) / maxDim
        )
    }
}
