import Foundation
import CoreVideo

final class CVDisplayLinkDriver {
    private var displayLink: CVDisplayLink?
    var callback: (() -> Void)?

    init?() {
        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard status == kCVReturnSuccess, let link else { return }

        self.displayLink = link

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(
            link,
            { _, _, _, _, _, userInfo in
                guard let userInfo else { return kCVReturnError }
                let driver = Unmanaged<CVDisplayLinkDriver>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                driver.callback?()
                return kCVReturnSuccess
            },
            userInfo
        )
    }

    deinit {
        stop()
    }

    func start() {
        guard let displayLink else { return }
        if !CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStart(displayLink)
        }
    }

    func stop() {
        guard let displayLink else { return }
        if CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }
}
