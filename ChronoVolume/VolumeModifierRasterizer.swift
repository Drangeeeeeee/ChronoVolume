import Foundation
import Dispatch
import Metal
import simd

enum VolumeModifierRasterizer {
    fileprivate static let maxGPUModifierCount = 32
    private static let alphaBoundsFullScanVoxelLimit = 8_000_000
    private static let alphaBoundsSampleLimit = 2_000_000
    private static let sdfVoxelLimit = 40_000_000
    private static let distanceInfinity: Float = 1.0e20

    static func hasActiveModifiers(_ modifiers: [MeshModifierItem]) -> Bool {
        modifiers.contains(where: isActiveModifier)
    }

    private static func isActiveModifier(_ modifier: MeshModifierItem) -> Bool {
        modifier.isEnabled && (!modifier.state.isIdentity || modifier.state.inflateMode == .fracturedSurface)
    }

    static func downsampledPreviewVolumeForModifierEditing(
        from volume: LoadedVolume,
        maxBytes: Int
    ) -> LoadedVolume {
        let sourceBytes = volume.width * volume.height * volume.depth * 4
        guard sourceBytes > maxBytes,
              volume.width > 1 || volume.height > 1 || volume.depth > 1 else {
            return volume
        }

        var scale = 2
        while downsampledByteCount(volume: volume, scale: scale) > maxBytes,
              scale < max(volume.width, max(volume.height, volume.depth)) {
            scale += 1
        }

        let dstWidth = downsampledDimension(volume.width, scale: scale)
        let dstHeight = downsampledDimension(volume.height, scale: scale)
        let dstDepth = downsampledDimension(volume.depth, scale: scale)
        guard dstWidth > 0, dstHeight > 0, dstDepth > 0 else { return volume }

        let xMap = sampleIndexMap(sourceCount: volume.width, outputCount: dstWidth)
        let yMap = sampleIndexMap(sourceCount: volume.height, outputCount: dstHeight)
        let zMap = sampleIndexMap(sourceCount: volume.depth, outputCount: dstDepth)
        var rgba = [UInt8](repeating: 0, count: dstWidth * dstHeight * dstDepth * 4)

        volume.rgba.withUnsafeBufferPointer { srcBuffer in
            rgba.withUnsafeMutableBufferPointer { dstBuffer in
                guard let srcBase = srcBuffer.baseAddress,
                      let dstBase = dstBuffer.baseAddress else { return }

                DispatchQueue.concurrentPerform(iterations: dstDepth) { z in
                    let sourceZ = zMap[z]
                    for y in 0..<dstHeight {
                        let sourceY = yMap[y]
                        for x in 0..<dstWidth {
                            let sourceX = xMap[x]
                            let src = ((sourceZ * volume.height + sourceY) * volume.width + sourceX) * 4
                            let dst = ((z * dstHeight + y) * dstWidth + x) * 4
                            dstBase[dst] = srcBase[src]
                            dstBase[dst + 1] = srcBase[src + 1]
                            dstBase[dst + 2] = srcBase[src + 2]
                            dstBase[dst + 3] = srcBase[src + 3]
                        }
                    }
                }
            }
        }

        return LoadedVolume(
            width: dstWidth,
            height: dstHeight,
            depth: dstDepth,
            rgba: rgba,
            hasMeaningfulAlpha: volume.hasMeaningfulAlpha,
            sourceFPS: volume.sourceFPS,
            sourceDurationSeconds: volume.sourceDurationSeconds,
            sourceFrameCountEstimate: volume.sourceFrameCountEstimate,
            sourceColorProfile: volume.sourceColorProfile
        )
    }

    static func applying(_ modifiers: [MeshModifierItem], to volume: LoadedVolume) -> LoadedVolume {
        guard hasActiveModifiers(modifiers), volume.width > 0, volume.height > 0, volume.depth > 0 else {
            return volume
        }

        if !requiresSurfaceSDF(modifiers),
           let gpuVolume = applyingWithMetal(modifiers, to: volume, readBackToCPU: true) {
            return gpuVolume
        }

        let transformed = applying(modifiers, to: CPUVolume(
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            rgba: volume.rgba,
            hasMeaningfulAlpha: volume.hasMeaningfulAlpha,
            sourceColorProfile: volume.sourceColorProfile
        ))

        return LoadedVolume(
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            rgba: transformed.rgba,
            hasMeaningfulAlpha: transformed.hasMeaningfulAlpha,
            sourceFPS: volume.sourceFPS,
            sourceDurationSeconds: volume.sourceDurationSeconds,
            sourceFrameCountEstimate: volume.sourceFrameCountEstimate,
            sourceColorProfile: volume.sourceColorProfile
        )
    }

    static func applyingForInteractivePreview(_ modifiers: [MeshModifierItem], to volume: LoadedVolume) -> LoadedVolume {
        guard hasActiveModifiers(modifiers), volume.width > 0, volume.height > 0, volume.depth > 0 else {
            return volume
        }

        if !requiresSurfaceSDF(modifiers),
           let gpuVolume = applyingWithMetal(modifiers, to: volume, readBackToCPU: false) {
            return gpuVolume
        }

        return applying(modifiers, to: volume)
    }

    private static func requiresSurfaceSDF(_ modifiers: [MeshModifierItem]) -> Bool {
        modifiers.contains {
            guard isActiveModifier($0) else { return false }
            switch $0.state.inflateMode {
            case .surfaceSDF:
                return abs($0.state.inflate) > 0.000_001
            case .fracturedSurface:
                return true
            case .alphaBounds, .volumeCenter:
                return false
            }
        }
    }

    static func usesSurfaceSDFMode(_ modifiers: [MeshModifierItem]) -> Bool {
        requiresSurfaceSDF(modifiers)
    }

    private static func applyingWithMetal(
        _ modifiers: [MeshModifierItem],
        to volume: LoadedVolume,
        readBackToCPU: Bool
    ) -> LoadedVolume? {
        let activeModifiers = modifiers
            .filter(isActiveModifier)
            .prefix(maxGPUModifierCount)
        guard !activeModifiers.isEmpty else { return volume }
        let textureCacheID = UUID()
        guard let rgba = MetalVolumeModifierKernel.shared?.apply(
            modifiers: Array(activeModifiers),
            sourceID: volume.textureCacheID,
            resultID: textureCacheID,
            rgba: volume.rgba,
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            hasMeaningfulAlpha: volume.hasMeaningfulAlpha,
            readBackToCPU: readBackToCPU
        ) else {
            return nil
        }

        return LoadedVolume(
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            textureCacheID: textureCacheID,
            rgba: rgba,
            hasMeaningfulAlpha: volume.hasMeaningfulAlpha,
            sourceFPS: volume.sourceFPS,
            sourceDurationSeconds: volume.sourceDurationSeconds,
            sourceFrameCountEstimate: volume.sourceFrameCountEstimate,
            sourceColorProfile: volume.sourceColorProfile
        )
    }

    static func cachedModifiedTexture(for textureCacheID: UUID, device: MTLDevice) -> MTLTexture? {
        MetalVolumeModifierKernel.shared?.cachedModifiedTexture(for: textureCacheID, device: device)
    }

    static func materializedCPUVolume(from volume: LoadedVolume) -> LoadedVolume? {
        guard let rgba = MetalVolumeModifierKernel.shared?.readBackCachedTexture(
            for: volume.textureCacheID,
            width: volume.width,
            height: volume.height,
            depth: volume.depth
        ) else {
            return nil
        }

        return LoadedVolume(
            width: volume.width,
            height: volume.height,
            depth: volume.depth,
            textureCacheID: volume.textureCacheID,
            rgba: rgba,
            hasMeaningfulAlpha: volume.hasMeaningfulAlpha,
            sourceFPS: volume.sourceFPS,
            sourceDurationSeconds: volume.sourceDurationSeconds,
            sourceFrameCountEstimate: volume.sourceFrameCountEstimate,
            sourceColorProfile: volume.sourceColorProfile
        )
    }

