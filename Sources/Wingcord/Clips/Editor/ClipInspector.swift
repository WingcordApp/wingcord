import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

// MARK: - The editor's inspector
//
// docs/CLIPS-PRESENCE.md, D14 — a trailing pane of grouped sections: the
// canvas (shape, background, padding, corners, shadow), Discord's crop presets,
// then whatever is selected — a segment's speed, a zoom, a blur, a caption,
// words, a picture — and the clip's own: the cursor, captions, the sound with
// voice clean-up, the camera, Clip Info.

struct ClipInspector: View {
    var editor: ClipEditorModel

    var body: some View {
        Form {
            CanvasSection(editor: editor)

            Section("Crop") {
                SegmentedPicker(
                    options: CropPreset.allCases.map { .init($0, $0.title) },
                    selection: binding(\.crop, "Crop"),
                    fillsWidth: true
                )
                HStack {
                    Button("Adjust…") { editor.isAdjustingCrop = true }
                        .disabled(editor.edits.crop == .original)
                    Spacer()
                    Button("Reset") {
                        editor.change("Reset Crop") {
                            $0.crop = .original
                            $0.cropPosition = 0.5
                        }
                    }
                    .disabled(editor.edits.crop == .original && editor.edits.cropPosition == 0.5)
                }
            }

            selectedSection

            if editor.cursorLog != nil {
                CursorSection(editor: editor)
            }

            CaptionsSection(editor: editor)

            if !editor.stems.isEmpty {
                AudioSection(editor: editor)
            }

            if editor.cameraURL != nil {
                Section("Camera") {
                    Toggle("Show the camera", isOn: Binding(
                        get: { editor.edits.camera != nil },
                        set: { shown in editor.change("Camera") { $0.camera = shown ? CameraPlacement() : nil } }
                    ))
                    .toggleStyle(.switch)
                    if let camera = editor.edits.camera {
                        LabeledContent("Size") {
                            Slider(value: Binding(
                                get: { camera.diameter },
                                set: { editor.edits.camera?.diameter = $0 }
                            ), in: 0.15...0.6) { editing in
                                if editing { editor.beginChange() } else { editor.endChange("Camera Size") }
                            }
                        }
                    }
                }
            }

            ClipInfoSection(editor: editor)
        }
        .formStyle(.grouped)
    }

    /// The section for whatever the timeline or the picture has selected.
    @ViewBuilder
    private var selectedSection: some View {
        switch editor.selection {
        case .segment:
            if let segment = editor.selectedSegment {
                Section("Segment") {
                    LabeledContent("Speed") {
                        SegmentedPicker(
                            options: [0.5, 1, 1.5, 2, 4].map { .init($0, ClipTimelineView.scale($0)) },
                            selection: Binding(get: { segment.speed }, set: { editor.setSpeed($0) })
                        )
                    }
                    LabeledContent("Length", value: ClipEditorView.time(segment.outputDuration))
                    Button("Delete Segment", role: .destructive) { editor.deleteSelectedSegment() }
                        .disabled(editor.sequence.placed.count < 2)
                }
            }
        case .zoom(let id):
            if let index = editor.edits.zooms.firstIndex(where: { $0.id == id }) {
                Section(editor.edits.zooms[index].isSuggested ? "Zoom (suggested)" : "Zoom") {
                    LabeledContent("Scale") {
                        Slider(value: Binding(
                            get: { editor.edits.zooms[safe: index]?.scale ?? 2 },
                            set: { editor.edits.zooms[index].scale = $0 }
                        ), in: ZoomBlock.scales) { editing in
                            if editing { editor.beginChange() } else { editor.endChange("Zoom Scale") }
                        }
                    }
                    if editor.cursorLog != nil {
                        Toggle("Follow the cursor", isOn: Binding(
                            get: { editor.edits.zooms[safe: index]?.followsCursor ?? false },
                            set: { value in editor.change("Follow Cursor") { $0.zooms[index].followsCursor = value } }
                        ))
                        .toggleStyle(.switch)
                    }
                    Text("Drag the target on the picture to choose where it looks.")
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(InkColor.secondary)
                    Button("Remove Zoom", role: .destructive) { editor.deleteSelection() }
                }
            }
        case .blur(let id):
            if let index = editor.edits.blurs.firstIndex(where: { $0.id == id }) {
                Section("Blur") {
                    SegmentedPicker(
                        options: BlurRegion.Style.allCases.map { .init($0, $0.title) },
                        selection: Binding(
                            get: { editor.edits.blurs[safe: index]?.style ?? .blur },
                            set: { value in editor.change("Blur Style") { $0.blurs[index].style = value } }
                        ),
                        fillsWidth: true
                    )
                    LabeledContent("Strength") {
                        Slider(value: Binding(
                            get: { editor.edits.blurs[safe: index]?.strength ?? 0.6 },
                            set: { editor.edits.blurs[index].strength = $0 }
                        ), in: 0...1) { editing in
                            if editing { editor.beginChange() } else { editor.endChange("Blur Strength") }
                        }
                    }
                    Text("Drag the box on the picture to place it; its corner sizes it.")
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(InkColor.secondary)
                    Button("Remove Blur", role: .destructive) { editor.deleteSelection() }
                }
            }
        case .caption(let id):
            if let index = editor.edits.captions.firstIndex(where: { $0.id == id }) {
                Section("Caption") {
                    TextField("Caption", text: Binding(
                        get: { editor.edits.captions[safe: index]?.text ?? "" },
                        set: { editor.edits.captions[index].text = $0 }
                    ), axis: .vertical)
                    Button("Remove Caption", role: .destructive) { editor.deleteSelection() }
                }
            }
        case .overlay(let id):
            if let index = editor.edits.texts.firstIndex(where: { $0.id == id }) {
                Section("Text") { TextSettings(editor: editor, index: index) }
            } else if let index = editor.edits.images.firstIndex(where: { $0.id == id }) {
                Section("Image") { ImageSettings(editor: editor, index: index) }
            }
        case nil:
            EmptyView()
        }
    }

