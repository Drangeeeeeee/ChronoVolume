import AppKit
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

private var isShiftDown: Bool {
    NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
}

private var isCommandDown: Bool {
    NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
}

private func endCompositionTextEditing() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

private struct CompositionFocusDismissMonitor: NSViewRepresentable {
    final class Coordinator {
        var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                guard let window = event.window, window.isKeyWindow else { return event }
                let hitView = window.contentView?.hitTest(event.locationInWindow)
                if !Self.isTextInput(hitView) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        static func isTextInput(_ view: NSView?) -> Bool {
            var current = view
            while let view = current {
                if view is NSTextField || view is NSTextView {
                    return true
                }
                current = view.superview
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
            coordinator.monitor = nil
        }
    }
}

private struct LayerHeaderInteractionCatcher: NSViewRepresentable {
    let dragThreshold: CGFloat
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.dragThreshold = dragThreshold
        view.onClick = onClick
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: InteractionView, context: Context) {
        nsView.dragThreshold = dragThreshold
        nsView.onClick = onClick
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
    }

    final class InteractionView: NSView {
        var dragThreshold: CGFloat = 10
        var onClick: ((NSEvent.ModifierFlags) -> Void)?
        var onDragChanged: ((CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
        private var mouseDownPoint: CGPoint?
        private var mouseDownFlags: NSEvent.ModifierFlags = []
        private var hasStartedDrag = false

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            mouseDownFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            hasStartedDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownPoint else { return }
            let point = convert(event.locationInWindow, from: nil)
            let translationY = point.y - start.y
            if !hasStartedDrag {
                let translationX = point.x - start.x
                guard hypot(translationX, translationY) >= dragThreshold else { return }
                hasStartedDrag = true
            }
            onDragChanged?(translationY)
        }

        override func mouseUp(with event: NSEvent) {
            if hasStartedDrag {
                onDragEnded?()
            } else {
                let flags = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .union(mouseDownFlags)
                onClick?(flags)
            }
            mouseDownPoint = nil
            mouseDownFlags = []
            hasStartedDrag = false
        }
    }
}

private let compositionTimelineCoordinateSpace = "compositionTimelineCoordinateSpace"

private enum CompositionKeyframeTimelineMode: String, CaseIterable, Identifiable {
    case keyframes
    case curves

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyframes: return "关键帧"
        case .curves: return "曲线"
        }
    }
}

enum CompositionPreviewMode: String, CaseIterable, Identifiable {
    case world
    case camera
    case allCameras

    var id: String { rawValue }

    var title: String {
        switch self {
        case .world: return "世界视图"
        case .camera: return "摄像机视图"
        case .allCameras: return "所有摄像机视图"
        }
    }

    static var defaultWorldCamera: CameraRigState {
        var camera = CameraRigState()
        camera.positionZ = 3.0
        return camera
    }
}

struct CompositionWorkspaceView: View {
    @ObservedObject var model: CompositionModel
    @State private var previewMode: CompositionPreviewMode = .camera
    @State private var worldPreviewCamera = CompositionPreviewMode.defaultWorldCamera
    @State private var cameraPreviewOffsets: [UUID: CGSize] = [:]
    @State private var cameraPreviewDragStarts: [UUID: CGSize] = [:]
    @State private var previewResizeStartRatio: Double?
    @State private var inspectorResizeStartWidth: Double?

    var body: some View {
        VStack(spacing: 0) {
            compositionTabBar
            GeometryReader { proxy in
                let availableHeight = max(1, proxy.size.height)
                let previewHeight = resolvedPreviewHeight(totalHeight: availableHeight)
                VStack(spacing: 0) {
                    previewArea
                        .frame(height: previewHeight)
                        .overlay(alignment: .topTrailing) {
                            previewControls
                        }
                        .overlay {
                            previewHintLayer
                        }

                    previewTimelineResizeHandle(totalHeight: availableHeight)

                    timelineAndInspectorPane
                        .frame(height: max(240, availableHeight - previewHeight - 8))
                }
            }
        }
        .sheet(isPresented: $model.isShowingNewCompositionSheet) {
            NewCompositionSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingCompositionSettingsSheet) {
            CompositionSettingsSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingCompositionExportSettingsSheet) {
            CompositionExportSettingsSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingMediaManagerSheet) {
            CompositionMediaManagerSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingCachePolicyCenterSheet) {
            CompositionCachePolicyCenterSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingPerformanceDiagnosticsSheet) {
            CompositionPerformanceDiagnosticsSheet(model: model)
        }
        .background {
            CompositionFocusDismissMonitor()
                .frame(width: 0, height: 0)
        }
    }

