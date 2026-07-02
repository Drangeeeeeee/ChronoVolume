import Foundation
import simd

struct MeshSurfaceVertex: Sendable {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

struct LoadedMesh: Sendable {
    let vertices: [MeshSurfaceVertex]
    let triangleCount: Int
}

extension LoadedMesh {
    func applying(_ modifiers: [MeshModifierItem]) -> LoadedMesh {
        guard !modifiers.isEmpty else { return self }
        var mesh = self
        for modifier in modifiers where modifier.isEnabled && !modifier.state.isIdentity {
            mesh = mesh.applying(modifier.state)
        }
        return mesh
    }

    func applying(_ modifier: MeshModifierState) -> LoadedMesh {
        guard !modifier.isIdentity, vertices.count >= 3 else { return self }

        let transform = meshModifierTransformMatrix(modifier)
        var transformed: [MeshSurfaceVertex] = []
        transformed.reserveCapacity(vertices.count)

        var index = 0
        while index + 2 < vertices.count {
            let deformedA = meshApplyShapeModifier(
                vertices[index].position,
                normal: vertices[index].normal,
                modifier: modifier
            )
            let deformedB = meshApplyShapeModifier(
                vertices[index + 1].position,
                normal: vertices[index + 1].normal,
                modifier: modifier
            )
            let deformedC = meshApplyShapeModifier(
                vertices[index + 2].position,
                normal: vertices[index + 2].normal,
                modifier: modifier
            )
            let a = meshTransformPoint(deformedA, transform)
            let b = meshTransformPoint(deformedB, transform)
            let c = meshTransformPoint(deformedC, transform)
            let normal = meshNormalizedOrDefault(
                simd_cross(b - a, c - a),
                fallback: vertices[index].normal
            )

            transformed.append(MeshSurfaceVertex(position: a, normal: normal))
            transformed.append(MeshSurfaceVertex(position: b, normal: normal))
            transformed.append(MeshSurfaceVertex(position: c, normal: normal))
            index += 3
        }

        if index < vertices.count {
            for vertex in vertices[index...] {
                transformed.append(
                    MeshSurfaceVertex(
                        position: meshTransformPoint(
                            meshApplyShapeModifier(vertex.position, normal: vertex.normal, modifier: modifier),
                            transform
                        ),
                        normal: vertex.normal
                    )
                )
            }
        }

        return LoadedMesh(vertices: transformed, triangleCount: triangleCount)
    }
}

struct LoadedMeshPackage: Sendable {
    let volume: LoadedVolume
    let mesh: LoadedMesh
    let triangleCount: Int
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
}

enum MeshVolumeLoaderError: LocalizedError {
    case unsupportedFormat(String)
    case invalidSTL
    case emptyMesh

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "暂不支持 \(ext.uppercased()) 模型格式"
        case .invalidSTL:
            return "无法解析 STL 模型"
        case .emptyMesh:
            return "模型没有可用三角面"
        }
    }
}

enum MeshVolumeLoader {
    static let supportedFileExtensions: Set<String> = ["stl"]