    private func binding<Value: Equatable>(_ key: WritableKeyPath<ClipEdits, Value>, _ name: String) -> Binding<Value> {
        Binding(get: { editor.edits[keyPath: key] }, set: { value in editor.change(name) { $0[keyPath: key] = value } })
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - The canvas

/// Slice's frame for a recording: the shape, what the picture sits on, and
/// how it sits there.
private struct CanvasSection: View {
    var editor: ClipEditorModel

    var body: some View {
        Section("Canvas") {
            SegmentedPicker(
                options: ClipCanvas.Aspect.allCases.map { .init($0, $0.title) },
                selection: Binding(
                    get: { editor.edits.canvas.aspect },
                    set: { value in editor.change("Canvas Shape") { $0.canvas.aspect = value } }
                ),
                fillsWidth: true
            )
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.base) {
                    swatch("None", fill: AnyShapeStyle(Ink.quaternary), isOn: editor.edits.canvas.background == .none) {
                        editor.change("Background") { $0.canvas = .plain }
                    }
                    ForEach(ClipCanvas.presets, id: \.name) { preset in
                        swatch(preset.name, fill: Self.fill(preset.canvas.background),
                               isOn: editor.edits.canvas.background == preset.canvas.background) {
                            editor.change("Background") { $0.canvas = preset.canvas }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            if editor.edits.canvas.background != .none {
                ColorPicker("Background", selection: Binding(
                    get: { Color(nsColor: NSColor(rgb: Self.firstColour(editor.edits.canvas.background))) },
                    set: { colour in
                        let rgb = NSColor(colour).rgb
                        editor.change("Background") { edits in
                            if case .gradient(_, let to, let angle) = edits.canvas.background {
                                edits.canvas.background = .gradient(rgb, to, angle: angle)
                            } else {
                                edits.canvas.background = .solid(rgb)
                            }
                        }
                    }
                ), supportsOpacity: false)
                slider("Padding", value: \.canvas.padding, range: 0...0.2)
                slider("Corners", value: \.canvas.cornerRadius, range: 0...0.08)
                slider("Shadow", value: \.canvas.shadow, range: 0...1)
            }
        }
    }

    private func slider(_ title: String, value key: WritableKeyPath<ClipEdits, Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: Binding(get: { editor.edits[keyPath: key] }, set: { editor.edits[keyPath: key] = $0 }), in: range) { editing in
                if editing { editor.beginChange() } else { editor.endChange(title) }
            }
        }
    }

    private func swatch(_ name: String, fill: AnyShapeStyle, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
                .frame(width: 44, height: 30)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isOn ? Palette.accent : .white.opacity(0.15), lineWidth: isOn ? 2.5 : 1)
                }
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    static func fill(_ background: ClipCanvas.Background) -> AnyShapeStyle {
        switch background {
        case .none: AnyShapeStyle(Ink.quaternary)
        case .solid(let rgb): AnyShapeStyle(Color(nsColor: NSColor(rgb: rgb)))
        case .gradient(let from, let to, _):
            AnyShapeStyle(LinearGradient(
                colors: [Color(nsColor: NSColor(rgb: from)), Color(nsColor: NSColor(rgb: to))],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        }
    }

    nonisolated static func firstColour(_ background: ClipCanvas.Background) -> UInt32 {
        switch background {
        case .none: 0
        case .solid(let rgb): rgb
        case .gradient(let from, _, _): from
        }
    }
}

// MARK: - The cursor

private struct CursorSection: View {
    var editor: ClipEditorModel

    var body: some View {
        Section("Cursor") {
            Toggle("Show the cursor", isOn: Binding(
                get: { editor.edits.cursor.isVisible },
                set: { value in editor.change("Cursor") { $0.cursor.isVisible = value } }
            ))
            .toggleStyle(.switch)
            if editor.edits.cursor.isVisible {
                LabeledContent("Size") {
                    Slider(value: Binding(get: { editor.edits.cursor.size }, set: { editor.edits.cursor.size = $0 }),
                           in: CursorStyle.sizes) { editing in
                        if editing { editor.beginChange() } else { editor.endChange("Cursor Size") }
                    }
                }
                LabeledContent("Smoothing") {
                    Slider(value: Binding(get: { editor.edits.cursor.smoothing }, set: { editor.edits.cursor.smoothing = $0 }),
                           in: 0...1) { editing in
                        if editing { editor.beginChange() } else { editor.endChange("Cursor Smoothing") }
                    }
                }
                Toggle("Show clicks", isOn: Binding(
                    get: { editor.edits.cursor.showsClicks },
                    set: { value in editor.change("Clicks") { $0.cursor.showsClicks = value } }
                ))
                .toggleStyle(.switch)
            }
            if editor.canSuggestZooms {
                Button("Suggest Zooms from Clicks", systemImage: "sparkles") { editor.suggestZooms() }
            }
        }
    }
}

// MARK: - Captions

private struct CaptionsSection: View {
    var editor: ClipEditorModel

    var body: some View {
        Section("Captions") {
            let voices = editor.stems.filter(\.isVoice)
            let sources = voices.isEmpty ? editor.stems : voices
            if !sources.isEmpty {
                Menu {
                    ForEach(sources) { stem in
                        Button(stem.title, systemImage: stem.symbolName) { editor.transcribe(stem: stem.index) }
                    }
                } label: {
                    Label(editor.edits.captions.isEmpty ? "Make Captions from…" : "Make Captions Again from…",
                          systemImage: "captions.bubble")
                }
                .disabled({ if case .working = editor.captionState { true } else { false } }())
            }
            switch editor.captionState {
            case .working(let stage):
                HStack(spacing: Spacing.base) {
                    if case .downloading(let fraction) = stage {
                        ProgressView(value: fraction).frame(width: 80)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(Self.words(for: stage))
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(InkColor.secondary)
                }
            case .failed(let reason):
                Text(reason)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Palette.destructive)
            case .idle:
                if editor.edits.captions.isEmpty {
                    Text("Words said in the clip, written on this Mac — nothing leaves it.")
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(InkColor.secondary)
                }
            }
            if !editor.edits.captions.isEmpty {
                Toggle("Show captions", isOn: Binding(
                    get: { editor.edits.showsCaptions },
                    set: { value in editor.change("Captions") { $0.showsCaptions = value } }
                ))
                .toggleStyle(.switch)
                if editor.edits.showsCaptions {
                    LabeledContent("Size") {
                        SegmentedPicker(
                            options: OverlaySize.allCases.map { .init($0, $0.title) },
                            selection: Binding(
                                get: { editor.edits.captionStyle.size },
                                set: { value in editor.change("Caption Size") { $0.captionStyle.size = value } }
                            )
                        )
                    }
                    LabeledContent("Place") {
                        SegmentedPicker(
                            options: CaptionStyle.Placement.allCases.map { .init($0, $0.title) },
                            selection: Binding(
                                get: { editor.edits.captionStyle.placement },
                                set: { value in editor.change("Caption Place") { $0.captionStyle.placement = value } }
                            )
                        )
                    }
                    Toggle("Dark box behind", isOn: Binding(
                        get: { editor.edits.captionStyle.hasBackground },
                        set: { value in editor.change("Caption Box") { $0.captionStyle.hasBackground = value } }
                    ))
                    .toggleStyle(.switch)
                }
            }
        }
    }

    nonisolated static func words(for stage: CaptionTranscriber.Stage) -> String {
        switch stage {
        case .preparing: "Getting ready…"
        case .downloading: "Downloading the language model…"
        case .listening: "Listening…"
        }
    }
}

// MARK: - The sound

private struct AudioSection: View {
    var editor: ClipEditorModel

    var body: some View {
        Section("Audio") {
            ForEach(editor.stems) { stem in
                Toggle(isOn: Binding(
                    get: { !editor.edits.mutedTracks.contains(stem.index) },
                    set: { kept in
                        editor.change(kept ? "Unmute" : "Mute") { edits in
                            if kept { edits.mutedTracks.remove(stem.index) } else { edits.mutedTracks.insert(stem.index) }
                        }
                    }
                )) {
                    Label(stem.title, systemImage: stem.symbolName)
                }
                .toggleStyle(.switch)
                if stem.isVoice, !editor.edits.mutedTracks.contains(stem.index) {
                    HStack {
                        Toggle("Clean up the voice", isOn: Binding(
                            get: { editor.edits.cleanedStems.contains(stem.index) },
                            set: { editor.setCleanUp($0, stem: stem.index) }
                        ))
                        .toggleStyle(.checkbox)
                        .disabled(editor.cleaningStems.contains(stem.index))
                        if editor.cleaningStems.contains(stem.index) {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.leading, 26)
                    .help("Keeps the voice and leaves out the noise around it — Apple's voice isolation, on this Mac.")
                }
            }
            if let failure = editor.cleanUpFailure {
                Text(failure)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Palette.destructive)
            }
        }
    }
}

// MARK: - Words and pictures

/// Discord's Text settings: the words, Size, Color, Stroke color, Stroke
/// width, Remove Text.
private struct TextSettings: View {
    var editor: ClipEditorModel
    var index: Int

    var body: some View {
        if let text = editor.edits.texts[safe: index] {
            TextEditor(text: Binding(get: { editor.edits.texts[safe: index]?.text ?? "" }, set: { editor.edits.texts[index].text = $0 }))
                .font(.system(.body))
                .frame(minHeight: 54)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Ink.quaternary, in: .rect(cornerRadius: 8))
            LabeledContent("Size") {
                SegmentedPicker(
                    options: OverlaySize.allCases.map { .init($0, $0.title) },
                    selection: Binding(get: { text.size }, set: { value in editor.change("Text Size") { $0.texts[index].size = value } })
                )
            }
            ColorPicker("Color", selection: color(\.color), supportsOpacity: false)
            ColorPicker("Stroke color", selection: color(\.strokeColor), supportsOpacity: false)
            LabeledContent("Stroke width") {
                SegmentedPicker(
                    options: StrokeWidth.allCases.map { .init($0, $0.title) },
                    selection: Binding(get: { text.strokeWidth }, set: { value in editor.change("Stroke") { $0.texts[index].strokeWidth = value } })
                )
            }
            Button("Remove Text", role: .destructive) { editor.removeOverlay(text.id) }
        }
    }

    private func color(_ key: WritableKeyPath<TextOverlay, UInt32>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(rgb: editor.edits.texts[safe: index]?[keyPath: key] ?? 0)) },
            set: { colour in editor.change("Text Colour") { $0.texts[index][keyPath: key] = NSColor(colour).rgb } }
        )
    }
}

