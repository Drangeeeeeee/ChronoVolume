import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum CameraControlLimits {
    static let angleRange: ClosedRange<Double> = -7200.0...7200.0
    static let positionRange: ClosedRange<Double> = -100.0...100.0
    static let focusRange: ClosedRange<Double> = -100.0...100.0
}

struct MainImportedVideo: Identifiable, Hashable, Sendable {
    struct RestorationResult: Sendable {
        let item: MainImportedVideo
        let pairingDiagnostic: String?
    }

    let id: UUID
    var sourcePair: VideoSourcePair
    var isAlphaCheater: Bool
    var pairingKey: String?
    var url: URL { sourcePair.colorURL }
    var name: String {
        if sourcePair.usesGeneratedWhiteColor {
            return sourcePair.alphaURL?.lastPathComponent ?? url.lastPathComponent
        }
        return url.lastPathComponent
    }
    var hasColorSource: Bool { !sourcePair.usesGeneratedWhiteColor }
    var hasAlphaSource: Bool { sourcePair.alphaURL != nil }
    var isModel: Bool { !isAlphaCheater && MeshVolumeLoader.isSupportedModelURL(url) }
    var pickerTitle: String {
        if isModel { return "\(name)（模型）" }
        guard isAlphaCheater else { return name }
        let state = hasColorSource && hasAlphaSource ? "A+B" : (hasColorSource ? "仅 A" : "仅 B · 白模")
        return "\(name)（AlphaCheater · \(state)）"
    }

    init(id: UUID, url: URL) {
        self.id = id
        self.isAlphaCheater = false
        self.pairingKey = nil
        let alphaURL = VideoSourcePairDiscovery.matchingAlphaURL(for: url)
        self.sourcePair = VideoSourcePair(
            colorURL: url,
            alphaURL: alphaURL,
            alphaSourceMode: alphaURL == nil ? .opaque : .external
        )
    }

    init(
        id: UUID,
        sourcePair: VideoSourcePair,
        isAlphaCheater: Bool = false,
        pairingKey: String? = nil
    ) {
        self.id = id
        self.sourcePair = sourcePair
        self.isAlphaCheater = isAlphaCheater
        self.pairingKey = isAlphaCheater
            ? (pairingKey ?? VideoSourcePairDiscovery.pairingKey(for: sourcePair))
            : nil
    }

    static func restoring(
        from record: ChronoVolumeProjectDocument.MainVideoRecord
    ) -> MainImportedVideo {
        restorationResult(from: record).item
    }

    static func restoring(
        from record: ChronoVolumeProjectDocument.MainVideoRecord,
        bookmarkResolver: (Data?) -> URL?
    ) -> MainImportedVideo {
        restorationResult(
            from: record,
            bookmarkResolver: bookmarkResolver
        ).item
    }

    static func restorationResult(
        from record: ChronoVolumeProjectDocument.MainVideoRecord
    ) -> RestorationResult {
        restorationResult(from: record, resolvedSourcePair: record.resolvedSourcePair())
    }

    static func restorationResult(
        from record: ChronoVolumeProjectDocument.MainVideoRecord,
        bookmarkResolver: (Data?) -> URL?
    ) -> RestorationResult {
        restorationResult(
            from: record,
            resolvedSourcePair: record.resolvedSourcePair(bookmarkResolver: bookmarkResolver)
        )
    }

    private static func restorationResult(
        from record: ChronoVolumeProjectDocument.MainVideoRecord,
        resolvedSourcePair: VideoSourcePair
    ) -> RestorationResult {
        let isAlphaCheater = record.isAlphaCheater ?? false
        let identity = isAlphaCheater
            ? VideoSourcePairDiscovery.restoredPairingIdentity(
                for: resolvedSourcePair,
                persistedKey: record.pairingKey
            )
            : .init(pairingKey: nil, diagnostic: nil)
        let item = MainImportedVideo(
            id: record.id,
            sourcePair: resolvedSourcePair,
            isAlphaCheater: isAlphaCheater,
            pairingKey: identity.pairingKey
        )
        return RestorationResult(
            item: item,
            pairingDiagnostic: identity.diagnostic
        )
    }
}

struct AlphaCheaterImportMergeResult: Sendable {
    var videos: [MainImportedVideo]
    var firstMatchedID: UUID?
    var conflicts: [VideoSourcePairDiscovery.RoleConflict]
}

enum AlphaCheaterImportedVideoState {
    struct SettingsUpdateResult: Sendable {
        let item: MainImportedVideo
        let requiresReload: Bool
    }

    static func merge(
        _ classification: VideoSourcePairDiscovery.AlphaCheaterImportClassification,
        into existingVideos: [MainImportedVideo],
        makeID: () -> UUID = UUID.init
    ) -> AlphaCheaterImportMergeResult {
        var videos = existingVideos
        var firstMatchedID: UUID?
        var conflicts = classification.roleConflicts

        for group in classification.groups {
            if let index = videos.firstIndex(where: {
                $0.isAlphaCheater && $0.pairingKey == group.pairingKey
            }) {
                var item = videos[index]
                firstMatchedID = firstMatchedID ?? item.id

                if let incomingColor = group.colorURL {
                    if item.hasColorSource {
                        if !VideoSourcePairDiscovery.urlsReferToSameFile(
                            item.sourcePair.colorURL,
                            incomingColor
                        ) {
                            conflicts.append(.init(
                                pairingKey: group.pairingKey,
                                role: .color,
                                keptURL: item.sourcePair.colorURL,
                                incomingURL: incomingColor
                            ))
                        }
                    } else {
                        item = addingColor(incomingColor, to: item)
                    }
                }

                if let incomingAlpha = group.alphaURL {
                    if let keptAlpha = item.sourcePair.alphaURL {
                        if !VideoSourcePairDiscovery.urlsReferToSameFile(keptAlpha, incomingAlpha) {
                            conflicts.append(.init(
                                pairingKey: group.pairingKey,
                                role: .alpha,
                                keptURL: keptAlpha,
                                incomingURL: incomingAlpha
                            ))
                        }
                    } else {
                        item = addingAlpha(incomingAlpha, to: item)
                    }
                }
                videos[index] = item
            } else {
                let item = MainImportedVideo(
                    id: makeID(),
                    sourcePair: group.sourcePair,
                    isAlphaCheater: true,
                    pairingKey: group.pairingKey
                )
                videos.append(item)
                firstMatchedID = firstMatchedID ?? item.id
            }
        }

        return AlphaCheaterImportMergeResult(
            videos: videos,
            firstMatchedID: firstMatchedID,
            conflicts: conflicts
        )
    }

    static func addingColor(_ url: URL, to item: MainImportedVideo) -> MainImportedVideo {
        guard item.isAlphaCheater, !item.hasColorSource, item.hasAlphaSource else { return item }
        var result = item
        result.sourcePair.colorURL = url
        result.sourcePair.usesGeneratedWhiteColor = false
        result.sourcePair.alphaSourceMode = .external
        return result
    }

    static func addingAlpha(_ url: URL, to item: MainImportedVideo) -> MainImportedVideo {
        guard item.isAlphaCheater, item.hasColorSource, !item.hasAlphaSource else { return item }
        var result = item
        result.sourcePair.alphaURL = url
        result.sourcePair.alphaSourceMode = .external
        result.sourcePair.usesGeneratedWhiteColor = false
        return result
    }

    static func removingColor(from item: MainImportedVideo) -> MainImportedVideo {
        guard item.isAlphaCheater,
              item.hasColorSource,
              let alphaURL = item.sourcePair.alphaURL else { return item }
        var result = item
        result.sourcePair.colorURL = alphaURL
        result.sourcePair.alphaURL = alphaURL
        result.sourcePair.alphaSourceMode = .external
        result.sourcePair.usesGeneratedWhiteColor = true
        result.sourcePair.externalAlphaSettings = result.sourcePair.externalAlphaSettings
            .applyingGeneratedWhiteColorSemantics(true)
        return result
    }

    static func removingAlpha(from item: MainImportedVideo) -> MainImportedVideo {
        guard item.isAlphaCheater, item.hasColorSource, item.hasAlphaSource else { return item }
        var result = item
        result.sourcePair.alphaURL = nil
        result.sourcePair.alphaSourceMode = .opaque
        result.sourcePair.usesGeneratedWhiteColor = false
        return result
    }