    static func isSupportedModelURL(_ url: URL) -> Bool {
        supportedFileExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(url: URL, maxResolution: Int = 128) throws -> LoadedMeshPackage {
        guard isSupportedModelURL(url) else {
            throw MeshVolumeLoaderError.unsupportedFormat(url.pathExtension)
        }

        let data = try Data(contentsOf: url)
        let triangles = try parseSTL(data: data)
        guard !triangles.isEmpty else { throw MeshVolumeLoaderError.emptyMesh }
        return voxelize(triangles: triangles, maxResolution: max(16, maxResolution))
    }

    private struct Triangle {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var c: SIMD3<Float>

        var normal: SIMD3<Float> {
            let n = simd_cross(b - a, c - a)
            let length = simd_length(n)
            guard length > 0.000_001 else { return SIMD3<Float>(0, 0, 1) }
            return n / length
        }
    }

    private static func parseSTL(data: Data) throws -> [Triangle] {
        if let binary = parseBinarySTL(data: data) {
            return binary
        }
        if let ascii = parseASCIISTL(data: data) {
            return ascii
        }
        throw MeshVolumeLoaderError.invalidSTL
    }

    private static func parseBinarySTL(data: Data) -> [Triangle]? {
        guard data.count >= 84 else { return nil }
        let count = Int(readUInt32(data, offset: 80))
        let expectedSize = 84 + count * 50
        guard count > 0, expectedSize <= data.count else { return nil }

        var triangles: [Triangle] = []
        triangles.reserveCapacity(count)

        var offset = 84
        for _ in 0..<count {
            offset += 12
            let a = SIMD3<Float>(
                readFloat32(data, offset: offset),
                readFloat32(data, offset: offset + 4),
                readFloat32(data, offset: offset + 8)
            )
            offset += 12
            let b = SIMD3<Float>(
                readFloat32(data, offset: offset),
                readFloat32(data, offset: offset + 4),
                readFloat32(data, offset: offset + 8)
            )
            offset += 12
            let c = SIMD3<Float>(
                readFloat32(data, offset: offset),
                readFloat32(data, offset: offset + 4),
                readFloat32(data, offset: offset + 8)
            )
            offset += 14
            if isFinite(a), isFinite(b), isFinite(c) {
                triangles.append(Triangle(a: a, b: b, c: c))
            }
        }

        return triangles.isEmpty ? nil : triangles
    }

    private static func parseASCIISTL(data: Data) -> [Triangle]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(1024)

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("vertex") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 4,
                  let x = Float(parts[1]),
                  let y = Float(parts[2]),
                  let z = Float(parts[3]) else {
                continue
            }
            let vertex = SIMD3<Float>(x, y, z)
            if isFinite(vertex) {
                vertices.append(vertex)
            }
        }