    private var compositionTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.openCompositionTabIDs, id: \.self) { id in
                    compositionTab(id)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 1)
        }
    }

    private func compositionTab(_ id: UUID) -> some View {
        let isActive = model.activeCompositionTabID == id
        return HStack(spacing: 6) {
            Image(systemName: id == CompositionModel.rootCompositionAssetID ? "rectangle.3.group" : "square.stack.3d.up")
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.compositionTabTitle(for: id))
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(model.compositionTabDetail(for: id))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if id != CompositionModel.rootCompositionAssetID {
                Button {
                    model.closeCompositionTab(id: id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isActive ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.openCompositionTab(id: id)
        }
        .help(id == CompositionModel.rootCompositionAssetID ? "主合成" : "预合成标签页")
    }

    private var timelineAndInspectorPane: some View {
        HStack(spacing: 0) {
            CompositionTimelineView(model: model)
                .frame(minWidth: 520, maxWidth: .infinity)

            if model.workspaceLayout.showDetachedInspector {
                Rectangle()
                    .fill(Color.secondary.opacity(0.001))
                    .frame(width: 10)
                    .overlay {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 1)
                    }
                    .gesture(inspectorResizeGesture)
                    .help("拖动调整独立属性面板宽度")

                CompositionDetachedInspectorPanel(
                    model: model,
                    width: CGFloat(model.workspaceLayout.detachedInspectorWidth)
                )
                .frame(width: CGFloat(model.workspaceLayout.detachedInspectorWidth))
            }
        }
    }

    private func resolvedPreviewHeight(totalHeight: CGFloat) -> CGFloat {
        let ratio = min(0.78, max(0.24, model.workspaceLayout.previewHeightRatio))
        let raw = totalHeight * ratio
        return min(max(220, raw), max(220, totalHeight - 260))
    }

    private func previewTimelineResizeHandle(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.001))
            .frame(height: 8)
            .overlay {
                Rectangle()
                    .fill(Color.secondary.opacity(0.26))
                    .frame(height: 1)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if previewResizeStartRatio == nil {
                            previewResizeStartRatio = model.workspaceLayout.previewHeightRatio
                        }
                        let start = previewResizeStartRatio ?? model.workspaceLayout.previewHeightRatio
                        let next = start + Double(value.translation.height / max(1, totalHeight))
                        model.workspaceLayout.previewHeightRatio = min(0.78, max(0.24, next))
                    }
                    .onEnded { _ in
                        previewResizeStartRatio = nil
                    }
            )
            .help("拖动调整预览区与时间线比例，布局会随项目保存")
    }

    private var inspectorResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if inspectorResizeStartWidth == nil {
                    inspectorResizeStartWidth = model.workspaceLayout.detachedInspectorWidth
                }
                let start = inspectorResizeStartWidth ?? model.workspaceLayout.detachedInspectorWidth
                let next = start - Double(value.translation.width)
                model.workspaceLayout.detachedInspectorWidth = min(520, max(280, next))
            }
            .onEnded { _ in
                inspectorResizeStartWidth = nil
            }
    }

    @ViewBuilder
    private var previewArea: some View {
        switch previewMode {
        case .world:
            previewPane(mode: .world)
        case .camera:
            previewPane(mode: .camera)
        case .allCameras:
            allCameraPreviewPane
        }
    }

    private func previewPane(
        mode: CompositionPreviewMode,
        cameraClipID: UUID? = nil,
        title: String? = nil
    ) -> some View {
        CompositionMetalView(
            model: model,
            previewMode: mode,
            cameraClipID: cameraClipID,
            worldCamera: $worldPreviewCamera
        )
        .background {
            compositionPreviewBackground
        }
        .overlay {
            if mode == .world {
                ZStack {
                    CompositionCameraWorldOverlay(
                        model: model,
                        worldCamera: worldPreviewCamera
                    )
                    CompositionTransformGizmoOverlay(
                        model: model,
                        worldCamera: worldPreviewCamera
                    )
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    endCompositionTextEditing()
                }
        )
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title ?? mode.title)
                    .font(.caption.bold())
                Text(model.status)
                    .font(.caption)
                Text(model.compositionPreviewQualityStatusText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(8)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .padding(10)
        }
    }

    private var allCameraPreviewPane: some View {
        GeometryReader { proxy in
            let clips = Array(model.visibleCameraClips().enumerated())
            ZStack {
                previewPane(mode: .world, title: "世界视图")
                    .frame(width: proxy.size.width, height: proxy.size.height)

                ForEach(clips, id: \.element.id) { index, clip in
                    floatingCameraPreview(
                        clip: clip,
                        index: index,
                        containerSize: proxy.size
                    )
                }
            }
        }
    }

    private func floatingCameraPreview(
        clip: CompositionCameraClip,
        index: Int,
        containerSize: CGSize
    ) -> some View {
        let windowSize = floatingCameraWindowSize(containerSize: containerSize)
        let base = floatingCameraBasePosition(index: index, containerSize: containerSize, windowSize: windowSize)
        let offset = cameraPreviewOffsets[clip.id] ?? .zero
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "video")
                    .font(.caption2)
                Text(clip.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(clip.startFrame) +\(clip.duration)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.black.opacity(0.58))
            .contentShape(Rectangle())
            .gesture(floatingCameraDragGesture(clipID: clip.id))
            .onTapGesture {
                model.selectCameraClip(clip.id)
            }

            previewPane(mode: .camera, cameraClipID: clip.id, title: nil)
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(model.selectedCameraClipID == clip.id ? Color.purple : Color.white.opacity(0.52), lineWidth: 1.2)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(0.72))
                .padding(6)
                .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 5))
                .padding(5)
                .contentShape(Rectangle())
                .gesture(floatingCameraDragGesture(clipID: clip.id))
        }
        .shadow(color: .black.opacity(0.42), radius: 10)
        .position(x: base.x + offset.width, y: base.y + offset.height)
        .onTapGesture {
            model.selectCameraClip(clip.id)
        }
    }

    private func floatingCameraDragGesture(clipID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if cameraPreviewDragStarts[clipID] == nil {
                    cameraPreviewDragStarts[clipID] = cameraPreviewOffsets[clipID] ?? .zero
                }
                let start = cameraPreviewDragStarts[clipID] ?? .zero
                cameraPreviewOffsets[clipID] = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
            }
            .onEnded { _ in
                cameraPreviewDragStarts[clipID] = nil
            }
    }

    private func floatingCameraWindowSize(containerSize: CGSize) -> CGSize {
        let width = min(300, max(220, containerSize.width * 0.24))
        let height = width * 0.62
        return CGSize(width: width, height: height)
    }

    private func floatingCameraBasePosition(
        index: Int,
        containerSize: CGSize,
        windowSize: CGSize
    ) -> CGPoint {
        let margin: CGFloat = 18
        let gap: CGFloat = 12
        let column = index / 2
        let verticalStep = windowSize.height + gap
        let topY = margin + windowSize.height / 2 + CGFloat(column) * verticalStep
        let bottomY = containerSize.height - margin - windowSize.height / 2 - CGFloat(column) * verticalStep
        let y = index.isMultiple(of: 2) ? topY : bottomY
        let x = index.isMultiple(of: 4) || index % 4 == 1
            ? margin + windowSize.width / 2
            : containerSize.width - margin - windowSize.width / 2
        return CGPoint(
            x: min(max(margin + windowSize.width / 2, x), max(margin + windowSize.width / 2, containerSize.width - margin - windowSize.width / 2)),
            y: min(max(margin + windowSize.height / 2, y), max(margin + windowSize.height / 2, containerSize.height - margin - windowSize.height / 2))
        )
    }

    private var previewControls: some View {
        HStack(spacing: 8) {
            Toggle("属性面板", isOn: Binding(
                get: { model.workspaceLayout.showDetachedInspector },
                set: { model.workspaceLayout.showDetachedInspector = $0 }
            ))
            .toggleStyle(.checkbox)
            .help("在时间线右侧独立显示当前选中的图层或摄像机属性")

            Button("复位世界视图") {
                worldPreviewCamera = CompositionPreviewMode.defaultWorldCamera
            }
            .disabled(previewMode == .camera)

            Picker("合成预览", selection: $previewMode) {
                ForEach(CompositionPreviewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            Picker("质量", selection: Binding(
                get: { model.workspaceLayout.previewQuality },
                set: { model.workspaceLayout.previewQuality = $0 }
            )) {
                ForEach(CompositionPreviewQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 128)
            .help(model.workspaceLayout.previewQuality.detailText)
        }
        .padding(10)
    }

    @ViewBuilder
    private var previewHintLayer: some View {
        if let hint = previewHint {
            Text(hint)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .padding(14)
                .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var compositionPreviewBackground: some View {
        if model.composition.backgroundTransparent {
            CompositionCheckerboardBackground()
        } else {
            Color(
                red: model.composition.backgroundColor.red,
                green: model.composition.backgroundColor.green,
                blue: model.composition.backgroundColor.blue
            )
        }
    }

    private var previewHint: String? {
        if model.assets.isEmpty {
            return "导入视频后，点击素材右侧“加入”或拖入下方时间线。"
        }

        if model.assets.contains(where: { !$0.isReady && !$0.status.hasPrefix("导入失败") }) {
            return "素材正在导入，完成后可加入时间线。"
        }

        if model.composition.layers.isEmpty {
            return "素材已就绪，点击“加入”或拖到时间线即可在预览窗口显示。"
        }

        if model.activeRenderLayers().isEmpty {
            return "当前帧没有活动层，移动时间线播放头或调整层的开始/时长。"
        }

        return nil
    }
}

private struct CompositionDetachedInspectorPanel: View {
    @ObservedObject var model: CompositionModel
    let width: CGFloat

    private var propertyPanelWidth: CGFloat {
        max(210, width - 120)
    }

    private var miniatureTimelineWidth: CGFloat {
        max(72, width - propertyPanelWidth - 28)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("属性", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button {
                    model.workspaceLayout.showDetachedInspector = false
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help("隐藏独立属性面板")
            }

            Divider()

            ScrollView {
                if let cameraID = model.selectedCameraClipID {
                    Text("摄像机：\(model.cameraClipName(id: cameraID))")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CompositionCameraInspector(
                        model: model,
                        timelineWidth: miniatureTimelineWidth,
                        propertyPanelWidth: propertyPanelWidth,
                        timelineHorizontalOffset: 0,
                        keyframeTimelineMode: .keyframes,
                        showSelectedKeyframeCurves: false
                    )
                } else if let layerID = model.selectedLayerID,
                          let layerBinding = model.bindingForLayer(id: layerID) {
                    Text("图层")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CompositionLayerInspector(
                        model: model,
                        layer: layerBinding,
                        timelineWidth: miniatureTimelineWidth,
                        propertyPanelWidth: propertyPanelWidth,
                        timelineHorizontalOffset: 0,
                        keyframeTimelineMode: .keyframes,
                        showSelectedKeyframeCurves: false
                    )
                } else if !model.selectedLayerIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已选择 \(model.selectedLayerIDs.count) 个图层")
                            .font(.headline)
                        Text("多选时可在时间线中批量移动、锁定、隐藏、Solo 或预合成。若要编辑具体属性，请选中单个图层。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("未选中对象")
                            .font(.headline)
                        Text("选择一个图层或摄像机后，这里会固定显示它的属性。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
        }
    }
}

struct CompositionProjectPanel: View {
    @ObservedObject var model: CompositionModel

    var body: some View {
        GroupBox("项目管理") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("新建合成") {
                            model.beginNewComposition()
                        }
                        Button("预渲染导出缓存") {
                            model.prepareCompositionExportCachesInteractively()
                        }
                        .disabled(model.assets.isEmpty || model.isCompositionExporting)
                    }

                    HStack {
                        Button("刷新缓存") {
                            model.refreshExportCacheStates()
                        }
                        .disabled(model.assets.isEmpty)

                        Button("检查素材") {
                            model.checkCompositionAssetFiles()
                        }
                        .disabled(model.assets.isEmpty)

                        Button("查找脱机素材") {
                            model.findOfflineCompositionAssetsInteractively()
                        }
                        .disabled(model.assets.isEmpty)
                    }

                    HStack {
                        Button("清理缓存") {
                            model.removeCompositionExportCachesInteractively()
                        }
                        .disabled(model.assets.isEmpty || model.isCompositionExporting)

                        Button("缓存策略") {
                            model.openCachePolicyCenter()
                        }
                        .disabled(model.videoAssets.isEmpty)

                        Button("媒体管理器") {
                            model.openMediaManager()
                        }
                        .disabled(model.mediaAssets.isEmpty || model.isCompositionExporting)

                        Button("性能诊断") {
                            model.openPerformanceDiagnostics()
                        }

                        Button("诊断包") {
                            model.generateDiagnosticsPackageInteractively()
                        }
                    }
                }

                Text("素材：\(model.assets.count)    层：\(model.composition.layers.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("当前合成：\(model.activeCompositionName)")
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 6) {
                    Text("合成")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    let rootDisplay = model.isEditingRootComposition ? model.composition : model.rootComposition
                    CompositionDocumentRow(
                        title: rootDisplay.name,
                        detail: "\(rootDisplay.width) × \(rootDisplay.height) × \(rootDisplay.frameCount)",
                        isActive: model.isEditingRootComposition,
                        canAdd: model.canAddRootCompositionToActive,
                        openAction: {
                            model.openRootComposition()
                        },
                        addAction: {
                            model.addRootCompositionLayer()
                        }
                    )

                    ForEach(model.precompositionAssets) { asset in
                        CompositionAssetRow(
                            asset: asset,
                            isActiveComposition: model.activeCompositionAssetID == asset.id,
                            addAction: {
                                model.addLayer(assetID: asset.id)
                            },
                            openAction: {
                                model.openPrecompositionAsset(id: asset.id)
                            },
                            relinkAction: {
                                model.relinkCompositionAssetInteractively(id: asset.id)
                            },
                            rebuildMeshAction: nil
                        )
                    }
                }

                let mediaAssets = model.mediaAssets
                if mediaAssets.isEmpty {
                    Text("导入的视频或模型会出现在这里。拖到右侧时间线即可成为合成层。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("素材")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(mediaAssets) { asset in
                                CompositionAssetRow(
                                    asset: asset,
                                    isActiveComposition: false,
                                    addAction: {
                                        model.addLayer(assetID: asset.id)
                                    },
                                    openAction: nil,
                                    relinkAction: {
                                        model.relinkCompositionAssetInteractively(id: asset.id)
                                    },
                                    rebuildMeshAction: {
                                        model.rebuildMeshVolumeCacheInteractively(id: asset.id)
                                    }
                                )
                            }
                        }
                    }
                    .frame(minHeight: 130, maxHeight: 260)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CompositionRenderQueuePanel: View {
    @ObservedObject var model: CompositionModel

    private var hasQueuedJobs: Bool {
        model.compositionRenderQueue.contains { $0.status == .queued }
    }

    private var hasFinishedJobs: Bool {
        model.compositionRenderQueue.contains { $0.status == .completed || $0.status == .failed }
    }

    var body: some View {
        GroupBox("渲染队列") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("加入队列") {
                        model.exportCompositionInteractively()
                    }
                    .disabled((model.isCompositionExporting && !model.isCompositionRenderQueueRunning) || model.composition.layers.isEmpty)

                    if model.isCompositionRenderQueuePaused {
                        Button("继续") {
                            model.resumeCompositionRenderQueue()
                        }
                        .disabled(!hasQueuedJobs)
                    } else {
                        Button("暂停") {
                            model.pauseCompositionRenderQueue()
                        }
                        .disabled(model.compositionRenderQueue.isEmpty)
                    }

                    Button("清理完成") {
                        model.clearFinishedCompositionRenderQueueJobs()
                    }
                    .disabled(!hasFinishedJobs)
                }

                Text(model.compositionRenderQueueSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.compositionRenderQueue.isEmpty {
                    Text("可把多个合成导出加入队列，每个任务会保存独立的导出设置、日志和诊断数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(model.compositionRenderQueue) { job in
                                CompositionRenderQueueRow(
                                    job: job,
                                    retryAction: {
                                        model.retryCompositionRenderQueueJob(id: job.id)
                                    },
                                    removeAction: {
                                        model.removeCompositionRenderQueueJob(id: job.id)
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(minHeight: 150, maxHeight: 300)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CompositionRenderQueueRow: View {
    let job: CompositionRenderQueueJob
    let retryAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title)
                        .lineLimit(1)
                    Text(job.outputURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(job.status.title)
                    .font(.caption.bold())
                    .foregroundStyle(statusColor)
            }

            ProgressView(value: job.progress)

            Text(settingsSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if !job.route.isEmpty {
                Text("\(Int((job.progress * 100).rounded()))%｜\(job.route)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let errorMessage = job.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                if job.status == .failed || job.status == .completed {
                    Button("重试") {
                        retryAction()
                    }
                    .font(.caption)
                }

                if let logURL = job.logURL {
                    Button("显示日志") {
                        NSWorkspace.shared.activateFileViewerSelecting([logURL])
                    }
                    .font(.caption)
                }

                Spacer()

                Text(job.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button("移除") {
                    removeAction()
                }
                .font(.caption)
                .disabled(job.status == .running)
            }
        }
        .padding(8)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
    }

    private var settingsSummary: String {
        let alphaText = job.settings.preserveAlpha ? "带 Alpha" : "不带 Alpha"
        let rangeText: String
        switch job.settings.rangeMode {
        case .full:
            rangeText = "完整"
        case .currentToEnd:
            rangeText = "当前到结束"
        case .custom:
            rangeText = "\(job.settings.startFrame)-\(job.settings.endFrame)"
        }
        return "\(job.settings.width) × \(job.settings.height)｜\(String(format: "%.2f", job.settings.fps)) fps｜\(job.settings.bitDepth.title)｜\(alphaText)｜\(job.settings.sourceMode.title)｜范围 \(rangeText)"
    }

    private var statusColor: Color {
        switch job.status {
        case .queued:
            return .secondary
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private var rowBackground: Color {
        switch job.status {
        case .queued:
            return Color(nsColor: .quaternaryLabelColor).opacity(0.45)
        case .running:
            return Color.blue.opacity(0.12)
        case .completed:
            return Color.green.opacity(0.10)
        case .failed:
            return Color.red.opacity(0.10)
        }
    }
}

private struct CompositionDocumentRow: View {
    let title: String
    let detail: String
    let isActive: Bool
    let canAdd: Bool
    let openAction: () -> Void
    let addAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(isActive ? Color.accentColor : Color.purple)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(isActive ? "当前" : "打开") {
                openAction()
            }
            .disabled(isActive)

            Button("加入") {
                addAction()
            }
            .disabled(!canAdd)
        }
        .padding(8)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .onDrag {
            NSItemProvider(object: CompositionModel.rootCompositionAssetID.uuidString as NSString)
        }
    }
}

private struct CompositionAssetRow: View {
    let asset: CompositionAsset
    let isActiveComposition: Bool
    let addAction: () -> Void
    let openAction: (() -> Void)?
    let relinkAction: () -> Void
    let rebuildMeshAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: assetIconName)
                .foregroundStyle(assetIconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .lineLimit(1)
                Text(asset.infoText)
                    .font(.caption)
                    .foregroundStyle(asset.sourceFileMissing ? .orange : .secondary)
                    .lineLimit(3)
                Text(asset.exportCacheText)
                    .font(.caption2)
                    .foregroundStyle(cacheTextColor)
                    .lineLimit(2)
            }

            Spacer()

            if asset.isPrecomposition, let openAction {
                Button(isActiveComposition ? "当前" : "打开") {
                    openAction()
                }
                .disabled(isActiveComposition)
            }

            if asset.sourceFileMissing && asset.isFileBackedMedia {
                Button("查找") {
                    relinkAction()
                }
            }

            if asset.isMesh, let rebuildMeshAction {
                Button("高精度体") {
                    rebuildMeshAction()
                }
                .disabled(asset.sourceFileMissing || asset.isExportCacheBusy)
            }

            Button("加入") {
                addAction()
            }
            .disabled(!asset.isReady)
        }
        .padding(8)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
        .onTapGesture(count: 2) {
            if asset.isPrecomposition, let openAction {
                openAction()
            }
        }
        .onDrag {
            NSItemProvider(object: asset.id.uuidString as NSString)
        }
    }

    private var rowBackground: Color {
        if isActiveComposition {
            return Color.accentColor.opacity(0.12)
        }
        if asset.isPrecomposition {
            return Color.purple.opacity(0.08)
        }
        if asset.isMesh {
            return Color.blue.opacity(0.08)
        }
        return Color(nsColor: .quaternaryLabelColor).opacity(0.45)
    }

    private var cacheTextColor: Color {
        if asset.isPrecomposition {
            return .purple
        }
        switch asset.exportCacheState {
        case .ready:
            return .green
        case .failed:
            return .red
        case .building, .loading:
            return .orange
        case .unknown, .missing:
            return .secondary
        }
    }

    private var assetIconName: String {
        if asset.isPrecomposition {
            return "square.stack.3d.up"
        }
        if asset.isMesh {
            return asset.sourceFileMissing ? "exclamationmark.triangle.fill" : (asset.isReady ? "shippingbox.fill" : "hourglass")
        }
        return asset.sourceFileMissing ? "exclamationmark.triangle.fill" : (asset.isReady ? "film.stack" : "hourglass")
    }

    private var assetIconColor: Color {
        if asset.isPrecomposition {
            return .purple
        }
        if asset.isMesh {
            return asset.sourceFileMissing ? .orange : (asset.isReady ? .blue : .secondary)
        }
        return asset.sourceFileMissing ? .orange : (asset.isReady ? .green : .secondary)
    }
}

private struct CompositionMediaManagerSheet: View {
    @ObservedObject var model: CompositionModel

    private var items: [CompositionMediaManagerItem] {
        model.mediaManagerItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("媒体管理器")
                        .font(.title3.bold())
                    Text("集中查看源文件、bit depth、Alpha、raw cache 和缓存占用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("缓存总量 \(model.mediaManagerTotalCacheSizeText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("刷新检查") {
                    model.refreshMediaManager()
                }
                .disabled(model.videoAssets.isEmpty)

                Button("查找脱机素材") {
                    model.findOfflineCompositionAssetsInteractively()
                }
                .disabled(!items.contains(where: \.isMissing))

                Button("一键清理缓存") {
                    model.clearAllMediaManagerCaches()
                }
                .disabled(items.isEmpty || model.isCompositionExporting)

                Spacer()

                Text("视频素材 \(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("还没有视频素材")
                        .font(.headline)
                    Text("导入视频后，这里会显示源文件状态和 raw cache 信息。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            CompositionMediaManagerRow(
                                item: item,
                                clearAction: {
                                    model.clearMediaManagerCache(assetID: item.id)
                                },
                                relinkAction: {
                                    model.relinkCompositionAssetInteractively(id: item.id)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 260)
            }

            Divider()

            HStack {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                Button("关闭") {
                    model.isShowingMediaManagerSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 780, height: 560)
        .onAppear {
            model.refreshMediaManager()
        }
    }
}

private struct CompositionMediaManagerRow: View {
    let item: CompositionMediaManagerItem
    let clearAction: () -> Void
    let relinkAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.isMissing ? "exclamationmark.triangle.fill" : "film.stack")
                    .foregroundStyle(item.isMissing ? Color.orange : Color.green)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(item.isMissing ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if item.isMissing {
                    Button("重新链接") {
                        relinkAction()
                    }
                }

                Button("清理缓存") {
                    clearAction()
                }
                .disabled(item.rawCacheSizeBytes == 0)
            }

            HStack(spacing: 6) {
                CompositionMediaBadge(
                    title: item.fileStatusText,
                    color: item.isMissing ? .orange : .green
                )
                CompositionMediaBadge(title: item.sourceText, color: .secondary)
                CompositionMediaBadge(title: item.bitDepthText, color: .blue)
                CompositionMediaBadge(
                    title: item.alphaText,
                    color: item.alphaText.hasPrefix("检测到") ? .purple : .secondary
                )
                CompositionMediaBadge(
                    title: item.rawCacheStatusText,
                    color: rawCacheColor
                )
                CompositionMediaBadge(
                    title: "缓存 \(item.rawCacheSizeText)",
                    color: item.rawCacheSizeBytes > 0 ? .teal : .secondary
                )
            }
        }
        .padding(10)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rawCacheColor: Color {
        switch item.exportCacheState {
        case .ready:
            return .green
        case .failed:
            return .red
        case .building, .loading:
            return .orange
        case .unknown, .missing:
            return item.rawCacheStatusText.contains("有缓存") ? .orange : .secondary
        }
    }
}

private struct CompositionCachePolicyCenterSheet: View {
    @ObservedObject var model: CompositionModel
    @State private var includeProxy = true
    @State private var includeHighPrecision = true

    private var items: [CompositionCachePolicyItem] {
        model.cachePolicyItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("缓存策略中心")
                        .font(.title3.bold())
                    Text("统一管理代理缓存、高精度 raw cache、过期判断、后台预构建和清理范围。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("缓存总量 \(model.cachePolicyTotalSizeText)")
                        .font(.caption.monospacedDigit())
                    Text("待处理 \(model.cachePolicyNeedsWorkCount) 个素材")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Toggle("代理", isOn: $includeProxy)
                    .toggleStyle(.checkbox)
                Toggle("高精度", isOn: $includeHighPrecision)
                    .toggleStyle(.checkbox)

                Divider()
                    .frame(height: 18)

                Button("刷新") {
                    model.refreshCachePolicyCenter()
                }
                .disabled(model.videoAssets.isEmpty)

                Button("预构建项目") {
                    model.prebuildProjectCachesFromPolicy(
                        includeProxy: includeProxy,
                        includeHighPrecision: includeHighPrecision
                    )
                }
                .disabled(model.isBuildingCachePolicyCaches || model.videoAssets.isEmpty || (!includeProxy && !includeHighPrecision))

                Button("预构建当前合成") {
                    model.prebuildCurrentCompositionCachesFromPolicy(
                        includeProxy: includeProxy,
                        includeHighPrecision: includeHighPrecision
                    )
                }
                .disabled(model.isBuildingCachePolicyCaches || model.composition.layers.isEmpty || (!includeProxy && !includeHighPrecision))

                Spacer()

                Button("清理当前合成") {
                    model.clearCurrentCompositionCachesFromPolicy()
                }
                .disabled(model.isBuildingCachePolicyCaches || model.composition.layers.isEmpty)

                Button("清理项目") {
                    model.clearProjectCachesFromPolicy()
                }
                .disabled(model.isBuildingCachePolicyCaches || model.videoAssets.isEmpty)
            }

            if model.isBuildingCachePolicyCaches {
                ProgressView("后台预构建缓存中…")
                    .controlSize(.small)
            }

            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.icloud")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("还没有可管理的视频素材")
                        .font(.headline)
                    Text("导入视频后，代理缓存和高精度 raw cache 会出现在这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            CompositionCachePolicyRow(
                                item: item,
                                includeProxy: includeProxy,
                                includeHighPrecision: includeHighPrecision,
                                isBusy: model.isBuildingCachePolicyCaches,
                                prebuildAction: {
                                    model.prebuildAssetCachesFromPolicy(
                                        assetID: item.id,
                                        includeProxy: includeProxy,
                                        includeHighPrecision: includeHighPrecision
                                    )
                                },
                                clearAction: {
                                    model.clearAssetCachesFromPolicy(assetID: item.id)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 310)
            }

            Divider()

            HStack {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                Button("关闭") {
                    model.isShowingCachePolicyCenterSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 900, height: 650)
        .onAppear {
            model.refreshCachePolicyCenter()
        }
    }
}

private struct CompositionCachePolicyRow: View {
    let item: CompositionCachePolicyItem
    let includeProxy: Bool
    let includeHighPrecision: Bool
    let isBusy: Bool
    let prebuildAction: () -> Void
    let clearAction: () -> Void

    private var canPrebuild: Bool {
        !item.sourceMissing &&
            ((includeProxy && item.proxyNeedsBuild) || (includeHighPrecision && item.highPrecisionNeedsBuild))
    }

    private var canClear: Bool {
        item.cacheSizeBytes > 0 || item.proxyStatusText == "已就绪" || item.proxyIsExpired
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.sourceMissing ? "exclamationmark.triangle.fill" : "film.stack")
                    .foregroundStyle(item.sourceMissing ? Color.orange : Color.green)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(item.sourceMissing ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("预构建") {
                    prebuildAction()
                }
                .disabled(isBusy || !canPrebuild)

                Button("清理") {
                    clearAction()
                }
                .disabled(isBusy || !canClear)
            }

            HStack(spacing: 6) {
                CompositionMediaBadge(
                    title: item.sourceMissing ? "源文件丢失" : "源文件存在",
                    color: item.sourceMissing ? .orange : .green
                )
                CompositionMediaBadge(title: item.sourceText, color: .secondary)
                CompositionMediaBadge(
                    title: "代理：\(item.proxyStatusText)",
                    color: proxyColor
                )
                CompositionMediaBadge(
                    title: "高精度：\(item.highPrecisionStatusText)",
                    color: highPrecisionColor
                )
                CompositionMediaBadge(
                    title: item.requiredHighPrecisionAlpha ? "需要 Alpha raw cache" : "需要不带 Alpha raw cache",
                    color: .purple
                )
                CompositionMediaBadge(
                    title: "缓存 \(item.cacheSizeText)",
                    color: item.cacheSizeBytes > 0 ? .teal : .secondary
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("代理：\(item.proxyDetailText)")
                Text("高精度：\(item.highPrecisionDetailText)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .padding(10)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
    }

    private var proxyColor: Color {
        if item.proxyIsExpired { return .orange }
        if item.proxyNeedsBuild { return .secondary }
        return .green
    }

    private var highPrecisionColor: Color {
        if item.highPrecisionIsExpired { return .orange }
        if item.highPrecisionNeedsBuild { return .secondary }
        if item.highPrecisionStatusText.hasPrefix("已就绪") { return .green }
        if item.highPrecisionStatusText.contains("丢失") { return .orange }
        return .secondary
    }
}

private struct CompositionMediaBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(color)
    }
}

private struct CompositionPerformanceDiagnosticsSheet: View {
    @ObservedObject var model: CompositionModel

    private var snapshot: CompositionPerformanceSnapshot {
        model.performanceSnapshot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("性能 / 诊断")
                        .font(.title3.bold())
                    Text("实时查看合成预览 FPS、渲染路径、缓存命中和内存压力。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("刷新：\(timeText(snapshot.updatedAt))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                CompositionPerformanceMetricCard(
                    title: "预览 FPS",
                    value: String(format: "%.1f", snapshot.previewFPS),
                    detail: snapshot.drawableText
                )
                CompositionPerformanceMetricCard(
                    title: "活动层",
                    value: "\(snapshot.activeLayerCount)",
                    detail: "当前时间码可见渲染层"
                )
                CompositionPerformanceMetricCard(
                    title: "纹理占用",
                    value: byteCountText(snapshot.estimatedTextureMemoryBytes),
                    detail: "GPU/shared 纹理估算"
                )
            }

            GroupBox("GPU / CPU 路径") {
                VStack(alignment: .leading, spacing: 8) {
                    diagnosticsLine(title: "预览路径", value: snapshot.previewPathText)
                    diagnosticsLine(title: "素材来源", value: snapshot.sourcePathText)
                    diagnosticsLine(title: "CPU 参与", value: "UI、时间线求值、缓存检查；画面预览由 Metal 绘制")
                }
                .padding(.vertical, 4)
            }

            GroupBox("缓存命中") {
                VStack(alignment: .leading, spacing: 10) {
                    cacheRateRow(
                        title: "预览纹理",
                        hit: snapshot.textureHitCount,
                        miss: snapshot.textureMissCount,
                        rate: snapshot.textureHitRate
                    )
                    cacheRateRow(
                        title: "raw cache",
                        hit: snapshot.rawCacheHitCount,
                        miss: snapshot.rawCacheMissCount,
                        rate: snapshot.rawCacheHitRate
                    )
                }
                .padding(.vertical, 4)
            }

            GroupBox("内存压力") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("进程内存")
                            .frame(width: 76, alignment: .leading)
                        Text("\(byteCountText(snapshot.appMemoryBytes)) / \(byteCountText(snapshot.physicalMemoryBytes))")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Text(snapshot.memoryPressureText)
                            .font(.caption.bold())
                            .foregroundStyle(memoryPressureColor)
                    }
                    ProgressView(value: min(1, max(0, snapshot.memoryPressureLevel)))
                        .tint(memoryPressureColor)
                    Text("这里显示的是 ChronoVolume 当前进程常驻内存占物理内存的比例；Metal 在 Apple Silicon 上通常使用统一内存，所以纹理占用也会反映到内存压力中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("立即刷新") {
                    model.refreshPerformanceDiagnostics()
                }
                Spacer()
                Button("关闭") {
                    model.isShowingPerformanceDiagnosticsSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720)
        .onAppear {
            model.refreshPerformanceDiagnostics()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard model.isShowingPerformanceDiagnosticsSheet else { return }
            model.refreshPerformanceDiagnostics()
        }
    }

    private var memoryPressureColor: Color {
        if snapshot.memoryPressureLevel >= 0.75 { return .red }
        if snapshot.memoryPressureLevel >= 0.50 { return .orange }
        return .green
    }

    private func diagnosticsLine(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func cacheRateRow(title: String, hit: Int, miss: Int, rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .frame(width: 76, alignment: .leading)
                Text("\(hit) 命中 / \(miss) 未命中")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((rate * 100).rounded()))%")
                    .font(.caption.bold().monospacedDigit())
            }
            ProgressView(value: min(1, max(0, rate)))
        }
        .font(.caption)
    }

    private func byteCountText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func byteCountText(_ bytes: UInt64) -> String {
        byteCountText(Int64(min(bytes, UInt64(Int64.max))))
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct CompositionPerformanceMetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.36), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NewCompositionSheet: View {
    @ObservedObject var model: CompositionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建合成")
                .font(.title3.bold())

            HStack {
                Text("名称")
                    .frame(width: 54, alignment: .leading)
                TextField("", text: $model.newCompositionDraft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }

            HStack {
                CompositionIntField(title: "宽", value: $model.newCompositionDraft.width)
                CompositionIntField(title: "高", value: $model.newCompositionDraft.height)
            }

            HStack {
                CompositionIntField(title: "帧数", value: $model.newCompositionDraft.frameCount)
                CompositionDoubleField(title: "FPS", value: $model.newCompositionDraft.fps, width: 72, lowerLimit: 0.05)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("背景")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                CompositionBackgroundPicker(
                    color: $model.newCompositionDraft.backgroundColor,
                    transparent: $model.newCompositionDraft.backgroundTransparent
                )
            }

            HStack {
                Spacer()
                Button("取消") {
                    model.cancelNewComposition()
                }
                .keyboardShortcut(.cancelAction)

                Button("创建") {
                    model.confirmNewComposition()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct CompositionSettingsSheet: View {
    @ObservedObject var model: CompositionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("合成设置")
                .font(.title3.bold())

            HStack {
                Text("名称")
                    .frame(width: 54, alignment: .leading)
                TextField("", text: $model.composition.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }

            HStack {
                CompositionIntField(title: "宽", value: Binding(
                    get: { model.composition.width },
                    set: {
                        model.composition.width = $0
                        model.clampCompositionSettings()
                    }
                ))
                CompositionIntField(title: "高", value: Binding(
                    get: { model.composition.height },
                    set: {
                        model.composition.height = $0
                        model.clampCompositionSettings()
                    }
                ))
            }

            HStack {
                CompositionIntField(title: "帧数", value: Binding(
                    get: { model.composition.frameCount },
                    set: {
                        model.composition.frameCount = $0
                        model.clampCompositionSettings()
                    }
                ))
                CompositionDoubleField(title: "FPS", value: Binding(
                    get: { model.composition.fps },
                    set: {
                        model.composition.fps = $0
                        model.clampCompositionSettings()
                    }
                ), width: 72, lowerLimit: 0.05)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("背景")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                CompositionBackgroundPicker(
                    color: $model.composition.backgroundColor,
                    transparent: $model.composition.backgroundTransparent
                )
            }

            HStack {
                Spacer()
                Button("完成") {
                    model.commitActiveCompositionChanges()
                    model.isShowingCompositionSettingsSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct CompositionExportSettingsSheet: View {
    @ObservedObject var model: CompositionModel

    private var isCustomRange: Bool {
        model.compositionExportSettings.rangeMode == .custom
    }

    private var usesCustomBackground: Bool {
        model.compositionExportSettings.backgroundMode == .custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("合成导出设置")
                .font(.title3.bold())

            GroupBox("画面") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        CompositionIntField(title: "宽", value: Binding(
                            get: { model.compositionExportSettings.width },
                            set: {
                                model.compositionExportSettings.width = $0
                                model.clampCompositionExportSettings()
                            }
                        ))
                        CompositionIntField(title: "高", value: Binding(
                            get: { model.compositionExportSettings.height },
                            set: {
                                model.compositionExportSettings.height = $0
                                model.clampCompositionExportSettings()
                            }
                        ))
                        Button("匹配合成") {
                            model.resetCompositionExportSettingsToComposition()
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 12) {
                        CompositionDoubleField(title: "FPS", value: Binding(
                            get: { model.compositionExportSettings.fps },
                            set: {
                                model.compositionExportSettings.fps = $0
                                model.clampCompositionExportSettings()
                            }
                        ), width: 72, lowerLimit: 0.05)

                        Picker("Bit Depth", selection: $model.compositionExportSettings.bitDepth) {
                            ForEach(ExportBitDepth.allCases) { bitDepth in
                                Text(bitDepth.title).tag(bitDepth)
                            }
                        }
                        .frame(width: 190)

                        Picker("色彩", selection: $model.compositionExportSettings.colorProfile) {
                            ForEach(ExportColorProfile.allCases) { profile in
                                Text(profile.title).tag(profile)
                            }
                        }
                        .frame(width: 210)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("Alpha 与背景") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("导出携带 Alpha 通道", isOn: $model.compositionExportSettings.preserveAlpha)

                    Picker("背景", selection: $model.compositionExportSettings.backgroundMode) {
                        ForEach(CompositionExportBackgroundMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.compositionExportSettings.preserveAlpha)

                    ColorPicker(
                        "自定义背景颜色",
                        selection: Binding(
                            get: {
                                let color = model.compositionExportSettings.backgroundColor
                                return Color(red: color.red, green: color.green, blue: color.blue)
                            },
                            set: { newColor in
                                let resolved = NSColor(newColor).usingColorSpace(.sRGB) ?? .black
                                model.compositionExportSettings.backgroundColor = VolumeBackgroundColor(
                                    red: max(0, min(1, resolved.redComponent)),
                                    green: max(0, min(1, resolved.greenComponent)),
                                    blue: max(0, min(1, resolved.blueComponent))
                                )
                            }
                        )
                    )
                    .disabled(model.compositionExportSettings.preserveAlpha || !usesCustomBackground)

                    Text(model.compositionExportSettings.preserveAlpha ? "携带 Alpha 时背景会以透明方式输出。" : "不携带 Alpha 时会把透明区域合成到所选背景上。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("渲染来源") {
                Picker("来源", selection: $model.compositionExportSettings.sourceMode) {
                    ForEach(CompositionExportSourceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox("导出范围") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("范围", selection: Binding(
                        get: { model.compositionExportSettings.rangeMode },
                        set: {
                            model.compositionExportSettings.rangeMode = $0
                            model.clampCompositionExportSettings()
                        }
                    )) {
                        ForEach(CompositionExportRangeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 12) {
                        CompositionIntField(title: "起始", value: Binding(
                            get: { model.compositionExportSettings.startFrame },
                            set: {
                                model.compositionExportSettings.startFrame = $0
                                model.clampCompositionExportSettings()
                            }
                        ))
                        CompositionIntField(title: "结束", value: Binding(
                            get: { model.compositionExportSettings.endFrame },
                            set: {
                                model.compositionExportSettings.endFrame = $0
                                model.clampCompositionExportSettings()
                            }
                        ))
                        Text("共 \(max(1, model.compositionExportSettings.endFrame - model.compositionExportSettings.startFrame + 1)) 帧")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .disabled(!isCustomRange)
                }
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("取消") {
                    model.isShowingCompositionExportSettingsSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("加入队列") {
                    model.enqueueCurrentCompositionExportInteractively()
                }
                .disabled(model.composition.layers.isEmpty)

                Button("导出") {
                    model.confirmCompositionExportSettings()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isCompositionExporting)
            }
        }
        .padding(20)
        .frame(width: 680)
        .onAppear {
            model.clampCompositionExportSettings()
        }
        .onChange(of: model.currentFrame) { _, _ in
            model.clampCompositionExportSettings()
        }
    }
}

private struct CompositionTimelineView: View {
    @ObservedObject var model: CompositionModel
    @State private var isDropTargeted = false
    @State private var layerSelectionStart: CGPoint?
    @State private var layerSelectionCurrent: CGPoint?
    @State private var timelineZoom: CGFloat = 1
    @State private var timelineScrollOffset: CGPoint = .zero
    @State private var timelineOverlayScrollOffset: CGPoint?
    @State private var timelineScrollRequestID = 0
    @State private var timelineScrollRequestX: CGFloat = 0
    @State private var trackHeaderWidth: CGFloat = 320
    @State private var showTimelineOverflow = false
    @State private var keyframeTimelineMode: CompositionKeyframeTimelineMode = .keyframes
    @State private var showSelectedKeyframeCurves = false
    @State private var layerReorderDragLayerID: UUID?
    @State private var layerReorderStartIndex: Int?
    @State private var layerReorderLastTargetIndex: Int?
    private let rulerHeight: CGFloat = 28
    private let trackRowHeight: CGFloat = 34
    private let expandedPanelHeight: CGFloat = 560

    private var displayedLayers: [CompositionLayer] {
        let query = model.workspaceLayout.timelineLayerSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return model.composition.layers.filter { layer in
            if !query.isEmpty {
                let assetName = model.assets.first(where: { $0.id == layer.assetID })?.name.lowercased() ?? ""
                guard layer.name.lowercased().contains(query) || assetName.contains(query) else {
                    return false
                }
            }
            if model.workspaceLayout.timelineFilterVisibleOnly, !layer.isVisible { return false }
            if model.workspaceLayout.timelineFilterLockedOnly, !layer.isLocked { return false }
            if model.workspaceLayout.timelineFilterKeyframedOnly, layer.keyframes.isEmpty { return false }
            return true
        }
    }

    private var isTimelineLayerFilterActive: Bool {
        !model.workspaceLayout.timelineLayerSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            model.workspaceLayout.timelineFilterVisibleOnly ||
            model.workspaceLayout.timelineFilterLockedOnly ||
            model.workspaceLayout.timelineFilterKeyframedOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(model.isCompositionPlaying ? "暂停" : "播放") {
                    model.togglePlayback()
                }

                Button("添加摄像机") {
                    model.addCameraClipAtCurrentFrame()
                }

                Button("预合成") {
                    model.precomposeSelectedLayers()
                }
                .disabled(model.selectedLayerIDs.count < 2)

                Button("打开预合成") {
                    model.openSelectedPrecomposition()
                }
                .disabled(model.selectedPrecompositionLayerIDs.isEmpty)
                .help("像打开普通合成一样进入当前选中的预合成图层。")

                Button("导出合成") {
                    model.exportCompositionInteractively()
                }
                .disabled((model.isCompositionExporting && !model.isCompositionRenderQueueRunning) || model.composition.layers.isEmpty)

                Toggle("吸附", isOn: $model.isTimelineSnappingEnabled)
                    .toggleStyle(.checkbox)
                    .help("开启后拖动播放头、图层、边缘和拖入素材会吸附到标记、关键帧和片段边界；按 Shift 可临时强制吸附。")

                Button("添加标记") {
                    model.addTimelineMarkerAtCurrentFrame()
                }

                Button("删除标记") {
                    model.deleteTimelineMarkerAtCurrentFrame()
                }

                Menu("图层控制") {
                    Button("预合成选中") {
                        model.precomposeSelectedLayers()
                    }
                    .disabled(model.selectedLayerIDs.count < 2)
                    Button("打开预合成") {
                        model.openSelectedPrecomposition()
                    }
                    .disabled(model.selectedPrecompositionLayerIDs.isEmpty)
                    Button("展开/收起内部预览") {
                        model.toggleSelectedPrecompositionContents()
                    }
                    .disabled(model.selectedPrecompositionLayerIDs.isEmpty)
                    Divider()
                    Button("置顶选中") {
                        model.moveSelectedLayersToTop()
                    }
                    Button("上移选中") {
                        model.moveSelectedLayersUp()
                    }
                    Button("下移选中") {
                        model.moveSelectedLayersDown()
                    }
                    Button("置底选中") {
                        model.moveSelectedLayersToBottom()
                    }
                    Divider()
                    Button("显示选中") {
                        model.setSelectedLayersVisible(true)
                    }
                    Button("隐藏选中") {
                        model.setSelectedLayersVisible(false)
                    }
                    Divider()
                    Button("显示全部") {
                        model.setAllLayersVisible(true)
                    }
                    Button("隐藏全部") {
                        model.setAllLayersVisible(false)
                    }
                    Divider()
                    Button("锁定选中") {
                        model.setSelectedLayersLocked(true)
                    }
                    Button("解锁选中") {
                        model.setSelectedLayersLocked(false)
                    }
                    Divider()
                    Button("清除 Solo") {
                        model.clearLayerSolo()
                    }
                }

                Text("\(model.currentFrame)/\(max(0, model.composition.frameCount - 1))")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            timelineFilterBar

            GeometryReader { proxy in
                let baseTimelineWidth = max(proxy.size.width - trackHeaderWidth, 720)
                let maxTimelineZoom = max(
                    1,
                    min(
                        128,
                        CGFloat(max(1, model.composition.frameCount))
                            * max(1, proxy.size.width - trackHeaderWidth)
                            / max(1, baseTimelineWidth)
                    )
                )
                let effectiveTimelineZoom = min(timelineZoom, maxTimelineZoom)
                let timelineWidth = max(baseTimelineWidth, baseTimelineWidth * effectiveTimelineZoom)
                let contentWidth = trackHeaderWidth + timelineWidth
                let contentHeight = timelineContentHeight
                let fixedHeaderOffset = timelineScrollOffset.x
                let overlayHorizontalOffset = (timelineOverlayScrollOffset ?? timelineScrollOffset).x
                let rightTimelineOffset = trackHeaderWidth + fixedHeaderOffset - overlayHorizontalOffset

                ZStack(alignment: .topLeading) {
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .frame(width: contentWidth, height: contentHeight)

                            Rectangle()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .frame(width: trackHeaderWidth, height: contentHeight)
                                .overlay {
                                    Color.secondary.opacity(0.06)
                                }
                                .offset(x: fixedHeaderOffset)
                                .zIndex(20)

                            timelineBackground(width: timelineWidth)
                                .offset(x: rightTimelineOffset)

                            selectionCaptureLayer(
                                contentWidth: contentWidth,
                                timelineWidth: timelineWidth,
                                height: contentHeight
                            )

                            ForEach(Array(model.composition.cameraClips.enumerated()), id: \.element.id) { index, clip in
                                let rowTop = cameraRowTop(index)
                                cameraTrackHeader(clip: clip, rowTop: rowTop)
                                    .offset(x: fixedHeaderOffset)
                                    .zIndex(25)
                                CompositionTimelineCameraBlock(
                                    model: model,
                                    clipID: clip.id,
                                    rowTop: rowTop,
                                    width: timelineWidth,
                                    trackLeadingX: trackHeaderWidth,
                                    showOverflow: showTimelineOverflow
                                )
                                .offset(x: rightTimelineOffset)

                                if model.isCameraTrackExpanded,
                                   model.selectedCameraClipID == clip.id {
                                    cameraExpandedPanel(
                                        width: timelineWidth,
                                        rowTop: rowTop + trackRowHeight,
                                        horizontalOffset: fixedHeaderOffset,
                                        keyframeTimelineMode: keyframeTimelineMode,
                                        showSelectedKeyframeCurves: showSelectedKeyframeCurves
                                    )
                                    .zIndex(22)
                                }
                            }

                            rulerDragLayer(width: timelineWidth)
                                .offset(x: rightTimelineOffset)

                            ForEach(Array(displayedLayers.enumerated()), id: \.element.id) { index, layer in
                                let rowTop = layerRowTop(index)
                                let precompContentHeight = precompositionInlineHeight(for: layer)
                                layerTrackHeader(layer: layer, rowTop: rowTop)
                                    .offset(x: fixedHeaderOffset)
                                    .zIndex(25)
                                CompositionTimelineLayerBlock(
                                    model: model,
                                    layerID: layer.id,
                                    rowTop: rowTop,
                                    width: timelineWidth,
                                    trackLeadingX: trackHeaderWidth,
                                    showOverflow: showTimelineOverflow
                                )
                                .offset(x: rightTimelineOffset)

                                if model.openedPrecompositionLayerIDs.contains(layer.id),
                                   let nested = model.precompositionContent(for: layer.id) {
                                    precompositionContentPanel(
                                        parentLayer: layer,
                                        nested: nested,
                                        rowTop: rowTop + trackRowHeight,
                                        width: timelineWidth,
                                        height: precompContentHeight,
                                        leftHorizontalOffset: fixedHeaderOffset,
                                        rightHorizontalOffset: rightTimelineOffset
                                    )
                                    .zIndex(23)
                                }

                                if model.expandedLayerIDs.contains(layer.id),
                                   let layerBinding = model.bindingForLayer(id: layer.id) {
                                    layerExpandedPanel(
                                        layer: layerBinding,
                                        rowTop: rowTop + trackRowHeight + precompContentHeight,
                                        width: timelineWidth,
                                        horizontalOffset: fixedHeaderOffset,
                                        keyframeTimelineMode: keyframeTimelineMode,
                                        showSelectedKeyframeCurves: showSelectedKeyframeCurves
                                    )
                                    .zIndex(22)
                                }
                            }

                        }
                        .frame(
                            width: contentWidth,
                            height: contentHeight,
                            alignment: .topLeading
                        )
                        .coordinateSpace(name: compositionTimelineCoordinateSpace)
                        .contentShape(Rectangle())
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1.5)
                        }
                        .transaction { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                        .onDrop(
                            of: [.plainText],
                            delegate: CompositionTimelineDropDelegate(
                                model: model,
                                width: timelineWidth,
                                leadingOffset: trackHeaderWidth,
                                isTargeted: $isDropTargeted
                            )
                        )
	                    }

	                    TimelineWheelCatcher(
	                        trackHeaderWidth: trackHeaderWidth,
	                        baseTimelineWidth: baseTimelineWidth,
	                        timelineZoom: effectiveTimelineZoom,
	                        frameCount: model.composition.frameCount,
	                        requestedScrollID: timelineScrollRequestID,
	                        requestedScrollX: timelineScrollRequestX
	                    ) { nextZoom in
	                        var transaction = Transaction()
	                        transaction.disablesAnimations = true
	                        withTransaction(transaction) {
	                            timelineZoom = nextZoom
	                        }
	                    } onScrollOffsetChanged: { offset in
	                        timelineScrollOffset = offset
	                        timelineOverlayScrollOffset = nil
	                    } onPredictedScrollOffsetChanged: { offset in
	                        timelineOverlayScrollOffset = offset
	                    } onMiddleMouseToggle: {
	                        showTimelineOverflow.toggle()
	                    }
	                    .frame(width: proxy.size.width, height: proxy.size.height)
	                    .zIndex(85)

	                    stickyTimelineRuler(
                        viewportWidth: proxy.size.width,
                        timelineWidth: timelineWidth,
                        horizontalOffset: overlayHorizontalOffset
                    )
                    .zIndex(30)

                    stickyPlayheadOverlay(
                        viewportWidth: proxy.size.width,
                        viewportHeight: proxy.size.height,
                        timelineWidth: timelineWidth,
                        horizontalOffset: overlayHorizontalOffset
                    )
                    .zIndex(60)

                    timelineHeaderResizeHandle(viewportHeight: proxy.size.height)
                        .zIndex(80)

                    timelineRangeOverview(
                        viewportWidth: proxy.size.width,
                        viewportHeight: proxy.size.height,
                        timelineWidth: timelineWidth,
                        horizontalOffset: overlayHorizontalOffset
                    ) { targetX in
                        timelineScrollRequestX = targetX
                        timelineScrollRequestID += 1
                    }
                    .zIndex(90)
                }
            }
        }
        .padding(12)
        .onAppear {
            trackHeaderWidth = CGFloat(model.workspaceLayout.timelineHeaderWidth)
            timelineZoom = CGFloat(model.workspaceLayout.timelineZoom)
        }
        .onChange(of: trackHeaderWidth) { _, width in
            model.workspaceLayout.timelineHeaderWidth = Double(width)
        }
        .onChange(of: timelineZoom) { _, zoom in
            model.workspaceLayout.timelineZoom = Double(zoom)
        }
        .onChange(of: model.workspaceLayout.timelineHeaderWidth) { _, width in
            let next = CGFloat(width)
            if abs(trackHeaderWidth - next) > 0.5 {
                trackHeaderWidth = next
            }
        }
        .onChange(of: model.workspaceLayout.timelineZoom) { _, zoom in
            let next = CGFloat(zoom)
            if abs(timelineZoom - next) > 0.001 {
                timelineZoom = next
            }
        }
    }

    private var timelineFilterBar: some View {
        HStack(spacing: 8) {
            TextField(
                "搜索图层",
                text: Binding(
                    get: { model.workspaceLayout.timelineLayerSearchText },
                    set: { model.workspaceLayout.timelineLayerSearchText = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)

            Toggle("可见", isOn: Binding(
                get: { model.workspaceLayout.timelineFilterVisibleOnly },
                set: { model.workspaceLayout.timelineFilterVisibleOnly = $0 }
            ))
            .toggleStyle(.checkbox)

            Toggle("锁定", isOn: Binding(
                get: { model.workspaceLayout.timelineFilterLockedOnly },
                set: { model.workspaceLayout.timelineFilterLockedOnly = $0 }
            ))
            .toggleStyle(.checkbox)

            Toggle("有关键帧", isOn: Binding(
                get: { model.workspaceLayout.timelineFilterKeyframedOnly },
                set: { model.workspaceLayout.timelineFilterKeyframedOnly = $0 }
            ))
            .toggleStyle(.checkbox)

            if isTimelineLayerFilterActive {
                Button("清除筛选") {
                    model.workspaceLayout.timelineLayerSearchText = ""
                    model.workspaceLayout.timelineFilterVisibleOnly = false
                    model.workspaceLayout.timelineFilterLockedOnly = false
                    model.workspaceLayout.timelineFilterKeyframedOnly = false
                }
                .buttonStyle(.borderless)

                Text("显示 \(displayedLayers.count)/\(model.composition.layers.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(model.workspaceLayout.showDetachedInspector ? "隐藏属性面板" : "独立属性面板") {
                model.workspaceLayout.showDetachedInspector.toggle()
            }
        }
        .font(.caption)
    }

    private var timelineContentHeight: CGFloat {
        var height = rulerHeight
        for clip in model.composition.cameraClips {
            height += trackRowHeight
            if model.isCameraTrackExpanded, model.selectedCameraClipID == clip.id {
                height += expandedPanelHeight
            }
        }
        for layer in displayedLayers {
            height += trackRowHeight
            height += precompositionInlineHeight(for: layer)
            if model.expandedLayerIDs.contains(layer.id) {
                height += expandedPanelHeight
            }
        }
        return max(180, height + 12)
    }

    private func cameraRowTop(_ index: Int) -> CGFloat {
        var y = rulerHeight
        for clipIndex in 0..<index {
            let clip = model.composition.cameraClips[clipIndex]
            y += trackRowHeight
            if model.isCameraTrackExpanded, model.selectedCameraClipID == clip.id {
                y += expandedPanelHeight
            }
        }
        return y
    }

    private func layerRowTop(_ index: Int) -> CGFloat {
        var y = rulerHeight
        for clip in model.composition.cameraClips {
            y += trackRowHeight
            if model.isCameraTrackExpanded, model.selectedCameraClipID == clip.id {
                y += expandedPanelHeight
            }
        }
        let layers = displayedLayers
        for layerIndex in 0..<index {
            let layer = layers[layerIndex]
            y += trackRowHeight
            y += precompositionInlineHeight(for: layer)
            if model.expandedLayerIDs.contains(layer.id) {
                y += expandedPanelHeight
            }
        }
        return y
    }

    private func precompositionInlineHeight(for layer: CompositionLayer) -> CGFloat {
        guard model.openedPrecompositionLayerIDs.contains(layer.id),
              let nested = model.precompositionContent(for: layer.id) else {
            return 0
        }
        return max(54, CGFloat(max(1, nested.layers.count)) * 24 + 34)
    }

    private func timelineBackground(width: CGFloat) -> some View {
        let frameCount = max(1, model.composition.frameCount)
        let step = timelineTickStep(width: width)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))

            ForEach(Array(stride(from: 0, through: frameCount, by: step)), id: \.self) { frame in
                let x = CGFloat(frame) / CGFloat(frameCount) * width
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 1000))
                }
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }

            ForEach(model.composition.markers) { marker in
                let x = CGFloat(marker.frame) / CGFloat(frameCount) * width
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 1000))
                }
                .stroke(Color.green.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
    }

    private func stickyTimelineRuler(
        viewportWidth: CGFloat,
        timelineWidth: CGFloat,
        horizontalOffset: CGFloat
    ) -> some View {
        let frameCount = max(1, model.composition.frameCount)
        let step = timelineTickStep(width: timelineWidth)
        let visibleTimelineStart = max(0, horizontalOffset - trackHeaderWidth)
        let visibleTimelineEnd = max(0, horizontalOffset + viewportWidth - trackHeaderWidth)
        let startFrame = max(0, Int(floor(visibleTimelineStart / max(1, timelineWidth) * CGFloat(frameCount))) - step)
        let endFrame = min(
            frameCount,
            Int(ceil(visibleTimelineEnd / max(1, timelineWidth) * CGFloat(frameCount))) + step
        )
        let firstTick = max(0, (startFrame / step) * step)
        let ticks = Array(stride(from: firstTick, through: endFrame, by: step))

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(height: 1)
                }

            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: trackHeaderWidth)
                .zIndex(10)

            HStack(spacing: 8) {
                Text("时间码")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                Picker("视图", selection: $keyframeTimelineMode) {
                    ForEach(CompositionKeyframeTimelineMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: min(140, max(96, trackHeaderWidth - 84)))
                .help("切换属性轨道显示：关键帧标记或所选关键帧的曲线。")

                Toggle("选中曲线", isOn: $showSelectedKeyframeCurves)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .disabled(keyframeTimelineMode == .curves)
                    .help("关键帧视图中叠加显示已选关键帧的曲线；曲线视图会显示全部曲线。")
            }
            .padding(.leading, 8)
            .frame(width: trackHeaderWidth, height: rulerHeight, alignment: .leading)
                .zIndex(11)

            ForEach(ticks, id: \.self) { frame in
                let x = trackHeaderWidth
                    + CGFloat(frame) / CGFloat(frameCount) * timelineWidth
                    - horizontalOffset
                if x >= trackHeaderWidth && x <= viewportWidth {
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.55))
                            .frame(width: 1, height: 8)
                        Text("\(frame)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 58, height: rulerHeight, alignment: .top)
                    .position(x: x, y: rulerHeight / 2)
                }
            }

            ForEach(model.composition.markers) { marker in
                let x = trackHeaderWidth
                    + CGFloat(marker.frame) / CGFloat(frameCount) * timelineWidth
                    - horizontalOffset
                if x >= trackHeaderWidth && x <= viewportWidth {
                    VStack(spacing: 0) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 8))
                        Text(marker.name)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.green)
                    .frame(width: 70, height: rulerHeight, alignment: .top)
                    .position(x: x, y: rulerHeight / 2)
                }
            }

            Color.clear
                .contentShape(Rectangle())
                .frame(width: max(0, viewportWidth - trackHeaderWidth), height: rulerHeight)
                .offset(x: trackHeaderWidth)
                .zIndex(12)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let timelineX = value.location.x + horizontalOffset - trackHeaderWidth
                            setFrameFromTimelineX(timelineX, width: timelineWidth)
                        }
                )
        }
        .frame(width: viewportWidth, height: rulerHeight)
    }

    private func timelineHeaderResizeHandle(viewportHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.001))
            .frame(width: 12, height: viewportHeight)
            .overlay {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 1)
            }
            .position(x: trackHeaderWidth, y: viewportHeight / 2)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        trackHeaderWidth = max(180, min(560, value.location.x))
                    }
            )
            .help("拖动调整左侧属性列与时间线宽度")
    }

    private func timelineRangeOverview(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        timelineWidth: CGFloat,
        horizontalOffset: CGFloat,
        onScroll: @escaping (CGFloat) -> Void
    ) -> some View {
        let timelineViewportWidth = max(1, viewportWidth - trackHeaderWidth)
        let overviewWidth = max(96, timelineViewportWidth - 24)
        let visibleLength = min(timelineWidth, timelineViewportWidth)
        let maxScrollX = max(0, timelineWidth - visibleLength)
        let visibleStart = max(0, min(maxScrollX, horizontalOffset))

        return TimelineRangeOverviewBar(
            overviewWidth: overviewWidth,
            timelineWidth: timelineWidth,
            visibleStart: visibleStart,
            visibleLength: visibleLength,
            onScroll: onScroll
        )
        .frame(width: overviewWidth, height: 18)
        .position(
            x: trackHeaderWidth + overviewWidth / 2 + 12,
            y: max(14, viewportHeight - 14)
        )
    }

    private func stickyPlayheadOverlay(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        timelineWidth: CGFloat,
        horizontalOffset: CGFloat
    ) -> some View {
        let frameCount = max(1, model.composition.frameCount)
        let playheadX = trackHeaderWidth
            + CGFloat(model.currentFrame) / CGFloat(frameCount) * timelineWidth
            - horizontalOffset
        let isVisible = playheadX >= trackHeaderWidth - 1 && playheadX <= viewportWidth + 1
        let labelX = min(max(playheadX, trackHeaderWidth + 14), viewportWidth - 14)

        return ZStack(alignment: .topLeading) {
            if isVisible {
                Path { path in
                    path.move(to: CGPoint(x: playheadX, y: 0))
                    path.addLine(to: CGPoint(x: playheadX, y: viewportHeight))
                }
                .stroke(Color.red, lineWidth: 2)

                Text("\(model.currentFrame)")
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                    .position(x: labelX, y: 10)
            }
        }
        .frame(width: viewportWidth, height: viewportHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func timelineTickStep(width: CGFloat) -> Int {
        let frameCount = max(1, model.composition.frameCount)
        let pixelsPerFrame = max(0.0001, width / CGFloat(frameCount))
        let targetFrames = max(1, Int(ceil(90 / pixelsPerFrame)))
        let bases = [1, 2, 3, 5, 10, 15, 30]
        var scale = 1
        while scale < 1_000_000 {
            for base in bases {
                let candidate = base * scale
                if candidate >= targetFrames {
                    return max(1, candidate)
                }
            }
            scale *= 10
        }
        return max(1, frameCount / 10)
    }

    private func selectionCaptureLayer(contentWidth: CGFloat, timelineWidth: CGFloat, height: CGFloat) -> some View {
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())

            if let rect = layerSelectionRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(
                        Rectangle()
                            .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: contentWidth, height: height)
        .gesture(layerSelectionGesture(timelineWidth: timelineWidth))
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    endCompositionTextEditing()
                }
        )
    }

    private var layerSelectionRect: CGRect? {
        guard let start = layerSelectionStart, let current = layerSelectionCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
    }

    private func layerSelectionGesture(timelineWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if layerSelectionStart == nil {
                    layerSelectionStart = value.startLocation
                }
                layerSelectionCurrent = value.location
            }
            .onEnded { _ in
                if let rect = layerSelectionRect {
                    model.setBoxSelectedLayers(layerIDs(in: rect, timelineWidth: timelineWidth))
                }
                layerSelectionStart = nil
                layerSelectionCurrent = nil
            }
    }

    private func layerIDs(in rect: CGRect, timelineWidth: CGFloat) -> Set<UUID> {
        let total = max(1, model.composition.frameCount)
        var ids: Set<UUID> = []
        for (index, layer) in displayedLayers.enumerated() {
            let rowTop = layerRowTop(index)
            let layerRect = CGRect(
                x: trackHeaderWidth + CGFloat(layer.startFrame) / CGFloat(total) * timelineWidth,
                y: rowTop,
                width: max(18, CGFloat(layer.duration) / CGFloat(total) * timelineWidth),
                height: 28
            )
            if rect.intersects(layerRect) {
                ids.insert(layer.id)
            }
        }
        return ids
    }

    private func rulerDragLayer(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: width, height: rulerHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        setFrameFromTimelineX(value.location.x, width: width)
                    }
            )
    }

    private func setFrameFromTimelineX(_ x: CGFloat, width: CGFloat) {
        endCompositionTextEditing()
        model.stopPlayback()
        let total = max(1, model.composition.frameCount)
        let progress = max(0, min(1, x / max(1, width)))
        var frame = Int((progress * CGFloat(total)).rounded())
        if model.isTimelineSnappingEnabled || isShiftDown {
            let tolerance = max(2, Int((CGFloat(total) / max(1, width) * 10).rounded()))
            frame = model.snappedTimelineFrame(frame, tolerance: tolerance, force: isShiftDown)
        }
        model.setCurrentFrame(frame)
    }

    private func cameraTrackHeader(clip: CompositionCameraClip, rowTop: CGFloat) -> some View {
        HStack(spacing: 4) {
            Button {
                let wasOpen = model.isCameraTrackExpanded && model.selectedCameraClipID == clip.id
                model.selectCameraClip(clip.id)
                model.isCameraTrackExpanded = !wasOpen
            } label: {
                Image(systemName: model.isCameraTrackExpanded && model.selectedCameraClipID == clip.id ? "chevron.down" : "chevron.right")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)

            Image(systemName: "video")
                .foregroundStyle(model.selectedCameraClipID == clip.id ? .purple : .secondary)
            Text(clip.name)
                .lineLimit(1)
            Spacer()
            Button {
                model.toggleCameraVisibility(id: clip.id)
            } label: {
                Image(systemName: clip.isVisible ? "eye" : "eye.slash")
                    .frame(width: 18)
                    .foregroundStyle(clip.isVisible ? Color.secondary : Color.orange)
            }
            .buttonStyle(.borderless)
            .help(clip.isVisible ? "在摄像机视图中隐藏此摄像机" : "在摄像机视图中显示此摄像机")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(width: trackHeaderWidth, height: 28)
        .contentShape(Rectangle())
        .position(x: trackHeaderWidth / 2, y: rowTop + 14)
        .onTapGesture {
            model.selectCameraClip(clip.id)
        }
    }

    private func cameraExpandedPanel(
        width: CGFloat,
        rowTop: CGFloat,
        horizontalOffset: CGFloat,
        keyframeTimelineMode: CompositionKeyframeTimelineMode,
        showSelectedKeyframeCurves: Bool
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            CompositionCameraInspector(
                model: model,
                timelineWidth: width,
                propertyPanelWidth: trackHeaderWidth,
                timelineHorizontalOffset: horizontalOffset,
                keyframeTimelineMode: keyframeTimelineMode,
                showSelectedKeyframeCurves: showSelectedKeyframeCurves
            )
            .padding(.vertical, 8)
        }
        .frame(width: trackHeaderWidth + width, height: expandedPanelHeight - 8, alignment: .topLeading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .position(
            x: (trackHeaderWidth + width) / 2,
            y: rowTop + expandedPanelHeight / 2
        )
    }

    private func layerTrackHeader(layer: CompositionLayer, rowTop: CGFloat) -> some View {
        HStack(spacing: 4) {
            Button {
                model.toggleLayerExpanded(id: layer.id)
            } label: {
                Image(systemName: model.expandedLayerIDs.contains(layer.id) ? "chevron.down" : "chevron.right")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)

            layerNameDragArea(layer: layer, rowTop: rowTop)

            if model.isPrecompositionLayer(layer) {
                Button {
                    model.openPrecompositionLayer(id: layer.id)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .frame(width: 18)
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.borderless)
                .help("打开这个预合成")

                Button {
                    model.togglePrecompositionContent(layerID: layer.id)
                } label: {
                    Image(systemName: model.openedPrecompositionLayerIDs.contains(layer.id)
                        ? "rectangle.compress.vertical"
                        : "rectangle.expand.vertical")
                        .frame(width: 18)
                        .foregroundStyle(.purple)
                }
                .buttonStyle(.borderless)
                .help(model.openedPrecompositionLayerIDs.contains(layer.id) ? "关闭预合成内容" : "打开预合成内容")
            }

            Menu {
                Button("置顶") {
                    model.moveLayerToTop(id: layer.id)
                }
                Button("上移") {
                    model.moveLayerUp(id: layer.id)
                }
                Button("下移") {
                    model.moveLayerDown(id: layer.id)
                }
                Button("置底") {
                    model.moveLayerToBottom(id: layer.id)
                }
            } label: {
                Image(systemName: "square.3.layers.3d.top.filled")
                    .frame(width: 18)
            }
            .menuStyle(.borderlessButton)
            .help("调整图层层级；时间线越上方，渲染时越靠上")

            Button {
                model.toggleLayerSolo(id: layer.id)
            } label: {
                Text("S")
                    .font(.caption2.bold())
                    .frame(width: 18, height: 18)
                    .foregroundStyle(layer.isSolo ? .white : .secondary)
                    .background(layer.isSolo ? Color.orange : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.borderless)
            .help(layer.isSolo ? "取消独显" : "独显此图层")

            Button {
                model.toggleLayerLock(id: layer.id)
            } label: {
                Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                    .frame(width: 18)
                    .foregroundStyle(layer.isLocked ? .orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(layer.isLocked ? "解锁此图层" : "锁定此图层")

            Button {
                model.toggleLayerVisibility(id: layer.id)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(layer.isVisible ? "在视图中隐藏此图层" : "在视图中显示此图层")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(width: trackHeaderWidth, height: 28)
        .contentShape(Rectangle())
        .position(x: trackHeaderWidth / 2, y: rowTop + 14)
    }

    private func layerNameDragArea(layer: CompositionLayer, rowTop: CGFloat) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(
                    model.selectedLayerIDs.contains(layer.id) || model.selectedLayerID == layer.id
                        ? Color.accentColor
                        : Color.secondary
                )
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(layerReorderDragLayerID == layer.id ? Color.accentColor : Color.secondary)
                .frame(width: 12)
            Text(layer.name)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            LayerHeaderInteractionCatcher(
                dragThreshold: 10,
                onClick: { flags in
                    selectLayerFromHeader(layer, flags: flags)
                },
                onDragChanged: { translationY in
                    updateLayerReorder(layer: layer, translationY: translationY)
                },
                onDragEnded: {
                    endLayerReorder()
                }
            )
        }
        .help("点击选择图层；按住名称区域上下拖动调整层级")
    }

    private func selectLayerFromHeader(_ layer: CompositionLayer) {
        selectLayerFromHeader(
            layer,
            flags: NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    private func selectLayerFromHeader(_ layer: CompositionLayer, flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift) {
            model.selectLayerRange(to: layer.id)
        } else if flags.contains(.command) {
            model.toggleLayerSelection(layer.id)
        } else {
            model.selectOnlyLayer(layer.id)
        }
    }

    private func updateLayerReorder(layer: CompositionLayer, translationY: CGFloat) {
        guard !layer.isLocked else { return }
        guard !isTimelineLayerFilterActive else {
            model.status = "筛选图层时暂不调整层级，清除筛选后可拖拽排序"
            return
        }
        if layerReorderDragLayerID != layer.id {
            let startIndex = model.composition.layers.firstIndex(where: { $0.id == layer.id })
            model.beginLayerReorder(id: layer.id)
            layerReorderDragLayerID = layer.id
            layerReorderStartIndex = startIndex
            layerReorderLastTargetIndex = startIndex
        }

        guard let startIndex = layerReorderStartIndex else { return }
        let rowDistance = trackRowHeight * 1.1
        let rawOffset = translationY / rowDistance
        let rowOffset: Int
        if rawOffset > 0 {
            rowOffset = Int(floor(rawOffset + 0.5))
        } else {
            rowOffset = Int(ceil(rawOffset - 0.5))
        }

        let targetIndex = max(
            0,
            min(model.composition.layers.count - 1, startIndex + rowOffset)
        )
        guard layerReorderLastTargetIndex != targetIndex else { return }
        layerReorderLastTargetIndex = targetIndex
        model.reorderLayer(id: layer.id, toVisualIndex: targetIndex, recordUndoStep: false)
    }

    private func endLayerReorder() {
        layerReorderDragLayerID = nil
        layerReorderStartIndex = nil
        layerReorderLastTargetIndex = nil
    }

    private func layerReorderGesture(layer: CompositionLayer) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(compositionTimelineCoordinateSpace))
            .onChanged { value in
                guard !layer.isLocked else { return }
                if layerReorderDragLayerID != layer.id {
                    let startIndex = model.composition.layers.firstIndex(where: { $0.id == layer.id })
                    model.beginLayerReorder(id: layer.id)
                    layerReorderDragLayerID = layer.id
                    layerReorderStartIndex = startIndex
                    layerReorderLastTargetIndex = startIndex
                }

                guard let startIndex = layerReorderStartIndex else { return }
                let rowDistance = trackRowHeight * 1.1
                let rawOffset = value.translation.height / rowDistance
                let rowOffset: Int
                if rawOffset > 0 {
                    rowOffset = Int(floor(rawOffset + 0.5))
                } else {
                    rowOffset = Int(ceil(rawOffset - 0.5))
                }

                let targetIndex = max(
                    0,
                    min(model.composition.layers.count - 1, startIndex + rowOffset)
                )
                guard layerReorderLastTargetIndex != targetIndex else { return }
                layerReorderLastTargetIndex = targetIndex
                model.reorderLayer(id: layer.id, toVisualIndex: targetIndex, recordUndoStep: false)
            }
            .onEnded { _ in
                layerReorderDragLayerID = nil
                layerReorderStartIndex = nil
                layerReorderLastTargetIndex = nil
            }
    }

    private func layerExpandedPanel(
        layer: Binding<CompositionLayer>,
        rowTop: CGFloat,
        width: CGFloat,
        horizontalOffset: CGFloat,
        keyframeTimelineMode: CompositionKeyframeTimelineMode,
        showSelectedKeyframeCurves: Bool
    ) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            CompositionLayerInspector(
                model: model,
                layer: layer,
                timelineWidth: width,
                propertyPanelWidth: trackHeaderWidth,
                timelineHorizontalOffset: horizontalOffset,
                keyframeTimelineMode: keyframeTimelineMode,
                showSelectedKeyframeCurves: showSelectedKeyframeCurves
            )
            .padding(.vertical, 8)
        }
        .frame(width: trackHeaderWidth + width, height: expandedPanelHeight - 8, alignment: .topLeading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .position(
            x: (trackHeaderWidth + width) / 2,
            y: rowTop + expandedPanelHeight / 2
        )
    }

    private func precompositionContentPanel(
        parentLayer: CompositionLayer,
        nested: CompositionDocumentState,
        rowTop: CGFloat,
        width: CGFloat,
        height: CGFloat,
        leftHorizontalOffset: CGFloat,
        rightHorizontalOffset: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up")
                    Text("预合成内容")
                    Spacer(minLength: 4)
                    Text("\(nested.layers.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .font(.caption.bold())
                .foregroundStyle(.purple)

                if nested.layers.isEmpty {
                    Text("内部没有图层")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(nested.layers.enumerated()), id: \.element.id) { index, child in
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(child.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(child.startFrame)+\(child.duration)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .frame(height: 20)
                        .opacity(child.isVisible ? 1 : 0.45)
                        .padding(.leading, CGFloat(min(index, 3)) * 2)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: trackHeaderWidth, height: height, alignment: .topLeading)
            .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .offset(x: leftHorizontalOffset)
            .zIndex(2)

            precompositionContentTimeline(parentLayer: parentLayer, nested: nested, width: width, height: height)
                .offset(x: rightHorizontalOffset)
        }
        .frame(width: trackHeaderWidth + width, height: height, alignment: .topLeading)
        .position(x: (trackHeaderWidth + width) / 2, y: rowTop + height / 2)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func precompositionContentTimeline(
        parentLayer: CompositionLayer,
        nested: CompositionDocumentState,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let total = max(1, model.composition.frameCount)
        let parentStart = parentLayer.startFrame
        let parentEnd = parentLayer.startFrame + parentLayer.duration

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.purple.opacity(0.045))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.purple.opacity(0.18))
                        .frame(height: 1)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.purple.opacity(0.18))
                        .frame(height: 1)
                }

            ForEach(Array(nested.layers.enumerated()), id: \.element.id) { index, child in
                let childStart = parentStart + child.startFrame
                let childEnd = childStart + child.duration
                let visibleStart = max(0, max(parentStart, childStart))
                let visibleEnd = min(total, min(parentEnd, childEnd))
                if visibleEnd > visibleStart {
                    let x = CGFloat(visibleStart) / CGFloat(total) * width
                    let w = max(10, CGFloat(visibleEnd - visibleStart) / CGFloat(total) * width)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(child.isVisible ? Color.purple.opacity(0.46) : Color.gray.opacity(0.24))
                        .overlay(alignment: .leading) {
                            Text(child.name)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                        }
                        .frame(width: w, height: 18)
                        .position(x: x + w / 2, y: 31 + CGFloat(index) * 24)
                }
            }
        }
        .frame(width: width, height: height)
    }

    private func playhead(width: CGFloat) -> some View {
        let total = max(1, model.composition.frameCount)
        let x = CGFloat(model.currentFrame) / CGFloat(total) * width
        return Path { path in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: 1000))
        }
        .stroke(Color.red, lineWidth: 2)
    }

    private func cameraKeyframeMarkers(width: CGFloat, clip: CompositionCameraClip) -> some View {
        let frames = Array(Set(clip.keyframes.map(\.frame))).sorted()
        return ZStack(alignment: .leading) {
            ForEach(frames, id: \.self) { frame in
                if frame >= clip.startFrame && frame < clip.startFrame + clip.duration {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.yellow)
                        .shadow(color: .black.opacity(0.35), radius: 1)
                        .position(
                            x: CGFloat(frame - clip.startFrame) / CGFloat(max(1, clip.duration)) * width,
                            y: 14
                        )
                }
            }
        }
    }
}

