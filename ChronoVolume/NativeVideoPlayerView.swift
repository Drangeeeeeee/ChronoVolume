import SwiftUI
import AVKit

struct NativeVideoPlayerView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.player = model.player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== model.player {
            nsView.player = model.player
        }
    }
}