    static func updatingExternalAlphaSettings(
        _ settings: ExternalAlphaSettings,
        for item: MainImportedVideo
    ) -> SettingsUpdateResult {
        let effectiveSettings = settings.applyingGeneratedWhiteColorSemantics(
            item.sourcePair.usesGeneratedWhiteColor
        )
        guard effectiveSettings != item.sourcePair.externalAlphaSettings else {
            return SettingsUpdateResult(item: item, requiresReload: false)
        }
        var result = item
        result.sourcePair.externalAlphaSettings = effectiveSettings
        result.sourcePair.alphaSourceMode = result.sourcePair.alphaURL == nil ? .opaque : .external
        return SettingsUpdateResult(item: result, requiresReload: true)
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldClose: shouldClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.install(on: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        DispatchQueue.main.async {
            if let window = nsView.window {
                context.coordinator.install(on: window)
            }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () -> Bool
        private weak var window: NSWindow?

        init(shouldClose: @escaping () -> Bool) {
            self.shouldClose = shouldClose
        }

        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldClose()
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var distributedSettings = DistributedExportSettings()
    @StateObject private var exportOptions = ExportOptionsState()
    @StateObject private var exportRuntime = ExportRuntimeState()
    @StateObject private var nodeServiceModel = NodeServiceModel()
    @StateObject private var compositionModel = CompositionModel()
    @StateObject private var runtimeAudit = RuntimeAuditModel()

    @State private var runtimeAuditWindowController = RuntimeAuditWindowController()
    @State private var selectedTab: Int = 0
    @State private var localKeyMonitor: Any?
    @State private var importedVideos: [MainImportedVideo] = []
    @State private var selectedImportedVideoID: UUID?
    @State private var currentProjectURL: URL?
    @State private var savedProjectSignature: Data?
    @State private var lastAutosaveSignature: Data?
    @State private var didCheckAutosaveRecovery = false
    @State private var compositionSidebarDragStartWidth: Double?

    var body: some View {
        ZStack {
            Group {
                if selectedTab == 2 {
                    compositionSplitLayout
                } else {
                    HSplitView {
                        controlPanel
                            .frame(minWidth: 340, idealWidth: 390, maxWidth: 470)

                        Group {
                            switch selectedTab {
                            case 0:
                            SlicePreviewPage(model: model)
                            case 1:
                            CameraWorkspace3D(model: model)
                            default:
                            CompositionWorkspaceView(model: compositionModel)
                            }
                        }
                    }
                }
            }
            .disabled(exportRuntime.isExporting)
            .allowsHitTesting(!exportRuntime.isExporting)

            if exportRuntime.isExporting {
                ExportProgressOverlay(
                    runtime: exportRuntime,
                    distributedSettings: distributedSettings,
                    appStatus: model.status,
                    onClose: {
                        exportRuntime.closeIfPossible()
                        model.restoreAfterExclusiveExport()
                    }
                )
            }
        }
        .frame(minWidth: 1320, minHeight: 840)
        .background(WindowCloseGuard {
            confirmCloseIfNeeded()
        })
        .onAppear {
            if savedProjectSignature == nil {
                savedProjectSignature = makeProjectSignature()
            }
            compositionModel.projectFilePathForDiagnostics = currentProjectURL?.path
            promptForAutosaveRecoveryIfNeeded()
            runtimeAudit.record(.info, category: "动态审查", title: "启动", message: "运行时审查已启用（\(RuntimeAuditModel.toolVersion)）")

            compositionModel.onVideoPackageLoaded = { [weak model, runtimeAudit] url, package in
                Task { @MainActor in
                    model?.cacheLoadedVideoPackage(package, url: url)
                    let full = package.fullTemporalVolume
                    runtimeAudit.record(
                        .success,
                        category: "素材",
                        title: "合成代理导入完成",
                        message: "\(url.lastPathComponent)：\(full.width) × \(full.height) × \(full.depth)"
                    )
                }
            }

            compositionModel.onMeshPackageLoaded = { [runtimeAudit] url, package in
                Task { @MainActor in
                    let volume = package.volume
                    runtimeAudit.record(
                        .success,
                        category: "素材",
                        title: "模型导入完成",
                        message: "\(url.lastPathComponent)：\(volume.width) × \(volume.height) × \(volume.depth)"
                    )
                }
            }

            if localKeyMonitor == nil {
                localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                    if handleProjectShortcut(event) {
                        return nil
                    }

                    if selectedTab == 2, handleCompositionKeyDown(event) {
                        return nil
                    }

                    if event.keyCode == 49 && !event.isARepeat {
                        if exportRuntime.isExporting {
                            return nil
                        }
                        if selectedTab == 1 || model.isCameraPreviewFloating {
                            model.toggleCameraTimelinePlayback()
                        } else {
                            model.togglePlayback()
                        }
                        return nil
                    }
                    return event
                }
            }
        }
        .onDisappear {
            if let localKeyMonitor {
                NSEvent.removeMonitor(localKeyMonitor)
                self.localKeyMonitor = nil
            }
        }
        .onChange(of: model.status) { _, newStatus in
            runtimeAudit.observeStatus(source: "主应用", status: newStatus)
            exportRuntime.updateFromAppStatus(newStatus)

            if exportRuntime.shouldRestoreAppAfterExport {
                model.restoreAfterExclusiveExport()
            }

            if newStatus == "就绪", !exportRuntime.isExporting {
                model.prewarmWorkerSourceIfReady(settings: distributedSettings)
            }
        }
        .onChange(of: distributedSettings.connectionState) { _, state in
            if case .online = state, model.status == "就绪", !exportRuntime.isExporting {
                model.prewarmWorkerSourceIfReady(settings: distributedSettings)
            }
        }
        .onChange(of: compositionModel.status) { _, newStatus in
            runtimeAudit.observeStatus(source: "合成", status: newStatus)
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            guard oldValue != newValue else { return }
            runtimeAudit.record(
                .completed,
                category: "视图",
                title: "\(workspaceTitle(for: oldValue))视图完成",
                message: "已切换到 \(workspaceTitle(for: newValue))视图"
            )
        }
        .onChange(of: runtimeAudit.refreshRequestID) { _, _ in
            sampleRuntimeAudit()
        }
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { _ in
            performAutosaveIfNeeded()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            sampleRuntimeAudit()
        }
    }

    private var compositionSplitLayout: some View {
        HStack(spacing: 0) {
            controlPanel
                .frame(
                    width: CGFloat(compositionModel.workspaceLayout.projectSidebarWidth),
                    alignment: .topLeading
                )

            Rectangle()
                .fill(Color.secondary.opacity(0.001))
                .frame(width: 10)
                .overlay {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(width: 1)
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if compositionSidebarDragStartWidth == nil {
                                compositionSidebarDragStartWidth = compositionModel.workspaceLayout.projectSidebarWidth
                            }
                            let start = compositionSidebarDragStartWidth ?? compositionModel.workspaceLayout.projectSidebarWidth
                            let next = start + Double(value.translation.width)
                            compositionModel.workspaceLayout.projectSidebarWidth = min(560, max(300, next))
                        }
                        .onEnded { _ in
                            compositionSidebarDragStartWidth = nil
                        }
                )
                .help("拖动调整左侧项目区宽度，布局会随项目保存")

            CompositionWorkspaceView(model: compositionModel)
        }
    }

    private func handleProjectShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandOrControl = flags.contains(.command) || flags.contains(.control)
        let hasShift = flags.contains(.shift)
        let character = event.charactersIgnoringModifiers?.lowercased()

        let isNewShortcut = hasCommandOrControl && !hasShift && character == "n"
        let isSaveShortcut = hasCommandOrControl && character == "s"
        guard isNewShortcut || isSaveShortcut else { return false }
        guard !exportRuntime.isExporting else { return true }

        if isNewShortcut {
            newProject()
            return true
        }

        if hasShift {
            saveProjectAs()
        } else {
            saveProject()
        }
        return true
    }

    private func handleCompositionKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandOrControl = flags.contains(.command) || flags.contains(.control)
        let hasShift = flags.contains(.shift)
        let character = event.charactersIgnoringModifiers?.lowercased()
        let plainFlags = flags.subtracting([.capsLock, .numericPad, .function])

        if plainFlags.isEmpty, event.keyCode == 49 {
            guard !event.isARepeat else { return true }
            endTextInputEditing()
            compositionModel.togglePlayback()
            return true
        }

        guard !isTextInputFocused else { return false }

        if hasCommandOrControl, hasShift, character == "d" {
            compositionModel.splitSelectedLayerAtCurrentFrame()
            return true
        }

        if hasCommandOrControl, !hasShift, character == "z" {
            compositionModel.undoCompositionEdit()
            return true
        }

        if hasCommandOrControl, hasShift, character == "z" {
            compositionModel.redoCompositionEdit()
            return true
        }

        if hasCommandOrControl, !hasShift, character == "c" {
            compositionModel.copyCompositionSelection()
            return true
        }

        if hasCommandOrControl, !hasShift, character == "v" {
            compositionModel.pasteCompositionClipboard()
            return true
        }

        if hasCommandOrControl, !hasShift, character == "k" {
            compositionModel.isShowingCompositionSettingsSheet = true
            return true
        }