private struct TimelineRangeOverviewBar: View {
    let overviewWidth: CGFloat
    let timelineWidth: CGFloat
    let visibleStart: CGFloat
    let visibleLength: CGFloat
    let onScroll: (CGFloat) -> Void

    @State private var dragGrabOffset: CGFloat?

    var body: some View {
        let safeTimelineWidth = max(1, timelineWidth)
        let safeOverviewWidth = max(1, overviewWidth)
        let maxScrollX = max(0, safeTimelineWidth - visibleLength)
        let handleWidth = min(
            safeOverviewWidth,
            max(28, safeOverviewWidth * visibleLength / safeTimelineWidth)
        )
        let maxHandleX = max(0, safeOverviewWidth - handleWidth)
        let handleX = maxScrollX > 0
            ? max(0, min(maxHandleX, visibleStart / maxScrollX * maxHandleX))
            : 0
        let visiblePercent = Int((visibleLength / safeTimelineWidth * 100).rounded())

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.32), lineWidth: 1)
                }

            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(maxScrollX > 0 ? 0.78 : 0.38))
                .overlay {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(visiblePercent)%")
                            .font(.caption2.monospacedDigit().bold())
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                }
                .frame(width: handleWidth, height: 12)
                .offset(x: handleX)
                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
        }
        .frame(width: safeOverviewWidth, height: 16)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard maxScrollX > 0 else { return }
                    if dragGrabOffset == nil {
                        let startX = max(0, min(safeOverviewWidth, value.startLocation.x))
                        if startX >= handleX, startX <= handleX + handleWidth {
                            dragGrabOffset = startX - handleX
                        } else {
                            dragGrabOffset = handleWidth / 2
                        }
                    }
                    let nextHandleX = max(
                        0,
                        min(maxHandleX, value.location.x - (dragGrabOffset ?? handleWidth / 2))
                    )
                    let progress = maxHandleX > 0 ? nextHandleX / maxHandleX : 0
                    onScroll(progress * maxScrollX)
                }
                .onEnded { _ in
                    dragGrabOffset = nil
                }
        )
        .help("拖动快速移动当前屏幕内的时间码范围")
    }
}

private struct TimelineWheelCatcher: NSViewRepresentable {
    let trackHeaderWidth: CGFloat
    let baseTimelineWidth: CGFloat
    let timelineZoom: CGFloat
    let frameCount: Int
    let requestedScrollID: Int
    let requestedScrollX: CGFloat
    let onOptionZoom: (CGFloat) -> Void
    let onScrollOffsetChanged: (CGPoint) -> Void
    let onPredictedScrollOffsetChanged: (CGPoint) -> Void
    let onMiddleMouseToggle: () -> Void