        guard vertices.count >= 3 else { return nil }
        var triangles: [Triangle] = []
        triangles.reserveCapacity(vertices.count / 3)
        var index = 0
        while index + 2 < vertices.count {
            triangles.append(Triangle(a: vertices[index], b: vertices[index + 1], c: vertices[index + 2]))
            index += 3
        }
        return triangles.isEmpty ? nil : triangles
    }

    private static func voxelize(triangles: [Triangle], maxResolution: Int) -> LoadedMeshPackage {
        var minPoint = triangles[0].a
        var maxPoint = triangles[0].a

        for triangle in triangles {
            for vertex in [triangle.a, triangle.b, triangle.c] {
                minPoint = simd.min(minPoint, vertex)
                maxPoint = simd.max(maxPoint, vertex)
            }
        }

        var extent = maxPoint - minPoint
        if extent.x <= 0 { extent.x = 1 }
        if extent.y <= 0 { extent.y = 1 }
        if extent.z <= 0 { extent.z = 1 }

        let surfaceMesh = makeSurfaceMesh(
            triangles: triangles,
            minPoint: minPoint,
            extent: extent
        )

        let longest = max(extent.x, max(extent.y, extent.z))
        let scale = Float(max(1, maxResolution - 4)) / max(longest, 0.000_001)
        let width = max(4, Int(ceil(extent.x * scale)) + 4)
        let height = max(4, Int(ceil(extent.y * scale)) + 4)
        let depth = max(4, Int(ceil(extent.z * scale)) + 4)
        let voxelCount = width * height * depth
        var surfaceAlpha = [UInt8](repeating: 0, count: voxelCount)
        var interior = [Bool](repeating: false, count: voxelCount)
        var normalAccum = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: voxelCount)
        var columnHits = [[Float]](repeating: [], count: width * height)

        func voxelIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
            (z * height + y) * width + x
        }

        func columnIndex(_ x: Int, _ y: Int) -> Int {
            y * width + x
        }

        func normalize(_ point: SIMD3<Float>) -> SIMD3<Float> {
            (point - minPoint) * scale + SIMD3<Float>(2, 2, 2)
        }

        let surfaceRadius: Float = 0.9
        for triangle in triangles {
            let a = normalize(triangle.a)
            let b = normalize(triangle.b)
            let c = normalize(triangle.c)
            let normal = triangle.normal
            let triMin = simd.min(a, simd.min(b, c))
            let triMax = simd.max(a, simd.max(b, c))

            let minX = max(0, Int(floor(triMin.x)) - 1)
            let minY = max(0, Int(floor(triMin.y)) - 1)
            let minZ = max(0, Int(floor(triMin.z)) - 1)
            let maxX = min(width - 1, Int(ceil(triMax.x)) + 1)
            let maxY = min(height - 1, Int(ceil(triMax.y)) + 1)
            let maxZ = min(depth - 1, Int(ceil(triMax.z)) + 1)

            guard minX <= maxX, minY <= maxY, minZ <= maxZ else { continue }

            for z in minZ...maxZ {
                for y in minY...maxY {
                    for x in minX...maxX {
                        let center = SIMD3<Float>(Float(x) + 0.5, Float(y) + 0.5, Float(z) + 0.5)
                        let distanceSquared = pointTriangleDistanceSquared(center, a, b, c)
                        guard distanceSquared <= surfaceRadius * surfaceRadius else { continue }
                        let distance = sqrt(distanceSquared)
                        let coverage = max(0, min(1, 1 - distance / surfaceRadius))
                        let alpha = UInt8(max(72, min(255, Int((coverage * 255).rounded()))))
                        let index = voxelIndex(x, y, z)
                        surfaceAlpha[index] = max(surfaceAlpha[index], alpha)
                        normalAccum[index] += normal * coverage
                    }
                }
            }

            guard abs(simd_cross(b - a, c - a).z) > 0.000_001 else { continue }
            let fillMinX = max(0, Int(floor(triMin.x)))
            let fillMinY = max(0, Int(floor(triMin.y)))
            let fillMaxX = min(width - 1, Int(ceil(triMax.x)))
            let fillMaxY = min(height - 1, Int(ceil(triMax.y)))
            guard fillMinX <= fillMaxX, fillMinY <= fillMaxY else { continue }

            for y in fillMinY...fillMaxY {
                for x in fillMinX...fillMaxX {
                    let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
                    guard let barycentric = barycentric2D(
                        point: p,
                        a: SIMD2<Float>(a.x, a.y),
                        b: SIMD2<Float>(b.x, b.y),
                        c: SIMD2<Float>(c.x, c.y)
                    ) else { continue }
                    let tolerance: Float = -0.000_1
                    guard barycentric.x >= tolerance,
                          barycentric.y >= tolerance,
                          barycentric.z >= tolerance else {
                        continue
                    }
                    let z = barycentric.x * a.z + barycentric.y * b.z + barycentric.z * c.z
                    if z >= 0, z <= Float(depth - 1) {
                        columnHits[columnIndex(x, y)].append(z)
                    }
                }
            }
        }

        for y in 0..<height {
            for x in 0..<width {
                var hits = columnHits[columnIndex(x, y)]
                guard hits.count >= 2 else { continue }
                hits.sort()
                hits = compactRayHits(hits)
                guard hits.count >= 2 else { continue }

                var hitIndex = 0
                while hitIndex + 1 < hits.count {
                    let start = max(0, Int(ceil(min(hits[hitIndex], hits[hitIndex + 1]))))
                    let end = min(depth - 1, Int(floor(max(hits[hitIndex], hits[hitIndex + 1]))))
                    if start <= end {
                        for z in start...end {
                            interior[voxelIndex(x, y, z)] = true
                        }
                    }
                    hitIndex += 2
                }
            }
        }

        var rgba = [UInt8](repeating: 0, count: voxelCount * 4)
        let lightDirection = simd_normalize(SIMD3<Float>(-0.35, 0.65, 0.68))
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    let sourceIndex = voxelIndex(x, y, z)
                    let alpha = surfaceAlpha[sourceIndex]
                    let isInterior = interior[sourceIndex]
                    guard alpha > 0 || isInterior else { continue }

                    let targetIndex = sourceIndex * 4
                    if alpha > 0 {
                        let normal = normalizedOrDefault(normalAccum[sourceIndex])
                        let lighting = 0.48 + 0.52 * abs(simd_dot(normal, lightDirection))
                        let shade = UInt8(max(148, min(255, Int((190 + 58 * lighting).rounded()))))
                        rgba[targetIndex] = shade
                        rgba[targetIndex + 1] = shade
                        rgba[targetIndex + 2] = UInt8(min(255, Int(shade) + 8))
                        rgba[targetIndex + 3] = alpha
                    } else {
                        rgba[targetIndex] = 224
                        rgba[targetIndex + 1] = 228
                        rgba[targetIndex + 2] = 238
                        rgba[targetIndex + 3] = 34
                    }
                }
            }
        }

        let volume = LoadedVolume(
            width: width,
            height: height,
            depth: depth,
            rgba: rgba,
            hasMeaningfulAlpha: true,
            sourceFPS: 30,
            sourceDurationSeconds: Double(depth) / 30.0,
            sourceFrameCountEstimate: depth,
            sourceColorProfile: .rec709
        )

        return LoadedMeshPackage(
            volume: volume,
            mesh: surfaceMesh,
            triangleCount: triangles.count,
            boundsMin: minPoint,
            boundsMax: maxPoint
        )
    }

    private static func makeSurfaceMesh(
        triangles: [Triangle],
        minPoint: SIMD3<Float>,
        extent: SIMD3<Float>
    ) -> LoadedMesh {
        let invExtent = SIMD3<Float>(
            1 / max(extent.x, 0.000_001),
            1 / max(extent.y, 0.000_001),
            1 / max(extent.z, 0.000_001)
        )

        func normalizePosition(_ point: SIMD3<Float>) -> SIMD3<Float> {
            let normalized = (point - minPoint) * invExtent
            return normalized - SIMD3<Float>(0.5, 0.5, 0.5)
        }

        var vertices: [MeshSurfaceVertex] = []
        vertices.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            let normal = triangle.normal
            vertices.append(MeshSurfaceVertex(position: normalizePosition(triangle.a), normal: normal))
            vertices.append(MeshSurfaceVertex(position: normalizePosition(triangle.b), normal: normal))
            vertices.append(MeshSurfaceVertex(position: normalizePosition(triangle.c), normal: normal))
        }

        return LoadedMesh(vertices: vertices, triangleCount: triangles.count)
    }

    private static func pointTriangleDistanceSquared(
        _ p: SIMD3<Float>,
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) -> Float {
        let ab = b - a
        let ac = c - a
        let ap = p - a

        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return simd_length_squared(ap) }

        let bp = p - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return simd_length_squared(bp) }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            let projection = a + v * ab
            return simd_length_squared(p - projection)
        }

        let cp = p - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return simd_length_squared(cp) }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            let projection = a + w * ac
            return simd_length_squared(p - projection)
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, (d4 - d3) >= 0, (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            let projection = b + w * (c - b)
            return simd_length_squared(p - projection)
        }

        let denominator = 1 / (va + vb + vc)
        let v = vb * denominator
        let w = vc * denominator
        let projection = a + ab * v + ac * w
        return simd_length_squared(p - projection)
    }

    private static func barycentric2D(
        point: SIMD2<Float>,
        a: SIMD2<Float>,
        b: SIMD2<Float>,
        c: SIMD2<Float>
    ) -> SIMD3<Float>? {
        let denominator = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
        guard abs(denominator) > 0.000_001 else { return nil }

        let w0 = ((b.y - c.y) * (point.x - c.x) + (c.x - b.x) * (point.y - c.y)) / denominator
        let w1 = ((c.y - a.y) * (point.x - c.x) + (a.x - c.x) * (point.y - c.y)) / denominator
        let w2 = 1 - w0 - w1
        return SIMD3<Float>(w0, w1, w2)
    }

    private static func compactRayHits(_ hits: [Float]) -> [Float] {
        guard let first = hits.first else { return [] }
        var compacted = [first]
        for hit in hits.dropFirst() {
            if abs(hit - compacted[compacted.count - 1]) > 0.35 {
                compacted.append(hit)
            }
        }
        return compacted
    }

    private static func normalizedOrDefault(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(value)
        guard length > 0.000_001 else { return SIMD3<Float>(0, 0, 1) }
        return value / length
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { target in
            data.copyBytes(to: target, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: value)
    }

    private static func readFloat32(_ data: Data, offset: Int) -> Float {
        Float(bitPattern: readUInt32(data, offset: offset))
    }

    private static func isFinite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}

