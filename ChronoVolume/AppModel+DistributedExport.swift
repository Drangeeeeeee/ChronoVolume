import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

private final class DistributedSchedulingAccessoryView: NSView {
    var coordinator: DistributedSchedulingAccessoryCoordinator?
}

private final class DistributedSchedulingPercentField: NSTextField {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if let action {
                NSApp.sendAction(action, to: target, from: self)
            }
            return
        }
        super.keyDown(with: event)
    }
}

private final class DistributedSchedulingAccessoryCoordinator: NSObject {
    let popup: NSPopUpButton
    let manualStack: NSStackView
    let sliders: [NSSlider]
    let fields: [NSTextField]

    init(
        popup: NSPopUpButton,
        manualStack: NSStackView,
        sliders: [NSSlider],
        fields: [NSTextField]
    ) {
        self.popup = popup
        self.manualStack = manualStack
        self.sliders = sliders
        self.fields = fields
        super.init()
        popup.target = self
        popup.action = #selector(modeChanged(_:))
        for slider in sliders {
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
        }
        for field in fields {
            field.target = self
            field.action = #selector(fieldCommitted(_:))
            field.delegate = self
        }
        updateManualVisibility()
        syncFieldsFromSliders()
        updateSliderLimits()
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        updateManualVisibility()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let index = sliders.firstIndex(where: { $0 === sender }) else { return }
        sender.doubleValue = clamped(value: sender.doubleValue, at: index)
        syncFieldsFromSliders()
        updateSliderLimits()
    }

    @objc private func fieldCommitted(_ sender: NSTextField) {
        guard let index = fields.firstIndex(where: { $0 === sender }) else { return }
        let value = Double(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? sliders[index].doubleValue
        sliders[index].doubleValue = clamped(value: value, at: index)
        syncFieldsFromSliders()
        updateSliderLimits()
    }

    var selectedMode: DistributedSchedulingMode {
        DistributedSchedulingMode.allCases.first { $0.rawValue == popup.titleOfSelectedItem } ?? .automaticFixed
    }

    var manualBoundaries: [Double] {
        sliders.enumerated().map { index, slider in
            clamped(value: slider.doubleValue, at: index)
        }
    }

    private func updateManualVisibility() {
        manualStack.isHidden = selectedMode != .manualFixed
    }

    private func syncFieldsFromSliders() {
        for (index, field) in fields.enumerated() {
            field.stringValue = String(format: "%.0f", sliders[index].doubleValue)
        }
    }

    private func updateSliderLimits() {
        for (index, slider) in sliders.enumerated() {
            slider.minValue = 0.0
            slider.maxValue = 100.0
            slider.doubleValue = clamped(value: slider.doubleValue, at: index)
        }
    }

    private func clamped(value: Double, at index: Int) -> Double {
        min(max(value, lowerBound(for: index)), upperBound(for: index))
    }

    private func lowerBound(for index: Int) -> Double {
        index > 0 ? sliders[index - 1].doubleValue : 0.0
    }

    private func upperBound(for index: Int) -> Double {
        index + 1 < sliders.count ? sliders[index + 1].doubleValue : 100.0
    }
}

extension DistributedSchedulingAccessoryCoordinator: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }

        if let field = control as? NSTextField {
            fieldCommitted(field)
        }
        return true
    }
}

@MainActor
extension AppModel {
    private var distributedExportSourceURL: URL? {
        if let asset = player?.currentItem?.asset as? AVURLAsset {
            return asset.url
        }
        return nil
    }

    private var distributedExportCPUVolume: CPUVolume? {
        Mirror(reflecting: self).descendant("fullCPUVolume") as? CPUVolume
    }