    func makeNSView(context: Context) -> WheelCatcherView {
        let view = WheelCatcherView()
        view.configure(
            trackHeaderWidth: trackHeaderWidth,
            baseTimelineWidth: baseTimelineWidth,
            timelineZoom: timelineZoom,
            frameCount: frameCount,
            requestedScrollID: requestedScrollID,
            requestedScrollX: requestedScrollX,
            onOptionZoom: onOptionZoom,
            onScrollOffsetChanged: onScrollOffsetChanged,
            onPredictedScrollOffsetChanged: onPredictedScrollOffsetChanged,
            onMiddleMouseToggle: onMiddleMouseToggle
        )
        return view
    }

    func updateNSView(_ nsView: WheelCatcherView, context: Context) {
        nsView.configure(
            trackHeaderWidth: trackHeaderWidth,
            baseTimelineWidth: baseTimelineWidth,
            timelineZoom: timelineZoom,
            frameCount: frameCount,
            requestedScrollID: requestedScrollID,
            requestedScrollX: requestedScrollX,
            onOptionZoom: onOptionZoom,
            onScrollOffsetChanged: onScrollOffsetChanged,
            onPredictedScrollOffsetChanged: onPredictedScrollOffsetChanged,
            onMiddleMouseToggle: onMiddleMouseToggle
        )
    }

    final class WheelCatcherView: NSView {
        var onOptionZoom: ((CGFloat) -> Void)?
        var onScrollOffsetChanged: ((CGPoint) -> Void)?
        var onPredictedScrollOffsetChanged: ((CGPoint) -> Void)?
        var trackHeaderWidth: CGFloat = 320
        var baseTimelineWidth: CGFloat = 720
        var timelineZoom: CGFloat = 1
        var frameCount: Int = 1
        var onMiddleMouseToggle: (() -> Void)?
        private var lastAppliedScrollRequestID = 0
        private var boundsObserver: NSObjectProtocol?
        private weak var observedScrollView: NSScrollView?
        private var zoomScrollGeneration = 0
        private var zoomAnchorResetGeneration = 0
        private var horizontalScrollGeneration = 0
        private var suppressWheelUntil: TimeInterval = 0
        private var suppressOffsetPublishUntil: TimeInterval = 0
        private var lockedVerticalOrigin: CGFloat?
        private var zoomAnchor: ZoomAnchor?
        private weak var pendingZoomScrollView: NSScrollView?
        private var pendingZoomAnchor: ZoomAnchor?
        private var pendingZoomFactor: CGFloat = 1
        private var pendingZoomScheduled = false

        private struct ZoomAnchor {
            var timelineProgress: CGFloat
            var viewportX: CGFloat
            var verticalOrigin: CGFloat
            var lastEventTime: TimeInterval
        }

        override var acceptsFirstResponder: Bool { false }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func configure(
            trackHeaderWidth: CGFloat,
            baseTimelineWidth: CGFloat,
            timelineZoom: CGFloat,
            frameCount: Int,
            requestedScrollID: Int,
            requestedScrollX: CGFloat,
            onOptionZoom: @escaping (CGFloat) -> Void,
            onScrollOffsetChanged: @escaping (CGPoint) -> Void,
            onPredictedScrollOffsetChanged: @escaping (CGPoint) -> Void,
            onMiddleMouseToggle: @escaping () -> Void
        ) {
            self.trackHeaderWidth = trackHeaderWidth
            self.baseTimelineWidth = baseTimelineWidth
            self.timelineZoom = timelineZoom
            self.frameCount = max(1, frameCount)
            self.onOptionZoom = onOptionZoom
            self.onScrollOffsetChanged = onScrollOffsetChanged
            self.onPredictedScrollOffsetChanged = onPredictedScrollOffsetChanged
            self.onMiddleMouseToggle = onMiddleMouseToggle
            configureScrollObservation()
            applyScrollRequestIfNeeded(id: requestedScrollID, x: requestedScrollX)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                clearScrollObservation()
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.configureScrollObservation()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point), let event = window?.currentEvent else { return nil }
            switch event.type {
            case .scrollWheel:
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return flags.contains(.option) || flags.contains(.shift) ? self : nil
            case .otherMouseDown:
                return event.buttonNumber == 2 ? self : nil
            default:
                return nil
            }
        }

        override func scrollWheel(with event: NSEvent) {
            _ = handleScrollWheel(event)
        }

        override func otherMouseDown(with event: NSEvent) {
            _ = handleOtherMouseDown(event)
        }

        private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            let localPoint = convert(event.locationInWindow, from: nil)
            guard bounds.contains(localPoint) else { return event }
            let eventTime = event.timestamp
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            guard let scrollView = scrollView(containing: event) else {
                return flags.contains(.option) || flags.contains(.shift) ? nil : event
            }
            let documentPoint = (scrollView.documentView ?? self).convert(event.locationInWindow, from: nil)

            if flags.contains(.option) {
                let anchor = zoomAnchorForEvent(
                    at: eventTime,
                    documentPoint: documentPoint,
                    scrollView: scrollView
                )
                let fixedY = anchor.verticalOrigin
                lockedVerticalOrigin = fixedY
                suppressWheelUntil = eventTime + 1.2
                suppressOffsetPublishUntil = ProcessInfo.processInfo.systemUptime + 0.35
                queueZoomAroundAnchor(
                    delta: event.scrollingDeltaY,
                    anchor: anchor,
                    scrollView: scrollView,
                    fixedVerticalOrigin: fixedY
                )
                resetVerticalScroll(scrollView: scrollView, to: fixedY)
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    self.resetVerticalScroll(scrollView: scrollView, to: fixedY)
                }
                scheduleZoomAnchorReset()
                return nil
            }
            if flags.contains(.shift) {
                lockedVerticalOrigin = scrollView.contentView.bounds.origin.y
                suppressWheelUntil = eventTime + 0.45
                let bounds = scrollView.contentView.bounds
                let documentWidth = scrollView.documentView?.frame.width ?? bounds.width
                let maxOriginX = max(0, documentWidth - bounds.width)
                let next = CGPoint(
                    x: max(0, min(maxOriginX, bounds.origin.x - (event.scrollingDeltaY + event.scrollingDeltaX) * 3)),
                    y: bounds.origin.y
                )
                horizontalScrollGeneration += 1
                let generation = horizontalScrollGeneration
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    guard generation == self.horizontalScrollGeneration else { return }
                    scrollView.contentView.scroll(to: next)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                    self.onScrollOffsetChanged?(scrollView.contentView.bounds.origin)
                }
                return nil
            }
            if eventTime < suppressWheelUntil {
                if let lockedVerticalOrigin {
                    resetVerticalScroll(scrollView: scrollView, to: lockedVerticalOrigin)
                }
                return nil
            }
            lockedVerticalOrigin = nil
            DispatchQueue.main.async { [weak self] in
                self?.publishScrollOffset()
            }
            return event
        }

        private func handleOtherMouseDown(_ event: NSEvent) -> NSEvent? {
            guard event.window === window, event.buttonNumber == 2 else { return event }
            guard scrollView(containing: event) != nil else { return event }
            onMiddleMouseToggle?()
            return nil
        }

        private func zoomAnchorForEvent(
            at eventTime: TimeInterval,
            documentPoint: CGPoint,
            scrollView: NSScrollView
        ) -> ZoomAnchor {
            if var existing = zoomAnchor,
               eventTime - existing.lastEventTime < 0.8 {
                existing.lastEventTime = eventTime
                zoomAnchor = existing
                return existing
            }

            let bounds = scrollView.contentView.bounds
            let oldTimelineWidth = max(1, baseTimelineWidth * max(1, timelineZoom))
            let viewportX = max(
                trackHeaderWidth,
                min(bounds.width, documentPoint.x - bounds.origin.x)
            )
            let anchorContentX = bounds.origin.x + viewportX
            let anchorTimelineX = max(0, min(oldTimelineWidth, anchorContentX - trackHeaderWidth))
            let progress = anchorTimelineX / oldTimelineWidth
            let anchor = ZoomAnchor(
                timelineProgress: progress,
                viewportX: viewportX,
                verticalOrigin: bounds.origin.y,
                lastEventTime: eventTime
            )
            zoomAnchor = anchor
            return anchor
        }

        private func scheduleZoomAnchorReset() {
            zoomAnchorResetGeneration += 1
            let generation = zoomAnchorResetGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, generation == self.zoomAnchorResetGeneration else { return }
                self.zoomAnchor = nil
                self.lockedVerticalOrigin = nil
            }
        }

        private func queueZoomAroundAnchor(
            delta: CGFloat,
            anchor: ZoomAnchor,
            scrollView: NSScrollView,
            fixedVerticalOrigin: CGFloat
        ) {
            let clampedDelta = max(-8, min(8, delta))
            pendingZoomFactor *= CGFloat(exp(Double(clampedDelta) * 0.015))
            pendingZoomAnchor = anchor
            pendingZoomScrollView = scrollView
            lockedVerticalOrigin = fixedVerticalOrigin
            guard !pendingZoomScheduled else { return }
            pendingZoomScheduled = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [weak self] in
                self?.applyPendingZoom()
            }
        }

        private func applyPendingZoom() {
            guard pendingZoomScheduled else { return }
            pendingZoomScheduled = false
            let factor = pendingZoomFactor
            pendingZoomFactor = 1
            guard abs(factor - 1) > 0.0001,
                  let anchor = pendingZoomAnchor,
                  let scrollView = pendingZoomScrollView else {
                return
            }
            zoomAroundAnchor(
                factor: factor,
                anchor: anchor,
                scrollView: scrollView,
                fixedVerticalOrigin: lockedVerticalOrigin ?? anchor.verticalOrigin
            )
        }

        private func zoomAroundAnchor(
            factor: CGFloat,
            anchor: ZoomAnchor,
            scrollView: NSScrollView,
            fixedVerticalOrigin: CGFloat
        ) {
            let oldZoom = max(1, timelineZoom)
            let visibleTimelineWidth = max(1, scrollView.contentView.bounds.width - trackHeaderWidth)
            let frameLimitedZoom = CGFloat(max(1, frameCount)) * visibleTimelineWidth / max(1, baseTimelineWidth)
            let maxZoom = max(1, min(128, frameLimitedZoom))
            let nextZoom = max(1, min(maxZoom, oldZoom * factor))
            guard abs(nextZoom - oldZoom) > 0.0001 else { return }

            let newTimelineWidth = max(1, baseTimelineWidth * nextZoom)
            let viewportPointX = anchor.viewportX
            let newAnchorContentX = trackHeaderWidth + anchor.timelineProgress * newTimelineWidth
            let expectedDocumentWidth = trackHeaderWidth + newTimelineWidth
            let maxPredictedOriginX = max(0, expectedDocumentWidth - scrollView.contentView.bounds.width)
            let predictedOrigin = CGPoint(
                x: max(0, min(maxPredictedOriginX, newAnchorContentX - viewportPointX)),
                y: fixedVerticalOrigin
            )

            timelineZoom = nextZoom
            zoomScrollGeneration += 1
            let generation = zoomScrollGeneration
            onOptionZoom?(nextZoom)
            onPredictedScrollOffsetChanged?(predictedOrigin)
            scrollToZoomAnchor(
                scrollView: scrollView,
                newTimelineWidth: newTimelineWidth,
                newAnchorContentX: newAnchorContentX,
                viewportPointX: viewportPointX,
                fixedVerticalOrigin: fixedVerticalOrigin,
                generation: generation,
                attempt: 0
            )
        }

        private func scrollToZoomAnchor(
            scrollView: NSScrollView,
            newTimelineWidth: CGFloat,
            newAnchorContentX: CGFloat,
            viewportPointX: CGFloat,
            fixedVerticalOrigin: CGFloat,
            generation: Int,
            attempt: Int
        ) {
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                guard generation == self.zoomScrollGeneration else { return }
                let expectedDocumentWidth = self.trackHeaderWidth + newTimelineWidth
                let documentWidth = scrollView.documentView?.frame.width ?? expectedDocumentWidth
                if documentWidth + 0.5 < expectedDocumentWidth, attempt < 8 {
                    self.scrollToZoomAnchor(
                        scrollView: scrollView,
                        newTimelineWidth: newTimelineWidth,
                        newAnchorContentX: newAnchorContentX,
                        viewportPointX: viewportPointX,
                        fixedVerticalOrigin: fixedVerticalOrigin,
                        generation: generation,
                        attempt: attempt + 1
                    )
                    return
                }

                let maxOriginX = max(0, documentWidth - scrollView.contentView.bounds.width)
                let newOriginX = max(0, min(maxOriginX, newAnchorContentX - viewportPointX))
                let newOrigin = CGPoint(x: newOriginX, y: fixedVerticalOrigin)
                scrollView.contentView.scroll(to: newOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.publishScrollOffset(origin: newOrigin, force: true)
            }
        }

        private func scrollView(containing event: NSEvent) -> NSScrollView? {
            if let observedScrollView,
               windowPoint(event.locationInWindow, isInside: observedScrollView) {
                return observedScrollView
            }
            if let enclosingScrollView,
               windowPoint(event.locationInWindow, isInside: enclosingScrollView) {
                return enclosingScrollView
            }
            return scrollViews(containing: event.locationInWindow)
                .min { lhs, rhs in
                    lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
                }
        }

        private func resetVerticalScroll(scrollView: NSScrollView, to y: CGFloat) {
            let current = scrollView.contentView.bounds.origin
            guard abs(current.y - y) > 0.5 else { return }
            let origin = CGPoint(x: current.x, y: y)
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            publishScrollOffset(origin: origin)
        }

        private func applyScrollRequestIfNeeded(id: Int, x: CGFloat) {
            guard id != 0, id != lastAppliedScrollRequestID else { return }
            lastAppliedScrollRequestID = id
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let scrollView = self.enclosingScrollView ?? self.observedScrollView else { return }
                let maxOriginX = max(
                    0,
                    (scrollView.documentView?.frame.width ?? 0) - scrollView.contentView.bounds.width
                )
                let nextOrigin = CGPoint(
                    x: max(0, min(maxOriginX, x)),
                    y: scrollView.contentView.bounds.origin.y
                )
                scrollView.contentView.scroll(to: nextOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.publishScrollOffset(origin: nextOrigin, force: true)
            }
        }

        private func configureScrollObservation() {
            guard window != nil,
                  let scrollView = enclosingScrollView ?? scrollViewCoveringSelf() else { return }
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            guard observedScrollView !== scrollView else {
                publishScrollOffset()
                return
            }
            clearScrollObservation()
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.publishScrollOffset()
            }
            publishScrollOffset()
        }

        private func clearScrollObservation() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
            observedScrollView = nil
        }

        private func publishScrollOffset(origin: CGPoint? = nil, force: Bool = false) {
            if !force, ProcessInfo.processInfo.systemUptime < suppressOffsetPublishUntil {
                return
            }
            guard let scrollView = enclosingScrollView ?? observedScrollView else { return }
            onScrollOffsetChanged?(origin ?? scrollView.contentView.bounds.origin)
        }

        private func scrollViewCoveringSelf() -> NSScrollView? {
            guard window != nil else { return nil }
            let selfRect = convert(bounds, to: nil)
            return allScrollViews()
                .filter { scrollView in
                    scrollView.window === window && scrollView.convert(scrollView.bounds, to: nil).intersects(selfRect)
                }
                .max { lhs, rhs in
                    intersectionArea(lhs.convert(lhs.bounds, to: nil), selfRect)
                        < intersectionArea(rhs.convert(rhs.bounds, to: nil), selfRect)
                }
        }

        private func scrollViews(containing windowPoint: CGPoint) -> [NSScrollView] {
            allScrollViews().filter { scrollView in
                scrollView.window === window && self.windowPoint(windowPoint, isInside: scrollView)
            }
        }

        private func allScrollViews() -> [NSScrollView] {
            guard let root = window?.contentView else { return [] }
            var result: [NSScrollView] = []
            func walk(_ view: NSView) {
                if let scrollView = view as? NSScrollView {
                    result.append(scrollView)
                }
                view.subviews.forEach(walk)
            }
            walk(root)
            return result
        }

        private func windowPoint(_ point: CGPoint, isInside scrollView: NSScrollView) -> Bool {
            let local = scrollView.convert(point, from: nil)
            return scrollView.bounds.contains(local)
        }

        private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
            let rect = lhs.intersection(rhs)
            guard !rect.isNull else { return 0 }
            return rect.width * rect.height
        }
    }
}

private enum CompositionGizmoHandle {
    case moveXY
    case moveX
    case moveY
    case moveZ
    case rotate
    case scale
}

private enum CompositionGizmoTarget: Equatable {
    case layer(UUID)
    case camera(UUID)
}

private struct CompositionGizmoDragState {
    let target: CompositionGizmoTarget
    let layerTransform: VolumeTransformState?
    let camera: CameraRigState?
}

private struct CompositionGizmoScreenBasis {
    let x: CGSize
    let y: CGSize
    let z: CGSize

    func projectedAmount(for translation: CGSize, axis: CGSize) -> Float {
        let denominator = axis.width * axis.width + axis.height * axis.height
        guard denominator > 0.0001 else { return 0 }
        let numerator = translation.width * axis.width + translation.height * axis.height
        return Float(numerator / denominator)
    }

    func projectedXYDelta(for translation: CGSize) -> SIMD2<Float> {
        let determinant = x.width * y.height - y.width * x.height
        guard abs(determinant) > 0.0001 else {
            return SIMD2<Float>(
                projectedAmount(for: translation, axis: x),
                projectedAmount(for: translation, axis: y)
            )
        }
        let dx = (translation.width * y.height - y.width * translation.height) / determinant
        let dy = (x.width * translation.height - translation.width * x.height) / determinant
        return SIMD2<Float>(Float(dx), Float(dy))
    }

    func displayEndpoint(from anchor: CGPoint, axis: CGSize, length: CGFloat) -> CGPoint {
        let axisLength = max(0.0001, hypot(axis.width, axis.height))
        let scale = length / axisLength
        return CGPoint(
            x: anchor.x + axis.width * scale,
            y: anchor.y + axis.height * scale
        )
    }
}

private func worldOrbitProjectedPosition(
    _ position: SIMD3<Float>,
    camera: CameraRigState
) -> SIMD3<Float> {
    let pitchCos = cos(camera.pitch)
    let pitchSin = sin(camera.pitch)
    let yawCos = cos(camera.yaw)
    let yawSin = sin(camera.yaw)

    let pitchRotated = SIMD3<Float>(
        position.x,
        position.y * pitchCos - position.z * pitchSin,
        position.y * pitchSin + position.z * pitchCos
    )

    return SIMD3<Float>(
        pitchRotated.x * yawCos + pitchRotated.z * yawSin,
        pitchRotated.y,
        -pitchRotated.x * yawSin + pitchRotated.z * yawCos
    )
}

private func compositionWorldPixelsPerUnit(in size: CGSize, camera: CameraRigState) -> CGFloat {
    let focalLength = max(1, CGFloat(camera.focalLength))
    let sensorHeight: CGFloat = 24
    let fov = 2 * atan(sensorHeight / (2 * focalLength))
    let yScale = 1 / tan(fov * 0.5)
    let distance = max(0.8, CGFloat(camera.distance))
    return max(1, size.height * 0.5 * yScale / distance)
}

private struct CompositionCameraWorldOverlay: View {
    @ObservedObject var model: CompositionModel
    let worldCamera: CameraRigState

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(model.visibleCameraClips()) { clip in
                    let camera = model.renderCamera(clipID: clip.id, at: model.currentFrame)
                    let position = SIMD3<Float>(camera.positionX, camera.positionY, camera.positionZ)
                    if let anchor = anchorPoint(for: position, in: proxy.size) {
                        cameraMarker(
                            clip: clip,
                            camera: camera,
                            anchor: anchor,
                            directionEnd: directionPoint(for: position, camera: camera, anchor: anchor, in: proxy.size)
                        )
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    private func cameraMarker(
        clip: CompositionCameraClip,
        camera: CameraRigState,
        anchor: CGPoint,
        directionEnd: CGPoint
    ) -> some View {
        let selected = model.selectedCameraClipID == clip.id
        let vector = CGSize(width: directionEnd.x - anchor.x, height: directionEnd.y - anchor.y)
        let length = max(1, hypot(vector.width, vector.height))
        let unit = CGSize(width: vector.width / length, height: vector.height / length)
        let perp = CGSize(width: -unit.height, height: unit.width)
        let coneLeft = CGPoint(x: directionEnd.x - unit.width * 14 + perp.width * 11, y: directionEnd.y - unit.height * 14 + perp.height * 11)
        let coneRight = CGPoint(x: directionEnd.x - unit.width * 14 - perp.width * 11, y: directionEnd.y - unit.height * 14 - perp.height * 11)

        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: anchor)
                path.addLine(to: coneLeft)
                path.addLine(to: directionEnd)
                path.addLine(to: coneRight)
                path.closeSubpath()
            }
            .fill((selected ? Color.orange : Color.orange.opacity(0.7)).opacity(0.16))

            Path { path in
                path.move(to: anchor)
                path.addLine(to: directionEnd)
                path.move(to: coneLeft)
                path.addLine(to: directionEnd)
                path.addLine(to: coneRight)
            }
            .stroke(
                selected ? Color.yellow : Color.orange.opacity(0.72),
                style: StrokeStyle(lineWidth: selected ? 3 : 2, lineCap: .round)
            )

            Circle()
                .fill(selected ? Color.orange : Color.orange.opacity(0.72))
                .overlay(Circle().stroke(.black.opacity(0.55), lineWidth: 1))
                .frame(width: selected ? 14 : 10, height: selected ? 14 : 10)
                .position(anchor)

            Image(systemName: "video.fill")
                .font(.caption.bold())
                .foregroundStyle(selected ? .orange : .orange.opacity(0.78))
                .position(x: anchor.x + 18, y: anchor.y - 16)

            Text(clip.name)
                .font(.caption2.bold())
                .lineLimit(1)
                .foregroundStyle(selected ? .orange : .white.opacity(0.78))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.44), in: RoundedRectangle(cornerRadius: 4))
                .position(x: anchor.x + 44, y: anchor.y + 18)
        }
    }

    private func directionPoint(
        for position: SIMD3<Float>,
        camera: CameraRigState,
        anchor: CGPoint,
        in size: CGSize
    ) -> CGPoint {
        let forward = cameraForward(camera)
        let projectedTarget = screenPoint(for: position + forward * 0.85, in: size)
        let raw = projectedTarget ?? CGPoint(x: anchor.x, y: anchor.y - 48)
        let vector = CGSize(width: raw.x - anchor.x, height: raw.y - anchor.y)
        let length = hypot(vector.width, vector.height)
        if length < 6 {
            let fallback = CGPoint(
                x: anchor.x + CGFloat(sin(camera.yaw)) * 48,
                y: anchor.y - CGFloat(cos(camera.yaw)) * 48
            )
            return fallback
        }
        let clampedLength = min(72, max(44, length))
        return CGPoint(
            x: anchor.x + vector.width / length * clampedLength,
            y: anchor.y + vector.height / length * clampedLength
        )
    }

    private func cameraForward(_ camera: CameraRigState) -> SIMD3<Float> {
        let yawSin = sin(camera.yaw)
        let yawCos = cos(camera.yaw)
        let pitchSin = sin(camera.pitch)
        let pitchCos = cos(camera.pitch)
        return simd_normalize(SIMD3<Float>(
            yawSin * pitchCos,
            -pitchSin,
            -yawCos * pitchCos
        ))
    }

    private func screenPoint(for position: SIMD3<Float>, in size: CGSize) -> CGPoint? {
        guard size.width > 1, size.height > 1 else { return nil }
        let ppu = compositionWorldPixelsPerUnit(in: size, camera: worldCamera)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let projected = worldOrbitProjectedPosition(position, camera: worldCamera)
        let point = CGPoint(
            x: center.x + CGFloat(projected.x) * ppu,
            y: center.y - CGFloat(projected.y) * ppu
        )
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    private func anchorPoint(for position: SIMD3<Float>, in size: CGSize) -> CGPoint? {
        guard let point = screenPoint(for: position, in: size) else { return nil }
        return CGPoint(
            x: min(max(28, point.x), max(28, size.width - 28)),
            y: min(max(28, point.y), max(28, size.height - 28))
        )
    }
}

private struct CompositionTransformGizmoOverlay: View {
    @ObservedObject var model: CompositionModel
    let worldCamera: CameraRigState

    @State private var dragState: CompositionGizmoDragState?

    private let axisLength: CGFloat = 72
    private let centerSize: CGFloat = 16
    private let handleSize: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            if let targetInfo = currentTargetInfo,
               let anchor = anchorPoint(for: targetInfo.position, in: proxy.size) {
                ZStack(alignment: .topLeading) {
                    gizmoBody(
                        targetInfo: targetInfo,
                        anchor: anchor,
                        basis: screenBasis(for: targetInfo.position, in: proxy.size)
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    private var currentTargetInfo: (target: CompositionGizmoTarget, title: String, position: SIMD3<Float>)? {
        if let id = model.selectedLayerID,
           let layer = model.composition.layers.first(where: { $0.id == id }) {
            let transform = model
                .activeRenderLayers()
                .first(where: { $0.id == id })?
                .transform ?? layer.transform
            return (
                .layer(id),
                layer.name,
                SIMD3<Float>(transform.positionX, transform.positionY, transform.positionZ)
            )
        }

        if let id = model.selectedCameraClipID,
           model.composition.cameraClips.contains(where: { $0.id == id }) {
            let camera = model.renderCamera(clipID: id, at: model.currentFrame)
            return (
                .camera(id),
                model.cameraClipName(id: id),
                SIMD3<Float>(camera.positionX, camera.positionY, camera.positionZ)
            )
        }

        return nil
    }

    private func gizmoBody(
        targetInfo: (target: CompositionGizmoTarget, title: String, position: SIMD3<Float>),
        anchor: CGPoint,
        basis: CompositionGizmoScreenBasis
    ) -> some View {
        let xEnd = basis.displayEndpoint(from: anchor, axis: basis.x, length: axisLength)
        let yEnd = basis.displayEndpoint(from: anchor, axis: basis.y, length: axisLength)
        let zEnd = basis.displayEndpoint(from: anchor, axis: basis.z, length: axisLength)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: anchor)
                path.addLine(to: xEnd)
                path.move(to: anchor)
                path.addLine(to: yEnd)
                path.move(to: anchor)
                path.addLine(to: zEnd)
            }
            .stroke(.white.opacity(0.16), lineWidth: 6)
            .allowsHitTesting(false)

            axisLine(from: anchor, to: xEnd, color: .red)
                .allowsHitTesting(false)
            axisLine(from: anchor, to: yEnd, color: .green)
                .allowsHitTesting(false)
            axisLine(from: anchor, to: zEnd, color: .blue)
                .allowsHitTesting(false)

            Circle()
                .stroke(.orange.opacity(0.88), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .frame(width: 88, height: 88)
                .position(anchor)
                .allowsHitTesting(false)

            handleCircle(
                color: .orange,
                position: CGPoint(x: anchor.x + 31, y: anchor.y - 31),
                help: "拖动旋转：图层旋转Z / 摄像机 Roll"
            )
                .gesture(gizmoDragGesture(.rotate, target: targetInfo.target, basis: basis))
                .help("拖动旋转：图层旋转Z / 摄像机 Roll")

            Text("X")
                .font(.caption.bold())
                .foregroundStyle(.red)
                .position(x: xEnd.x + 14, y: xEnd.y)
                .allowsHitTesting(false)
            Text("Y")
                .font(.caption.bold())
                .foregroundStyle(.green)
                .position(x: yEnd.x, y: yEnd.y - 14)
                .allowsHitTesting(false)
            Text("Z")
                .font(.caption.bold())
                .foregroundStyle(.blue)
                .position(x: zEnd.x - 14, y: zEnd.y + 12)
                .allowsHitTesting(false)

            handleCircle(
                color: .red,
                position: xEnd,
                help: "拖动 X 轴移动"
            )
            .gesture(gizmoDragGesture(.moveX, target: targetInfo.target, basis: basis))

            handleCircle(
                color: .green,
                position: yEnd,
                help: "拖动 Y 轴移动"
            )
            .gesture(gizmoDragGesture(.moveY, target: targetInfo.target, basis: basis))

            handleCircle(
                color: .blue,
                position: zEnd,
                help: "拖动 Z 轴移动"
            )
            .gesture(gizmoDragGesture(.moveZ, target: targetInfo.target, basis: basis))

            RoundedRectangle(cornerRadius: 3)
                .fill(.yellow)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.45), lineWidth: 1))
                .frame(width: handleSize, height: handleSize)
                .position(x: anchor.x + 48, y: anchor.y - 48)
                .gesture(gizmoDragGesture(.scale, target: targetInfo.target, basis: basis))
                .help(targetInfo.target.isLayer ? "拖动缩放图层" : "拖动调整摄像机焦段")

