import SwiftUI
import CoreGraphics

struct SlicePreviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let cgImage = model.currentSliceCGImage {
                    Image(decorative: cgImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if model.isSliceRendering {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在生成切片…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "film")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("未生成 2D 切片")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            model.rebuildCurrentSlice()
        }
    }
}
