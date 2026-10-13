import AppKit
import SwiftUI
import WingcordCore

/// Discord's preview of a text file in a message (`684519`'s `eS`, its boxes
/// from the `__4d95d` stylesheet — DESIGN-NOTES §13): the first lines in a
/// code box over a footer of controls.
///
/// **Its grounds are this app's**, the ones the file card and a code block
/// beside it wear: the code box is a code block's plate, the footer and the
/// edge are the file card's — so a preview, a file card and a fenced block in
/// one message are one family whatever the theme.
struct PlaintextPreviewCard: View {
    var key: PlaintextCardKey
    /// A card laid out only to learn its size: it fetches nothing and reports
    /// nothing. See `HostedCardHosts.measure`.
    var isMeasuring = false

    @Environment(AppModel.self) private var model
    /// The code box's content, measured, for an open card's height.
    @State private var contentHeight: CGFloat = 0
    @State private var showsWholeFile = false

    /// Discord's text area: at least 118, at most 500 open, and 126 folded —
    /// `max(6 × 16, 100) + 26`, which every file fills, because the code view
    /// is at least 100 tall inside 26 points of margin, padding and border.
    static let minimumHeight: CGFloat = 118
    static let collapsedHeight: CGFloat = 126
    static let expandedMaxHeight: CGFloat = 500
    /// The footer's row: Discord's name over its size, 18 and 16 points of
    /// line — fixed, so a card that has not loaded measures as one that has.
    static let footerRowHeight: CGFloat = 34

    var body: some View {
        let state = model.plaintextPreview(key)
        let shape = RoundedRectangle(cornerRadius: EmbedLayoutEngine.corner, style: .continuous)
        VStack(spacing: 0) {
            textArea(state)
            Rectangle().fill(edge).frame(height: 1)
            footer(state)
        }
        .background(Color(cgColor: ThemeInk.current.cardFill))
        .clipShape(shape)
        .overlay { shape.strokeBorder(edge, lineWidth: 1) }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard !isMeasuring else { return }
            model.noteHostedCardSize(size, for: .plaintext(key))
        }
        .task {
            guard !isMeasuring else { return }
            await model.loadPlaintextPreview(key)
        }
        .sheet(isPresented: $showsWholeFile) {
            PlaintextFileSheet(key: key, wrapsText: state.wrapsText)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: key.filename))
    }

    private var edge: Color { Color(cgColor: ThemeInk.current.hoverFill) }

    // MARK: Text

    private func textArea(_ state: PlaintextPreviewState) -> some View {
        let height = state.isExpanded
            ? min(Self.expandedMaxHeight, max(Self.minimumHeight, contentHeight))
            : Self.collapsedHeight
        return ZStack(alignment: .topLeading) {
            Color(cgColor: ThemeInk.current.plates.codeFill)
            if case .loaded(let text, let bytesLeft) = state.contents {
                let excerpt = PlaintextPreview.excerpt(of: text, isExpanded: state.isExpanded, bytesLeft: bytesLeft)
                ScrollView(state.wrapsText ? .vertical : [.vertical, .horizontal]) {
                    CodeTextView(text: CodeText.plain(excerpt.text + excerpt.notice), wraps: state.wrapsText)
                        .frame(minHeight: 100, alignment: .topLeading)
                        // `.codeView`: padding 8, margin 8 8 0.
                        .padding(8)
                        .padding([.top, .horizontal], 8)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            // And the edge along the top, which the stroke draws inside.
                            contentHeight = height + 1
                        }
                }
                // A file that fits does not hold the transcript's scroll.
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height)
    }

    // MARK: Footer

    /// Expand or Collapse, the name and size, then — after a gap of at least
    /// 16 — View whole file and ⋯, as Discord's footer orders them.
    private func footer(_ state: PlaintextPreviewState) -> some View {
        HStack(spacing: 0) {
            toggle(state)
            PlaintextFileName(key: key)
            Spacer(minLength: 16)
            if case .loaded = state.contents {
                Button { showsWholeFile = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("View whole file")
                .accessibilityLabel(Text("View whole file"))
            }
            PlaintextMoreMenu(key: key, wrapsText: Binding(
                get: { state.wrapsText },
                set: { wraps in model.updatePlaintextPreview(key) { $0.wrapsText = wraps } }
            ))
            .padding(.leading, 16)
            .padding(.trailing, 4)
        }
        .frame(height: Self.footerRowHeight)
        .padding(12)
    }

    /// Discord's `eI`: offered when the card is open or folds lines away, and
    /// titled with how many lines the file has — or more than, when the fetch
    /// did not reach its end.
    @ViewBuilder
    private func toggle(_ state: PlaintextPreviewState) -> some View {
        if case .loaded(let text, let bytesLeft) = state.contents {
            let excerpt = PlaintextPreview.excerpt(of: text, isExpanded: state.isExpanded, bytesLeft: bytesLeft)
            if excerpt.offersToggle {
                let title = PlaintextPreview.toggleTitle(
                    isExpanded: state.isExpanded,
                    lineCount: excerpt.lineCount,
                    isWholeFile: bytesLeft == 0
                )
                Button {
                    model.updatePlaintextPreview(key) { $0.isExpanded.toggle() }
                } label: {
                    Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(title)
                .accessibilityLabel(Text(title))
                .padding(.trailing, 8)
            }
        }
    }
}

/// Discord's `ep`: the name over its size, the name cut at its end and
/// whole in its tooltip.
private struct PlaintextFileName: View {
    var key: PlaintextCardKey

    var body: some View {
        let size = PlaintextPreview.fileSize(key.size)
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: key.filename)
                .font(.body)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("\(key.filename) (\(size))")
            Text(verbatim: size)
                .font(.caption)
                .foregroundStyle(Ink.tertiary)
        }
    }
}

/// Discord's ⋯ (`em`): Download, and Wrap Text.
private struct PlaintextMoreMenu: View {
    var key: PlaintextCardKey
    @Binding var wrapsText: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Download") {
                AttachmentDownloads.download(from: key.url, named: key.filename, model: model)
            }
            Toggle("Wrap Text", isOn: $wrapsText)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel(Text("More Options"))
    }
}

/// Discord's View whole file (`eN`): everything the card fetched, with what
/// was not said after it, and the card's footer under it — its own Wrap Text,
/// started from the card's, as Discord's modal starts its own.
struct PlaintextFileSheet: View {
    var key: PlaintextCardKey

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var wrapsText: Bool

    init(key: PlaintextCardKey, wrapsText: Bool) {
        self.key = key
        _wrapsText = State(initialValue: wrapsText)
    }

    var body: some View {
        VStack(spacing: 0) {
            if case .loaded(let text, let bytesLeft) = model.plaintextPreview(key).contents {
                CodeDocumentView(
                    text: CodeText.plain(text + PlaintextPreview.wholeFileNotice(bytesLeft: bytesLeft)),
                    wraps: wrapsText,
                    inset: 16
                )
                .background(Color(cgColor: ThemeInk.current.plates.codeFill))
            }
            Divider()
            HStack(spacing: 0) {
                PlaintextFileName(key: key)
                Spacer(minLength: 16)
                PlaintextMoreMenu(key: key, wrapsText: $wrapsText)
                    .padding(.trailing, 16)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 900, minHeight: 360, idealHeight: 640)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Plaintext file previews"))
    }
}
