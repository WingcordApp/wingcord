import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

// MARK: - The editor
//
// docs/CLIPS-PRESENCE.md, D14 — Discord's Edit Clip grown into a Slice-class
// Mac editor (Phase 5): the edit itself playing, with handles for whatever is
// selected; the tools; the timeline's lanes; the inspector as a trailing pane
// (HIG: "Consider a panel … or a split view pane for an inspector"). Space
// plays, the arrows step a frame, I and O trim at the playhead, S cuts there,
// ⌫ removes what is selected, ⌘Z undoes (HIG: "Support high-precision input
// … Handle keyboard shortcuts").

struct ClipEditorView: View {
    var store: ClipLibraryStore
    var share: (ClipLibraryItem) -> Void
    @State private var editor: ClipEditorModel
    @State private var showsInspector = true
    @State private var isExporting = false
    @State private var exportState: ExportState = .idle
    @State private var isPickingImage = false
    @State private var imageFailure: String?
    @FocusState private var isFocused: Bool
    @Environment(\.undoManager) private var undoManager

    enum ExportState: Equatable {
        case idle, exporting(Double), failed(String)
    }

    init(item: ClipLibraryItem, store: ClipLibraryStore, share: @escaping (ClipLibraryItem) -> Void) {
        self.store = store
        self.share = share
        _editor = State(initialValue: ClipEditorModel(item: item))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if editor.isAdjustingCrop {
                    CropAdjustView(editor: editor)
                } else {
                    ComposedPreview(editor: editor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            tools
            ClipTimelineView(editor: editor)
                .frame(height: 200)
                .padding(.horizontal, Spacing.group)
                .padding(.bottom, Spacing.margin)
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) { editor.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { editor.step(by: -1); return .handled }
        .onKeyPress(.rightArrow) { editor.step(by: 1); return .handled }
        .onKeyPress("i") { editor.setStartHere(); return .handled }
        .onKeyPress("o") { editor.setEndHere(); return .handled }
        .onKeyPress("s") { editor.splitAtPlayhead(); return .handled }
        .onKeyPress(.delete) {
            guard editor.selection != nil else { return .ignored }
            editor.deleteSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            if editor.isAdjustingCrop { editor.isAdjustingCrop = false; return .handled }
            guard editor.selection != nil else { return .ignored }
            editor.selection = nil
            return .handled
        }
        .inspector(isPresented: $showsInspector) {
            ClipInspector(editor: editor)
                .inspectorColumnWidth(min: 270, ideal: 310, max: 400)
        }
        .toolbar {
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                    .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
        .modal(isPresented: $isExporting) {
            ClipExportSheet(editor: editor) { settings in
                isExporting = false
                export(with: settings)
            } cancel: { isExporting = false }
        }
        .fileImporter(isPresented: $isPickingImage, allowedContentTypes: [.png, .jpeg, .webP]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try editor.addImage(from: url)
                imageFailure = nil
            } catch {
                imageFailure = error.localizedDescription
            }
        }
        .task {
            editor.undoManager = undoManager
            await editor.load()
            isFocused = true
        }
        .onDisappear { editor.tearDown() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.snug) {
            Button("Clips", systemImage: "chevron.left") {
                editor.tearDown()
                store.editing = nil
                store.reload()
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help("Back to the library")

            TextField("Untitled clip", text: $editor.title)
                .textFieldStyle(.plain)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .disabled(editor.item.kind != .clip)

            Spacer(minLength: Spacing.snug)

            switch exportState {
            case .exporting(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 120)
            case .failed(let reason):
                Text(reason)
                    .font(.system(.callout))
                    .foregroundStyle(Palette.destructive)
                    .lineLimit(2)
            case .idle:
                EmptyView()
            }

            Button("Export…", systemImage: "square.and.arrow.down") { isExporting = true }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled({ if case .exporting = exportState { true } else { false } }())
            if editor.item.kind == .clip || editor.item.kind == .recording {
                Button("Share…", systemImage: "square.and.arrow.up") {
                    editor.save()
                    share(currentItem)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.snug)
    }

    /// The item with the edits as they stand, for the share sheet.
    private var currentItem: ClipLibraryItem {
        var item = editor.item
        if item.kind == .recording {
            item.clip.take?.edits = editor.edits.isEmpty ? nil : editor.edits
        } else {
            var manifest = item.clip.manifest ?? ClipManifest(createdAt: item.clip.created, duration: editor.sourceDuration)
            manifest.edits = editor.edits.isEmpty ? nil : editor.edits
            let title = editor.title.trimmingCharacters(in: .whitespaces)
            manifest.title = title.isEmpty ? nil : title
            item.clip.manifest = manifest
        }
        return item
    }

    private func export(with settings: ClipExportSettings) {
        let panel = NSSavePanel()
        let name = editor.title.isEmpty ? editor.item.clip.name : editor.title
        panel.nameFieldStringValue = name + (settings.format == .gif ? ".gif" : ".mp4")
        panel.allowedContentTypes = [settings.format == .gif ? .gif : .mpeg4Movie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportState = .exporting(0)
        Task {
            do {
                _ = try await editor.export(to: destination, settings: settings, maxBytes: nil) { fraction in
                    Task { @MainActor in
                        if case .exporting = exportState { exportState = .exporting(fraction) }
                    }
                }
                exportState = .idle
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                exportState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: Spacing.base) {
            Button(editor.isPlaying ? "Pause" : "Play", systemImage: editor.isPlaying ? "pause.fill" : "play.fill") {
                editor.togglePlay()
            }
            .labelStyle(.glassCircleIcon)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.space, modifiers: [])

            Text("\(Self.time(editor.currentTime)) / \(Self.time(editor.outputDuration))")
                .font(.system(.body, weight: .medium).monospacedDigit())
                .foregroundStyle(Ink.primary)
                .frame(minWidth: 110, alignment: .leading)

            Spacer(minLength: Spacing.base)

            Button("Split", systemImage: "scissors") { editor.splitAtPlayhead() }
                .help("Cut the clip at the playhead (S)")
            Menu {
                ForEach([0.25, 0.5, 1, 1.5, 2, 4], id: \.self) { speed in
                    Button(ClipTimelineView.scale(speed)) { editor.setSpeed(speed) }
                }
            } label: {
                Label("Speed", systemImage: "gauge.with.dots.needle.67percent")
            }
            .disabled(editor.selectedSegment == nil)
            .help(editor.selectedSegment == nil ? "Select a segment to change its speed" : "Play the segment faster or slower")
            Divider().frame(height: 20)
            Menu {
                Button("Add Zoom", systemImage: "plus.magnifyingglass") { editor.addZoom() }
                Button("Suggest Zooms from Clicks", systemImage: "sparkles") { editor.suggestZooms() }
                    .disabled(!editor.canSuggestZooms)
            } label: {
                Label("Zoom", systemImage: "plus.magnifyingglass")
            } primaryAction: {
                editor.addZoom()
            }
            .help("Zoom in on part of the picture")
            Button("Blur", systemImage: "drop.halffull") { editor.addBlur() }
                .help("Hide part of the picture")
            Button("Text", systemImage: "textformat") { editor.addText() }
                .help("Add words over the clip")
            Button("Image", systemImage: "photo") { isPickingImage = true }
                .help(imageFailure ?? "Add a picture over the clip")
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.snug)
    }

    nonisolated static func time(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let whole = Int(total)
        let tenths = Int((total - Double(whole)) * 10)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }
}

// MARK: - The picture

/// Maps between the source picture, the canvas and the screen.
nonisolated struct PreviewGeometry {
    /// The canvas on screen.
    var canvas: CGRect
    /// Where the picture sits on the canvas, in its 0…1 frame.
    var content: CGRect
    /// The crop, in the source's 0…1 frame.
    var crop: CGRect

    /// A point of the source picture (0…1) on screen — without the zoom.
    func screenPoint(source point: CGPoint) -> CGPoint {
        let inCrop = CGPoint(x: (point.x - crop.minX) / max(crop.width, 0.0001), y: (point.y - crop.minY) / max(crop.height, 0.0001))
        return CGPoint(
            x: canvas.minX + (content.minX + inCrop.x * content.width) * canvas.width,
            y: canvas.minY + (content.minY + inCrop.y * content.height) * canvas.height
        )
    }

    /// A point on screen as a point of the source picture (0…1).
    func sourcePoint(screen point: CGPoint) -> CGPoint {
        let x = ((point.x - canvas.minX) / max(canvas.width, 1) - content.minX) / max(content.width, 0.0001)
        let y = ((point.y - canvas.minY) / max(canvas.height, 1) - content.minY) / max(content.height, 0.0001)
        return CGPoint(x: crop.minX + x * crop.width, y: crop.minY + y * crop.height)
    }

    /// A canvas frame (0…1) on screen.
    func screenRect(canvas frame: CGRect) -> CGRect {
        CGRect(
            x: canvas.minX + frame.minX * canvas.width, y: canvas.minY + frame.minY * canvas.height,
            width: frame.width * canvas.width, height: frame.height * canvas.height
        )
    }
}

/// The edit playing, and a handle for what is selected.
private struct ComposedPreview: View {
    var editor: ClipEditorModel

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 16, dy: 16)
            let canvas = AVMakeRect(aspectRatio: editor.renderSize, insideRect: bounds)
            let size = editor.videoSize
            let crop = editor.cropRect
            let geometryMap = PreviewGeometry(
                canvas: canvas, content: editor.contentFrame,
                crop: size.width > 0 ? CGRect(x: crop.minX / size.width, y: crop.minY / size.height,
                                              width: crop.width / size.width, height: crop.height / size.height)
                    : CGRect(x: 0, y: 0, width: 1, height: 1)
            )
            ZStack(alignment: .topLeading) {
                EditorPlayerView(player: editor.player)
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX, y: canvas.minY)
                    .contentShape(.rect)
                    .onTapGesture { editor.selection = nil }
                SelectionHandles(editor: editor, map: geometryMap)
            }
        }
    }
}

/// Whatever is selected, made grabbable on the picture: a word or picture
/// moved, the camera moved, a blur moved and sized, a zoom's focus set.
private struct SelectionHandles: View {
    var editor: ClipEditorModel
    var map: PreviewGeometry
    @State private var origin: CGPoint?
    @State private var originRect: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let placement = editor.edits.camera, editor.cameraURL != nil {
                let diameter = placement.diameter * map.canvas.height
                let centre = CGPoint(x: map.canvas.minX + placement.x * map.canvas.width, y: map.canvas.minY + placement.y * map.canvas.height)
                Circle()
                    .strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: diameter, height: diameter)
                    .contentShape(.circle)
                    .offset(x: centre.x - diameter / 2, y: centre.y - diameter / 2)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        let start = origin ?? CGPoint(x: placement.x, y: placement.y)
                        if origin == nil { origin = start; editor.beginChange() }
                        editor.edits.camera?.x = min(1, max(0, start.x + value.translation.width / max(map.canvas.width, 1)))
                        editor.edits.camera?.y = min(1, max(0, start.y + value.translation.height / max(map.canvas.height, 1)))
                    }.onEnded { _ in origin = nil; editor.endChange("Move Camera") })
                    .help("Drag to move the camera")
            }
            switch editor.selection {
            case .overlay(let id):
                if let frame = overlayFrame(id) {
                    let rect = map.screenRect(canvas: frame)
                    Rectangle()
                        .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: rect.width, height: rect.height)
                        .contentShape(.rect)
                        .offset(x: rect.minX, y: rect.minY)
                        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                            let start = origin ?? centre(of: id)
                            if origin == nil { origin = start; editor.beginChange() }
                            move(id, to: CGPoint(
                                x: min(1, max(0, start.x + value.translation.width / max(map.canvas.width, 1))),
                                y: min(1, max(0, start.y + value.translation.height / max(map.canvas.height, 1)))
                            ))
                        }.onEnded { _ in origin = nil; editor.endChange("Move") })
                }
            case .blur(let id):
                if let blur = editor.edits.blurs.first(where: { $0.id == id }) {
                    let topLeft = map.screenPoint(source: CGPoint(x: blur.rect.minX, y: blur.rect.minY))
                    let bottomRight = map.screenPoint(source: CGPoint(x: blur.rect.maxX, y: blur.rect.maxY))
                    let rect = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
                    ZStack(alignment: .bottomTrailing) {
                        Rectangle()
                            .strokeBorder(.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .contentShape(.rect)
                            .gesture(blurDrag(id, rect: blur.rect, resizes: false))
                        Circle()
                            .fill(.white)
                            .frame(width: 12, height: 12)
                            .offset(x: 6, y: 6)
                            .gesture(blurDrag(id, rect: blur.rect, resizes: true))
                            .pointerStyle(.frameResize(position: .bottomTrailing))
                    }
                    .frame(width: max(rect.width, 8), height: max(rect.height, 8))
                    .offset(x: rect.minX, y: rect.minY)
                }
            case .zoom(let id):
                if let zoom = editor.edits.zooms.first(where: { $0.id == id }), !zoom.followsCursor {
                    let point = map.screenPoint(source: CGPoint(x: zoom.x, y: zoom.y))
                    Image(symbol: "scope")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .frame(width: 34, height: 34)
                        .contentShape(.circle)
                        .offset(x: point.x - 17, y: point.y - 17)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("preview")).onChanged { value in
                            if origin == nil { origin = .zero; editor.beginChange() }
                            let source = map.sourcePoint(screen: value.location)
                            guard let index = editor.edits.zooms.firstIndex(where: { $0.id == id }) else { return }
                            editor.edits.zooms[index].x = min(1, max(0, source.x))
                            editor.edits.zooms[index].y = min(1, max(0, source.y))
                        }.onEnded { _ in origin = nil; editor.endChange("Zoom Focus") })
                        .help("Drag to set where the zoom looks")
                }
            default:
                EmptyView()
            }
        }
        .coordinateSpace(.named("preview"))
    }

    private func blurDrag(_ id: UUID, rect: CGRect, resizes: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            let start = originRect ?? rect
            if originRect == nil { originRect = start; editor.beginChange() }
            let dx = value.translation.width / max(map.canvas.width * map.content.width, 1) * map.crop.width
            let dy = value.translation.height / max(map.canvas.height * map.content.height, 1) * map.crop.height
            guard let index = editor.edits.blurs.firstIndex(where: { $0.id == id }) else { return }
            var next = start
            if resizes {
                next.size.width = max(0.03, min(1 - start.minX, start.width + dx))
                next.size.height = max(0.03, min(1 - start.minY, start.height + dy))
            } else {
                next.origin.x = min(max(0, start.minX + dx), 1 - start.width)
                next.origin.y = min(max(0, start.minY + dy), 1 - start.height)
            }
            editor.edits.blurs[index].rect = next
        }.onEnded { _ in originRect = nil; editor.endChange(resizes ? "Resize Blur" : "Move Blur") }
    }

    private func overlayFrame(_ id: UUID) -> CGRect? {
        if let text = editor.edits.texts.first(where: { $0.id == id }) {
            return ClipOverlayRenderer.render(text, aspect: editor.outputAspect)?.frame
        }
        if let image = editor.edits.images.first(where: { $0.id == id }) {
            return ClipOverlayRenderer.render(image, assets: editor.assetsFolder, aspect: editor.outputAspect)?.frame
        }
        return nil
    }

    private func centre(of id: UUID) -> CGPoint {
        if let text = editor.edits.texts.first(where: { $0.id == id }) { return CGPoint(x: text.x, y: text.y) }
        if let image = editor.edits.images.first(where: { $0.id == id }) { return CGPoint(x: image.x, y: image.y) }
        return CGPoint(x: 0.5, y: 0.5)
    }

    private func move(_ id: UUID, to point: CGPoint) {
        if let index = editor.edits.texts.firstIndex(where: { $0.id == id }) {
            editor.edits.texts[index].x = point.x
            editor.edits.texts[index].y = point.y
        } else if let index = editor.edits.images.firstIndex(where: { $0.id == id }) {
            editor.edits.images[index].x = point.x
            editor.edits.images[index].y = point.y
        }
    }
}