            Circle()
                .fill(.orange)
                .overlay(Circle().stroke(.black.opacity(0.55), lineWidth: 1))
                .frame(width: centerSize, height: centerSize)
                .position(anchor)
                .gesture(gizmoDragGesture(.moveXY, target: targetInfo.target, basis: basis))
                .help("拖动平面移动")

            Text(targetInfo.target.isLayer ? "层" : "Cam")
                .font(.caption.bold())
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 4))
                .position(x: anchor.x + 28, y: anchor.y - 18)
                .allowsHitTesting(false)

            Text(targetInfo.title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 4))
                .position(x: anchor.x + 52, y: anchor.y + 24)
                .allowsHitTesting(false)
        }
    }

    private func axisLine(from start: CGPoint, to end: CGPoint, color: Color) -> some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(color.opacity(0.88), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    private func handleCircle(color: Color, position: CGPoint, help: String) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1))
            .frame(width: handleSize, height: handleSize)
            .position(position)
            .contentShape(Circle())
            .help(help)
    }

    private func gizmoDragGesture(
        _ handle: CompositionGizmoHandle,
        target: CompositionGizmoTarget,
        basis: CompositionGizmoScreenBasis
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let state = beginDragIfNeeded(for: target)
                apply(
                    handle: handle,
                    target: target,
                    state: state,
                    translation: value.translation,
                    basis: basis
                )
            }
            .onEnded { _ in
                dragState = nil
            }
    }

    private func beginDragIfNeeded(for target: CompositionGizmoTarget) -> CompositionGizmoDragState {
        if let dragState, dragState.target == target {
            return dragState
        }

        model.beginCompositionGizmoEdit()
        let next: CompositionGizmoDragState
        switch target {
        case .layer(let id):
            let transform = model
                .activeRenderLayers()
                .first(where: { $0.id == id })?
                .transform
                ?? model.composition.layers.first(where: { $0.id == id })?.transform
            next = CompositionGizmoDragState(target: target, layerTransform: transform, camera: nil)
            model.selectOnlyLayer(id)
        case .camera(let id):
            let camera = model.renderCamera(clipID: id, at: model.currentFrame)
            next = CompositionGizmoDragState(target: target, layerTransform: nil, camera: camera)
            model.selectCameraClip(id)
        }
        dragState = next
        return next
    }

    private func apply(
        handle: CompositionGizmoHandle,
        target: CompositionGizmoTarget,
        state: CompositionGizmoDragState,
        translation: CGSize,
        basis: CompositionGizmoScreenBasis
    ) {
        let xyDelta = basis.projectedXYDelta(for: translation)
        let dx = basis.projectedAmount(for: translation, axis: basis.x)
        let dy = basis.projectedAmount(for: translation, axis: basis.y)
        let dz = basis.projectedAmount(for: translation, axis: basis.z)
        let rotationDelta = Float(translation.width - translation.height) * 0.01
        let scaleFactor = max(0.05, 1 + Float(translation.width - translation.height) * 0.01)

        switch target {
        case .layer(let id):
            guard let start = state.layerTransform else { return }
            switch handle {
            case .moveXY:
                setLayer(id: id, .positionX, start.positionX + xyDelta.x)
                setLayer(id: id, .positionY, start.positionY + xyDelta.y)
            case .moveX:
                setLayer(id: id, .positionX, start.positionX + dx)
            case .moveY:
                setLayer(id: id, .positionY, start.positionY + dy)
            case .moveZ:
                setLayer(id: id, .positionZ, start.positionZ + dz)
            case .rotate:
                setLayer(id: id, .rotationZ, start.rotationZ + rotationDelta)
            case .scale:
                setLayer(id: id, .scaleX, max(0.01, start.scaleX * scaleFactor))
            }
        case .camera:
            guard let start = state.camera else { return }
            switch handle {
            case .moveXY:
                setCamera(.positionX, start.positionX + xyDelta.x)
                setCamera(.positionY, start.positionY + xyDelta.y)
            case .moveX:
                setCamera(.positionX, start.positionX + dx)
            case .moveY:
                setCamera(.positionY, start.positionY + dy)
            case .moveZ:
                setCamera(.positionZ, start.positionZ + dz)
            case .rotate:
                setCamera(.roll, start.roll + rotationDelta)
            case .scale:
                setCamera(.focalLength, max(1, start.focalLength * scaleFactor))
            }
        }
    }

    private func setLayer(id: UUID, _ property: CompositionLayerKeyframeProperty, _ value: Float) {
        model.setLayerProperty(layerID: id, property: property, value: value, recordHistory: false)
    }

    private func setCamera(_ property: CompositionCameraKeyframeProperty, _ value: Float) {
        let syncFocusOrientation: Bool = {
            switch property {
            case .positionX, .positionY, .positionZ, .focusTargetX, .focusTargetY, .focusTargetZ:
                return true
            case .yaw, .pitch, .roll, .focalLength, .aperture:
                return false
            }
        }()
        model.setCompositionCameraProperty(
            property,
            value: value,
            syncFocusOrientation: syncFocusOrientation,
            recordHistory: false
        )
    }

    private func anchorPoint(for position: SIMD3<Float>, in size: CGSize) -> CGPoint? {
        guard size.width > 1, size.height > 1 else { return nil }
        let ppu = pixelsPerUnit(in: size)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let projected = worldOrbitProjectedPosition(position, camera: worldCamera)
        let point = CGPoint(
            x: center.x + CGFloat(projected.x) * ppu,
            y: center.y - CGFloat(projected.y) * ppu
        )
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return CGPoint(
            x: min(max(28, point.x), max(28, size.width - 28)),
            y: min(max(28, point.y), max(28, size.height - 28))
        )
    }

    private func screenBasis(for position: SIMD3<Float>, in size: CGSize) -> CompositionGizmoScreenBasis {
        let ppu = pixelsPerUnit(in: size)
        let base = worldOrbitProjectedPosition(position, camera: worldCamera)

        func axisDelta(_ axis: SIMD3<Float>) -> CGSize {
            let projected = worldOrbitProjectedPosition(position + axis, camera: worldCamera)
            let delta = projected - base
            return CGSize(
                width: CGFloat(delta.x) * ppu,
                height: -CGFloat(delta.y) * ppu
            )
        }

        let x = axisDelta(SIMD3<Float>(1, 0, 0))
        let y = axisDelta(SIMD3<Float>(0, 1, 0))
        let z = axisDelta(SIMD3<Float>(0, 0, 1))
        return CompositionGizmoScreenBasis(x: x, y: y, z: z)
    }

    private func pixelsPerUnit(in size: CGSize) -> CGFloat {
        compositionWorldPixelsPerUnit(in: size, camera: worldCamera)
    }
}

private extension CompositionGizmoTarget {
    var isLayer: Bool {
        if case .layer = self { return true }
        return false
    }
}

private struct CompositionPropertyGroupData<Property: Identifiable>: Identifiable {
    let id: String
    let title: String
    let properties: [Property]
}

private struct CompositionPropertyGroup<Content: View>: View {
    let title: String
    let count: Int
    let propertyPanelWidth: CGFloat
    var stickyHorizontalOffset: CGFloat = 0
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 12)
                    Text(title)
                        .font(.caption.bold())
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 24)
            .frame(width: propertyPanelWidth, alignment: .leading)
            .offset(x: stickyHorizontalOffset)
            .zIndex(30)

            if isExpanded {
                content()
            }
        }
    }
}

private struct CompositionCameraInspector: View {
    @ObservedObject var model: CompositionModel
    let timelineWidth: CGFloat
    let propertyPanelWidth: CGFloat
    let timelineHorizontalOffset: CGFloat
    let keyframeTimelineMode: CompositionKeyframeTimelineMode
    let showSelectedKeyframeCurves: Bool

    @State private var propertySearchText = ""
    @State private var collapsedGroups: Set<String> = []

    private let propertyRowHeight: CGFloat = 30
    private let propertyRowSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.selectedCameraClipID.map { model.cameraClipName(id: $0) } ?? "摄像机")
                    .font(.headline)
                Spacer()
                Button("复位摄像机") {
                    model.resetSelectedCompositionCamera()
                }
                .buttonStyle(.borderless)
                .help("复位当前摄像机位置、方向、焦点锁定、焦段和光圈")
            }
            .frame(width: propertyPanelWidth, alignment: .leading)
            .offset(x: timelineHorizontalOffset)

            Toggle("焦点锁定", isOn: Binding(
                get: { model.compositionCamera.focusLockEnabled },
                set: { enabled in
                    model.setCompositionCameraFocusLock(enabled)
                }
            ))
            .padding(.leading, 24)
            .offset(x: timelineHorizontalOffset)

            propertyTools
                .frame(width: propertyPanelWidth, alignment: .leading)
                .offset(x: timelineHorizontalOffset)

            if displayedCameraGroups.isEmpty {
                Text("没有匹配的摄像机属性")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
                    .offset(x: timelineHorizontalOffset)
            } else {
                ForEach(displayedCameraGroups) { group in
                    CompositionPropertyGroup(
                        title: group.title,
                        count: group.properties.count,
                        propertyPanelWidth: propertyPanelWidth,
                        stickyHorizontalOffset: timelineHorizontalOffset,
                        isExpanded: groupExpandedBinding(group.id)
                    ) {
                        KeyframeSelectionGroup(
                            propertyPanelWidth: propertyPanelWidth,
                            timelineWidth: timelineWidth,
                            height: keyframedRowsHeight(for: group.properties),
                            allowsSelection: keyframeTimelineMode == .keyframes,
                            isMarkerAt: { isCameraMarker(at: $0, properties: group.properties) },
                            onSelect: { rect, extending in
                                selectCameraKeyframes(in: rect, extending: extending, properties: group.properties)
                            }
                        ) {
                            VStack(alignment: .leading, spacing: propertyRowSpacing) {
                                ForEach(group.properties) { property in
                                    cameraRow(for: property)
                                }
                            }
                        }
                    }
                }
            }

            KeyframeCurveEditorPanel(
                model: model,
                stickyHorizontalOffset: timelineHorizontalOffset
            )
                .padding(.leading, 24)

            Text("菱形按钮会在当前时间码记录对应属性关键帧；夹在关键帧之间修改属性会自动补帧。保持插值会维持当前值，到下个关键帧时直接跳变。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
                .offset(x: timelineHorizontalOffset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var propertyTools: some View {
        HStack(spacing: 8) {
            TextField("搜索摄像机属性", text: $propertySearchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            Menu("折叠预设") {
                Button("全部展开") {
                    collapsedGroups = []
                }
                Button("只看方向") {
                    collapsedGroups = Set(cameraGroups.map(\.id).filter { $0 != "orientation" })
                }
                Button("只看位置") {
                    collapsedGroups = Set(cameraGroups.map(\.id).filter { $0 != "position" })
                }
                Button("只看镜头") {
                    collapsedGroups = Set(cameraGroups.map(\.id).filter { $0 != "lens" })
                }
                Button("全部折叠") {
                    collapsedGroups = Set(cameraGroups.map(\.id))
                }
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.leading, 24)
    }

    private var cameraGroups: [CompositionPropertyGroupData<CompositionCameraKeyframeProperty>] {
        var groups: [CompositionPropertyGroupData<CompositionCameraKeyframeProperty>] = [
            CompositionPropertyGroupData(
                id: "orientation",
                title: "方向",
                properties: [.yaw, .pitch, .roll]
            ),
            CompositionPropertyGroupData(
                id: "position",
                title: "位置",
                properties: [.positionX, .positionY, .positionZ]
            )
        ]
        if model.compositionCamera.focusLockEnabled {
            groups.append(
                CompositionPropertyGroupData(
                    id: "focus",
                    title: "焦点锁定",
                    properties: [.focusTargetX, .focusTargetY, .focusTargetZ]
                )
            )
        }
        groups.append(
            CompositionPropertyGroupData(
                id: "lens",
                title: "镜头",
                properties: [.focalLength, .aperture]
            )
        )
        return groups
    }

    private var displayedCameraGroups: [CompositionPropertyGroupData<CompositionCameraKeyframeProperty>] {
        cameraGroups.compactMap { group in
            let properties = filteredProperties(group.properties, groupTitle: group.title)
            guard !properties.isEmpty else { return nil }
            return CompositionPropertyGroupData(id: group.id, title: group.title, properties: properties)
        }
    }

    private func filteredProperties(
        _ properties: [CompositionCameraKeyframeProperty],
        groupTitle: String
    ) -> [CompositionCameraKeyframeProperty] {
        let query = propertySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return properties }
        return properties.filter { property in
            property.title.lowercased().contains(query)
                || property.rawValue.lowercased().contains(query)
                || groupTitle.lowercased().contains(query)
        }
    }

    private func groupExpandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(id) || !propertySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            set: { isExpanded in
                if isExpanded {
                    collapsedGroups.remove(id)
                } else {
                    collapsedGroups.insert(id)
                }
            }
        )
    }

    private func keyframedRowsHeight(for properties: [CompositionCameraKeyframeProperty]) -> CGFloat {
        let count = properties.count
        guard count > 0 else { return 0 }
        return CGFloat(count) * propertyRowHeight + CGFloat(count - 1) * propertyRowSpacing
    }

    @ViewBuilder
    private func cameraRow(for property: CompositionCameraKeyframeProperty) -> some View {
        switch property {
        case .yaw:
            cameraRow(
                property: .yaw,
                title: "Yaw 偏航",
                value: cameraAngleBinding(\.yaw),
                dragScale: 0.35,
                displayMode: .turnsDegrees,
                resetValue: 0,
                disabled: model.compositionCamera.focusLockEnabled
            )
        case .pitch:
            cameraRow(
                property: .pitch,
                title: "Pitch 俯仰",
                value: cameraAngleBinding(\.pitch),
                dragScale: 0.35,
                displayMode: .turnsDegrees,
                resetValue: 0,
                disabled: model.compositionCamera.focusLockEnabled
            )
        case .roll:
            cameraRow(
                property: .roll,
                title: "Roll 翻滚",
                value: cameraAngleBinding(\.roll),
                dragScale: 0.35,
                displayMode: .turnsDegrees,
                resetValue: 0
            )
        case .positionX:
            cameraRow(property: .positionX, title: "位置X", value: cameraFloatBinding(\.positionX), resetValue: 0)
        case .positionY:
            cameraRow(property: .positionY, title: "位置Y", value: cameraFloatBinding(\.positionY), resetValue: 0)
        case .positionZ:
            cameraRow(
                property: .positionZ,
                title: "位置Z",
                value: cameraFloatBinding(\.positionZ),
                resetValue: Double(CompositionModel.defaultCompositionCamera().positionZ)
            )
        case .focusTargetX:
            cameraRow(property: .focusTargetX, title: "焦点X", value: cameraFloatBinding(\.focusTargetX), resetValue: 0)
        case .focusTargetY:
            cameraRow(property: .focusTargetY, title: "焦点Y", value: cameraFloatBinding(\.focusTargetY), resetValue: 0)
        case .focusTargetZ:
            cameraRow(property: .focusTargetZ, title: "焦点Z", value: cameraFloatBinding(\.focusTargetZ), resetValue: 0)
        case .focalLength:
            cameraRow(
                property: .focalLength,
                title: "焦段",
                value: cameraFloatBinding(\.focalLength, lowerLimit: 1, syncFocusOrientation: false),
                dragScale: 0.35,
                suffix: "mm",
                resetValue: Double(CompositionModel.defaultCompositionCamera().focalLength)
            )
        case .aperture:
            cameraRow(
                property: .aperture,
                title: "光圈",
                value: cameraFloatBinding(\.aperture, lowerLimit: 0.1, syncFocusOrientation: false),
                dragScale: 0.02,
                resetValue: Double(CompositionModel.defaultCompositionCamera().aperture)
            )
        }
    }

    private func selectCameraKeyframes(
        in rect: CGRect,
        extending: Bool,
        properties: [CompositionCameraKeyframeProperty]
    ) {
        let hitRect = rect.insetBy(dx: -7, dy: -7)
        var selections: Set<CompositionCameraKeyframeSelection> = []
        for (index, property) in properties.enumerated() {
            let rowY = rowCenterY(for: index)
            for keyframe in model.compositionCameraKeyframes(for: property) {
                let point = CGPoint(x: keyframeX(for: keyframe.frame), y: rowY)
                if hitRect.contains(point) {
                    selections.insert(
                        CompositionCameraKeyframeSelection(property: property, frame: keyframe.frame)
                    )
                }
            }
        }
        model.setBoxSelectedCameraKeyframes(selections, extending: extending)
    }

    private func isCameraMarker(
        at point: CGPoint,
        properties: [CompositionCameraKeyframeProperty]
    ) -> Bool {
        let tolerance: CGFloat = 9
        for (index, property) in properties.enumerated() {
            guard abs(point.y - rowCenterY(for: index)) <= tolerance else { continue }
            for keyframe in model.compositionCameraKeyframes(for: property) {
                if abs(point.x - keyframeX(for: keyframe.frame)) <= tolerance {
                    return true
                }
            }
        }
        return false
    }

    private func rowCenterY(for index: Int) -> CGFloat {
        CGFloat(index) * (propertyRowHeight + propertyRowSpacing) + propertyRowHeight / 2
    }

    private func keyframeX(for frame: Int) -> CGFloat {
        let total = max(1, model.composition.frameCount)
        let rawX = CGFloat(max(0, min(total, frame))) / CGFloat(total) * timelineWidth
        let edgeInset: CGFloat = 9
        guard timelineWidth > edgeInset * 2 else { return rawX }
        return max(edgeInset, min(timelineWidth - edgeInset, rawX))
    }

    private func cameraRow(
        property: CompositionCameraKeyframeProperty,
        title: String,
        value: Binding<Double>,
        dragScale: Double = 0.01,
        suffix: String = "",
        displayMode: DraggableNumberField.DisplayMode = .number,
        resetValue: Double?,
        disabled: Bool = false
    ) -> some View {
        KeyframedPropertyRow(
            title: title,
            value: value,
            isKeyframedAtCurrentFrame: model.hasCompositionCameraKeyframe(property: property),
            keyframes: model.compositionCameraKeyframes(for: property).map {
                PropertyKeyframeMarker(frame: $0.frame, value: $0.value, interpolation: $0.interpolation, bezierCurve: $0.bezierCurve)
            },
            isKeyframeSelected: { frame in
                model.selectedCameraKeyframes.contains(
                    CompositionCameraKeyframeSelection(property: property, frame: frame)
                )
            },
            currentFrame: model.currentFrame,
            frameCount: model.composition.frameCount,
            timelineWidth: timelineWidth,
            propertyPanelWidth: propertyPanelWidth,
            timelineHorizontalOffset: timelineHorizontalOffset,
            timelineMode: keyframeTimelineMode,
            showSelectedKeyframeCurves: showSelectedKeyframeCurves,
            normalizeCurveValues: model.workspaceLayout.normalizeCurveValues,
            curveValueZoom: model.workspaceLayout.curveEditorZoom,
            curveValuePan: model.workspaceLayout.curveEditorPanY,
            snapCurveHandles: model.workspaceLayout.snapCurveHandles,
            curveColor: color(for: property),
            rowHeight: propertyRowHeight,
            dragScale: dragScale,
            suffix: suffix,
            displayMode: displayMode,
            resetValue: resetValue,
            disabled: disabled,
            expression: model.compositionCameraExpression(for: property),
            setExpressionEnabled: { enabled in
                model.setCompositionCameraExpressionEnabled(property, enabled: enabled)
            },
            setExpressionSource: { source in
                model.setCompositionCameraExpressionSource(property, source: source)
            },
            beginValueDrag: {
                model.beginCompositionValueDrag()
            },
            endValueDrag: {
                model.endCompositionValueDrag()
            }
        ) {
            model.toggleCompositionCameraPropertyKeyframes(property)
        } selectKeyframes: { frames, extending in
            model.setBoxSelectedCameraKeyframes(
                property: property,
                frames: frames,
                extending: extending
            )
        } beginKeyframeDrag: {
            model.beginSelectedKeyframeDrag()
        } updateKeyframeDrag: { delta in
            model.updateSelectedKeyframeDrag(by: delta)
        } endKeyframeDrag: {
            model.endSelectedKeyframeDrag()
        } setBezierCurve: { frame, curve in
            model.setCameraKeyframeBezierCurve(
                property: property,
                frame: frame,
                curve: curve,
                recordHistory: false
            )
        }
    }

    private func color(for property: CompositionCameraKeyframeProperty) -> Color {
        switch property {
        case .yaw: return .red
        case .pitch: return .green
        case .roll: return .blue
        case .positionX: return .orange
        case .positionY: return .pink
        case .positionZ: return .purple
        case .focusTargetX: return .cyan
        case .focusTargetY: return .mint
        case .focusTargetZ: return .teal
        case .focalLength: return .yellow
        case .aperture: return .indigo
        }
    }

    private func cameraAngleBinding(_ keyPath: WritableKeyPath<CameraRigState, Float>) -> Binding<Double> {
        let property: CompositionCameraKeyframeProperty = {
            switch keyPath {
            case \CameraRigState.yaw: return .yaw
            case \CameraRigState.pitch: return .pitch
            default: return .roll
            }
        }()
        return Binding(
            get: { Double(model.compositionCamera[keyPath: keyPath]) * 180.0 / .pi },
            set: { newValue in
                model.setCompositionCameraProperty(
                    property,
                    value: Float(newValue * .pi / 180.0),
                    syncFocusOrientation: false
                )
            }
        )
    }

    private func cameraFloatBinding(
        _ keyPath: WritableKeyPath<CameraRigState, Float>,
        lowerLimit: Double? = nil,
        syncFocusOrientation: Bool = true
    ) -> Binding<Double> {
        let property = cameraProperty(for: keyPath)
        return Binding(
            get: { Double(model.compositionCamera[keyPath: keyPath]) },
            set: { newValue in
                let resolved = lowerLimit.map { max($0, newValue) } ?? newValue
                model.setCompositionCameraProperty(
                    property,
                    value: Float(resolved),
                    syncFocusOrientation: syncFocusOrientation
                )
            }
        )
    }

    private func cameraProperty(
        for keyPath: WritableKeyPath<CameraRigState, Float>
    ) -> CompositionCameraKeyframeProperty {
        switch keyPath {
        case \CameraRigState.positionX: return .positionX
        case \CameraRigState.positionY: return .positionY
        case \CameraRigState.positionZ: return .positionZ
        case \CameraRigState.focusTargetX: return .focusTargetX
        case \CameraRigState.focusTargetY: return .focusTargetY
        case \CameraRigState.focusTargetZ: return .focusTargetZ
        case \CameraRigState.focalLength: return .focalLength
        default: return .aperture
        }
    }
}

private struct CompositionTimelineCameraBlock: View {
    @ObservedObject var model: CompositionModel
    let clipID: UUID
    let rowTop: CGFloat
    let width: CGFloat
    let trackLeadingX: CGFloat
    let showOverflow: Bool

    @State private var dragStartFrame: Int?
    @State private var moveGrabOffset: CGFloat?
    @State private var resizeGrabOffset: CGFloat?

    private var clip: CompositionCameraClip? {
        model.composition.cameraClips.first { $0.id == clipID }
    }

    var body: some View {
        Group {
            if let clip {
                block(clip)
            }
        }
    }

    @ViewBuilder
    private func block(_ clip: CompositionCameraClip) -> some View {
        let total = max(1, model.composition.frameCount)
        let clipEnd = clip.startFrame + clip.duration
        let visibleStart = showOverflow ? clip.startFrame : max(0, clip.startFrame)
        let visibleEnd = showOverflow ? clipEnd : min(total, clipEnd)
        if visibleEnd > visibleStart {
            let x = CGFloat(visibleStart) / CGFloat(total) * width
            let w = max(18, CGFloat(visibleEnd - visibleStart) / CGFloat(total) * width)
            let selected = model.selectedCameraClipID == clip.id

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(clip.isVisible
                        ? (selected ? Color.purple.opacity(0.86) : Color.purple.opacity(0.58))
                        : Color.gray.opacity(0.34)
                    )

                HStack(spacing: 4) {
                    if !clip.isVisible {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                    }
                    Text(clip.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(clip.startFrame) +\(clip.duration)")
                        .font(.caption2.monospacedDigit())
                        .opacity(0.82)
                }
                .padding(.horizontal, 8)
            }
            .font(.caption)
            .foregroundStyle(.white)
            .frame(width: w, height: 28)
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectCameraClip(clip.id)
            }
            .gesture(moveGesture(clip: clip))
            .overlay(alignment: .leading) {
                resizeHandle(edge: .leading, clip: clip)
            }
            .overlay(alignment: .trailing) {
                resizeHandle(edge: .trailing, clip: clip)
            }
            .overlay(alignment: .leading) {
                cameraKeyframeMarkers(clip: clip, width: w)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.white.opacity(0.85) : Color.clear, lineWidth: 1.5)
            }
            .position(x: x + w / 2, y: rowTop + 14)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private enum Edge {
        case leading
        case trailing
    }

    private func resizeHandle(edge: Edge, clip: CompositionCameraClip) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.32))
                .frame(width: 7, height: 28)
            Color.clear
                .frame(width: 18, height: 32)
        }
        .frame(width: 18, height: 32)
        .contentShape(Rectangle())
        .highPriorityGesture(resizeGesture(edge: edge, clip: clip))
        .help(edge == .leading ? "拖动修改摄像机开始时间码" : "拖动修改摄像机时长")
    }

    private func cameraKeyframeMarkers(clip: CompositionCameraClip, width: CGFloat) -> some View {
        let duration = max(1, clip.duration)
        let frames = Array(Set(clip.keyframes.map(\.frame))).sorted()
        return ZStack(alignment: .leading) {
            ForEach(frames, id: \.self) { frame in
                let localFrame = frame - clip.startFrame
                Image(systemName: "diamond.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .position(
                        x: CGFloat(localFrame) / CGFloat(duration) * width,
                        y: 14
                    )
            }
        }
    }

    private func moveGesture(clip: CompositionCameraClip) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(compositionTimelineCoordinateSpace))
            .onChanged { value in
                if dragStartFrame == nil {
                    dragStartFrame = clip.startFrame
                    model.selectCameraClip(clip.id)
                }
                let timelineX = value.location.x - trackLeadingX
                if moveGrabOffset == nil {
                    moveGrabOffset = timelineX - xPosition(forFrame: dragStartFrame ?? clip.startFrame)
                }
                let targetFrame = frame(forTimelineX: timelineX - (moveGrabOffset ?? 0))
                let delta = targetFrame - (dragStartFrame ?? clip.startFrame)
                model.moveCameraClip(id: clip.id, startFrame: (dragStartFrame ?? clip.startFrame) + delta)
            }
            .onEnded { _ in
                dragStartFrame = nil
                moveGrabOffset = nil
            }
    }

    private func resizeGesture(edge: Edge, clip: CompositionCameraClip) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(compositionTimelineCoordinateSpace))
            .onChanged { value in
                model.selectCameraClip(clip.id)
                let timelineX = value.location.x - trackLeadingX
                if resizeGrabOffset == nil {
                    let edgeFrame = edge == .leading
                        ? clip.startFrame
                        : clip.startFrame + clip.duration
                    resizeGrabOffset = timelineX - xPosition(forFrame: edgeFrame)
                }
                let targetFrame = frame(forTimelineX: timelineX - (resizeGrabOffset ?? 0))
                switch edge {
                case .leading:
                    model.trimCameraClipStart(id: clip.id, startFrame: targetFrame)
                case .trailing:
                    model.trimCameraClipEnd(id: clip.id, endFrame: targetFrame)
                }
            }
            .onEnded { _ in
                resizeGrabOffset = nil
            }
    }

    private func frame(forTimelineX x: CGFloat) -> Int {
        let total = max(1, model.composition.frameCount)
        let frame = Int((x / max(1, width) * CGFloat(total)).rounded())
        let tolerance = max(2, Int((CGFloat(total) / max(1, width) * 10).rounded()))
        return model.snappedTimelineFrame(frame, tolerance: tolerance, force: isShiftDown)
    }

    private func xPosition(forFrame frame: Int) -> CGFloat {
        let total = max(1, model.composition.frameCount)
        return CGFloat(frame) / CGFloat(total) * width
    }
}

