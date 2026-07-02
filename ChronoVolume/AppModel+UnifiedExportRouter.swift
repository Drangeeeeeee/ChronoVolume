import Foundation

@MainActor
extension AppModel {
    func exportCurrent2DVideoInteractivelyLocal(
        preserveAlpha: Bool,
        qualityScale: Double,
        padToEven: Bool = true,
        highPrecision: Bool,
        bitDepth: Int = 8,
        colorProfile: VideoColorProfile = .rec709
    ) {
        exportCurrent2DVideoInteractively(
            preserveAlpha: preserveAlpha,
            qualityScale: qualityScale,
            padToEven: padToEven,
            highPrecision: highPrecision,
            bitDepth: bitDepth,
            colorProfile: colorProfile
        )
    }

    func exportCurrent2DVideoInteractivelyDistributed(
        preserveAlpha: Bool,
        qualityScale: Double,
        padToEven: Bool = true,
        bitDepth: Int = 8,
        colorProfile: VideoColorProfile = .rec709,
        distributedSettings: DistributedExportSettings
    ) {
        startDistributedExportInteractively(
            settings: distributedSettings,
            preserveAlpha: preserveAlpha,
            padToEven: padToEven,
            qualityScale: qualityScale,
            bitDepth: bitDepth,
            colorProfile: colorProfile
        )
    }

    func exportCurrent2DVideoInteractivelyUnified(
        preserveAlpha: Bool,
        qualityScale: Double,
        padToEven: Bool = true,
        highPrecision: Bool,
        bitDepth: Int = 8,
        colorProfile: VideoColorProfile = .rec709,
        distributedSettings: DistributedExportSettings
    ) {
        let canUseDistributed =
            distributedSettings.isEnabled &&
            highPrecision &&
            (
                sliceMode == .plane ||
                (sliceMode == .axis && (playbackAxis == .x || playbackAxis == .y))
            )

        if canUseDistributed {
            exportCurrent2DVideoInteractivelyDistributed(
                preserveAlpha: preserveAlpha,
                qualityScale: qualityScale,
                padToEven: padToEven,
                bitDepth: bitDepth,
                colorProfile: colorProfile,
                distributedSettings: distributedSettings
            )
        } else {
            exportCurrent2DVideoInteractivelyLocal(
                preserveAlpha: preserveAlpha,
                qualityScale: qualityScale,
                padToEven: padToEven,
                highPrecision: highPrecision,
                bitDepth: bitDepth,
                colorProfile: colorProfile
            )
        }
    }
}