/// The crop set on the source picture itself: the still at the playhead,
/// everything outside the box dimmed, the box dragged along the one way it
/// can move.
private struct CropAdjustView: View {
    var editor: ClipEditorModel
    @State private var startPosition: Double?

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 16, dy: 16)
            let picture = AVMakeRect(
                aspectRatio: editor.videoSize == .zero ? CGSize(width: 16, height: 9) : editor.videoSize, insideRect: bounds
            )
            let scale = editor.videoSize.width > 0 ? picture.width / editor.videoSize.width : 1
            let crop = editor.cropRect
            let box = CGRect(
                x: picture.minX + crop.minX * scale, y: picture.minY + crop.minY * scale,
                width: crop.width * scale, height: crop.height * scale
            )
            ZStack(alignment: .topLeading) {
                if let still = editor.cropStill {
                    Image(decorative: still, scale: 1)
                        .resizable()
                        .frame(width: picture.width, height: picture.height)
                        .offset(x: picture.minX, y: picture.minY)
                }
                Path { path in
                    path.addRect(picture)
                    path.addRect(box)
                }
                .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(.white, lineWidth: 2)
                    .contentShape(.rect)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        let start = startPosition ?? editor.edits.cropPosition
                        if startPosition == nil { startPosition = start; editor.beginChange() }
                        let horizontal = box.height >= picture.height - 1
                        let travel = horizontal ? picture.width - box.width : picture.height - box.height
                        guard travel > 0 else { return }
                        let delta = horizontal ? value.translation.width : value.translation.height
                        editor.edits.cropPosition = min(1, max(0, start + Double(delta / travel)))
                    }.onEnded { _ in startPosition = nil; editor.endChange("Move Crop") })
                    .help("Drag to move the crop")
            }
            .overlay(alignment: .bottom) {
                Button("Done") { editor.isAdjustingCrop = false }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.bottom, Spacing.margin)
            }
        }
    }
}