private struct CompositionTimelineLayerBlock: View {
    @ObservedObject var model: CompositionModel
    let layerID: UUID
    let rowTop: CGFloat
    let width: CGFloat
    let trackLeadingX: CGFloat
    let showOverflow: Bool

    @State private var dragStartFrame: Int?
    @State private var groupMoveLastDelta = 0
    @State private var moveGrabOffset: CGFloat?
    @State private var resizeGrabOffset: CGFloat?

    private var layer: CompositionLayer? {
        model.composition.layers.first { $0.id == layerID }
    }

    var body: some View {
        Group {
            if let layer {
                block(layer)
            }
        }
    }

    @ViewBuilder
    private func block(_ layer: CompositionLayer) -> some View {
        let total = max(1, model.composition.frameCount)
        let layerEnd = layer.startFrame + layer.duration
        let visibleStart = showOverflow ? layer.startFrame : max(0, layer.startFrame)
        let visibleEnd = showOverflow ? layerEnd : min(total, layerEnd)
        if visibleEnd > visibleStart {
            let x = CGFloat(visibleStart) / CGFloat(total) * width
            let w = max(18, CGFloat(visibleEnd - visibleStart) / CGFloat(total) * width)
            let selected = model.selectedLayerIDs.contains(layer.id) || model.selectedLayerID == layer.id

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(layer.isVisible
                        ? (layer.isSolo
                            ? Color.orange.opacity(selected ? 0.86 : 0.68)
                            : (selected ? Color.accentColor.opacity(0.78) : Color.blue.opacity(0.58)))
                        : Color.gray.opacity(0.36)
                    )

                HStack(spacing: 4) {
                    if layer.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                    }
                    Text(layer.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(layer.startFrame) +\(layer.duration)")
                        .font(.caption2.monospacedDigit())
                        .opacity(0.82)
                }
                .padding(.horizontal, 8)
            }
            .font(.caption)
            .foregroundStyle(.white)
            .frame(width: w, height: 28)
            .contentShape(Rectangle())
            .onTapGesture {
                if isShiftDown {
                    model.selectLayerRange(to: layer.id)
                } else if isCommandDown {
                    model.toggleLayerSelection(layer.id)
                } else {
                    model.selectOnlyLayer(layer.id)
                }
            }
            .gesture(moveGesture(layer: layer))
            .overlay(alignment: .leading) {
                resizeHandle(edge: .leading, layer: layer)
            }
            .overlay(alignment: .trailing) {
                resizeHandle(edge: .trailing, layer: layer)
            }
            .overlay(alignment: .leading) {
                layerKeyframeMarkers(layer: layer, width: w)
            }
            .position(x: x + w / 2, y: rowTop + 14)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private func layerKeyframeMarkers(layer: CompositionLayer, width: CGFloat) -> some View {
        let duration = max(1, layer.duration)
        let frames = Array(Set(layer.keyframes.map(\.frame))).sorted()
        return ZStack(alignment: .leading) {
            ForEach(frames, id: \.self) { frame in
                let localFrame = max(0, min(duration, frame - layer.startFrame))
                Image(systemName: "diamond.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .position(
                        x: CGFloat(localFrame) / CGFloat(duration) * width,
                        y: 14
                    )
            }
        }
    }

    private enum Edge {
        case leading
        case trailing
    }

    private func resizeHandle(edge: Edge, layer: CompositionLayer) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.32))
                .frame(width: 7, height: 28)

            Color.clear
                .frame(width: 18, height: 32)
        }
        .frame(width: 18, height: 32)
        .contentShape(Rectangle())
        .highPriorityGesture(resizeGesture(edge: edge, layer: layer))
        .help(edge == .leading ? "拖动修改开始时间码" : "拖动修改时长")
    }

    private func moveGesture(layer: CompositionLayer) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(compositionTimelineCoordinateSpace))
            .onChanged { value in
                if dragStartFrame == nil {
                    dragStartFrame = layer.startFrame
                    groupMoveLastDelta = 0
                    if !model.selectedLayerIDs.contains(layer.id) {
                        if isShiftDown {
                            model.selectLayerRange(to: layer.id)
                        } else if isCommandDown {
                            model.toggleLayerSelection(layer.id)
                        } else {
                            model.selectOnlyLayer(layer.id)
                        }
                    }
                }
                let timelineX = value.location.x - trackLeadingX
                if moveGrabOffset == nil {
                    moveGrabOffset = timelineX - xPosition(forFrame: dragStartFrame ?? layer.startFrame)
                }
                let targetFrame = frame(forTimelineX: timelineX - (moveGrabOffset ?? 0))
                let delta = targetFrame - (dragStartFrame ?? layer.startFrame)
                if model.selectedLayerIDs.contains(layer.id), model.selectedLayerIDs.count > 1 {
                    let incremental = delta - groupMoveLastDelta
                    model.shiftSelectedLayers(by: incremental)
                    groupMoveLastDelta = delta
                } else {
                    model.moveLayer(id: layer.id, startFrame: (dragStartFrame ?? layer.startFrame) + delta)
                }
            }
            .onEnded { _ in
                dragStartFrame = nil
                groupMoveLastDelta = 0
                moveGrabOffset = nil
            }
    }

    private func resizeGesture(edge: Edge, layer: CompositionLayer) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(compositionTimelineCoordinateSpace))
            .onChanged { value in
                model.selectedLayerID = layer.id
                let timelineX = value.location.x - trackLeadingX
                if resizeGrabOffset == nil {
                    let edgeFrame = edge == .leading
                        ? layer.startFrame
                        : layer.startFrame + layer.duration
                    resizeGrabOffset = timelineX - xPosition(forFrame: edgeFrame)
                }
                let targetFrame = frame(forTimelineX: timelineX - (resizeGrabOffset ?? 0))

                switch edge {
                case .leading:
                    model.trimLayerStart(id: layer.id, startFrame: targetFrame)
                case .trailing:
                    model.trimLayerEnd(id: layer.id, endFrame: targetFrame)
                }
            }
            .onEnded { _ in
                resizeGrabOffset = nil
            }
    }

    private func frames(for translation: CGFloat) -> Int {
        let total = max(1, model.composition.frameCount)
        return Int((translation / max(1, width) * CGFloat(total)).rounded())
    }

    private func frame(forTimelineX x: CGFloat) -> Int {
        let total = max(1, model.composition.frameCount)
        let progress = x / max(1, width)
        let frame = Int((progress * CGFloat(total)).rounded())
        let tolerance = max(2, Int((CGFloat(total) / max(1, width) * 10).rounded()))
        return model.snappedTimelineFrame(frame, tolerance: tolerance, force: isShiftDown)
    }

    private func xPosition(forFrame frame: Int) -> CGFloat {
        let total = max(1, model.composition.frameCount)
        return CGFloat(frame) / CGFloat(total) * width
    }
}

@MainActor
private struct CompositionTimelineDropDelegate: DropDelegate {
    let model: CompositionModel
    let width: CGFloat
    let leadingOffset: CGFloat
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let frame = model.frameForDrop(x: max(0, info.location.x - leadingOffset), width: width)
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let idString = object as? String else { return }
            Task { @MainActor in
                model.addLayer(assetIDString: idString)
                if let selectedID = model.selectedLayerID,
                   let index = model.composition.layers.firstIndex(where: { $0.id == selectedID }) {
                    model.composition.layers[index].startFrame = frame
                    model.clampCompositionSettings()
                }
            }
        }
        return true
    }
}

private struct CompositionLayerInspector: View {
    @ObservedObject var model: CompositionModel
    @Binding var layer: CompositionLayer
    let timelineWidth: CGFloat
    let propertyPanelWidth: CGFloat
    let timelineHorizontalOffset: CGFloat
    let keyframeTimelineMode: CompositionKeyframeTimelineMode
    let showSelectedKeyframeCurves: Bool

    @State private var propertySearchText = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var isModifierPanelExpanded = false

    private let propertyRowHeight: CGFloat = 30
    private let propertyRowSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(layer.name)
                .font(.headline)
                .lineLimit(1)
                .frame(width: propertyPanelWidth, alignment: .leading)
                .offset(x: timelineHorizontalOffset)

            HStack {
                DraggableIntField(title: "开始", value: $layer.startFrame, dragScale: 0.25, resetValue: 0)
                DraggableIntField(title: "时长", value: $layer.duration, lowerLimit: 1, dragScale: 0.25, resetValue: 1)
            }
            .padding(.leading, 24)
            .offset(x: timelineHorizontalOffset)

