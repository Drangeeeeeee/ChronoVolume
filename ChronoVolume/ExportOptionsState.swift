import Foundation
import SwiftUI

@MainActor
final class ExportOptionsState: ObservableObject {
    @Published var preserveAlpha: Bool = false
    @Published var highPrecision: Bool = true
    @Published var padToEven: Bool = true
    @Published var qualityScale: Double = 1.0
    @Published var bitDepth: ExportBitDepth = .source
    @Published var colorProfile: ExportColorProfile = .source

    func makeProjectState() -> ChronoVolumeProjectDocument.ExportOptionsProjectState {
        ChronoVolumeProjectDocument.ExportOptionsProjectState(
            preserveAlpha: preserveAlpha,
            highPrecision: highPrecision,
            padToEven: padToEven,
            qualityScale: qualityScale,
            bitDepth: bitDepth,
            colorProfile: colorProfile
        )
    }

    func restoreProjectState(_ state: ChronoVolumeProjectDocument.ExportOptionsProjectState) {
        preserveAlpha = state.preserveAlpha
        highPrecision = state.highPrecision
        padToEven = state.padToEven
        qualityScale = max(0.05, min(4.0, state.qualityScale))
        bitDepth = state.bitDepth
        colorProfile = state.colorProfile
    }
}
