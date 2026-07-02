import Foundation
import AVFoundation

enum SegmentStitcherError: LocalizedError {
    case noSegments
    case cannotCreateExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSegments:
            return "没有可拼接的 segment"
        case .cannotCreateExportSession:
            return "无法创建拼接导出会话"
        case .exportFailed(let reason):
            return "segment 拼接失败：\(reason)"
        }
    }
}

enum SegmentStitcher {
    static func stitch(
        segmentURLs: [URL],
        outputURL: URL
    ) async throws {
        guard !segmentURLs.isEmpty else {
            throw SegmentStitcherError.noSegments
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SegmentStitcherError.cannotCreateExportSession
        }

        var cursor = CMTime.zero

        for url in segmentURLs {
            let asset = AVURLAsset(url: url)
            guard let srcTrack = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            try videoTrack.insertTimeRange(timeRange, of: srcTrack, at: cursor)
            cursor = cursor + timeRange.duration
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw SegmentStitcherError.cannotCreateExportSession
        }

        session.outputURL = outputURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false

        let sem = DispatchSemaphore(value: 0)
        session.exportAsynchronously {
            sem.signal()
        }
        sem.wait()

        switch session.status {
        case .completed:
            return
        case .failed, .cancelled:
            throw SegmentStitcherError.exportFailed(session.error?.localizedDescription ?? "未知原因")
        default:
            throw SegmentStitcherError.exportFailed("导出状态异常")
        }
    }
}