            HStack(spacing: 8) {
                Text("混合")
                    .font(.caption.bold())
                    .frame(width: 44, alignment: .leading)

                Picker("混合模式", selection: blendModeBinding) {
                    ForEach(CompositionLayerBlendMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 152)
                .help(layer.blendMode.helpText)
            }
            .padding(.leading, 24)
            .frame(width: propertyPanelWidth, alignment: .leading)
            .offset(x: timelineHorizontalOffset)

            HStack(spacing: 8) {
                Text("体显示")
                    .font(.caption.bold())
                    .frame(width: 44, alignment: .leading)

                Picker("体显示", selection: volumeRenderModeBinding) {
                    ForEach(CompositionLayerVolumeRenderMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 152)
                .help("Alpha体适合透明体积；像素体会以方块体素方式显示此图层。")
            }
            .padding(.leading, 24)
            .frame(width: propertyPanelWidth, alignment: .leading)
            .offset(x: timelineHorizontalOffset)

            layerModifierToolbar
                .frame(width: propertyPanelWidth, alignment: .leading)
                .offset(x: timelineHorizontalOffset)

            layerModifierEditor
                .frame(width: propertyPanelWidth + timelineWidth, alignment: .leading)

            propertyTools
                .frame(width: propertyPanelWidth, alignment: .leading)
                .offset(x: timelineHorizontalOffset)

            if displayedLayerGroups.isEmpty {
                Text("没有匹配的图层属性")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
                    .offset(x: timelineHorizontalOffset)
            } else {
                ForEach(displayedLayerGroups) { group in
                    CompositionPropertyGroup(
                        title: group.title,
                        count: group.properties.count,
                        propertyPanelWidth: propertyPanelWidth,
                        stickyHorizontalOffset: timelineHorizontalOffset,
                        isExpanded: groupExpandedBinding(group.id)
                    ) {
                        KeyframeSelectionGroup(
                            propertyPanelWidth: propertyPanelWidth,
                            timelineWidth: timelineWidth,
                            height: keyframedRowsHeight(for: group.properties),
                            allowsSelection: keyframeTimelineMode == .keyframes,
                            isMarkerAt: { isLayerMarker(at: $0, properties: group.properties) },
                            onSelect: { rect, extending in
                                selectLayerKeyframes(in: rect, extending: extending, properties: group.properties)
                            }
                        ) {
                            VStack(alignment: .leading, spacing: propertyRowSpacing) {
                                ForEach(group.properties) { property in
                                    layerRow(for: property)
                                }
                            }
                        }
                    }
                }
            }

            KeyframeCurveEditorPanel(
                model: model,
                stickyHorizontalOffset: timelineHorizontalOffset
            )
                .padding(.leading, 24)

            Text("删除层：选中图层后按 Delete。保持插值会维持当前值，到下个关键帧时直接跳变。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
                .offset(x: timelineHorizontalOffset)
        }
        .disabled(layer.isLocked)
        .overlay(alignment: .topTrailing) {
            if layer.isLocked {
                Label("已锁定", systemImage: "lock.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                    .padding(.trailing, 8)
            }
        }
    }

    private var propertyTools: some View {
        HStack(spacing: 8) {
            TextField("搜索图层属性", text: $propertySearchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            Menu("折叠预设") {
                Button("全部展开") {
                    collapsedGroups = []
                }
                Button("只看位置") {
                    collapsedGroups = Set(layerGroups.map(\.id).filter { $0 != "position" })
                }
                Button("只看旋转") {
                    collapsedGroups = Set(layerGroups.map(\.id).filter { $0 != "rotation" })
                }
                Button("只看外观") {
                    collapsedGroups = Set(layerGroups.map(\.id).filter { $0 != "appearance" })
                }
                Button("全部折叠") {
                    collapsedGroups = Set(layerGroups.map(\.id))
                }
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.leading, 24)
    }

    private var blendModeBinding: Binding<CompositionLayerBlendMode> {
        Binding(
            get: { layer.blendMode },
            set: { model.setLayerBlendMode(layerID: layer.id, blendMode: $0) }
        )
    }

    private var volumeRenderModeBinding: Binding<CompositionLayerVolumeRenderMode> {
        Binding(
            get: { layer.volumeRenderMode },
            set: { model.setLayerVolumeRenderMode(layerID: layer.id, mode: $0) }
        )
    }

    @ViewBuilder
    private var layerModifierToolbar: some View {
        if model.canUseLayerModifiers(layerID: layer.id) {
            HStack(spacing: 8) {
                Button(layer.modifiers.isEmpty ? "添加模型修改器" : "添加修改器") {
                    model.addLayerModifier(layerID: layer.id)
                    isModifierPanelExpanded = true
                }
                .buttonStyle(.bordered)

                Text(layer.modifiers.isEmpty ? "未添加" : "\(layer.modifiers.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 24)
        }
    }

    @ViewBuilder
    private var layerModifierEditor: some View {
        if model.canUseLayerModifiers(layerID: layer.id) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    isModifierPanelExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isModifierPanelExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                        Text("修改器参数")
                            .font(.caption.bold())
                        if !layer.modifiers.isEmpty {
                            Text("\(layer.modifiers.count)")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 24)
                .frame(width: propertyPanelWidth, alignment: .leading)
                .offset(x: timelineHorizontalOffset)
                .zIndex(10)

                if isModifierPanelExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Button("添加修改器") {
                            model.addLayerModifier(layerID: layer.id)
                            isModifierPanelExpanded = true
                        }
                        Button("上移") {
                            model.moveSelectedLayerModifier(layerID: layer.id, up: true)
                        }
                        .disabled(activeLayerModifier == nil)
                        Button("下移") {
                            model.moveSelectedLayerModifier(layerID: layer.id, up: false)
                        }
                        .disabled(activeLayerModifier == nil)
                        Button("删除") {
                            model.deleteSelectedLayerModifier(layerID: layer.id)
                        }
                        .disabled(activeLayerModifier == nil)
                    }
                    .buttonStyle(.bordered)
                    .padding(.leading, 42)
                    .frame(width: propertyPanelWidth, alignment: .leading)
                    .offset(x: timelineHorizontalOffset)
                    .zIndex(10)

                    if layer.modifiers.isEmpty {
                        Text("此图层还没有修改器。修改器会作用在此图层自己的体素代理上，不会改原素材。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 42)
                            .frame(width: propertyPanelWidth, alignment: .leading)
                            .offset(x: timelineHorizontalOffset)
                            .zIndex(10)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(layer.modifiers) { modifier in
                                HStack(spacing: 6) {
                                    Toggle(
                                        "",
                                        isOn: Binding(
                                            get: { modifier.isEnabled },
                                            set: {
                                                model.setLayerModifierEnabled(
                                                    layerID: layer.id,
                                                    modifierID: modifier.id,
                                                    isEnabled: $0
                                                )
                                            }
                                        )
                                    )
                                    .labelsHidden()
                                    Button {
                                        model.selectLayerModifier(layerID: layer.id, modifierID: modifier.id)
                                    } label: {
                                        HStack {
                                            Text(modifier.name)
                                                .lineLimit(1)
                                            Spacer()
                                            if selectedLayerModifierID == modifier.id {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.bold())
                                            }
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(selectedLayerModifierID == modifier.id ? Color.accentColor.opacity(0.16) : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.leading, 42)
                        .frame(width: propertyPanelWidth, alignment: .leading)
                        .offset(x: timelineHorizontalOffset)
                        .zIndex(10)
                    }

                    if activeLayerModifier != nil {
                        Divider()
                        Button("复位当前修改器") {
                            model.resetSelectedLayerModifier(layerID: layer.id)
                        }
                        .buttonStyle(.bordered)
                        .padding(.leading, 42)
                        .frame(width: propertyPanelWidth, alignment: .leading)
                        .offset(x: timelineHorizontalOffset)
                        .zIndex(10)

                        Group {
                            modifierSliderRow(.positionX, range: -2...2)
                            modifierSliderRow(.positionY, range: -2...2)
                            modifierSliderRow(.positionZ, range: -2...2)
                            modifierSliderRow(.rotationX, range: -360...360, suffix: "°")
                            modifierSliderRow(.rotationY, range: -360...360, suffix: "°")
                            modifierSliderRow(.rotationZ, range: -360...360, suffix: "°")
                            modifierSliderRow(.scaleX, range: 0.05...4)
                            modifierSliderRow(.scaleY, range: 0.05...4)
                            modifierSliderRow(.scaleZ, range: 0.05...4)
                            modifierSliderRow(.inflate, range: -0.4...0.4)

                            HStack(spacing: 8) {
                                Text("膨胀方式")
                                    .font(.caption.bold())
                                    .frame(width: 62, alignment: .leading)
                                Picker("膨胀方式", selection: modifierInflateModeBinding) {
                                    ForEach(VoxelInflateMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 136, alignment: .leading)
                            }
                            .padding(.leading, 42)
                            .frame(width: propertyPanelWidth, alignment: .leading)
                            .offset(x: timelineHorizontalOffset)
                            .zIndex(10)
                            .clipped()

                            modifierSliderRow(.twistY, range: -360...360, suffix: "°")
                            modifierSliderRow(.taperX, range: -1...1)
                            modifierSliderRow(.taperZ, range: -1...1)

                            VStack(alignment: .leading, spacing: propertyRowSpacing) {
                                modifierToggleRow(.mirrorX)
                                modifierToggleRow(.mirrorY)
                                modifierToggleRow(.mirrorZ)
                            }
                            .font(.caption)
                        }
                        .frame(width: propertyPanelWidth + timelineWidth, alignment: .leading)
                    }
                }
                .padding(.top, 6)
                }
            }
        } else if model.isPrecompositionLayer(layer) {
            Text("预合成层请打开内容后修改内部图层。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
        }
    }

    private var selectedLayerModifierID: UUID? {
        if let selected = model.selectedLayerModifierIDs[layer.id],
           layer.modifiers.contains(where: { $0.id == selected }) {
            return selected
        }
        return layer.modifiers.first?.id
    }

    private var activeLayerModifier: MeshModifierItem? {
        guard let selectedLayerModifierID else { return nil }
        return layer.modifiers.first { $0.id == selectedLayerModifierID }
    }

    private func modifierSliderRow(
        _ property: MeshModifierKeyframeProperty,
        range: ClosedRange<Double>,
        suffix: String = ""
    ) -> some View {
        KeyframedPropertyRow(
            title: property.title,
            value: modifierValueBinding(property),
            isKeyframedAtCurrentFrame: model.hasSelectedLayerModifierKeyframe(layerID: layer.id, property: property),
            keyframes: model.selectedLayerModifierKeyframes(layerID: layer.id, property: property).map {
                PropertyKeyframeMarker(
                    frame: $0.frame,
                    value: modifierDisplayValue($0.value, property: property),
                    interpolation: $0.interpolation,
                    bezierCurve: $0.bezierCurve
                )
            },
            isKeyframeSelected: { _ in false },
            currentFrame: model.currentFrame,
            frameCount: model.composition.frameCount,
            timelineWidth: timelineWidth,
            propertyPanelWidth: propertyPanelWidth,
            timelineHorizontalOffset: timelineHorizontalOffset,
            timelineMode: keyframeTimelineMode,
            showSelectedKeyframeCurves: showSelectedKeyframeCurves,
            normalizeCurveValues: model.workspaceLayout.normalizeCurveValues,
            curveValueZoom: model.workspaceLayout.curveEditorZoom,
            curveValuePan: model.workspaceLayout.curveEditorPanY,
            snapCurveHandles: model.workspaceLayout.snapCurveHandles,
            curveColor: color(for: property),
            rowHeight: propertyRowHeight,
            dragScale: property.isAngle ? 0.35 : 0.01,
            suffix: suffix,
            displayMode: property.isAngle ? .turnsDegrees : .number,
            resetValue: resetValue(for: property),
            showsExpressionButton: false,
            expression: CompositionPropertyExpression(),
            setExpressionEnabled: { _ in },
            setExpressionSource: { _ in },
            beginValueDrag: {
                model.beginCompositionValueDrag()
            },
            endValueDrag: {
                model.endCompositionValueDrag()
            }
        ) {
            model.toggleSelectedLayerModifierPropertyKeyframes(layerID: layer.id, property: property)
        } selectKeyframes: { _, _ in
        } beginKeyframeDrag: {
        } updateKeyframeDrag: { _ in
        } endKeyframeDrag: {
        } setBezierCurve: { _, _ in
        }
    }

    private func modifierToggleRow(_ property: MeshModifierKeyframeProperty) -> some View {
        let keyframes = model.selectedLayerModifierKeyframes(layerID: layer.id, property: property).map {
            PropertyKeyframeMarker(
                frame: $0.frame,
                value: $0.value,
                interpolation: $0.interpolation,
                bezierCurve: $0.bezierCurve
            )
        }
        let isAtCurrent = model.hasSelectedLayerModifierKeyframe(layerID: layer.id, property: property)
        let hasAny = !keyframes.isEmpty

        return ZStack(alignment: .topLeading) {
            PropertyKeyframeTrack(
                keyframes: keyframes,
                isKeyframeSelected: { _ in false },
                currentFrame: model.currentFrame,
                frameCount: model.composition.frameCount,
                width: timelineWidth,
                mode: keyframeTimelineMode,
                showSelectedKeyframeCurves: showSelectedKeyframeCurves,
                normalizeCurveValues: model.workspaceLayout.normalizeCurveValues,
                curveValueZoom: model.workspaceLayout.curveEditorZoom,
                curveValuePan: model.workspaceLayout.curveEditorPanY,
                snapCurveHandles: model.workspaceLayout.snapCurveHandles,
                curveColor: color(for: property),
                selectKeyframes: { _, _ in },
                beginKeyframeDrag: {},
                updateKeyframeDrag: { _ in },
                endKeyframeDrag: {},
                setBezierCurve: { _, _ in }
            )
            .frame(width: timelineWidth, height: propertyRowHeight)
            .offset(x: propertyPanelWidth)

            HStack(spacing: 6) {
                Button {
                    model.toggleSelectedLayerModifierPropertyKeyframes(layerID: layer.id, property: property)
                } label: {
                    Image(systemName: isAtCurrent ? "diamond.fill" : "diamond")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isAtCurrent || hasAny ? .yellow : .secondary)
                        .frame(width: 16, height: 20)
                }
                .buttonStyle(.borderless)
                .help(hasAny ? "清空此修改器属性的关键帧" : "为此修改器属性添加关键帧")

                Color.clear
                    .frame(width: 16, height: 20)

                Toggle(property.title, isOn: modifierBooleanValueBinding(property))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .frame(width: propertyPanelWidth, height: propertyRowHeight, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1)
            }
            .offset(x: timelineHorizontalOffset)
            .zIndex(5)
        }
        .frame(width: propertyPanelWidth + timelineWidth, height: propertyRowHeight, alignment: .topLeading)
    }

    private func modifierKeyframeButton(_ property: MeshModifierKeyframeProperty) -> some View {
        let isAtCurrent = model.hasSelectedLayerModifierKeyframe(layerID: layer.id, property: property)
        let hasAny = model.hasAnySelectedLayerModifierKeyframes(layerID: layer.id, property: property)
        return Button {
            model.toggleSelectedLayerModifierPropertyKeyframes(layerID: layer.id, property: property)
        } label: {
            Image(systemName: isAtCurrent ? "diamond.fill" : "diamond")
                .font(.caption2)
                .frame(width: 14, height: 14)
                .foregroundStyle(isAtCurrent ? Color.yellow : (hasAny ? Color.yellow.opacity(0.7) : Color.secondary))
        }
        .buttonStyle(.plain)
        .help(hasAny ? "清空此修改器属性的关键帧" : "为此修改器属性添加关键帧")
    }

    private func modifierValueBinding(_ property: MeshModifierKeyframeProperty) -> Binding<Double> {
        Binding(
            get: {
                let value = model.selectedLayerModifierValue(layerID: layer.id, property: property)
                if property.isAngle {
                    return Double(value) * 180.0 / .pi
                }
                return Double(value)
            },
            set: { newValue in
                let value = property.isAngle
                    ? Float(newValue * .pi / 180.0)
                    : Float(newValue)
                model.setSelectedLayerModifierValue(layerID: layer.id, property: property, value: value)
            }
        )
    }

    private func modifierDisplayValue(
        _ value: Float,
        property: MeshModifierKeyframeProperty
    ) -> Float {
        property.isAngle ? value * 180.0 / .pi : value
    }

    private func resetValue(for property: MeshModifierKeyframeProperty) -> Double {
        switch property {
        case .scaleX, .scaleY, .scaleZ:
            return 1
        default:
            return 0
        }
    }

    private func color(for property: MeshModifierKeyframeProperty) -> Color {
        switch property {
        case .positionX: return .red
        case .positionY: return .green
        case .positionZ: return .blue
        case .rotationX: return .orange
        case .rotationY: return .pink
        case .rotationZ: return .purple
        case .scaleX: return .cyan
        case .scaleY: return .mint
        case .scaleZ: return .teal
        case .inflate: return .yellow
        case .twistY: return .indigo
        case .taperX: return .brown
        case .taperZ: return .gray
        case .mirrorX, .mirrorY, .mirrorZ: return .secondary
        }
    }

    private func modifierBooleanValueBinding(_ property: MeshModifierKeyframeProperty) -> Binding<Bool> {
        Binding(
            get: { model.selectedLayerModifierValue(layerID: layer.id, property: property) >= 0.5 },
            set: { newValue in
                model.setSelectedLayerModifierValue(layerID: layer.id, property: property, value: newValue ? 1 : 0)
            }
        )
    }

    private func modifierBinding(
        _ keyPath: WritableKeyPath<MeshModifierState, Float>
    ) -> Binding<Double> {
        Binding(
            get: { Double(model.selectedLayerModifierState(layerID: layer.id)[keyPath: keyPath]) },
            set: { newValue in
                model.updateSelectedLayerModifierState(layerID: layer.id) { state in
                    state[keyPath: keyPath] = Float(newValue)
                }
            }
        )
    }

    private func modifierAngleBinding(
        _ keyPath: WritableKeyPath<MeshModifierState, Float>
    ) -> Binding<Double> {
        Binding(
            get: {
                Double(model.selectedLayerModifierState(layerID: layer.id)[keyPath: keyPath]) * 180.0 / .pi
            },
            set: { newValue in
                model.updateSelectedLayerModifierState(layerID: layer.id) { state in
                    state[keyPath: keyPath] = Float(newValue * .pi / 180.0)
                }
            }
        )
    }

    private var modifierInflateModeBinding: Binding<VoxelInflateMode> {
        Binding(
            get: { model.selectedLayerModifierState(layerID: layer.id).inflateMode },
            set: { newValue in
                model.updateSelectedLayerModifierState(layerID: layer.id) { state in
                    state.inflateMode = newValue
                }
            }
        )
    }

    private func modifierBoolBinding(
        _ keyPath: WritableKeyPath<MeshModifierState, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.selectedLayerModifierState(layerID: layer.id)[keyPath: keyPath] },
            set: { newValue in
                model.updateSelectedLayerModifierState(layerID: layer.id) { state in
                    state[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private var layerGroups: [CompositionPropertyGroupData<CompositionLayerKeyframeProperty>] {
        [
            CompositionPropertyGroupData(
                id: "position",
                title: "位置",
                properties: [.positionX, .positionY, .positionZ]
            ),
            CompositionPropertyGroupData(
                id: "rotation",
                title: "旋转",
                properties: [.rotationX, .rotationY, .rotationZ]
            ),
            CompositionPropertyGroupData(
                id: "appearance",
                title: "外观",
                properties: [.scaleX, .scaleY, .scaleZ, .opacity]
            )
        ]
    }

    private var displayedLayerGroups: [CompositionPropertyGroupData<CompositionLayerKeyframeProperty>] {
        layerGroups.compactMap { group in
            let properties = filteredProperties(group.properties, groupTitle: group.title)
            guard !properties.isEmpty else { return nil }
            return CompositionPropertyGroupData(id: group.id, title: group.title, properties: properties)
        }
    }

    private func filteredProperties(
        _ properties: [CompositionLayerKeyframeProperty],
        groupTitle: String
    ) -> [CompositionLayerKeyframeProperty] {
        let query = propertySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return properties }
        return properties.filter { property in
            property.title.lowercased().contains(query)
                || property.rawValue.lowercased().contains(query)
                || groupTitle.lowercased().contains(query)
        }
    }

    private func groupExpandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroups.contains(id) || !propertySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            set: { isExpanded in
                if isExpanded {
                    collapsedGroups.remove(id)
                } else {
                    collapsedGroups.insert(id)
                }
            }
        )
    }

    private func keyframedRowsHeight(for properties: [CompositionLayerKeyframeProperty]) -> CGFloat {
        let count = properties.count
        guard count > 0 else { return 0 }
        return CGFloat(count) * propertyRowHeight + CGFloat(count - 1) * propertyRowSpacing
    }

    @ViewBuilder
    private func layerRow(for property: CompositionLayerKeyframeProperty) -> some View {
        switch property {
        case .positionX:
            layerRow(property: .positionX, title: "位置X", value: doubleBinding(.positionX), resetValue: 0)
        case .positionY:
            layerRow(property: .positionY, title: "位置Y", value: doubleBinding(.positionY), resetValue: 0)
        case .positionZ:
            layerRow(property: .positionZ, title: "位置Z", value: doubleBinding(.positionZ), resetValue: 0)
        case .rotationX:
            layerRow(
                property: .rotationX,
                title: "旋转X",
                value: degreeBinding(.rotationX),
                dragScale: 0.35,
                displayMode: .turnsDegrees,
                resetValue: 0
            )
        case .rotationY:
            layerRow(
                property: .rotationY,
                title: "旋转Y",
                value: degreeBinding(.rotationY),
                dragScale: 0.35,
                displayMode: .turnsDegrees,
                resetValue: 0
            )
        case .rotationZ:
            layerRow(
                property: .rotationZ,
                title: "旋转Z",
                value: degreeBinding(.rotationZ),
                dragScale: 0.35,
                displayMode: .turnsDegrees,
                resetValue: 0
            )
        case .scale:
            EmptyView()
        case .scaleX:
            layerRow(
                property: .scaleX,
                title: "缩放X",
                value: doubleBinding(.scaleX, lowerLimit: 0.01),
                dragScale: 0.01,
                resetValue: 1,
                inlineAccessory: AnyView(scaleLinkButton(for: .scaleX))
            )
        case .scaleY:
            layerRow(
                property: .scaleY,
                title: "缩放Y",
                value: doubleBinding(.scaleY, lowerLimit: 0.01),
                dragScale: 0.01,
                resetValue: 1,
                inlineAccessory: AnyView(scaleLinkButton(for: .scaleY))
            )
        case .scaleZ:
            layerRow(
                property: .scaleZ,
                title: "缩放T",
                value: doubleBinding(.scaleZ, lowerLimit: 0.01),
                dragScale: 0.01,
                resetValue: 1,
                inlineAccessory: AnyView(scaleLinkButton(for: .scaleZ))
            )
        case .opacity:
            layerRow(
                property: .opacity,
                title: "不透明度",
                value: doubleBinding(.opacity),
                dragScale: 0.01,
                resetValue: 1
            )
        }
    }

    private func scaleLinkButton(for property: CompositionLayerKeyframeProperty) -> some View {
        let isLinked = scaleAxisLinked(property)
        return Button {
            model.setLayerScaleAxisLinked(layerID: layer.id, property: property, isLinked: !isLinked)
        } label: {
            Image(systemName: isLinked ? "link" : "link.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isLinked ? Color.accentColor : Color.secondary)
                .frame(width: 18, height: 20)
        }
        .buttonStyle(.borderless)
        .help(isLinked ? "\(property.title) 已加入等比缩放组" : "\(property.title) 不参与等比缩放")
    }

    private func scaleAxisLinked(_ property: CompositionLayerKeyframeProperty) -> Bool {
        switch property {
        case .scaleX:
            return layer.transform.scaleXLinked
        case .scaleY:
            return layer.transform.scaleYLinked
        case .scaleZ:
            return layer.transform.scaleZLinked
        default:
            return false
        }
    }

    private func selectLayerKeyframes(
        in rect: CGRect,
        extending: Bool,
        properties: [CompositionLayerKeyframeProperty]
    ) {
        let hitRect = rect.insetBy(dx: -7, dy: -7)
        var selections: Set<CompositionLayerKeyframeSelection> = []
        for (index, property) in properties.enumerated() {
            let rowY = rowCenterY(for: index)
            for keyframe in model.layerKeyframes(layerID: layer.id, property: property) {
                let point = CGPoint(x: keyframeX(for: keyframe.frame), y: rowY)
                if hitRect.contains(point) {
                    selections.insert(
                        CompositionLayerKeyframeSelection(
                            layerID: layer.id,
                            property: property,
                            frame: keyframe.frame
                        )
                    )
                }
            }
        }
        model.setBoxSelectedLayerKeyframes(selections, extending: extending)
    }

    private func isLayerMarker(
        at point: CGPoint,
        properties: [CompositionLayerKeyframeProperty]
    ) -> Bool {
        let tolerance: CGFloat = 9
        for (index, property) in properties.enumerated() {
            guard abs(point.y - rowCenterY(for: index)) <= tolerance else { continue }
            for keyframe in model.layerKeyframes(layerID: layer.id, property: property) {
                if abs(point.x - keyframeX(for: keyframe.frame)) <= tolerance {
                    return true
                }
            }
        }
        return false
    }

    private func rowCenterY(for index: Int) -> CGFloat {
        CGFloat(index) * (propertyRowHeight + propertyRowSpacing) + propertyRowHeight / 2
    }

    private func keyframeX(for frame: Int) -> CGFloat {
        let total = max(1, model.composition.frameCount)
        let rawX = CGFloat(max(0, min(total, frame))) / CGFloat(total) * timelineWidth
        let edgeInset: CGFloat = 9
        guard timelineWidth > edgeInset * 2 else { return rawX }
        return max(edgeInset, min(timelineWidth - edgeInset, rawX))
    }

    private func layerRow(
        property: CompositionLayerKeyframeProperty,
        title: String,
        value: Binding<Double>,
        dragScale: Double = 0.01,
        displayMode: DraggableNumberField.DisplayMode = .number,
        resetValue: Double?,
        inlineAccessory: AnyView? = nil
    ) -> some View {
        KeyframedPropertyRow(
            title: title,
            value: value,
            isKeyframedAtCurrentFrame: model.hasLayerKeyframe(layerID: layer.id, property: property),
            keyframes: model.layerKeyframes(layerID: layer.id, property: property).map {
                PropertyKeyframeMarker(frame: $0.frame, value: $0.value, interpolation: $0.interpolation, bezierCurve: $0.bezierCurve)
            },
            isKeyframeSelected: { frame in
                model.selectedLayerKeyframes.contains(
                    CompositionLayerKeyframeSelection(layerID: layer.id, property: property, frame: frame)
                )
            },
            currentFrame: model.currentFrame,
            frameCount: model.composition.frameCount,
            timelineWidth: timelineWidth,
            propertyPanelWidth: propertyPanelWidth,
            timelineHorizontalOffset: timelineHorizontalOffset,
            timelineMode: keyframeTimelineMode,
            showSelectedKeyframeCurves: showSelectedKeyframeCurves,
            normalizeCurveValues: model.workspaceLayout.normalizeCurveValues,
            curveValueZoom: model.workspaceLayout.curveEditorZoom,
            curveValuePan: model.workspaceLayout.curveEditorPanY,
            snapCurveHandles: model.workspaceLayout.snapCurveHandles,
            curveColor: color(for: property),
            rowHeight: propertyRowHeight,
            dragScale: dragScale,
            displayMode: displayMode,
            resetValue: resetValue,
            inlineAccessory: inlineAccessory,
            expression: model.layerExpression(layerID: layer.id, property: property),
            setExpressionEnabled: { enabled in
                model.setLayerExpressionEnabled(layerID: layer.id, property: property, enabled: enabled)
            },
            setExpressionSource: { source in
                model.setLayerExpressionSource(layerID: layer.id, property: property, source: source)
            },
            beginValueDrag: {
                model.beginCompositionValueDrag()
            },
            endValueDrag: {
                model.endCompositionValueDrag()
            }
        ) {
            model.toggleLayerPropertyKeyframes(layerID: layer.id, property: property)
        } selectKeyframes: { frames, extending in
            model.setBoxSelectedLayerKeyframes(
                layerID: layer.id,
                property: property,
                frames: frames,
                extending: extending
            )
        } beginKeyframeDrag: {
            model.beginSelectedKeyframeDrag()
        } updateKeyframeDrag: { delta in
            model.updateSelectedKeyframeDrag(by: delta)
        } endKeyframeDrag: {
            model.endSelectedKeyframeDrag()
        } setBezierCurve: { frame, curve in
            model.setLayerKeyframeBezierCurve(
                layerID: layer.id,
                property: property,
                frame: frame,
                curve: curve,
                recordHistory: false
            )
        }
    }

    private func color(for property: CompositionLayerKeyframeProperty) -> Color {
        switch property {
        case .positionX: return .red
        case .positionY: return .green
        case .positionZ: return .blue
        case .rotationX: return .orange
        case .rotationY: return .pink
        case .rotationZ: return .purple
        case .scale: return .cyan
        case .scaleX: return .cyan
        case .scaleY: return .mint
        case .scaleZ: return .teal
        case .opacity: return .yellow
        }
    }

    private func doubleBinding(_ property: CompositionLayerKeyframeProperty, lowerLimit: Double? = nil) -> Binding<Double> {
        Binding(
            get: {
                switch property {
                case .positionX: return Double(layer.transform.positionX)
                case .positionY: return Double(layer.transform.positionY)
                case .positionZ: return Double(layer.transform.positionZ)
                case .scale: return Double(layer.transform.scale)
                case .scaleX: return Double(layer.transform.scaleX)
                case .scaleY: return Double(layer.transform.scaleY)
                case .scaleZ: return Double(layer.transform.scaleZ)
                case .opacity: return Double(layer.opacity)
                case .rotationX, .rotationY, .rotationZ: return 0
                }
            },
            set: { newValue in
                let resolved = lowerLimit.map { max($0, newValue) } ?? newValue
                model.setLayerProperty(layerID: layer.id, property: property, value: Float(resolved))
            }
        )
    }

    private func degreeBinding(_ property: CompositionLayerKeyframeProperty) -> Binding<Double> {
        Binding(
            get: {
                let radians: Float
                switch property {
                case .rotationX: radians = layer.transform.rotationX
                case .rotationY: radians = layer.transform.rotationY
                case .rotationZ: radians = layer.transform.rotationZ
                default: radians = 0
                }
                return Double(radians) * 180.0 / .pi
            },
            set: {
                model.setLayerProperty(layerID: layer.id, property: property, value: Float($0 * .pi / 180.0))
            }
        )
    }
}

private struct CompositionModifierSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix: String = ""
    var beginEditing: () -> Void = {}
    var endEditing: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .frame(width: 62, alignment: .leading)
            Slider(
                value: $value,
                in: range,
                onEditingChanged: { isEditing in
                    if isEditing {
                        beginEditing()
                    } else {
                        endEditing()
                    }
                }
            )
            TextField(
                title,
                value: $value,
                formatter: Self.numberFormatter
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 62)
            Text(suffix)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)
        }
        .font(.caption)
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

private struct KeyframeCurveEditorPanel: View {
    @ObservedObject var model: CompositionModel
    var stickyHorizontalOffset: CGFloat = 0

    var body: some View {
        if model.selectedKeyframeCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("曲线")
                        .font(.caption.bold())
                        .frame(width: 36, alignment: .leading)

                    Picker("插值", selection: Binding(
                        get: { model.selectedKeyframeInterpolation() },
                        set: { model.setSelectedKeyframeInterpolation($0) }
                    )) {
                        ForEach(CompositionKeyframeInterpolation.allCases) { interpolation in
                            Text(interpolation.title).tag(interpolation)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)

                    Text("\(model.selectedKeyframeCount) 个")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(model.selectedKeyframeInterpolation().explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(model.selectedKeyframeVelocityText())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Toggle("归一化", isOn: Binding(
                        get: { model.workspaceLayout.normalizeCurveValues },
                        set: { model.workspaceLayout.normalizeCurveValues = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("多属性曲线按各自关键帧范围归一化显示，便于比较不同单位的变化趋势。")

                    Toggle("手柄吸附", isOn: Binding(
                        get: { model.workspaceLayout.snapCurveHandles },
                        set: { model.workspaceLayout.snapCurveHandles = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .help("拖动贝塞尔手柄时吸附到 0.05 的控制点网格。")

                    Button("复制 Easing") {
                        model.copySelectedKeyframeEasing()
                    }
                    .buttonStyle(.borderless)

                    Button("粘贴 Easing") {
                        model.pasteSelectedKeyframeEasing()
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.selectedKeyframeCount == 0)
                }

                if model.selectedKeyframeInterpolation() == .bezier {
                    HStack(alignment: .center, spacing: 10) {
                        BezierCurvePreview(
                            curve: model.selectedKeyframeBezierCurve(),
                            zoom: model.workspaceLayout.curveEditorZoom,
                            panX: model.workspaceLayout.curveEditorPanX,
                            panY: model.workspaceLayout.curveEditorPanY,
                            snapHandles: model.workspaceLayout.snapCurveHandles,
                            onEditingBegan: model.beginCompositionValueDrag,
                            onEditingEnded: model.endCompositionValueDrag,
                            onChange: model.setSelectedKeyframeBezierCurve
                        )
                            .frame(width: 136, height: 76)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                DraggableNumberField(
                                    title: "P1 X",
                                    value: curveBinding(\.controlPoint1X),
                                    width: 58,
                                    labelWidth: 34,
                                    lowerLimit: 0,
                                    dragScale: 0.004,
                                    onDragBegan: model.beginCompositionValueDrag,
                                    onDragEnded: model.endCompositionValueDrag
                                )
                                DraggableNumberField(
                                    title: "P1 Y",
                                    value: curveBinding(\.controlPoint1Y),
                                    width: 58,
                                    labelWidth: 34,
                                    dragScale: 0.004,
                                    onDragBegan: model.beginCompositionValueDrag,
                                    onDragEnded: model.endCompositionValueDrag
                                )
                            }
                            HStack(spacing: 8) {
                                DraggableNumberField(
                                    title: "P2 X",
                                    value: curveBinding(\.controlPoint2X),
                                    width: 58,
                                    labelWidth: 34,
                                    lowerLimit: 0,
                                    dragScale: 0.004,
                                    onDragBegan: model.beginCompositionValueDrag,
                                    onDragEnded: model.endCompositionValueDrag
                                )
                                DraggableNumberField(
                                    title: "P2 Y",
                                    value: curveBinding(\.controlPoint2Y),
                                    width: 58,
                                    labelWidth: 34,
                                    dragScale: 0.004,
                                    onDragBegan: model.beginCompositionValueDrag,
                                    onDragEnded: model.endCompositionValueDrag
                                )
                            }
                            HStack(spacing: 8) {
                                Button("曲线复位") {
                                    model.workspaceLayout.curveEditorZoom = 1
                                    model.workspaceLayout.curveEditorPanX = 0
                                    model.workspaceLayout.curveEditorPanY = 0
                                }
                                .buttonStyle(.borderless)
                            }
                            .font(.caption2)

                            HStack(spacing: 8) {
                                Text("缩放")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Slider(value: Binding(
                                    get: { model.workspaceLayout.curveEditorZoom },
                                    set: { model.workspaceLayout.curveEditorZoom = min(6, max(0.5, $0)) }
                                ), in: 0.5...6)
                                .frame(width: 116)
                                Text("\(Int(model.workspaceLayout.curveEditorZoom * 100))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }

                            HStack(spacing: 8) {
                                Text("平移")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Slider(value: Binding(
                                    get: { model.workspaceLayout.curveEditorPanX },
                                    set: { model.workspaceLayout.curveEditorPanX = min(1, max(-1, $0)) }
                                ), in: -1...1)
                                .frame(width: 86)
                                Slider(value: Binding(
                                    get: { model.workspaceLayout.curveEditorPanY },
                                    set: { model.workspaceLayout.curveEditorPanY = min(1, max(-1, $0)) }
                                ), in: -1...1)
                                .frame(width: 86)
                            }

                            Text("拖动橙色点或曲线两端附近调整；开启吸附后手柄会落在控制点网格上。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .offset(x: stickyHorizontalOffset)
            .zIndex(40)
        }
    }

    private func curveBinding(_ keyPath: WritableKeyPath<CompositionBezierCurve, Float>) -> Binding<Double> {
        Binding(
            get: {
                Double(model.selectedKeyframeBezierCurve()[keyPath: keyPath])
            },
            set: { newValue in
                var curve = model.selectedKeyframeBezierCurve()
                curve[keyPath: keyPath] = Float(newValue)
                model.setSelectedKeyframeBezierCurve(curve)
            }
        )
    }
}

private struct BezierCurvePreview: View {
    let curve: CompositionBezierCurve
    var zoom: Double = 1
    var panX: Double = 0
    var panY: Double = 0
    var snapHandles: Bool = false
    var onEditingBegan: (() -> Void)?
    var onEditingEnded: (() -> Void)?
    let onChange: (CompositionBezierCurve) -> Void

    private enum ControlHandle {
        case point1
        case point2
    }

    @State private var activeHandle: ControlHandle?

    var body: some View {
        GeometryReader { proxy in
            Canvas(rendersAsynchronously: false) { context, size in
                let outer = CGRect(origin: .zero, size: size)
                let rect = previewRect(in: size)

                context.fill(
                    Path(roundedRect: outer, cornerRadius: 6),
                    with: .color(Color(nsColor: .textBackgroundColor).opacity(0.86))
                )

                var box = Path()
                box.addRect(rect)
                context.stroke(box, with: .color(.secondary.opacity(0.45)), lineWidth: 1)

                var diagonal = Path()
                diagonal.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                diagonal.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                context.stroke(diagonal, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                let control1 = point(x: curve.controlPoint1X, y: curve.controlPoint1Y, in: rect)
                let control2 = point(x: curve.controlPoint2X, y: curve.controlPoint2Y, in: rect)
                let start = CGPoint(x: rect.minX, y: rect.maxY)
                let end = CGPoint(x: rect.maxX, y: rect.minY)

                var handles = Path()
                handles.move(to: start)
                handles.addLine(to: control1)
                handles.move(to: end)
                handles.addLine(to: control2)
                context.stroke(handles, with: .color(.orange.opacity(0.65)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                drawControlPoint(at: control1, active: activeHandle == .point1, context: &context)
                drawControlPoint(at: control2, active: activeHandle == .point2, context: &context)

                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: control1, control2: control2)
                context.stroke(path, with: .color(.cyan), lineWidth: 2.4)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let rect = previewRect(in: proxy.size)
                        let handle = activeHandle ?? nearestHandle(to: value.startLocation, in: rect)
                        if activeHandle == nil {
                            endCompositionTextEditing()
                            onEditingBegan?()
                            activeHandle = handle
                        }
                        update(handle: handle, location: value.location, in: rect)
                    }
                    .onEnded { _ in
                        activeHandle = nil
                        onEditingEnded?()
                    }
            )
        }
    }

    private func previewRect(in size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
    }

    private func drawControlPoint(
        at point: CGPoint,
        active: Bool,
        context: inout GraphicsContext
    ) {
        let radius: CGFloat = active ? 5.5 : 4.2
        let rect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.fill(Path(ellipseIn: rect), with: .color(active ? .white : .orange))
        context.stroke(Path(ellipseIn: rect), with: .color(.orange), lineWidth: active ? 2 : 1)
    }

    private func point(x: Float, y: Float, in rect: CGRect) -> CGPoint {
        let normalizedX = (CGFloat(x) - 0.5) * resolvedZoom + 0.5 + CGFloat(panX)
        let normalizedY = (CGFloat(y) - 0.5) * resolvedZoom + 0.5 + CGFloat(panY)
        return CGPoint(
            x: rect.minX + normalizedX * rect.width,
            y: rect.maxY - normalizedY * rect.height
        )
    }

    private func nearestHandle(to location: CGPoint, in rect: CGRect) -> ControlHandle {
        let control1 = point(x: curve.controlPoint1X, y: curve.controlPoint1Y, in: rect)
        let control2 = point(x: curve.controlPoint2X, y: curve.controlPoint2Y, in: rect)
        let start = CGPoint(x: rect.minX, y: rect.maxY)
        let end = CGPoint(x: rect.maxX, y: rect.minY)
        let candidates: [(ControlHandle, CGFloat)] = [
            (.point1, distance(location, control1)),
            (.point2, distance(location, control2)),
            (.point1, distance(location, start)),
            (.point2, distance(location, end))
        ]
        return candidates.min { $0.1 < $1.1 }?.0 ?? .point1
    }

    private func update(handle: ControlHandle, location: CGPoint, in rect: CGRect) {
        var next = curve
        let rawX = ((location.x - rect.minX) / max(1, rect.width) - CGFloat(panX) - 0.5) / resolvedZoom + 0.5
        let rawY = ((rect.maxY - location.y) / max(1, rect.height) - CGFloat(panY) - 0.5) / resolvedZoom + 0.5
        let x = snapped(Float(rawX), step: 0.05)
        let y = snapped(Float(rawY), step: 0.05)

        switch handle {
        case .point1:
            next.controlPoint1X = max(0, min(1, x))
            next.controlPoint1Y = max(-3, min(3, y))
        case .point2:
            next.controlPoint2X = max(0, min(1, x))
            next.controlPoint2Y = max(-3, min(3, y))
        }
        onChange(next)
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private var resolvedZoom: CGFloat {
        CGFloat(min(6, max(0.5, zoom)))
    }

    private func snapped(_ value: Float, step: Float) -> Float {
        guard snapHandles, step > 0 else { return value }
        return (value / step).rounded() * step
    }
}

private struct PropertyKeyframeMarker: Identifiable, Hashable {
    var frame: Int
    var value: Float
    var interpolation: CompositionKeyframeInterpolation
    var bezierCurve: CompositionBezierCurve

    var id: Int { frame }
}

private struct KeyframeMarkerShape: Shape {
    let interpolation: CompositionKeyframeInterpolation

    func path(in rect: CGRect) -> Path {
        switch interpolation {
        case .linear:
            return diamondPath(in: rect)
        case .easeInOut:
            return funnelPath(in: rect)
        case .hold:
            return squarePath(in: rect)
        case .bezier:
            return circlePath(in: rect)
        }
    }

    private func diamondPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    private func funnelPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.15, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.15, y: rect.midY))
        path.closeSubpath()
        return path
    }

    private func squarePath(in rect: CGRect) -> Path {
        Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 1.5)
    }

    private func circlePath(in rect: CGRect) -> Path {
        Path(ellipseIn: rect)
    }
}

private struct KeyframeMarkerView: View {
    let marker: PropertyKeyframeMarker
    let isSelected: Bool

    var body: some View {
        KeyframeMarkerShape(interpolation: marker.interpolation)
            .fill(fillColor)
            .overlay {
                KeyframeMarkerShape(interpolation: marker.interpolation)
                    .stroke(Color.black.opacity(0.45), lineWidth: 0.75)
            }
            .frame(width: marker.interpolation == .easeInOut ? 11 : 9, height: 9)
            .shadow(color: .black.opacity(0.3), radius: 1)
            .help(marker.interpolation.title)
    }

    private var fillColor: Color {
        if isSelected {
            return .accentColor
        }
        switch marker.interpolation {
        case .linear:
            return .yellow
        case .easeInOut:
            return .orange
        case .hold:
            return .mint
        case .bezier:
            return .cyan
        }
    }
}

private struct PropertyCurveTrack: View {
    let keyframes: [PropertyKeyframeMarker]
    let selectedFrames: Set<Int>
    let frameCount: Int
    let width: CGFloat
    let mode: CompositionKeyframeTimelineMode
    let showSelectedOnly: Bool
    let normalizeCurveValues: Bool
    let curveValueZoom: Double
    let curveValuePan: Double
    let snapCurveHandles: Bool
    let color: Color
    let selectKeyframes: (Set<Int>, Bool) -> Void
    let setBezierCurve: (Int, CompositionBezierCurve) -> Void

    private struct ActiveHandle: Equatable {
        let frame: Int
        let pointIndex: Int
    }

    @State private var activeHandle: ActiveHandle?

    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height)
            let sorted = keyframes.sorted { $0.frame < $1.frame }
            let segments = curveSegments(in: sorted)
            let range = valueRange(for: segments)

            ZStack(alignment: .topLeading) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    curvePath(for: segment, valueRange: range, height: height)
                        .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                        .shadow(color: color.opacity(0.35), radius: 2)
                }

                if mode == .curves {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if let handles = bezierHandles(for: segment, valueRange: range, height: height) {
                            Path { path in
                                path.move(to: handles.start)
                                path.addLine(to: handles.point1)
                                path.move(to: handles.end)
                                path.addLine(to: handles.point2)
                            }
                            .stroke(color.opacity(0.38), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                            Circle()
                                .fill(Color.orange)
                                .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 0.75))
                                .frame(width: 9, height: 9)
                                .position(handles.point1)

                            Circle()
                                .fill(Color.orange)
                                .overlay(Circle().stroke(Color.black.opacity(0.45), lineWidth: 0.75))
                                .frame(width: 9, height: 9)
                                .position(handles.point2)
                        }
                    }
                }

                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    curveEndpointDots(for: segment, valueRange: range, height: height)
                        .fill(color)
                }

                if segments.isEmpty && !sorted.isEmpty && showSelectedOnly {
                    Text("选择关键帧查看曲线")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .frame(width: width, height: height, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .gesture(curveDragGesture(segments: segments, valueRange: range, height: height))
        }
        .allowsHitTesting(mode == .curves)
    }

    private func curveSegments(in sorted: [PropertyKeyframeMarker]) -> [(lower: PropertyKeyframeMarker, upper: PropertyKeyframeMarker?)] {
        var segments: [(lower: PropertyKeyframeMarker, upper: PropertyKeyframeMarker?)] = []
        if !showSelectedOnly {
            for marker in sorted {
                let upper = sorted.first { $0.frame > marker.frame }
                segments.append((lower: marker, upper: upper))
            }
            return segments
        }
        for marker in sorted where selectedFrames.contains(marker.frame) {
            let upper = sorted.first { $0.frame > marker.frame }
            segments.append((lower: marker, upper: upper))
        }
        return segments
    }

    private func valueRange(
        for segments: [(lower: PropertyKeyframeMarker, upper: PropertyKeyframeMarker?)]
    ) -> ClosedRange<Float> {
        let values = segments.flatMap { segment -> [Float] in
            if let upper = segment.upper {
                return [segment.lower.value, upper.value]
            }
            return [segment.lower.value]
        }
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 0...1
        }
        guard normalizeCurveValues else {
            let maxAbs = max(Float(1), abs(minValue), abs(maxValue))
            return (-maxAbs)...maxAbs
        }
        if abs(maxValue - minValue) < 0.00001 {
            let padding = max(0.5, abs(maxValue) * 0.1)
            return (minValue - Float(padding))...(maxValue + Float(padding))
        }
        let padding = (maxValue - minValue) * 0.18
        return (minValue - padding)...(maxValue + padding)
    }

    private func curvePath(
        for segment: (lower: PropertyKeyframeMarker, upper: PropertyKeyframeMarker?),
        valueRange: ClosedRange<Float>,
        height: CGFloat
    ) -> Path {
        guard let upper = segment.upper else {
            let point = point(frame: segment.lower.frame, value: segment.lower.value, range: valueRange, height: height)
            var path = Path()
            path.move(to: CGPoint(x: point.x - 8, y: point.y))
            path.addLine(to: CGPoint(x: point.x + 8, y: point.y))
            return path
        }

        if segment.lower.interpolation == .hold {
            let start = point(frame: segment.lower.frame, value: segment.lower.value, range: valueRange, height: height)
            let beforeJump = point(frame: upper.frame, value: segment.lower.value, range: valueRange, height: height)
            let end = point(frame: upper.frame, value: upper.value, range: valueRange, height: height)
            var path = Path()
            path.move(to: start)
            path.addLine(to: beforeJump)
            path.addLine(to: end)
            return path
        }

        var path = Path()
        for step in 0...80 {
            let progress = Float(step) / 80
            let amount = interpolatedAmount(progress, interpolation: segment.lower.interpolation, curve: segment.lower.bezierCurve)
            let frame = Float(segment.lower.frame) + Float(upper.frame - segment.lower.frame) * progress
            let value = segment.lower.value + (upper.value - segment.lower.value) * amount
            let current = point(frame: frame, value: value, range: valueRange, height: height)
            if step == 0 {
                path.move(to: current)
            } else {
                path.addLine(to: current)
            }
        }
        return path
    }

    private func bezierHandles(
        for segment: (lower: PropertyKeyframeMarker, upper: PropertyKeyframeMarker?),
        valueRange: ClosedRange<Float>,
        height: CGFloat
    ) -> (start: CGPoint, point1: CGPoint, point2: CGPoint, end: CGPoint)? {
        guard let upper = segment.upper else { return nil }
        let curve = effectiveBezierCurve(for: segment.lower)
        let start = point(frame: segment.lower.frame, value: segment.lower.value, range: valueRange, height: height)
        let end = point(frame: upper.frame, value: upper.value, range: valueRange, height: height)
        let frameSpan = Float(upper.frame - segment.lower.frame)
        let valueSpan = upper.value - segment.lower.value
        let point1 = point(
            frame: Float(segment.lower.frame) + frameSpan * curve.controlPoint1X,
            value: segment.lower.value + valueSpan * curve.controlPoint1Y,
            range: valueRange,
            height: height
        )
        let point2 = point(
            frame: Float(segment.lower.frame) + frameSpan * curve.controlPoint2X,
            value: segment.lower.value + valueSpan * curve.controlPoint2Y,
            range: valueRange,
            height: height
        )
        return (start, point1, point2, end)
    }

    private func curveEndpointDots(
        for segment: (lower: PropertyKeyframeMarker, upper: PropertyKeyframeMarker?),
        valueRange: ClosedRange<Float>,
        height: CGFloat
    ) -> Path {
        var path = Path()
        let start = point(frame: segment.lower.frame, value: segment.lower.value, range: valueRange, height: height)
        path.addEllipse(in: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6))
        if let upper = segment.upper {
            let end = point(frame: upper.frame, value: upper.value, range: valueRange, height: height)
            path.addEllipse(in: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6))
        }
        return path
    }

    private func point(frame: Int, value: Float, range: ClosedRange<Float>, height: CGFloat) -> CGPoint {
        point(frame: Float(frame), value: value, range: range, height: height)
    }

    private func point(frame: Float, value: Float, range: ClosedRange<Float>, height: CGFloat) -> CGPoint {
        let frameProgress = CGFloat(max(0, min(Float(frameCount), frame)) / Float(max(1, frameCount)))
        let valueSpan = max(0.00001, range.upperBound - range.lowerBound)
        let rawValueProgress = CGFloat((value - range.lowerBound) / valueSpan)
        let valueProgress = (rawValueProgress - 0.5) * resolvedCurveZoom + 0.5 + CGFloat(curveValuePan)
        return CGPoint(
            x: frameProgress * width,
            y: height - valueProgress * height
        )
    }

    private func interpolatedAmount(
        _ progress: Float,
        interpolation: CompositionKeyframeInterpolation,
        curve: CompositionBezierCurve
    ) -> Float {
        switch interpolation {
        case .linear:
            return progress
        case .easeInOut:
            return progress * progress * (3 - 2 * progress)
        case .hold:
            return 0
        case .bezier:
            return cubicBezierY(forX: progress, curve: curve)
        }
    }

    private func cubicBezierY(forX x: Float, curve: CompositionBezierCurve) -> Float {
        var lower: Float = 0
        var upper: Float = 1
        var t = x
        for _ in 0..<12 {
            let currentX = cubicBezierValue(t, p1: curve.controlPoint1X, p2: curve.controlPoint2X)
            if abs(currentX - x) < 0.0001 { break }
            if currentX > x {
                upper = t
            } else {
                lower = t
            }
            t = (lower + upper) * 0.5
        }
        return cubicBezierValue(t, p1: curve.controlPoint1Y, p2: curve.controlPoint2Y)
    }

    private func cubicBezierValue(_ t: Float, p1: Float, p2: Float) -> Float {
        let oneMinusT = 1 - t
        return 3 * oneMinusT * oneMinusT * t * p1
            + 3 * oneMinusT * t * t * p2
            + t * t * t
    }

    private func effectiveBezierCurve(for marker: PropertyKeyframeMarker) -> CompositionBezierCurve {
        switch marker.interpolation {
        case .linear:
            return CompositionBezierCurve(
                controlPoint1X: 1.0 / 3.0,
                controlPoint1Y: 1.0 / 3.0,
                controlPoint2X: 2.0 / 3.0,
                controlPoint2Y: 2.0 / 3.0
            )
        case .easeInOut:
            return CompositionBezierCurve.default
        case .hold:
            return CompositionBezierCurve(
                controlPoint1X: 0,
                controlPoint1Y: 0,
                controlPoint2X: 1,
                controlPoint2Y: 0
            )
        case .bezier:
            return marker.bezierCurve
        }
    }

    private func curveDragGesture(
        segments: [(lower: PropertyKeyframeMarker, upper: PropertyKeyframeMarker?)],
        valueRange: ClosedRange<Float>,
        height: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let handle: ActiveHandle
                if let activeHandle {
                    handle = activeHandle
                } else {
                    guard let nearest = nearestHandle(
                        at: value.startLocation,
                        segments: segments,
                        valueRange: valueRange,
                        height: height
                    ) else {
                        return
                    }
                    selectKeyframes([nearest.frame], false)
                    activeHandle = nearest
                    handle = nearest
                }
                guard let segment = segments.first(where: {
                    $0.lower.frame == handle.frame && $0.upper != nil
                }) else {
                    return
                }
                let curve = curveForDragLocation(
                    value.location,
                    segment: segment,
                    handle: handle,
                    valueRange: valueRange,
                    height: height
                )
                setBezierCurve(handle.frame, curve)
            }
            .onEnded { _ in
                activeHandle = nil
            }
    }

    private func nearestHandle(
        at location: CGPoint,
        segments: [(lower: PropertyKeyframeMarker, upper: PropertyKeyframeMarker?)],
        valueRange: ClosedRange<Float>,
        height: CGFloat
    ) -> ActiveHandle? {
        var nearest: (handle: ActiveHandle, distance: CGFloat)?
        for segment in segments {
            guard let handles = bezierHandles(for: segment, valueRange: valueRange, height: height) else { continue }
            let candidates = [
                (ActiveHandle(frame: segment.lower.frame, pointIndex: 1), handles.point1),
                (ActiveHandle(frame: segment.lower.frame, pointIndex: 2), handles.point2)
            ]
            for candidate in candidates {
                let distance = hypot(candidate.1.x - location.x, candidate.1.y - location.y)
                if nearest == nil || distance < nearest!.distance {
                    nearest = (candidate.0, distance)
                }
            }
        }
        return nearest?.handle
    }

    private func curveForDragLocation(
        _ location: CGPoint,
        segment: (lower: PropertyKeyframeMarker, upper: PropertyKeyframeMarker?),
        handle: ActiveHandle,
        valueRange: ClosedRange<Float>,
        height: CGFloat
    ) -> CompositionBezierCurve {
        guard let upper = segment.upper else {
            return effectiveBezierCurve(for: segment.lower)
        }
        let startX = point(frame: segment.lower.frame, value: segment.lower.value, range: valueRange, height: height).x
        let endX = point(frame: upper.frame, value: upper.value, range: valueRange, height: height).x
        let xSpan = max(0.00001, endX - startX)
        let controlX = Float(max(0, min(1, (location.x - startX) / xSpan)))

        let valueSpan = max(0.00001, valueRange.upperBound - valueRange.lowerBound)
        let screenProgress = (height - location.y) / max(1, height)
        let rawProgress = (screenProgress - CGFloat(curveValuePan) - 0.5) / resolvedCurveZoom + 0.5
        let value = valueRange.lowerBound + Float(rawProgress) * valueSpan
        let keyframeDelta = upper.value - segment.lower.value
        let controlY: Float
        if abs(keyframeDelta) < 0.00001 {
            controlY = 0.5 + (value - segment.lower.value) / valueSpan
        } else {
            controlY = (value - segment.lower.value) / keyframeDelta
        }

        var curve = effectiveBezierCurve(for: segment.lower)
        if handle.pointIndex == 1 {
            curve.controlPoint1X = snapped(max(0, min(1, controlX)))
            curve.controlPoint1Y = snapped(max(-3, min(3, controlY)))
        } else {
            curve.controlPoint2X = snapped(max(0, min(1, controlX)))
            curve.controlPoint2Y = snapped(max(-3, min(3, controlY)))
        }
        return curve
    }

    private var resolvedCurveZoom: CGFloat {
        CGFloat(min(6, max(0.5, curveValueZoom)))
    }

    private func snapped(_ value: Float) -> Float {
        guard snapCurveHandles else { return value }
        let step: Float = 0.05
        return (value / step).rounded() * step
    }
}

private struct KeyframeSelectionGroup<Content: View>: View {
    let propertyPanelWidth: CGFloat
    let timelineWidth: CGFloat
    let height: CGFloat
    let allowsSelection: Bool
    let isMarkerAt: (CGPoint) -> Bool
    let onSelect: (CGRect, Bool) -> Void
    @ViewBuilder var content: () -> Content

    @State private var startPoint: CGPoint?
    @State private var currentPoint: CGPoint?
    @State private var ignoringDrag = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            content()

            if let rect = selectionRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(
                        Rectangle()
                            .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: propertyPanelWidth + rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: propertyPanelWidth + timelineWidth, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .simultaneousGesture(selectionGesture)
    }

    private var selectionRect: CGRect? {
        guard allowsSelection else { return nil }
        guard let startPoint, let currentPoint else { return nil }
        return CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(startPoint.x - currentPoint.x),
            height: abs(startPoint.y - currentPoint.y)
        )
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard allowsSelection else { return }
                guard !ignoringDrag else { return }
                if startPoint == nil {
                    let timelineStart = timelinePoint(value.startLocation)
                    guard timelineStart.x >= 0, timelineStart.x <= timelineWidth else {
                        ignoringDrag = true
                        return
                    }
                    guard !isMarkerAt(timelineStart) else {
                        ignoringDrag = true
                        return
                    }
                    startPoint = timelineStart
                }
                currentPoint = timelinePoint(value.location)
            }
            .onEnded { _ in
                if allowsSelection, !ignoringDrag, let selectionRect {
                    onSelect(selectionRect, isShiftDown)
                }
                startPoint = nil
                currentPoint = nil
                ignoringDrag = false
            }
    }

    private func timelinePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - propertyPanelWidth, y: point.y)
    }
}

