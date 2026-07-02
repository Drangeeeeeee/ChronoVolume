import SwiftUI
import MetalKit
import simd

struct PlaneSliceMetalView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    final class Coordinator {
        var lastSignature: String = ""
        var lastPausedState: Bool?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        guard let device = MTLCreateSystemDefaultDevice() else {
            return view
        }

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let renderer = PlaneSliceRenderer(view: view)
        view.delegate = renderer

        DispatchQueue.main.async {
            model.attachPlaneSliceRenderer(renderer)
        }

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        guard let renderer = nsView.delegate as? PlaneSliceRenderer else { return }

        let playing = model.isPlaying
        let busy = model.isSliceRendering || model.isAxisCacheBuilding
        let fastPreview = playing || busy

        let previewScale: Float = {
            if playing {
                return model.reduceResolutionWhilePlaying ? 0.42 : 0.72
            }
            if busy {
                return 0.68
            }
            return 1.0
        }()

        let params = model.planePreviewParameters(previewScale: previewScale)
        let signature = planeSignature(
            params: params,
            useAlpha: model.useAlpha,
            showCheckerboard: model.showCheckerboard,
            fastPreview: fastPreview
        )

        let shouldPause = !playing
        if context.coordinator.lastPausedState != shouldPause {
            context.coordinator.lastPausedState = shouldPause
            if shouldPause {
                nsView.isPaused = true
                nsView.enableSetNeedsDisplay = true
            } else {
                nsView.enableSetNeedsDisplay = false
                nsView.isPaused = false
                nsView.preferredFramesPerSecond = 60
            }
        }

        if signature != context.coordinator.lastSignature {
            context.coordinator.lastSignature = signature
            renderer.update(
                params: params,
                useAlpha: model.useAlpha,
                showCheckerboard: model.showCheckerboard,
                fastPreview: fastPreview
            )

            if shouldPause {
                nsView.needsDisplay = true
            }
        }
    }

    private func planeSignature(
        params: PlaneSliceParameters?,
        useAlpha: Bool,
        showCheckerboard: Bool,
        fastPreview: Bool
    ) -> String {
        guard let p = params else {
            return "nil|\(useAlpha)|\(showCheckerboard)|\(fastPreview)"
        }

        func q(_ v: Float) -> String {
            String(Int((v * 1000).rounded()))
        }

        return [
            String(p.outWidth),
            String(p.outHeight),
            q(p.u.x), q(p.u.y), q(p.u.z),
            q(p.v.x), q(p.v.y), q(p.v.z),
            q(p.n.x), q(p.n.y), q(p.n.z),
            q(p.uMin), q(p.uMax),
            q(p.vMin), q(p.vMax),
            q(p.d),
            String(p.volumeWidth),
            String(p.volumeHeight),
            String(p.volumeDepth),
            useAlpha ? "1" : "0",
            showCheckerboard ? "1" : "0",
            fastPreview ? "1" : "0"
        ].joined(separator: "|")
    }
}