private func meshModifierTransformMatrix(_ modifier: MeshModifierState) -> simd_float4x4 {
    let mirrorScale = SIMD3<Float>(
        (modifier.mirrorX ? -1 : 1) * max(0.000_1, modifier.scaleX),
        (modifier.mirrorY ? -1 : 1) * max(0.000_1, modifier.scaleY),
        (modifier.mirrorZ ? -1 : 1) * max(0.000_1, modifier.scaleZ)
    )
    let scale = meshScaleMatrix(mirrorScale)
    let rotX = meshRotationMatrix(angle: modifier.rotationX, axis: SIMD3<Float>(1, 0, 0))
    let rotY = meshRotationMatrix(angle: modifier.rotationY, axis: SIMD3<Float>(0, 1, 0))
    let rotZ = meshRotationMatrix(angle: modifier.rotationZ, axis: SIMD3<Float>(0, 0, 1))
    let translation = meshTranslationMatrix(SIMD3<Float>(
        modifier.positionX,
        modifier.positionY,
        modifier.positionZ
    ))
    return translation * rotZ * rotY * rotX * scale
}

private func meshTransformPoint(_ point: SIMD3<Float>, _ matrix: simd_float4x4) -> SIMD3<Float> {
    let p = matrix * SIMD4<Float>(point.x, point.y, point.z, 1)
    return SIMD3<Float>(p.x, p.y, p.z)
}

