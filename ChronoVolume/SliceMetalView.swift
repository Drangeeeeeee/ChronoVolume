
import SwiftUI
import MetalKit
import AppKit

struct SliceMetalView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)

        guard let device = MTLCreateSystemDefaultDevice() else {
            return view
        }

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = false

        let renderer = SliceRenderer(view: view)
        view.delegate = renderer

        let appModel = model
        DispatchQueue.main.async {
            appModel.attachSliceRenderer(renderer)
        }

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        guard let renderer = nsView.delegate as? SliceRenderer else { return }

        let scaleFactor = nsView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let resolutionScale: CGFloat = (model.isPlaying && model.reduceResolutionWhilePlaying) ? 0.5 : 1.0
        let drawableWidth = max(1, Int(nsView.bounds.width * scaleFactor * resolutionScale))
        let drawableHeight = max(1, Int(nsView.bounds.height * scaleFactor * resolutionScale))
        let desired = CGSize(width: drawableWidth, height: drawableHeight)
        if nsView.drawableSize != desired {
            nsView.drawableSize = desired
        }

        if model.isPlaying {
            nsView.enableSetNeedsDisplay = false
            nsView.isPaused = false
            nsView.preferredFramesPerSecond = 60
        } else {
            nsView.isPaused = true
            nsView.enableSetNeedsDisplay = true
            nsView.needsDisplay = true
        }

        renderer.updateParams(
            sliceMode: model.sliceMode,
            playbackAxis: model.playbackAxis,
            currentIndex: model.currentIndex,
            showCheckerboard: model.showCheckerboard,
            useAlpha: model.useAlpha,
            referencePlane: model.referencePlane,
            fastPreview: model.isPlaying && model.useFastPreviewWhilePlaying
        )
        renderer.requestRedraw()
    }
}