    private static func downsampledDimension(_ value: Int, scale: Int) -> Int {
        max(1, Int(ceil(Double(value) / Double(max(1, scale)))))
    }

    private static func downsampledByteCount(volume: LoadedVolume, scale: Int) -> Int {
        downsampledDimension(volume.width, scale: scale)
            * downsampledDimension(volume.height, scale: scale)
            * downsampledDimension(volume.depth, scale: scale)
            * 4
    }

    private static func sampleIndexMap(sourceCount: Int, outputCount: Int) -> [Int] {
        guard outputCount > 0 else { return [] }
        guard sourceCount > 1 else { return Array(repeating: 0, count: outputCount) }
        guard outputCount > 1 else { return [sourceCount / 2] }

        return (0..<outputCount).map { index in
            let position = (Double(index) + 0.5) / Double(outputCount) * Double(sourceCount)
            return max(0, min(sourceCount - 1, Int(position.rounded(.down))))
        }
    }

    static func applying(_ modifiers: [MeshModifierItem], to volume: CPUVolume) -> CPUVolume {
        let activeModifiers = modifiers.filter(isActiveModifier)
        guard !activeModifiers.isEmpty, volume.width > 0, volume.height > 0, volume.depth > 0 else {
            return volume
        }

        if requiresSurfaceSDF(activeModifiers) {
            return applyingWithSurfaceSDF(activeModifiers, to: volume)
        }

        var rgba = [UInt8](repeating: 0, count: volume.rgba.count)
        let width = volume.width
        let height = volume.height
        let depth = volume.depth
        let source = volume.rgba
        let scale = volumeScale(width: width, height: height, depth: depth)
        let alphaCenter = alphaContentCenter(
            rgba: source,
            width: width,
            height: height,
            depth: depth,
            hasMeaningfulAlpha: volume.hasMeaningfulAlpha
        )
        let outsetScale = modifierOutsetScale(activeModifiers)
        let outsetCenter = modifierOutsetCenter(activeModifiers, alphaCenter: alphaCenter)

        rgba.withUnsafeMutableBufferPointer { dstBuffer in
            source.withUnsafeBufferPointer { srcBuffer in
                guard let dstBase = dstBuffer.baseAddress,
                      let srcBase = srcBuffer.baseAddress else { return }

                DispatchQueue.concurrentPerform(iterations: depth) { z in
                    for y in 0..<height {
                        for x in 0..<width {
                            let normalized = normalizedPoint(
                                x: x,
                                y: y,
                                z: z,
                                width: width,
                                height: height,
                                depth: depth
                            )
                            let virtualPoint = outsetCenter + (normalized - outsetCenter) * outsetScale
                            let sourcePoint = inverseMappedPoint(
                                virtualPoint,
                                modifiers: activeModifiers,
                                volumeScale: scale,
                                alphaCenter: alphaCenter
                            )
                            let voxel = denormalizedPoint(
                                sourcePoint,
                                width: width,
                                height: height,
                                depth: depth
                            )
                            let sample = sampleLinearRGBA(
                                source: srcBase,
                                width: width,
                                height: height,
                                depth: depth,
                                x: voxel.x,
                                y: voxel.y,
                                z: voxel.z
                            )
                            let dst = ((z * height + y) * width + x) * 4
                            dstBase[dst] = sample.x
                            dstBase[dst + 1] = sample.y
                            dstBase[dst + 2] = sample.z
                            dstBase[dst + 3] = sample.w
                        }
                    }
                }
            }
        }

        return CPUVolume(
            width: width,
            height: height,
            depth: depth,
            rgba: rgba,
            hasMeaningfulAlpha: volume.hasMeaningfulAlpha,
            sourceColorProfile: volume.sourceColorProfile
        )
    }

    private static func applyingWithSurfaceSDF(
        _ modifiers: [MeshModifierItem],
        to volume: CPUVolume
    ) -> CPUVolume {
        var current = volume
        for modifier in modifiers {
            guard isActiveModifier(modifier) else { continue }
            let shouldUseSurfaceSDF: Bool
            switch modifier.state.inflateMode {
            case .surfaceSDF:
                shouldUseSurfaceSDF = abs(modifier.state.inflate) > 0.000_001
            case .fracturedSurface:
                shouldUseSurfaceSDF = true
            case .alphaBounds, .volumeCenter:
                shouldUseSurfaceSDF = false
            }
            if shouldUseSurfaceSDF {
                var transformState = modifier.state
                let inflate = transformState.inflate
                let fractured = transformState.inflateMode == .fracturedSurface
                transformState.inflate = 0
                if !transformState.isIdentity {
                    let transformModifier = MeshModifierItem(
                        id: modifier.id,
                        name: modifier.name,
                        isEnabled: true,
                        state: transformState
                    )
                    current = applying([transformModifier], to: current)
                }
                current = applyingSurfaceSDFInflate(inflate, to: current, fractured: fractured)
            } else {
                current = applying([modifier], to: current)
            }
        }
        return current
    }

