import Foundation
import AVFoundation

@MainActor
extension AppModel {
    func prepareForExclusiveExport() {
        releaseInteractivePreviewResourcesForExport()
        status = "正在进入导出专用模式：暂停播放并锁定非导出操作"
    }

    func restoreAfterExclusiveExport() {
        restoreInteractivePreviewResourcesAfterExport()
    }
}