private struct KeyframedPropertyRow: View {
    let title: String
    @Binding var value: Double
    let isKeyframedAtCurrentFrame: Bool
    let keyframes: [PropertyKeyframeMarker]
    let isKeyframeSelected: (Int) -> Bool
    let currentFrame: Int
    let frameCount: Int
    let timelineWidth: CGFloat
    let propertyPanelWidth: CGFloat
    let timelineHorizontalOffset: CGFloat
    let timelineMode: CompositionKeyframeTimelineMode
    let showSelectedKeyframeCurves: Bool
    let normalizeCurveValues: Bool
    let curveValueZoom: Double
    let curveValuePan: Double
    let snapCurveHandles: Bool
    let curveColor: Color
    let rowHeight: CGFloat
    var dragScale: Double = 0.01
    var suffix: String = ""
    var displayMode: DraggableNumberField.DisplayMode = .number
    var resetValue: Double?
    var disabled: Bool = false
    var showsExpressionButton: Bool = true
    var inlineAccessory: AnyView? = nil
    var expression: CompositionPropertyExpression
    var setExpressionEnabled: (Bool) -> Void
    var setExpressionSource: (String) -> Void
    var beginValueDrag: (() -> Void)?
    var endValueDrag: (() -> Void)?
    let setKeyframe: () -> Void
    let selectKeyframes: (Set<Int>, Bool) -> Void
    let beginKeyframeDrag: () -> Void
    let updateKeyframeDrag: (Int) -> Void
    let endKeyframeDrag: () -> Void
    let setBezierCurve: (Int, CompositionBezierCurve) -> Void

    var body: some View {
        let hasPropertyKeyframes = !keyframes.isEmpty
        ZStack(alignment: .topLeading) {
            PropertyKeyframeTrack(
                keyframes: keyframes,
                isKeyframeSelected: isKeyframeSelected,
                currentFrame: currentFrame,
                frameCount: frameCount,
                width: timelineWidth,
                mode: timelineMode,
                showSelectedKeyframeCurves: showSelectedKeyframeCurves,
                normalizeCurveValues: normalizeCurveValues,
                curveValueZoom: curveValueZoom,
                curveValuePan: curveValuePan,
                snapCurveHandles: snapCurveHandles,
                curveColor: curveColor,
                selectKeyframes: selectKeyframes,
                beginKeyframeDrag: beginKeyframeDrag,
                updateKeyframeDrag: updateKeyframeDrag,
                endKeyframeDrag: endKeyframeDrag,
                setBezierCurve: setBezierCurve
            )
            .frame(width: timelineWidth, height: rowHeight)
            .offset(x: propertyPanelWidth)

            HStack(spacing: 6) {
                Button {
                    setKeyframe()
                } label: {
                    Image(systemName: isKeyframedAtCurrentFrame ? "diamond.fill" : "diamond")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isKeyframedAtCurrentFrame || hasPropertyKeyframes ? .yellow : .secondary)
                        .frame(width: 16, height: 20)
                }
                .buttonStyle(.borderless)
                .help(hasPropertyKeyframes ? "清空此属性所有关键帧，并保留当前时间码对应状态" : "在当前时间码记录此属性关键帧")

                if showsExpressionButton {
                    ExpressionPopoverButton(
                        expression: expression,
                        setEnabled: setExpressionEnabled,
                        setSource: setExpressionSource
                    )
                } else {
                    Color.clear
                        .frame(width: 16, height: 20)
                }

                if let inlineAccessory {
                    inlineAccessory
                }

                DraggableNumberField(
                    title: title,
                    value: $value,
                    width: displayMode == .turnsDegrees ? 96 : 78,
                    labelWidth: 74,
                    dragScale: dragScale,
                    suffix: suffix,
                    displayMode: displayMode,
                    resetValue: resetValue,
                    onDragBegan: beginValueDrag,
                    onDragEnded: endValueDrag
                )
                .disabled(disabled)
            }
            .frame(width: propertyPanelWidth, height: rowHeight, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor)
            )
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1)
            }
            .offset(x: timelineHorizontalOffset)
            .zIndex(5)
        }
        .frame(width: propertyPanelWidth + timelineWidth, height: rowHeight, alignment: .topLeading)
    }
}

private struct ExpressionPopoverButton: View {
    let expression: CompositionPropertyExpression
    let setEnabled: (Bool) -> Void
    let setSource: (String) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Text("ƒ")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(expression.isActive ? Color.accentColor : Color.secondary)
                .frame(width: 16, height: 20)
        }
        .buttonStyle(.borderless)
        .help(expression.isActive ? "表达式已启用" : "添加表达式")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用表达式", isOn: Binding(
                    get: { expression.isEnabled },
                    set: setEnabled
                ))

                TextField("sin(frame / 20) * 100", text: Binding(
                    get: { expression.source },
                    set: setSource
                ), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .frame(width: 280)

                VStack(alignment: .leading, spacing: 4) {
                    Text("可用：frame、time、fps、value")
                    Text("函数：sin/cos/noise/clamp/lerp/min/max")
                    Text("绑定：layer(\"图层名\", \"positionX\")")
                    Text("摄像机：camera(\"yaw\") 或 camera(\"摄像机 1\", \"focalLength\")")
                    Text("音频占位：audio(time) 目前返回 0")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }
}

private struct PropertyKeyframeTrack: View {
    let keyframes: [PropertyKeyframeMarker]
    let isKeyframeSelected: (Int) -> Bool
    let currentFrame: Int
    let frameCount: Int
    let width: CGFloat
    let mode: CompositionKeyframeTimelineMode
    let showSelectedKeyframeCurves: Bool
    let normalizeCurveValues: Bool
    let curveValueZoom: Double
    let curveValuePan: Double
    let snapCurveHandles: Bool
    let curveColor: Color
    let selectKeyframes: (Set<Int>, Bool) -> Void
    let beginKeyframeDrag: () -> Void
    let updateKeyframeDrag: (Int) -> Void
    let endKeyframeDrag: () -> Void
    let setBezierCurve: (Int, CompositionBezierCurve) -> Void

    @State private var isDraggingKeyframes = false
    @State private var activeInteractionFrame: Int?

    var body: some View {
        let total = max(1, frameCount)
        let uniqueMarkers = uniqueKeyframeMarkers()
        let uniqueFrames = uniqueMarkers.map(\.frame)
        let selectedFrames = Set(uniqueFrames.filter { isKeyframeSelected($0) })

        ZStack(alignment: .leading) {
            Rectangle()
                .fill(mode == .curves ? curveColor.opacity(0.06) : Color.secondary.opacity(0.055))

            Path { path in
                path.move(to: CGPoint(x: 0, y: 15))
                path.addLine(to: CGPoint(x: width, y: 15))
            }
            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)

            if mode == .curves || showSelectedKeyframeCurves {
                PropertyCurveTrack(
                    keyframes: uniqueMarkers,
                    selectedFrames: selectedFrames,
                    frameCount: total,
                    width: width,
                    mode: mode,
                    showSelectedOnly: mode != .curves,
                    normalizeCurveValues: normalizeCurveValues,
                    curveValueZoom: curveValueZoom,
                    curveValuePan: curveValuePan,
                    snapCurveHandles: snapCurveHandles,
                    color: curveColor,
                    selectKeyframes: selectKeyframes,
                    setBezierCurve: setBezierCurve
                )
            }

            ForEach(uniqueMarkers) { marker in
                KeyframeMarkerView(marker: marker, isSelected: isKeyframeSelected(marker.frame))
                    .contentShape(Rectangle())
                    .position(x: xPosition(for: marker.frame), y: 15)
                    .allowsHitTesting(mode == .keyframes)
            }

        }
        .contentShape(Rectangle())
        .simultaneousGesture(keyframeInteractionGesture(availableFrames: uniqueFrames))
    }

    private func uniqueKeyframeMarkers() -> [PropertyKeyframeMarker] {
        var seen: Set<Int> = []
        var result: [PropertyKeyframeMarker] = []
        for marker in keyframes.sorted(by: { $0.frame < $1.frame }) where !seen.contains(marker.frame) {
            seen.insert(marker.frame)
            result.append(marker)
        }
        return result
    }

    private func keyframeInteractionGesture(availableFrames: [Int]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard mode == .keyframes else {
                    resetKeyframeInteraction()
                    return
                }
                if activeInteractionFrame == nil {
                    activeInteractionFrame = nearestKeyframeFrame(at: value.startLocation.x, in: availableFrames)
                }
                guard let frame = activeInteractionFrame else { return }
                guard abs(value.translation.width) >= 2 else { return }
                let delta = frames(for: value.translation.width)

                if !isDraggingKeyframes {
                    guard delta != 0 else { return }
                    if !isKeyframeSelected(frame) {
                        selectKeyframes([frame], isShiftDown)
                    }
                    beginKeyframeDrag()
                    isDraggingKeyframes = true
                }
                updateKeyframeDrag(delta)
            }
            .onEnded { _ in
                guard mode == .keyframes else {
                    resetKeyframeInteraction()
                    return
                }
                if isDraggingKeyframes {
                    endKeyframeDrag()
                } else if let frame = activeInteractionFrame {
                    selectKeyframes([frame], isShiftDown)
                }
                resetKeyframeInteraction()
            }
    }

    private func resetKeyframeInteraction() {
        isDraggingKeyframes = false
        activeInteractionFrame = nil
    }

    private func frames(for translation: CGFloat) -> Int {
        let total = max(1, frameCount)
        return Int((translation / max(1, width) * CGFloat(total)).rounded())
    }

    private func nearestKeyframeFrame(at x: CGFloat, in frames: [Int]) -> Int? {
        let tolerance: CGFloat = 10
        guard let nearest = frames.min(by: {
            abs(xPosition(for: $0) - x) < abs(xPosition(for: $1) - x)
        }) else {
            return nil
        }
        return abs(xPosition(for: nearest) - x) <= tolerance ? nearest : nil
    }

    private func xPosition(for frame: Int) -> CGFloat {
        let total = max(1, frameCount)
        let rawX = CGFloat(max(0, min(total, frame))) / CGFloat(total) * width
        let edgeInset: CGFloat = 9
        guard width > edgeInset * 2 else { return rawX }
        return max(edgeInset, min(width - edgeInset, rawX))
    }
}

private struct DraggableIntField: View {
    let title: String
    @Binding var value: Int
    var lowerLimit: Int?
    var dragScale: Double = 0.2
    var resetValue: Int?

    @State private var dragStartValue: Int?

    var body: some View {
        HStack {
            Text(title)
                .font(.footnote)
                .frame(width: 38, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { gesture in
                            if dragStartValue == nil {
                                endCompositionTextEditing()
                                dragStartValue = value
                            }
                            let start = Double(dragStartValue ?? value)
                            setValue(Int((start + gesture.translation.width * dragScale).rounded()))
                        }
                        .onEnded { _ in
                            dragStartValue = nil
                        }
                )

            TextField("", value: Binding(
                get: { value },
                set: { setValue($0) }
            ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)

            if let resetValue {
                Button {
                    setValue(resetValue)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("复位")
            }
        }
    }

    private func setValue(_ newValue: Int) {
        let resolvedValue = lowerLimit.map { max($0, newValue) } ?? newValue
        guard resolvedValue != value else { return }
        value = resolvedValue
    }
}

private struct DraggableNumberField: View {
    enum DisplayMode {
        case number
        case turnsDegrees
    }

    let title: String
    @Binding var value: Double
    var width: CGFloat = 92
    var labelWidth: CGFloat = 56
    var lowerLimit: Double?
    var dragScale: Double = 0.01
    var suffix: String = ""
    var displayMode: DisplayMode = .number
    var resetValue: Double?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    @State private var dragStartValue: Double?
    @State private var draftText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.footnote)
                .frame(width: labelWidth, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { gesture in
                            if dragStartValue == nil {
                                endCompositionTextEditing()
                                dragStartValue = value
                                onDragBegan?()
                            }
                            let start = dragStartValue ?? value
                            setValue(start + gesture.translation.width * dragScale)
                        }
                        .onEnded { _ in
                            dragStartValue = nil
                            onDragEnded?()
                        }
                )

            textField

            if !suffix.isEmpty && displayMode == .number {
                Text(suffix)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
            }

            if let resetValue {
                Button {
                    setValue(resetValue)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("复位")
            }
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
                set: { setValue($0) }
            ), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        case .turnsDegrees:
            TextField("", text: $draftText)
                .textFieldStyle(.roundedBorder)
                .frame(width: max(width, 96))
                .focused($isFocused)
                .onSubmit {
                    commitDraft()
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        commitDraft()
                    }
                }
        }
    }

    private func setValue(_ newValue: Double) {
        let resolvedValue = lowerLimit.map { max($0, newValue) } ?? newValue
        guard abs(resolvedValue - value) > 0.000001 else { return }
        value = resolvedValue
    }

    private func commitDraft() {
        guard displayMode == .turnsDegrees else { return }
        if let parsed = parseTurnsDegrees(draftText) {
            setValue(parsed)
            draftText = formattedValue(value)
        } else {
            draftText = formattedValue(value)
        }
        isFocused = false
    }

    private func formattedValue(_ value: Double) -> String {
        switch displayMode {
        case .number:
            return String(format: "%.2f", value)
        case .turnsDegrees:
            return formatTurnsDegrees(value)
        }
    }

    private func formatTurnsDegrees(_ degrees: Double) -> String {
        let parts = decomposeRoundedTurnsDegrees(degrees)
        let rounded = Double(parts.tenths) / 10.0
        let remainderText: String
        if abs(rounded.rounded() - rounded) < 0.0001 {
            remainderText = String(format: "%.0f", rounded)
        } else {
            remainderText = String(format: "%.1f", rounded)
        }
        return "\(parts.turns)x\(remainderText)°"
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
}

private struct CompositionIntField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.footnote)
                .frame(width: 38, alignment: .leading)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
        }
    }
}

private struct CompositionDoubleField: View {
    let title: String
    @Binding var value: Double
    var width: CGFloat = 92
    var lowerLimit: Double?

    var body: some View {
        HStack {
            Text(title)
                .font(.footnote)
                .frame(width: 56, alignment: .leading)
            TextField("", value: Binding(
                get: { value },
                set: { newValue in
                    value = lowerLimit.map { max($0, newValue) } ?? newValue
                }
            ), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }
}

private struct CompositionBackgroundPicker: View {
    @Binding var color: VolumeBackgroundColor
    @Binding var transparent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("透明背景", isOn: $transparent)

            ColorPicker(
                "背景颜色",
                selection: Binding(
                    get: {
                        Color(red: color.red, green: color.green, blue: color.blue)
                    },
                    set: { newColor in
                        let resolved = NSColor(newColor).usingColorSpace(.sRGB) ?? .black
                        color.red = max(0, min(1, resolved.redComponent))
                        color.green = max(0, min(1, resolved.greenComponent))
                        color.blue = max(0, min(1, resolved.blueComponent))
                    }
                )
            )
            .disabled(transparent)
        }
    }
}

private struct CompositionCheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 16
            let cols = Int(ceil(size.width / tile))
            let rows = Int(ceil(size.height / tile))

            for y in 0...rows {
                for x in 0...cols {
                    let isDark = (x + y).isMultiple(of: 2)
                    let rect = CGRect(
                        x: CGFloat(x) * tile,
                        y: CGFloat(y) * tile,
                        width: tile,
                        height: tile
                    )
                    context.fill(
                        Path(rect),
                        with: .color(isDark ? Color.gray.opacity(0.45) : Color.gray.opacity(0.22))
                    )
                }
            }
        }
    }
}

private struct CompositionMetalView: NSViewRepresentable {
    @ObservedObject var model: CompositionModel
    let previewMode: CompositionPreviewMode
    var cameraClipID: UUID? = nil
    @Binding var worldCamera: CameraRigState

    final class Coordinator {
        var renderer: CompositionRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
        view.autoResizeDrawable = false
        view.manualDrawableScale = CGFloat(model.workspaceLayout.previewQuality.drawableScale(isPlaying: model.isCompositionPlaying))
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = 60

        let renderer = CompositionRenderer(view: view)
        context.coordinator.renderer = renderer
        view.delegate = renderer
        view.interactionDelegate = renderer

        return view
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        if nsView.delegate == nil {
            nsView.delegate = renderer
        }
        if nsView.interactionDelegate == nil {
            nsView.interactionDelegate = renderer
        }
        renderer.setAssets(model.assets)
        renderer.setRenderLayers(
            model.activeRenderLayers(),
            allowModifiedTextureRefresh: !model.isCompositionValueDragging
        )
        renderer.setBackgroundColor(
            model.composition.backgroundColor,
            transparent: model.composition.backgroundTransparent
        )
        let previewScale = CGFloat(model.workspaceLayout.previewQuality.drawableScale(isPlaying: model.isCompositionPlaying))
        nsView.manualDrawableScale = previewScale
        renderer.setPreviewQuality(
            model.workspaceLayout.previewQuality,
            isPlaying: model.isCompositionPlaying
        )
        renderer.setInteractionMode(previewMode == .world ? .orbit : .freeCamera)
        renderer.onPreviewDiagnosticsChanged = { diagnostics in
            DispatchQueue.main.async {
                model.updateCompositionRendererDiagnostics(diagnostics)
            }
        }
        renderer.onModifiedTextureRefreshStatusChanged = { refreshStatus in
            DispatchQueue.main.async {
                model.updateCompositionModifierPreviewStatus(refreshStatus)
            }
        }
        renderer.onCameraInteractionBegan = {
            DispatchQueue.main.async {
                guard previewMode != .world else { return }
                model.beginCompositionValueDrag()
            }
        }
        renderer.onCameraInteractionEnded = {
            DispatchQueue.main.async {
                guard previewMode != .world else { return }
                model.endCompositionValueDrag()
            }
        }
        renderer.onCameraChanged = { camera in
            DispatchQueue.main.async {
                switch previewMode {
                case .world:
                    worldCamera = camera
                case .camera, .allCameras:
                    if let cameraClipID {
                        model.selectCameraClip(cameraClipID)
                    } else if let selectedID = model.selectedCameraClipID,
                              model.isCameraClipVisible(id: selectedID) {
                        model.selectCameraClip(selectedID)
                    } else if let activeID = model.activeCameraClip()?.id {
                        model.selectCameraClip(activeID)
                    }
                    model.setCompositionCameraFromView(camera)
                }
            }
        }
        if previewMode == .world {
            renderer.setCamera(worldCamera)
        } else {
            renderer.setCamera(model.renderCamera(clipID: cameraClipID, at: model.currentFrame))
        }
        renderer.requestRedraw()
    }
}