/// The Export sheet: MP4 or GIF, how big, how smooth.
private struct ClipExportSheet: View {
    var editor: ClipEditorModel
    var export: (ClipExportSettings) -> Void
    var cancel: () -> Void
    @State private var settings = ClipExportSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(title: "Export Clip")
            Form {
                LabeledContent("Format") {
                    SegmentedPicker(
                        options: ClipExportSettings.Format.allCases.map { .init($0, $0.title) },
                        selection: $settings.format
                    )
                }
                if settings.format == .mp4 {
                    Picker("Resolution", selection: $settings.resolution) {
                        ForEach(ClipExportSettings.Resolution.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Frame Rate", selection: $settings.framerate) {
                        ForEach(ClipExportSettings.Framerate.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } else {
                    Text("A GIF is written small and at 15 frames a second, so it stays light enough to send.")
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(InkColor.secondary)
                }
                Toggle("Burn in speaking indicators", isOn: Binding(
                    get: { editor.edits.burnsInSpeaking },
                    set: { value in editor.change("Speaking Indicators") { $0.burnsInSpeaking = value } }
                ))
                .toggleStyle(.switch)
                .disabled(editor.item.clip.manifest?.timeline.contains { if case .speaking = $0.event { true } else { false } } != true)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, Spacing.base)
            GlassEffectContainer(spacing: Spacing.snug) {
                HStack(spacing: Spacing.snug) {
                    ModalButton(title: "Cancel", symbolName: "xmark", role: .cancel, action: cancel)
                    Spacer()
                    ModalButton(title: "Export…", symbolName: "square.and.arrow.up", role: .act) { export(settings) }
                }
            }
            .padding(Spacing.margin)
        }
        .frame(width: 440)
    }
}

/// The player's layer — the picture alone, no controls of its own.
struct EditorPlayerView: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.wantsLayer = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: NSView {
        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