    private static func applyingSurfaceSDFInflate(
        _ inflate: Float,
        to volume: CPUVolume,
        fractured: Bool = false
    ) -> CPUVolume {
        let width = volume.width
        let height = volume.height
        let depth = volume.depth
        let voxelCount = width * height * depth
        guard voxelCount > 0,
              volume.rgba.count == voxelCount * 4 else {
            return applyingAlphaBoundsInflateFallback(inflate, to: volume)
        }
        guard voxelCount <= sdfVoxelLimit else {
            guard fractured else {
                return applyingAlphaBoundsInflateFallback(inflate, to: volume)
            }
            return applyingFracturedVolumeFallback(inflate, to: volume)
        }

        let maxDimension = max(1, max(width - 1, max(height - 1, depth - 1)))
        let requestedRadius = abs(inflate) * Float(maxDimension)
        let minimumFractureRadius = fractured ? max(2, Float(maxDimension) * 0.035) : 0
        let radius = max(requestedRadius, minimumFractureRadius)
        guard radius > 0.000_1 else { return volume }

        let isDilation = inflate >= 0
        let shouldGrowExterior = inflate > 0.000_1
        let source = volume.rgba
        var hasSeed = false
        var hasOccupiedAlpha = false
        var hasEmptyAlpha = false
        var distance = [Float](repeating: distanceInfinity, count: voxelCount)
        for voxelIndex in 0..<voxelCount {
            let alpha = source[voxelIndex * 4 + 3]
            let occupied = alpha > 8
            hasOccupiedAlpha = hasOccupiedAlpha || occupied
            hasEmptyAlpha = hasEmptyAlpha || !occupied
            let isSeed = isDilation ? occupied : !occupied
            if isSeed {
                distance[voxelIndex] = 0
                hasSeed = true
            }
        }
        guard hasOccupiedAlpha, hasEmptyAlpha else {
            return applyingAlphaBoundsInflateFallback(inflate, to: volume)
        }
        guard hasSeed else { return volume }

        exactSquaredDistanceTransform3D(&distance, width: width, height: height, depth: depth)
        let emptyDistance: [Float]? = fractured && isDilation
            ? squaredDistanceFieldToEmptyAlpha(source, width: width, height: height, depth: depth)
            : nil

        let alphaCenter = alphaContentCenter(
            rgba: source,
            width: width,
            height: height,
            depth: depth,
            hasMeaningfulAlpha: volume.hasMeaningfulAlpha
        )
        let centerVoxel = SIMD3<Float>(
            (alphaCenter.x + 0.5) * Float(max(0, width - 1)),
            (alphaCenter.y + 0.5) * Float(max(0, height - 1)),
            (alphaCenter.z + 0.5) * Float(max(0, depth - 1))
        )

        var output = [UInt8](repeating: 0, count: source.count)
        let colorSearchSteps = max(4, min(256, Int(ceil(radius)) + 8))

        for voxelIndex in 0..<voxelCount {
            let src = voxelIndex * 4
            let alpha = source[src + 3]
            let occupied = alpha > 8
            let distSquared = distance[voxelIndex]
            let x = voxelIndex % width
            let yz = voxelIndex / width
            let y = yz % height
            let z = yz / height
            let localRadius = fractured
                ? fracturedSurfaceRadius(
                    baseRadius: radius,
                    x: x,
                    y: y,
                    z: z,
                    width: width,
                    height: height,
                    depth: depth
                )
                : radius
            let localRadiusSquared = localRadius * localRadius

            if isDilation {
                if occupied {
                    if fractured,
                       shouldCutFractureVolumeVoxel(
                           radius: radius,
                           x: x,
                           y: y,
                           z: z
                       ) {
                        continue
                    }
                    if fractured,
                       let emptyDistance,
                       shouldCarveOriginalSurfaceVoxel(
                           distanceToEmpty: sqrt(max(0, emptyDistance[voxelIndex])),
                           radius: radius,
                           x: x,
                           y: y,
                           z: z
                       ) {
                        continue
                    }
                    let surfaceCoverage = fractured
                        ? originalSurfaceFractureCoverage(
                            distanceToEmpty: emptyDistance.map { sqrt(max(0, $0[voxelIndex])) } ?? Float.greatestFiniteMagnitude,
                            radius: radius,
                            alpha: alpha,
                            x: x,
                            y: y,
                            z: z
                        )
                        : 1
                    let volumeCoverage = fractured
                        ? fractureVolumeCoverage(radius: radius, x: x, y: y, z: z)
                        : 1
                    let totalCoverage = surfaceCoverage * volumeCoverage
                    output[src] = UInt8(max(0, min(255, Int(round(Float(source[src]) * totalCoverage)))))
                    output[src + 1] = UInt8(max(0, min(255, Int(round(Float(source[src + 1]) * totalCoverage)))))
                    output[src + 2] = UInt8(max(0, min(255, Int(round(Float(source[src + 2]) * totalCoverage)))))
                    output[src + 3] = UInt8(max(0, min(255, Int(round(Float(source[src + 3]) * totalCoverage)))))
                    continue
                }

                guard shouldGrowExterior, distSquared <= localRadiusSquared else { continue }
                let distanceToSurface = sqrt(max(0, distSquared))
                if fractured && shouldRemoveFractureVoxel(
                    distance: distanceToSurface,
                    radius: localRadius,
                    x: x,
                    y: y,
                    z: z
                ) {
                    continue
                }
                var coverage = max(0, min(1, localRadius - distanceToSurface + 1))
                if fractured {
                    coverage *= fracturedSurfaceCoverage(
                        distance: distanceToSurface,
                        radius: localRadius,
                        x: x,
                        y: y,
                        z: z
                    )
                }
                guard coverage > 0 else { continue }

                let color = nearestOpaqueColorTowardCenter(
                    source: source,
                    width: width,
                    height: height,
                    depth: depth,
                    x: x,
                    y: y,
                    z: z,
                    center: centerVoxel,
                    maxSteps: colorSearchSteps
                )
                output[src] = color.x
                output[src + 1] = color.y
                output[src + 2] = color.z
                output[src + 3] = UInt8(max(0, min(255, Int(round(255 * coverage)))))
            } else {
                guard occupied else { continue }
                let distanceToEmpty = sqrt(max(0, distSquared))
                let keepCoverage = max(0, min(1, distanceToEmpty - localRadius + 1))
                guard keepCoverage > 0 else { continue }
                output[src] = source[src]
                output[src + 1] = source[src + 1]
                output[src + 2] = source[src + 2]
                output[src + 3] = UInt8(max(0, min(255, Int(round(Float(alpha) * keepCoverage)))))
            }
        }

        return CPUVolume(
            width: width,
            height: height,
            depth: depth,
            rgba: output,
            hasMeaningfulAlpha: volume.hasMeaningfulAlpha || hasEmptyAlpha,
            sourceColorProfile: volume.sourceColorProfile
        )
    }

    private static func squaredDistanceFieldToEmptyAlpha(
        _ source: [UInt8],
        width: Int,
        height: Int,
        depth: Int
    ) -> [Float] {
        let voxelCount = width * height * depth
        var field = [Float](repeating: distanceInfinity, count: voxelCount)
        for voxelIndex in 0..<voxelCount where source[voxelIndex * 4 + 3] <= 8 {
            field[voxelIndex] = 0
        }
        exactSquaredDistanceTransform3D(&field, width: width, height: height, depth: depth)
        return field
    }

    private static func applyingFracturedVolumeFallback(_ inflate: Float, to volume: CPUVolume) -> CPUVolume {
        let base: CPUVolume
        if abs(inflate) > 0.000_1 {
            base = applyingAlphaBoundsInflateFallback(inflate, to: volume)
        } else {
            base = volume
        }

        let width = base.width
        let height = base.height
        let depth = base.depth
        let voxelCount = width * height * depth
        guard voxelCount > 0, base.rgba.count == voxelCount * 4 else { return base }

        let maxDimension = max(1, max(width - 1, max(height - 1, depth - 1)))
        let requestedRadius = abs(inflate) * Float(maxDimension)
        let radius = max(requestedRadius, max(2, Float(maxDimension) * 0.035))
        var output = base.rgba

        output.withUnsafeMutableBufferPointer { buffer in
            guard let dst = buffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: depth) { z in
                for y in 0..<height {
                    for x in 0..<width {
                        let index = ((z * height + y) * width + x) * 4
                        let alpha = dst[index + 3]
                        guard alpha > 8 else { continue }
                        if shouldCutFractureVolumeVoxel(radius: radius, x: x, y: y, z: z) {
                            dst[index] = 0
                            dst[index + 1] = 0
                            dst[index + 2] = 0
                            dst[index + 3] = 0
                            continue
                        }
                        let coverage = fractureVolumeCoverage(radius: radius, x: x, y: y, z: z)
                        dst[index] = UInt8(max(0, min(255, Int(round(Float(dst[index]) * coverage)))))
                        dst[index + 1] = UInt8(max(0, min(255, Int(round(Float(dst[index + 1]) * coverage)))))
                        dst[index + 2] = UInt8(max(0, min(255, Int(round(Float(dst[index + 2]) * coverage)))))
                        dst[index + 3] = UInt8(max(0, min(255, Int(round(Float(alpha) * coverage)))))
                    }
                }
            }
        }