    private func chooseDistributedFinalOutputURL(axisText: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存分布式导出结果"
        panel.nameFieldStringValue = "distributed_\(axisText.lowercased())_result.mov"
        panel.allowedContentTypes = [.movie]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func confirmUploadMissingSourceToWorker(fileName: String, targetPath: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Worker 缺少源缓存文件"
        alert.informativeText = "是否由主机把当前源视频发送到 Worker？\n\n文件名：\(fileName)\n目标路径：\(targetPath)"
        alert.addButton(withTitle: "发送并继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func chooseDistributedScheduling(
        totalFrames: Int,
        workers: [DistributedWorkerNode]
    ) -> DistributedSchedulingChoice? {
        let onlineWorkers = workers.filter(\.isOnline)
        let nodeNames = ["本机"] + onlineWorkers.map(\.displayName)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "选择分布式导出策略"
        alert.informativeText = "动态 chunk 会自动抢任务；自动分配会按设备能力固定分段；手动分配可用滑块指定每台机器负责的连续区间。"
        alert.addButton(withTitle: "开始导出")
        alert.addButton(withTitle: "取消")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        DistributedSchedulingMode.allCases.forEach { popup.addItem(withTitle: $0.rawValue) }
        popup.selectItem(withTitle: DistributedSchedulingMode.automaticFixed.rawValue)
        stack.addArrangedSubview(popup)

        let hint = NSTextField(labelWithString: "在线节点：\(nodeNames.joined(separator: " → "))｜总帧数 \(totalFrames)")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        var sliders: [NSSlider] = []
        var fields: [NSTextField] = []
        let manualStack = NSStackView()
        manualStack.orientation = .vertical
        manualStack.alignment = .leading
        manualStack.spacing = 8
        stack.addArrangedSubview(manualStack)

        let boundaryCount = onlineWorkers.count
        if boundaryCount > 0 {
            for boundaryIndex in 0..<boundaryCount {
                let defaultValue = Double(boundaryIndex + 1) * 100.0 / Double(boundaryCount + 1)
                let labelText: String
                if boundaryIndex == 0 {
                    labelText = "边界 \(boundaryIndex + 1)：0% → 此处由本机渲染"
                } else {
                    labelText = "边界 \(boundaryIndex + 1)：上一边界 → 此处由 \(nodeNames[boundaryIndex]) 渲染"
                }
                let label = NSTextField(labelWithString: labelText)
                label.font = .systemFont(ofSize: 12)
                let slider = NSSlider(value: defaultValue, minValue: 0, maxValue: 100, target: nil, action: nil)
                slider.numberOfTickMarks = 11
                slider.allowsTickMarkValuesOnly = false
                slider.widthAnchor.constraint(equalToConstant: 430).isActive = true
                let field = DistributedSchedulingPercentField(string: String(format: "%.0f", defaultValue))
                field.alignment = .right
                field.widthAnchor.constraint(equalToConstant: 40).isActive = true
                let percent = NSTextField(labelWithString: "%")
                let controlRow = NSStackView(views: [slider, field, percent])
                controlRow.orientation = .horizontal
                controlRow.alignment = .centerY
                controlRow.spacing = 4
                let row = NSStackView(views: [label, controlRow])
                row.orientation = .vertical
                row.alignment = .leading
                row.spacing = 2
                manualStack.addArrangedSubview(row)
                sliders.append(slider)
                fields.append(field)
            }
        }

        let container = DistributedSchedulingAccessoryView(frame: NSRect(x: 0, y: 0, width: 560, height: 92 + boundaryCount * 54))
        container.addSubview(stack)
        let coordinator = DistributedSchedulingAccessoryCoordinator(
            popup: popup,
            manualStack: manualStack,
            sliders: sliders,
            fields: fields
        )
        container.coordinator = coordinator
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        return DistributedSchedulingChoice(
            mode: coordinator.selectedMode,
            manualBoundaries: coordinator.manualBoundaries
        )
    }

    nonisolated private static func makeWorkerCacheHint(
        sourceURL: URL,
        checked: (hash: String, response: DistributedSourceCheckResponse),
        message: String? = nil
    ) -> (expectedName: String, expectedFullPath: String, exists: Bool, message: String) {
        let expectedName = checked.hash + "_" + sourceURL.lastPathComponent
        let workerBasePath = checked.response.localPath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        } ?? "(Worker 当前未返回缓存目录)"
        let expectedFullPath = workerBasePath == "(Worker 当前未返回缓存目录)"
            ? expectedName
            : URL(fileURLWithPath: workerBasePath, isDirectory: true)
                .appendingPathComponent(expectedName)
                .path

        return (
            expectedName,
            expectedFullPath,
            checked.response.exists,
            message ?? (checked.response.exists ? "Worker 已找到源缓存文件" : "Worker 缺少源缓存文件")
        )
    }

    nonisolated private static func rawCacheDisplayMessage(_ response: DistributedPrepareSourceResponse) -> String {
        switch response.state {
        case "ready":
            if let imported = response.importedVolumeInfo, !imported.isEmpty {
                return "Worker 已导入视频会话，raw cache 已就绪（\(imported)）"
            }
            return "Worker raw cache 已就绪，正在等待 Worker 会话导入"
        case "running":
            return "Worker 视频导入/缓存正在建立：\(Int(response.progress * 100))%｜\(response.message)"
        case "failed":
            return "Worker 视频导入/缓存建立失败：\(response.error ?? response.message)"
        case "missing":
            return "Worker 尚未导入视频会话"
        default:
            return response.message
        }
    }

    nonisolated private static func combinedWorkerCacheMessage(
        sourceExists: Bool,
        rawResponse: DistributedPrepareSourceResponse?
    ) -> String {
        guard sourceExists else {
            return "Worker 缺少源文件，可点击发送当前源文件"
        }
        guard let rawResponse else {
            return "Worker 源文件已存在，视频会话状态未知"
        }
        if rawResponse.state == "ready" {
            return rawCacheDisplayMessage(rawResponse)
        }
        return "Worker 源文件已存在，\(rawCacheDisplayMessage(rawResponse))"
    }

    nonisolated private static func fetchWorkerIdentity(
        workerURL: URL
    ) async throws -> (DistributedWorkerHello, DistributedWorkerCapabilities) {
        let helloURL = workerURL.appendingPathComponent("hello")
        let capsURL = workerURL.appendingPathComponent("capabilities")

        let (helloData, helloResp) = try await URLSession.shared.data(from: helloURL)
        guard let helloHTTP = helloResp as? HTTPURLResponse,
              (200...299).contains(helloHTTP.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let hello = try JSONDecoder().decode(DistributedWorkerHello.self, from: helloData)

        let (capsData, capsResp) = try await URLSession.shared.data(from: capsURL)
        guard let capsHTTP = capsResp as? HTTPURLResponse,
              (200...299).contains(capsHTTP.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let caps = try JSONDecoder().decode(DistributedWorkerCapabilities.self, from: capsData)
        return (hello, caps)
    }

    nonisolated private static func refreshWorkerSourceCacheState(
        settings: DistributedExportSettings,
        worker: DistributedWorkerNode,
        sourceURL: URL,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        prepareIfFound: Bool
    ) async {
        guard let workerURL = worker.normalizedURL else {
            await MainActor.run {
                settings.updateWorkerCacheHint(
                    workerID: worker.id,
                    expectedFileName: "-",
                    expectedFullPath: "-",
                    exists: false,
                    message: "\(worker.displayName) Worker 地址无效"
                )
                settings.updateWorkerRawCacheState(
                    workerID: worker.id,
                    state: "missing",
                    message: "Worker 地址无效，无法检查源文件"
                )
            }
            return
        }

        do {
            let checked = try await DistributedExportCoordinator.checkWorkerSource(
                workerURL: workerURL,
                sourceURL: sourceURL
            )

            let initialRawResponse: DistributedPrepareSourceResponse?
            if checked.response.exists, let workerLocalPath = checked.response.localPath {
                initialRawResponse = try? await DistributedExportCoordinator.checkWorkerSourcePrepare(
                    workerURL: workerURL,
                    sourceURL: sourceURL,
                    sourceHash: checked.hash,
                    workerLocalSourcePath: workerLocalPath,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    sourceFrameCount: sourceFrameCount
                )
            } else {
                initialRawResponse = nil
            }

            let hint = makeWorkerCacheHint(
                sourceURL: sourceURL,
                checked: checked,
                message: combinedWorkerCacheMessage(
                    sourceExists: checked.response.exists,
                    rawResponse: initialRawResponse
                )
            )

            await MainActor.run {
                settings.updateWorkerCacheHint(
                    workerID: worker.id,
                    expectedFileName: hint.expectedName,
                    expectedFullPath: hint.expectedFullPath,
                    exists: hint.exists,
                    message: hint.message
                )
                if let initialRawResponse {
                    settings.updateWorkerRawCacheState(
                        workerID: worker.id,
                        state: initialRawResponse.state,
                        message: rawCacheDisplayMessage(initialRawResponse)
                    )
                } else {
                    settings.updateWorkerRawCacheState(
                        workerID: worker.id,
                        state: checked.response.exists ? "missing" : "missing",
                        message: checked.response.exists ? "Worker raw cache 未建立" : "Worker 缺少源文件，无法建立 raw cache"
                    )
                }
            }

            guard prepareIfFound,
                  checked.response.exists,
                  let workerLocalPath = checked.response.localPath,
                  initialRawResponse?.state != "ready" else {
                return
            }

            await MainActor.run {
                settings.updateWorkerCacheHint(
                    workerID: worker.id,
                    expectedFileName: hint.expectedName,
                    expectedFullPath: hint.expectedFullPath,
                    exists: true,
                    message: "准备导入 \(worker.displayName) 视频会话"
                )
                settings.updateWorkerRawCacheState(
                    workerID: worker.id,
                    state: "preparing",
                    message: "准备导入 Worker 视频会话"
                )
            }

            let started = try await DistributedExportCoordinator.startWorkerSourcePrepare(
                workerURL: workerURL,
                sourceURL: sourceURL,
                sourceHash: checked.hash,
                workerLocalSourcePath: workerLocalPath,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount
            )

            let final: DistributedPrepareSourceResponse
            if started.state == "ready" || started.state == "failed" {
                final = started
            } else {
                final = try await DistributedExportCoordinator.pollWorkerSourcePrepare(
                    workerURL: workerURL,
                    sourceHash: checked.hash,
                    onProgress: { progress in
                        await MainActor.run {
                            settings.updateWorkerCacheHint(
                                workerID: worker.id,
                                expectedFileName: hint.expectedName,
                                expectedFullPath: hint.expectedFullPath,
                                exists: true,
                                message: "正在导入 \(worker.displayName) 视频会话：\(Int(progress.progress * 100))%｜\(progress.message)"
                            )
                            settings.updateWorkerRawCacheState(
                                workerID: worker.id,
                                state: progress.state,
                                message: rawCacheDisplayMessage(progress)
                            )
                        }
                    }
                )
            }

            await MainActor.run {
                let message = final.state == "ready"
                    ? rawCacheDisplayMessage(final)
                    : "Worker 视频导入/缓存建立失败：\(final.error ?? final.message)"
                settings.updateWorkerCacheHint(
                    workerID: worker.id,
                    expectedFileName: hint.expectedName,
                    expectedFullPath: hint.expectedFullPath,
                    exists: true,
                    message: message
                )
                settings.updateWorkerRawCacheState(
                    workerID: worker.id,
                    state: final.state,
                    message: message
                )
            }
        } catch {
            await MainActor.run {
                settings.updateWorkerCacheHint(
                    workerID: worker.id,
                    expectedFileName: worker.lastExpectedCacheFileName,
                    expectedFullPath: worker.lastExpectedCacheFullPath,
                    exists: worker.lastCacheExists,
                    message: "\(worker.displayName) 源文件检查失败：\(error.localizedDescription)"
                )
                settings.updateWorkerRawCacheState(
                    workerID: worker.id,
                    state: "missing",
                    message: "Worker 源文件检查失败，无法确认 raw cache"
                )
            }
        }
    }

    private func updateDistributedStatusBar(
        settings: DistributedExportSettings,
        title: String
    ) {
        let now = Date()
        let shouldAlwaysUpdate = title.contains("完成")
            || title.contains("开始")
            || title.contains("失败")
            || title.contains("拼接")
            || title.contains("预检查")
        if !shouldAlwaysUpdate,
           now.timeIntervalSince(lastDistributedStatusBarUpdate) < 1.0 {
            return
        }
        lastDistributedStatusBarUpdate = now

        let hostItem = settings.progressItems.first { $0.role == "host" || $0.nodeID == "host" }
        let workerItems = settings.progressItems.filter { $0.role == "worker" || $0.nodeID.hasPrefix("worker") }

        let hostText: String
        if let hostItem {
            hostText = "\(hostItem.displayName) \(hostItem.percentText) \(hostItem.state)"
        } else {
            hostText = "本机 --"
        }

        let workerText: String
        if workerItems.isEmpty {
            workerText = "Worker --"
        } else {
            workerText = workerItems
                .map { "\($0.displayName) \($0.percentText) \($0.state)" }
                .joined(separator: "，")
        }

        let totalText = "\(Int(max(0, min(1, settings.totalDistributedProgress)) * 100))%"
        status = "\(title)｜\(hostText)｜\(workerText)｜总进度 \(totalText)"
    }


    func startDistributedExportInteractively(
        settings: DistributedExportSettings,
        preserveAlpha: Bool = false,
        padToEven: Bool = true,
        qualityScale: Double = 1.0,
        bitDepth: Int = 8,
        colorProfile: VideoColorProfile = .rec709
    ) {
        guard settings.isEnabled else {
            status = "请先启用分布式导出"
            return
        }

        settings.clearWorkerCacheHint()

        let exportMode = sliceMode
        guard (exportMode == .axis && (playbackAxis == .x || playbackAxis == .y)) || exportMode == .plane else {
            status = "当前只有 X / Y 轴和参考面切片支持分布式高精度导出"
            return
        }

        guard let sourceURL = distributedExportSourceURL else {
            status = "没有可用的源视频 URL，无法发起分布式导出"
            return
        }

        let axis = playbackAxis
        let referencePlaneSnapshot = referencePlane
        let fps = sourceFPS > 0 ? sourceFPS : 30.0
        let exportBitDepth = bitDepth
        let exportColorProfile = colorProfile

        // 拍平主线程状态，避免后台任务访问 MainActor 隔离属性
        let sourceWidthSnapshot = distributedSourceWidth
        let sourceHeightSnapshot = distributedSourceHeight
        let sourceFrameCountSnapshot = sourceFrameCount
        let offerUploadWhenSourceMissing = settings.offerUploadWhenSourceMissing
        let recordDiagnostics = settings.recordExportDiagnostics
        let qualityScaleSnapshot = min(1.0, max(0.05, qualityScale))

        let highPrecisionPlaneMetrics = exportMode == .plane
            ? VideoExportHelper.highPrecisionPlaneOutputMetrics(
                sourceWidth: sourceWidthSnapshot,
                sourceHeight: sourceHeightSnapshot,
                sourceFrameCount: sourceFrameCountSnapshot,
                referencePlane: referencePlaneSnapshot,
                qualityScale: qualityScaleSnapshot,
                padToEven: padToEven
            )
            : nil

        let totalFrames = highPrecisionPlaneMetrics?.sliceCount ?? distributedOutputFrameCount
        guard totalFrames > 0 else {
            status = "当前切面没有可分布式导出的输出帧"
            return
        }

        let outputSizeSnapshot = highPrecisionPlaneMetrics.map { (width: $0.width, height: $0.height) }
            ?? distributedOutputImageSize
        guard outputSizeSnapshot.width > 0, outputSizeSnapshot.height > 0 else {
            status = "当前切面输出尺寸无效，无法分布式导出"
            return
        }
        let axisText = exportMode == .plane ? "参考面" : (axis == .x ? "X" : "Y")

        guard let finalOutputURL = chooseDistributedFinalOutputURL(axisText: axisText) else {
            status = "已取消分布式导出"
            return
        }

        let workerSnapshots = settings.workers
        let onlineWorkerSnapshots = workerSnapshots.filter { $0.isOnline && $0.normalizedURL != nil }
        guard !onlineWorkerSnapshots.isEmpty else {
            status = "没有在线 Worker，请先测试连接"
            return
        }

        guard let schedulingChoice = chooseDistributedScheduling(
            totalFrames: totalFrames,
            workers: workerSnapshots
        ) else {
            status = "已取消分布式导出"
            return
        }

        let fixedPlan: DistributedMultiSplitPlan
        switch schedulingChoice.mode {
        case .dynamicChunk:
            fixedPlan = settings.multiSplitPlan(totalOutputFrames: totalFrames)
        case .automaticFixed:
            fixedPlan = DistributedMultiSplitPlan.build(
                totalFrames: totalFrames,
                workers: workerSnapshots,
                weights: Self.automaticDistributedWeights(workers: workerSnapshots)
            )
        case .manualFixed:
            fixedPlan = DistributedMultiSplitPlan.build(
                totalFrames: totalFrames,
                workers: workerSnapshots,
                manualBoundaries: schedulingChoice.manualBoundaries
            )
        }
        let legacyPlan = schedulingChoice.mode == .dynamicChunk
            ? DistributedSplitPlan.build(totalFrames: totalFrames, localSharePercent: 100)
            : Self.legacySplitPlan(from: fixedPlan)

        let sessionID = UUID().uuidString
        settings.resetProgress(sessionID: sessionID)
        settings.updateProgressItem(
            nodeID: "host",
            displayName: "本机",
            role: "host",
            state: "waiting",
            progress: 0.0,
            message: "等待本机分段"
        )
        for worker in onlineWorkerSnapshots {
            settings.updateProgressItem(
                nodeID: worker.nodeID,
                displayName: worker.displayName,
                role: "worker",
                state: "waiting",
                progress: 0.0,
                message: "等待 Worker 分段"
            )
        }

        let qualityScaleText = String(format: "%.2f", qualityScaleSnapshot)
        updateDistributedStatusBar(
            settings: settings,
            title: "分布式预检查中｜轴 \(axisText)｜质量比例 \(qualityScaleText)"
        )

        if schedulingChoice.mode != .dynamicChunk && fixedPlan.workers.filter({ $0.frameCount > 0 }).isEmpty {
            Task.detached(priority: .userInitiated) { [sourceURL, finalOutputURL, legacyPlan, fixedPlan, exportMode, axis, axisText, referencePlaneSnapshot, fps, sourceWidthSnapshot, sourceHeightSnapshot, sourceFrameCountSnapshot, preserveAlpha, padToEven, qualityScaleSnapshot, recordDiagnostics, sessionID] in
                final class LocalTimingDetailBox: @unchecked Sendable {
                    var value: String = "-"
                }
                let localTimingDetailBox = LocalTimingDetailBox()
                let didAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "worker-0",
                            displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                            role: "worker",
                            state: "skipped",
                            progress: 1.0,
                            message: "Worker 未分配分段"
                        )
                        self.updateDistributedStatusBar(
                            settings: settings,
                            title: "分布式本机全量导出中｜轴 \(axisText)"
                        )
                    }

                    let progressHandler: ExportProgressHandler = { p, text in
                        if let text {
                            localTimingDetailBox.value = text
                        }
                        Task { @MainActor in
                            settings.updateProgressItem(
                                nodeID: "host",
                                displayName: "本机",
                                role: "host",
                                state: "running",
                                progress: p,
                                message: text ?? "处理中"
                            )
                            self.updateDistributedStatusBar(
                                settings: settings,
                                title: "分布式本机全量导出中｜轴 \(axisText)"
                            )
                        }
                    }
                    try VideoExportHelper.exportHighPrecisionDistributedSegment(
                        outputURL: finalOutputURL,
                        sourceURL: sourceURL,
                        mode: exportMode,
                        axis: axis,
                        referencePlane: referencePlaneSnapshot,
                        sourceWidth: sourceWidthSnapshot,
                        sourceHeight: sourceHeightSnapshot,
                        sourceFrameCount: sourceFrameCountSnapshot,
                        fps: fps,
                        preserveAlpha: preserveAlpha,
                        padToEven: padToEven,
                        qualityScale: qualityScaleSnapshot,
                        outputStartFrame: legacyPlan.localStartFrame,
                        outputEndFrame: legacyPlan.localEndFrame,
                        bitDepth: exportBitDepth,
                        colorProfile: exportColorProfile,
                        progress: progressHandler
                    )

                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "host",
                            displayName: "本机",
                            role: "host",
                            state: "completed",
                            progress: 1.0,
                            message: "完成",
                            timingText: "详情 \(localTimingDetailBox.value)"
                        )
                        settings.updateProgressItem(
                            nodeID: "worker-0",
                            displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                            role: "worker",
                            state: "skipped",
                            progress: 1.0,
                            message: "Worker 未分配分段"
                        )
                        self.updateDistributedStatusBar(
                            settings: settings,
                            title: "分布式导出完成"
                        )
                        self.status = "分布式导出完成：\(finalOutputURL.lastPathComponent)"
                    }
                    if recordDiagnostics {
                        await Self.writeDistributedExportDiagnostics(
                            settings: settings,
                            model: self,
                            finalOutputURL: finalOutputURL,
                            sourceURL: sourceURL,
                            sourceFileHash: nil,
                            sessionID: sessionID,
                            title: "分布式导出完成",
                            plan: legacyPlan,
                            allocations: Self.diagnosticsAllocations(from: fixedPlan),
                            axis: axisText,
                            fps: fps,
                            sourceWidth: sourceWidthSnapshot,
                            sourceHeight: sourceHeightSnapshot,
                            sourceFrameCount: sourceFrameCountSnapshot,
                            preserveAlpha: preserveAlpha,
                            padToEven: padToEven,
                            qualityScale: qualityScaleSnapshot
                        )
                    }
                } catch {
                    await MainActor.run {
                        self.status = "分布式导出失败：\(error.localizedDescription)"
                    }
                }
            }
            return
        }

        Task.detached(priority: .userInitiated) { [sourceURL, finalOutputURL, fixedPlan, legacyPlan, schedulingChoice, exportMode, axis, referencePlaneSnapshot, outputSizeSnapshot, fps, sourceWidthSnapshot, sourceHeightSnapshot, sourceFrameCountSnapshot, preserveAlpha, padToEven, qualityScaleSnapshot, offerUploadWhenSourceMissing, recordDiagnostics, workerSnapshots] in
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                var workerTargets: [DistributedWorkerExportTarget] = []

                for worker in workerSnapshots where worker.isOnline {
                    guard let workerURL = worker.normalizedURL else { continue }
                    let allocation = schedulingChoice.mode == .dynamicChunk
                        ? DistributedSegmentAllocation(
                            id: worker.nodeID,
                            displayName: worker.displayName,
                            role: "worker",
                            startFrame: 0,
                            endFrame: -1
                        )
                        : fixedPlan.workers.first { $0.id == worker.nodeID } ?? DistributedSegmentAllocation(
                            id: worker.nodeID,
                            displayName: worker.displayName,
                            role: "worker",
                            startFrame: 0,
                            endFrame: -1
                        )
                    if schedulingChoice.mode != .dynamicChunk && allocation.frameCount <= 0 {
                        continue
                    }

                    var checked = try await DistributedExportCoordinator.checkWorkerSource(
                        workerURL: workerURL,
                        sourceURL: sourceURL
                    )

                    let initialHint = Self.makeWorkerCacheHint(
                        sourceURL: sourceURL,
                        checked: checked,
                        message: checked.response.exists ? "\(worker.displayName) 已找到源缓存文件" : "\(worker.displayName) 缺少源缓存文件，请复制到对应缓存目录"
                    )

                    await MainActor.run {
                        settings.updateWorkerCacheHint(
                            workerID: worker.id,
                            expectedFileName: initialHint.expectedName,
                            expectedFullPath: initialHint.expectedFullPath,
                            exists: initialHint.exists,
                            message: initialHint.message
                        )
                    }

                    if !checked.response.exists && offerUploadWhenSourceMissing {
                        let shouldUpload = await MainActor.run {
                            self.confirmUploadMissingSourceToWorker(
                                fileName: initialHint.expectedName,
                                targetPath: initialHint.expectedFullPath
                            )
                        }

                        if shouldUpload {
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: allocation.id,
                                    displayName: worker.displayName,
                                    role: "worker",
                                    state: "uploading",
                                    progress: 0.0,
                                    message: "准备接收源文件"
                                )
                                self.updateDistributedStatusBar(
                                    settings: settings,
                                    title: "正在把源视频发送到 \(worker.displayName)"
                                )
                            }

                            try await DistributedExportCoordinator.uploadSourceToWorker(
                                workerURL: workerURL,
                                sourceURL: sourceURL,
                                sourceHash: checked.hash,
                                progress: { uploadProgress, uploadMessage in
                                    await MainActor.run {
                                        settings.updateProgressItem(
                                            nodeID: allocation.id,
                                            displayName: worker.displayName,
                                            role: "worker",
                                            state: "uploading",
                                            progress: uploadProgress,
                                            message: uploadMessage
                                        )
                                        self.updateDistributedStatusBar(
                                            settings: settings,
                                            title: "正在把源视频发送到 \(worker.displayName)"
                                        )
                                    }
                                }
                            )

                            checked = try await DistributedExportCoordinator.checkWorkerSource(
                                workerURL: workerURL,
                                sourceURL: sourceURL
                            )
                        }
                    }

                    guard checked.response.exists, let workerLocalPath = checked.response.localPath else {
                        await MainActor.run {
                            self.status = "\(worker.displayName) 未找到源视频。已在面板中生成可复制的缓存文件名与完整路径。"
                        }
                        return
                    }

                    workerTargets.append(
                        DistributedWorkerExportTarget(
                            nodeID: allocation.id,
                            displayName: worker.displayName,
                            workerURL: workerURL,
                            workerLocalPath: workerLocalPath,
                            sourceFileHash: checked.hash,
                            allocation: allocation
                        )
                    )
                }

                guard !workerTargets.isEmpty else {
                    await MainActor.run {
                        self.status = "没有可用 Worker 分段，已取消分布式导出"
                    }
                    return
                }
                let finalWorkerTargets = workerTargets

                await MainActor.run {
                    settings.resetProgress(sessionID: sessionID)
                    settings.updateProgressItem(
                        nodeID: "host",
                        displayName: "本机",
                        role: "host",
                        state: "waiting",
                        progress: 0.0,
                        message: "等待本机预热"
                    )
                    for target in finalWorkerTargets {
                        settings.updateProgressItem(
                            nodeID: target.nodeID,
                            displayName: target.displayName,
                            role: "worker",
                            state: "waiting",
                            progress: 0.0,
                            message: "等待 Worker 预热"
                        )
                    }
                    self.updateDistributedStatusBar(
                        settings: settings,
                        title: "源文件已就绪，开始预热导出缓存"
                    )
                }

                switch schedulingChoice.mode {
                case .dynamicChunk:
                    try await Self.runDynamicMultiDistributedExport(
                        settings: settings,
                        model: self,
                        sourceURL: sourceURL,
                        finalOutputURL: finalOutputURL,
                        legacyPlan: legacyPlan,
                        workerTargets: finalWorkerTargets,
                        mode: exportMode,
                        axis: axis,
                        referencePlane: referencePlaneSnapshot,
                        outputWidth: outputSizeSnapshot.width,
                        outputHeight: outputSizeSnapshot.height,
                        fps: fps,
                        sourceWidth: sourceWidthSnapshot,
                        sourceHeight: sourceHeightSnapshot,
                        sourceFrameCount: sourceFrameCountSnapshot,
                        preserveAlpha: preserveAlpha,
                        padToEven: padToEven,
                        qualityScale: qualityScaleSnapshot,
                        colorProfile: exportColorProfile,
                        sessionID: sessionID,
                        recordDiagnostics: recordDiagnostics
                    )
                case .automaticFixed, .manualFixed:
                    try await Self.runBalancedMultiDistributedExport(
                        settings: settings,
                        model: self,
                        sourceURL: sourceURL,
                        finalOutputURL: finalOutputURL,
                        plan: fixedPlan,
                        legacyPlan: legacyPlan,
                        workerTargets: finalWorkerTargets,
                        mode: exportMode,
                        axis: axis,
                        referencePlane: referencePlaneSnapshot,
                        outputWidth: outputSizeSnapshot.width,
                        outputHeight: outputSizeSnapshot.height,
                        fps: fps,
                        sourceWidth: sourceWidthSnapshot,
                        sourceHeight: sourceHeightSnapshot,
                        sourceFrameCount: sourceFrameCountSnapshot,
                        preserveAlpha: preserveAlpha,
                        padToEven: padToEven,
                        qualityScale: qualityScaleSnapshot,
                        colorProfile: exportColorProfile,
                        sessionID: sessionID,
                        recordDiagnostics: recordDiagnostics
                    )
                }
            } catch {
                await MainActor.run {
                    self.status = "分布式导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func prewarmWorkerSourceIfReady(settings: DistributedExportSettings) {
        let workers = settings.workers.filter { $0.isOnline && $0.normalizedURL != nil }
        guard !workers.isEmpty else { return }
        guard let sourceURL = distributedExportSourceURL else { return }
        guard distributedSourceWidth > 0, distributedSourceHeight > 0, sourceFrameCount > 0 else { return }

        let sourceWidthSnapshot = distributedSourceWidth
        let sourceHeightSnapshot = distributedSourceHeight
        let sourceFrameCountSnapshot = sourceFrameCount

        Task.detached(priority: .utility) { [sourceURL, workers, sourceWidthSnapshot, sourceHeightSnapshot, sourceFrameCountSnapshot] in
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            await withTaskGroup(of: Void.self) { group in
                for worker in workers {
                    group.addTask {
                        await Self.refreshWorkerSourceCacheState(
                            settings: settings,
                            worker: worker,
                            sourceURL: sourceURL,
                            sourceWidth: sourceWidthSnapshot,
                            sourceHeight: sourceHeightSnapshot,
                            sourceFrameCount: sourceFrameCountSnapshot,
                            prepareIfFound: true
                        )
                    }
                }
            }
        }
    }

    func testAllWorkerConnectionsAndPrepare(settings: DistributedExportSettings) {
        let workers = settings.workers
        guard !workers.isEmpty else {
            status = "没有可测试的 Worker"
            return
        }

        let sourceURL = distributedExportSourceURL
        let sourceWidthSnapshot = distributedSourceWidth
        let sourceHeightSnapshot = distributedSourceHeight
        let sourceFrameCountSnapshot = sourceFrameCount

        for worker in workers {
            settings.updateWorkerRawCacheState(
                workerID: worker.id,
                state: "checking",
                message: "正在测试连接"
            )
        }
        status = "正在测试所有 Worker 并检查源缓存"

        Task.detached(priority: .userInitiated) { [workers, sourceURL, sourceWidthSnapshot, sourceHeightSnapshot, sourceFrameCountSnapshot] in
            let didAccess = sourceURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if didAccess {
                    sourceURL?.stopAccessingSecurityScopedResource()
                }
            }

            await withTaskGroup(of: Void.self) { group in
                for worker in workers {
                    group.addTask {
                        guard let workerURL = worker.normalizedURL else {
                            await MainActor.run {
                                settings.updateWorkerConnection(
                                    workerID: worker.id,
                                    state: .offline("Worker 地址无效"),
                                    name: "-",
                                    capabilities: nil
                                )
                            }
                            return
                        }

                        await MainActor.run {
                            settings.updateWorkerConnection(
                                workerID: worker.id,
                                state: .checking,
                                name: "-",
                                capabilities: nil
                            )
                        }

                        do {
                            let (hello, caps) = try await Self.fetchWorkerIdentity(workerURL: workerURL)
                            await MainActor.run {
                                settings.updateWorkerConnection(
                                    workerID: worker.id,
                                    state: .online,
                                    name: hello.name,
                                    capabilities: caps
                                )
                            }

                            guard let sourceURL,
                                  sourceWidthSnapshot > 0,
                                  sourceHeightSnapshot > 0,
                                  sourceFrameCountSnapshot > 0 else {
                                return
                            }

                            var refreshedWorker = worker
                            refreshedWorker.connectionState = .online
                            refreshedWorker.name = hello.name
                            refreshedWorker.capabilities = caps
                            await Self.refreshWorkerSourceCacheState(
                                settings: settings,
                                worker: refreshedWorker,
                                sourceURL: sourceURL,
                                sourceWidth: sourceWidthSnapshot,
                                sourceHeight: sourceHeightSnapshot,
                                sourceFrameCount: sourceFrameCountSnapshot,
                                prepareIfFound: true
                            )
                        } catch {
                            await MainActor.run {
                                settings.updateWorkerConnection(
                                    workerID: worker.id,
                                    state: .offline(error.localizedDescription),
                                    name: "-",
                                    capabilities: nil
                                )
                                settings.updateWorkerRawCacheState(
                                    workerID: worker.id,
                                    state: "missing",
                                    message: "Worker 连接失败，无法检查源缓存"
                                )
                            }
                        }
                    }
                }
            }

            await MainActor.run {
                let onlineCount = settings.workers.filter(\.isOnline).count
                self.status = sourceURL == nil
                    ? "已测试所有 Worker：在线 \(onlineCount) 台"
                    : "已测试所有 Worker 并检查源缓存：在线 \(onlineCount) 台"
            }
        }
    }

    func refreshWorkerSourceCache(settings: DistributedExportSettings) {
        let workers = settings.workers.filter { $0.isOnline && $0.normalizedURL != nil }
        guard !workers.isEmpty else {
            status = "没有在线 Worker，请先测试连接"
            return
        }
        guard let sourceURL = distributedExportSourceURL else {
            status = "没有可用的源视频 URL"
            return
        }
        guard distributedSourceWidth > 0, distributedSourceHeight > 0, sourceFrameCount > 0 else {
            status = "当前视频尺寸信息还未就绪"
            return
        }

        let sourceWidthSnapshot = distributedSourceWidth
        let sourceHeightSnapshot = distributedSourceHeight
        let sourceFrameCountSnapshot = sourceFrameCount

        Task.detached(priority: .userInitiated) { [sourceURL, workers, sourceWidthSnapshot, sourceHeightSnapshot, sourceFrameCountSnapshot] in
            await withTaskGroup(of: Void.self) { group in
                for worker in workers {
                    group.addTask {
                        await Self.refreshWorkerSourceCacheState(
                            settings: settings,
                            worker: worker,
                            sourceURL: sourceURL,
                            sourceWidth: sourceWidthSnapshot,
                            sourceHeight: sourceHeightSnapshot,
                            sourceFrameCount: sourceFrameCountSnapshot,
                            prepareIfFound: false
                        )
                    }
                }
            }
            await MainActor.run {
                self.status = "已刷新所有在线 Worker 源文件检查"
            }
        }
    }

    func uploadCurrentSourceToWorker(settings: DistributedExportSettings) {
        let workers = settings.workers.filter { $0.isOnline && $0.normalizedURL != nil }
        guard !workers.isEmpty else {
            status = "没有在线 Worker，请先测试连接"
            return
        }
        guard let sourceURL = distributedExportSourceURL else {
            status = "没有可用的源视频 URL"
            return
        }

        Task.detached(priority: .userInitiated) { [sourceURL, workers] in
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                for worker in workers {
                    guard let workerURL = worker.normalizedURL else { continue }
                    let checked = try await DistributedExportCoordinator.checkWorkerSource(
                        workerURL: workerURL,
                        sourceURL: sourceURL
                    )
                    let startHint = Self.makeWorkerCacheHint(
                        sourceURL: sourceURL,
                        checked: checked,
                        message: checked.response.exists ? "\(worker.displayName) 源文件已存在，无需重复发送" : "准备发送当前源文件到 \(worker.displayName)"
                    )
                    await MainActor.run {
                        settings.updateWorkerCacheHint(
                            workerID: worker.id,
                            expectedFileName: startHint.expectedName,
                            expectedFullPath: startHint.expectedFullPath,
                            exists: startHint.exists,
                            message: startHint.message
                        )
                        if !checked.response.exists {
                            settings.updateWorkerRawCacheState(
                                workerID: worker.id,
                                state: "missing",
                                message: "Worker 缺少源文件，无法建立 raw cache"
                            )
                        }
                    }

                    guard !checked.response.exists else { continue }

                    try await DistributedExportCoordinator.uploadSourceToWorker(
                        workerURL: workerURL,
                        sourceURL: sourceURL,
                        sourceHash: checked.hash,
                        progress: { uploadProgress, uploadMessage in
                            await MainActor.run {
                                settings.updateWorkerCacheHint(
                                    workerID: worker.id,
                                    expectedFileName: startHint.expectedName,
                                    expectedFullPath: startHint.expectedFullPath,
                                    exists: false,
                                    message: "正在发送源文件：\(Int(uploadProgress * 100))%｜\(uploadMessage)"
                                )
                                settings.updateWorkerRawCacheState(
                                    workerID: worker.id,
                                    state: "missing",
                                    message: "源文件发送完成后可建立 Worker raw cache"
                                )
                                self.status = "正在发送源文件到 \(worker.displayName)"
                            }
                        }
                    )

                    let refreshed = try await DistributedExportCoordinator.checkWorkerSource(
                        workerURL: workerURL,
                        sourceURL: sourceURL
                    )
                    let refreshedHint = Self.makeWorkerCacheHint(
                        sourceURL: sourceURL,
                        checked: refreshed,
                        message: refreshed.response.exists ? "源文件已发送到 \(worker.displayName)" : "发送完成后仍未检测到 \(worker.displayName) 源文件"
                    )
                    await MainActor.run {
                        settings.updateWorkerCacheHint(
                            workerID: worker.id,
                            expectedFileName: refreshedHint.expectedName,
                            expectedFullPath: refreshedHint.expectedFullPath,
                            exists: refreshedHint.exists,
                            message: refreshedHint.message
                        )
                        settings.updateWorkerRawCacheState(
                            workerID: worker.id,
                            state: "missing",
                            message: refreshed.response.exists ? "Worker raw cache 未建立" : "Worker 缺少源文件，无法建立 raw cache"
                        )
                    }
                }
                await MainActor.run {
                    self.status = "已向所有缺少源文件的在线 Worker 发送源文件"
                }
            } catch {
                await MainActor.run {
                    self.status = "发送源文件到 Worker 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func prepareWorkerRawCache(settings: DistributedExportSettings) {
        let workers = settings.workers.filter { $0.isOnline && $0.normalizedURL != nil }
        guard !workers.isEmpty else {
            status = "没有在线 Worker，请先测试连接"
            return
        }
        guard let sourceURL = distributedExportSourceURL else {
            status = "没有可用的源视频 URL"
            return
        }
        guard distributedSourceWidth > 0, distributedSourceHeight > 0, sourceFrameCount > 0 else {
            status = "当前视频尺寸信息还未就绪"
            return
        }

        let sourceWidthSnapshot = distributedSourceWidth
        let sourceHeightSnapshot = distributedSourceHeight
        let sourceFrameCountSnapshot = sourceFrameCount

        Task.detached(priority: .userInitiated) { [sourceURL, workers, sourceWidthSnapshot, sourceHeightSnapshot, sourceFrameCountSnapshot] in
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                for worker in workers {
                    guard let workerURL = worker.normalizedURL else { continue }
                    let checked = try await DistributedExportCoordinator.checkWorkerSource(
                        workerURL: workerURL,
                        sourceURL: sourceURL
                    )
                    let hint = Self.makeWorkerCacheHint(
                        sourceURL: sourceURL,
                        checked: checked,
                        message: checked.response.exists ? "准备导入 \(worker.displayName) 视频会话" : "\(worker.displayName) 缺少源文件，请先发送当前源文件"
                    )
                    await MainActor.run {
                        settings.updateWorkerCacheHint(
                            workerID: worker.id,
                            expectedFileName: hint.expectedName,
                            expectedFullPath: hint.expectedFullPath,
                            exists: hint.exists,
                            message: hint.message
                        )
                        settings.updateWorkerRawCacheState(
                            workerID: worker.id,
                            state: checked.response.exists ? "preparing" : "missing",
                            message: checked.response.exists ? "准备导入 Worker 视频会话" : "Worker 缺少源文件，无法导入 Worker 视频会话"
                        )
                        self.status = "正在导入 \(worker.displayName) 视频会话"
                    }

                    guard checked.response.exists, let workerLocalPath = checked.response.localPath else {
                        continue
                    }

                    let initial = try await DistributedExportCoordinator.startWorkerSourcePrepare(
                        workerURL: workerURL,
                        sourceURL: sourceURL,
                        sourceHash: checked.hash,
                        workerLocalSourcePath: workerLocalPath,
                        sourceWidth: sourceWidthSnapshot,
                        sourceHeight: sourceHeightSnapshot,
                        sourceFrameCount: sourceFrameCountSnapshot
                    )

                    let final: DistributedPrepareSourceResponse
                    if initial.state == "ready" || initial.state == "failed" {
                        final = initial
                    } else {
                        final = try await DistributedExportCoordinator.pollWorkerSourcePrepare(
                            workerURL: workerURL,
                            sourceHash: checked.hash,
                            onProgress: { progress in
                                await MainActor.run {
                                    settings.updateWorkerCacheHint(
                                        workerID: worker.id,
                                        expectedFileName: hint.expectedName,
                                        expectedFullPath: hint.expectedFullPath,
                                        exists: true,
                                        message: "正在导入 \(worker.displayName) 视频会话：\(Int(progress.progress * 100))%｜\(progress.message)"
                                    )
                                    settings.updateWorkerRawCacheState(
                                        workerID: worker.id,
                                        state: progress.state,
                                        message: Self.rawCacheDisplayMessage(progress)
                                    )
                                    self.status = "正在导入 \(worker.displayName) 视频会话"
                                }
                            }
                        )
                    }

                    await MainActor.run {
                        let message = final.state == "ready" ? Self.rawCacheDisplayMessage(final) : "Worker 视频导入/缓存建立失败：\(final.error ?? final.message)"
                        settings.updateWorkerCacheHint(
                            workerID: worker.id,
                            expectedFileName: hint.expectedName,
                            expectedFullPath: hint.expectedFullPath,
                            exists: true,
                            message: message
                        )
                        settings.updateWorkerRawCacheState(
                            workerID: worker.id,
                            state: final.state,
                            message: message
                        )
                    }
                }
                await MainActor.run {
                    self.status = "所有在线 Worker 视频会话导入已完成"
                }
            } catch {
                await MainActor.run {
                    self.status = "导入 Worker 视频会话失败：\(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated private static func dynamicDistributedChunkSize(totalFrames: Int) -> Int {
        dynamicDistributedChunkSize(totalFrames: totalFrames, activeNodeCount: 2)
    }

    nonisolated private static func dynamicDistributedChunkSize(totalFrames: Int, activeNodeCount: Int) -> Int {
        guard totalFrames > 0 else { return 1 }
        let safeNodeCount = max(1, activeNodeCount)
        let targetChunkCount = max(safeNodeCount, safeNodeCount * 2)
        let rawSize = Int((Double(totalFrames) / Double(targetChunkCount)).rounded(.up))
        return max(192, rawSize)
    }

    nonisolated private static func dynamicWorkerBatchSize(totalFrames: Int) -> Int {
        1
    }

    nonisolated private static func syncDynamicDistributedProgress(
        settings: DistributedExportSettings,
        workerURL: URL,
        title: String
    ) async {
        let snapshot = await MainActor.run {
            settings.makeClusterSnapshot(title: title)
        }
        await DistributedExportCoordinator.postClusterStatus(
            workerURL: workerURL,
            snapshot: snapshot
        )
    }

    nonisolated private static func syncDistributedProgress(
        settings: DistributedExportSettings,
        workerTargets: [DistributedWorkerExportTarget],
        title: String
    ) async {
        for target in workerTargets {
            await syncDynamicDistributedProgress(
                settings: settings,
                workerURL: target.workerURL,
                title: title
            )
        }
    }

    nonisolated private static func secondsSince(_ start: Date) -> Double {
        max(0.0, Date().timeIntervalSince(start))
    }

    nonisolated private static func durationText(_ seconds: Double) -> String {
        if seconds >= 60 {
            return String(format: "%.1f 分", seconds / 60.0)
        }
        return String(format: "%.1f 秒", seconds)
    }

    nonisolated private static func fpsText(frames: Int, seconds: Double) -> String {
        guard frames > 0, seconds > 0.05 else { return "FPS -" }
        return String(format: "FPS %.2f", Double(frames) / seconds)
    }

    nonisolated private struct DistributedWorkerExportTarget: Sendable {
        let nodeID: String
        let displayName: String
        let workerURL: URL
        let workerLocalPath: String
        let sourceFileHash: String
        let allocation: DistributedSegmentAllocation
    }

    nonisolated private static func legacySplitPlan(from plan: DistributedMultiSplitPlan) -> DistributedSplitPlan {
        let workerStart = plan.workers.first?.startFrame ?? plan.local.endFrame + 1
        let workerEnd = plan.workers.last?.endFrame ?? workerStart - 1
        return DistributedSplitPlan(
            localStartFrame: plan.local.startFrame,
            localEndFrame: plan.local.endFrame,
            workerStartFrame: workerStart,
            workerEndFrame: workerEnd
        )
    }

    nonisolated private static func diagnosticsAllocations(
        from plan: DistributedMultiSplitPlan
    ) -> [DistributedExportDiagnosticsAllocation] {
        plan.all.map { allocation in
            DistributedExportDiagnosticsAllocation(
                nodeID: allocation.id,
                displayName: allocation.displayName,
                role: allocation.role,
                startFrame: allocation.startFrame,
                endFrame: allocation.endFrame,
                frameCount: allocation.frameCount
            )
        }
    }

    nonisolated private static func automaticDistributedWeights(workers: [DistributedWorkerNode]) -> [Double] {
        let onlineCaps = workers.filter(\.isOnline).compactMap(\.capabilities)
        let averageCPU = Double(max(1, onlineCaps.map(\.cpuCores).reduce(0, +))) / Double(max(1, onlineCaps.count))
        let averageGPU = Double(max(1, onlineCaps.map(\.gpuCores).reduce(0, +))) / Double(max(1, onlineCaps.count))
        let averageMemory = Double(max(1, onlineCaps.map(\.memoryGB).reduce(0, +))) / Double(max(1, onlineCaps.count))

        func weight(cpu: Double, gpu: Double, memory: Double) -> Double {
            max(0.2, gpu * 0.55 + cpu * 0.25 + memory * 0.20)
        }

        let hostWeight = weight(cpu: averageCPU, gpu: averageGPU, memory: averageMemory)
        let workerWeights = workers.filter(\.isOnline).map { worker in
            guard let caps = worker.capabilities else {
                return hostWeight
            }
            return weight(
                cpu: Double(caps.cpuCores),
                gpu: Double(caps.gpuCores),
                memory: Double(caps.memoryGB)
            )
        }
        return [hostWeight] + workerWeights
    }

    nonisolated private static func weightedProgress(
        settings: DistributedExportSettings,
        plan: DistributedMultiSplitPlan
    ) async -> Double {
        await MainActor.run {
            let total = max(1, plan.totalFrameCount)
            return plan.all.reduce(0.0) { partial, allocation in
                let progress = settings.progressItems.first { $0.nodeID == allocation.id }?.progress ?? 0.0
                return partial + (Double(allocation.frameCount) * progress / Double(total))
            }
        }
    }

    nonisolated private static func writeDistributedExportDiagnostics(
        settings: DistributedExportSettings,
        model: AppModel,
        finalOutputURL: URL,
        sourceURL: URL,
        sourceFileHash: String?,
        sessionID: String,
        title: String,
        plan: DistributedSplitPlan,
        allocations: [DistributedExportDiagnosticsAllocation]? = nil,
        axis: String,
        fps: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        preserveAlpha: Bool,
        padToEven: Bool,
        qualityScale: Double
    ) async {
        do {
            let snapshot = await MainActor.run {
                settings.makeClusterSnapshot(title: title)
            }
            let report = DistributedExportDiagnosticsReport(
                schemaVersion: 1,
                sessionID: sessionID,
                exportedAtISO8601: ISO8601DateFormatter().string(from: Date()),
                sourcePath: sourceURL.path,
                sourceFileHash: sourceFileHash,
                outputPath: finalOutputURL.path,
                axis: axis,
                fps: fps,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                totalOutputFrames: max(0, plan.localFrameCount + plan.workerFrameCount),
                preserveAlpha: preserveAlpha,
                padToEven: padToEven,
                qualityScale: qualityScale,
                splitPlan: DistributedExportDiagnosticsSplitPlan(
                    localStartFrame: plan.localStartFrame,
                    localEndFrame: plan.localEndFrame,
                    localFrameCount: plan.localFrameCount,
                    workerStartFrame: plan.workerStartFrame,
                    workerEndFrame: plan.workerEndFrame,
                    workerFrameCount: plan.workerFrameCount
                ),
                allocations: allocations ?? [
                    DistributedExportDiagnosticsAllocation(
                        nodeID: "host",
                        displayName: "本机",
                        role: "host",
                        startFrame: plan.localStartFrame,
                        endFrame: plan.localEndFrame,
                        frameCount: plan.localFrameCount
                    ),
                    DistributedExportDiagnosticsAllocation(
                        nodeID: "worker-0",
                        displayName: "Worker",
                        role: "worker",
                        startFrame: plan.workerStartFrame,
                        endFrame: plan.workerEndFrame,
                        frameCount: plan.workerFrameCount
                    )
                ].filter { $0.frameCount > 0 || $0.role == "host" },
                progressSnapshot: snapshot
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let stamp = formatter.string(from: Date())
            let baseName = finalOutputURL.deletingPathExtension().lastPathComponent
            let reportURL = finalOutputURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(baseName)_distributed_diagnostics_\(stamp).json")

            try data.write(to: reportURL, options: .atomic)

            await MainActor.run {
                model.status = "分布式导出完成，诊断数据已保存：\(reportURL.lastPathComponent)"
            }
        } catch {
            await MainActor.run {
                model.status = "分布式导出完成，但诊断数据保存失败：\(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func runBalancedMultiDistributedExport(
        settings: DistributedExportSettings,
        model: AppModel,
        sourceURL: URL,
        finalOutputURL: URL,
        plan: DistributedMultiSplitPlan,
        legacyPlan: DistributedSplitPlan,
        workerTargets: [DistributedWorkerExportTarget],
        mode: SliceMode,
        axis: PlaybackAxis,
        referencePlane: ReferencePlaneState,
        outputWidth: Int,
        outputHeight: Int,
        fps: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        preserveAlpha: Bool,
        padToEven: Bool,
        qualityScale: Double,
        colorProfile: VideoColorProfile,
        sessionID: String,
        recordDiagnostics: Bool
    ) async throws {
        let totalOutputFrames = max(1, plan.totalFrameCount)
        let sourceFileHash = workerTargets.first?.sourceFileHash ?? "-"
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ChronoVolumeDistributed", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)

        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        let axisToken = mode == .plane ? "plane" : (axis == .x ? "x" : "y")

        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "固定分工",
                role: "cluster",
                state: "preparing",
                progress: 0.0,
                message: "本机 \(plan.local.frameCount) 帧｜Worker \(plan.workers.map(\.frameCount).reduce(0, +)) 帧"
            )
            model.updateDistributedStatusBar(settings: settings, title: "多 Worker 固定分工导出开始")
        }
        await syncDistributedProgress(settings: settings, workerTargets: workerTargets, title: "多 Worker 固定分工导出开始")

        let workerWarmupTasks: [String: Task<String?, Never>] = Dictionary(
            uniqueKeysWithValues: workerTargets.map { target in
                (
                    target.nodeID,
                    Task.detached(priority: .userInitiated) {
                        let warmupStart = Date()
                        do {
                            let initialPrepare = try await DistributedExportCoordinator.startWorkerSourcePrepare(
                                workerURL: target.workerURL,
                                sourceURL: sourceURL,
                                sourceHash: target.sourceFileHash,
                                workerLocalSourcePath: target.workerLocalPath,
                                sourceWidth: sourceWidth,
                                sourceHeight: sourceHeight,
                                sourceFrameCount: sourceFrameCount
                            )

                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: target.nodeID,
                                    displayName: target.displayName,
                                    role: "worker",
                                    state: "preparing",
                                    progress: min(0.08, initialPrepare.progress * 0.08),
                                    message: initialPrepare.message
                                )
                            }

                            let prepareResult: DistributedPrepareSourceResponse
                            if initialPrepare.state == "ready" || initialPrepare.state == "failed" {
                                prepareResult = initialPrepare
                            } else {
                                prepareResult = try await DistributedExportCoordinator.pollWorkerSourcePrepare(
                                    workerURL: target.workerURL,
                                    sourceHash: target.sourceFileHash,
                                    onProgress: { progress in
                                        await MainActor.run {
                                            settings.updateProgressItem(
                                                nodeID: target.nodeID,
                                                displayName: target.displayName,
                                                role: "worker",
                                                state: "preparing",
                                                progress: min(0.08, progress.progress * 0.08),
                                                message: progress.message
                                            )
                                        }
                                    }
                                )
                            }

                            let warmupDuration = secondsSince(warmupStart)
                            if prepareResult.state == "ready", let rawPath = prepareResult.rawCachePath {
                                await MainActor.run {
                                    settings.updateProgressItem(
                                        nodeID: target.nodeID,
                                        displayName: target.displayName,
                                        role: "worker",
                                        state: "preparing",
                                        progress: 0.08,
                                        message: "Worker 预热完成",
                                        timingText: "Worker 预热 \(durationText(warmupDuration))"
                                    )
                                }
                                return rawPath
                            }

                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: target.nodeID,
                                    displayName: target.displayName,
                                    role: "worker",
                                    state: "running",
                                    progress: 0.08,
                                    message: "Worker 预热失败，将回退到普通分段：\(prepareResult.error ?? prepareResult.message)",
                                    timingText: "Worker 预热 \(durationText(warmupDuration))"
                                )
                            }
                            return nil
                        } catch {
                            let warmupDuration = secondsSince(warmupStart)
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: target.nodeID,
                                    displayName: target.displayName,
                                    role: "worker",
                                    state: "running",
                                    progress: 0.08,
                                    message: "Worker 预热不可用，将回退到普通分段：\(error.localizedDescription)",
                                    timingText: "Worker 预热 \(durationText(warmupDuration))"
                                )
                            }
                            return nil
                        }
                    }
                )
            }
        )

        final class TimingDetailBox: @unchecked Sendable {
            var value: String = "-"
        }

        let hostTask: Task<(Int, URL)?, Error>? = plan.local.frameCount > 0
            ? Task.detached(priority: .userInitiated) {
                let hostDetailBox = TimingDetailBox()
                let hostPreparedRawCacheURL = tempDir.appendingPathComponent(
                    "host_\(sourceFileHash)_\(sourceWidth)x\(sourceHeight)x\(sourceFrameCount).rawframes"
                )
                let hostRawStart = Date()
                let hostRawCacheURL = try VideoExportHelper.prepareDistributedRawFrameCache(
                    sourceURL: sourceURL,
                    outputURL: hostPreparedRawCacheURL,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    sourceFrameCount: sourceFrameCount,
                    progress: { p, text in
                        Task {
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: "host",
                                    displayName: "本机",
                                    role: "host",
                                    state: "preparing",
                                    progress: min(0.08, p * 0.08),
                                    message: text ?? "正在建立本机 raw cache"
                                )
                                model.updateDistributedStatusBar(settings: settings, title: "本机正在预热导出缓存")
                            }
                        }
                    }
                )
                let hostRawDuration = secondsSince(hostRawStart)

                if !workerWarmupTasks.isEmpty {
                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "host",
                            displayName: "本机",
                            role: "host",
                            state: "waiting",
                            progress: 0.08,
                            message: "等待 Worker 完成预热后同步开跑"
                        )
                    }
                    for task in workerWarmupTasks.values {
                        _ = await task.value
                    }
                }

                let localSegmentURL = tempDir.appendingPathComponent(
                    "segment_0000_host_\(axisToken)_\(plan.local.startFrame)_\(plan.local.endFrame).mov"
                )

                let hostRenderStart = Date()
                let progressHandler: ExportProgressHandler = { p, text in
                        if let text {
                            hostDetailBox.value = text
                        }
                        Task {
                            let renderElapsed = secondsSince(hostRenderStart)
                            let renderedFrames = Int((Double(plan.local.frameCount) * p).rounded())
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: "host",
                                    displayName: "本机",
                                    role: "host",
                                    state: "running",
                                    progress: p,
                                    message: text ?? "处理中",
                                    timingText: "raw \(durationText(hostRawDuration))｜渲染 \(durationText(renderElapsed))｜\(fpsText(frames: renderedFrames, seconds: renderElapsed))"
                                )
                            }
                            let weighted = await weightedProgress(settings: settings, plan: plan)
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: "cluster",
                                    displayName: "固定分工",
                                    role: "cluster",
                                    state: "running",
                                    progress: weighted,
                                    message: "多 Worker 分段导出中"
                                )
                                model.updateDistributedStatusBar(settings: settings, title: "多 Worker 固定分工导出中")
                            }
                            await syncDistributedProgress(settings: settings, workerTargets: workerTargets, title: "多 Worker 固定分工导出中")
                        }
                }
                try VideoExportHelper.exportHighPrecisionDistributedSegment(
                    outputURL: localSegmentURL,
                    sourceURL: sourceURL,
                    mode: mode,
                    axis: axis,
                    referencePlane: referencePlane,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    sourceFrameCount: sourceFrameCount,
                    fps: fps,
                    preserveAlpha: preserveAlpha,
                    padToEven: padToEven,
                    qualityScale: qualityScale,
                    outputStartFrame: plan.local.startFrame,
                    outputEndFrame: plan.local.endFrame,
                    preparedRawCacheURL: hostRawCacheURL,
                    colorProfile: colorProfile,
                    progress: progressHandler
                )
                let hostRenderDuration = secondsSince(hostRenderStart)

                await MainActor.run {
                    settings.updateProgressItem(
                        nodeID: "host",
                        displayName: "本机",
                        role: "host",
                        state: "completed",
                        progress: 1.0,
                        message: "本机分段完成",
                        timingText: "raw \(durationText(hostRawDuration))｜渲染 \(durationText(hostRenderDuration))｜\(fpsText(frames: plan.local.frameCount, seconds: hostRenderDuration))｜详情 \(hostDetailBox.value)"
                    )
                }
                return (plan.local.startFrame, localSegmentURL)
            }
            : nil

        let workerTasks: [Task<(Int, URL)?, Error>] = workerTargets.map { target in
            Task.detached(priority: .userInitiated) {
                let workerWarmupWaitStart = Date()
                let preparedRawCachePath = await workerWarmupTasks[target.nodeID]?.value
                let workerWarmupWaitDuration = secondsSince(workerWarmupWaitStart)
                let workerRouteBox = TimingDetailBox()
                let workerJob = DistributedExportCoordinator.buildWorkerJob(
                    sourceURL: sourceURL,
                    mode: mode,
                    axis: axis,
                    referencePlane: referencePlane,
                    totalOutputFrames: totalOutputFrames,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    sourceFrameCount: sourceFrameCount,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight,
                    fps: fps,
                    preserveAlpha: preserveAlpha,
                    padToEven: padToEven,
                    qualityScale: qualityScale,
                    rangeStart: target.allocation.startFrame,
                    rangeEnd: target.allocation.endFrame,
                    colorProfile: colorProfile,
                    sourceFileHash: target.sourceFileHash
                )

                let workerRemoteRenderStart = Date()
                try await DistributedExportCoordinator.startRemoteWorkerJob(
                    workerURL: target.workerURL,
                    job: workerJob,
                    workerLocalSourcePath: target.workerLocalPath,
                    preparedRawCachePath: preparedRawCachePath
                )

                let remoteResult = try await DistributedExportCoordinator.pollRemoteWorkerJob(
                    workerURL: target.workerURL,
                    jobID: workerJob.jobID,
                    onProgress: { progress in
                        workerRouteBox.value = progress.message
                        let renderElapsed = secondsSince(workerRemoteRenderStart)
                        let renderedFrames = Int((Double(target.allocation.frameCount) * progress.progress).rounded())
                        await MainActor.run {
                            settings.updateProgressItem(
                                nodeID: target.nodeID,
                                displayName: target.displayName,
                                role: "worker",
                                state: progress.state,
                                progress: progress.progress,
                                message: progress.message,
                                timingText: "预热等待 \(durationText(workerWarmupWaitDuration))｜远程渲染 \(durationText(renderElapsed))｜\(fpsText(frames: renderedFrames, seconds: renderElapsed))"
                            )
                        }
                        let weighted = await weightedProgress(settings: settings, plan: plan)
                        await MainActor.run {
                            settings.updateProgressItem(
                                nodeID: "cluster",
                                displayName: "固定分工",
                                role: "cluster",
                                state: "running",
                                progress: weighted,
                                message: "\(target.displayName) \(target.allocation.startFrame)...\(target.allocation.endFrame)"
                            )
                            model.updateDistributedStatusBar(settings: settings, title: "多 Worker 固定分工导出中")
                        }
                        await syncDistributedProgress(settings: settings, workerTargets: workerTargets, title: "多 Worker 固定分工导出中")
                    }
                )
                let workerRemoteRenderDuration = secondsSince(workerRemoteRenderStart)

                guard remoteResult.state == "completed" else {
                    throw DistributedCoordinatorError.remoteResultFailed(remoteResult.error ?? remoteResult.state)
                }

                let remoteDownloadedURL = tempDir.appendingPathComponent(
                    "segment_\(target.nodeID)_\(axisToken)_\(target.allocation.startFrame)_\(target.allocation.endFrame).mov"
                )
                let workerDownloadStart = Date()
                try await DistributedExportCoordinator.downloadRemoteWorkerSegment(
                    workerURL: target.workerURL,
                    jobID: workerJob.jobID,
                    to: remoteDownloadedURL
                )
                let workerDownloadDuration = secondsSince(workerDownloadStart)

                await MainActor.run {
                    settings.updateProgressItem(
                        nodeID: target.nodeID,
                        displayName: target.displayName,
                        role: "worker",
                        state: "completed",
                        progress: 1.0,
                        message: "Worker 分段完成：\(workerRouteBox.value)",
                        timingText: "预热等待 \(durationText(workerWarmupWaitDuration))｜远程渲染 \(durationText(workerRemoteRenderDuration))｜下载 \(durationText(workerDownloadDuration))｜\(fpsText(frames: target.allocation.frameCount, seconds: workerRemoteRenderDuration))｜详情 \(workerRouteBox.value)"
                    )
                }
                return (target.allocation.startFrame, remoteDownloadedURL)
            }
        }

        var segmentPairs: [(Int, URL)] = []
        do {
            if let hostPair = try await hostTask?.value {
                segmentPairs.append(hostPair)
            }
            for task in workerTasks {
                if let pair = try await task.value {
                    segmentPairs.append(pair)
                }
            }
        } catch {
            hostTask?.cancel()
            workerTasks.forEach { $0.cancel() }
            throw error
        }

        let segments = segmentPairs
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "固定分工",
                role: "cluster",
                state: "stitching",
                progress: 1.0,
                message: "正在拼接 \(segments.count) 个分段"
            )
            model.updateDistributedStatusBar(settings: settings, title: "正在拼接多 Worker 分段")
        }
        await syncDistributedProgress(settings: settings, workerTargets: workerTargets, title: "正在拼接多 Worker 分段")

        try await SegmentStitcher.stitch(
            segmentURLs: segments,
            outputURL: finalOutputURL
        )

        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "host",
                displayName: "本机",
                role: "host",
                state: plan.local.frameCount > 0 ? "completed" : "skipped",
                progress: 1.0,
                message: plan.local.frameCount > 0 ? "完成" : "本机未分配分段"
            )
            for target in workerTargets {
                settings.updateProgressItem(
                    nodeID: target.nodeID,
                    displayName: target.displayName,
                    role: "worker",
                    state: "completed",
                    progress: 1.0,
                    message: "完成"
                )
            }
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "固定分工",
                role: "cluster",
                state: "completed",
                progress: 1.0,
                message: "完成"
            )
            model.updateDistributedStatusBar(settings: settings, title: "分布式导出完成")
        }
        await syncDistributedProgress(settings: settings, workerTargets: workerTargets, title: "分布式导出完成")

        if recordDiagnostics {
            await writeDistributedExportDiagnostics(
                settings: settings,
                model: model,
                finalOutputURL: finalOutputURL,
                sourceURL: sourceURL,
                sourceFileHash: sourceFileHash,
                sessionID: sessionID,
                title: "分布式导出完成",
                plan: legacyPlan,
                allocations: diagnosticsAllocations(from: plan),
                axis: axisToken,
                fps: fps,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                preserveAlpha: preserveAlpha,
                padToEven: padToEven,
                qualityScale: qualityScale
            )
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    nonisolated private static func runDynamicMultiDistributedExport(
        settings: DistributedExportSettings,
        model: AppModel,
        sourceURL: URL,
        finalOutputURL: URL,
        legacyPlan: DistributedSplitPlan,
        workerTargets: [DistributedWorkerExportTarget],
        mode: SliceMode,
        axis: PlaybackAxis,
        referencePlane: ReferencePlaneState,
        outputWidth: Int,
        outputHeight: Int,
        fps: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        preserveAlpha: Bool,
        padToEven: Bool,
        qualityScale: Double,
        colorProfile: VideoColorProfile,
        sessionID: String,
        recordDiagnostics: Bool
    ) async throws {
        let totalOutputFrames = max(1, legacyPlan.localFrameCount + legacyPlan.workerFrameCount)
        let chunkQueue = DynamicDistributedChunkQueue(
            totalFrames: totalOutputFrames,
            chunkSize: dynamicDistributedChunkSize(
                totalFrames: totalOutputFrames,
                activeNodeCount: workerTargets.count + 1
            )
        )
        let sourceFileHash = workerTargets.first?.sourceFileHash ?? "-"
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ChronoVolumeDistributed", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let axisToken = mode == .plane ? "plane" : (axis == .x ? "x" : "y")

        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "动态调度",
                role: "cluster",
                state: "preparing",
                progress: 0.0,
                message: "已切成 \(chunkQueue.initialChunkCount) 个 chunk"
            )
            model.updateDistributedStatusBar(settings: settings, title: "动态分布式导出开始")
        }
        await syncDistributedProgress(settings: settings, workerTargets: workerTargets, title: "动态分布式导出开始")

        let workerWarmupTasks: [String: Task<String?, Never>] = Dictionary(
            uniqueKeysWithValues: workerTargets.map { target in
                (
                    target.nodeID,
                    Task.detached(priority: .userInitiated) {
                        do {
                            let initialPrepare = try await DistributedExportCoordinator.startWorkerSourcePrepare(
                                workerURL: target.workerURL,
                                sourceURL: sourceURL,
                                sourceHash: target.sourceFileHash,
                                workerLocalSourcePath: target.workerLocalPath,
                                sourceWidth: sourceWidth,
                                sourceHeight: sourceHeight,
                                sourceFrameCount: sourceFrameCount
                            )

                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: target.nodeID,
                                    displayName: target.displayName,
                                    role: "worker",
                                    state: "preparing",
                                    progress: min(0.08, initialPrepare.progress * 0.08),
                                    message: initialPrepare.message
                                )
                            }

                            let prepareResult: DistributedPrepareSourceResponse
                            if initialPrepare.state == "ready" || initialPrepare.state == "failed" {
                                prepareResult = initialPrepare
                            } else {
                                prepareResult = try await DistributedExportCoordinator.pollWorkerSourcePrepare(
                                    workerURL: target.workerURL,
                                    sourceHash: target.sourceFileHash,
                                    onProgress: { progress in
                                        await MainActor.run {
                                            settings.updateProgressItem(
                                                nodeID: target.nodeID,
                                                displayName: target.displayName,
                                                role: "worker",
                                                state: "preparing",
                                                progress: min(0.08, progress.progress * 0.08),
                                                message: progress.message
                                            )
                                        }
                                    }
                                )
                            }

                            if prepareResult.state == "ready", let rawPath = prepareResult.rawCachePath {
                                await MainActor.run {
                                    settings.updateProgressItem(
                                        nodeID: target.nodeID,
                                        displayName: target.displayName,
                                        role: "worker",
                                        state: "preparing",
                                        progress: 0.08,
                                        message: "Worker 预热完成"
                                    )
                                }
                                return rawPath
                            }

                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: target.nodeID,
                                    displayName: target.displayName,
                                    role: "worker",
                                    state: "running",
                                    progress: 0.08,
                                    message: "Worker 预热失败，将回退到普通分段：\(prepareResult.error ?? prepareResult.message)"
                                )
                            }
                            return nil
                        } catch {
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: target.nodeID,
                                    displayName: target.displayName,
                                    role: "worker",
                                    state: "running",
                                    progress: 0.08,
                                    message: "Worker 预热不可用，将回退到普通分段：\(error.localizedDescription)"
                                )
                            }
                            return nil
                        }
                    }
                )
            }
        )

        final class TimingDetailBox: @unchecked Sendable {
            var value: String = "-"
        }

        let hostTask = Task.detached(priority: .userInitiated) {
            let hostDetailBox = TimingDetailBox()
            let hostPreparedRawCacheURL = tempDir.appendingPathComponent(
                "host_\(sourceFileHash)_\(sourceWidth)x\(sourceHeight)x\(sourceFrameCount).rawframes"
            )
            let hostRawStart = Date()
            let hostRawCacheURL = try VideoExportHelper.prepareDistributedRawFrameCache(
                sourceURL: sourceURL,
                outputURL: hostPreparedRawCacheURL,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                progress: { p, text in
                    Task {
                        await MainActor.run {
                            settings.updateProgressItem(
                                nodeID: "host",
                                displayName: "本机",
                                role: "host",
                                state: "preparing",
                                progress: min(0.08, p * 0.08),
                                message: text ?? "正在建立本机 raw cache"
                            )
                            model.updateDistributedStatusBar(settings: settings, title: "本机正在预热导出缓存")
                        }
                    }
                }
            )
            let hostRawDuration = secondsSince(hostRawStart)

            for task in workerWarmupTasks.values {
                _ = await task.value
            }

            while let chunk = await chunkQueue.nextChunk() {
                let localSegmentURL = tempDir.appendingPathComponent(
                    "segment_\(String(format: "%04d", chunk.index))_host_\(axisToken)_\(chunk.startFrame)_\(chunk.endFrame).mov"
                )
                let hostRenderStart = Date()
                let progressHandler: ExportProgressHandler = { p, text in
                        if let text {
                            hostDetailBox.value = text
                        }
                        Task {
                            let progressSnapshot = await chunkQueue.updateInFlightProgress(
                                nodeID: "host",
                                currentChunk: chunk,
                                currentProgress: p
                            )
                            let renderElapsed = secondsSince(hostRenderStart)
                            let renderedFrames = Int((Double(chunk.frameCount) * p).rounded())
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: "host",
                                    displayName: "本机",
                                    role: "host",
                                    state: "running",
                                    progress: progressSnapshot.nodeProgress,
                                    message: "chunk \(chunk.index + 1)：\(text ?? "处理中")",
                                    timingText: "raw \(durationText(hostRawDuration))｜当前 chunk 渲染 \(durationText(renderElapsed))｜\(fpsText(frames: renderedFrames, seconds: renderElapsed))｜详情 \(hostDetailBox.value)"
                                )
                                settings.updateProgressItem(
                                    nodeID: "cluster",
                                    displayName: "动态调度",
                                    role: "cluster",
                                    state: "running",
                                    progress: progressSnapshot.overallProgress,
                                    message: "本机 \(chunk.startFrame)...\(chunk.endFrame)"
                                )
                                model.updateDistributedStatusBar(settings: settings, title: "动态分布式导出中")
                            }
                            await syncDistributedProgress(settings: settings, workerTargets: workerTargets, title: "动态分布式导出中")
                        }
                }
                try VideoExportHelper.exportHighPrecisionDistributedSegment(
                    outputURL: localSegmentURL,
                    sourceURL: sourceURL,
                    mode: mode,
                    axis: axis,
                    referencePlane: referencePlane,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    sourceFrameCount: sourceFrameCount,
                    fps: fps,
                    preserveAlpha: preserveAlpha,
                    padToEven: padToEven,
                    qualityScale: qualityScale,
                    outputStartFrame: chunk.startFrame,
                    outputEndFrame: chunk.endFrame,
                    preparedRawCacheURL: hostRawCacheURL,
                    colorProfile: colorProfile,
                    progress: progressHandler
                )

                await chunkQueue.markCompleted(nodeID: "host", chunk: chunk, segmentURL: localSegmentURL)
            }

            let finalHostProgress = await chunkQueue.nodeAndOverallProgress(nodeID: "host")
            await MainActor.run {
                settings.updateProgressItem(
                    nodeID: "host",
                    displayName: "本机",
                    role: "host",
                    state: "completed",
                    progress: finalHostProgress.nodeProgress,
                    message: "本机暂无更多 chunk",
                    timingText: "raw \(durationText(hostRawDuration))｜详情 \(hostDetailBox.value)"
                )
            }
        }

        let workerTasks = workerTargets.map { target in
            Task.detached(priority: .userInitiated) {
                let preparedRawCachePath = await workerWarmupTasks[target.nodeID]?.value
                let workerBatchSize = dynamicWorkerBatchSize(totalFrames: totalOutputFrames)
                let workerRouteBox = TimingDetailBox()

                while true {
                    let batchChunks = await chunkQueue.nextChunks(maxCount: workerBatchSize)
                    guard !batchChunks.isEmpty else { break }

                    let workerJobs = batchChunks.map { chunk in
                        DistributedExportCoordinator.buildWorkerJob(
                            sourceURL: sourceURL,
                            mode: mode,
                            axis: axis,
                            referencePlane: referencePlane,
                            totalOutputFrames: totalOutputFrames,
                            sourceWidth: sourceWidth,
                            sourceHeight: sourceHeight,
                            sourceFrameCount: sourceFrameCount,
                            outputWidth: outputWidth,
                            outputHeight: outputHeight,
                            fps: fps,
                            preserveAlpha: preserveAlpha,
                            padToEven: padToEven,
                            qualityScale: qualityScale,
                            rangeStart: chunk.startFrame,
                            rangeEnd: chunk.endFrame,
                            colorProfile: colorProfile,
                            sourceFileHash: target.sourceFileHash
                        )
                    }
                    let batchID = UUID()
                    let chunkByJobID = Dictionary(uniqueKeysWithValues: zip(workerJobs.map(\.jobID), batchChunks))

                    let remoteRenderStart = Date()
                    try await DistributedExportCoordinator.startRemoteWorkerJobBatch(
                        workerURL: target.workerURL,
                        batchID: batchID,
                        jobs: workerJobs,
                        workerLocalSourcePath: target.workerLocalPath,
                        preparedRawCachePath: preparedRawCachePath
                    )

                    let remoteBatchResult = try await DistributedExportCoordinator.pollRemoteWorkerJobBatch(
                        workerURL: target.workerURL,
                        batchID: batchID,
                        onProgress: { progress in
                            if progress.message.contains("upload ")
                                || progress.message.contains("高精度") {
                                workerRouteBox.value = progress.message
                            }
                            let currentChunk = progress.currentJobID.flatMap { chunkByJobID[$0] }
                            let progressSnapshot = await chunkQueue.updateBatchInFlightProgress(
                                nodeID: target.nodeID,
                                chunks: batchChunks,
                                batchProgress: progress.progress
                            )
                            let renderElapsed = secondsSince(remoteRenderStart)
                            let batchFrames = batchChunks.reduce(0) { $0 + $1.frameCount }
                            let renderedFrames = Int((Double(batchFrames) * progress.progress).rounded())
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: target.nodeID,
                                    displayName: target.displayName,
                                    role: "worker",
                                    state: progress.state,
                                    progress: progressSnapshot.nodeProgress,
                                    message: "批量 \(batchChunks.count) 个 chunk：\(Int(progress.progress * 100))%｜\(progress.message)",
                                    timingText: "当前批渲染 \(durationText(renderElapsed))｜\(fpsText(frames: renderedFrames, seconds: renderElapsed))｜详情 \(workerRouteBox.value)"
                                )
                                settings.updateProgressItem(
                                    nodeID: "cluster",
                                    displayName: "动态调度",
                                    role: "cluster",
                                    state: "running",
                                    progress: progressSnapshot.overallProgress,
                                    message: currentChunk.map { "\(target.displayName) \($0.startFrame)...\($0.endFrame)" } ?? "\(target.displayName) 批量 chunk"
                                )
                                model.updateDistributedStatusBar(settings: settings, title: "动态分布式导出中")
                            }
                            await syncDistributedProgress(settings: settings, workerTargets: workerTargets, title: "动态分布式导出中")
                        }
                    )

                    guard remoteBatchResult.state == "completed" else {
                        throw DistributedCoordinatorError.remoteResultFailed(remoteBatchResult.error ?? remoteBatchResult.state)
                    }

                    for remoteResult in remoteBatchResult.results {
                        guard remoteResult.state == "completed",
                              let chunk = chunkByJobID[remoteResult.jobID] else {
                            throw DistributedCoordinatorError.remoteResultFailed(remoteResult.error ?? remoteResult.state)
                        }

                        let remoteDownloadedURL = tempDir.appendingPathComponent(
                            "segment_\(String(format: "%04d", chunk.index))_\(target.nodeID)_\(axisToken)_\(chunk.startFrame)_\(chunk.endFrame).mov"
                        )

                        try await DistributedExportCoordinator.downloadRemoteWorkerSegment(
                            workerURL: target.workerURL,
                            jobID: remoteResult.jobID,
                            to: remoteDownloadedURL
                        )
                        await chunkQueue.markCompleted(nodeID: target.nodeID, chunk: chunk, segmentURL: remoteDownloadedURL)
                    }
                }

                let finalWorkerProgress = await chunkQueue.nodeAndOverallProgress(nodeID: target.nodeID)
                await MainActor.run {
                    settings.updateProgressItem(
                        nodeID: target.nodeID,
                        displayName: target.displayName,
                        role: "worker",
                        state: "completed",
                        progress: finalWorkerProgress.nodeProgress,
                        message: "Worker 暂无更多 chunk",
                        timingText: "详情 \(workerRouteBox.value)"
                    )
                }
            }
        }

        do {
            try await hostTask.value
            for task in workerTasks {
                try await task.value
            }
        } catch {
            hostTask.cancel()
            workerTasks.forEach { $0.cancel() }
            throw error
        }

        let segments = await chunkQueue.sortedSegmentURLs()
        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "动态调度",
                role: "cluster",
                state: "stitching",
                progress: 1.0,
                message: "正在拼接 \(segments.count) 个 chunk"
            )
            model.updateDistributedStatusBar(settings: settings, title: "正在拼接动态 chunk")
        }
        await syncDistributedProgress(settings: settings, workerTargets: workerTargets, title: "正在拼接动态 chunk")

        try await SegmentStitcher.stitch(segmentURLs: segments, outputURL: finalOutputURL)

        await MainActor.run {
            settings.updateProgressItem(nodeID: "host", displayName: "本机", role: "host", state: "completed", progress: 1.0, message: "完成")
            for target in workerTargets {
                settings.updateProgressItem(nodeID: target.nodeID, displayName: target.displayName, role: "worker", state: "completed", progress: 1.0, message: "完成")
            }
            settings.updateProgressItem(nodeID: "cluster", displayName: "动态调度", role: "cluster", state: "completed", progress: 1.0, message: "完成")
            model.updateDistributedStatusBar(settings: settings, title: "分布式导出完成")
        }
        await syncDistributedProgress(settings: settings, workerTargets: workerTargets, title: "分布式导出完成")

        if recordDiagnostics {
            let counts = await chunkQueue.completedFrameCounts()
            let dynamicAllocations = ([DistributedExportDiagnosticsAllocation(
                nodeID: "host",
                displayName: "本机",
                role: "host",
                startFrame: -1,
                endFrame: -1,
                frameCount: counts["host", default: 0]
            )] + workerTargets.map { target in
                DistributedExportDiagnosticsAllocation(
                    nodeID: target.nodeID,
                    displayName: target.displayName,
                    role: "worker",
                    startFrame: -1,
                    endFrame: -1,
                    frameCount: counts[target.nodeID, default: 0]
                )
            })
            await writeDistributedExportDiagnostics(
                settings: settings,
                model: model,
                finalOutputURL: finalOutputURL,
                sourceURL: sourceURL,
                sourceFileHash: sourceFileHash,
                sessionID: sessionID,
                title: "分布式导出完成",
                plan: legacyPlan,
                allocations: dynamicAllocations,
                axis: axisToken,
                fps: fps,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                preserveAlpha: preserveAlpha,
                padToEven: padToEven,
                qualityScale: qualityScale
            )
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    nonisolated private static func runBalancedFixedDistributedExport(
        settings: DistributedExportSettings,
        model: AppModel,
        sourceURL: URL,
        workerURL: URL,
        finalOutputURL: URL,
        plan: DistributedSplitPlan,
        axis: PlaybackAxis,
        fps: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        preserveAlpha: Bool,
        padToEven: Bool,
        qualityScale: Double,
        sourceFileHash: String,
        workerLocalPath: String,
        sessionID: String,
        recordDiagnostics: Bool
    ) async throws {
        let totalOutputFrames = max(1, plan.localFrameCount + plan.workerFrameCount)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ChronoVolumeDistributed", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)

        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        let axisToken = axis == .x ? "x" : "y"
        let workerDisplayName = await MainActor.run {
            settings.workerName == "-" ? "Worker" : settings.workerName
        }

        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "固定分工",
                role: "cluster",
                state: "preparing",
                progress: 0.0,
                message: "本机 \(plan.localFrameCount) 帧｜Worker \(plan.workerFrameCount) 帧"
            )
            model.updateDistributedStatusBar(
                settings: settings,
                title: "固定分工导出开始"
            )
        }
        await syncDynamicDistributedProgress(
            settings: settings,
            workerURL: workerURL,
            title: "固定分工导出开始"
        )

        let workerWarmupTask: Task<String?, Never>? = plan.workerFrameCount > 0
            ? Task.detached(priority: .userInitiated) {
                let workerWarmupStart = Date()
                do {
                    let initialPrepare = try await DistributedExportCoordinator.startWorkerSourcePrepare(
                        workerURL: workerURL,
                        sourceURL: sourceURL,
                        sourceHash: sourceFileHash,
                        workerLocalSourcePath: workerLocalPath,
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight,
                        sourceFrameCount: sourceFrameCount
                    )

                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "worker-0",
                            displayName: workerDisplayName,
                            role: "worker",
                            state: "preparing",
                            progress: min(0.08, initialPrepare.progress * 0.08),
                            message: initialPrepare.message
                        )
                        model.updateDistributedStatusBar(
                            settings: settings,
                            title: "Worker 正在预热导出缓存"
                        )
                    }

                    let prepareResult: DistributedPrepareSourceResponse
                    if initialPrepare.state == "ready" || initialPrepare.state == "failed" {
                        prepareResult = initialPrepare
                    } else {
                        prepareResult = try await DistributedExportCoordinator.pollWorkerSourcePrepare(
                            workerURL: workerURL,
                            sourceHash: sourceFileHash,
                            onProgress: { progress in
                                await MainActor.run {
                                    settings.updateProgressItem(
                                        nodeID: "worker-0",
                                        displayName: workerDisplayName,
                                        role: "worker",
                                        state: "preparing",
                                        progress: min(0.08, progress.progress * 0.08),
                                        message: progress.message
                                    )
                                    model.updateDistributedStatusBar(
                                        settings: settings,
                                        title: "Worker 正在预热导出缓存"
                                    )
                                }
                            }
                        )
                    }

                    if prepareResult.state == "ready", let rawPath = prepareResult.rawCachePath {
                        let warmupDuration = secondsSince(workerWarmupStart)
                        await MainActor.run {
                            settings.updateProgressItem(
                                nodeID: "worker-0",
                                displayName: workerDisplayName,
                                role: "worker",
                                state: "preparing",
                                progress: 0.08,
                                message: "Worker 预热完成",
                                timingText: "Worker 预热 \(durationText(warmupDuration))"
                            )
                        }
                        return rawPath
                    }

                    let warmupDuration = secondsSince(workerWarmupStart)
                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "worker-0",
                            displayName: workerDisplayName,
                            role: "worker",
                            state: "running",
                            progress: 0.08,
                            message: "Worker 预热失败，将回退到普通分段：\(prepareResult.error ?? prepareResult.message)",
                            timingText: "Worker 预热 \(durationText(warmupDuration))"
                        )
                    }
                    return nil
                } catch {
                    let warmupDuration = secondsSince(workerWarmupStart)
                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "worker-0",
                            displayName: workerDisplayName,
                            role: "worker",
                            state: "running",
                            progress: 0.08,
                            message: "Worker 预热不可用，将回退到普通分段：\(error.localizedDescription)",
                            timingText: "Worker 预热 \(durationText(warmupDuration))"
                        )
                    }
                    return nil
                }
            }
            : nil

        final class TimingDetailBox: @unchecked Sendable {
            var value: String = "-"
        }

        let hostTask: Task<(Int, URL)?, Error>? = plan.localFrameCount > 0
            ? Task.detached(priority: .userInitiated) {
                let hostDetailBox = TimingDetailBox()
                let hostPreparedRawCacheURL = tempDir.appendingPathComponent(
                    "host_\(sourceFileHash)_\(sourceWidth)x\(sourceHeight)x\(sourceFrameCount).rawframes"
                )
                let hostRawStart = Date()
                let hostRawCacheURL = try VideoExportHelper.prepareDistributedRawFrameCache(
                    sourceURL: sourceURL,
                    outputURL: hostPreparedRawCacheURL,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    sourceFrameCount: sourceFrameCount,
                    progress: { p, text in
                        Task {
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: "host",
                                    displayName: "本机",
                                    role: "host",
                                    state: "preparing",
                                    progress: min(0.08, p * 0.08),
                                    message: text ?? "正在建立本机 raw cache"
                                )
                                model.updateDistributedStatusBar(
                                    settings: settings,
                                    title: "本机正在预热导出缓存"
                                )
                            }
                        }
                    }
                )
                let hostRawDuration = secondsSince(hostRawStart)

                if let workerWarmupTask {
                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "host",
                            displayName: "本机",
                            role: "host",
                            state: "waiting",
                            progress: 0.08,
                            message: "等待 Worker 完成预热后同步开跑"
                        )
                    }
                    _ = await workerWarmupTask.value
                }

                let localSegmentURL = tempDir.appendingPathComponent(
                    "segment_0000_host_\(axisToken)_\(plan.localStartFrame)_\(plan.localEndFrame).mov"
                )

                let hostRenderStart = Date()
                try VideoExportHelper.exportHighPrecisionDistributedSegment(
                    outputURL: localSegmentURL,
                    sourceURL: sourceURL,
                    axis: axis,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    sourceFrameCount: sourceFrameCount,
                    fps: fps,
                    preserveAlpha: preserveAlpha,
                    padToEven: padToEven,
                    qualityScale: qualityScale,
                    outputStartFrame: plan.localStartFrame,
                    outputEndFrame: plan.localEndFrame,
                    preparedRawCacheURL: hostRawCacheURL,
                    progress: { p, text in
                        if let text {
                            hostDetailBox.value = text
                        }
                        Task {
                            let renderElapsed = secondsSince(hostRenderStart)
                            let renderedFrames = Int((Double(plan.localFrameCount) * p).rounded())
                            let weighted = Double(plan.localFrameCount) * p / Double(totalOutputFrames)
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: "host",
                                    displayName: "本机",
                                    role: "host",
                                    state: "running",
                                    progress: p,
                                    message: text ?? "处理中",
                                    timingText: "raw \(durationText(hostRawDuration))｜渲染 \(durationText(renderElapsed))｜\(fpsText(frames: renderedFrames, seconds: renderElapsed))"
                                )
                                settings.updateProgressItem(
                                    nodeID: "cluster",
                                    displayName: "固定分工",
                                    role: "cluster",
                                    state: "running",
                                    progress: weighted,
                                    message: "本机 \(plan.localStartFrame)...\(plan.localEndFrame)"
                                )
                                model.updateDistributedStatusBar(
                                    settings: settings,
                                    title: "固定分工导出中"
                                )
                            }
                            await syncDynamicDistributedProgress(
                                settings: settings,
                                workerURL: workerURL,
                                title: "固定分工导出中"
                            )
                        }
                    }
                )
                let hostRenderDuration = secondsSince(hostRenderStart)

                await MainActor.run {
                    settings.updateProgressItem(
                        nodeID: "host",
                        displayName: "本机",
                        role: "host",
                        state: "completed",
                        progress: 1.0,
                        message: "本机分段完成",
                        timingText: "raw \(durationText(hostRawDuration))｜渲染 \(durationText(hostRenderDuration))｜\(fpsText(frames: plan.localFrameCount, seconds: hostRenderDuration))｜详情 \(hostDetailBox.value)"
                    )
                }
                return (plan.localStartFrame, localSegmentURL)
            }
            : nil

        let workerTask: Task<(Int, URL)?, Error>? = plan.workerFrameCount > 0
            ? Task.detached(priority: .userInitiated) {
                let workerWarmupWaitStart = Date()
                let preparedRawCachePath = await workerWarmupTask?.value
                let workerWarmupWaitDuration = secondsSince(workerWarmupWaitStart)
                let workerRouteBox = TimingDetailBox()
                let workerJob = DistributedExportCoordinator.buildWorkerJob(
                    sourceURL: sourceURL,
                    axis: axis,
                    totalOutputFrames: totalOutputFrames,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    sourceFrameCount: sourceFrameCount,
                    fps: fps,
                    preserveAlpha: preserveAlpha,
                    padToEven: padToEven,
                    qualityScale: qualityScale,
                    rangeStart: plan.workerStartFrame,
                    rangeEnd: plan.workerEndFrame,
                    sourceFileHash: sourceFileHash
                )

                let workerRemoteRenderStart = Date()
                try await DistributedExportCoordinator.startRemoteWorkerJob(
                    workerURL: workerURL,
                    job: workerJob,
                    workerLocalSourcePath: workerLocalPath,
                    preparedRawCachePath: preparedRawCachePath
                )

                let remoteResult = try await DistributedExportCoordinator.pollRemoteWorkerJob(
                    workerURL: workerURL,
                    jobID: workerJob.jobID,
                    onProgress: { progress in
                        workerRouteBox.value = progress.message
                        let renderElapsed = secondsSince(workerRemoteRenderStart)
                        let renderedFrames = Int((Double(plan.workerFrameCount) * progress.progress).rounded())
                        let weighted = Double(plan.workerFrameCount) * progress.progress / Double(totalOutputFrames)
                        let hostDone = await MainActor.run {
                            settings.progressItems.first { $0.nodeID == "host" }?.progress ?? 0.0
                        }
                        let hostWeighted = Double(plan.localFrameCount) * hostDone / Double(totalOutputFrames)
                        await MainActor.run {
                            settings.updateProgressItem(
                                nodeID: "worker-0",
                                displayName: workerDisplayName,
                                role: "worker",
                                state: progress.state,
                                progress: progress.progress,
                                message: progress.message,
                                timingText: "预热等待 \(durationText(workerWarmupWaitDuration))｜远程渲染 \(durationText(renderElapsed))｜\(fpsText(frames: renderedFrames, seconds: renderElapsed))"
                            )
                            settings.updateProgressItem(
                                nodeID: "cluster",
                                displayName: "固定分工",
                                role: "cluster",
                                state: "running",
                                progress: min(1.0, hostWeighted + weighted),
                                message: "Worker \(plan.workerStartFrame)...\(plan.workerEndFrame)"
                            )
                            model.updateDistributedStatusBar(
                                settings: settings,
                                title: "固定分工导出中"
                            )
                        }
                        await syncDynamicDistributedProgress(
                            settings: settings,
                            workerURL: workerURL,
                            title: "固定分工导出中"
                        )
                    }
                )
                let workerRemoteRenderDuration = secondsSince(workerRemoteRenderStart)

                guard remoteResult.state == "completed" else {
                    throw DistributedCoordinatorError.remoteResultFailed(
                        remoteResult.error ?? remoteResult.state
                    )
                }

                let remoteDownloadedURL = tempDir.appendingPathComponent(
                    "segment_0001_worker_\(axisToken)_\(plan.workerStartFrame)_\(plan.workerEndFrame).mov"
                )
                let workerDownloadStart = Date()
                try await DistributedExportCoordinator.downloadRemoteWorkerSegment(
                    workerURL: workerURL,
                    jobID: workerJob.jobID,
                    to: remoteDownloadedURL
                )
                let workerDownloadDuration = secondsSince(workerDownloadStart)

                await MainActor.run {
                    settings.updateProgressItem(
                        nodeID: "worker-0",
                        displayName: workerDisplayName,
                        role: "worker",
                        state: "completed",
                        progress: 1.0,
                        message: "Worker 分段完成：\(workerRouteBox.value)",
                        timingText: "预热等待 \(durationText(workerWarmupWaitDuration))｜远程渲染 \(durationText(workerRemoteRenderDuration))｜下载 \(durationText(workerDownloadDuration))｜\(fpsText(frames: plan.workerFrameCount, seconds: workerRemoteRenderDuration))｜详情 \(workerRouteBox.value)"
                    )
                }
                return (plan.workerStartFrame, remoteDownloadedURL)
            }
            : nil

        let hostResult: (Int, URL)?
        let workerResult: (Int, URL)?
        do {
            hostResult = try await hostTask?.value
            workerResult = try await workerTask?.value
        } catch {
            hostTask?.cancel()
            workerTask?.cancel()
            throw error
        }

        let segments = [hostResult, workerResult]
            .compactMap { $0 }
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "固定分工",
                role: "cluster",
                state: "stitching",
                progress: 1.0,
                message: "正在拼接 \(segments.count) 个分段"
            )
            model.updateDistributedStatusBar(
                settings: settings,
                title: "正在拼接固定分段"
            )
        }
        await syncDynamicDistributedProgress(
            settings: settings,
            workerURL: workerURL,
            title: "正在拼接固定分段"
        )

        try await SegmentStitcher.stitch(
            segmentURLs: segments,
            outputURL: finalOutputURL
        )

        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "host",
                displayName: "本机",
                role: "host",
                state: plan.localFrameCount > 0 ? "completed" : "skipped",
                progress: 1.0,
                message: plan.localFrameCount > 0 ? "完成" : "本机未分配分段"
            )
            settings.updateProgressItem(
                nodeID: "worker-0",
                displayName: workerDisplayName,
                role: "worker",
                state: "completed",
                progress: 1.0,
                message: "完成"
            )
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "固定分工",
                role: "cluster",
                state: "completed",
                progress: 1.0,
                message: "完成"
            )
            model.updateDistributedStatusBar(
                settings: settings,
                title: "分布式导出完成"
            )
        }
        await syncDynamicDistributedProgress(
            settings: settings,
            workerURL: workerURL,
            title: "分布式导出完成"
        )

        if recordDiagnostics {
            await writeDistributedExportDiagnostics(
                settings: settings,
                model: model,
                finalOutputURL: finalOutputURL,
                sourceURL: sourceURL,
                sourceFileHash: sourceFileHash,
                sessionID: sessionID,
                title: "分布式导出完成",
                plan: plan,
                axis: axis.rawValue,
                fps: fps,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceFrameCount: sourceFrameCount,
                preserveAlpha: preserveAlpha,
                padToEven: padToEven,
                qualityScale: qualityScale
            )
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    nonisolated private static func runDynamicDistributedExport(
        settings: DistributedExportSettings,
        model: AppModel,
        sourceURL: URL,
        workerURL: URL,
        finalOutputURL: URL,
        plan: DistributedSplitPlan,
        axis: PlaybackAxis,
        fps: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceFrameCount: Int,
        preserveAlpha: Bool,
        padToEven: Bool,
        qualityScale: Double,
        sourceFileHash: String,
        workerLocalPath: String,
        sessionID: String
    ) async throws {
        let totalOutputFrames = plan.localFrameCount + plan.workerFrameCount
        let chunkQueue = DynamicDistributedChunkQueue(
            totalFrames: totalOutputFrames,
            chunkSize: dynamicDistributedChunkSize(totalFrames: totalOutputFrames)
        )

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ChronoVolumeDistributed", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)

        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        let axisToken = axis == .x ? "x" : "y"

        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "动态调度",
                role: "cluster",
                state: "running",
                progress: 0.0,
                message: "已切成 \(chunkQueue.initialChunkCount) 个 chunk"
            )
            model.updateDistributedStatusBar(
                settings: settings,
                title: "动态分布式导出开始"
            )
        }
        await syncDynamicDistributedProgress(
            settings: settings,
            workerURL: workerURL,
            title: "动态分布式导出开始"
        )

        let workerWarmupTask: Task<String?, Never>? = plan.workerFrameCount > 0
            ? Task.detached(priority: .userInitiated) {
                do {
                    let initialPrepare = try await DistributedExportCoordinator.startWorkerSourcePrepare(
                        workerURL: workerURL,
                        sourceURL: sourceURL,
                        sourceHash: sourceFileHash,
                        workerLocalSourcePath: workerLocalPath,
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight,
                        sourceFrameCount: sourceFrameCount
                    )

                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "worker-0",
                            displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                            role: "worker",
                            state: "preparing",
                            progress: min(0.08, initialPrepare.progress * 0.08),
                            message: initialPrepare.message
                        )
                        model.updateDistributedStatusBar(
                            settings: settings,
                            title: "Worker 正在预热导出缓存"
                        )
                    }

                    let prepareResult: DistributedPrepareSourceResponse
                    if initialPrepare.state == "ready" || initialPrepare.state == "failed" {
                        prepareResult = initialPrepare
                    } else {
                        prepareResult = try await DistributedExportCoordinator.pollWorkerSourcePrepare(
                            workerURL: workerURL,
                            sourceHash: sourceFileHash,
                            onProgress: { progress in
                                await MainActor.run {
                                    settings.updateProgressItem(
                                        nodeID: "worker-0",
                                        displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                                        role: "worker",
                                        state: "preparing",
                                        progress: min(0.08, progress.progress * 0.08),
                                        message: progress.message
                                    )
                                    model.updateDistributedStatusBar(
                                        settings: settings,
                                        title: "Worker 正在预热导出缓存"
                                    )
                                }
                            }
                        )
                    }

                    if prepareResult.state == "ready", let rawPath = prepareResult.rawCachePath {
                        return rawPath
                    }

                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "worker-0",
                            displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                            role: "worker",
                            state: "running",
                            progress: 0.08,
                            message: "Worker 预热失败，将回退到普通分段：\(prepareResult.error ?? prepareResult.message)"
                        )
                    }
                    return nil
                } catch {
                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "worker-0",
                            displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                            role: "worker",
                            state: "running",
                            progress: 0.08,
                            message: "Worker 预热不可用，将回退到普通分段：\(error.localizedDescription)"
                        )
                    }
                    return nil
                }
            }
            : nil

        let hostTask: Task<Void, Error>? = plan.localFrameCount > 0
            ? Task.detached(priority: .userInitiated) {
                let hostPreparedRawCacheURL = tempDir.appendingPathComponent(
                    "host_\(sourceFileHash)_\(sourceWidth)x\(sourceHeight)x\(sourceFrameCount).rawframes"
                )

                let hostRawCacheURL = try VideoExportHelper.prepareDistributedRawFrameCache(
                    sourceURL: sourceURL,
                    outputURL: hostPreparedRawCacheURL,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    sourceFrameCount: sourceFrameCount,
                    progress: { p, text in
                        Task {
                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: "host",
                                    displayName: "本机",
                                    role: "host",
                                    state: "preparing",
                                    progress: min(0.08, p * 0.08),
                                    message: text ?? "正在建立本机 raw cache"
                                )
                                model.updateDistributedStatusBar(
                                    settings: settings,
                                    title: "本机正在预热导出缓存"
                                )
                            }
                        }
                    }
                )

                if let workerWarmupTask {
                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "host",
                            displayName: "本机",
                            role: "host",
                            state: "waiting",
                            progress: 0.08,
                            message: "等待 Worker 完成预热后同步开跑"
                        )
                        model.updateDistributedStatusBar(
                            settings: settings,
                            title: "等待 Worker 预热完成"
                        )
                    }
                    _ = await workerWarmupTask.value
                }

                while let chunk = await chunkQueue.nextChunk() {
                    let localSegmentURL = tempDir.appendingPathComponent(
                        "segment_\(String(format: "%04d", chunk.index))_host_\(axisToken)_\(chunk.startFrame)_\(chunk.endFrame).mov"
                    )

                    try VideoExportHelper.exportHighPrecisionDistributedSegment(
                        outputURL: localSegmentURL,
                        sourceURL: sourceURL,
                        axis: axis,
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight,
                        sourceFrameCount: sourceFrameCount,
                        fps: fps,
                        preserveAlpha: preserveAlpha,
                        padToEven: padToEven,
                        qualityScale: qualityScale,
                        outputStartFrame: chunk.startFrame,
                        outputEndFrame: chunk.endFrame,
                        preparedRawCacheURL: hostRawCacheURL,
                        progress: { p, text in
                            Task {
                                let progressSnapshot = await chunkQueue.updateInFlightProgress(
                                    nodeID: "host",
                                    currentChunk: chunk,
                                    currentProgress: p
                                )
                                await MainActor.run {
                                    settings.updateProgressItem(
                                        nodeID: "host",
                                        displayName: "本机",
                                        role: "host",
                                        state: "running",
                                        progress: progressSnapshot.nodeProgress,
                                        message: "chunk \(chunk.index + 1)：\(text ?? "处理中")"
                                    )
                                    settings.updateProgressItem(
                                        nodeID: "cluster",
                                        displayName: "动态调度",
                                        role: "cluster",
                                        state: "running",
                                        progress: progressSnapshot.overallProgress,
                                        message: "本机 \(chunk.startFrame)...\(chunk.endFrame)"
                                    )
                                    model.updateDistributedStatusBar(
                                        settings: settings,
                                        title: "动态分布式导出中"
                                    )
                                }
                                await syncDynamicDistributedProgress(
                                    settings: settings,
                                    workerURL: workerURL,
                                    title: "动态分布式导出中"
                                )
                            }
                        }
                    )

                    await chunkQueue.markCompleted(
                        nodeID: "host",
                        chunk: chunk,
                        segmentURL: localSegmentURL
                    )
                    let progressSnapshot = await chunkQueue.nodeAndOverallProgress(nodeID: "host")
                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "host",
                            displayName: "本机",
                            role: "host",
                            state: "running",
                            progress: progressSnapshot.nodeProgress,
                            message: "完成 chunk \(chunk.index + 1)"
                        )
                        settings.updateProgressItem(
                            nodeID: "cluster",
                            displayName: "动态调度",
                            role: "cluster",
                            state: "running",
                            progress: progressSnapshot.overallProgress,
                            message: "本机完成 \(chunk.startFrame)...\(chunk.endFrame)"
                        )
                    }
                    await syncDynamicDistributedProgress(
                        settings: settings,
                        workerURL: workerURL,
                        title: "动态分布式导出中"
                    )
                }

                let finalHostProgress = await chunkQueue.nodeAndOverallProgress(nodeID: "host")
                await MainActor.run {
                    settings.updateProgressItem(
                        nodeID: "host",
                        displayName: "本机",
                        role: "host",
                        state: "completed",
                        progress: finalHostProgress.nodeProgress,
                        message: "本机暂无更多 chunk"
                    )
                    model.updateDistributedStatusBar(
                        settings: settings,
                        title: "本机动态分段已完成"
                    )
                }
                await syncDynamicDistributedProgress(
                    settings: settings,
                    workerURL: workerURL,
                    title: "本机动态分段已完成"
                )
            }
            : nil

        let workerTask: Task<Void, Error>? = plan.workerFrameCount > 0
            ? Task.detached(priority: .userInitiated) {
                let preparedRawCachePath = await workerWarmupTask?.value

                let workerBatchSize = dynamicWorkerBatchSize(totalFrames: totalOutputFrames)
                while true {
                    let batchChunks = await chunkQueue.nextChunks(maxCount: workerBatchSize)
                    guard !batchChunks.isEmpty else { break }

                    let workerJobs = batchChunks.map { chunk in
                        DistributedExportCoordinator.buildWorkerJob(
                            sourceURL: sourceURL,
                            axis: axis,
                            totalOutputFrames: totalOutputFrames,
                            sourceWidth: sourceWidth,
                            sourceHeight: sourceHeight,
                            sourceFrameCount: sourceFrameCount,
                            fps: fps,
                            preserveAlpha: preserveAlpha,
                            padToEven: padToEven,
                            qualityScale: qualityScale,
                            rangeStart: chunk.startFrame,
                            rangeEnd: chunk.endFrame,
                            sourceFileHash: sourceFileHash
                        )
                    }
                    let batchID = UUID()
                    let chunkByJobID = Dictionary(uniqueKeysWithValues: zip(workerJobs.map(\.jobID), batchChunks))

                    try await DistributedExportCoordinator.startRemoteWorkerJobBatch(
                        workerURL: workerURL,
                        batchID: batchID,
                        jobs: workerJobs,
                        workerLocalSourcePath: workerLocalPath,
                        preparedRawCachePath: preparedRawCachePath
                    )

                    let remoteBatchResult = try await DistributedExportCoordinator.pollRemoteWorkerJobBatch(
                        workerURL: workerURL,
                        batchID: batchID,
                        onProgress: { progress in
                            let currentChunk = progress.currentJobID.flatMap { chunkByJobID[$0] }

                            let progressSnapshot = await chunkQueue.updateBatchInFlightProgress(
                                nodeID: "worker-0",
                                chunks: batchChunks,
                                batchProgress: progress.progress
                            )

                            await MainActor.run {
                                settings.updateProgressItem(
                                    nodeID: "worker-0",
                                    displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                                    role: "worker",
                                    state: progress.state,
                                    progress: progressSnapshot.nodeProgress,
                                    message: "连续批量 \(batchChunks.count) 个 chunk：\(Int(progress.progress * 100))%｜\(progress.message)"
                                )
                                settings.updateProgressItem(
                                    nodeID: "cluster",
                                    displayName: "动态调度",
                                    role: "cluster",
                                    state: "running",
                                    progress: progressSnapshot.overallProgress,
                                    message: currentChunk.map { "Worker \($0.startFrame)...\($0.endFrame)" } ?? "Worker 批量 chunk"
                                )
                                model.updateDistributedStatusBar(
                                    settings: settings,
                                    title: "动态分布式导出中"
                                )
                            }
                            await syncDynamicDistributedProgress(
                                settings: settings,
                                workerURL: workerURL,
                                title: "动态分布式导出中"
                            )
                        }
                    )

                    guard remoteBatchResult.state == "completed" else {
                        throw DistributedCoordinatorError.remoteResultFailed(
                            remoteBatchResult.error ?? remoteBatchResult.state
                        )
                    }

                    for remoteResult in remoteBatchResult.results {
                        guard remoteResult.state == "completed",
                              let chunk = chunkByJobID[remoteResult.jobID] else {
                            throw DistributedCoordinatorError.remoteResultFailed(
                                remoteResult.error ?? remoteResult.state
                            )
                        }

                        let remoteDownloadedURL = tempDir.appendingPathComponent(
                            "segment_\(String(format: "%04d", chunk.index))_worker_\(axisToken)_\(chunk.startFrame)_\(chunk.endFrame).mov"
                        )

                        let progressSnapshot = await chunkQueue.nodeAndOverallProgress(nodeID: "worker-0")
                        await MainActor.run {
                            settings.updateProgressItem(
                                nodeID: "worker-0",
                                displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                                role: "worker",
                                state: "downloading",
                                progress: progressSnapshot.nodeProgress,
                                message: "下载批量 chunk \(chunk.index + 1)"
                            )
                            settings.updateProgressItem(
                                nodeID: "cluster",
                                displayName: "动态调度",
                                role: "cluster",
                                state: "running",
                                progress: progressSnapshot.overallProgress,
                                message: "下载 Worker chunk \(chunk.index + 1)"
                            )
                            model.updateDistributedStatusBar(
                                settings: settings,
                                title: "Worker chunk 下载中"
                            )
                        }
                        await syncDynamicDistributedProgress(
                            settings: settings,
                            workerURL: workerURL,
                            title: "Worker chunk 下载中"
                        )

                        try await DistributedExportCoordinator.downloadRemoteWorkerSegment(
                            workerURL: workerURL,
                            jobID: remoteResult.jobID,
                            to: remoteDownloadedURL
                        )

                        await chunkQueue.markCompleted(
                            nodeID: "worker-0",
                            chunk: chunk,
                            segmentURL: remoteDownloadedURL
                        )
                    }

                    let completedProgressSnapshot = await chunkQueue.nodeAndOverallProgress(nodeID: "worker-0")
                    await MainActor.run {
                        settings.updateProgressItem(
                            nodeID: "worker-0",
                            displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                            role: "worker",
                            state: "running",
                            progress: completedProgressSnapshot.nodeProgress,
                            message: "完成一批 \(batchChunks.count) 个 chunk"
                        )
                        settings.updateProgressItem(
                            nodeID: "cluster",
                            displayName: "动态调度",
                            role: "cluster",
                            state: "running",
                            progress: completedProgressSnapshot.overallProgress,
                            message: "Worker 完成批量 chunk"
                        )
                    }
                    await syncDynamicDistributedProgress(
                        settings: settings,
                        workerURL: workerURL,
                        title: "动态分布式导出中"
                    )
                }

                let finalWorkerProgress = await chunkQueue.nodeAndOverallProgress(nodeID: "worker-0")
                await MainActor.run {
                    settings.updateProgressItem(
                        nodeID: "worker-0",
                        displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                        role: "worker",
                        state: "completed",
                        progress: finalWorkerProgress.nodeProgress,
                        message: "Worker 暂无更多 chunk"
                    )
                    model.updateDistributedStatusBar(
                        settings: settings,
                        title: "Worker 动态分段已完成"
                    )
                }
                await syncDynamicDistributedProgress(
                    settings: settings,
                    workerURL: workerURL,
                    title: "Worker 动态分段已完成"
                )
            }
            : nil

        if plan.localFrameCount <= 0 {
            await MainActor.run {
                settings.updateProgressItem(
                    nodeID: "host",
                    displayName: "本机",
                    role: "host",
                    state: "skipped",
                    progress: 1.0,
                    message: "本机未分配分段"
                )
                model.updateDistributedStatusBar(
                    settings: settings,
                    title: "本机无分段，等待 Worker"
                )
            }
            await syncDynamicDistributedProgress(
                settings: settings,
                workerURL: workerURL,
                title: "本机无分段，等待 Worker"
            )
        }

        do {
            try await hostTask?.value
            try await workerTask?.value
        } catch {
            hostTask?.cancel()
            workerTask?.cancel()
            throw error
        }

        let segments = await chunkQueue.sortedSegmentURLs()
        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "动态调度",
                role: "cluster",
                state: "stitching",
                progress: 1.0,
                message: "正在拼接 \(segments.count) 个 chunk"
            )
            model.updateDistributedStatusBar(
                settings: settings,
                title: "正在拼接动态 chunk"
            )
        }
        await syncDynamicDistributedProgress(
            settings: settings,
            workerURL: workerURL,
            title: "正在拼接动态 chunk"
        )

        try await SegmentStitcher.stitch(
            segmentURLs: segments,
            outputURL: finalOutputURL
        )

        await MainActor.run {
            settings.updateProgressItem(
                nodeID: "host",
                displayName: "本机",
                role: "host",
                state: "completed",
                progress: 1.0,
                message: "完成"
            )
            settings.updateProgressItem(
                nodeID: "worker-0",
                displayName: settings.workerName == "-" ? "Worker" : settings.workerName,
                role: "worker",
                state: "completed",
                progress: 1.0,
                message: "完成"
            )
            settings.updateProgressItem(
                nodeID: "cluster",
                displayName: "动态调度",
                role: "cluster",
                state: "completed",
                progress: 1.0,
                message: "完成"
            )
            model.updateDistributedStatusBar(
                settings: settings,
                title: "分布式导出完成"
            )
        }
        await syncDynamicDistributedProgress(
            settings: settings,
            workerURL: workerURL,
            title: "分布式导出完成"
        )

        try? FileManager.default.removeItem(at: tempDir)
    }
}

