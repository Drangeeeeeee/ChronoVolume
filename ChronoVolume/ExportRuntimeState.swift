import Foundation
import SwiftUI

@MainActor
final class ExportRuntimeState: ObservableObject {
    @Published var isExporting: Bool = false
    @Published var title: String = "导出中"
    @Published var startedAt: Date?
    @Published var latestStatus: String = "-"
    @Published var canClose: Bool = false
    @Published var shouldRestoreAppAfterExport: Bool = false

    func begin(title: String) {
        self.title = title
        self.startedAt = Date()
        self.latestStatus = "正在准备导出…"
        self.canClose = false
        self.shouldRestoreAppAfterExport = false
        self.isExporting = true
    }

    func updateFromAppStatus(_ status: String) {
        latestStatus = status

        let finishedKeywords = [
            "导出完成",
            "分布式导出完成",
            "完成：",
            "已取消",
            "取消",
            "失败",
            "错误"
        ]

        if finishedKeywords.contains(where: { status.contains($0) }) {
            canClose = true
            shouldRestoreAppAfterExport = true
        }
    }

    func closeIfPossible() {
        guard canClose else {
            return
        }

        isExporting = false
        shouldRestoreAppAfterExport = false
    }

    var elapsedText: String {
        guard let startedAt else {
            return "0s"
        }

        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let minutes = elapsed / 60
        let seconds = elapsed % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}