        if plainFlags.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            compositionModel.deleteCompositionTimelineSelection()
            return true
        }

        return false
    }

    private var isTextInputFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func endTextInputEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("ChronoVolume")
                        .font(.title2.bold())
                    Spacer()
                    Menu("项目") {
                        Button("新建项目") {
                            newProject()
                        }
                        .keyboardShortcut("n", modifiers: [.command])

                        Button("打开项目") {
                            openProject()
                        }

                        Divider()

                        Button("保存项目") {
                            saveProject()
                        }
                        .keyboardShortcut("s", modifiers: [.command])

                        Button("另存为") {
                            saveProjectAs()
                        }
                        .keyboardShortcut("s", modifiers: [.command, .shift])

                        Divider()

                        Button("关闭项目") {
                            closeProject()
                        }
                    }
                    .disabled(exportRuntime.isExporting)
                    Button {
                        runtimeAuditWindowController.show(model: runtimeAudit)
                    } label: {
                        Label("动态审查", systemImage: "waveform.path.ecg")
                    }
                    .help(runtimeAudit.stateSummaryText)
                    Button("导入视频/模型") {
                        chooseVideo()
                    }
                }

                Button("导入AlphaCheater") {
                    chooseAlphaCheater()
                }
                .help("可多选 A_color / B_alpha；按文件名自动配对，也支持只导入一路")

                mediaStatusPanel

                Picker("工作区", selection: $selectedTab) {
                    Text("2D").tag(0)
                    Text("3D").tag(1)
                    Text("合成").tag(2)
                }
                .pickerStyle(.segmented)

                if selectedTab == 0 {
                    twoDControlsPanel
                    twoDExportPanel
                    if supportsDistributedExport {
                        distributedWorkerPanel
                    }
                } else if selectedTab == 1 {
                    if model.sliceMode == .plane {
                        referencePlane3DPanel
                    }
                    volumeRenderPanel
                    cameraControlPanel
                    cameraExportPanel
                } else {
                    compositionControlPanel
                }

                Spacer(minLength: 20)
            }
            .padding(16)
        }
    }

    private var mediaStatusPanel: some View {
        GroupBox("媒体") {
            VStack(alignment: .leading, spacing: 6) {
                Text("文件：\(model.fileName)")
                    .lineLimit(2)

                if !importedVideos.isEmpty {
                    Picker("显示", selection: Binding(
                        get: { selectedImportedVideoID ?? importedVideos.first?.id },
                        set: { newValue in
                            if let newValue {
                                selectImportedVideo(id: newValue)
                            }
                        }
                    )) {
                        ForEach(importedVideos) { item in
                            Text(item.pickerTitle).tag(Optional(item.id))
                        }
                    }
                }

                if let item = selectedImportedVideo, item.isAlphaCheater {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(alphaCheaterSourceSummary(item))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            if item.hasColorSource && !item.hasAlphaSource {
                                Button("添加 B_alpha") { chooseAlphaVideo() }
                            } else if !item.hasColorSource && item.hasAlphaSource {
                                Button("添加 A_color") { chooseColorVideoForSelectedAlphaCheater() }
                            } else if item.hasColorSource && item.hasAlphaSource {
                                Button("移除 A_color") { removeSelectedColorSource() }
                                Button("移除 B_alpha") { removeSelectedExternalAlpha() }
                            }
                        }
                    }
                }

                Text("状态：\(model.status)")
                    .foregroundStyle(.secondary)

                Text("Alpha：\(model.alphaInfo)")
                    .lineLimit(2)

                if let color = model.colorSourceMetadata,
                   selectedImportedVideo?.sourcePair.usesGeneratedWhiteColor != true {
                    DisclosureGroup("A_color 属性") {
                        sourceMetadataView(color, isAlpha: false)
                    }
                } else if selectedImportedVideo?.sourcePair.usesGeneratedWhiteColor == true {
                    Text("A_color：未添加；RGB 使用 (1, 1, 1) 直通白模，透明度来自 B_alpha")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let alpha = model.alphaSourceMetadata,
                   let pair = model.videoSourcePair {
                    DisclosureGroup("B_alpha 属性") {
                        sourceMetadataView(alpha, isAlpha: true)
                        if pair.usesGeneratedWhiteColor {
                            Text("通道：\(pair.externalAlphaSettings.channel.rawValue) · 反转：\(pair.externalAlphaSettings.invert ? "是" : "否") · 范围：\(pair.externalAlphaSettings.range.rawValue)")
                        } else {
                            Text("通道：\(pair.externalAlphaSettings.channel.rawValue) · 反转：\(pair.externalAlphaSettings.invert ? "是" : "否") · 同步：\(model.alphaSyncStatus)")
                        }
                        Text("精度：源 \(model.sourceAlphaBitDepth)-bit；RGBA8 交互预览 \(model.previewAlphaBitDepth)-bit；高精度旁路不经过预览 Alpha")
                    }

                    Picker("B_alpha 预览", selection: Binding(
                        get: { model.externalAlphaPreviewMode },
                        set: { model.setExternalAlphaPreviewMode($0) }
                    )) {
                        ForEach(ExternalAlphaPreviewMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    DisclosureGroup("B_alpha 解释与兼容策略") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("取值通道", selection: alphaSettingBinding(\.channel)) {
                                ForEach(ExternalAlphaChannel.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Toggle("反转", isOn: alphaSettingBinding(\.invert))
                            Picker("范围", selection: alphaSettingBinding(\.range)) {
                                ForEach(ExternalAlphaRange.allCases) { Text($0.rawValue).tag($0) }
                            }
                            if ExternalAlphaSettingsAvailability.editableSettings(for: pair).contains(.association) {
                                Picker("A_color Alpha 关联", selection: alphaSettingBinding(\.association)) {
                                    ForEach(AlphaAssociation.allCases) { association in
                                        Text(association == .straight ? "Straight（RGB 未预乘）" : "Premultiplied（按 B_alpha 反预乘）")
                                            .tag(association)
                                    }
                                }
                                Text("Premultiplied 输入在 B_alpha=0 处无法恢复被清零的 RGB；加载诊断会报告此类像素。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("同步", selection: alphaSettingBinding(\.syncPolicy)) {
                                    ForEach(ExternalAlphaSyncPolicy.allCases) { Text($0.rawValue).tag($0) }
                                }
                                Picker("尺寸", selection: alphaSettingBinding(\.resizePolicy)) {
                                    ForEach(ExternalAlphaResizePolicy.allCases) { Text($0.rawValue).tag($0) }
                                }
                                Text("nearest/resample/scale/trim 仅在这里显式选择，默认 strict 不会静默兼容。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("B-only 白模固定按 Straight Alpha 解释；同步与尺寸匹配由 B_alpha 自身时间线和显示尺寸决定。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                if model.sourceDurationSeconds > 0 {
                    Text(
                        String(
                            format: "%.2f fps，%.2f 秒，%d 帧，%d-bit，%@",
                            model.sourceFPS,
                            model.sourceDurationSeconds,
                            model.sourceFrameCount,
                            model.sourceBitDepth,
                            model.sourceColorProfile.detailText
                        )
                    )
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                }

                DisclosureGroup("体数据") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("3D预览体：\(model.previewVolumeInfo)")
                        Text("实际体：\(model.actualVolumeInfo)")
                        Text("工作体：\(model.volumeInfo)")
                        Text("2D 时间轴：\(model.fullTemporalDepthCount) 帧")
                        Text("3D 时间轴：\(model.previewDepthCount) 帧")

                        if let cacheStatus = model.highPrecisionCacheStatusText() {
                            Text("高精度缓存：\(cacheStatus)")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sourceMetadataView(_ metadata: VideoSourceMetadata, isAlpha: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(metadata.fileName) · \(metadata.container) · \(metadata.codec)")
            Text("\(metadata.displayWidth) × \(metadata.displayHeight) · 旋转 \(metadata.rotationDegrees)° · \(String(format: "%.6f", metadata.fps)) fps")
            Text("\(String(format: "%.6f", metadata.durationSeconds)) 秒 · \(metadata.frameCount) 帧 · time base \(metadata.timeBase)")
            Text("\(metadata.pixelFormat) · \(metadata.bitDepth)-bit · range \(metadata.range.rawValue)")
            if !isAlpha {
                Text("primaries \(metadata.colorPrimaries) · transfer \(metadata.transfer) · matrix \(metadata.matrix) · 内嵌 Alpha \(metadata.hasEmbeddedAlpha ? "是" : "否")")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func alphaSettingBinding<Value>(_ keyPath: WritableKeyPath<ExternalAlphaSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.videoSourcePair?.externalAlphaSettings[keyPath: keyPath] ?? ExternalAlphaSettings()[keyPath: keyPath] },
            set: { value in
                guard var settings = model.videoSourcePair?.externalAlphaSettings else { return }
                settings[keyPath: keyPath] = value
                updateSelectedExternalAlphaSettings(settings)
            }
        )
    }

    private var twoDControlsPanel: some View {
        GroupBox("切片与播放") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("切片模式", selection: Binding(
                    get: { model.sliceMode },
                    set: { model.setSliceMode($0) }
                )) {
                    ForEach(SliceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                if model.sliceMode == .axis {
                    Picker("时间轴", selection: Binding(
                        get: { model.playbackAxis },
                        set: { model.setPlaybackAxis($0) }
                    )) {
                        ForEach(PlaybackAxis.allCases) { axis in
                            Text(axis.title).tag(axis)
                        }
                    }
                } else {
                    ReferencePlaneControls(model: model) {
                        model.showPlaneOverlay = true
                        model.updateReferencePlaneOverlay()
                        selectedTab = 1
                    }
                }

                HStack {
                    Button(model.isPlaying ? "暂停" : "播放") {
                        model.togglePlayback()
                    }

                    Button("停止") {
                        model.stopPlayback()
                        model.setCurrentIndex(0)
                    }

                    Button("跳到最明显帧") {
                        model.jumpToBestVisibleFrame()
                    }
                    .disabled(!(model.sliceMode == .axis && model.playbackAxis == .t))
                }

                frameIndexSlider

                HStack {
                    Text("播放倍率")
                    Slider(
                        value: Binding(
                            get: { model.playbackRate },
                            set: { model.setPlaybackRate($0) }
                        ),
                        in: 0.1...4.0,
                        step: 0.05
                    )
                    Text(String(format: "%.2fx", model.playbackRate))
                        .frame(width: 58, alignment: .trailing)
                }

                let size = model.imageSizeForCurrentMode()
                Text("当前切片尺寸：\(size.0) × \(size.1)")
                    .foregroundStyle(.secondary)
                    .font(.footnote)

                DisclosureGroup("预览显示") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("播放时动态降分辨率", isOn: $model.reduceResolutionWhilePlaying)
                            .help("开启后，X/Y/参考面在播放时会自动降低预览分辨率，暂停后恢复清晰画质")

                        Toggle("透明区域显示棋盘格", isOn: Binding(
                            get: { model.showCheckerboard },
                            set: {
                                model.showCheckerboard = $0
                                model.invalidateSliceCacheAndRebuild()
                            }
                        ))
                        .disabled(model.sliceMode == .axis && model.playbackAxis == .t)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var compositionControlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            CompositionProjectPanel(model: compositionModel)
            CompositionRenderQueuePanel(model: compositionModel)
        }
    }

    private var twoDExportPanel: some View {
        GroupBox("2D 导出") {
            VStack(alignment: .leading, spacing: 10) {
                ExportActionPanel(
                    options: exportOptions,
                    distributedSettings: distributedSettings,
                    sourceBitDepth: model.sourceBitDepth,
                    sourceColorProfile: model.sourceColorProfile,
                    onLocalExport: {
                        model.prepareForExclusiveExport()
                        exportRuntime.begin(title: "本机导出")
                        model.exportCurrent2DVideoInteractivelyLocal(
                            preserveAlpha: exportOptions.preserveAlpha,
                            qualityScale: exportOptions.qualityScale,
                            padToEven: exportOptions.padToEven,
                            highPrecision: exportOptions.highPrecision,
                            bitDepth: exportOptions.bitDepth.resolved(sourceBitDepth: model.sourceBitDepth),
                            colorProfile: exportOptions.colorProfile.resolved(source: model.sourceColorProfile)
                        )
                    },
                    onDistributedExport: {
                        model.prepareForExclusiveExport()
                        exportRuntime.begin(title: "分布式导出")
                        model.exportCurrent2DVideoInteractivelyDistributed(
                            preserveAlpha: exportOptions.preserveAlpha,
                            qualityScale: exportOptions.qualityScale,
                            padToEven: exportOptions.padToEven,
                            bitDepth: exportOptions.bitDepth.resolved(sourceBitDepth: model.sourceBitDepth),
                            colorProfile: exportOptions.colorProfile.resolved(source: model.sourceColorProfile),
                            distributedSettings: distributedSettings
                        )
                    }
                )
                .disabled(model.totalFrameCountForCurrentMode() == 0)

                Menu("高精度缓存") {
                    Button("建立高精度缓存（不带 Alpha）") {
                        model.buildHighPrecisionCacheInteractively(preserveAlpha: false)
                    }

                    Button("建立高精度缓存（带 Alpha）") {
                        model.buildHighPrecisionCacheInteractively(preserveAlpha: true)
                    }

                    Divider()

                    Button("清理当前视频高精度缓存") {
                        model.removeHighPrecisionCacheInteractively()
                    }
                }
                .help("先建立高精度缓存，后续同一视频重复做高精度 X/Y 导出会更快")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var distributedWorkerPanel: some View {
        GroupBox("分布式与 Worker") {
            VStack(alignment: .leading, spacing: 10) {
                DistributedExportPanel(
                    settings: distributedSettings,
                    currentAxisTitle: model.sliceMode == .plane ? "参考面" : (model.playbackAxis == .x ? "X" : "Y"),
                    totalOutputFrames: model.distributedOutputFrameCount,
                    pairedPrecisionNotice: distributedPairedPrecisionNotice,
                    onTestAllWorkers: {
                        model.testAllWorkerConnectionsAndPrepare(settings: distributedSettings)
                    },
                    onStartDistributedExport: {
                        model.prepareForExclusiveExport()
                        exportRuntime.begin(title: "分布式导出")
                        model.exportCurrent2DVideoInteractivelyDistributed(
                            preserveAlpha: exportOptions.preserveAlpha,
                            qualityScale: exportOptions.qualityScale,
                            padToEven: exportOptions.padToEven,
                            bitDepth: exportOptions.bitDepth.resolved(sourceBitDepth: model.sourceBitDepth),
                            colorProfile: exportOptions.colorProfile.resolved(source: model.sourceColorProfile),
                            distributedSettings: distributedSettings
                        )
                    },
                    onRefreshWorkerSource: {
                        model.refreshWorkerSourceCache(settings: distributedSettings)
                    },
                    onUploadSourceToWorker: {
                        model.uploadCurrentSourceToWorker(settings: distributedSettings)
                    },
                    onPrepareWorkerRawCache: {
                        model.prepareWorkerRawCache(settings: distributedSettings)
                    }
                )

                DisclosureGroup("本机 Worker 服务") {
                    NodeServicePanel(model: nodeServiceModel)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var distributedPairedPrecisionNotice: String? {
        guard let pair = model.videoSourcePair,
              pair.alphaSourceMode == .external else { return nil }
        if pair.usesGeneratedWhiteColor {
            return ExternalPairedRenderPolicy.generatedWhiteDistributedNotice
        }
        return "A_color + B_alpha 当前使用 RGBA8 paired renderer；颜色、Alpha 或输出任一路高于 8-bit 时会在传输前明确拒绝。"
    }

    private var volumeRenderPanel: some View {
        GroupBox("体渲染") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("使用 Alpha 体渲染", isOn: Binding(
                    get: { model.useAlpha },
                    set: { newValue in
                        model.useAlpha = newValue
                        model.renderer?.useAlpha = newValue
                        model.cameraPreviewRenderer?.useAlpha = newValue
                        model.renderer?.requestRedraw()
                        model.cameraPreviewRenderer?.requestRedraw()
                        model.invalidateSliceCacheAndRebuild()
                    }
                ))

                Toggle("使用像素体进行渲染", isOn: Binding(
                    get: { model.useVoxelBlockRendering },
                    set: { newValue in
                        model.useVoxelBlockRendering = newValue
                        model.renderer?.useVoxelBlockRendering = newValue
                        model.cameraPreviewRenderer?.useVoxelBlockRendering = newValue
                        model.renderer?.requestRedraw()
                        model.cameraPreviewRenderer?.requestRedraw()
                    }
                ))
                .help("开启后，3D 视图会把体数据按体素块进行渲染，呈现由小立方像素块堆叠而成的效果")

                Toggle("边缘连续", isOn: Binding(
                    get: { model.smoothVolumeEdges },
                    set: { newValue in
                        model.smoothVolumeEdges = newValue
                        model.renderer?.smoothEdges = newValue
                        model.cameraPreviewRenderer?.smoothEdges = newValue
                        model.renderer?.requestRedraw()
                        model.cameraPreviewRenderer?.requestRedraw()
                        model.invalidateSliceCacheAndRebuild()
                    }
                ))
                .help("对体数据边缘做邻域采样，减少高步数下的层状断裂；像素体渲染时也会柔化小方块外缘")

                DisclosureGroup("体变换（视频/模型）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("用于整体移动、旋转和缩放当前体数据；视频和 STL 都可使用。下方修改器用于 STL 网格形变或视频体素重采样。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        CameraSliderRow(title: "位置X", value: Binding(
                            get: { Double(model.volumeTransform.positionX) },
                            set: {
                                model.volumeTransform.positionX = Float($0)
                                model.updateVolumeTransformRenderers()
                            }
                        ), range: -4.0...4.0, format: "%.2f", resetValue: 0)

                        CameraSliderRow(title: "位置Y", value: Binding(
                            get: { Double(model.volumeTransform.positionY) },
                            set: {
                                model.volumeTransform.positionY = Float($0)
                                model.updateVolumeTransformRenderers()
                            }
                        ), range: -4.0...4.0, format: "%.2f", resetValue: 0)

                        CameraSliderRow(title: "位置Z", value: Binding(
                            get: { Double(model.volumeTransform.positionZ) },
                            set: {
                                model.volumeTransform.positionZ = Float($0)
                                model.updateVolumeTransformRenderers()
                            }
                        ), range: -4.0...4.0, format: "%.2f", resetValue: 0)

                        CameraSliderRow(title: "旋转X", value: Binding(
                            get: { Double(model.volumeTransform.rotationX) * 180.0 / .pi },
                            set: {
                                model.volumeTransform.rotationX = Float($0 * .pi / 180.0)
                                model.updateVolumeTransformRenderers()
                            }
                        ), range: -360.0...360.0, format: "%.1f", resetValue: 0, displayMode: .turnsDegrees)

                        CameraSliderRow(title: "旋转Y", value: Binding(
                            get: { Double(model.volumeTransform.rotationY) * 180.0 / .pi },
                            set: {
                                model.volumeTransform.rotationY = Float($0 * .pi / 180.0)
                                model.updateVolumeTransformRenderers()
                            }
                        ), range: -360.0...360.0, format: "%.1f", resetValue: 0, displayMode: .turnsDegrees)

                        CameraSliderRow(title: "旋转Z", value: Binding(
                            get: { Double(model.volumeTransform.rotationZ) * 180.0 / .pi },
                            set: {
                                model.volumeTransform.rotationZ = Float($0 * .pi / 180.0)
                                model.updateVolumeTransformRenderers()
                            }
                        ), range: -360.0...360.0, format: "%.1f", resetValue: 0, displayMode: .turnsDegrees)

                        CameraSliderRow(title: "缩放", value: Binding(
                            get: { Double(model.volumeTransform.scale) },
                            set: {
                                model.volumeTransform.scale = Float(max(0.01, $0))
                                model.updateVolumeTransformRenderers()
                            }
                        ), range: 0.1...4.0, format: "%.2f", resetValue: 1, lowerLimit: 0.01)

                        Button("复位体变换") {
                            model.resetVolumeTransform()
                        }
                    }
                    .padding(.top, 4)
                }

                if model.hasModifierTarget {
                    DisclosureGroup(model.hasEditableMesh ? "模型修改器（STL 网格）" : "体素修改器（视频）") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.hasEditableMesh
                                 ? "修改器会按列表顺序叠加，结果用于 3D 显示、2D 切片和导出；原始 STL 会保留。"
                                 : "修改器会按列表顺序叠加，通过体素重采样生成派生视频体；原视频体会保留。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let message = model.modifierLoadingMessage {
                                ModifierLoadingBadge(message: message)
                            }

                            HStack {
                                Button(model.hasEditableMesh ? "添加变换" : "添加体素变换") {
                                    model.addMeshTransformModifier()
                                }
                                Button("上移") {
                                    model.moveSelectedMeshModifier(up: true)
                                }
                                .disabled(model.meshModifierStack.count <= 1)
                                Button("下移") {
                                    model.moveSelectedMeshModifier(up: false)
                                }
                                .disabled(model.meshModifierStack.count <= 1)
                                Button("删除") {
                                    model.deleteSelectedMeshModifier()
                                }
                                .disabled(model.meshModifierStack.isEmpty)
                            }

                            if model.meshModifierStack.isEmpty {
                                Text(model.hasEditableMesh ? "当前没有修改器，切片使用原始模型。" : "当前没有修改器，切片使用原始视频体。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(model.meshModifierStack) { modifier in
                                        let isSelected = model.selectedMeshModifierID == modifier.id
                                        HStack(spacing: 6) {
                                            Toggle("", isOn: Binding(
                                                get: {
                                                    model.meshModifierStack.first(where: { $0.id == modifier.id })?.isEnabled ?? false
                                                },
                                                set: {
                                                    model.setMeshModifierEnabled(id: modifier.id, isEnabled: $0)
                                                }
                                            ))
                                            .labelsHidden()

                                            Text(modifier.name)
                                                .font(.caption)
                                                .fontWeight(isSelected ? .semibold : .regular)
                                            Spacer()
                                            Text(modifier.isEnabled ? "启用" : "停用")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(5)
                                        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            model.selectMeshModifier(id: modifier.id)
                                        }
                                    }
                                }

                                CameraSliderRow(title: "位置X", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.positionX) },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.positionX = Float(newValue)
                                        }
                                    }
                                ), range: -1.5...1.5, format: "%.3f", resetValue: 0)

                                CameraSliderRow(title: "位置Y", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.positionY) },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.positionY = Float(newValue)
                                        }
                                    }
                                ), range: -1.5...1.5, format: "%.3f", resetValue: 0)

                                CameraSliderRow(title: "位置Z", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.positionZ) },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.positionZ = Float(newValue)
                                        }
                                    }
                                ), range: -1.5...1.5, format: "%.3f", resetValue: 0)

                                CameraSliderRow(title: "旋转X", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.rotationX) * 180.0 / .pi },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.rotationX = Float(newValue * .pi / 180.0)
                                        }
                                    }
                                ), range: -360.0...360.0, format: "%.1f", resetValue: 0, displayMode: .turnsDegrees)

                                CameraSliderRow(title: "旋转Y", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.rotationY) * 180.0 / .pi },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.rotationY = Float(newValue * .pi / 180.0)
                                        }
                                    }
                                ), range: -360.0...360.0, format: "%.1f", resetValue: 0, displayMode: .turnsDegrees)

                                CameraSliderRow(title: "旋转Z", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.rotationZ) * 180.0 / .pi },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.rotationZ = Float(newValue * .pi / 180.0)
                                        }
                                    }
                                ), range: -360.0...360.0, format: "%.1f", resetValue: 0, displayMode: .turnsDegrees)

                                CameraSliderRow(title: "缩放X", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.scaleX) },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.scaleX = Float(max(0.001, newValue))
                                        }
                                    }
                                ), range: 0.05...4.0, format: "%.3f", resetValue: 1, lowerLimit: 0.001)

                                CameraSliderRow(title: "缩放Y", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.scaleY) },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.scaleY = Float(max(0.001, newValue))
                                        }
                                    }
                                ), range: 0.05...4.0, format: "%.3f", resetValue: 1, lowerLimit: 0.001)

                                CameraSliderRow(title: "缩放Z", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.scaleZ) },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.scaleZ = Float(max(0.001, newValue))
                                        }
                                    }
                                ), range: 0.05...4.0, format: "%.3f", resetValue: 1, lowerLimit: 0.001)

                                CameraSliderRow(title: "膨胀", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.inflate) },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.inflate = Float(newValue)
                                        }
                                    }
                                ), range: -0.25...0.25, format: "%.3f", resetValue: 0)

                                if model.hasEditableMesh {
                                    Text("STL 模型会沿网格法线膨胀。")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Picker("膨胀方式", selection: Binding(
                                        get: { model.selectedMeshModifierState.inflateMode },
                                        set: { newValue in
                                            model.updateSelectedMeshModifierState { state in
                                                state.inflateMode = newValue
                                            }
                                        }
                                    )) {
                                        ForEach(VoxelInflateMode.allCases) { mode in
                                            Text(mode.title).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)

                                    Text("SDF表面按 Alpha 表面距离膨胀/收缩；破碎表面会直接切裂可见表层，膨胀为正时会继续生成碎裂外壳。")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                CameraSliderRow(title: "扭转Y", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.twistY) * 180.0 / .pi },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.twistY = Float(newValue * .pi / 180.0)
                                        }
                                    }
                                ), range: -720.0...720.0, format: "%.1f", resetValue: 0, displayMode: .turnsDegrees)

                                CameraSliderRow(title: "锥形X", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.taperX) },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.taperX = Float(newValue)
                                        }
                                    }
                                ), range: -1.0...1.0, format: "%.3f", resetValue: 0)

                                CameraSliderRow(title: "锥形Z", value: Binding(
                                    get: { Double(model.selectedMeshModifierState.taperZ) },
                                    set: { newValue in
                                        model.updateSelectedMeshModifierState { state in
                                            state.taperZ = Float(newValue)
                                        }
                                    }
                                ), range: -1.0...1.0, format: "%.3f", resetValue: 0)

                                HStack {
                                    Toggle("镜像X", isOn: Binding(
                                        get: { model.selectedMeshModifierState.mirrorX },
                                        set: { newValue in
                                            model.updateSelectedMeshModifierState { state in
                                                state.mirrorX = newValue
                                            }
                                        }
                                    ))
                                    Toggle("镜像Y", isOn: Binding(
                                        get: { model.selectedMeshModifierState.mirrorY },
                                        set: { newValue in
                                            model.updateSelectedMeshModifierState { state in
                                                state.mirrorY = newValue
                                            }
                                        }
                                    ))
                                    Toggle("镜像Z", isOn: Binding(
                                        get: { model.selectedMeshModifierState.mirrorZ },
                                        set: { newValue in
                                            model.updateSelectedMeshModifierState { state in
                                                state.mirrorZ = newValue
                                            }
                                        }
                                    ))
                                }

                                HStack {
                                    Button("居中选中") {
                                        model.centerMeshModifierPosition()
                                    }
                                    Button("复位选中") {
                                        model.resetSelectedMeshModifier()
                                    }
                                    Button("清空全部") {
                                        model.resetMeshModifiers()
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                } else {
                    GroupBox("修改器") {
                        Text("导入视频或 STL 后，可在这里添加非破坏性修改器。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    Text("步数")
                    Slider(
                        value: Binding(
                            get: { Double(model.steps) },
                            set: { newValue in
                                model.steps = Int(newValue)
                                model.renderer?.steps = model.steps
                                model.cameraPreviewRenderer?.steps = model.steps
                                model.renderer?.requestRedraw()
                                model.cameraPreviewRenderer?.requestRedraw()
                            }
                        ),
                        in: 16...512,
                        step: 1
                    )
                    Text("\(model.steps)")
                        .frame(width: 52, alignment: .trailing)
                }

                HStack {
                    Text("密度")
                    Slider(
                        value: Binding(
                            get: { model.density },
                            set: { newValue in
                                model.density = newValue
                                model.renderer?.density = Float(newValue)
                                model.cameraPreviewRenderer?.density = Float(newValue)
                                model.renderer?.requestRedraw()
                                model.cameraPreviewRenderer?.requestRedraw()
                            }
                        ),
                        in: 0.05...4.0
                    )
                    Text(String(format: "%.2f", model.density))
                        .frame(width: 52, alignment: .trailing)
                }

                HStack {
                    Text("亮度")
                    Slider(
                        value: Binding(
                            get: { model.brightness },
                            set: { newValue in
                                model.brightness = newValue
                                model.renderer?.brightness = Float(newValue)
                                model.cameraPreviewRenderer?.brightness = Float(newValue)
                                model.renderer?.requestRedraw()
                                model.cameraPreviewRenderer?.requestRedraw()
                            }
                        ),
                        in: 0.1...6.0
                    )
                    Text(String(format: "%.2f", model.brightness))
                        .frame(width: 52, alignment: .trailing)
                }

                DisclosureGroup("视图与辅助线") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("显示角落坐标轴", isOn: $model.showCornerAxesOverlay)
                        Toggle("显示原点坐标轴", isOn: $model.showOriginAxesOverlay)
                        Toggle("显示参考面", isOn: Binding(
                            get: { model.showPlaneOverlay },
                            set: {
                                model.showPlaneOverlay = $0
                                model.updateReferencePlaneOverlay()
                            }
                        ))
                        Toggle("显示摄像头", isOn: $model.showCameraOverlay)

                        Picker("3D 背景", selection: Binding(
                            get: { model.volumeBackgroundMode },
                            set: { newValue in
                                model.volumeBackgroundMode = newValue
                                model.updateVolumeBackground()
                            }
                        )) {
                            ForEach(VolumeBackgroundMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text("背景颜色")
                            Spacer()
                            StableColorWell(color: Binding(
                                get: { model.volumeBackgroundColor },
                                set: { newValue in
                                    model.volumeBackgroundColor = newValue
                                    model.updateVolumeBackground()
                                }
                            ))
                            .frame(width: 54, height: 28)
                        }

                        HStack {
                            Button("复位3D默认视图") {
                                model.reset3DDefaultView()
                            }

                            Button("复位参考面") {
                                model.resetReferencePlane()
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var referencePlane3DPanel: some View {
        GroupBox("参考面切片") {
            VStack(alignment: .leading, spacing: 10) {
                Text("在 3D 体视图中调整参考面，可以直接看到黄色参考面随 Yaw / Pitch / Roll 变化。")
                    .foregroundStyle(.secondary)
                    .font(.footnote)

                ReferencePlaneControls(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cameraControlPanel: some View {
        GroupBox("摄像机") {
            VStack(alignment: .leading, spacing: 10) {
                CameraTimelineEditor(model: model)

                DisclosureGroup("位置与镜头") {
                    VStack(alignment: .leading, spacing: 8) {
                        CameraSliderRow(title: "Yaw（偏航）", value: Binding(
                            get: { Double(model.cameraRig.yaw) * 180.0 / .pi },
                            set: {
                                model.cameraRig.yaw = Float($0 * .pi / 180.0)
                                model.updateCameraRigAndPreview(syncFocusOrientation: false)
                            }
                        ), range: CameraControlLimits.angleRange, format: "%.1f", resetValue: 0, displayMode: .turnsDegrees)
                        .disabled(model.cameraRig.focusLockEnabled)

                        CameraSliderRow(title: "Pitch（俯仰）", value: Binding(
                            get: { Double(model.cameraRig.pitch) * 180.0 / .pi },
                            set: {
                                model.cameraRig.pitch = Float($0 * .pi / 180.0)
                                model.updateCameraRigAndPreview(syncFocusOrientation: false)
                            }
                        ), range: CameraControlLimits.angleRange, format: "%.1f", resetValue: 0, displayMode: .turnsDegrees)
                        .disabled(model.cameraRig.focusLockEnabled)

                        CameraSliderRow(title: "Roll（滚转）", value: Binding(
                            get: { Double(model.cameraRig.roll) * 180.0 / .pi },
                            set: {
                                model.cameraRig.roll = Float($0 * .pi / 180.0)
                                model.updateCameraRigAndPreview(syncFocusOrientation: false)
                            }
                        ), range: CameraControlLimits.angleRange, format: "%.1f", resetValue: 0, displayMode: .turnsDegrees)

                        CameraSliderRow(title: "位置X", value: Binding(
                            get: { Double(model.cameraRig.positionX) },
                            set: {
                                model.cameraRig.positionX = Float($0)
                                model.updateCameraRigAndPreview()
                            }
                        ), range: CameraControlLimits.positionRange, format: "%.2f", resetValue: 0)

                        CameraSliderRow(title: "位置Y", value: Binding(
                            get: { Double(model.cameraRig.positionY) },
                            set: {
                                model.cameraRig.positionY = Float($0)
                                model.updateCameraRigAndPreview()
                            }
                        ), range: CameraControlLimits.positionRange, format: "%.2f", resetValue: 0)

                        CameraSliderRow(title: "位置Z", value: Binding(
                            get: { Double(model.cameraRig.positionZ) },
                            set: {
                                model.cameraRig.positionZ = Float($0)
                                model.updateCameraRigAndPreview()
                            }
                        ), range: CameraControlLimits.positionRange, format: "%.2f", resetValue: 0)

                        Toggle("焦点锁定", isOn: Binding(
                            get: { model.cameraRig.focusLockEnabled },
                            set: {
                                model.cameraRig.focusLockEnabled = $0
                                model.updateCameraRigAndPreview()
                            }
                        ))

                        if model.cameraRig.focusLockEnabled {
                            CameraSliderRow(title: "焦点X", value: Binding(
                                get: { Double(model.cameraRig.focusTargetX) },
                                set: {
                                    model.cameraRig.focusTargetX = Float($0)
                                    model.updateCameraRigAndPreview()
                                }
                            ), range: CameraControlLimits.focusRange, format: "%.2f", resetValue: 0)

                            CameraSliderRow(title: "焦点Y", value: Binding(
                                get: { Double(model.cameraRig.focusTargetY) },
                                set: {
                                    model.cameraRig.focusTargetY = Float($0)
                                    model.updateCameraRigAndPreview()
                                }
                            ), range: CameraControlLimits.focusRange, format: "%.2f", resetValue: 0)

                            CameraSliderRow(title: "焦点Z", value: Binding(
                                get: { Double(model.cameraRig.focusTargetZ) },
                                set: {
                                    model.cameraRig.focusTargetZ = Float($0)
                                    model.updateCameraRigAndPreview()
                                }
                            ), range: CameraControlLimits.focusRange, format: "%.2f", resetValue: 0)
                        }

                        CameraSliderRow(title: "焦段", value: Binding(
                            get: { Double(model.cameraRig.focalLength) },
                            set: {
                                model.cameraRig.focalLength = Float(max(1.0, $0))
                                model.updateCameraRigAndPreview(syncFocusOrientation: false)
                            }
                        ), range: 12...200, format: "%.0f", resetValue: 50, lowerLimit: 1.0)

                        CameraSliderRow(title: "光圈", value: Binding(
                            get: { Double(model.cameraRig.aperture) },
                            set: {
                                model.cameraRig.aperture = Float(max(0.1, $0))
                                model.updateCameraRigAndPreview(syncFocusOrientation: false)
                            }
                        ), range: 1.0...22.0, format: "%.1f", resetValue: 5.6, lowerLimit: 0.1)
                    }
                    .padding(.top, 4)
                }

                CameraFunctionDriverEditor(model: model)

                HStack {
                    Button("添加/更新关键帧") {
                        model.captureCameraKeyframe()
                    }
                    Button("删除当前帧关键帧") {
                        model.deleteCameraKeyframeAtCurrentFrame()
                    }
                    .disabled(!model.hasCameraKeyframeAtCurrentFrame)
                    Button(model.isCameraTimelinePlaying ? "停止" : "播放") {
                        model.toggleCameraTimelinePlayback()
                    }
                    Button("悬浮摄像机窗口") {
                        model.showFloatingCameraPreviewWindow()
                    }
                    Button("应用最近关键帧") {
                        if let keyframe = model.cameraKeyframes.min(by: {
                            abs($0.frame - model.cameraTimelineFrame) < abs($1.frame - model.cameraTimelineFrame)
                        }) {
                            model.applyCameraKeyframe(keyframe)
                        }
                    }
                    .disabled(model.cameraKeyframes.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cameraExportPanel: some View {
        GroupBox("摄像机导出") {
            VStack(alignment: .leading, spacing: 10) {
                CameraExportOptionsEditor(model: model)

                HStack {
                    Text("色彩空间")
                    Picker("摄像机导出色彩空间", selection: $exportOptions.colorProfile) {
                        ForEach(ExportColorProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer()
                    Text(exportOptions.colorProfile.resolved(source: model.sourceColorProfile).title)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("导出摄像机画面") {
                        _ = model.exportCameraVideoInteractively(
                            preserveAlpha: model.cameraExportPreserveAlpha,
                            padToEven: exportOptions.padToEven,
                            bitDepth: exportOptions.bitDepth.resolved(sourceBitDepth: model.sourceBitDepth),
                            colorProfile: exportOptions.colorProfile.resolved(source: model.sourceColorProfile),
                            onExportStarted: {
                                exportRuntime.begin(title: "摄像机画面导出")
                            }
                        )
                    }
                    .disabled(model.previewDepthCount <= 0)

                    Toggle("携带 Alpha", isOn: $model.cameraExportPreserveAlpha)
                        .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var supportsDistributedExport: Bool {
        model.sliceMode == .plane || (model.sliceMode == .axis && (model.playbackAxis == .x || model.playbackAxis == .y))
    }

    private func workspaceTitle(for tab: Int) -> String {
        switch tab {
        case 0: return "2D"
        case 1: return "3D"
        case 2: return "合成"
        default: return "未知"
        }
    }

    private func sampleRuntimeAudit() {
        runtimeAudit.sample(
            app: model,
            composition: compositionModel,
            exportRuntime: exportRuntime,
            distributed: distributedSettings,
            projectURL: currentProjectURL,
            importedVideoCount: importedVideos.count,
            selectedVideoID: selectedImportedVideoID,
            selectedTab: selectedTab,
            hasUnsavedChanges: hasUnsavedProjectChanges,
            autosaveExists: FileManager.default.fileExists(atPath: autosaveRecoveryURL.path)
        )
    }

    private var frameIndexSlider: some View {
        let total = model.totalFrameCountForCurrentMode()

        return HStack {
            Text("索引")

            if total > 1 {
                Slider(
                    value: Binding(
                        get: { Double(min(model.currentIndex, total - 1)) },
                        set: { model.setCurrentIndex(Int($0.rounded())) }
                    ),
                    in: 0...Double(total - 1),
                    step: 1
                )
            } else {
                Slider(value: .constant(0), in: 0...1, step: 1)
                    .disabled(true)
            }

            Text(total > 0 ? "\(model.currentIndex)/\(total - 1)" : "-")
                .frame(width: 92, alignment: .trailing)
        }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = importableContentTypes

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let meshURLs = panel.urls.filter { MeshVolumeLoader.isSupportedModelURL($0) }
            addImportedVideos(panel.urls, preferredSelectionURL: meshURLs.first ?? panel.urls.first)
            compositionModel.importAssets(urls: panel.urls)
            if !meshURLs.isEmpty {
                selectedTab = 1
            }
            runtimeAudit.record(
                .success,
                category: "素材",
                title: "导入素材",
                message: "选择 \(panel.urls.count) 个素材：\(panel.urls.map(\.lastPathComponent).joined(separator: "、"))"
            )
        }
    }

    private func chooseAlphaCheater() {
        let panel = NSOpenPanel()
        panel.title = "导入 AlphaCheater（可多选 A_color / B_alpha）"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = alphaCapableVideoContentTypes
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let classification = VideoSourcePairDiscovery.classifyAlphaCheaterURLs(panel.urls)
        guard !classification.groups.isEmpty else {
            model.status = "未识别到 AlphaCheater 文件。请使用 name_A_color / name_B_alpha、name-A_color / name-B_alpha 或 A_color / B_alpha 命名。"
            return
        }

        let previousPairs = Dictionary(uniqueKeysWithValues: importedVideos.map { ($0.id, $0.sourcePair) })
        let merge = AlphaCheaterImportedVideoState.merge(classification, into: importedVideos)
        importedVideos = merge.videos
        if let firstID = merge.firstMatchedID,
           let item = importedVideos.first(where: { $0.id == firstID }) {
            if selectedImportedVideoID == firstID {
                if previousPairs[firstID] != item.sourcePair {
                    model.loadVideo(pair: item.sourcePair, restoring: model.makeProjectState())
                }
            } else {
                selectImportedVideo(id: firstID)
            }
        }

        var diagnostics: [String] = ["已识别 \(classification.groups.count) 组 AlphaCheater 素材"]
        if !classification.unrecognized.isEmpty {
            diagnostics.append("未识别：\(classification.unrecognized.map(\.lastPathComponent).joined(separator: "、"))")
        }
        if !merge.conflicts.isEmpty {
            diagnostics.append(merge.conflicts.map(\.diagnostic).joined(separator: "；"))
        }
        model.status = diagnostics.joined(separator: "；")
        runtimeAudit.record(.success, category: "素材", title: "导入 AlphaCheater", message: model.status)
    }

    private func chooseColorVideoForSelectedAlphaCheater() {
        let panel = NSOpenPanel()
        panel.title = "添加 A_color"
        panel.message = "添加真实 A_color 后将恢复 association、同步和尺寸匹配设置。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = alphaCapableVideoContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let index = selectedImportedVideoIndex,
              importedVideos[index].isAlphaCheater,
              importedVideos[index].sourcePair.usesGeneratedWhiteColor else {
            model.status = "当前素材不是仅含 B_alpha 的 AlphaCheater 素材"
            return
        }
        let item = AlphaCheaterImportedVideoState.addingColor(url, to: importedVideos[index])
        importedVideos[index] = item
        model.loadVideo(pair: item.sourcePair, restoring: model.makeProjectState())
    }

    private func chooseAlphaVideo() {
        let panel = NSOpenPanel()
        panel.title = "添加 B_alpha（支持 MKV + FFV1 gray16le）"
        panel.message = "gray10/12/16le 可用于交互预览，但当前不能进入高于 8-bit 的 paired 分布式导出。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = alphaCapableVideoContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let index = selectedImportedVideoIndex,
              importedVideos[index].isAlphaCheater,
              importedVideos[index].hasColorSource,
              !importedVideos[index].hasAlphaSource else {
            model.status = "请先选择仅含 A_color 的 AlphaCheater 素材"
            return
        }
        let item = AlphaCheaterImportedVideoState.addingAlpha(url, to: importedVideos[index])
        importedVideos[index] = item
        model.loadVideo(pair: item.sourcePair, restoring: model.makeProjectState())
    }

    private var selectedImportedVideoIndex: Int? {
        guard let selectedImportedVideoID else { return nil }
        return importedVideos.firstIndex { $0.id == selectedImportedVideoID }
    }

    private var selectedImportedVideo: MainImportedVideo? {
        guard let selectedImportedVideoIndex else { return nil }
        return importedVideos[selectedImportedVideoIndex]
    }

    private func alphaCheaterSourceSummary(_ item: MainImportedVideo) -> String {
        let color = item.hasColorSource ? item.sourcePair.colorURL.lastPathComponent : "未添加（白模）"
        let alpha = item.sourcePair.alphaURL?.lastPathComponent ?? "未添加"
        return "AlphaCheater｜A_color：\(color)｜B_alpha：\(alpha)"
    }

    private func removeSelectedExternalAlpha() {
        guard let index = selectedImportedVideoIndex,
              importedVideos[index].isAlphaCheater,
              importedVideos[index].hasColorSource,
              importedVideos[index].hasAlphaSource else { return }
        let item = AlphaCheaterImportedVideoState.removingAlpha(from: importedVideos[index])
        importedVideos[index] = item
        model.loadVideo(pair: item.sourcePair, restoring: model.makeProjectState())
    }

    private func removeSelectedColorSource() {
        guard let index = selectedImportedVideoIndex,
              importedVideos[index].isAlphaCheater,
              importedVideos[index].hasColorSource else { return }
        let item = AlphaCheaterImportedVideoState.removingColor(from: importedVideos[index])
        importedVideos[index] = item
        model.loadVideo(pair: item.sourcePair, restoring: model.makeProjectState())
    }

    private func updateSelectedExternalAlphaSettings(_ settings: ExternalAlphaSettings) {
        guard let index = selectedImportedVideoIndex else { return }
        let update = AlphaCheaterImportedVideoState.updatingExternalAlphaSettings(
            settings,
            for: importedVideos[index]
        )
        guard update.requiresReload else { return }
        importedVideos[index] = update.item
        model.loadVideo(pair: update.item.sourcePair, restoring: model.makeProjectState())
    }

    private var alphaCapableVideoContentTypes: [UTType] {
        var types: [UTType] = [.movie, .audiovisualContent]
        for ext in ["mkv", "mov", "mp4", "m4v", "avi", "webm"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    private var importableContentTypes: [UTType] {
        var types: [UTType] = [.movie]
        for ext in MeshVolumeLoader.supportedFileExtensions.sorted() {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    private func addImportedVideos(_ urls: [URL], preferredSelectionURL: URL? = nil) {
        var firstNewID: UUID?
        var preferredID: UUID?
        for url in urls {
            if let existing = importedVideos.first(where: { $0.url == url }) {
                firstNewID = firstNewID ?? existing.id
                if url == preferredSelectionURL {
                    preferredID = existing.id
                }
                continue
            }

            let item = MainImportedVideo(id: UUID(), url: url)
            importedVideos.append(item)
            firstNewID = firstNewID ?? item.id
            if url == preferredSelectionURL {
                preferredID = item.id
            }
        }

        if let selectedID = preferredID ?? firstNewID {
            selectImportedVideo(id: selectedID)
        }
    }

    private func selectImportedVideo(id: UUID) {
        guard let item = importedVideos.first(where: { $0.id == id }) else { return }
        selectedImportedVideoID = id
        runtimeAudit.record(.info, category: "素材", title: "切换当前素材", message: item.name)
        if item.isModel {
            selectedTab = 1
            model.loadStaticMesh(url: item.url)
        } else {
            model.loadVideo(pair: item.sourcePair)
        }
    }

    private var projectContentType: UTType {
        UTType(filenameExtension: ChronoVolumeProjectDocument.fileExtension) ?? .json
    }

    private var projectContentTypes: [UTType] {
        var types = [projectContentType]
        if let legacy = UTType(filenameExtension: ChronoVolumeProjectDocument.legacyFileExtension),
           legacy != projectContentType {
            types.append(legacy)
        }
        return types
    }

    @discardableResult
    private func saveProject() -> Bool {
        if let currentProjectURL {
            return writeProject(to: currentProjectURL)
        }

        return saveProjectAs()
    }

    @discardableResult
    private func saveProjectAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [projectContentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = currentProjectURL.map {
            projectFileName(for: $0.deletingPathExtension().lastPathComponent)
        } ?? defaultProjectFileName()
        panel.directoryURL = currentProjectURL?.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        return writeProject(to: url)
    }

    @discardableResult
    private func writeProject(to url: URL) -> Bool {
        do {
            try makeProjectDocument().write(to: url)
            currentProjectURL = url
            compositionModel.projectFilePathForDiagnostics = url.path
            savedProjectSignature = makeProjectSignature()
            lastAutosaveSignature = savedProjectSignature
            removeAutosaveRecovery()
            model.status = "项目已保存：\(url.lastPathComponent)"
            compositionModel.status = "项目已保存：\(url.lastPathComponent)"
            runtimeAudit.record(.success, category: "项目", title: "保存项目", message: url.lastPathComponent)
            return true
        } catch {
            model.status = "项目保存失败：\(error.localizedDescription)"
            runtimeAudit.record(.error, category: "项目", title: "保存项目失败", message: error.localizedDescription)
            return false
        }
    }

    private func makeProjectDocument(
        autosaveOriginalProjectPath: String? = nil
    ) -> ChronoVolumeProjectDocument {
        var document = ChronoVolumeProjectDocument()
        document.formatVersion = ChronoVolumeProjectDocument.currentFormatVersion
        document.savedAt = Date()
        document.autosaveOriginalProjectPath = autosaveOriginalProjectPath
        document.autosaveCreatedAt = autosaveOriginalProjectPath == nil ? nil : Date()
        document.selectedTab = selectedTab
        document.mainVideos = importedVideos.map {
            let sourcePair = $0.sourcePair
            return ChronoVolumeProjectDocument.MainVideoRecord(
                id: $0.id,
                path: $0.url.path,
                name: $0.name,
                colorBookmark: securityScopedBookmark(for: $0.url),
                alphaPath: sourcePair.alphaURL?.path,
                alphaBookmark: sourcePair.alphaURL.flatMap(securityScopedBookmark),
                alphaSourceMode: sourcePair.alphaSourceMode,
                externalAlphaSettings: sourcePair.externalAlphaSettings,
                usesGeneratedWhiteColor: sourcePair.usesGeneratedWhiteColor,
                isAlphaCheater: $0.isAlphaCheater,
                pairingKey: $0.pairingKey
            )
        }
        document.selectedMainVideoID = selectedImportedVideoID
        document.appState = model.makeProjectState()
        document.exportOptions = exportOptions.makeProjectState()
        document.distributed = distributedSettings.makeProjectState()
        document.composition = compositionModel.makeProjectState()
        return document
    }

    private func securityScopedBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private var autosaveRecoveryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ChronoVolume", isDirectory: true)
            .appendingPathComponent("Autosave", isDirectory: true)
            .appendingPathComponent("ChronoVolume-Recovery.\(ChronoVolumeProjectDocument.fileExtension)")
    }

    private func promptForAutosaveRecoveryIfNeeded() {
        guard !didCheckAutosaveRecovery else { return }
        didCheckAutosaveRecovery = true

        let url = autosaveRecoveryURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        DispatchQueue.main.async {
            do {
                let document = try ChronoVolumeProjectDocument.read(from: url)
                showAutosaveRecoveryPrompt(document: document, recoveryURL: url)
            } catch {
                model.status = "自动恢复文件读取失败：\(error.localizedDescription)"
            }
        }
    }

    private func showAutosaveRecoveryPrompt(
        document: ChronoVolumeProjectDocument,
        recoveryURL: URL
    ) {
        let alert = NSAlert()
        alert.messageText = "发现自动保存的恢复项目"
        let autosaveDate = document.autosaveCreatedAt ?? document.savedAt
        alert.informativeText = "ChronoVolume 上次可能没有正常关闭。是否恢复 \(autosaveDate.formatted(date: .abbreviated, time: .standard)) 的自动保存项目？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "丢弃")
        alert.addButton(withTitle: "稍后")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            runtimeAudit.record(.warning, category: "项目", title: "恢复自动保存", message: recoveryURL.lastPathComponent)
            restoreProject(document, from: recoveryURL, recoveredAutosave: true)
        case .alertSecondButtonReturn:
            runtimeAudit.record(.info, category: "项目", title: "丢弃自动保存", message: recoveryURL.lastPathComponent)
            removeAutosaveRecovery()
        default:
            break
        }
    }

    private func performAutosaveIfNeeded() {
        guard !exportRuntime.isExporting else { return }
        guard hasUnsavedProjectChanges else {
            removeAutosaveRecovery()
            lastAutosaveSignature = savedProjectSignature
            return
        }
        guard let signature = makeProjectSignature(),
              signature != lastAutosaveSignature else {
            return
        }

        do {
            let url = autosaveRecoveryURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try makeProjectDocument(
                autosaveOriginalProjectPath: currentProjectURL?.path
            ).write(to: url)
            lastAutosaveSignature = signature
            runtimeAudit.record(.success, category: "项目", title: "自动保存", message: url.lastPathComponent)
        } catch {
            model.status = "自动保存失败：\(error.localizedDescription)"
            runtimeAudit.record(.error, category: "项目", title: "自动保存失败", message: error.localizedDescription)
        }
    }

    private func removeAutosaveRecovery() {
        try? FileManager.default.removeItem(at: autosaveRecoveryURL)
    }

    private func makeProjectSignature() -> Data? {
        var document = makeProjectDocument()
        document.savedAt = Date(timeIntervalSince1970: 0)
        document.autosaveOriginalProjectPath = nil
        document.autosaveCreatedAt = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(document)
    }

    private var hasUnsavedProjectChanges: Bool {
        guard let savedProjectSignature,
              let currentSignature = makeProjectSignature() else {
            return false
        }
        return savedProjectSignature != currentSignature
    }

    private func confirmCloseIfNeeded() -> Bool {
        guard hasUnsavedProjectChanges else {
            removeAutosaveRecovery()
            lastAutosaveSignature = savedProjectSignature
            return true
        }

        let alert = NSAlert()
        alert.messageText = "项目尚未保存"
        alert.informativeText = "关闭 ChronoVolume 前要保存当前项目吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveProject()
        case .alertSecondButtonReturn:
            removeAutosaveRecovery()
            lastAutosaveSignature = nil
            return true
        default:
            return false
        }
    }

    private func newProject() {
        guard !exportRuntime.isExporting else { return }
        guard confirmCloseIfNeeded() else { return }
        runtimeAudit.record(.info, category: "项目", title: "新建项目", message: "重置当前工作区")
        resetProject(status: "已新建项目")
    }

    private func closeProject() {
        guard !exportRuntime.isExporting else { return }
        guard confirmCloseIfNeeded() else { return }
        runtimeAudit.record(.info, category: "项目", title: "关闭项目", message: currentProjectURL?.lastPathComponent ?? "未保存项目")
        resetProject(status: "项目已关闭")
    }

    private func resetProject(status: String) {
        removeAutosaveRecovery()
        lastAutosaveSignature = nil
        currentProjectURL = nil
        compositionModel.projectFilePathForDiagnostics = nil
        selectedTab = 0
        importedVideos = []
        selectedImportedVideoID = nil

        exportOptions.restoreProjectState(ChronoVolumeProjectDocument.ExportOptionsProjectState())
        distributedSettings.restoreProjectState(ChronoVolumeProjectDocument.DistributedExportProjectState())
        compositionModel.restoreProjectState(ChronoVolumeProjectDocument.CompositionProjectState())
        compositionModel.status = status
        model.resetForNewProject(statusMessage: status)

        savedProjectSignature = makeProjectSignature()
    }

    private func openProject() {
        guard confirmCloseIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = projectContentTypes

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let document = try ChronoVolumeProjectDocument.read(from: url)
            restoreProject(document, from: url)
            removeAutosaveRecovery()
            runtimeAudit.record(.success, category: "项目", title: "打开项目", message: url.lastPathComponent)
        } catch {
            model.status = "项目打开失败：\(error.localizedDescription)"
            runtimeAudit.record(.error, category: "项目", title: "打开项目失败", message: error.localizedDescription)
        }
    }

    private func restoreProject(
        _ document: ChronoVolumeProjectDocument,
        from url: URL,
        recoveredAutosave: Bool = false
    ) {
        if recoveredAutosave,
           let originalPath = document.autosaveOriginalProjectPath,
           !originalPath.isEmpty {
            currentProjectURL = URL(fileURLWithPath: originalPath)
        } else {
            currentProjectURL = recoveredAutosave ? nil : url
        }
        compositionModel.projectFilePathForDiagnostics = currentProjectURL?.path
        selectedTab = max(0, min(2, document.selectedTab))
        exportOptions.restoreProjectState(document.exportOptions)
        distributedSettings.restoreProjectState(document.distributed)
        compositionModel.restoreProjectState(document.composition)

        let mainRestorationResults = document.mainVideos.map {
            MainImportedVideo.restorationResult(from: $0)
        }
        var restoredVideos = mainRestorationResults.map(\.item)
        for asset in document.composition.assets
        where !restoredVideos.contains(where: { $0.url.path == asset.path }) {
            restoredVideos.append(MainImportedVideo(id: asset.id, url: asset.url))
        }
        importedVideos = restoredVideos
        for diagnostic in mainRestorationResults.compactMap(\.pairingDiagnostic) {
            runtimeAudit.record(
                .warning,
                category: "项目",
                title: "AlphaCheater 配对身份兼容",
                message: diagnostic
            )
        }

        let restoredSelectedID = document.selectedMainVideoID.flatMap { id in
            restoredVideos.contains(where: { $0.id == id }) ? id : nil
        } ?? restoredVideos.first?.id
        selectedImportedVideoID = restoredSelectedID

        if let selectedID = restoredSelectedID,
           let selectedVideo = restoredVideos.first(where: { $0.id == selectedID }),
           FileManager.default.fileExists(atPath: selectedVideo.url.path) {
            if selectedVideo.isModel {
                model.loadStaticMesh(url: selectedVideo.url, restoring: document.appState)
            } else {
                model.loadVideo(pair: selectedVideo.sourcePair, restoring: document.appState)
            }
        } else {
            model.restoreProjectState(document.appState)
            model.status = restoredVideos.isEmpty ? "项目已打开：\(url.lastPathComponent)" : "项目已打开，但主视频文件不存在"
        }
        compositionModel.status = document.composition.assets.isEmpty
            ? "项目已打开：\(url.lastPathComponent)"
            : "项目已打开，正在恢复素材…"
        if recoveredAutosave {
            savedProjectSignature = Data()
            lastAutosaveSignature = makeProjectSignature()
            model.status = "已恢复自动保存项目，请保存以保留恢复结果"
            compositionModel.status = "已恢复自动保存项目，请保存以保留恢复结果"
            runtimeAudit.record(.warning, category: "项目", title: "已恢复自动保存项目", message: url.lastPathComponent)
        } else {
            savedProjectSignature = makeProjectSignature()
            lastAutosaveSignature = savedProjectSignature
        }
    }

    private func defaultProjectFileName() -> String {
        let rawName = compositionModel.composition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = rawName.isEmpty ? "ChronoVolume Project" : rawName
        return projectFileName(for: baseName)
    }

    private func projectFileName(for baseName: String) -> String {
        let lowercased = baseName.lowercased()
        let primaryExtension = ChronoVolumeProjectDocument.fileExtension.lowercased()
        let legacyExtension = ChronoVolumeProjectDocument.legacyFileExtension.lowercased()
        if lowercased.hasSuffix(".\(primaryExtension)") || lowercased.hasSuffix(".\(legacyExtension)") {
            return baseName
        }
        return "\(baseName).\(ChronoVolumeProjectDocument.fileExtension)"
    }
}

private struct ReferencePlaneControls: View {
    @ObservedObject var model: AppModel
    var onOpen3D: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AngleInputRow(
                title: "Yaw（偏航）",
                value: Binding(
                    get: { model.referencePlane.yawDegrees },
                    set: { model.stageReferencePlane(yaw: $0) }
                ),
                applyAction: {
                    model.applyReferencePlane()
                }
            )

            AngleInputRow(
                title: "Pitch（俯仰）",
                value: Binding(
                    get: { model.referencePlane.pitchDegrees },
                    set: { model.stageReferencePlane(pitch: $0) }
                ),
                applyAction: {
                    model.applyReferencePlane()
                }
            )

            AngleInputRow(
                title: "Roll（滚转）",
                value: Binding(
                    get: { model.referencePlane.rollDegrees },
                    set: { model.stageReferencePlane(roll: $0) }
                ),
                applyAction: {
                    model.applyReferencePlane()
                }
            )

            HStack {
                Button("应用参考面") {
                    model.applyReferencePlane()
                }
                Button("复位参考面") {
                    model.resetReferencePlane()
                }
                if let onOpen3D {
                    Button("在3D中查看") {
                        onOpen3D()
                    }
                }
            }
        }
    }
}

private struct CameraWorkspace3D: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HSplitView {
            ZStack(alignment: .topLeading) {
                MetalVolumeView(model: model, role: .main, allowsInteraction: true)
                    .background(backgroundView)

                VolumeOverlayView(model: model)

                if let message = model.modifierLoadingMessage {
                    ModifierLoadingOverlay(message: message)
                }
            }
            .frame(minWidth: 520)

            if !model.isCameraPreviewFloating {
                VStack(alignment: .leading, spacing: 8) {
                    Text("摄像机视图")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)

                    ZStack {
                        MetalVolumeView(model: model, role: .cameraPreview, allowsInteraction: false)
                            .background(backgroundView)
                        Text("Camera")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if let message = model.modifierLoadingMessage {
                            ModifierLoadingOverlay(message: message)
                        }
                    }
                    .frame(minWidth: 340, minHeight: 260)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("预览使用摄像机参数；左侧仍保留原 3D 交互视角。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text(String(
                            format: "位置: (%.2f, %.2f, %.2f)",
                            model.cameraRig.positionX,
                            model.cameraRig.positionY,
                            model.cameraRig.positionZ
                        ))
                        .font(.footnote.monospacedDigit())

                        Text(String(
                            format: "方向: Yaw %.1f° | Pitch %.1f° | Roll %.1f°",
                            Double(model.cameraRig.yaw) * 180.0 / .pi,
                            Double(model.cameraRig.pitch) * 180.0 / .pi,
                            Double(model.cameraRig.roll) * 180.0 / .pi
                        ))
                        .font(.footnote.monospacedDigit())

                        if model.cameraRig.focusLockEnabled {
                            Text(String(
                                format: "焦点: (%.2f, %.2f, %.2f)",
                                model.cameraRig.focusTargetX,
                                model.cameraRig.focusTargetY,
                                model.cameraRig.focusTargetZ
                            ))
                            .font(.footnote.monospacedDigit())
                        }

                        Text(String(
                            format: "焦段 %.0fmm | 光圈 f/%.1f",
                            model.cameraRig.focalLength,
                            model.cameraRig.aperture
                        ))
                        .font(.footnote.monospacedDigit())
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .frame(minWidth: 360, idealWidth: 420)
            }
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        if model.volumeBackgroundMode == .checkerboard {
            CheckerboardBackground()
        } else {
            Color(
                red: model.volumeBackgroundColor.red,
                green: model.volumeBackgroundColor.green,
                blue: model.volumeBackgroundColor.blue
            )
        }
    }
}

private struct ModifierLoadingBadge: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ModifierLoadingOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(message)
                .font(.callout.weight(.semibold))
            Text("复杂体素操作可能需要几秒到几十秒；期间会先显示低延迟预览，完整体会在后台继续重建。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }
}

private struct CheckerboardBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let tile: CGFloat = 18
            Canvas { context, size in
                let columns = Int(ceil(size.width / tile))
                let rows = Int(ceil(size.height / tile))
                for row in 0..<rows {
                    for column in 0..<columns {
                        let dark = (row + column).isMultiple(of: 2)
                        let rect = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                        context.fill(Path(rect), with: .color(dark ? Color(white: 0.18) : Color(white: 0.32)))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct CameraSliderRow: View {
    enum DisplayMode {
        case number
        case turnsDegrees
    }

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    let resetValue: Double
    var lowerLimit: Double?
    var suffix: String?
    var displayMode: DisplayMode = .number

    @State private var draftText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 82, alignment: .leading)
            Slider(
                value: Binding(
                    get: { sliderDisplayValue },
                    set: { value = valueForSliderChange($0) }
                ),
                in: range,
                onEditingChanged: { editing in
                    handleSliderEditingChanged(editing)
                }
            )

            textField

            if let suffix {
                Text(suffix)
                    .foregroundStyle(.secondary)
            }
            Button("复位") {
                value = resetValue
            }
            .buttonStyle(.borderless)
        }
        .onAppear {
            draftText = formattedValue(value)
        }
        .onChange(of: value) { _, newValue in
            if !isFocused {
                draftText = formattedValue(newValue)
            }
        }
    }

    @ViewBuilder
    private var textField: some View {
        switch displayMode {
        case .number:
            TextField("", value: Binding(
                get: { value },
                set: { value = sanitized($0) }
            ), format: .number.precision(formatPrecision))
                .textFieldStyle(.roundedBorder)
                .frame(width: 74)
        case .turnsDegrees:
            TextField("", text: $draftText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
                .focused($isFocused)
                .onSubmit {
                    commitDraft()
                }
        }
    }

    private func commitDraft() {
        guard displayMode == .turnsDegrees else { return }
        if let parsed = parseTurnsDegrees(draftText) {
            value = sanitized(parsed)
            draftText = formattedValue(value)
        } else {
            draftText = formattedValue(value)
        }
        isFocused = false
    }

    private func sanitized(_ newValue: Double) -> Double {
        if let lowerLimit {
            return max(lowerLimit, newValue)
        }
        return newValue
    }

    private var sliderDisplayValue: Double {
        switch displayMode {
        case .number:
            return min(range.upperBound, max(range.lowerBound, value))
        case .turnsDegrees:
            return min(range.upperBound, max(range.lowerBound, value))
        }
    }

    private func valueForSliderChange(_ sliderValue: Double) -> Double {
        switch displayMode {
        case .number:
            return sanitized(sliderValue)
        case .turnsDegrees:
            return sanitized(sliderValue)
        }
    }

    private func handleSliderEditingChanged(_ editing: Bool) {
        guard displayMode == .turnsDegrees, !editing else { return }
        if !isFocused {
            draftText = formattedValue(value)
        }
    }

    private func formattedValue(_ value: Double) -> String {
        switch displayMode {
        case .number:
            return String(format: format, value)
        case .turnsDegrees:
            return formatTurnsDegrees(value)
        }
    }

    private func formatTurnsDegrees(_ degrees: Double) -> String {
        let parts = decomposeRoundedTurnsDegrees(degrees)
        let turnText = "\(parts.turns)"
        let remainderText: String
        let rounded = Double(parts.tenths) / 10.0
        if abs(rounded.rounded() - rounded) < 0.0001 {
            remainderText = String(format: "%.0f", rounded)
        } else {
            remainderText = String(format: "%.1f", rounded)
        }
        return "\(turnText)x\(remainderText)°"
    }

    private func decomposeRoundedTurnsDegrees(_ degrees: Double) -> (turns: Int, tenths: Int) {
        let totalTenths = Int((degrees * 10.0).rounded())
        let turnTenths = 3600
        if totalTenths >= 0 {
            return (totalTenths / turnTenths, totalTenths % turnTenths)
        }
        let turns = -((-totalTenths) / turnTenths)
        let remainder = totalTenths - turns * turnTenths
        return (turns, remainder)
    }

    private func parseTurnsDegrees(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "X", with: "x")

        guard !normalized.isEmpty else { return nil }
        if normalized.contains("x") {
            let parts = normalized.split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let turns = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let degrees = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return turns * 360.0 + degrees
        }
        return Double(normalized)
    }

    private var formatPrecision: FloatingPointFormatStyle<Double>.Configuration.Precision {
        if format.contains(".0") {
            return .fractionLength(0)
        }
        if format.contains(".1") {
            return .fractionLength(1)
        }
        return .fractionLength(2)
    }
}

private struct CameraFunctionDriverEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("x 是时间线进度 0...1，y 是关键帧插值后的当前值。支持 sin/cos/tan/abs/sqrt/pow/min/max 和 pi。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                CameraExpressionRow(title: "Yaw（偏航）", text: $model.cameraFunctionDriver.yawExpression)
                CameraExpressionRow(title: "Pitch（俯仰）", text: $model.cameraFunctionDriver.pitchExpression)
                CameraExpressionRow(title: "Roll（滚转）", text: $model.cameraFunctionDriver.rollExpression)
                CameraExpressionRow(title: "位置X", text: $model.cameraFunctionDriver.positionXExpression)
                CameraExpressionRow(title: "位置Y", text: $model.cameraFunctionDriver.positionYExpression)
                CameraExpressionRow(title: "位置Z", text: $model.cameraFunctionDriver.positionZExpression)
                CameraExpressionRow(title: "焦段", text: $model.cameraFunctionDriver.focalLengthExpression)
                CameraExpressionRow(title: "光圈", text: $model.cameraFunctionDriver.apertureExpression)

                HStack {
                    Button("应用当前帧函数") {
                        model.setCameraTimelineFrame(model.cameraTimelineFrame)
                    }
                    Button("清空函数") {
                        model.cameraFunctionDriver.yawExpression = ""
                        model.cameraFunctionDriver.pitchExpression = ""
                        model.cameraFunctionDriver.rollExpression = ""
                        model.cameraFunctionDriver.positionXExpression = ""
                        model.cameraFunctionDriver.positionYExpression = ""
                        model.cameraFunctionDriver.positionZExpression = ""
                        model.cameraFunctionDriver.focalLengthExpression = ""
                        model.cameraFunctionDriver.apertureExpression = ""
                        model.setCameraTimelineFrame(model.cameraTimelineFrame)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Toggle("函数驱动 f(x) / f(x,y)", isOn: Binding(
                get: { model.cameraFunctionDriver.isEnabled },
                set: { newValue in
                    model.cameraFunctionDriver.isEnabled = newValue
                    model.setCameraTimelineFrame(model.cameraTimelineFrame)
                }
            ))
        }
    }
}

private struct CameraExpressionRow: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 42, alignment: .leading)
            TextField("例如 y + sin(x*pi*2)*0.25", text: $text)
                .textFieldStyle(.roundedBorder)
        }
        .font(.footnote)
    }
}

private struct CameraExportOptionsEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DisclosureGroup("摄像机导出选项") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("尺寸", selection: $model.cameraExportSizeMode) {
                    ForEach(CameraExportSizeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if model.cameraExportSizeMode == .custom {
                    HStack {
                        Text("宽")
                        TextField("宽", value: $model.cameraExportCustomWidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 78)
                        Text("高")
                        TextField("高", value: $model.cameraExportCustomHeight, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 78)
                    }
                }

                Picker("FPS", selection: $model.cameraExportFPSMode) {
                    ForEach(CameraExportFPSMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if model.cameraExportFPSMode == .custom {
                    HStack {
                        Text("FPS")
                        TextField("FPS", value: $model.cameraExportCustomFPS, format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 92)
                    }
                }

                Picker("背景", selection: $model.cameraExportBackgroundMode) {
                    ForEach(CameraExportBackgroundMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if model.cameraExportBackgroundMode == .color || model.cameraExportBackgroundMode == .checkerboard {
                    HStack {
                        Text("背景颜色")
                        Spacer()
                        StableColorWell(color: $model.cameraExportBackgroundColor)
                            .frame(width: 54, height: 28)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct StableColorWell: NSViewRepresentable {
    @Binding var color: VolumeBackgroundColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(frame: .zero)
        well.supportsAlpha = false
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        well.color = nsColor(from: color)
        return well
    }

    func updateNSView(_ nsView: NSColorWell, context: Context) {
        let next = nsColor(from: color)
        if nsView.color.usingColorSpace(.deviceRGB) != next {
            nsView.color = next
        }
    }

    private func nsColor(from color: VolumeBackgroundColor) -> NSColor {
        NSColor(
            calibratedRed: max(0, min(1, color.red)),
            green: max(0, min(1, color.green)),
            blue: max(0, min(1, color.blue)),
            alpha: 1
        )
    }

    final class Coordinator: NSObject {
        private var parent: StableColorWell

        init(_ parent: StableColorWell) {
            self.parent = parent
        }

        @objc func colorChanged(_ sender: NSColorWell) {
            let c = sender.color.usingColorSpace(.deviceRGB) ?? sender.color
            parent.color = VolumeBackgroundColor(
                red: Double(c.redComponent),
                green: Double(c.greenComponent),
                blue: Double(c.blueComponent)
            )
        }
    }
}

private struct CameraTimelineEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(model.isCameraTimelinePlaying ? "暂停" : "播放") {
                    model.toggleCameraTimelinePlayback()
                }
                Text("帧")
                Slider(
                    value: Binding(
                        get: { Double(model.cameraTimelineFrame) },
                        set: { model.setCameraTimelineFrame(Int($0.rounded())) }
                    ),
                    in: 0...Double(max(1, model.cameraTimelineMaxFrame())),
                    step: 1
                )
                Text("\(model.cameraTimelineFrame)")
                    .frame(width: 52, alignment: .trailing)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.16))
                        .frame(height: 26)

                    ForEach(model.cameraKeyframes) { keyframe in
                        let x = keyframeX(keyframe.frame, width: proxy.size.width)
                        Button {
                            model.applyCameraKeyframe(keyframe)
                        } label: {
                            Diamond()
                                .fill(Color.accentColor)
                                .frame(width: 10, height: 10)
                        }
                        .buttonStyle(.plain)
                        .position(x: x, y: 13)
                        .contextMenu {
                            Button("删除关键帧") {
                                model.deleteCameraKeyframe(keyframe)
                            }
                        }
                    }

                    Rectangle()
                        .fill(Color.red.opacity(0.9))
                        .frame(width: 2, height: 30)
                        .position(x: keyframeX(model.cameraTimelineFrame, width: proxy.size.width), y: 15)
                }
            }
            .frame(height: 32)

            if model.cameraKeyframes.isEmpty {
                Text("添加关键帧后，播放时会自动插值摄像机位置、方向、焦段和光圈。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("关键帧")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    ForEach(model.cameraKeyframes) { keyframe in
                        HStack {
                            Button("帧 \(keyframe.frame)") {
                                model.applyCameraKeyframe(keyframe)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button("删除") {
                                model.deleteCameraKeyframe(keyframe)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
    }

    private func keyframeX(_ frame: Int, width: CGFloat) -> CGFloat {
        let maxFrame = max(1, model.cameraTimelineMaxFrame())
        return max(0, min(width, CGFloat(frame) / CGFloat(maxFrame) * width))
    }
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

struct CameraFloatingPreviewWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.volumeBackgroundMode == .checkerboard {
                    CheckerboardBackground()
                } else {
                    Color(
                        red: model.volumeBackgroundColor.red,
                        green: model.volumeBackgroundColor.green,
                        blue: model.volumeBackgroundColor.blue
                    )
                }
                MetalVolumeView(model: model, role: .cameraPreview, allowsInteraction: false)
                Text("摄像机视图")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            HStack {
                Button(model.isCameraTimelinePlaying ? "暂停" : "播放") {
                    model.toggleCameraTimelinePlayback()
                }
                Slider(
                    value: Binding(
                        get: { Double(model.cameraTimelineFrame) },
                        set: { model.setCameraTimelineFrame(Int($0.rounded())) }
                    ),
                    in: 0...Double(max(1, model.cameraTimelineMaxFrame())),
                    step: 1
                )
                Text("\(model.cameraTimelineFrame)")
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct AngleInputRow: View {
    let title: String
    @Binding var value: Float
    let applyAction: () -> Void

    @State private var draftText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 42, alignment: .leading)

            Slider(
                value: Binding(
                    get: { min(180.0, max(-180.0, Double(value))) },
                    set: { newValue in
                        value = Float(newValue)
                        if !isFocused {
                            draftText = Self.formatValue(value)
                        }
                    }
                ),
                in: -180...180
            )

            TextField("", text: $draftText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .focused($isFocused)
                .onAppear {
                    draftText = Self.formatValue(value)
                }
                .onChange(of: value) { _, newValue in
                    if !isFocused {
                        draftText = Self.formatValue(newValue)
                    }
                }
                .onSubmit {
                    commitDraft()
                }

            Button("确认") {
                commitDraft()
            }
            .buttonStyle(.borderless)

            Text("°")
                .foregroundStyle(.secondary)
        }
    }

    private func commitDraft() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draftText = Self.formatValue(value)
            isFocused = false
            return
        }

        if let parsed = Float(trimmed) {
            value = parsed
            draftText = Self.formatValue(parsed)
            applyAction()
        } else {
            draftText = Self.formatValue(value)
        }

        isFocused = false
    }

    private static func formatValue(_ value: Float) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.0001 {
            return String(Int(rounded.rounded()))
        }
        return String(format: "%.1f", rounded)
    }
}

private struct SlicePreviewPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isVideoVolumeModifierActive && model.sliceMode == .axis && model.playbackAxis == .t {
                SliceMetalView(model: model)
                    .background(Color.black)
            } else if model.hasMeshSlicePreview && model.isPlaying && model.sliceMode == .axis && model.playbackAxis == .t {
                SliceMetalView(model: model)
                    .background(Color.black)
            } else if model.usesGeneratedTimeAxisPreview && model.sliceMode == .axis && model.playbackAxis == .t {
                SlicePreviewView(model: model)
            } else if model.sliceMode == .axis && model.playbackAxis == .t {
                NativeVideoPlayerView(model: model)
                    .background(Color.black)
            } else if model.sliceMode == .plane {
                PlaneSliceMetalView(model: model)
                    .background(Color.black)
            } else if model.sliceMode == .axis && (model.playbackAxis == .x || model.playbackAxis == .y) {
                AxisSliceMetalView(model: model)
                    .background(Color.black)
            } else {
                SlicePreviewView(model: model)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    model.setCurrentIndex(max(0, model.currentIndex - 1))
                } label: {
                    Image(systemName: "backward.frame")
                }
                .disabled(model.totalFrameCountForCurrentMode() == 0)

                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(model.totalFrameCountForCurrentMode() == 0)

                Button {
                    let total = model.totalFrameCountForCurrentMode()
                    model.setCurrentIndex(min(max(0, total - 1), model.currentIndex + 1))
                } label: {
                    Image(systemName: "forward.frame")
                }
                .disabled(model.totalFrameCountForCurrentMode() == 0)

                let total = model.totalFrameCountForCurrentMode()

                if total > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(min(model.currentIndex, total - 1)) },
                            set: { model.setCurrentIndex(Int($0.rounded())) }
                        ),
                        in: 0...Double(total - 1),
                        step: 1
                    )
                } else {
                    Slider(value: .constant(0), in: 0...1, step: 1)
                        .disabled(true)
                }

                Text(total > 0 ? "\(model.currentIndex)/\(total - 1)" : "-")
                    .monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }
}
