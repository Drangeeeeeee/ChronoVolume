//
//  ChronoVolumeTests.swift
//  ChronoVolumeTests
//
//  Created by Muring Sen on 2026/4/8.
//

import Testing
@testable import ChronoVolume

struct ChronoVolumeTests {

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

}