        return CPUVolume(
            width: width,
            height: height,
            depth: depth,
            rgba: output,
            hasMeaningfulAlpha: true,
            sourceColorProfile: base.sourceColorProfile
        )
    }

    private static func shouldCarveOriginalSurfaceVoxel(
        distanceToEmpty: Float,
        radius: Float,
        x: Int,
        y: Int,
        z: Int
    ) -> Bool {
        let surfaceDepth = fractureSurfaceDepth(radius: radius)
        guard distanceToEmpty <= surfaceDepth else { return false }
        let surfaceAmount = 1 - max(0, min(1, distanceToEmpty / max(0.000_1, surfaceDepth)))
        let boundary = fractureBoundaryProximity(x: x, y: y, z: z, radius: radius, salt: 619)
        if boundary > 0.72 && surfaceAmount > 0.16 {
            return true
        }

        let crackScale = max(2, radius * 0.060)
        let shardScale = max(2, radius * 0.022)
        let crack = valueNoise3D(
            Float(x) / crackScale,
            Float(y) / crackScale,
            Float(z) / crackScale,
            salt: 421
        )
        let shard = valueNoise3D(
            Float(x) / shardScale,
            Float(y) / shardScale,
            Float(z) / shardScale,
            salt: 557
        )
        let threshold = 0.24 + surfaceAmount * 0.46
        return crack * 0.52 + shard * 0.28 + (1 - boundary) * 0.20 < threshold
    }

    private static func originalSurfaceFractureCoverage(
        distanceToEmpty: Float,
        radius: Float,
        alpha: UInt8,
        x: Int,
        y: Int,
        z: Int
    ) -> Float {
        guard alpha > 8 else { return 0 }
        let surfaceDepth = fractureSurfaceDepth(radius: radius)
        guard distanceToEmpty <= surfaceDepth else { return 1 }
        let surfaceAmount = 1 - max(0, min(1, distanceToEmpty / max(0.000_1, surfaceDepth)))
        let boundary = fractureBoundaryProximity(x: x, y: y, z: z, radius: radius, salt: 761)
        let grainScale = max(2, radius * 0.028)
        let grain = valueNoise3D(
            Float(x) / grainScale,
            Float(y) / grainScale,
            Float(z) / grainScale,
            salt: 733
        )
        return max(0.12, min(1, 0.78 + grain * 0.30 - surfaceAmount * 0.34 - boundary * 0.38))
    }

    private static func shouldCutFractureVolumeVoxel(
        radius: Float,
        x: Int,
        y: Int,
        z: Int
    ) -> Bool {
        let boundary = fractureBoundaryProximity(x: x, y: y, z: z, radius: radius, salt: 991)
        guard boundary > 0.44 else { return false }
        let grainScale = max(2, radius * 0.055)
        let grain = valueNoise3D(
            Float(x) / grainScale,
            Float(y) / grainScale,
            Float(z) / grainScale,
            salt: 887
        )
        let chip = hashUnit(x / 3, y / 3, z / 3, salt: 919)
        return boundary * 0.80 + grain * 0.12 + chip * 0.08 > 0.60
    }

    private static func fractureVolumeCoverage(
        radius: Float,
        x: Int,
        y: Int,
        z: Int
    ) -> Float {
        let boundary = fractureBoundaryProximity(x: x, y: y, z: z, radius: radius, salt: 1031)
        guard boundary > 0.12 else { return 1 }
        let grainScale = max(2, radius * 0.040)
        let grain = valueNoise3D(
            Float(x) / grainScale,
            Float(y) / grainScale,
            Float(z) / grainScale,
            salt: 1063
        )
        return max(0.04, min(1, 1 - boundary * 0.82 + grain * 0.16))
    }

    private static func fractureSurfaceDepth(radius: Float) -> Float {
        max(3.0, min(96.0, radius * 0.85))
    }

    private static func fracturedSurfaceRadius(
        baseRadius: Float,
        x: Int,
        y: Int,
        z: Int,
        width: Int,
        height: Int,
        depth: Int
    ) -> Float {
        let coarseScale = max(3, baseRadius * 0.45)
        let fineScale = max(2, baseRadius * 0.16)
        let nx = Float(x) / coarseScale
        let ny = Float(y) / coarseScale
        let nz = Float(z) / coarseScale
        let fx = Float(x) / fineScale
        let fy = Float(y) / fineScale
        let fz = Float(z) / fineScale
        let coarse = valueNoise3D(nx, ny, nz, salt: 17)
        let fine = valueNoise3D(fx, fy, fz, salt: 53)
        let axisShard = valueNoise3D(
            Float(x) / max(2, Float(max(1, width)) * 0.035),
            Float(y) / max(2, Float(max(1, height)) * 0.035),
            Float(z) / max(2, Float(max(1, depth)) * 0.035),
            salt: 89
        )
        let noise = max(0, min(1, coarse * 0.56 + fine * 0.28 + axisShard * 0.16))
        return max(0.25, baseRadius * (0.46 + noise * 0.98))
    }

    private static func shouldRemoveFractureVoxel(
        distance: Float,
        radius: Float,
        x: Int,
        y: Int,
        z: Int
    ) -> Bool {
        guard radius > 1 else { return false }
        let normalizedDistance = max(0, min(1, distance / radius))
        guard normalizedDistance > 0.08 else { return false }
        let boundary = fractureBoundaryProximity(x: x, y: y, z: z, radius: radius, salt: 283)
        if boundary > 0.66 {
            return true
        }
        let crackScale = max(2, radius * 0.11)
        let crack = valueNoise3D(
            Float(x) / crackScale,
            Float(y) / crackScale,
            Float(z) / crackScale,
            salt: 131
        )
        let shard = hashUnit(x / 2, y / 2, z / 2, salt: 211)
        let threshold = 0.12 + normalizedDistance * 0.28
        return crack * 0.62 + shard * 0.22 + (1 - boundary) * 0.16 < threshold
    }

    private static func fracturedSurfaceCoverage(
        distance: Float,
        radius: Float,
        x: Int,
        y: Int,
        z: Int
    ) -> Float {
        guard radius > 1 else { return 1 }
        let normalizedDistance = max(0, min(1, distance / radius))
        let boundary = fractureBoundaryProximity(x: x, y: y, z: z, radius: radius, salt: 347)
        let grainScale = max(2, radius * 0.06)
        let grain = valueNoise3D(
            Float(x) / grainScale,
            Float(y) / grainScale,
            Float(z) / grainScale,
            salt: 307
        )
        return max(0.08, min(1, 0.56 + grain * 0.48 - normalizedDistance * 0.18 - boundary * 0.42))
    }

    private static func fractureBoundaryProximity(
        x: Int,
        y: Int,
        z: Int,
        radius: Float,
        salt: Int
    ) -> Float {
        let scale = max(4, radius * 0.26)
        let warpScale = max(3, radius * 0.10)
        let warpAmount: Float = 0.42
        let px = Float(x) / scale + (valueNoise3D(Float(x) / warpScale, Float(y) / warpScale, Float(z) / warpScale, salt: salt) - 0.5) * warpAmount
        let py = Float(y) / scale + (valueNoise3D(Float(x) / warpScale, Float(y) / warpScale, Float(z) / warpScale, salt: salt + 37) - 0.5) * warpAmount
        let pz = Float(z) / scale + (valueNoise3D(Float(x) / warpScale, Float(y) / warpScale, Float(z) / warpScale, salt: salt + 73) - 0.5) * warpAmount
        let dx = distanceToNearestInteger(px)
        let dy = distanceToNearestInteger(py)
        let dz = distanceToNearestInteger(pz)
        let boundaryDistance = min(dx, min(dy, dz))
        let thickness = max(0.035, min(0.18, 0.09 + radius * 0.0015))
        return max(0, min(1, 1 - boundaryDistance / thickness))
    }

    private static func distanceToNearestInteger(_ value: Float) -> Float {
        let f = value - floor(value)
        return min(f, 1 - f)
    }

    private static func valueNoise3D(_ x: Float, _ y: Float, _ z: Float, salt: Int) -> Float {
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let z0 = Int(floor(z))
        let tx = smoothNoiseStep(x - Float(x0))
        let ty = smoothNoiseStep(y - Float(y0))
        let tz = smoothNoiseStep(z - Float(z0))

        func h(_ dx: Int, _ dy: Int, _ dz: Int) -> Float {
            hashUnit(x0 + dx, y0 + dy, z0 + dz, salt: salt)
        }

        let c00 = mix(h(0, 0, 0), h(1, 0, 0), tx)
        let c10 = mix(h(0, 1, 0), h(1, 1, 0), tx)
        let c01 = mix(h(0, 0, 1), h(1, 0, 1), tx)
        let c11 = mix(h(0, 1, 1), h(1, 1, 1), tx)
        let c0 = mix(c00, c10, ty)
        let c1 = mix(c01, c11, ty)
        return mix(c0, c1, tz)
    }

    private static func hashUnit(_ x: Int, _ y: Int, _ z: Int, salt: Int) -> Float {
        var h = UInt32(truncatingIfNeeded:
            x &* 374_761_393
            ^ y &* 668_265_263
            ^ z &* 2_246_822_519
            ^ salt &* 3_266_489_917
        )
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h = h ^ (h >> 16)
        return Float(h & 0x00ff_ffff) / Float(0x00ff_ffff)
    }

    private static func smoothNoiseStep(_ value: Float) -> Float {
        let t = max(0, min(1, value))
        return t * t * (3 - 2 * t)
    }

    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    private static func applyingAlphaBoundsInflateFallback(_ inflate: Float, to volume: CPUVolume) -> CPUVolume {
        let fallback = MeshModifierItem(
            name: "SDF fallback",
            state: MeshModifierState(inflate: inflate, inflateMode: .alphaBounds)
        )
        return applying([fallback], to: volume)
    }

    private static func exactSquaredDistanceTransform3D(
        _ field: inout [Float],
        width: Int,
        height: Int,
        depth: Int
    ) {
        guard width > 0, height > 0, depth > 0 else { return }
        var temp = [Float](repeating: 0, count: field.count)

        var line = [Float](repeating: 0, count: width)
        var transformed = [Float](repeating: 0, count: width)
        for z in 0..<depth {
            for y in 0..<height {
                let base = (z * height + y) * width
                for x in 0..<width {
                    line[x] = field[base + x]
                }
                squaredDistanceTransform1D(line, output: &transformed)
                for x in 0..<width {
                    temp[base + x] = transformed[x]
                }
            }
        }

        line = [Float](repeating: 0, count: height)
        transformed = [Float](repeating: 0, count: height)
        for z in 0..<depth {
            for x in 0..<width {
                for y in 0..<height {
                    line[y] = temp[(z * height + y) * width + x]
                }
                squaredDistanceTransform1D(line, output: &transformed)
                for y in 0..<height {
                    field[(z * height + y) * width + x] = transformed[y]
                }
            }
        }

        line = [Float](repeating: 0, count: depth)
        transformed = [Float](repeating: 0, count: depth)
        for y in 0..<height {
            for x in 0..<width {
                for z in 0..<depth {
                    line[z] = field[(z * height + y) * width + x]
                }
                squaredDistanceTransform1D(line, output: &transformed)
                for z in 0..<depth {
                    temp[(z * height + y) * width + x] = transformed[z]
                }
            }
        }

        field = temp
    }

    private static func squaredDistanceTransform1D(_ input: [Float], output: inout [Float]) {
        let count = input.count
        guard count > 0, output.count == count else { return }
        guard count > 1 else {
            output[0] = input[0]
            return
        }

        var locations = [Int](repeating: 0, count: count)
        var boundaries = [Float](repeating: 0, count: count + 1)
        var k = -1

        for q in 0..<count where input[q] < distanceInfinity * 0.5 {
            var intersection = -Float.infinity
            while k >= 0 {
                let p = locations[k]
                let fq = Float(q)
                let fp = Float(p)
                let numerator = (input[q] + fq * fq) - (input[p] + fp * fp)
                let denominator = Float(2 * (q - p))
                intersection = numerator / denominator
                if intersection <= boundaries[k] {
                    k -= 1
                } else {
                    break
                }
            }

            k += 1
            locations[k] = q
            boundaries[k] = k == 0 ? -Float.infinity : intersection
            boundaries[k + 1] = Float.infinity
        }

        guard k >= 0 else {
            output = [Float](repeating: distanceInfinity, count: count)
            return
        }

        var envelopeIndex = 0
        for q in 0..<count {
            while boundaries[envelopeIndex + 1] < Float(q) {
                envelopeIndex += 1
            }
            let p = locations[envelopeIndex]
            let delta = Float(q - p)
            output[q] = delta * delta + input[p]
        }
    }

    private static func nearestOpaqueColorTowardCenter(
        source: [UInt8],
        width: Int,
        height: Int,
        depth: Int,
        x: Int,
        y: Int,
        z: Int,
        center: SIMD3<Float>,
        maxSteps: Int
    ) -> SIMD4<UInt8> {
        let start = SIMD3<Float>(Float(x), Float(y), Float(z))
        let direction = center - start
        let length = simd_length(direction)
        guard length > 0.000_1 else {
            return nearestOpaqueColorInSmallNeighborhood(
                source: source,
                width: width,
                height: height,
                depth: depth,
                x: x,
                y: y,
                z: z
            )
        }
        let step = direction / length
        let iterations = min(maxSteps, max(1, Int(ceil(length))))
        for index in 1...iterations {
            let point = start + step * Float(index)
            let sx = max(0, min(width - 1, Int(round(point.x))))
            let sy = max(0, min(height - 1, Int(round(point.y))))
            let sz = max(0, min(depth - 1, Int(round(point.z))))
            let sampleIndex = ((sz * height + sy) * width + sx) * 4
            if source[sampleIndex + 3] > 8 {
                return SIMD4<UInt8>(
                    source[sampleIndex],
                    source[sampleIndex + 1],
                    source[sampleIndex + 2],
                    255
                )
            }
        }

        return nearestOpaqueColorInSmallNeighborhood(
            source: source,
            width: width,
            height: height,
            depth: depth,
            x: x,
            y: y,
            z: z
        )
    }

    private static func nearestOpaqueColorInSmallNeighborhood(
        source: [UInt8],
        width: Int,
        height: Int,
        depth: Int,
        x: Int,
        y: Int,
        z: Int
    ) -> SIMD4<UInt8> {
        for radius in 1...3 {
            let minX = max(0, x - radius)
            let maxX = min(width - 1, x + radius)
            let minY = max(0, y - radius)
            let maxY = min(height - 1, y + radius)
            let minZ = max(0, z - radius)
            let maxZ = min(depth - 1, z + radius)
            for zz in minZ...maxZ {
                for yy in minY...maxY {
                    for xx in minX...maxX {
                        let index = ((zz * height + yy) * width + xx) * 4
                        if source[index + 3] > 8 {
                            return SIMD4<UInt8>(
                                source[index],
                                source[index + 1],
                                source[index + 2],
                                255
                            )
                        }
                    }
                }
            }
        }
        return SIMD4<UInt8>(255, 255, 255, 255)
    }

    fileprivate static func volumeScale(width: Int, height: Int, depth: Int) -> SIMD3<Float> {
        let maxDimension = Float(max(1, max(width, max(height, depth))))
        return SIMD3<Float>(
            Float(max(1, width)) / maxDimension,
            Float(max(1, height)) / maxDimension,
            Float(max(1, depth)) / maxDimension
        )
    }

    private static func safeVolumeScale(_ scale: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            max(0.000_1, scale.x),
            max(0.000_1, scale.y),
            max(0.000_1, scale.z)
        )
    }

    fileprivate static func modifierOutsetScale(_ modifiers: [MeshModifierItem]) -> Float {
        let positiveInflate = modifiers.reduce(Float(0)) { partial, item in
            partial + max(0, item.state.inflate)
        }
        return min(4, max(1, 1 + positiveInflate * 2))
    }

    fileprivate static func alphaContentCenter(
        rgba: [UInt8],
        width: Int,
        height: Int,
        depth: Int,
        hasMeaningfulAlpha: Bool
    ) -> SIMD3<Float> {
        guard width > 1 || height > 1 || depth > 1 else { return .zero }
        guard rgba.count == width * height * depth * 4 else { return .zero }

        let voxelCount = width * height * depth
        let shouldFullScan = voxelCount <= alphaBoundsFullScanVoxelLimit
        let stride = shouldFullScan ? 1 : max(1, voxelCount / alphaBoundsSampleLimit)
        var minX = width
        var minY = height
        var minZ = depth
        var maxX = -1
        var maxY = -1
        var maxZ = -1

        func includeVoxel(_ voxelIndex: Int) {
            let alpha = rgba[voxelIndex * 4 + 3]
            guard alpha > 8 else { return }
            let x = voxelIndex % width
            let yz = voxelIndex / width
            let y = yz % height
            let z = yz / height
            minX = min(minX, x)
            minY = min(minY, y)
            minZ = min(minZ, z)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
            maxZ = max(maxZ, z)
        }

        var voxelIndex = 0
        while voxelIndex < voxelCount {
            includeVoxel(voxelIndex)
            voxelIndex += stride
        }

        if maxX < minX, stride > 1 {
            voxelIndex = 0
            while voxelIndex < voxelCount {
                includeVoxel(voxelIndex)
                voxelIndex += 1
                if maxX >= minX { break }
            }
        }

        guard maxX >= minX, maxY >= minY, maxZ >= minZ else { return .zero }
        return SIMD3<Float>(
            width > 1 ? (Float(minX + maxX) * 0.5) / Float(width - 1) - 0.5 : 0,
            height > 1 ? (Float(minY + maxY) * 0.5) / Float(height - 1) - 0.5 : 0,
            depth > 1 ? (Float(minZ + maxZ) * 0.5) / Float(depth - 1) - 0.5 : 0
        )
    }

    fileprivate static func modifierOutsetCenter(
        _ modifiers: [MeshModifierItem],
        alphaCenter: SIMD3<Float>
    ) -> SIMD3<Float> {
        modifiers.contains {
            $0.state.inflateMode == .alphaBounds && $0.state.inflate > 0.000_001
        } ? alphaCenter : .zero
    }

    private static func normalizedPoint(
        x: Int,
        y: Int,
        z: Int,
        width: Int,
        height: Int,
        depth: Int
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            width > 1 ? Float(x) / Float(width - 1) - 0.5 : 0,
            height > 1 ? Float(y) / Float(height - 1) - 0.5 : 0,
            depth > 1 ? Float(z) / Float(depth - 1) - 0.5 : 0
        )
    }

    private static func denormalizedPoint(
        _ p: SIMD3<Float>,
        width: Int,
        height: Int,
        depth: Int
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            (p.x + 0.5) * Float(max(0, width - 1)),
            (p.y + 0.5) * Float(max(0, height - 1)),
            (p.z + 0.5) * Float(max(0, depth - 1))
        )
    }

    private static func inverseMappedPoint(
        _ point: SIMD3<Float>,
        modifiers: [MeshModifierItem],
        volumeScale: SIMD3<Float>,
        alphaCenter: SIMD3<Float>
    ) -> SIMD3<Float> {
        var p = point
        for modifier in modifiers.reversed() {
            p = inverseApply(
                p,
                modifier: modifier.state,
                volumeScale: volumeScale,
                alphaCenter: alphaCenter
            )
        }
        return p
    }

    private static func inverseApply(
        _ point: SIMD3<Float>,
        modifier: MeshModifierState,
        volumeScale: SIMD3<Float>,
        alphaCenter: SIMD3<Float>
    ) -> SIMD3<Float> {
        let affine = modifierTransformMatrix(modifier)
        var p = transformPoint(point, simd_inverse(affine))
        p = inverseShape(
            p,
            modifier: modifier,
            volumeScale: volumeScale,
            alphaCenter: alphaCenter
        )
        return p
    }

    private static func inverseShape(
        _ point: SIMD3<Float>,
        modifier: MeshModifierState,
        volumeScale: SIMD3<Float>,
        alphaCenter: SIMD3<Float>
    ) -> SIMD3<Float> {
        var p = point

        if abs(modifier.inflate) > 0.000_001 {
            let safeScale = safeVolumeScale(volumeScale)
            let center = modifier.inflateMode == .alphaBounds ? alphaCenter : SIMD3<Float>.zero
            var scaledPoint = (p - center) * safeScale
            let length = simd_length(scaledPoint)
            if length > 0.000_001 {
                scaledPoint -= (scaledPoint / length) * modifier.inflate
                p = center + scaledPoint / safeScale
            }
        }

        let vertical = max(-1, min(1, p.y * 2))

        if abs(modifier.twistY) > 0.000_001 {
            let angle = -modifier.twistY * vertical
            let c = cos(angle)
            let s = sin(angle)
            let x = p.x * c - p.z * s
            let z = p.x * s + p.z * c
            p.x = x
            p.z = z
        }

        if abs(modifier.taperX) > 0.000_001 {
            p.x /= max(0.000_1, 1 + modifier.taperX * vertical)
        }
        if abs(modifier.taperZ) > 0.000_001 {
            p.z /= max(0.000_1, 1 + modifier.taperZ * vertical)
        }

        return p
    }

    private static func sampleLinearRGBA(
        source: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        depth: Int,
        x: Float,
        y: Float,
        z: Float
    ) -> SIMD4<UInt8> {
        guard x >= 0, x <= Float(width - 1),
              y >= 0, y <= Float(height - 1),
              z >= 0, z <= Float(depth - 1) else {
            return SIMD4<UInt8>(0, 0, 0, 0)
        }

        let x0 = Int(floor(x))
        let x1 = min(x0 + 1, width - 1)
        let y0 = Int(floor(y))
        let y1 = min(y0 + 1, height - 1)
        let z0 = Int(floor(z))
        let z1 = min(z0 + 1, depth - 1)

        let fx = x - Float(x0)
        let fy = y - Float(y0)
        let fz = z - Float(z0)

        func sample(_ zz: Int, _ yy: Int, _ xx: Int) -> SIMD4<Float> {
            let index = ((zz * height + yy) * width + xx) * 4
            return SIMD4<Float>(
                Float(source[index]),
                Float(source[index + 1]),
                Float(source[index + 2]),
                Float(source[index + 3])
            )
        }

        let c000 = sample(z0, y0, x0)
        let c100 = sample(z0, y0, x1)
        let c010 = sample(z0, y1, x0)
        let c110 = sample(z0, y1, x1)
        let c001 = sample(z1, y0, x0)
        let c101 = sample(z1, y0, x1)
        let c011 = sample(z1, y1, x0)
        let c111 = sample(z1, y1, x1)

        let c00 = simd_mix(c000, c100, SIMD4<Float>(repeating: fx))
        let c10 = simd_mix(c010, c110, SIMD4<Float>(repeating: fx))
        let c01 = simd_mix(c001, c101, SIMD4<Float>(repeating: fx))
        let c11 = simd_mix(c011, c111, SIMD4<Float>(repeating: fx))
        let c0 = simd_mix(c00, c10, SIMD4<Float>(repeating: fy))
        let c1 = simd_mix(c01, c11, SIMD4<Float>(repeating: fy))
        let c = simd_mix(c0, c1, SIMD4<Float>(repeating: fz))

        return SIMD4<UInt8>(
            UInt8(max(0, min(255, Int(round(c.x))))),
            UInt8(max(0, min(255, Int(round(c.y))))),
            UInt8(max(0, min(255, Int(round(c.z))))),
            UInt8(max(0, min(255, Int(round(c.w)))))
        )
    }

    private static func modifierTransformMatrix(_ modifier: MeshModifierState) -> simd_float4x4 {
        let scale = SIMD3<Float>(
            (modifier.mirrorX ? -1 : 1) * max(0.000_1, modifier.scaleX),
            (modifier.mirrorY ? -1 : 1) * max(0.000_1, modifier.scaleY),
            (modifier.mirrorZ ? -1 : 1) * max(0.000_1, modifier.scaleZ)
        )
        let s = scaleMatrix(scale)
        let rx = rotationMatrix(angle: modifier.rotationX, axis: SIMD3<Float>(1, 0, 0))
        let ry = rotationMatrix(angle: modifier.rotationY, axis: SIMD3<Float>(0, 1, 0))
        let rz = rotationMatrix(angle: modifier.rotationZ, axis: SIMD3<Float>(0, 0, 1))
        let t = translationMatrix(SIMD3<Float>(
            modifier.positionX,
            modifier.positionY,
            modifier.positionZ
        ))
        return t * rz * ry * rx * s
    }

    private static func transformPoint(_ p: SIMD3<Float>, _ matrix: simd_float4x4) -> SIMD3<Float> {
        let v = matrix * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }

    private static func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        )
    }

    private static func scaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(s.x, 0, 0, 0),
            SIMD4<Float>(0, s.y, 0, 0),
            SIMD4<Float>(0, 0, s.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func rotationMatrix(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        let a = simd_normalize(axis)
        let c = cos(angle)
        let s = sin(angle)
        let oneMinusC = 1 - c

        return simd_float4x4(
            SIMD4<Float>(
                c + a.x * a.x * oneMinusC,
                a.x * a.y * oneMinusC + a.z * s,
                a.x * a.z * oneMinusC - a.y * s,
                0
            ),
            SIMD4<Float>(
                a.y * a.x * oneMinusC - a.z * s,
                c + a.y * a.y * oneMinusC,
                a.y * a.z * oneMinusC + a.x * s,
                0
            ),
            SIMD4<Float>(
                a.z * a.x * oneMinusC + a.y * s,
                a.z * a.y * oneMinusC - a.x * s,
                c + a.z * a.z * oneMinusC,
                0
            ),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }
}

private struct VolumeModifierGPUUniforms {
    var width: UInt32
    var height: UInt32
    var depth: UInt32
    var modifierCount: UInt32
    var volumeScaleAndOutset: SIMD4<Float>
    var outsetCenter: SIMD4<Float>
}

private struct VolumeModifierGPUItem {
    var inverseAffine: simd_float4x4
    var shape: SIMD4<Float>
    var inflateCenter: SIMD4<Float>
}

private struct VolumeModifierSourceTextureKey: Hashable {
    let sourceID: UUID
    let width: Int
    let height: Int
    let depth: Int
    let byteCount: Int
}

private struct VolumeModifierSourceTextureEntry {
    let texture: MTLTexture
    let byteCount: Int
}

private struct VolumeModifierResultTextureEntry {
    let texture: MTLTexture
    let byteCount: Int
}

private struct VolumeModifierTextureSizeKey: Hashable {
    let width: Int
    let height: Int
    let depth: Int
    let byteCount: Int
}

private final class MetalVolumeModifierKernel {
    static let shared = MetalVolumeModifierKernel()

    private static let maxSourceTextureCacheBytes = 384 * 1024 * 1024
    private static let maxResultTextureCacheBytes = 384 * 1024 * 1024
    private static let maxOutputTexturePoolBytes = 192 * 1024 * 1024

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let cacheLock = NSLock()
    private var sourceTextureCache: [VolumeModifierSourceTextureKey: VolumeModifierSourceTextureEntry] = [:]
    private var sourceTextureCacheOrder: [VolumeModifierSourceTextureKey] = []
    private var sourceTextureCacheBytes: Int = 0
    private var resultTextureCache: [UUID: VolumeModifierResultTextureEntry] = [:]
    private var resultTextureCacheOrder: [UUID] = []
    private var resultTextureCacheBytes: Int = 0
    private var outputTexturePool: [VolumeModifierTextureSizeKey: MTLTexture] = [:]
    private var outputTexturePoolOrder: [VolumeModifierTextureSizeKey] = []
    private var outputTexturePoolBytes: Int = 0

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "volumeModifierKernel") else {
            return nil
        }

        do {
            self.device = device
            self.queue = queue
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            return nil
        }
    }

    func apply(
        modifiers: [MeshModifierItem],
        sourceID: UUID,
        resultID: UUID,
        rgba: [UInt8],
        width: Int,
        height: Int,
        depth: Int,
        hasMeaningfulAlpha: Bool,
        readBackToCPU: Bool = true
    ) -> [UInt8]? {
        guard width > 0, height > 0, depth > 0 else { return nil }
        guard rgba.count == width * height * depth * 4 else { return nil }
        guard !modifiers.isEmpty else { return rgba }

        let sourceDescriptor = makeTextureDescriptor(
            width: width,
            height: height,
            depth: depth,
            usage: [.shaderRead]
        )
        let sourceKey = VolumeModifierSourceTextureKey(
            sourceID: sourceID,
            width: width,
            height: height,
            depth: depth,
            byteCount: rgba.count
        )
        let region = MTLRegionMake3D(0, 0, 0, width, height, depth)
        guard let sourceTexture = makeSourceTexture(
            key: sourceKey,
            descriptor: sourceDescriptor,
            region: region,
            rgba: rgba,
            width: width,
            height: height
        ) else {
            return nil
        }

        let outputDescriptor = makeTextureDescriptor(
            width: width,
            height: height,
            depth: depth,
            usage: [.shaderWrite, .shaderRead]
        )
        let outputKey = VolumeModifierTextureSizeKey(
            width: width,
            height: height,
            depth: depth,
            byteCount: rgba.count
        )
        guard let outputTexture = acquireOutputTexture(
            key: outputKey,
            descriptor: outputDescriptor
        ) else {
            return nil
        }
        var outputTextureRetainedForPreview = false
        defer {
            if !outputTextureRetainedForPreview {
                releaseOutputTexture(outputTexture, for: outputKey)
            }
        }

        let volumeScale = VolumeModifierRasterizer.volumeScale(
            width: width,
            height: height,
            depth: depth
        )
        let alphaCenter = VolumeModifierRasterizer.alphaContentCenter(
            rgba: rgba,
            width: width,
            height: height,
            depth: depth,
            hasMeaningfulAlpha: hasMeaningfulAlpha
        )
        let outsetScale = VolumeModifierRasterizer.modifierOutsetScale(modifiers)
        let outsetCenter = VolumeModifierRasterizer.modifierOutsetCenter(
            modifiers,
            alphaCenter: alphaCenter
        )
        var uniforms = VolumeModifierGPUUniforms(
            width: UInt32(width),
            height: UInt32(height),
            depth: UInt32(depth),
            modifierCount: UInt32(min(modifiers.count, VolumeModifierRasterizer.maxGPUModifierCount)),
            volumeScaleAndOutset: SIMD4<Float>(
                volumeScale.x,
                volumeScale.y,
                volumeScale.z,
                outsetScale
            ),
            outsetCenter: SIMD4<Float>(
                outsetCenter.x,
                outsetCenter.y,
                outsetCenter.z,
                0
            )
        )
        var gpuModifiers = modifiers
            .prefix(VolumeModifierRasterizer.maxGPUModifierCount)
            .map { modifier -> VolumeModifierGPUItem in
                let affine = VolumeModifierRasterizer.gpuModifierTransformMatrix(modifier.state)
                let inflateCenter = modifier.state.inflateMode == .alphaBounds ? alphaCenter : .zero
                return VolumeModifierGPUItem(
                    inverseAffine: simd_inverse(affine),
                    shape: SIMD4<Float>(
                        modifier.state.inflate,
                        modifier.state.twistY,
                        modifier.state.taperX,
                        modifier.state.taperZ
                    ),
                    inflateCenter: SIMD4<Float>(
                        inflateCenter.x,
                        inflateCenter.y,
                        inflateCenter.z,
                        0
                    )
                )
            }

        let modifierBuffer = gpuModifiers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil as MTLBuffer? }
            return device.makeBuffer(
                bytes: baseAddress,
                length: buffer.count * MemoryLayout<VolumeModifierGPUItem>.stride,
                options: .storageModeShared
            )
        }

        guard let uniformBuffer = device.makeBuffer(
            bytes: &uniforms,
            length: MemoryLayout<VolumeModifierGPUUniforms>.stride,
            options: .storageModeShared
        ),
              let modifierBuffer,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
        encoder.setBuffer(modifierBuffer, offset: 0, index: 1)

        let threadWidth = max(1, min(pipeline.threadExecutionWidth, 8))
        let threadHeight = 4
        let threadDepth = 4
        let threadsPerThreadgroup = MTLSize(
            width: threadWidth,
            height: threadHeight,
            depth: threadDepth
        )
        let threadgroups = MTLSize(
            width: (width + threadWidth - 1) / threadWidth,
            height: (height + threadHeight - 1) / threadHeight,
            depth: (depth + threadDepth - 1) / threadDepth
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else { return nil }

        outputTextureRetainedForPreview = storeResultTexture(
            outputTexture,
            for: resultID,
            byteCount: rgba.count
        )

        guard readBackToCPU else {
            return rgba
        }

        var output = [UInt8](repeating: 0, count: rgba.count)
        outputTexture.getBytes(
            &output,
            bytesPerRow: width * 4,
            bytesPerImage: width * height * 4,
            from: region,
            mipmapLevel: 0,
            slice: 0
        )
        return output
    }

    func cachedModifiedTexture(for textureCacheID: UUID, device requestedDevice: MTLDevice) -> MTLTexture? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let entry = resultTextureCache[textureCacheID],
              entry.texture.device.registryID == requestedDevice.registryID else {
            return nil
        }
        resultTextureCacheOrder.removeAll { $0 == textureCacheID }
        resultTextureCacheOrder.append(textureCacheID)
        return entry.texture
    }

    func readBackCachedTexture(
        for textureCacheID: UUID,
        width: Int,
        height: Int,
        depth: Int
    ) -> [UInt8]? {
        cacheLock.lock()
        guard let entry = resultTextureCache[textureCacheID] else {
            cacheLock.unlock()
            return nil
        }
        resultTextureCacheOrder.removeAll { $0 == textureCacheID }
        resultTextureCacheOrder.append(textureCacheID)
        let texture = entry.texture
        cacheLock.unlock()

        guard texture.width == width,
              texture.height == height,
              texture.depth == depth,
              texture.pixelFormat == .rgba8Unorm else {
            return nil
        }

        var output = [UInt8](repeating: 0, count: width * height * depth * 4)
        let region = MTLRegionMake3D(0, 0, 0, width, height, depth)
        texture.getBytes(
            &output,
            bytesPerRow: width * 4,
            bytesPerImage: width * height * 4,
            from: region,
            mipmapLevel: 0,
            slice: 0
        )
        return output
    }

    private func makeTextureDescriptor(
        width: Int,
        height: Int,
        depth: Int,
        usage: MTLTextureUsage
    ) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = depth
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return descriptor
    }

    private func makeSourceTexture(
        key: VolumeModifierSourceTextureKey,
        descriptor: MTLTextureDescriptor,
        region: MTLRegion,
        rgba: [UInt8],
        width: Int,
        height: Int
    ) -> MTLTexture? {
        if let cachedTexture = cachedSourceTexture(for: key) {
            return cachedTexture
        }

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.replace(
            region: region,
            mipmapLevel: 0,
            slice: 0,
            withBytes: rgba,
            bytesPerRow: width * 4,
            bytesPerImage: width * height * 4
        )
        storeSourceTexture(texture, for: key)
        return texture
    }

    private func cachedSourceTexture(for key: VolumeModifierSourceTextureKey) -> MTLTexture? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let entry = sourceTextureCache[key] else { return nil }
        sourceTextureCacheOrder.removeAll { $0 == key }
        sourceTextureCacheOrder.append(key)
        return entry.texture
    }

    private func storeSourceTexture(_ texture: MTLTexture, for key: VolumeModifierSourceTextureKey) {
        guard key.byteCount <= Self.maxSourceTextureCacheBytes else { return }

        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let existing = sourceTextureCache.removeValue(forKey: key) {
            sourceTextureCacheBytes -= existing.byteCount
            sourceTextureCacheOrder.removeAll { $0 == key }
        }

        sourceTextureCache[key] = VolumeModifierSourceTextureEntry(
            texture: texture,
            byteCount: key.byteCount
        )
        sourceTextureCacheOrder.append(key)
        sourceTextureCacheBytes += key.byteCount

        while sourceTextureCacheBytes > Self.maxSourceTextureCacheBytes,
              let oldestKey = sourceTextureCacheOrder.first {
            sourceTextureCacheOrder.removeFirst()
            if let removed = sourceTextureCache.removeValue(forKey: oldestKey) {
                sourceTextureCacheBytes -= removed.byteCount
            }
        }
    }

    @discardableResult
    private func storeResultTexture(
        _ texture: MTLTexture,
        for textureCacheID: UUID,
        byteCount: Int
    ) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if byteCount > Self.maxResultTextureCacheBytes {
            resultTextureCache.removeAll(keepingCapacity: false)
            resultTextureCacheOrder.removeAll(keepingCapacity: false)
            resultTextureCacheBytes = 0
        }

        if let existing = resultTextureCache.removeValue(forKey: textureCacheID) {
            resultTextureCacheBytes -= existing.byteCount
            resultTextureCacheOrder.removeAll { $0 == textureCacheID }
        }

        resultTextureCache[textureCacheID] = VolumeModifierResultTextureEntry(
            texture: texture,
            byteCount: byteCount
        )
        resultTextureCacheOrder.append(textureCacheID)
        resultTextureCacheBytes += byteCount

        while byteCount <= Self.maxResultTextureCacheBytes,
              resultTextureCacheBytes > Self.maxResultTextureCacheBytes,
              let oldestID = resultTextureCacheOrder.first {
            resultTextureCacheOrder.removeFirst()
            if let removed = resultTextureCache.removeValue(forKey: oldestID) {
                resultTextureCacheBytes -= removed.byteCount
            }
        }
        return true
    }

    private func acquireOutputTexture(
        key: VolumeModifierTextureSizeKey,
        descriptor: MTLTextureDescriptor
    ) -> MTLTexture? {
        cacheLock.lock()
        if let texture = outputTexturePool.removeValue(forKey: key) {
            outputTexturePoolBytes -= key.byteCount
            outputTexturePoolOrder.removeAll { $0 == key }
            cacheLock.unlock()
            return texture
        }
        cacheLock.unlock()

        return device.makeTexture(descriptor: descriptor)
    }

    private func releaseOutputTexture(_ texture: MTLTexture, for key: VolumeModifierTextureSizeKey) {
        guard key.byteCount <= Self.maxOutputTexturePoolBytes else { return }

        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let existing = outputTexturePool.removeValue(forKey: key) {
            outputTexturePoolBytes -= key.byteCount
            outputTexturePoolOrder.removeAll { $0 == key }
            _ = existing
        }

        outputTexturePool[key] = texture
        outputTexturePoolOrder.append(key)
        outputTexturePoolBytes += key.byteCount

        while outputTexturePoolBytes > Self.maxOutputTexturePoolBytes,
              let oldestKey = outputTexturePoolOrder.first {
            outputTexturePoolOrder.removeFirst()
            if outputTexturePool.removeValue(forKey: oldestKey) != nil {
                outputTexturePoolBytes -= oldestKey.byteCount
            }
        }
    }
}

private extension VolumeModifierRasterizer {
    static func gpuModifierTransformMatrix(_ modifier: MeshModifierState) -> simd_float4x4 {
        modifierTransformMatrix(modifier)
    }
}