private struct DynamicDistributedChunk: Sendable {
    let index: Int
    let startFrame: Int
    let endFrame: Int

    var frameCount: Int {
        max(0, endFrame - startFrame + 1)
    }
}

private struct DynamicDistributedInFlight: Sendable {
    let chunkIndex: Int
    let frameCount: Int
    let progress: Double
}

private struct DynamicDistributedProgressSnapshot: Sendable {
    let nodeProgress: Double
    let overallProgress: Double
}

private actor DynamicDistributedChunkQueue {
    nonisolated let initialChunkCount: Int

    private let totalFrames: Int
    private let chunks: [DynamicDistributedChunk]
    private var nextIndex: Int = 0
    private var completedFramesByNode: [String: Int] = [:]
    private var completedFrames: Int = 0
    private var completedSegments: [(index: Int, url: URL)] = []
    private var completedChunkIndexes: Set<Int> = []
    private var inFlightByNode: [String: DynamicDistributedInFlight] = [:]

    init(totalFrames: Int, chunkSize: Int) {
        self.totalFrames = max(0, totalFrames)

        var built: [DynamicDistributedChunk] = []
        var start = 0
        var index = 0
        let safeChunkSize = max(1, chunkSize)

        while start < totalFrames {
            let end = min(totalFrames - 1, start + safeChunkSize - 1)
            built.append(
                DynamicDistributedChunk(
                    index: index,
                    startFrame: start,
                    endFrame: end
                )
            )
            index += 1
            start = end + 1
        }

        self.chunks = built
        self.initialChunkCount = built.count
    }

    func nextChunk() -> DynamicDistributedChunk? {
        guard nextIndex < chunks.count else { return nil }
        let chunk = chunks[nextIndex]
        nextIndex += 1
        return chunk
    }

    func nextChunks(maxCount: Int) -> [DynamicDistributedChunk] {
        guard maxCount > 0 else { return [] }

        var result: [DynamicDistributedChunk] = []
        while result.count < maxCount, nextIndex < chunks.count {
            result.append(chunks[nextIndex])
            nextIndex += 1
        }
        return result
    }

    func markCompleted(
        nodeID: String,
        chunk: DynamicDistributedChunk,
        segmentURL: URL
    ) {
        guard !completedChunkIndexes.contains(chunk.index) else { return }

        inFlightByNode.removeValue(forKey: nodeID)
        completedChunkIndexes.insert(chunk.index)
        completedFramesByNode[nodeID, default: 0] += chunk.frameCount
        completedFrames += chunk.frameCount
        completedSegments.append((index: chunk.index, url: segmentURL))
    }

    func updateInFlightProgress(
        nodeID: String,
        currentChunk: DynamicDistributedChunk? = nil,
        currentProgress: Double = 0.0
    ) -> DynamicDistributedProgressSnapshot {
        if
            let currentChunk,
            !completedChunkIndexes.contains(currentChunk.index)
        {
            inFlightByNode[nodeID] = DynamicDistributedInFlight(
                chunkIndex: currentChunk.index,
                frameCount: currentChunk.frameCount,
                progress: max(0.0, min(1.0, currentProgress))
            )
        }

        return nodeAndOverallProgress(nodeID: nodeID)
    }

    func updateBatchInFlightProgress(
        nodeID: String,
        chunks: [DynamicDistributedChunk],
        batchProgress: Double
    ) -> DynamicDistributedProgressSnapshot {
        let activeChunks = chunks.filter { !completedChunkIndexes.contains($0.index) }
        let frameCount = activeChunks.reduce(0) { $0 + $1.frameCount }
        if frameCount > 0 {
            inFlightByNode[nodeID] = DynamicDistributedInFlight(
                chunkIndex: activeChunks.first?.index ?? -1,
                frameCount: frameCount,
                progress: max(0.0, min(1.0, batchProgress))
            )
        }

        return nodeAndOverallProgress(nodeID: nodeID)
    }

    func nodeAndOverallProgress(nodeID: String) -> DynamicDistributedProgressSnapshot {
        let nodeCompleted = Double(completedFramesByNode[nodeID, default: 0])
        let nodeInFlight = inFlightByNode[nodeID].map {
            Double($0.frameCount) * $0.progress
        } ?? 0.0

        let overallInFlight = inFlightByNode.values.reduce(0.0) { partial, item in
            partial + Double(item.frameCount) * item.progress
        }

        return DynamicDistributedProgressSnapshot(
            nodeProgress: min(1.0, (nodeCompleted + nodeInFlight) / Double(max(1, totalFrames))),
            overallProgress: min(1.0, (Double(completedFrames) + overallInFlight) / Double(max(1, totalFrames)))
        )
    }

    func sortedSegmentURLs() -> [URL] {
        completedSegments
            .sorted { $0.index < $1.index }
            .map(\.url)
    }

    func completedFrameCounts() -> [String: Int] {
        completedFramesByNode
    }
}
