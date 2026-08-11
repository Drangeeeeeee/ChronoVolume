//
//  ChronoVolumeTests.swift
//  ChronoVolumeTests

import Testing
import Foundation
import AVFoundation
import CryptoKit
@testable import ChronoVolume

@Suite(.serialized)
struct ChronoVolumeTests {

    private final class HashObserverCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func record(_ url: URL) {
            lock.lock()
            storage += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class AllocationStageCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var stages: [VideoVolumeAllocationStage] = []

        func record(_ stage: VideoVolumeAllocationStage) {
            lock.lock()
            stages.append(stage)
            lock.unlock()
        }

        func contains(_ stage: VideoVolumeAllocationStage) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return stages.contains(stage)
        }
    }

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func distributedSplitPlanAllLocalHasNoWorkerFrames() {
        let plan = DistributedSplitPlan.build(totalFrames: 120, localSharePercent: 100)

        #expect(plan.localStartFrame == 0)
        #expect(plan.localEndFrame == 119)
        #expect(plan.localFrameCount == 120)
        #expect(plan.workerStartFrame == 120)
        #expect(plan.workerEndFrame == 119)
        #expect(plan.workerFrameCount == 0)
    }

    @Test func distributedSplitPlanAllWorkerHasNoLocalFrames() {
        let plan = DistributedSplitPlan.build(totalFrames: 120, localSharePercent: 0)

        #expect(plan.localStartFrame == 0)
        #expect(plan.localEndFrame == -1)
        #expect(plan.localFrameCount == 0)
        #expect(plan.workerStartFrame == 0)
        #expect(plan.workerEndFrame == 119)
        #expect(plan.workerFrameCount == 120)
    }

    @Test func distributedSplitPlanHalfKeepsContinuousRanges() {
        let plan = DistributedSplitPlan.build(totalFrames: 121, localSharePercent: 50)

        #expect(plan.localStartFrame == 0)
        #expect(plan.localEndFrame == 60)
        #expect(plan.localFrameCount == 61)
        #expect(plan.workerStartFrame == 61)
        #expect(plan.workerEndFrame == 120)
        #expect(plan.workerFrameCount == 60)
    }

    @Test func distributedMultiSplitPlanDividesRemainingFramesAcrossOnlineWorkers() {
        var workerA = DistributedWorkerNode(baseURL: "http://10.77.77.2:8787")
        workerA.connectionState = .online
        workerA.name = "A"

        var workerB = DistributedWorkerNode(baseURL: "http://10.77.77.3:8787")
        workerB.connectionState = .online
        workerB.name = "B"

        let plan = DistributedMultiSplitPlan.build(
            totalFrames: 100,
            localSharePercent: 40,
            workers: [workerA, workerB]
        )

        #expect(plan.local.startFrame == 0)
        #expect(plan.local.endFrame == 39)
        #expect(plan.local.frameCount == 40)
        #expect(plan.workers.count == 2)
        #expect(plan.workers[0].startFrame == 40)
        #expect(plan.workers[0].endFrame == 69)
        #expect(plan.workers[0].frameCount == 30)
        #expect(plan.workers[1].startFrame == 70)
        #expect(plan.workers[1].endFrame == 99)
        #expect(plan.workers[1].frameCount == 30)
        #expect(plan.totalFrameCount == 100)
    }

    @Test func distributedMultiSplitPlanUsesManualBoundaries() {
        var workerA = DistributedWorkerNode(baseURL: "http://10.77.77.2:8787")
        workerA.connectionState = .online
        var workerB = DistributedWorkerNode(baseURL: "http://10.77.77.3:8787")
        workerB.connectionState = .online

        let plan = DistributedMultiSplitPlan.build(
            totalFrames: 100,
            workers: [workerA, workerB],
            manualBoundaries: [25, 70]
        )

        #expect(plan.local.frameCount == 25)
        #expect(plan.workers[0].frameCount == 45)
        #expect(plan.workers[1].frameCount == 30)
        #expect(plan.local.startFrame == 0)
        #expect(plan.workers[0].startFrame == 25)
        #expect(plan.workers[1].startFrame == 70)
    }

    @Test func externalAlphaEightBitMergeIsExactAndPreservesHiddenRGB() throws {
        let color: [UInt8] = [
            12, 34, 56, 255,
            78, 90, 123, 255,
            201, 17, 88, 255,
            250, 240, 230, 255
        ]
        let merged = try ExternalAlphaMerger.mergePreview(
            colorRGBA: color,
            alphaCodeValues: [0, 64, 128, 255],
            bitDepth: 8,
            range: .full,
            invert: false
        )
        #expect([merged[3], merged[7], merged[11], merged[15]] == [0, 64, 128, 255])
        #expect(Array(merged[0..<3]) == [12, 34, 56])
        #expect(Array(merged[8..<11]) == [201, 17, 88])
    }

    @Test func gray16NormalizationKeepsSourcePrecision() throws {
        let values: [UInt16] = [0, 1, 32768, 65535]
        let normalized = try values.map {
            try ExternalAlphaNormalizer.normalized(codeValue: $0, bitDepth: 16, range: .full)
        }
        #expect(normalized[0] == 0)
        #expect(abs(normalized[1] - 1.0 / 65535.0) < 0.000000001)
        #expect(abs(normalized[2] - 32768.0 / 65535.0) < 0.000000001)
        #expect(normalized[3] == 1)
    }

    @Test func fullLimitedAndInvertNormalization() throws {
        #expect(try ExternalAlphaNormalizer.previewByte(codeValue: 128, bitDepth: 8, range: .full) == 128)
        #expect(try ExternalAlphaNormalizer.previewByte(codeValue: 16, bitDepth: 8, range: .limited) == 0)
        #expect(try ExternalAlphaNormalizer.previewByte(codeValue: 235, bitDepth: 8, range: .limited) == 255)
        #expect(try ExternalAlphaNormalizer.previewByte(codeValue: 0, bitDepth: 8, range: .full, invert: true) == 255)
        #expect(try ExternalAlphaNormalizer.previewByte(codeValue: 255, bitDepth: 8, range: .full, invert: true) == 0)
    }

    @Test func rgbChannelSelectionUsesRequestedComponent() {
        let rgba: (UInt16, UInt16, UInt16, UInt16) = (100, 200, 300, 400)
        #expect(ExternalAlphaNormalizer.selectedCodeValue(rgba: rgba, channel: .red, bitDepth: 16) == 100)
        #expect(ExternalAlphaNormalizer.selectedCodeValue(rgba: rgba, channel: .green, bitDepth: 16) == 200)
        #expect(ExternalAlphaNormalizer.selectedCodeValue(rgba: rgba, channel: .blue, bitDepth: 16) == 300)
        #expect(ExternalAlphaNormalizer.selectedCodeValue(rgba: rgba, channel: .alpha, bitDepth: 16) == 400)
    }

    @Test func strictDimensionValidationUsesDisplayOrientation() throws {
        let color = Self.metadata(width: 1920, height: 1080, rotation: 90)
        let normalizedAlpha = Self.metadata(width: 1080, height: 1920, rotation: 0)
        try ExternalAlphaCompatibilityValidator.validateDimensions(color: color, alpha: normalizedAlpha, policy: .strict)

        let wrong = Self.metadata(width: 1920, height: 1080, rotation: 0)
        do {
            try ExternalAlphaCompatibilityValidator.validateDimensions(color: color, alpha: wrong, policy: .strict)
            Issue.record("应当报告规范化后的显示分辨率不一致")
        } catch let error as ExternalAlphaError {
            #expect(error == .resolutionMismatch(colorWidth: 1080, colorHeight: 1920, alphaWidth: 1920, alphaHeight: 1080))
        }
    }

    @Test func strictSyncReportsFPSDurationCountAndStartOffset() throws {
        do {
            _ = try ExternalAlphaFrameSynchronizer.pair(
                colorTimes: [0, 1.0 / 30.0], alphaTimes: [0, 1.0 / 24.0],
                policy: .strict, colorFPS: 30, alphaFPS: 24
            )
            Issue.record("应当报告帧率不一致")
        } catch let error as ExternalAlphaError {
            if case .frameRateMismatch = error {} else { Issue.record("错误类型不正确：\(error)") }
        }

        do {
            _ = try ExternalAlphaFrameSynchronizer.pair(
                colorTimes: [0, 0.04, 0.08], alphaTimes: [0.01, 0.05, 0.09],
                policy: .strict, colorFPS: 25, alphaFPS: 25,
                colorDuration: 0.12, alphaDuration: 0.13
            )
            Issue.record("应当报告时长/起始时间不一致")
        } catch { #expect(error is ExternalAlphaError) }

        do {
            _ = try ExternalAlphaFrameSynchronizer.pair(
                colorTimes: [0, 0.04, 0.08], alphaTimes: [0, 0.04],
                policy: .strict, colorFPS: 25, alphaFPS: 25
            )
            Issue.record("应当报告帧数不一致")
        } catch let error as ExternalAlphaError {
            if case .frameCountMismatch = error {} else { Issue.record("错误类型不正确：\(error)") }
        }
    }

    @Test func variableFrameRatePairsByPTSNotArrayIndex() throws {
        let pairs = try ExternalAlphaFrameSynchronizer.pair(
            colorTimes: [0.0, 0.041, 0.100, 0.141],
            alphaTimes: [0.0, 0.030, 0.041, 0.101, 0.141],
            policy: .nearestFrame
        )
        #expect(pairs.map(\.alpha) == [0, 2, 3, 4])
    }

    @Test func strictIgnoresContainerTimeBaseButRequiresRealPTS() throws {
        let pairs = try ExternalAlphaFrameSynchronizer.pair(
            colorTimes: [0, 0.5, 1],
            alphaTimes: [0, 0.5, 1],
            policy: .strict,
            colorFPS: 2,
            alphaFPS: 2.0005,
            colorDuration: 1.5,
            alphaDuration: 1.5,
            colorTimeBase: "1/600",
            alphaTimeBase: "1/1000"
        )
        #expect(pairs.map(\.alpha) == [0, 1, 2])

        do {
            _ = try ExternalAlphaFrameSynchronizer.pair(
                colorTimes: [0, 0.5], alphaTimes: [0, 0.5], policy: .strict,
                colorHasRealPTS: true, alphaHasRealPTS: false
            )
            Issue.record("strict 不应接受合成 PTS")
        } catch let error as ExternalAlphaError {
            #expect(error == .noTimestamp)
        }
    }

    @Test func synchronizationPoliciesHaveDistinctBoundaryBehavior() throws {
        let nearest = try ExternalAlphaFrameSynchronizer.matches(
            colorTimes: [0, 0.25, 0.75, 1.25], alphaTimes: [0, 1], policy: .nearestFrame
        )
        #expect(nearest.map(\.nearestAlpha) == [0, 0, 1, 1])

        let resampled = try ExternalAlphaFrameSynchronizer.matches(
            colorTimes: [-0.25, 0.25, 0.75, 1.25], alphaTimes: [0, 1], policy: .resampleToColorTimeline
        )
        #expect(resampled[0] == .init(color: 0, alpha0: 0, alpha1: 0, fraction: 0))
        #expect(abs(resampled[1].fraction - 0.25) < 0.000001)
        #expect(abs(resampled[2].fraction - 0.75) < 0.000001)
        #expect(resampled[3].alpha0 == 1 && resampled[3].alpha1 == 1)

        let trimmed = try ExternalAlphaFrameSynchronizer.matches(
            colorTimes: [-0.5, 0, 0.5, 1, 1.5], alphaTimes: [0, 0.5, 1], policy: .trimToShortest
        )
        #expect(trimmed.map(\.color) == [1, 2, 3])
    }

    @Test func projectRoundTripPreservesExternalAlphaRelationship() throws {
        var document = ChronoVolumeProjectDocument()
        let id = UUID()
        let settings = ExternalAlphaSettings(
            channel: .green,
            invert: true,
            range: .limited,
            syncPolicy: .nearestFrame,
            resizePolicy: .scaleAlphaToColorSize,
            association: .straight
        )
        document.mainVideos = [.init(
            id: id,
            path: "/tmp/name_A_color.mov",
            name: "name_A_color.mov",
            alphaPath: "/tmp/name_B_alpha.mkv",
            alphaSourceMode: .external,
            externalAlphaSettings: settings
        )]
        let restored = try JSONDecoder().decode(
            ChronoVolumeProjectDocument.self,
            from: JSONEncoder().encode(document)
        )
        let pair = restored.mainVideos[0].resolvedSourcePair()
        #expect(pair.alphaURL?.path == "/tmp/name_B_alpha.mkv")
        #expect(pair.alphaSourceMode == .external)
        #expect(pair.externalAlphaSettings == settings)
    }

    @Test func alphaCheaterMultiSelectionClassifiesCompleteAndIncompleteGroups() throws {
        let root = URL(fileURLWithPath: "/tmp/AlphaCheater-import")
        let urls = [
            root.appendingPathComponent("first_A_color.mov"),
            root.appendingPathComponent("first_B_alpha.mkv"),
            root.appendingPathComponent("second-A_color.mov"),
            root.appendingPathComponent("third-B_alpha.mkv"),
            root.appendingPathComponent("not-alpha-cheater.mov")
        ]
        let result = VideoSourcePairDiscovery.classifyAlphaCheaterURLs(urls)
        #expect(result.groups.count == 3)
        #expect(result.unrecognized == [urls[4]])

        let complete = try #require(result.groups.first { $0.colorURL == urls[0] })
        #expect(complete.alphaURL == urls[1])
        #expect(!complete.sourcePair.usesGeneratedWhiteColor)

        let colorOnly = try #require(result.groups.first { $0.colorURL == urls[2] })
        #expect(colorOnly.alphaURL == nil)
        #expect(colorOnly.sourcePair.alphaSourceMode == .opaque)

        let alphaOnly = try #require(result.groups.first { $0.alphaURL == urls[3] })
        #expect(alphaOnly.colorURL == nil)
        #expect(alphaOnly.sourcePair.colorURL == urls[3])
        #expect(alphaOnly.sourcePair.usesGeneratedWhiteColor)
        #expect(alphaOnly.sourcePair.alphaSourceMode == .external)
    }

    @Test func incrementalGlobalImportUpgradesColorOnlyInPlace() throws {
        let directory = URL(fileURLWithPath: "/tmp/incremental-color-first")
        let color = directory.appendingPathComponent("foo_A_color.mov")
        let alpha = directory.appendingPathComponent("foo_B_alpha.mkv")
        let stableID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let first = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([color]),
            into: [],
            makeID: { stableID }
        )
        var colorOnly = try #require(first.videos.first)
        let originalID = colorOnly.id
        #expect(originalID == stableID)
        colorOnly.sourcePair.externalAlphaSettings = ExternalAlphaSettings(
            channel: .red,
            invert: true,
            range: .limited,
            syncPolicy: .nearestFrame,
            resizePolicy: .scaleAlphaToColorSize,
            association: .premultiplied
        )

        let second = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([alpha]),
            into: [colorOnly]
        )
        let complete = try #require(second.videos.first)
        #expect(second.videos.count == 1)
        #expect(complete.id == originalID)
        #expect(complete.sourcePair.colorURL == color)
        #expect(complete.sourcePair.alphaURL == alpha)
        #expect(complete.sourcePair.externalAlphaSettings == colorOnly.sourcePair.externalAlphaSettings)
        #expect(complete.hasColorSource && complete.hasAlphaSource)
    }

    @Test func incrementalGlobalImportUpgradesAlphaOnlyInPlace() throws {
        let directory = URL(fileURLWithPath: "/tmp/incremental-alpha-first")
        let color = directory.appendingPathComponent("foo-A_color.mov")
        let alpha = directory.appendingPathComponent("foo-B_alpha.mkv")
        let first = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([alpha]),
            into: []
        )
        let alphaOnly = try #require(first.videos.first)
        let originalID = alphaOnly.id
        #expect(alphaOnly.sourcePair.usesGeneratedWhiteColor)

        let second = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([color]),
            into: first.videos
        )
        let complete = try #require(second.videos.first)
        #expect(second.videos.count == 1)
        #expect(complete.id == originalID)
        #expect(complete.sourcePair.colorURL == color)
        #expect(complete.sourcePair.alphaURL == alpha)
        #expect(!complete.sourcePair.usesGeneratedWhiteColor)
    }

    @Test func repeatedCompleteGlobalImportDoesNotDuplicateMedia() throws {
        let directory = URL(fileURLWithPath: "/tmp/repeated-complete")
        let urls = [
            directory.appendingPathComponent("foo_A_color.mov"),
            directory.appendingPathComponent("foo_B_alpha.mkv")
        ]
        let classification = VideoSourcePairDiscovery.classifyAlphaCheaterURLs(urls)
        let first = AlphaCheaterImportedVideoState.merge(classification, into: [])
        let originalID = try #require(first.videos.first).id
        let second = AlphaCheaterImportedVideoState.merge(classification, into: first.videos)
        #expect(second.videos.count == 1)
        #expect(second.videos.first?.id == originalID)
        #expect(second.conflicts.isEmpty)
    }

    @Test func samePrefixInDifferentDirectoriesNeverPairs() throws {
        let firstDirectory = URL(fileURLWithPath: "/tmp/pairing-directory-one")
        let secondDirectory = URL(fileURLWithPath: "/tmp/pairing-directory-two")
        let color = firstDirectory.appendingPathComponent("foo_A_color.mov")
        let alpha = secondDirectory.appendingPathComponent("foo_B_alpha.mkv")
        let merged = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([color, alpha]),
            into: []
        )
        #expect(merged.videos.count == 2)
        #expect(Set(merged.videos.compactMap(\.pairingKey)).count == 2)
        #expect(merged.videos.contains { $0.hasColorSource && !$0.hasAlphaSource })
        #expect(merged.videos.contains { !$0.hasColorSource && $0.hasAlphaSource })
    }

    @Test func duplicateRolesReportConflictAndKeepFirstFile() throws {
        let directory = URL(fileURLWithPath: "/tmp/role-conflicts")
        let firstColor = directory.appendingPathComponent("foo_A_color.mov")
        let secondColor = directory.appendingPathComponent("foo_A_color.mp4")
        let firstAlpha = directory.appendingPathComponent("foo_B_alpha.mkv")
        let secondAlpha = directory.appendingPathComponent("foo_B_alpha.mov")
        let classification = VideoSourcePairDiscovery.classifyAlphaCheaterURLs([
            firstColor, secondColor, firstAlpha, secondAlpha
        ])
        let merged = AlphaCheaterImportedVideoState.merge(classification, into: [])
        let item = try #require(merged.videos.first)
        #expect(merged.videos.count == 1)
        #expect(merged.conflicts.count == 2)
        #expect(item.sourcePair.colorURL == firstColor)
        #expect(item.sourcePair.alphaURL == firstAlpha)
        #expect(merged.conflicts.map(\.diagnostic).allSatisfy { $0.contains("保留") && $0.contains("未覆盖") })
    }

    @Test func completePairRemovalTransitionsAreExplicit() throws {
        let directory = URL(fileURLWithPath: "/tmp/removal-transitions")
        let color = directory.appendingPathComponent("foo_A_color.mov")
        let alpha = directory.appendingPathComponent("foo_B_alpha.mkv")
        let complete = try #require(AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([color, alpha]),
            into: []
        ).videos.first)

        let alphaOnly = AlphaCheaterImportedVideoState.removingColor(from: complete)
        #expect(!alphaOnly.hasColorSource && alphaOnly.hasAlphaSource)
        #expect(alphaOnly.sourcePair.colorURL == alpha)
        #expect(alphaOnly.sourcePair.usesGeneratedWhiteColor)
        #expect(alphaOnly.sourcePair.externalAlphaSettings.association == .straight)
        #expect(alphaOnly.sourcePair.externalAlphaSettings.syncPolicy == .strict)
        #expect(alphaOnly.sourcePair.externalAlphaSettings.resizePolicy == .strict)

        let colorOnly = AlphaCheaterImportedVideoState.removingAlpha(from: complete)
        #expect(colorOnly.hasColorSource && !colorOnly.hasAlphaSource)
        #expect(colorOnly.sourcePair.colorURL == color)
        #expect(colorOnly.sourcePair.alphaSourceMode == .opaque)
    }

    @Test func mediaBarAddingColorToAlphaOnlyDisablesGeneratedWhite() throws {
        let directory = URL(fileURLWithPath: "/tmp/media-add-color")
        let color = directory.appendingPathComponent("foo_A_color.mov")
        let alpha = directory.appendingPathComponent("foo_B_alpha.mkv")
        let alphaOnly = try #require(AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([alpha]),
            into: []
        ).videos.first)
        let complete = AlphaCheaterImportedVideoState.addingColor(color, to: alphaOnly)
        #expect(complete.hasColorSource && complete.hasAlphaSource)
        #expect(!complete.sourcePair.usesGeneratedWhiteColor)
        #expect(complete.pairingKey == alphaOnly.pairingKey)
    }

    @Test func alphaOnlyExposesOnlyEffectiveSettingsAndIgnoresInvalidEdits() throws {
        let alpha = URL(fileURLWithPath: "/tmp/settings/foo_B_alpha.mkv")
        let pair = VideoSourcePair(
            colorURL: alpha,
            alphaURL: alpha,
            alphaSourceMode: .external,
            externalAlphaSettings: ExternalAlphaSettings(
                channel: .green,
                invert: true,
                range: .limited,
                syncPolicy: .nearestFrame,
                resizePolicy: .scaleAlphaToColorSize,
                association: .premultiplied
            ),
            usesGeneratedWhiteColor: true
        )
        let item = MainImportedVideo(id: UUID(), sourcePair: pair, isAlphaCheater: true)
        #expect(ExternalAlphaSettingsAvailability.editableSettings(for: pair) == [.channel, .invert, .range])
        #expect(pair.externalAlphaSettings.association == .straight)
        #expect(pair.externalAlphaSettings.syncPolicy == .strict)
        #expect(pair.externalAlphaSettings.resizePolicy == .strict)

        var invalidEdit = pair.externalAlphaSettings
        invalidEdit.association = .premultiplied
        invalidEdit.syncPolicy = .trimToShortest
        invalidEdit.resizePolicy = .scaleAlphaToColorSize
        let update = AlphaCheaterImportedVideoState.updatingExternalAlphaSettings(invalidEdit, for: item)
        #expect(!update.requiresReload)
        #expect(update.item.sourcePair == item.sourcePair)
    }

    @Test func alphaOnlyImportBuildsStraightWhiteRGBVolume() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let package = try await VideoVolumeLoader.load(
            colorURL: fixture.alpha,
            alphaURL: fixture.alpha,
            settings: ExternalAlphaSettings(),
            generatedWhiteColor: true,
            maxWidth: 16,
            maxHeight: 16,
            previewMaxDepth: 16
        )
        let frameBytes = 16 * 16 * 4
        for (frame, expectedAlpha) in [0, 64, 128, 255].enumerated() {
            let offset = frame * frameBytes
            #expect(Array(package.fullTemporalVolume.rgba[offset..<(offset + 3)]) == [255, 255, 255])
            #expect(package.fullTemporalVolume.rgba[offset + 3] == expectedAlpha)
        }
        #expect(package.alphaSyncStatus.contains("白模"))
        #expect(package.sourceBitDepth == 8)
    }

    @Test func workerAlphaOnlySegmentUsesGeneratedWhiteRGBAndExternalAlpha() throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let output = fixture.directory.appendingPathComponent("worker-white-output", isDirectory: true)
        let job = DistributedJobManifest(
            jobID: UUID(),
            sourceFileName: fixture.alpha.lastPathComponent,
            sourceFileHash: Self.sha256(fixture.alpha),
            alphaSourceFileName: fixture.alpha.lastPathComponent,
            alphaSourceFileHash: Self.sha256(fixture.alpha),
            alphaSourceMode: .external,
            externalAlphaSettings: ExternalAlphaSettings(),
            usesGeneratedWhiteColor: true,
            sourceColorBitDepth: 8,
            sourceAlphaBitDepth: 8,
            outputBitDepth: 8,
            sourceWidth: 16,
            sourceHeight: 16,
            sourceFrameCount: 4,
            fps: 2,
            mode: .axis,
            axis: .x,
            referencePlane: ReferencePlaneState(),
            preserveAlpha: true,
            padToEven: true,
            qualityScale: 1,
            outputWidth: 4,
            outputHeight: 16,
            totalOutputFrames: 1,
            outputStartFrame: 0,
            outputEndFrame: 0,
            codec: "ap4h",
            colorProfile: .rec709,
            createdAtISO8601: "test"
        )
        let result = try WorkerJobExecutor().execute(
            request: StartDistributedJobRequest(
                job: job,
                localSourcePath: fixture.alpha.path,
                outputDirectory: output.path,
                preparedRawCachePath: nil,
                localAlphaSourcePath: fixture.alpha.path
            ),
            progress: { _, _ in }
        )
        let frame = try Self.readFirstBGRAFrame(result.segmentURL)
        let alphas = (0..<4).map { frame.bytes[$0 * 4 + 3] }
        #expect(alphas == [0, 64, 128, 255])
        let transparentPixel = 0
        #expect(Array(frame.bytes[transparentPixel..<(transparentPixel + 3)]).allSatisfy { $0 >= 250 })
        let opaquePixel = 3 * 4
        #expect(Array(frame.bytes[opaquePixel..<(opaquePixel + 3)]).allSatisfy { $0 >= 250 })
    }

    @MainActor
    @Test func gray16AlphaOnlyLoadsInteractivelyButDistributedEntryRejectsBeforeTransfer() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makeGray16AlphaOnlyFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 16_384, 32_768, 65_535]
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pair = VideoSourcePair(
            colorURL: fixture.alpha,
            alphaURL: fixture.alpha,
            alphaSourceMode: .external,
            usesGeneratedWhiteColor: true
        )
        let package = try await VideoVolumeLoader.load(
            colorURL: fixture.alpha,
            alphaURL: fixture.alpha,
            settings: pair.externalAlphaSettings,
            generatedWhiteColor: true,
            maxWidth: 16,
            maxHeight: 16,
            previewMaxDepth: 16
        )
        #expect(package.sourceAlphaBitDepth == 16)
        let frameBytes = 16 * 16 * 4
        for (frameIndex, expectedAlpha) in [0, 64, 128, 255].enumerated() {
            let offset = frameIndex * frameBytes
            #expect(Array(package.fullTemporalVolume.rgba[offset..<(offset + 3)]) == [255, 255, 255])
            #expect(abs(Int(package.fullTemporalVolume.rgba[offset + 3]) - expectedAlpha) <= 1)
        }

        let model = AppModel()
        let distributed = DistributedExportSettings()
        distributed.isEnabled = true
        model.videoSourcePair = pair
        model.sourceBitDepth = package.sourceBitDepth
        model.sourceAlphaBitDepth = package.sourceAlphaBitDepth
        model.startDistributedExportInteractively(
            settings: distributed,
            preserveAlpha: true,
            bitDepth: 8
        )
        #expect(model.status.contains(ExternalPairedRenderPolicy.generatedWhiteHighBitDepthReason))
        #expect(model.status.contains("未开始传输或建立 Worker 作业"))
        #expect(distributed.workers.allSatisfy { $0.rawCacheState != "checking" })
    }

    @Test func projectRoundTripPreservesAlphaOnlyWhiteModelAndOrigin() throws {
        var document = ChronoVolumeProjectDocument()
        let alpha = URL(fileURLWithPath: "/tmp/example_B_alpha.mkv")
        let pairingKey = try #require(VideoSourcePairDiscovery.pairingKey(for: alpha))
        document.mainVideos = [.init(
            id: UUID(),
            path: alpha.path,
            name: alpha.lastPathComponent,
            alphaPath: alpha.path,
            alphaSourceMode: .external,
            externalAlphaSettings: ExternalAlphaSettings(),
            usesGeneratedWhiteColor: true,
            isAlphaCheater: true,
            pairingKey: pairingKey
        )]
        let restored = try JSONDecoder().decode(
            ChronoVolumeProjectDocument.self,
            from: JSONEncoder().encode(document)
        )
        let record = try #require(restored.mainVideos.first)
        #expect(record.isAlphaCheater == true)
        #expect(record.pairingKey == pairingKey)
        #expect(record.resolvedSourcePair().usesGeneratedWhiteColor)
        #expect(record.resolvedSourcePair().alphaURL == alpha)
        let restoredItem = MainImportedVideo(
            id: record.id,
            sourcePair: record.resolvedSourcePair(),
            isAlphaCheater: record.isAlphaCheater ?? false,
            pairingKey: record.pairingKey
        )
        #expect(restoredItem.pairingKey == pairingKey)
        #expect(!restoredItem.hasColorSource && restoredItem.hasAlphaSource)
    }

    @Test func projectRoundTripPreservesCompleteAlphaCheaterPairingKeyAndState() throws {
        let directory = URL(fileURLWithPath: "/tmp/project-complete-pair")
        let color = directory.appendingPathComponent("foo_A_color.mov")
        let alpha = directory.appendingPathComponent("foo_B_alpha.mkv")
        let pairingKey = try #require(VideoSourcePairDiscovery.pairingKey(for: color))
        var document = ChronoVolumeProjectDocument()
        document.mainVideos = [.init(
            id: UUID(),
            path: color.path,
            name: color.lastPathComponent,
            alphaPath: alpha.path,
            alphaSourceMode: .external,
            externalAlphaSettings: ExternalAlphaSettings(channel: .blue),
            usesGeneratedWhiteColor: false,
            isAlphaCheater: true,
            pairingKey: pairingKey
        )]
        let restored = try JSONDecoder().decode(
            ChronoVolumeProjectDocument.self,
            from: JSONEncoder().encode(document)
        )
        let record = try #require(restored.mainVideos.first)
        let item = MainImportedVideo(
            id: record.id,
            sourcePair: record.resolvedSourcePair(),
            isAlphaCheater: record.isAlphaCheater ?? false,
            pairingKey: record.pairingKey
        )
        #expect(item.isAlphaCheater)
        #expect(item.pairingKey == pairingKey)
        #expect(item.hasColorSource && item.hasAlphaSource)
        #expect(!item.sourcePair.usesGeneratedWhiteColor)
        #expect(item.sourcePair.externalAlphaSettings.channel == .blue)
    }

    @Test func restoredMovedColorOnlyUsesResolvedPairingKeyAndUpgradesInPlace() throws {
        let oldDirectory = URL(fileURLWithPath: "/tmp/restore-old-color-only")
        let movedDirectory = URL(fileURLWithPath: "/tmp/restore-new-color-only")
        let oldColor = oldDirectory.appendingPathComponent("foo_A_color.mov")
        let movedColor = movedDirectory.appendingPathComponent("foo_A_color.mov")
        let movedAlpha = movedDirectory.appendingPathComponent("foo_B_alpha.mkv")
        let oldKey = try #require(VideoSourcePairDiscovery.pairingKey(for: oldColor))
        let movedKey = try #require(VideoSourcePairDiscovery.pairingKey(for: movedColor))
        let bookmark = Data([0x41])
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let settings = ExternalAlphaSettings(
            channel: .red,
            invert: true,
            range: .limited,
            syncPolicy: .nearestFrame,
            resizePolicy: .scaleAlphaToColorSize,
            association: .premultiplied
        )
        let record = ChronoVolumeProjectDocument.MainVideoRecord(
            id: id,
            path: oldColor.path,
            name: oldColor.lastPathComponent,
            colorBookmark: bookmark,
            alphaSourceMode: .opaque,
            externalAlphaSettings: settings,
            usesGeneratedWhiteColor: false,
            isAlphaCheater: true,
            pairingKey: oldKey
        )
        let restored = MainImportedVideo.restoring(from: record) {
            $0 == bookmark ? movedColor : nil
        }

        #expect(restored.pairingKey == movedKey)
        #expect(restored.pairingKey != oldKey)
        let before = MainImportedVideo(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
            url: URL(fileURLWithPath: "/tmp/before.mov")
        )
        let after = MainImportedVideo(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            url: URL(fileURLWithPath: "/tmp/after.mov")
        )
        let merged = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([movedAlpha]),
            into: [before, restored, after]
        )
        let complete = try #require(merged.videos.first { $0.id == id })
        #expect(merged.videos.map(\.id) == [before.id, id, after.id])
        #expect(complete.sourcePair.colorURL == movedColor)
        #expect(complete.sourcePair.alphaURL == movedAlpha)
        #expect(complete.sourcePair.externalAlphaSettings == settings)
        #expect(complete.isAlphaCheater)
        #expect(!complete.sourcePair.usesGeneratedWhiteColor)
    }

    @Test func restoredMovedAlphaOnlyUsesResolvedPairingKeyAndUpgradesInPlace() throws {
        let oldDirectory = URL(fileURLWithPath: "/tmp/restore-old-alpha-only")
        let movedDirectory = URL(fileURLWithPath: "/tmp/restore-new-alpha-only")
        let oldAlpha = oldDirectory.appendingPathComponent("foo_B_alpha.mkv")
        let movedColor = movedDirectory.appendingPathComponent("foo_A_color.mov")
        let movedAlpha = movedDirectory.appendingPathComponent("foo_B_alpha.mkv")
        let oldKey = try #require(VideoSourcePairDiscovery.pairingKey(for: oldAlpha))
        let movedKey = try #require(VideoSourcePairDiscovery.pairingKey(for: movedAlpha))
        let bookmark = Data([0x42])
        let id = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let requestedSettings = ExternalAlphaSettings(
            channel: .blue,
            invert: true,
            range: .full,
            syncPolicy: .trimToShortest,
            resizePolicy: .scaleAlphaToColorSize,
            association: .premultiplied
        )
        let expectedSettings = requestedSettings.applyingGeneratedWhiteColorSemantics(true)
        let record = ChronoVolumeProjectDocument.MainVideoRecord(
            id: id,
            path: oldAlpha.path,
            name: oldAlpha.lastPathComponent,
            colorBookmark: bookmark,
            alphaPath: oldAlpha.path,
            alphaBookmark: bookmark,
            alphaSourceMode: .external,
            externalAlphaSettings: requestedSettings,
            usesGeneratedWhiteColor: true,
            isAlphaCheater: true,
            pairingKey: oldKey
        )
        let restored = MainImportedVideo.restoring(from: record) {
            $0 == bookmark ? movedAlpha : nil
        }

        #expect(restored.pairingKey == movedKey)
        #expect(restored.pairingKey != oldKey)
        #expect(restored.sourcePair.usesGeneratedWhiteColor)
        let merged = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([movedColor]),
            into: [restored]
        )
        let complete = try #require(merged.videos.first)
        #expect(merged.videos.count == 1)
        #expect(complete.id == id)
        #expect(complete.sourcePair.colorURL == movedColor)
        #expect(complete.sourcePair.alphaURL == movedAlpha)
        #expect(complete.sourcePair.externalAlphaSettings == expectedSettings)
        #expect(complete.isAlphaCheater)
        #expect(!complete.sourcePair.usesGeneratedWhiteColor)
    }

    @Test func restoredMovedCompletePairRepeatedImportDoesNotDuplicate() throws {
        let oldDirectory = URL(fileURLWithPath: "/tmp/restore-old-complete")
        let movedDirectory = URL(fileURLWithPath: "/tmp/restore-new-complete")
        let oldColor = oldDirectory.appendingPathComponent("foo-A_color.mov")
        let oldAlpha = oldDirectory.appendingPathComponent("foo-B_alpha.mkv")
        let movedColor = movedDirectory.appendingPathComponent("foo-A_color.mov")
        let movedAlpha = movedDirectory.appendingPathComponent("foo-B_alpha.mkv")
        let colorBookmark = Data([0x43])
        let alphaBookmark = Data([0x44])
        let id = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let settings = ExternalAlphaSettings(
            channel: .green,
            invert: false,
            range: .auto,
            syncPolicy: .resampleToColorTimeline,
            resizePolicy: .strict,
            association: .straight
        )
        let record = ChronoVolumeProjectDocument.MainVideoRecord(
            id: id,
            path: oldColor.path,
            name: oldColor.lastPathComponent,
            colorBookmark: colorBookmark,
            alphaPath: oldAlpha.path,
            alphaBookmark: alphaBookmark,
            alphaSourceMode: .external,
            externalAlphaSettings: settings,
            usesGeneratedWhiteColor: false,
            isAlphaCheater: true,
            pairingKey: VideoSourcePairDiscovery.pairingKey(for: oldColor)
        )
        let restored = MainImportedVideo.restoring(from: record) { bookmark in
            if bookmark == colorBookmark { return movedColor }
            if bookmark == alphaBookmark { return movedAlpha }
            return nil
        }
        let merged = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([movedColor, movedAlpha]),
            into: [restored]
        )
        let complete = try #require(merged.videos.first)
        #expect(merged.videos.count == 1)
        #expect(merged.conflicts.isEmpty)
        #expect(complete.id == id)
        #expect(complete.sourcePair.colorURL == movedColor)
        #expect(complete.sourcePair.alphaURL == movedAlpha)
        #expect(complete.sourcePair.externalAlphaSettings == settings)
        #expect(complete.isAlphaCheater)
        #expect(!complete.sourcePair.usesGeneratedWhiteColor)
    }

    @Test func restoredUnrecognizedCurrentNameFallsBackToPersistedPairingKey() throws {
        let oldColor = URL(fileURLWithPath: "/tmp/restore-fallback/foo_A_color.mov")
        let renamedColor = URL(fileURLWithPath: "/tmp/restore-fallback-moved/renamed.mov")
        let persistedKey = try #require(VideoSourcePairDiscovery.pairingKey(for: oldColor))
        let bookmark = Data([0x45])
        let id = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let settings = ExternalAlphaSettings(channel: .alpha, invert: true, range: .full)
        let record = ChronoVolumeProjectDocument.MainVideoRecord(
            id: id,
            path: oldColor.path,
            name: oldColor.lastPathComponent,
            colorBookmark: bookmark,
            alphaSourceMode: .opaque,
            externalAlphaSettings: settings,
            usesGeneratedWhiteColor: false,
            isAlphaCheater: true,
            pairingKey: persistedKey
        )
        let restored = MainImportedVideo.restoring(from: record) {
            $0 == bookmark ? renamedColor : nil
        }

        #expect(restored.id == id)
        #expect(restored.sourcePair.colorURL == renamedColor)
        #expect(restored.pairingKey == persistedKey)
        #expect(restored.sourcePair.externalAlphaSettings == settings)
        #expect(restored.isAlphaCheater)
        #expect(!restored.sourcePair.usesGeneratedWhiteColor)
    }

    @Test func pairingKeyNormalizesStandardizedAndSymbolicLinkDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChronoVolumePairingSymlink-\(UUID().uuidString)",
            isDirectory: true
        )
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: aliasDirectory,
            withDestinationURL: realDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let color = realDirectory
            .appendingPathComponent("nested")
            .appendingPathComponent("..")
            .appendingPathComponent("foo_A_color.mov")
        let alpha = aliasDirectory.appendingPathComponent("foo_B_alpha.mkv")
        #expect(VideoSourcePairDiscovery.pairingKey(for: color)
            == VideoSourcePairDiscovery.pairingKey(for: alpha))
    }

    @Test func restoredManualCrossGroupPairOriginatingFromAlphaKeepsAlphaKey() throws {
        let fooDirectory = URL(fileURLWithPath: "/tmp/manual-alpha-origin-foo")
        let barDirectory = URL(fileURLWithPath: "/tmp/manual-alpha-origin-bar")
        let fooColor = fooDirectory.appendingPathComponent("foo_A_color.mov")
        let fooAlpha = fooDirectory.appendingPathComponent("foo_B_alpha.mkv")
        let barColor = barDirectory.appendingPathComponent("bar_A_color.mov")
        let id = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let initial = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([fooAlpha]),
            into: [],
            makeID: { id }
        )
        var alphaOnly = try #require(initial.videos.first)
        alphaOnly.sourcePair.externalAlphaSettings.channel = .blue
        alphaOnly.sourcePair.externalAlphaSettings.invert = true
        alphaOnly.sourcePair.externalAlphaSettings.range = .limited
        let fooKey = try #require(alphaOnly.pairingKey)
        let complete = AlphaCheaterImportedVideoState.addingColor(barColor, to: alphaOnly)
        let settings = complete.sourcePair.externalAlphaSettings
        #expect(complete.pairingKey == fooKey)

        var document = ChronoVolumeProjectDocument()
        document.mainVideos = [.init(
            id: complete.id,
            path: complete.sourcePair.colorURL.path,
            name: complete.name,
            alphaPath: complete.sourcePair.alphaURL?.path,
            alphaSourceMode: complete.sourcePair.alphaSourceMode,
            externalAlphaSettings: settings,
            usesGeneratedWhiteColor: complete.sourcePair.usesGeneratedWhiteColor,
            isAlphaCheater: complete.isAlphaCheater,
            pairingKey: complete.pairingKey
        )]
        let reopenedDocument = try JSONDecoder().decode(
            ChronoVolumeProjectDocument.self,
            from: JSONEncoder().encode(document)
        )
        let reopenedRecord = try #require(reopenedDocument.mainVideos.first)
        let restoration = MainImportedVideo.restorationResult(from: reopenedRecord)
        let reopened = restoration.item
        #expect(restoration.pairingDiagnostic == nil)
        #expect(reopened.pairingKey == fooKey)
        #expect(reopened.id == id)
        #expect(reopened.sourcePair.externalAlphaSettings == settings)
        #expect(reopened.isAlphaCheater)
        #expect(!reopened.sourcePair.usesGeneratedWhiteColor)

        let before = MainImportedVideo(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000000")!,
            url: URL(fileURLWithPath: "/tmp/manual-alpha-before.mov")
        )
        let after = MainImportedVideo(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
            url: URL(fileURLWithPath: "/tmp/manual-alpha-after.mov")
        )
        let reimported = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([fooColor, fooAlpha]),
            into: [before, reopened, after]
        )
        let retained = try #require(reimported.videos.first { $0.id == id })
        #expect(reimported.videos.map(\.id) == [before.id, id, after.id])
        #expect(reimported.conflicts.count == 1)
        #expect(reimported.conflicts.first?.role == .color)
        #expect(retained.sourcePair.colorURL == barColor)
        #expect(retained.sourcePair.alphaURL == fooAlpha)
        #expect(retained.pairingKey == fooKey)
        #expect(retained.sourcePair.externalAlphaSettings == settings)
        #expect(retained.isAlphaCheater)
        #expect(!retained.sourcePair.usesGeneratedWhiteColor)
    }

    @Test func restoredManualCrossGroupPairOriginatingFromColorKeepsColorKey() throws {
        let fooDirectory = URL(fileURLWithPath: "/tmp/manual-color-origin-foo")
        let barDirectory = URL(fileURLWithPath: "/tmp/manual-color-origin-bar")
        let fooColor = fooDirectory.appendingPathComponent("foo_A_color.mov")
        let fooAlpha = fooDirectory.appendingPathComponent("foo_B_alpha.mkv")
        let barAlpha = barDirectory.appendingPathComponent("bar_B_alpha.mkv")
        let id = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
        let initial = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([fooColor]),
            into: [],
            makeID: { id }
        )
        var colorOnly = try #require(initial.videos.first)
        colorOnly.sourcePair.externalAlphaSettings = ExternalAlphaSettings(
            channel: .green,
            invert: true,
            range: .full,
            syncPolicy: .nearestFrame,
            resizePolicy: .scaleAlphaToColorSize,
            association: .premultiplied
        )
        let fooKey = try #require(colorOnly.pairingKey)
        let complete = AlphaCheaterImportedVideoState.addingAlpha(barAlpha, to: colorOnly)
        let settings = complete.sourcePair.externalAlphaSettings
        #expect(complete.pairingKey == fooKey)

        var document = ChronoVolumeProjectDocument()
        document.mainVideos = [.init(
            id: complete.id,
            path: complete.sourcePair.colorURL.path,
            name: complete.name,
            alphaPath: complete.sourcePair.alphaURL?.path,
            alphaSourceMode: complete.sourcePair.alphaSourceMode,
            externalAlphaSettings: settings,
            usesGeneratedWhiteColor: complete.sourcePair.usesGeneratedWhiteColor,
            isAlphaCheater: complete.isAlphaCheater,
            pairingKey: complete.pairingKey
        )]
        let reopenedDocument = try JSONDecoder().decode(
            ChronoVolumeProjectDocument.self,
            from: JSONEncoder().encode(document)
        )
        let reopenedRecord = try #require(reopenedDocument.mainVideos.first)
        let restoration = MainImportedVideo.restorationResult(from: reopenedRecord)
        let reopened = restoration.item
        #expect(restoration.pairingDiagnostic == nil)
        #expect(reopened.pairingKey == fooKey)
        #expect(reopened.id == id)
        #expect(reopened.sourcePair.externalAlphaSettings == settings)
        #expect(reopened.isAlphaCheater)
        #expect(!reopened.sourcePair.usesGeneratedWhiteColor)

        let before = MainImportedVideo(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000000")!,
            url: URL(fileURLWithPath: "/tmp/manual-color-before.mov")
        )
        let after = MainImportedVideo(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!,
            url: URL(fileURLWithPath: "/tmp/manual-color-after.mov")
        )
        let reimported = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([fooColor, fooAlpha]),
            into: [before, reopened, after]
        )
        let retained = try #require(reimported.videos.first { $0.id == id })
        #expect(reimported.videos.map(\.id) == [before.id, id, after.id])
        #expect(reimported.conflicts.count == 1)
        #expect(reimported.conflicts.first?.role == .alpha)
        #expect(retained.sourcePair.colorURL == fooColor)
        #expect(retained.sourcePair.alphaURL == barAlpha)
        #expect(retained.pairingKey == fooKey)
        #expect(retained.sourcePair.externalAlphaSettings == settings)
        #expect(retained.isAlphaCheater)
        #expect(!retained.sourcePair.usesGeneratedWhiteColor)
    }

    @Test func ambiguousRestoredPairWithoutPersistedKeyUsesDeterministicCompatibilityKey() throws {
        let color = URL(fileURLWithPath: "/tmp/manual-no-key-z/bar_A_color.mov")
        let alpha = URL(fileURLWithPath: "/tmp/manual-no-key-a/foo_B_alpha.mkv")
        let colorKey = try #require(VideoSourcePairDiscovery.pairingKey(for: color))
        let alphaKey = try #require(VideoSourcePairDiscovery.pairingKey(for: alpha))
        let pair = VideoSourcePair(
            colorURL: color,
            alphaURL: alpha,
            alphaSourceMode: .external
        )
        let resolution = VideoSourcePairDiscovery.restoredPairingIdentity(
            for: pair,
            persistedKey: nil
        )
        #expect(resolution.pairingKey == min(colorKey, alphaKey))
        #expect(resolution.diagnostic?.contains("按字典序较小者") == true)

        let explicitKey = "persisted-explicit-group"
        let explicitlyGrouped = MainImportedVideo(
            id: UUID(),
            sourcePair: pair,
            isAlphaCheater: true,
            pairingKey: explicitKey
        )
        #expect(explicitlyGrouped.pairingKey == explicitKey)
    }

    @Test func sameExistingColorThroughSymlinkDoesNotDuplicateOrConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChronoVolumeColorIdentity-\(UUID().uuidString)",
            isDirectory: true
        )
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let realColor = realDirectory.appendingPathComponent("foo_A_color.mov")
        let aliasColor = aliasDirectory.appendingPathComponent("foo_A_color.mov")
        try Data([1, 2, 3]).write(to: realColor)

        let first = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([realColor]),
            into: []
        )
        let firstID = try #require(first.videos.first).id
        let second = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([aliasColor]),
            into: first.videos
        )
        #expect(VideoSourcePairDiscovery.urlsReferToSameFile(realColor, aliasColor))
        #expect(second.videos.count == 1)
        #expect(second.videos.first?.id == firstID)
        #expect(second.conflicts.isEmpty)
    }

    @Test func sameExistingAlphaThroughSymlinkDoesNotDuplicateOrConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChronoVolumeAlphaIdentity-\(UUID().uuidString)",
            isDirectory: true
        )
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: realDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let realAlpha = realDirectory.appendingPathComponent("foo_B_alpha.mkv")
        let aliasAlpha = aliasDirectory.appendingPathComponent("foo_B_alpha.mkv")
        try Data([4, 5, 6]).write(to: realAlpha)

        let first = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([realAlpha]),
            into: []
        )
        let firstID = try #require(first.videos.first).id
        let second = AlphaCheaterImportedVideoState.merge(
            VideoSourcePairDiscovery.classifyAlphaCheaterURLs([aliasAlpha]),
            into: first.videos
        )
        #expect(VideoSourcePairDiscovery.urlsReferToSameFile(realAlpha, aliasAlpha))
        #expect(second.videos.count == 1)
        #expect(second.videos.first?.id == firstID)
        #expect(second.conflicts.isEmpty)
    }

    @Test func distinctExistingFilesWithSamePairingStemStillConflict() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChronoVolumeDistinctIdentity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstColor = directory.appendingPathComponent("foo_A_color.mov")
        let secondColor = directory.appendingPathComponent("foo_A_color.mp4")
        try Data([7, 8, 9]).write(to: firstColor)
        try Data([9, 8, 7]).write(to: secondColor)

        let classification = VideoSourcePairDiscovery.classifyAlphaCheaterURLs([
            firstColor,
            secondColor
        ])
        let merged = AlphaCheaterImportedVideoState.merge(classification, into: [])
        #expect(!VideoSourcePairDiscovery.urlsReferToSameFile(firstColor, secondColor))
        #expect(merged.videos.count == 1)
        #expect(merged.conflicts.count == 1)
        #expect(merged.conflicts.first?.keptURL == firstColor)
        #expect(merged.conflicts.first?.incomingURL == secondColor)
    }

    @Test func twoImportedVideosKeepIndependentPairsAcrossProjectRoundTrip() throws {
        var first = MainImportedVideo(id: UUID(), sourcePair: VideoSourcePair(
            colorURL: URL(fileURLWithPath: "/tmp/first.mov"),
            alphaURL: URL(fileURLWithPath: "/tmp/first-alpha.mkv"),
            alphaSourceMode: .external,
            externalAlphaSettings: ExternalAlphaSettings(channel: .red, invert: false, range: .full, syncPolicy: .strict, resizePolicy: .strict, association: .straight)
        ))
        var second = MainImportedVideo(id: UUID(), sourcePair: VideoSourcePair(
            colorURL: URL(fileURLWithPath: "/tmp/second.mov"),
            alphaURL: URL(fileURLWithPath: "/tmp/second-alpha.mkv"),
            alphaSourceMode: .external,
            externalAlphaSettings: ExternalAlphaSettings(channel: .blue, invert: true, range: .limited, syncPolicy: .nearestFrame, resizePolicy: .scaleAlphaToColorSize, association: .premultiplied)
        ))
        first.sourcePair.externalAlphaSettings.channel = .green
        second.sourcePair.externalAlphaSettings.invert = false

        var document = ChronoVolumeProjectDocument()
        document.mainVideos = [first, second].map { item in
            .init(
                id: item.id,
                path: item.sourcePair.colorURL.path,
                name: item.name,
                alphaPath: item.sourcePair.alphaURL?.path,
                alphaSourceMode: item.sourcePair.alphaSourceMode,
                externalAlphaSettings: item.sourcePair.externalAlphaSettings
            )
        }
        let restored = try JSONDecoder().decode(ChronoVolumeProjectDocument.self, from: JSONEncoder().encode(document))
        let pairs = restored.mainVideos.map { $0.resolvedSourcePair() }
        #expect(pairs[0].alphaURL?.path == "/tmp/first-alpha.mkv")
        #expect(pairs[0].externalAlphaSettings.channel == .green)
        #expect(pairs[1].alphaURL?.path == "/tmp/second-alpha.mkv")
        #expect(pairs[1].externalAlphaSettings.channel == .blue)
        #expect(pairs[1].externalAlphaSettings.association == .premultiplied)
    }

    @Test func premultipliedInputUsesExternalAlphaAndReportsZeroAlpha() {
        var rgba: [UInt8] = [50, 25, 10, 128, 7, 8, 9, 0]
        let count = ExternalAlphaMerger.unpremultiplyRGB(rgba: &rgba, normalizedAlpha: [32768, 0])
        #expect(abs(Int(rgba[0]) - 100) <= 1)
        #expect(abs(Int(rgba[1]) - 50) <= 1)
        #expect(Array(rgba[4..<7]) == [7, 8, 9])
        #expect(count == 1)
    }

    @Test func highPrecisionAlphaIsIndependentFromRGBA8Preview() throws {
        let preview = try ExternalAlphaNormalizer.previewByte(codeValue: 32768, bitDepth: 16, range: .full)
        let high = try ExternalAlphaNormalizer.highPrecisionUInt16(codeValue: 32768, bitDepth: 16, range: .full)
        #expect(preview == 128)
        #expect(high == 32768)
        #expect(UInt16(preview) * 257 != high)
    }

    @Test func distributedManifestCarriesBothHashesAndAllAlphaSettings() throws {
        let settings = ExternalAlphaSettings(channel: .blue, invert: true, range: .full, syncPolicy: .resampleToColorTimeline, resizePolicy: .strict, association: .straight)
        let manifest = DistributedJobManifest(
            jobID: UUID(),
            sourceFileName: "A.mov",
            sourceFileHash: "colorhash",
            alphaSourceFileName: "B.mkv",
            alphaSourceFileHash: "alphahash",
            alphaSourceMode: .external,
            externalAlphaSettings: settings,
            sourceWidth: 2,
            sourceHeight: 2,
            sourceFrameCount: 4,
            fps: 2,
            mode: .axis,
            axis: .x,
            referencePlane: ReferencePlaneState(),
            preserveAlpha: true,
            padToEven: true,
            qualityScale: 1,
            outputWidth: 4,
            outputHeight: 2,
            totalOutputFrames: 2,
            outputStartFrame: 0,
            outputEndFrame: 1,
            codec: "ap4h",
            colorProfile: .rec709,
            createdAtISO8601: "test"
        )
        let decoded = try JSONDecoder().decode(DistributedJobManifest.self, from: JSONEncoder().encode(manifest))
        #expect(decoded.sourceFileHash == "colorhash")
        #expect(decoded.alphaSourceFileHash == "alphahash")
        #expect(decoded.externalAlphaSettings == settings)

        let request = StartDistributedJobRequest(
            job: manifest,
            localSourcePath: "/worker/A.mov",
            outputDirectory: "/tmp/output",
            preparedRawCachePath: nil,
            localAlphaSourcePath: "/worker/B.mkv"
        )
        let decodedRequest = try JSONDecoder().decode(
            StartDistributedJobRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decodedRequest.localAlphaSourcePath == "/worker/B.mkv")
        #expect(decodedRequest.job.alphaSourceFileHash == "alphahash")
    }

    @Test func cacheKeyChangesWhenAlphaOrSettingsChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChronoVolumeCacheKey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let color = directory.appendingPathComponent("A.mov")
        let alpha1 = directory.appendingPathComponent("B1.mkv")
        let alpha2 = directory.appendingPathComponent("B2.mkv")
        try Data([1, 2, 3]).write(to: color)
        try Data([4, 5, 6]).write(to: alpha1)
        try Data([7, 8, 9]).write(to: alpha2)

        let pair1 = VideoSourcePair(colorURL: color, alphaURL: alpha1, alphaSourceMode: .external)
        let pair2 = VideoSourcePair(colorURL: color, alphaURL: alpha2, alphaSourceMode: .external)
        var pair3 = pair1
        pair3.externalAlphaSettings.invert = true
        #expect(HighPrecisionCacheHelper.cacheKey(for: pair1) != HighPrecisionCacheHelper.cacheKey(for: pair2))
        #expect(HighPrecisionCacheHelper.cacheKey(for: pair1) != HighPrecisionCacheHelper.cacheKey(for: pair3))
        let stableKey = HighPrecisionCacheHelper.cacheKey(for: pair1)
        for _ in 0..<1_000 {
            #expect(HighPrecisionCacheHelper.cacheKey(for: pair1) == stableKey)
        }
    }

    @MainActor
    @Test func mainActorCacheStatusQueryDoesNotReadOrHashSourceContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChronoVolumeMainActorCacheQuery-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let color = directory.appendingPathComponent("A.mov")
        let alpha = directory.appendingPathComponent("B.mkv")
        try Data(repeating: 0x5a, count: 4 * 1024 * 1024).write(to: color)
        try Data(repeating: 0xa5, count: 4 * 1024 * 1024).write(to: alpha)
        let pair = VideoSourcePair(colorURL: color, alphaURL: alpha, alphaSourceMode: .external)
        let counter = HashObserverCounter()

        try HighPrecisionCacheHelper.withContentHashObserver({ counter.record($0) }) {
            let context = HighPrecisionCacheHelper.makeCacheContext(for: pair, preserveAlpha: true)
            try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
            try Data().write(to: context.movieURL)
            try Data("{}".utf8).write(to: context.metadataURL)
            try Data().write(to: context.alphaSidecarURL)
            #expect(HighPrecisionCacheHelper.cacheDirectory(for: pair) == context.directory)
            #expect(HighPrecisionCacheHelper.cacheMovieURL(for: pair, preserveAlpha: true) == context.movieURL)
            #expect(HighPrecisionCacheHelper.hasCache(for: pair, preserveAlpha: true))
            HighPrecisionCacheHelper.removeCache(for: pair)
        }
        #expect(counter.value == 0)
    }

    @Test func zeroNominalFPSAndHighFrameCountVFRUseActualPTSDepth() throws {
        var pts: [Double] = []
        pts.reserveCapacity(240)
        var time = 0.0
        for index in 0..<240 {
            pts.append(time)
            time += index.isMultiple(of: 3) ? 1.0 / 240.0 : 1.0 / 120.0
        }
        let probe = HighPrecisionCacheHelper.FrameDepthProbeResult(
            presentationTimes: pts,
            reliableFrameCount: nil,
            nominalFrameRate: 0,
            durationSeconds: time
        )
        let depth = try #require(HighPrecisionCacheHelper.resolvedFrameDepthForMemoryBudget(probe))
        #expect(depth == 240)
        let estimate = try HighPrecisionCacheHelper.makePairedVolumeMemoryEstimate(
            width: 64,
            height: 64,
            depth: depth,
            budgetBytes: UInt64.max
        )
        #expect(estimate.depth == 240)
        #expect(estimate.estimatedPeakBytes == UInt64(64 * 64 * 240 * 24))

        let noReliableCount = HighPrecisionCacheHelper.FrameDepthProbeResult(
            presentationTimes: [],
            reliableFrameCount: nil,
            nominalFrameRate: 120,
            durationSeconds: 2
        )
        #expect(HighPrecisionCacheHelper.resolvedFrameDepthForMemoryBudget(noReliableCount) == nil)
    }

    @Test func decodedDepthAbovePreflightEstimateIsRejectedBeforeCPUVolume() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preflight = try HighPrecisionCacheHelper.makePairedVolumeMemoryEstimate(
            width: 16,
            height: 16,
            depth: 1,
            budgetBytes: UInt64(16 * 16 * 24 * 2)
        )
        var rejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.prepareSourceResolutionPairedVolume(
                for: fixture.pair,
                validatedEstimate: preflight
            )
        } catch {
            rejection = error.localizedDescription
        }
        #expect(rejection.contains("colorFrameAccumulation"))
        #expect(rejection.contains("数组扩容/体数据打包前拒绝"))
    }

    @Test func lowLoaderBudgetRejectsBeforeFullTemporalVolumeAllocation() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let stages = AllocationStageCounter()
        let budget = VideoVolumeMemoryBudget(
            maxPeakBytes: UInt64(16 * 16 * 24),
            allocationObserver: { stages.record($0) }
        )
        var rejection = ""
        do {
            _ = try await VideoVolumeLoader.load(
                colorURL: fixture.color,
                alphaURL: fixture.alpha,
                settings: fixture.pair.externalAlphaSettings,
                maxWidth: 16,
                maxHeight: 16,
                previewMaxDepth: Int.max,
                memoryBudget: budget
            )
        } catch {
            rejection = error.localizedDescription
        }
        #expect(rejection.contains("colorFrameAccumulation"))
        #expect(!stages.contains(.fullTemporalVolumeAllocated))
    }

    @Test func workerUsesSharedPreallocationBudgetProtection() throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let output = fixture.directory.appendingPathComponent("worker-low-budget", isDirectory: true)
        let job = DistributedJobManifest(
            jobID: UUID(), sourceFileName: fixture.color.lastPathComponent,
            sourceFileHash: Self.sha256(fixture.color),
            alphaSourceFileName: fixture.alpha.lastPathComponent,
            alphaSourceFileHash: Self.sha256(fixture.alpha), alphaSourceMode: .external,
            externalAlphaSettings: fixture.pair.externalAlphaSettings,
            sourceColorBitDepth: 8, sourceAlphaBitDepth: 8, outputBitDepth: 8,
            sourceWidth: 16, sourceHeight: 16, sourceFrameCount: 4, fps: 2,
            mode: .axis, axis: .x, referencePlane: ReferencePlaneState(), preserveAlpha: true,
            padToEven: true, qualityScale: 1, outputWidth: 4, outputHeight: 16,
            totalOutputFrames: 1, outputStartFrame: 0, outputEndFrame: 0,
            codec: "ap4h", colorProfile: .rec709, createdAtISO8601: "test"
        )
        var rejection = ""
        do {
            _ = try WorkerJobExecutor(
                pairedVolumeMemoryBudgetBytes: UInt64(16 * 16 * 24)
            ).execute(
                request: StartDistributedJobRequest(
                    job: job,
                    localSourcePath: fixture.color.path,
                    outputDirectory: output.path,
                    preparedRawCachePath: nil,
                    localAlphaSourcePath: fixture.alpha.path
                ),
                progress: { _, _ in }
            )
        } catch {
            rejection = error.localizedDescription
        }
        #expect(rejection.contains("内存"))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func lowBudgetCacheBuildRejectsBeforeHighPrecisionSamplesAllocation() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer {
            HighPrecisionCacheHelper.removeCache(for: fixture.pair)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let stages = AllocationStageCounter()
        let budget = VideoVolumeMemoryBudget(
            maxPeakBytes: UInt64(16 * 16 * 24),
            allocationObserver: { stages.record($0) }
        )
        var rejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.buildCache(
                from: fixture.pair,
                preserveAlpha: true,
                highPrecisionAlpha: nil,
                memoryBudget: budget,
                progress: { _, _ in }
            )
        } catch {
            rejection = error.localizedDescription
        }
        #expect(rejection.contains("内存"))
        #expect(!stages.contains(.highPrecisionAlphaSamplesAllocated))
        #expect(!FileManager.default.fileExists(
            atPath: HighPrecisionCacheHelper.cacheAlphaSidecarURL(for: fixture.pair).path
        ))
    }

    @Test func overBudgetSidecarRejectsBeforeMappingAndUInt16Allocation() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer {
            HighPrecisionCacheHelper.removeCache(for: fixture.pair)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        _ = try await HighPrecisionCacheHelper.buildCache(
            from: fixture.pair,
            preserveAlpha: true,
            highPrecisionAlpha: nil,
            progress: { _, _ in }
        )
        let stages = AllocationStageCounter()
        let budget = VideoVolumeMemoryBudget(
            maxPeakBytes: UInt64(16 * 16 * 24),
            allocationObserver: { stages.record($0) }
        )
        var rejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.loadAlphaSidecar(
                for: fixture.pair,
                memoryBudget: budget
            )
        } catch {
            rejection = error.localizedDescription
        }
        #expect(rejection.contains("内存"))
        #expect(!stages.contains(.alphaSidecarDataMapped))
        #expect(!stages.contains(.alphaSidecarSamplesAllocated))
    }

    @Test func maliciousHugeSidecarMetadataRejectsOverflowWithoutAllocation() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer {
            HighPrecisionCacheHelper.removeCache(for: fixture.pair)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        _ = try await HighPrecisionCacheHelper.buildCache(
            from: fixture.pair,
            preserveAlpha: true,
            highPrecisionAlpha: nil,
            progress: { _, _ in }
        )
        var metadata = try HighPrecisionCacheHelper.loadMetadata(for: fixture.pair, preserveAlpha: true)
        metadata.alphaSidecarWidth = Int.max
        metadata.alphaSidecarHeight = 2
        metadata.alphaSidecarDepth = 2
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(
            to: HighPrecisionCacheHelper.cacheMetadataURL(for: fixture.pair, preserveAlpha: true),
            options: .atomic
        )

        let stages = AllocationStageCounter()
        let budget = VideoVolumeMemoryBudget(
            maxPeakBytes: UInt64.max,
            allocationObserver: { stages.record($0) }
        )
        var rejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.loadAlphaSidecar(
                for: fixture.pair,
                memoryBudget: budget
            )
        } catch {
            rejection = error.localizedDescription
        }
        #expect(rejection.contains("乘法溢出"))
        #expect(!stages.contains(.alphaSidecarDataMapped))
        #expect(!stages.contains(.alphaSidecarSamplesAllocated))
    }

    @Test func opaqueCacheExportValidationRejectsChangedColorWithStableStat() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        let pair = VideoSourcePair(colorURL: fixture.color, alphaURL: nil, alphaSourceMode: .opaque)
        defer {
            HighPrecisionCacheHelper.removeCache(for: pair)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        _ = try await HighPrecisionCacheHelper.buildCache(
            from: pair,
            preserveAlpha: false,
            highPrecisionAlpha: nil,
            progress: { _, _ in }
        )
        let validURL = try await HighPrecisionCacheHelper.validatedCacheURL(for: pair, preserveAlpha: false)
        #expect(validURL == HighPrecisionCacheHelper.cacheMovieURL(for: pair, preserveAlpha: false))
        try Self.mutateFilePreservingSizeAndMTime(fixture.color)
        #expect(HighPrecisionCacheHelper.hasCache(for: pair, preserveAlpha: false))
        var rejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.validatedCacheURL(for: pair, preserveAlpha: false)
        } catch {
            rejection = error.localizedDescription
        }
        #expect(rejection.contains("内容哈希已变化"))
    }

    @Test func loadedPairedVolumeIsRevalidatedBeforeExportAfterSourceChange() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer {
            HighPrecisionCacheHelper.removeCache(for: fixture.pair)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        _ = try await HighPrecisionCacheHelper.buildCache(
            from: fixture.pair,
            preserveAlpha: true,
            highPrecisionAlpha: nil,
            progress: { _, _ in }
        )
        let loaded = try await HighPrecisionCacheHelper.loadMergedSourceCPUVolume(for: fixture.pair)
        #expect(loaded.depth == 4)
        try Self.mutateFilePreservingSizeAndMTime(fixture.alpha)
        var rejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.validatedCacheURL(for: fixture.pair, preserveAlpha: true)
        } catch {
            rejection = error.localizedDescription
        }
        #expect(rejection.contains("内容哈希已变化"))
    }

    @Test func pairedOutputBitDepthPolicyIsIdenticalForHostAndWorker() {
        #expect(ExternalPairedRenderPolicy.rejectionReason(
            sourceColorBitDepth: 8, sourceAlphaBitDepth: 8, outputBitDepth: 8
        ) == nil)
        #expect(ExternalPairedRenderPolicy.rejectionReason(
            sourceColorBitDepth: 10, sourceAlphaBitDepth: 8, outputBitDepth: 8
        ) != nil)
        #expect(ExternalPairedRenderPolicy.rejectionReason(
            sourceColorBitDepth: 8, sourceAlphaBitDepth: 10, outputBitDepth: 8
        ) != nil)
        #expect(ExternalPairedRenderPolicy.rejectionReason(
            sourceColorBitDepth: 8, sourceAlphaBitDepth: 8, outputBitDepth: 10
        ) != nil)
    }

    @Test func parallelSameNamedPairCachesStayIsolated() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let first = try Self.makePairedFixture(ffmpeg: ffmpeg, alphaValues: [0, 64, 128, 255], alphaPixelFormat: "gray")
        let second = try Self.makePairedFixture(ffmpeg: ffmpeg, alphaValues: [255, 128, 64, 0], alphaPixelFormat: "gray")
        defer {
            HighPrecisionCacheHelper.removeCache(for: first.pair)
            HighPrecisionCacheHelper.removeCache(for: second.pair)
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }
        async let firstBuild = HighPrecisionCacheHelper.buildCache(
            from: first.pair, preserveAlpha: true, highPrecisionAlpha: nil
        ) { _, _ in }
        async let secondBuild = HighPrecisionCacheHelper.buildCache(
            from: second.pair, preserveAlpha: true, highPrecisionAlpha: nil
        ) { _, _ in }
        let (firstMovie, secondMovie) = try await (firstBuild, secondBuild)
        let firstContext = HighPrecisionCacheHelper.makeCacheContext(for: first.pair, preserveAlpha: true)
        let secondContext = HighPrecisionCacheHelper.makeCacheContext(for: second.pair, preserveAlpha: true)
        #expect(firstContext.key != secondContext.key)
        #expect(firstContext.directory != secondContext.directory)
        #expect(firstMovie == firstContext.movieURL)
        #expect(secondMovie == secondContext.movieURL)
        #expect(FileManager.default.fileExists(atPath: firstContext.alphaSidecarURL.path))
        #expect(FileManager.default.fileExists(atPath: secondContext.alphaSidecarURL.path))
        #expect(try await HighPrecisionCacheHelper.loadAlphaSidecar(for: first.pair).samples.first == 0)
        #expect(try await HighPrecisionCacheHelper.loadAlphaSidecar(for: second.pair).samples.first == 65535)
    }

    @Test func sourceHashChangeInvalidatesCacheEvenWithSamePathSizeAndMTime() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(ffmpeg: ffmpeg, alphaValues: [0, 64, 128, 255], alphaPixelFormat: "gray")
        defer {
            HighPrecisionCacheHelper.removeCache(for: fixture.pair)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        _ = try await HighPrecisionCacheHelper.buildCache(
            from: fixture.pair, preserveAlpha: true, highPrecisionAlpha: nil
        ) { _, _ in }
        let oldKey = HighPrecisionCacheHelper.cacheKey(for: fixture.pair)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.alpha.path)
        let oldDate = try #require(attributes[.modificationDate] as? Date)
        var bytes = try Data(contentsOf: fixture.alpha)
        let mutationIndex = max(32, bytes.count - 17)
        bytes[mutationIndex] ^= 0x01
        try bytes.write(to: fixture.alpha)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fixture.alpha.path)
        #expect(HighPrecisionCacheHelper.cacheKey(for: fixture.pair) == oldKey)
        var rejected = false
        do {
            _ = try await HighPrecisionCacheHelper.loadAlphaSidecar(for: fixture.pair)
        } catch {
            rejected = error.localizedDescription.contains("哈希已变化")
        }
        #expect(rejected)
        // MainActor/UI presence queries intentionally do not hash multi-GB sources.
        // The asynchronous load operation above remains the authoritative validation.
        #expect(HighPrecisionCacheHelper.hasCache(for: fixture.pair, preserveAlpha: true))
    }

    @Test func ffv1Gray16MKVFallbackAndSingleFileRegression() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChronoVolumeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let colorURL = directory.appendingPathComponent("sample_A_color.mov")
        let alphaRawURL = directory.appendingPathComponent("alpha.raw")
        let alphaURL = directory.appendingPathComponent("sample_B_alpha.mkv")

        try Self.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "color=c=red:s=2x2:r=2:d=2", "-c:v", "prores_ks", "-profile:v", "3", colorURL.path])
        var raw = Data()
        for value: UInt16 in [0, 1, 32768, 65535] {
            for _ in 0..<4 {
                var little = value.littleEndian
                raw.append(Data(bytes: &little, count: 2))
            }
        }
        try raw.write(to: alphaRawURL)
        try Self.run(ffmpeg, ["-y", "-f", "rawvideo", "-pixel_format", "gray16le", "-video_size", "2x2", "-framerate", "2", "-i", alphaRawURL.path, "-c:v", "ffv1", "-level", "3", alphaURL.path])

        let single = try await VideoVolumeLoader.load(url: colorURL, maxWidth: 16, maxHeight: 16, previewMaxDepth: 16)
        #expect(single.sourceFrameCount == 4)

        var compatibility = ExternalAlphaSettings()
        compatibility.syncPolicy = .resampleToColorTimeline
        let dual = try await VideoVolumeLoader.load(
            colorURL: colorURL,
            alphaURL: alphaURL,
            settings: compatibility,
            maxWidth: 16,
            maxHeight: 16,
            previewMaxDepth: 16
        )
        #expect(dual.sourceAlphaBitDepth == 16)
        #expect(dual.alphaMetadata?.codec == "ffv1")
        #expect(dual.highPrecisionAlphaVolume?.samples[8] == 32768)
        #expect(dual.fullTemporalVolume.rgba[3] == 0)
        #expect(dual.fullTemporalVolume.rgba[0] > 0)
    }

    @Test func strictMOVPlusFFV1MKVPassesWithDifferentTimeBases() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(ffmpeg: ffmpeg, alphaValues: [0, 64, 128, 255], alphaPixelFormat: "gray")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let package = try await VideoVolumeLoader.load(
            colorURL: fixture.color,
            alphaURL: fixture.alpha,
            settings: ExternalAlphaSettings(),
            maxWidth: 16,
            maxHeight: 16,
            previewMaxDepth: 16
        )
        #expect(package.alphaSyncStatus.contains("严格 PTS 对齐通过"))
        #expect(package.fullTemporalVolume.depth == 4)
    }

    @Test func workerAxisSegmentActuallyContainsExternalAlpha() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(ffmpeg: ffmpeg, alphaValues: [0, 64, 128, 255], alphaPixelFormat: "gray")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let output = fixture.directory.appendingPathComponent("worker-output", isDirectory: true)
        let settings = ExternalAlphaSettings()
        let job = DistributedJobManifest(
            jobID: UUID(), sourceFileName: fixture.color.lastPathComponent,
            sourceFileHash: Self.sha256(fixture.color),
            alphaSourceFileName: fixture.alpha.lastPathComponent,
            alphaSourceFileHash: Self.sha256(fixture.alpha), alphaSourceMode: .external,
            externalAlphaSettings: settings, sourceColorBitDepth: 8, sourceAlphaBitDepth: 8, outputBitDepth: 8,
            sourceWidth: 16, sourceHeight: 16, sourceFrameCount: 4, fps: 2,
            mode: .axis, axis: .x, referencePlane: ReferencePlaneState(), preserveAlpha: true,
            padToEven: true, qualityScale: 1, outputWidth: 4, outputHeight: 16,
            totalOutputFrames: 2, outputStartFrame: 0, outputEndFrame: 0,
            codec: "ap4h", colorProfile: .rec709, createdAtISO8601: "test"
        )
        let result = try WorkerJobExecutor().execute(
            request: StartDistributedJobRequest(
                job: job, localSourcePath: fixture.color.path,
                outputDirectory: output.path, preparedRawCachePath: nil,
                localAlphaSourcePath: fixture.alpha.path
            ),
            progress: { _, _ in }
        )
        let frame = try Self.readFirstBGRAFrame(result.segmentURL)
        #expect(frame.width == 4)
        let alpha = (0..<4).map { frame.bytes[$0 * 4 + 3] }
        #expect(abs(Int(alpha[0]) - 0) <= 1)
        #expect(abs(Int(alpha[1]) - 64) <= 1)
        #expect(abs(Int(alpha[2]) - 128) <= 1)
        #expect(abs(Int(alpha[3]) - 255) <= 1)

        func workerJob(mode: SliceMode, axis: DistributedAxis, endFrame: Int) -> DistributedJobManifest {
            DistributedJobManifest(
                jobID: UUID(), sourceFileName: fixture.color.lastPathComponent,
                sourceFileHash: Self.sha256(fixture.color),
                alphaSourceFileName: fixture.alpha.lastPathComponent,
                alphaSourceFileHash: Self.sha256(fixture.alpha), alphaSourceMode: .external,
                externalAlphaSettings: settings, sourceColorBitDepth: 8, sourceAlphaBitDepth: 8, outputBitDepth: 8,
                sourceWidth: 16, sourceHeight: 16, sourceFrameCount: 4, fps: 2,
                mode: mode, axis: axis, referencePlane: ReferencePlaneState(), preserveAlpha: true,
                padToEven: true, qualityScale: 1, outputWidth: 16, outputHeight: 16,
                totalOutputFrames: endFrame + 1, outputStartFrame: 0, outputEndFrame: endFrame,
                codec: "ap4h", colorProfile: .rec709, createdAtISO8601: "test"
            )
        }
        let yResult = try WorkerJobExecutor().execute(
            request: StartDistributedJobRequest(
                job: workerJob(mode: .axis, axis: .y, endFrame: 0),
                localSourcePath: fixture.color.path, outputDirectory: output.path,
                preparedRawCachePath: nil, localAlphaSourcePath: fixture.alpha.path
            ), progress: { _, _ in }
        )
        let yFrame = try Self.readFirstBGRAFrame(yResult.segmentURL)
        let yAlpha = stride(from: 3, to: yFrame.bytes.count, by: 4).map { yFrame.bytes[$0] }
        for expected in [0, 64, 128, 255] {
            #expect(yAlpha.contains { abs(Int($0) - expected) <= 1 })
        }

        let planeResult = try WorkerJobExecutor().execute(
            request: StartDistributedJobRequest(
                job: workerJob(mode: .plane, axis: .x, endFrame: 3),
                localSourcePath: fixture.color.path, outputDirectory: output.path,
                preparedRawCachePath: nil, localAlphaSourcePath: fixture.alpha.path
            ), progress: { _, _ in }
        )
        let planeAlpha = try Self.readFirstPixelAlphas(planeResult.segmentURL)
        #expect(planeAlpha.count == 4)
        for (actual, expected) in zip(planeAlpha, [0, 64, 128, 255]) {
            #expect(abs(Int(actual) - expected) <= 1)
        }
    }

    @Test func wideSourceHostWorkerSegmentsMatchAndStitchWithoutAlphaDrift() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray",
            size: "1030x2"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let prepared = try await HighPrecisionCacheHelper.prepareSourceResolutionPairedVolume(for: fixture.pair)
        #expect(prepared.volume.width == 1030)
        #expect(prepared.volume.height == 2)
        #expect(prepared.volume.depth == 4)
        #expect(prepared.volume.presentationTimes.count == 4)

        let outputDirectory = fixture.directory.appendingPathComponent("wide-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let hostURL = outputDirectory.appendingPathComponent("host.mov")
        try VideoExportHelper.exportHighPrecisionDistributedSegment(
            outputURL: hostURL,
            sourceURL: fixture.color,
            mode: .plane,
            axis: .x,
            referencePlane: ReferencePlaneState(),
            sourceWidth: prepared.volume.width,
            sourceHeight: prepared.volume.height,
            sourceFrameCount: prepared.volume.depth,
            fps: 2,
            preserveAlpha: true,
            padToEven: true,
            outputStartFrame: 0,
            outputEndFrame: 1,
            preparedCPUVolume: prepared.volume,
            bitDepth: 8,
            progress: { _, _ in }
        )

        let geometry = prepared.volume.planeGeometry(for: ReferencePlaneState())
        let expectedWidth = geometry.outWidth.isMultiple(of: 2) ? geometry.outWidth : geometry.outWidth + 1
        let expectedHeight = geometry.outHeight.isMultiple(of: 2) ? geometry.outHeight : geometry.outHeight + 1
        let settings = fixture.pair.externalAlphaSettings
        let job = DistributedJobManifest(
            jobID: UUID(),
            sourceFileName: fixture.color.lastPathComponent,
            sourceFileHash: Self.sha256(fixture.color),
            alphaSourceFileName: fixture.alpha.lastPathComponent,
            alphaSourceFileHash: Self.sha256(fixture.alpha),
            alphaSourceMode: .external,
            externalAlphaSettings: settings,
            sourceColorBitDepth: 8,
            sourceAlphaBitDepth: 8,
            outputBitDepth: 8,
            sourcePresentationTimes: prepared.volume.presentationTimes,
            alphaAssociation: .straight,
            sourceWidth: 1030,
            sourceHeight: 2,
            sourceFrameCount: 4,
            fps: 2,
            mode: .plane,
            axis: .x,
            referencePlane: ReferencePlaneState(),
            preserveAlpha: true,
            padToEven: true,
            qualityScale: 1,
            outputWidth: expectedWidth,
            outputHeight: expectedHeight,
            totalOutputFrames: 4,
            outputStartFrame: 2,
            outputEndFrame: 3,
            codec: "ap4h",
            colorProfile: .rec709,
            createdAtISO8601: "test"
        )
        let workerResult = try WorkerJobExecutor().execute(
            request: StartDistributedJobRequest(
                job: job,
                localSourcePath: fixture.color.path,
                outputDirectory: outputDirectory.path,
                preparedRawCachePath: nil,
                localAlphaSourcePath: fixture.alpha.path
            ),
            progress: { _, _ in }
        )

        let hostProperties = try await Self.videoProperties(hostURL)
        let workerProperties = try await Self.videoProperties(workerResult.segmentURL)
        #expect(hostProperties.codec == "ap4h")
        #expect(workerProperties.codec == "ap4h")
        #expect(hostProperties.width == workerProperties.width)
        #expect(hostProperties.height == workerProperties.height)
        #expect(hostProperties.width == expectedWidth)
        #expect(hostProperties.height == expectedHeight)
        #expect(hostProperties.frameCount == 2)
        #expect(workerProperties.frameCount == 2)
        #expect(hostProperties.fps == 2)
        #expect(workerProperties.fps == 2)
        #expect(workerResult.metadata.outputStartFrame == 2)
        #expect(workerResult.metadata.outputEndFrame == 3)
        #expect(workerResult.metadata.outputBitDepth == 8)
        #expect(workerResult.metadata.alphaAssociation == .straight)
        #expect(job.externalAlphaSettings?.association == .straight)

        #expect(try Self.readFirstPixelAlphas(hostURL) == [0, 64])
        #expect(try Self.readFirstPixelAlphas(workerResult.segmentURL) == [128, 255])
        let stitchedURL = outputDirectory.appendingPathComponent("stitched.mov")
        try await SegmentStitcher.stitch(
            segmentURLs: [hostURL, workerResult.segmentURL],
            outputURL: stitchedURL
        )
        let stitchedProperties = try await Self.videoProperties(stitchedURL)
        #expect(stitchedProperties.frameCount == 4)
        #expect(stitchedProperties.width == expectedWidth)
        #expect(stitchedProperties.height == expectedHeight)
        #expect(try Self.readFirstPixelAlphas(stitchedURL) == [0, 64, 128, 255])
    }

    @Test func realYUVLimitedLumaAndRGBFullChannelExtraction() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChronoVolumeRange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let color = directory.appendingPathComponent("A.mov")
        try Self.run(ffmpeg, ["-y", "-f", "lavfi", "-i", "color=c=white:s=2x2:r=1:d=1", "-c:v", "prores_ks", "-profile:v", "3", color.path])

        let yuvRaw = directory.appendingPathComponent("limited.yuv")
        try Data([16, 64, 128, 235, 128, 128]).write(to: yuvRaw)
        let yuv = directory.appendingPathComponent("limited.mkv")
        try Self.run(ffmpeg, ["-y", "-f", "rawvideo", "-pixel_format", "yuv420p", "-video_size", "2x2", "-framerate", "1", "-i", yuvRaw.path, "-frames:v", "1", "-c:v", "ffv1", "-color_range", "tv", yuv.path])
        var yuvSettings = ExternalAlphaSettings()
        yuvSettings.range = .limited
        yuvSettings.syncPolicy = .resampleToColorTimeline
        let limited = try await VideoVolumeLoader.load(colorURL: color, alphaURL: yuv, settings: yuvSettings, maxWidth: 8, maxHeight: 8, previewMaxDepth: 8)
        let limitedAlpha = stride(from: 3, to: 16, by: 4).map { limited.fullTemporalVolume.rgba[$0] }.sorted()
        #expect(abs(Int(limitedAlpha[0]) - 0) <= 1)
        #expect(abs(Int(limitedAlpha[1]) - 56) <= 2)
        #expect(abs(Int(limitedAlpha[2]) - 130) <= 2)
        #expect(abs(Int(limitedAlpha[3]) - 255) <= 1)

        let rgbRaw = directory.appendingPathComponent("rgb.raw")
        try Data([10,20,30, 40,50,60, 70,80,90, 100,110,120]).write(to: rgbRaw)
        let rgb = directory.appendingPathComponent("rgb.mkv")
        try Self.run(ffmpeg, ["-y", "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", "2x2", "-framerate", "1", "-i", rgbRaw.path, "-frames:v", "1", "-c:v", "ffv1", "-pix_fmt", "bgr0", "-color_range", "pc", rgb.path])
        var rgbSettings = ExternalAlphaSettings()
        rgbSettings.channel = .red
        rgbSettings.range = .auto
        rgbSettings.syncPolicy = .resampleToColorTimeline
        let full = try await VideoVolumeLoader.load(colorURL: color, alphaURL: rgb, settings: rgbSettings, maxWidth: 8, maxHeight: 8, previewMaxDepth: 8)
        let red = stride(from: 3, to: 16, by: 4).map { full.fullTemporalVolume.rgba[$0] }.sorted()
        #expect(zip(red, [10, 40, 70, 100]).allSatisfy { abs(Int($0.0) - $0.1) <= 3 })
    }

    @Test func highPrecisionSidecarUsesSourceDimensionsAndIsConsumed() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(ffmpeg: ffmpeg, alphaValues: [0, 64, 128, 255], alphaPixelFormat: "gray", size: "12x8")
        defer {
            HighPrecisionCacheHelper.removeCache(for: fixture.pair)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        _ = try await HighPrecisionCacheHelper.buildCache(from: fixture.pair, preserveAlpha: true, highPrecisionAlpha: nil) { _, _ in }
        let metadata = try HighPrecisionCacheHelper.loadMetadata(for: fixture.pair, preserveAlpha: true)
        #expect(metadata.alphaSidecarWidth == 12)
        #expect(metadata.alphaSidecarHeight == 8)
        #expect(metadata.alphaSidecarDepth == 4)
        #expect(metadata.alphaSampleFormat == "uint16_normalized")
        #expect(metadata.alphaEndianness == "little")
        #expect(metadata.alphaPresentationTimes?.count == 4)
        #expect(metadata.alphaSidecarSHA256 != nil)
        let merged = try await HighPrecisionCacheHelper.loadMergedSourceCPUVolume(for: fixture.pair)
        #expect(merged.width == 12 && merged.height == 8 && merged.depth == 4)
        #expect(merged.rgba[3] == 0)
        #expect(merged.rgba[(3 * 12 * 8) * 4 + 3] == 255)
    }

    @Test func missingSidecarSHA256MetadataIsRejected() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer {
            HighPrecisionCacheHelper.removeCache(for: fixture.pair)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        _ = try await HighPrecisionCacheHelper.buildCache(
            from: fixture.pair,
            preserveAlpha: true,
            highPrecisionAlpha: nil,
            progress: { _, _ in }
        )
        var metadata = try HighPrecisionCacheHelper.loadMetadata(for: fixture.pair, preserveAlpha: true)
        metadata.alphaSidecarSHA256 = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(
            to: HighPrecisionCacheHelper.cacheMetadataURL(for: fixture.pair, preserveAlpha: true),
            options: .atomic
        )

        var loadRejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.loadAlphaSidecar(for: fixture.pair)
        } catch {
            loadRejection = error.localizedDescription
        }
        var cacheRejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.validatedCacheURL(
                for: fixture.pair,
                preserveAlpha: true
            )
        } catch {
            cacheRejection = error.localizedDescription
        }
        #expect(loadRejection.contains("缺少 sidecar SHA-256"))
        #expect(loadRejection.contains("重新建立缓存"))
        #expect(cacheRejection.contains("缺少 sidecar SHA-256"))
        #expect(cacheRejection.contains("重新建立缓存"))
    }

    @Test func sidecarHashGenerationFailureLeavesNoUsableCache() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        let context = HighPrecisionCacheHelper.makeCacheContext(for: fixture.pair, preserveAlpha: true)
        defer {
            HighPrecisionCacheHelper.removeCache(for: fixture.pair)
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        var rejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.buildCache(
                from: fixture.pair,
                preserveAlpha: true,
                highPrecisionAlpha: nil,
                sidecarHashProvider: { _ in nil },
                progress: { _, _ in }
            )
        } catch {
            rejection = error.localizedDescription
        }
        #expect(rejection.contains("Alpha sidecar SHA-256"))
        #expect(!HighPrecisionCacheHelper.hasCache(for: fixture.pair, preserveAlpha: true))
        #expect(!FileManager.default.fileExists(atPath: context.directory.path))
        #expect(!FileManager.default.fileExists(atPath: context.metadataURL.path))
        #expect(!FileManager.default.fileExists(atPath: context.alphaSidecarURL.path))
    }

    @Test func sameSizeSidecarMutationFailsValidationAndLoading() async throws {
        guard let ffmpeg = Self.executable("ffmpeg") else { return }
        let fixture = try Self.makePairedFixture(
            ffmpeg: ffmpeg,
            alphaValues: [0, 64, 128, 255],
            alphaPixelFormat: "gray"
        )
        defer {
            HighPrecisionCacheHelper.removeCache(for: fixture.pair)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        _ = try await HighPrecisionCacheHelper.buildCache(
            from: fixture.pair,
            preserveAlpha: true,
            highPrecisionAlpha: nil,
            progress: { _, _ in }
        )
        let sidecarURL = HighPrecisionCacheHelper.cacheAlphaSidecarURL(for: fixture.pair)
        let sizeBefore = try #require(
            (try FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size] as? NSNumber)?.uint64Value
        )
        try Self.mutateFilePreservingSizeAndMTime(sidecarURL)
        let sizeAfter = try #require(
            (try FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.size] as? NSNumber)?.uint64Value
        )
        #expect(sizeAfter == sizeBefore)

        var cacheRejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.validatedCacheURL(
                for: fixture.pair,
                preserveAlpha: true
            )
        } catch {
            cacheRejection = error.localizedDescription
        }
        var loadRejection = ""
        do {
            _ = try await HighPrecisionCacheHelper.loadAlphaSidecar(for: fixture.pair)
        } catch {
            loadRejection = error.localizedDescription
        }
        #expect(cacheRejection.contains("Alpha sidecar SHA-256 校验失败"))
        #expect(loadRejection.contains("Alpha sidecar SHA-256 校验失败"))
    }

    private static func makePairedFixture(
        ffmpeg: URL,
        alphaValues: [UInt8],
        alphaPixelFormat: String,
        size: String = "16x16"
    ) throws -> (directory: URL, color: URL, alpha: URL, pair: VideoSourcePair) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChronoVolumePair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let color = directory.appendingPathComponent("A.mov")
        let colorRaw = directory.appendingPathComponent("A.rgb")
        let alphaRaw = directory.appendingPathComponent("B.raw")
        let alpha = directory.appendingPathComponent("B.mkv")
        let dimensions = size.split(separator: "x").compactMap { Int($0) }
        let pixelCount = dimensions[0] * dimensions[1]
        var colorBytes = Data()
        for _ in alphaValues {
            for _ in 0..<pixelCount { colorBytes.append(contentsOf: [255, 0, 0]) }
        }
        try colorBytes.write(to: colorRaw)
        try run(ffmpeg, [
            "-y", "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", size,
            "-framerate", "2", "-i", colorRaw.path, "-frames:v", "\(alphaValues.count)",
            "-c:v", "prores_ks", "-profile:v", "3", "-video_track_timescale", "600", color.path
        ])
        var raw = Data()
        for value in alphaValues {
            raw.append(contentsOf: repeatElement(value, count: pixelCount))
        }
        try raw.write(to: alphaRaw)
        try run(ffmpeg, ["-y", "-f", "rawvideo", "-pixel_format", alphaPixelFormat, "-video_size", size, "-framerate", "2", "-i", alphaRaw.path, "-c:v", "ffv1", "-color_range", "pc", alpha.path])
        let pair = VideoSourcePair(colorURL: color, alphaURL: alpha, alphaSourceMode: .external)
        return (directory, color, alpha, pair)
    }

    private static func makeGray16AlphaOnlyFixture(
        ffmpeg: URL,
        alphaValues: [UInt16],
        size: String = "16x16"
    ) throws -> (directory: URL, alpha: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChronoVolumeGray16White-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rawURL = directory.appendingPathComponent("foo_B_alpha.raw")
        let alphaURL = directory.appendingPathComponent("foo_B_alpha.mkv")
        let dimensions = size.split(separator: "x").compactMap { Int($0) }
        let pixelCount = dimensions[0] * dimensions[1]
        var raw = Data()
        for value in alphaValues {
            for _ in 0..<pixelCount {
                raw.append(UInt8(truncatingIfNeeded: value))
                raw.append(UInt8(truncatingIfNeeded: value >> 8))
            }
        }
        try raw.write(to: rawURL)
        try run(ffmpeg, [
            "-y", "-f", "rawvideo", "-pixel_format", "gray16le", "-video_size", size,
            "-framerate", "2", "-i", rawURL.path, "-frames:v", "\(alphaValues.count)",
            "-c:v", "ffv1", "-level", "3", "-color_range", "pc", alphaURL.path
        ])
        return (directory, alphaURL)
    }

    private static func readFirstBGRAFrame(_ url: URL) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "ChronoVolumeTests", code: 20)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        reader.add(output)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw NSError(domain: "ChronoVolumeTests", code: 21)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw NSError(domain: "ChronoVolumeTests", code: 22)
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            bytes.replaceSubrange((y * width * 4)..<((y + 1) * width * 4), with: UnsafeBufferPointer(start: base.advanced(by: y * rowBytes), count: width * 4))
        }
        return (width, height, bytes)
    }

    private static func readFirstPixelAlphas(_ url: URL) throws -> [UInt8] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "ChronoVolumeTests", code: 23)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        reader.add(output)
        guard reader.startReading() else { throw NSError(domain: "ChronoVolumeTests", code: 24) }
        var result: [UInt8] = []
        while let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) {
                result.append(base[3])
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        return result
    }

    private static func videoProperties(
        _ url: URL
    ) async throws -> (codec: String, width: Int, height: Int, fps: Double, frameCount: Int) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = size.applying(transform)
        let descriptions = try await track.load(.formatDescriptions)
        let subtype = descriptions.first.map(CMFormatDescriptionGetMediaSubType) ?? 0
        let bytes: [UInt8] = [
            UInt8((subtype >> 24) & 0xff), UInt8((subtype >> 16) & 0xff),
            UInt8((subtype >> 8) & 0xff), UInt8(subtype & 0xff)
        ]
        let codec = String(bytes: bytes, encoding: .ascii) ?? ""
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        reader.add(output)
        guard reader.startReading() else { throw NSError(domain: "ChronoVolumeTests", code: 25) }
        var frameCount = 0
        var presentationTimes: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            frameCount += 1
            presentationTimes.append(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        let fps: Double
        if presentationTimes.count > 1 {
            let deltas = zip(presentationTimes.dropFirst(), presentationTimes).map(-).sorted()
            fps = 1.0 / deltas[deltas.count / 2]
        } else {
            fps = Double(try await track.load(.nominalFrameRate))
        }
        return (
            codec,
            max(1, Int(abs(transformed.width).rounded())),
            max(1, Int(abs(transformed.height).rounded())),
            fps,
            frameCount
        )
    }

    private static func sha256(_ url: URL) -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func mutateFilePreservingSizeAndMTime(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let oldDate = try #require(attributes[.modificationDate] as? Date)
        var bytes = try Data(contentsOf: url)
        let index = max(32, bytes.count - 17)
        bytes[index] ^= 0x01
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
    }

    private static func metadata(width: Int, height: Int, rotation: Int) -> VideoSourceMetadata {
        VideoSourceMetadata(
            fileName: "test", container: "mov", codec: "test", width: width, height: height,
            rotationDegrees: rotation, fps: 30, durationSeconds: 1, frameCount: 30,
            startTimeSeconds: 0, timeBase: "1/600", pixelFormat: "gray", bitDepth: 8,
            range: .full, colorPrimaries: "unknown", transfer: "linear", matrix: "identity",
            hasEmbeddedAlpha: false
        )
    }

    private static func executable(_ name: String) -> URL? {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ChronoVolumeTests", code: Int(process.terminationStatus))
        }
    }

}
