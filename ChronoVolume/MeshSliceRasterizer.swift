import CoreGraphics
import Foundation
import simd

enum MeshSliceRasterizer {
    struct Cache: Sendable {
        fileprivate let volumeWidth: Int
        fileprivate let volumeHeight: Int
        fileprivate let volumeDepth: Int
        fileprivate let triangles: [Triangle]
    }

    fileprivate struct Triangle: Sendable {
        let a: SIMD3<Float>
        let b: SIMD3<Float>
        let c: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    private struct Geometry {
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

    private struct Segment {
        let u0: Float
        let v0: Float
        let u1: Float
        let v1: Float
        let shade: Float
    }

    static func makeCache(mesh: LoadedMesh, volume: CPUVolume) -> Cache? {
        guard mesh.vertices.count >= 3 else { return nil }

        let volumeExtent = SIMD3<Float>(
            Float(max(1, volume.width - 1)),
            Float(max(1, volume.height - 1)),
            Float(max(1, volume.depth - 1))
        )

        var triangles: [Triangle] = []
        triangles.reserveCapacity(mesh.vertices.count / 3)

        var index = 0
        while index + 2 < mesh.vertices.count {
            let a = mesh.vertices[index].position * volumeExtent
            let b = mesh.vertices[index + 1].position * volumeExtent
            let c = mesh.vertices[index + 2].position * volumeExtent
            let normal = normalizedOrDefault(
                simd_cross(b - a, c - a),
                fallback: mesh.vertices[index].normal
            )

            if simd_length_squared(b - a) > 0.000_001,
               simd_length_squared(c - a) > 0.000_001 {
                triangles.append(Triangle(a: a, b: b, c: c, normal: normal))
            }
            index += 3
        }

        guard !triangles.isEmpty else { return nil }

        return Cache(
            volumeWidth: volume.width,
            volumeHeight: volume.height,
            volumeDepth: volume.depth,
            triangles: triangles
        )
    }

    static func makeCGImage(
        cache: Cache,
        mode: SliceMode,
        axis: PlaybackAxis,
        index: Int,
        referencePlane: ReferencePlaneState,
        width: Int,
        height: Int,
        useAlpha: Bool,
        showCheckerboard: Bool,
        supersampleScale: Int = 1
    ) -> CGImage? {
        let outWidth = max(1, width)
        let outHeight = max(1, height)
        guard let geometry = makeGeometry(
            cache: cache,
            mode: mode,
            axis: axis,
            referencePlane: referencePlane
        ) else { return nil }

        let rgba = renderRGBA(
            cache: cache,
            geometry: geometry,
            frameIndex: index,
            width: outWidth,
            height: outHeight,
            useAlpha: useAlpha,
            showCheckerboard: showCheckerboard,
            supersampleScale: supersampleScale
        )

        return cgImageFromRGBA(width: outWidth, height: outHeight, rgba: rgba)
    }

    private static func makeGeometry(
        cache: Cache,
        mode: SliceMode,
        axis: PlaybackAxis,
        referencePlane: ReferencePlaneState
    ) -> Geometry? {
        let halfX = Float(cache.volumeWidth - 1) * 0.5
        let halfY = Float(cache.volumeHeight - 1) * 0.5
        let halfT = Float(cache.volumeDepth - 1) * 0.5

        let u: SIMD3<Float>
        let v: SIMD3<Float>
        let n: SIMD3<Float>
        let uMin: Float
        let uMax: Float
        let vMin: Float
        let vMax: Float
        let dBase: Float
        let dStep: Float

        switch mode {
        case .axis:
            switch axis {
            case .t:
                u = SIMD3<Float>(1, 0, 0)
                v = SIMD3<Float>(0, 1, 0)
                n = SIMD3<Float>(0, 0, 1)
                uMin = -halfX
                uMax = halfX
                vMin = -halfY
                vMax = halfY
                dBase = -halfT
                dStep = 1
            case .x:
                u = SIMD3<Float>(0, 0, 1)
                v = SIMD3<Float>(0, 1, 0)
                n = SIMD3<Float>(1, 0, 0)
                uMin = -halfT
                uMax = halfT
                vMin = -halfY
                vMax = halfY
                dBase = -halfX
                dStep = 1
            case .y:
                u = SIMD3<Float>(1, 0, 0)
                v = SIMD3<Float>(0, 0, 1)
                n = SIMD3<Float>(0, 1, 0)
                uMin = -halfX
                uMax = halfX
                vMin = -halfT
                vMax = halfT
                dBase = -halfY
                dStep = 1
            }
        case .plane:
            let plane = makePlaneGeometry(
                width: cache.volumeWidth,
                height: cache.volumeHeight,
                depth: cache.volumeDepth,
                plane: referencePlane
            )
            let basis = correctedBasis(plane)
            let sliceCount = max(1, plane.sliceCount)

            u = basis.u
            v = basis.v
            n = basis.n
            uMin = plane.uMin
            uMax = plane.uMax
            vMin = plane.vMin
            vMax = plane.vMax

            if sliceCount == 1 {
                dBase = (plane.nMin + plane.nMax) * 0.5
                dStep = 0
            } else {
                dBase = plane.nMin
                dStep = (plane.nMax - plane.nMin) / Float(sliceCount - 1)
            }
        }

        guard uMax > uMin, vMax > vMin else { return nil }
        return Geometry(
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

    private static func renderRGBA(
        cache: Cache,
        geometry: Geometry,
        frameIndex: Int,
        width: Int,
        height: Int,
        useAlpha: Bool,
        showCheckerboard: Bool,
        supersampleScale: Int
    ) -> [UInt8] {
        let scale = max(1, min(3, supersampleScale))
        guard scale > 1 else {
            return renderRasterRGBA(
                cache: cache,
                geometry: geometry,
                frameIndex: frameIndex,
                width: width,
                height: height,
                useAlpha: useAlpha,
                showCheckerboard: showCheckerboard
            )
        }

        let highWidth = max(1, width * scale)
        let highHeight = max(1, height * scale)
        let highRGBA = renderRasterRGBA(
            cache: cache,
            geometry: geometry,
            frameIndex: frameIndex,
            width: highWidth,
            height: highHeight,
            useAlpha: useAlpha,
            showCheckerboard: showCheckerboard
        )

        return downsampleRGBA(
            highRGBA,
            srcWidth: highWidth,
            srcHeight: highHeight,
            dstWidth: width,
            dstHeight: height,
            scale: scale
        )
    }

    private static func renderRasterRGBA(
        cache: Cache,
        geometry: Geometry,
        frameIndex: Int,
        width: Int,
        height: Int,
        useAlpha: Bool,
        showCheckerboard: Bool
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let d = geometry.dBase + Float(frameIndex) * geometry.dStep
        let segments = meshSliceSegments(cache: cache, geometry: geometry, d: d)
        guard !segments.isEmpty else {
            if showCheckerboard && useAlpha {
                fillCheckerboard(into: &out, width: width, height: height)
            }
            return out
        }

        let uSpan = max(0.000_001, geometry.uMax - geometry.uMin)
        let vSpan = max(0.000_001, geometry.vMax - geometry.vMin)
        var rowHits = Array(repeating: [(x: Float, shade: Float)](), count: height)

        for segment in segments {
            guard abs(segment.v1 - segment.v0) > 0.000_001 else { continue }

            let lower = min(segment.v0, segment.v1)
            let upper = max(segment.v0, segment.v1)
            let minRow = max(0, Int(floor(((lower - geometry.vMin) / vSpan) * Float(height) - 1)))
            let maxRow = min(height - 1, Int(ceil(((upper - geometry.vMin) / vSpan) * Float(height) + 1)))
            guard minRow <= maxRow else { continue }

            for y in minRow...maxRow {
                let vLine = geometry.vMin + (Float(y) + 0.5) / Float(height) * vSpan
                guard vLine >= lower, vLine < upper else { continue }

                let t = (vLine - segment.v0) / (segment.v1 - segment.v0)
                let uHit = segment.u0 + (segment.u1 - segment.u0) * t
                let x = (uHit - geometry.uMin) / uSpan * Float(width)
                rowHits[y].append((x, segment.shade))
            }
        }

        if showCheckerboard && useAlpha {
            fillCheckerboard(into: &out, width: width, height: height)
        }

        for y in 0..<height {
            guard !rowHits[y].isEmpty else { continue }
            let hits = compactRowHits(rowHits[y].sorted { $0.x < $1.x })
            guard hits.count >= 2 else { continue }

            var hitIndex = 0
            while hitIndex + 1 < hits.count {
                let left = hits[hitIndex]
                let right = hits[hitIndex + 1]
                let x0 = min(left.x, right.x)
                let x1 = max(left.x, right.x)
                let start = max(0, Int(ceil(x0)))
                let end = min(width, Int(floor(x1)))

                if start < end {
                    let shadeValue = max(150, min(255, Int(((left.shade + right.shade) * 0.5 * 255).rounded())))
                    let shade = UInt8(shadeValue)
                    let blue = UInt8(clamping: shadeValue + 6)
                    for x in start..<end {
                        let dst = (y * width + x) * 4
                        writePixel(
                            into: &out,
                            at: dst,
                            r: shade,
                            g: shade,
                            b: blue,
                            a: 255,
                            useAlpha: useAlpha
                        )
                    }
                }

                hitIndex += 2
            }
        }

        return out
    }

    private static func meshSliceSegments(
        cache: Cache,
        geometry: Geometry,
        d: Float
    ) -> [Segment] {
        let lightDirection = simd_normalize(SIMD3<Float>(-0.35, 0.65, 0.68))
        let triangleCount = cache.triangles.count
        let workerCount = min(max(1, ProcessInfo.processInfo.activeProcessorCount), max(1, triangleCount / 1_500))
        guard workerCount > 1 else {
            return meshSliceSegments(
                cache: cache,
                geometry: geometry,
                d: d,
                triangleRange: 0..<triangleCount,
                lightDirection: lightDirection
            )
        }

        let chunkSize = max(1, (triangleCount + workerCount - 1) / workerCount)
        var segments: [Segment] = []
        segments.reserveCapacity(triangleCount / 8)
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
            let start = workerIndex * chunkSize
            let end = min(triangleCount, start + chunkSize)
            guard start < end else { return }

            let local = meshSliceSegments(
                cache: cache,
                geometry: geometry,
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
        cache: Cache,
        geometry: Geometry,
        d: Float,
        triangleRange: Range<Int>,
        lightDirection: SIMD3<Float>
    ) -> [Segment] {
        let epsilon: Float = 0.000_01
        var segments: [Segment] = []
        segments.reserveCapacity(max(16, triangleRange.count / 8))

        for index in triangleRange {
            let triangle = cache.triangles[index]
            let da = simd_dot(triangle.a, geometry.n)
            let db = simd_dot(triangle.b, geometry.n)
            let dc = simd_dot(triangle.c, geometry.n)
            guard d >= min(da, db, dc) - epsilon, d <= max(da, db, dc) + epsilon else { continue }

            guard let pair = trianglePlaneIntersection(
                triangle: triangle,
                normal: geometry.n,
                d: d
            ) else { continue }

            let p0 = pair.0
            let p1 = pair.1
            let u0 = simd_dot(p0, geometry.u)
            let v0 = simd_dot(p0, geometry.v)
            let u1 = simd_dot(p1, geometry.u)
            let v1 = simd_dot(p1, geometry.v)
            guard abs(u1 - u0) + abs(v1 - v0) > 0.000_1 else { continue }

            let shade = max(0.68, min(1.0, 0.72 + 0.28 * abs(simd_dot(triangle.normal, lightDirection))))
            segments.append(Segment(u0: u0, v0: v0, u1: u1, v1: v1, shade: shade))
        }

        return segments
    }

    private static func trianglePlaneIntersection(
        triangle: Triangle,
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

    private static func compactRowHits(_ hits: [(x: Float, shade: Float)]) -> [(x: Float, shade: Float)] {
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

    private static func normalizedOrDefault(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(value)
        guard length > 0.000_001 else {
            let fallbackLength = simd_length(fallback)
            return fallbackLength > 0.000_001 ? fallback / fallbackLength : SIMD3<Float>(0, 0, 1)
        }
        return value / length
    }

    private static func fillCheckerboard(into out: inout [UInt8], width: Int, height: Int) {
        let tile = 12
        for y in 0..<height {
            for x in 0..<width {
                let isDark = ((x / tile) + (y / tile)) % 2 == 0
                let bg: UInt8 = isDark ? 92 : 132
                let dst = (y * width + x) * 4
                out[dst] = bg
                out[dst + 1] = bg
                out[dst + 2] = bg
                out[dst + 3] = 255
            }
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

        for y in 0..<dstHeight {
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
                        r += Int(src[s])
                        g += Int(src[s + 1])
                        b += Int(src[s + 2])
                        a += Int(src[s + 3])
                    }
                }

                let d = (y * dstWidth + x) * 4
                dst[d] = UInt8(clamping: (r + sampleCount / 2) / sampleCount)
                dst[d + 1] = UInt8(clamping: (g + sampleCount / 2) / sampleCount)
                dst[d + 2] = UInt8(clamping: (b + sampleCount / 2) / sampleCount)
                dst[d + 3] = UInt8(clamping: (a + sampleCount / 2) / sampleCount)
            }
        }

        return dst
    }

    private static func writePixel(
        into out: inout [UInt8],
        at dst: Int,
        r: UInt8,
        g: UInt8,
        b: UInt8,
        a: UInt8,
        useAlpha: Bool
    ) {
        out[dst] = r
        out[dst + 1] = g
        out[dst + 2] = b
        out[dst + 3] = useAlpha ? a : 255
    }

    private static func cgImageFromRGBA(width: Int, height: Int, rgba: [UInt8]) -> CGImage? {
        let bytesPerRow = width * 4
        let data = Data(rgba)

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