private func meshApplyShapeModifier(
    _ position: SIMD3<Float>,
    normal: SIMD3<Float>,
    modifier: MeshModifierState
) -> SIMD3<Float> {
    var p = position
    let vertical = max(-1, min(1, p.y * 2))

    if abs(modifier.taperX) > 0.000_001 {
        p.x *= max(0.000_1, 1 + modifier.taperX * vertical)
    }
    if abs(modifier.taperZ) > 0.000_001 {
        p.z *= max(0.000_1, 1 + modifier.taperZ * vertical)
    }

    if abs(modifier.twistY) > 0.000_001 {
        let angle = modifier.twistY * vertical
        let c = cos(angle)
        let s = sin(angle)
        let x = p.x * c - p.z * s
        let z = p.x * s + p.z * c
        p.x = x
        p.z = z
    }

    if abs(modifier.inflate) > 0.000_001 {
        p += meshNormalizedOrDefault(normal, fallback: SIMD3<Float>(0, 1, 0)) * modifier.inflate
    }

    return p
}

private func meshNormalizedOrDefault(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(value)
    if length > 0.000_001 {
        return value / length
    }
    let fallbackLength = simd_length(fallback)
    return fallbackLength > 0.000_001 ? fallback / fallbackLength : SIMD3<Float>(0, 0, 1)
}

private func meshTranslationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(t.x, t.y, t.z, 1)
    )
}

private func meshScaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(s.x, 0, 0, 0),
        SIMD4<Float>(0, s.y, 0, 0),
        SIMD4<Float>(0, 0, s.z, 0),
        SIMD4<Float>(0, 0, 0, 1)
    )
}

private func meshRotationMatrix(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let normalizedAxis = simd_normalize(axis)
    let x = normalizedAxis.x
    let y = normalizedAxis.y
    let z = normalizedAxis.z
    let c = cos(angle)
    let s = sin(angle)
    let t = 1 - c

    return simd_float4x4(
        SIMD4<Float>(t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0),
        SIMD4<Float>(t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0),
        SIMD4<Float>(t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0),
        SIMD4<Float>(0, 0, 0, 1)
    )
}
