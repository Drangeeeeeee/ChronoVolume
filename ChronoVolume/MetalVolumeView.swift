import SwiftUI
import MetalKit
import AppKit

protocol InteractiveMTKViewDelegate: AnyObject {
    func mouseDown(with event: NSEvent)
    func mouseDragged(with event: NSEvent)
    func mouseUp(with event: NSEvent)

    func rightMouseDown(with event: NSEvent)
    func rightMouseDragged(with event: NSEvent)
    func rightMouseUp(with event: NSEvent)

    func scrollWheel(with event: NSEvent)

    func keyDown(with event: NSEvent)
    func keyUp(with event: NSEvent)
}

struct MetalVolumeView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var role: VolumeRendererRole = .main
    var allowsInteraction: Bool = true

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero)

        guard let device = MTLCreateSystemDefaultDevice() else {
            return view
        }

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.layer?.isOpaque = false
        view.framebufferOnly = false

        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = 60

        let renderer = VolumeRenderer(view: view)
        view.delegate = renderer
        view.interactionDelegate = allowsInteraction ? renderer : nil

        DispatchQueue.main.async {
            switch role {
            case .main:
                model.attachRenderer(renderer)
            case .cameraPreview:
                model.attachCameraPreviewRenderer(renderer)
            }
        }

        return view
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        guard let renderer = nsView.delegate as? VolumeRenderer else { return }

        renderer.useAlpha = model.useAlpha
        renderer.steps = model.steps
        renderer.density = Float(model.density)
        renderer.brightness = Float(model.brightness)
        renderer.useVoxelBlockRendering = model.useVoxelBlockRendering
        renderer.smoothEdges = model.smoothVolumeEdges
        renderer.setVolumeTransform(model.volumeTransform)
        if role == .main {
            model.updateReferencePlaneOverlay(renderer: renderer)
        } else {
            renderer.setReferencePlaneOverlay(vertices: [], visible: false)
        }
        renderer.cameraMode = role == .cameraPreview ? .freeCamera : .orbit
        renderer.focalLength = role == .cameraPreview ? model.cameraRig.focalLength : 50
        renderer.setBackgroundColor(
            red: model.volumeBackgroundColor.red,
            green: model.volumeBackgroundColor.green,
            blue: model.volumeBackgroundColor.blue,
            alpha: model.volumeBackgroundMode == .checkerboard ? 0 : 1
        )
        if role == .cameraPreview {
            renderer.setCamera(
                yaw: model.cameraRig.yaw,
                pitch: model.cameraRig.pitch,
                roll: model.cameraRig.roll,
                distance: 0,
                position: SIMD3<Float>(model.cameraRig.positionX, model.cameraRig.positionY, model.cameraRig.positionZ),
                focusLockEnabled: model.cameraRig.focusLockEnabled,
                focusTarget: SIMD3<Float>(model.cameraRig.focusTargetX, model.cameraRig.focusTargetY, model.cameraRig.focusTargetZ)
            )
        }
        renderer.requestRedraw()
    }
}

enum VolumeRendererRole {
    case main
    case cameraPreview
}

final class InteractiveMTKView: MTKView {
    weak var interactionDelegate: InteractiveMTKViewDelegate?
    var manualDrawableScale: CGFloat? {
        didSet {
            updateManualDrawableSize()
        }
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        updateManualDrawableSize()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        interactionDelegate?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        interactionDelegate?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        interactionDelegate?.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        interactionDelegate?.rightMouseDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        interactionDelegate?.rightMouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        interactionDelegate?.rightMouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        interactionDelegate?.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        interactionDelegate?.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        interactionDelegate?.keyUp(with: event)
    }

    private func updateManualDrawableSize() {
        guard let manualDrawableScale else { return }
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let scale = max(0.1, min(1, manualDrawableScale)) * backingScale
        let nextSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        if abs(drawableSize.width - nextSize.width) > 0.5 ||
            abs(drawableSize.height - nextSize.height) > 0.5 {
            drawableSize = nextSize
        }
    }
}