/// Discord's Image settings: Size, Shadow, Shadow color, Remove.
private struct ImageSettings: View {
    var editor: ClipEditorModel
    var index: Int

    var body: some View {
        if let image = editor.edits.images[safe: index] {
            LabeledContent("Size") {
                SegmentedPicker(
                    options: OverlaySize.allCases.map { .init($0, $0.title) },
                    selection: Binding(get: { image.size }, set: { value in editor.change("Image Size") { $0.images[index].size = value } })
                )
            }
            Toggle("Shadow", isOn: Binding(
                get: { image.hasShadow },
                set: { value in editor.change("Shadow") { $0.images[index].hasShadow = value } }
            ))
            .toggleStyle(.switch)
            if image.hasShadow {
                ColorPicker("Shadow color", selection: Binding(
                    get: { Color(nsColor: NSColor(rgb: editor.edits.images[safe: index]?.shadowColor ?? 0)) },
                    set: { colour in editor.change("Shadow Colour") { $0.images[index].shadowColor = NSColor(colour).rgb } }
                ), supportsOpacity: false)
            }
            Button("Remove Image", role: .destructive) { editor.removeOverlay(image.id) }
        }
    }
}

/// Discord's Clip Info: the game, who was there, when, how long.
private struct ClipInfoSection: View {
    var editor: ClipEditorModel

    var body: some View {
        Section("Clip Info") {
            if let game = editor.item.game {
                LabeledContent("Game", value: game)
            }
            LabeledContent("Length", value: ClipEditorView.time(editor.outputDuration))
            LabeledContent("Saved", value: editor.item.clip.created.formatted(date: .abbreviated, time: .shortened))
            if !editor.item.participants.isEmpty {
                LabeledContent("With") {
                    Text(editor.item.participants.map(\.name).joined(separator: ", "))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}
