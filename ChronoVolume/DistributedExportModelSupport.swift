import Foundation

extension AppModel {
    /// 供分布式导出 GUI 使用：从“实际体尺寸”文本里尽量解析出真实体尺寸。
    /// 预期格式通常类似：
    /// - "1920x1080x1603"
    /// - "1920 × 1080 × 1603"
    /// - 其它包含前三个整数的文本
    private func parseVolumeTriplet(from text: String) -> (Int, Int, Int)? {
        let pattern = #"\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let values = matches.compactMap { match -> Int? in
            guard let range = Range(match.range, in: text) else { return nil }
            return Int(text[range])
        }

        guard values.count >= 3 else { return nil }
        return (values[0], values[1], values[2])
    }

    private var parsedActualVolumeTriplet: (Int, Int, Int)? {
        if let v = parseVolumeTriplet(from: actualVolumeInfo) {
            return v
        }
        if let v = parseVolumeTriplet(from: volumeInfo) {
            return v
        }
        if let v = parseVolumeTriplet(from: previewVolumeInfo) {
            return v
        }
        return nil
    }

    /// 真实体尺寸的 X 方向长度
    var distributedSourceWidth: Int {
        parsedActualVolumeTriplet?.0 ?? 0
    }

    /// 真实体尺寸的 Y 方向长度
    var distributedSourceHeight: Int {
        parsedActualVolumeTriplet?.1 ?? 0
    }

    /// 当前切面若开启分布式导出，应切分的总输出帧数
    var distributedOutputFrameCount: Int {
        switch sliceMode {
        case .axis:
            return distributedSourceAxisFrameCount
        case .plane:
            guard distributedSourceWidth > 0, distributedSourceHeight > 0, sourceFrameCount > 0 else {
                return totalFrameCountForCurrentMode()
            }
            return VideoExportHelper.highPrecisionPlaneOutputMetrics(
                sourceWidth: distributedSourceWidth,
                sourceHeight: distributedSourceHeight,
                sourceFrameCount: sourceFrameCount,
                referencePlane: referencePlane
            ).sliceCount
        }
    }

    var distributedOutputImageSize: (width: Int, height: Int) {
        switch sliceMode {
        case .axis:
            switch playbackAxis {
            case .x:
                return (sourceFrameCount, distributedSourceHeight)
            case .y:
                return (distributedSourceWidth, sourceFrameCount)
            case .t:
                return (0, 0)
            }
        case .plane:
            guard distributedSourceWidth > 0, distributedSourceHeight > 0, sourceFrameCount > 0 else {
                let size = imageSizeForCurrentMode()
                return (size.0, size.1)
            }
            let metrics = VideoExportHelper.highPrecisionPlaneOutputMetrics(
                sourceWidth: distributedSourceWidth,
                sourceHeight: distributedSourceHeight,
                sourceFrameCount: sourceFrameCount,
                referencePlane: referencePlane
            )
            return (metrics.width, metrics.height)
        }
    }

    /// 当前轴若开启分布式导出，应切分的总输出帧数
    var distributedSourceAxisFrameCount: Int {
        guard sliceMode == .axis else { return 0 }
        switch playbackAxis {
        case .x:
            return distributedSourceWidth
        case .y:
            return distributedSourceHeight
        case .t:
            return 0
        }
    }
}
