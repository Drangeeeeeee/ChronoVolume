import Foundation

struct DistributedProgressItem: Codable, Identifiable, Equatable {
    var id: String { nodeID }

    let nodeID: String
    let displayName: String
    let role: String
    let state: String
    let progress: Double
    let message: String
    let timingText: String?

    var percentText: String {
        "\(Int(max(0, min(1, progress)) * 100))%"
    }
}

struct DistributedClusterProgressSnapshot: Codable, Equatable {
    let sessionID: String
    let title: String
    let totalProgress: Double
    let items: [DistributedProgressItem]
    let updatedAtISO8601: String
}

struct DistributedExportDiagnosticsSplitPlan: Codable, Equatable {
    let localStartFrame: Int
    let localEndFrame: Int
    let localFrameCount: Int
    let workerStartFrame: Int
    let workerEndFrame: Int
    let workerFrameCount: Int
}

struct DistributedExportDiagnosticsAllocation: Codable, Equatable {
    let nodeID: String
    let displayName: String
    let role: String
    let startFrame: Int
    let endFrame: Int
    let frameCount: Int
}

struct DistributedExportDiagnosticsReport: Codable, Equatable {
    let schemaVersion: Int
    let sessionID: String
    let exportedAtISO8601: String
    let sourcePath: String
    let sourceFileHash: String?
    let outputPath: String
    let axis: String
    let fps: Double
    let sourceWidth: Int
    let sourceHeight: Int
    let sourceFrameCount: Int
    let totalOutputFrames: Int
    let preserveAlpha: Bool
    let padToEven: Bool
    let qualityScale: Double
    let splitPlan: DistributedExportDiagnosticsSplitPlan
    let allocations: [DistributedExportDiagnosticsAllocation]
    let progressSnapshot: DistributedClusterProgressSnapshot
}
