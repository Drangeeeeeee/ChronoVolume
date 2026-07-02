import Foundation
import CoreGraphics

enum AxisSliceCache {
    static func buildSliceCGImage(
        from volume: CPUVolume,
        axis: PlaybackAxis,
        index: Int,
        showCheckerboard: Bool,
        useAlpha: Bool
    ) -> CGImage? {
        precondition(axis == .t || axis == .x || axis == .y)

        let imageWidth: Int
        let imageHeight: Int
        let clampedIndex: Int

        switch axis {
        case .t:
            imageWidth = volume.width
            imageHeight = volume.height
            clampedIndex = max(0, min(index, volume.depth - 1))
        case .x:
            imageWidth = volume.depth
            imageHeight = volume.height
            clampedIndex = max(0, min(index, volume.width - 1))
        case .y:
            imageWidth = volume.width
            imageHeight = volume.depth
            clampedIndex = max(0, min(index, volume.height - 1))
        }

        let frameBytes = imageWidth * imageHeight * 4
        var out = [UInt8](repeating: 0, count: frameBytes)

        switch axis {
        case .t:
            for y in 0..<volume.height {
                for x in 0..<volume.width {
                    let (r, g, b, a) = volume.rgbaAt(t: clampedIndex, y: y, x: x)
                    let dst = (y * imageWidth + x) * 4
                    writePixel(
                        into: &out,
                        at: dst,
                        outWidth: imageWidth,
                        r: r,
                        g: g,
                        b: b,
                        a: a,
                        checkerboard: showCheckerboard && useAlpha && volume.hasMeaningfulAlpha
                    )
                }
            }

        case .x:
            for y in 0..<volume.height {
                for t in 0..<volume.depth {
                    let (r, g, b, a) = volume.rgbaAt(t: t, y: y, x: clampedIndex)
                    let dst = (y * imageWidth + t) * 4
                    writePixel(
                        into: &out,
                        at: dst,
                        outWidth: imageWidth,
                        r: r,
                        g: g,
                        b: b,
                        a: a,
                        checkerboard: showCheckerboard && useAlpha && volume.hasMeaningfulAlpha
                    )
                }
            }

        case .y:
            for t in 0..<volume.depth {
                for x in 0..<volume.width {
                    let (r, g, b, a) = volume.rgbaAt(t: t, y: clampedIndex, x: x)
                    let dst = (t * imageWidth + x) * 4
                    writePixel(
                        into: &out,
                        at: dst,
                        outWidth: imageWidth,
                        r: r,
                        g: g,
                        b: b,
                        a: a,
                        checkerboard: showCheckerboard && useAlpha && volume.hasMeaningfulAlpha
                    )
                }
            }
        }

        return cgImageFromRGBA(width: imageWidth, height: imageHeight, rgba: out)
    }

    private static func writePixel(
        into out: inout [UInt8],
        at dst: Int,
        outWidth: Int,
        r: UInt8,
        g: UInt8,
        b: UInt8,
        a: UInt8,
        checkerboard: Bool
    ) {
        if checkerboard {
            let pixelIndex = dst / 4
            let x = pixelIndex % max(1, outWidth)
            let y = pixelIndex / max(1, outWidth)
            let tile = 12
            let isDark = ((x / tile) + (y / tile)) % 2 == 0
            let bg: UInt8 = isDark ? 180 : 235
            let alpha = Float(a) / 255.0

            out[dst] = UInt8(Float(bg) * (1 - alpha) + Float(r) * alpha)
            out[dst + 1] = UInt8(Float(bg) * (1 - alpha) + Float(g) * alpha)
            out[dst + 2] = UInt8(Float(bg) * (1 - alpha) + Float(b) * alpha)
            out[dst + 3] = 255
        } else {
            out[dst] = r
            out[dst + 1] = g
            out[dst + 2] = b
            out[dst + 3] = 255
        }
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
