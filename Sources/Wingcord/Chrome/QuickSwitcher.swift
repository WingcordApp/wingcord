import AppKit
import SwiftUI
import WingcordCore

/// ⌘K — everywhere the account can go, one field and a list.
///
/// **Redesigned to Spotlight's shape** (docs/BETA3.md §7, his ask, 2026-11-19:
/// "redesigning the navigator, plus centering it … something cool nice"): a
/// big search field with its glass, two-line rows that lead with each place's
/// picture — the server's icon under a channel, a face for a person — a
/// selection in the room's accent, and a foot that teaches the five sigils by
/// name and can be clicked. Centred in the window by the presenter, at the
/// height that keeps the field still while the list grows.
///
/// **The lit row is this view's own state.** Reading it off the store would mean
/// a publication per arrow key, and every read of `quickSwitchSections` walks
/// the account and ranks it — so holding it here is the difference between an
/// arrow press re-laying-out one panel and re-ranking five thousand candidates.
struct QuickSwitcher: View {
    /// **A binding, not a value plus a setter.** The setter is the store's
    /// `setQuickSwitchText`, which starts the games request — and a stored
    /// closure property is a non-`Sendable` function value where `TextField`
    /// wants a main-actor-isolated one. Built in the presenter, where the store
    /// is, exactly as the toolbar's search field is.
    @Binding var text: String
    var sections: [QuickSwitchSection]
    var filter: QuickSwitchFilter?
    var isLoadingGames: Bool
    var pick: (QuickSwitchRow) -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion
    @Namespace private var selectionNamespace
    @FocusState private var isFocused: Bool
    @State private var selection = 0
    /// Where the pointer was when a row last took the selection from it — so
    /// rows sliding under a pointer that hasn't moved, as the list changes with
    /// typing, don't take the selection away from the top match.
    @State private var pointerAtLastHover: CGPoint? = NSEvent.mouseLocation

    /// Wide enough for a channel's name on the first line and its category
    /// and server on the second without either truncating on an ordinary
    /// account.
    static let width: CGFloat = 640
    /// Eight rows and a heading, which is where scanning stops and typing
    /// starts. Past that the list scrolls.
    static let maxListHeight: CGFloat = 400
    static let rowHeight: CGFloat = 48
    /// A row's picture: a server's icon, a face, a game's mark.
    static let tileSide: CGFloat = 32
    /// The field's band and the foot's, for the presenter's centring.
    static let fieldHeight: CGFloat = 60
    static let footHeight: CGFloat = 44
    /// The tallest the panel gets — what the presenter centres, so the field
    /// sits still while the list beneath it grows and shrinks.
    static var maxHeight: CGFloat { fieldHeight + maxListHeight + footHeight }
    private static let corner: CGFloat = 26

    private var rows: [QuickSwitchRow] { sections.flatMap(\.rows) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            list
            foot
        }
        .frame(width: Self.width)
        // A navigation control over the window, like Spotlight: `.regular`
        // glass, the HIG's default for a control over content.
        .glassEffect(.regular, in: shape)
        .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
        // **After the panel is in the window, not as it appears**: a focus
        // request made in `onAppear` lands while the materialize transition is
        // still inserting the field, and is dropped — the switcher opened with
        // nothing focused. `.task` runs once it is attached, as the DM menu's
        // field does.
        .task { isFocused = true }
        // The list is rebuilt by every keystroke, and a lit row that survived
        // into a different list is lighting somewhere nobody asked for.
        .onChange(of: rows) { _, new in
            selection = new.isEmpty ? 0 : min(selection, new.count - 1)
        }
        // A new search starts at its best answer, as Spotlight's does; the
        // pointer has to move to take the selection off it.
        .onChange(of: text) {
            selection = 0
            pointerAtLastHover = NSEvent.mouseLocation
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Quick switcher"))
    }

    private var shape: RoundedRectangle {
        .rect(cornerRadius: Self.corner, style: .continuous)
    }

    // MARK: The field

    /// **Spotlight's field**: a magnifying glass, then the words, large — the
    /// field *is* this panel's title and the only thing in it anybody types
    /// into. A narrowing sigil shows as a token before the words, so the mode
    /// is never something to remember being in; Escape's key sits at the end.
    private var field: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .accessibilityHidden(true)
            if let filter {
                FilterToken(filter: filter)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            TextField(prompt, text: words)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(InkColor.solid)
                .lineLimit(1)
                .focused($isFocused)
                // The keyboard, made sure of — see `QuickSwitchFocusAnchor`.
                .background { QuickSwitchFocusAnchor() }
                // A sigil at the start narrows, into the token — caught before
                // the field takes it, so the field never shows it at all.
                .onKeyPress(characters: Self.sigils, phases: .down) { press in
                    guard Self.split(text).words.isEmpty,
                          let narrowing = press.characters.first.flatMap(QuickSwitchFilter.init)
                    else { return .ignored }
                    text = String(narrowing.rawValue)
                    return .handled
                }
                // Backspace in an empty narrowed field takes the token away,
                // as a token field's does.
                .onKeyPress(keys: Self.backspaces, phases: .down) { _ in
                    guard filter != nil, Self.split(text).words.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.return) { commit() }
                .onKeyPress(.escape) { dismiss(); return .handled }
            if isLoadingGames {
                ProgressView().controlSize(.small)
            }
            KeyCap("esc")
        }
        .padding(.horizontal, Spacing.margin + 2)
        .frame(height: Self.fieldHeight)
        .animation(motion.hover, value: filter)
        .overlay(alignment: .bottom) { Divider().overlay(Ink.quaternary) }
    }

    /// **The field shows the words; the token shows the sigil.** Typed at the
    /// start, a sigil narrows the list and goes into the token before the
    /// field (`onKeyPress(characters:)`), so the narrowing isn't written twice;
    /// another sigil there narrows to that one instead.
    private var words: Binding<String> {
        Binding(
            get: { Self.split(text).words },
            set: { new in
                guard let narrowing = Self.split(text).filter else {
                    text = new
                    return
                }
                // A sigil the field may still be showing is the token's, not
                // part of the words.
                let typed = new.first == narrowing.rawValue ? String(new.dropFirst()) : new
                text = String(narrowing.rawValue) + typed
            }
        )
    }

    /// The Mac's delete key, which arrives as DEL (U+007F) rather than the
    /// backspace `KeyEquivalent.delete` names — both, so either way works.
    private static let backspaces: Set<KeyEquivalent> = [.delete, KeyEquivalent(Character(UnicodeScalar(127)))]

    /// The five sigils, for the key press that narrows.
    private static let sigils = CharacterSet(charactersIn: String(QuickSwitchFilter.allCases.map(\.rawValue)))

    /// The store's text as its narrowing and the words after it, as typed —
    /// not `QuickSwitchQuery.parse`'s folded needle, which is for matching.
    static func split(_ text: String) -> (filter: QuickSwitchFilter?, words: String) {
        let trimmed = text.drop { $0 == " " }
        guard let first = trimmed.first, let filter = QuickSwitchFilter(rawValue: first) else { return (nil, text) }
        return (filter, String(trimmed.dropFirst()))
    }

    /// What the field asks for, which changes with the sigil so the mode is
    /// never a state you have to remember being in.
    private var prompt: String {
        guard let filter else { return "Where would you like to go?" }
        return "Search \(filter.title.lowercased())"
    }

    // MARK: The list

    @ViewBuilder
    private var list: some View {
        if rows.isEmpty {
            empty
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            Section {
                                rows(of: section)
                            } header: {
                                if let title = section.title { heading(title) }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.snug)
                    .padding(.vertical, Spacing.snug)
                }
                .scrollIndicators(.automatic)
                .softScrollEdgesVertical()
                .frame(maxHeight: Self.maxListHeight)
                // **A ceiling, not a height.** `fixedSize` proposes nil, which
                // is what makes the scroll view report its content's height;
                // the frame above stops a long list growing past the cap.
                .fixedSize(horizontal: false, vertical: true)
                // **The selection travels; it does not cut** — `Motion.glassMorph`.
                .animation(motion.glassMorph, value: selection)
                .onChange(of: selection) { _, index in
                    guard rows.indices.contains(index) else { return }
                    withAnimation(motion.standard) { proxy.scrollTo(rows[index].id) }
                }
            }
        }
    }

    private func rows(of section: QuickSwitchSection) -> some View {
        // The flat index a row occupies, resolved once per section rather than
        // searched per row.
        let offset = sections
            .prefix { $0.id != section.id }
            .reduce(0) { $0 + $1.rows.count }

        return ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
            let position = offset + index
            let isSelected = position == selection
            QuickSwitchRowView(row: row, isSelected: isSelected)
                .id(row.id)
                .frame(height: Self.rowHeight)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Palette.accent.opacity(0.24))
                            .overlay {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1)
                            }
                            .matchedGeometryEffect(id: "quickswitch.selection", in: selectionNamespace)
                    }
                }
                .contentShape(.rect)
                .onHover { entered in
                    // Only a pointer that moved takes the selection.
                    let pointer = NSEvent.mouseLocation
                    guard entered, selection != position, pointer != pointerAtLastHover else { return }
                    pointerAtLastHover = pointer
                    selection = position
                }
                .onTapGesture { pick(row) }
        }
    }

    /// Sentence case and the secondary ink: a section names a group, quietly —
    /// shouting it in capitals over every place in it was the old look's noise.
    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.base + 2)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var empty: some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: isLoadingGames ? "gamecontroller" : emptySymbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Ink.secondary)
            Text(emptyLine)
                .font(.system(.body))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.margin * 2)
    }

    private var emptySymbol: String {
        QuickSwitchQuery.parse(text).isEmpty ? "clock.arrow.circlepath" : "magnifyingglass"
    }

    /// Three different nothings, and they are not the same news.
    private var emptyLine: String {
        if isLoadingGames { return "Looking for games…" }
        let query = QuickSwitchQuery.parse(text)
        if query.isEmpty {
            guard let filter else { return "Open a channel and it will show up here." }
            return "Start typing to search \(filter.title.lowercased())."
        }
        return "Nothing here matches “\(query.needle)”."
    }

    // MARK: The foot

    /// **The grammar, by name, and clickable.** The five sigils are the whole
    /// of the feature's depth and nothing else in the window teaches them, so
    /// each is shown with what it narrows to; a click narrows (or widens back),
    /// as typing the sigil does. The keys that move and open sit at the end.
    private var foot: some View {
        HStack(spacing: Spacing.tight) {
            ForEach(QuickSwitchFilter.allCases, id: \.self) { value in
                Button { toggle(value) } label: {
                    HStack(spacing: 5) {
                        Text(String(value.rawValue))
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                        Text(Self.shortName(value))
                            .font(.system(.caption, weight: .medium))
                    }
                    .foregroundStyle(filter == value ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.secondary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        filter == value ? Palette.accent.opacity(0.18) : Ink.quaternary.opacity(0.35),
                        in: .capsule
                    )
                }
                .buttonStyle(.plain)
                .help("Narrow to \(value.title.lowercased()) — or type \(String(value.rawValue))")
            }
            Spacer(minLength: Spacing.base)
            KeyCap("↑↓")
            Text("move")
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
            KeyCap("↩")
                .padding(.leading, Spacing.tight)
            Text("open")
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, Spacing.margin)
        .frame(height: Self.footHeight)
        .overlay(alignment: .top) { Divider().overlay(Ink.quaternary) }
        .animation(motion.hover, value: filter)
        // Every mode the chips name is reachable by typing, and VoiceOver is
        // already announcing the list row by row.
        .accessibilityHidden(true)
    }

    private static func shortName(_ filter: QuickSwitchFilter) -> String {
        switch filter {
        case .people: "People"
        case .textChannels: "Text"
        case .voiceChannels: "Voice"
        case .servers: "Servers"
        case .games: "Games"
        }
    }

    /// Narrows to `value`, or widens back where it was already narrowed, and
    /// keeps whatever was typed after the sigil.
    private func toggle(_ value: QuickSwitchFilter) {
        let current = Self.split(text)
        text = current.filter == value ? current.words : String(value.rawValue) + current.words
        isFocused = true
    }

    // MARK: Keys

    /// Wrapping, so holding a direction never dead-ends at either end of a list
    /// this short — the same rule the composer's lists keep.
    private func move(_ delta: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .handled }
        selection = ((selection + delta) % rows.count + rows.count) % rows.count
        return .handled
    }

    /// **Return with nothing to pick does nothing rather than closing.** A
    /// switcher that dismissed on an empty list would throw away what somebody
    /// typed at the exact moment they were about to correct it.
    private func commit() -> KeyPress.Result {
        guard rows.indices.contains(selection) else { return .handled }
        pick(rows[selection])
        return .handled
    }
}

// MARK: - The narrowing token

/// "# Text channels", before the field's words while a sigil narrows the list.
private struct FilterToken: View {
    var filter: QuickSwitchFilter

    var body: some View {
        HStack(spacing: 4) {
            Text(String(filter.rawValue))
                .font(.system(.callout, design: .monospaced, weight: .bold))
            Text(filter.title)
                .font(.system(.callout, weight: .semibold))
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.accent.opacity(0.18), in: .capsule)
        .fixedSize()
        .accessibilityLabel(Text("Narrowed to \(filter.title)"))
    }
}

// MARK: - A key

/// A key's cap — "esc", "↩", "↑↓" — drawn small, so the keys a panel answers
/// to are named where the hand is about to use them.
private struct KeyCap: View {
    var label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(.caption2, weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(Ink.quaternary.opacity(0.45), in: .rect(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Ink.quaternary, lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - One row

/// A place, a person or a game, in two lines: its picture, its name, and what
/// tells it from another of the same name — a channel's category and server, a
/// person's handle.
private struct QuickSwitchRowView: View {
    var row: QuickSwitchRow
    var isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.base + 2) {
            tile
            VStack(alignment: .leading, spacing: 1) {
                // **Full ink whether or not it is lit.** The pill marks the
                // selection; dimming every other name as well makes a list of
                // nine places read as one place and eight refusals.
                Text(row.title)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: Spacing.base)
            if row.mentionCount > 0 {
                MentionBadge(count: row.mentionCount)
            } else if row.isUnread {
                Circle()
                    .fill(Ink.primary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            if isSelected {
                KeyCap("↩")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One node with a plain label — §2.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The second line: a channel's category and server, a person's handle,
    /// or what kind of thing this is.
    private var detail: String? {
        let parts = [row.subtitle, row.label.map(Self.readable), row.trailing].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A category as it reads in a sentence rather than shouted: Discord
    /// draws them in capitals, and most servers name them that way too.
    private static func readable(_ category: String) -> String {
        guard category == category.uppercased(), category.contains(where: \.isLetter) else { return category }
        return category.capitalized
    }

    private var label: String {
        var parts = [row.title]
        if let subtitle = row.subtitle { parts.append(subtitle) }
        if let label = row.label { parts.append(label) }
        if let trailing = row.trailing { parts.append("in \(trailing)") }
        if row.mentionCount > 0 { parts.append("\(row.mentionCount) mentions") }
        return parts.joined(separator: ", ")
    }

    /// The row's picture. A channel leads with its **server's** icon and wears
    /// its own kind — #, a speaker, a megaphone — as a badge on the corner; a
    /// person is their face with their presence; a server or a game is its mark.
    @ViewBuilder
    private var tile: some View {
        let side = QuickSwitcher.tileSide
        if let symbolName = row.symbolName {
            ZStack(alignment: .bottomTrailing) {
                if row.serverIconURL != nil || row.serverMonogram != nil {
                    ApplicationMark(url: row.serverIconURL, monogram: Self.tileMonogram(row.serverMonogram), side: side)
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Ink.quaternary.opacity(0.5))
                        .frame(width: side, height: side)
                }
                Image(symbol: symbolName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .frame(width: 17, height: 17)
                    .background(.regularMaterial, in: .circle)
                    .overlay { Circle().strokeBorder(Ink.quaternary, lineWidth: 0.5) }
                    .offset(x: 4, y: 4)
            }
            .frame(width: side, height: side)
        } else if row.isPerson {
            AvatarView(url: row.iconURL, monogram: row.monogram ?? "?", side: side)
                .overlay(alignment: .bottomTrailing) {
                    if let status = row.status {
                        PresenceDot(status: status, side: side * 0.38)
                            .offset(x: 1, y: 1)
                    }
                }
        } else if row.iconURL != nil || row.monogram != nil {
            ApplicationMark(url: row.iconURL, monogram: Self.tileMonogram(row.monogram), side: side)
        } else {
            Color.clear.frame(width: side, height: side)
        }
    }

    /// At most three letters on a 32-point tile: a server's initials can run to
    /// six with punctuation ("K|CCam"), which wrapped inside the tile.
    private static func tileMonogram(_ monogram: String?) -> String {
        guard let monogram, !monogram.isEmpty else { return "?" }
        let letters = monogram.filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty ? String(monogram.prefix(2)) : String(letters.prefix(3))
    }
}

/// The red count beside a channel with something addressed to the reader in it.
///
/// The same token and the same face every other badge in the app uses — a
/// switcher that invented its own would be the one place a mention looks
/// different.
private struct MentionBadge: View {
    var count: Int

    var body: some View {
        Text(count > 99 ? "99+" : String(count))
            .font(Typeface.badge)
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.tight)
            .frame(minWidth: 16, minHeight: 16)
            .background(Palette.unreadBadge, in: .capsule)
            .accessibilityHidden(true)
    }
}

// MARK: - The keyboard, made sure of

/// Puts the keyboard in the switcher's field, and checks that it stayed there.
///
/// **`isFocused = true` is one request, and SwiftUI drops it without a word
/// when the field is not ready to take it.** The panel arrives through a
/// transition, so its field is put into the window a little after the panel
/// appears; a request that lands in between is lost, and how wide that gap is
/// depends on how busy the main thread is — which is why the switcher opened
/// with the keyboard still in the composer *sometimes*, and more often on a
/// busy account. Moving the request from `onAppear` to `.task` narrowed the gap
/// and did not close it.
///
/// So the field is found in AppKit — the text field lying where this view
/// lies, behind it — and made first responder directly, a turn after the panel
/// is in the window and again over the next half second for as long as it has
/// not held. After that it stops: the keyboard is the reader's to move.
private struct QuickSwitchFocusAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ nsView: Anchor, context: Context) {}

    final class Anchor: NSView {
        private var attempts: Task<Void, Never>?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attempts?.cancel()
            attempts = nil
            guard window != nil else { return }
            attempts = Task { [weak self] in
                // A turn first, so the field is in the window; then while the
                // panel is still settling.
                for wait in [0, 50, 100, 150, 200] {
                    if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) } else { await Task.yield() }
                    guard !Task.isCancelled, let self else { return }
                    self.focusField()
                }
            }
        }

        /// The text field this view sits behind: the one whose box in the
        /// window meets this one's.
        private func field(in window: NSWindow) -> NSTextField? {
            guard let content = window.contentView else { return nil }
            let mine = convert(bounds, to: nil)
            var found: NSTextField?
            func search(_ view: NSView) {
                guard found == nil else { return }
                if let candidate = view as? NSTextField, candidate.isEditable,
                   candidate.convert(candidate.bounds, to: nil).intersects(mine) {
                    found = candidate
                    return
                }
                for child in view.subviews { search(child) }
            }
            search(content)
            return found
        }

        private func focusField() {
            guard let window, let field = field(in: window) else { return }
            // Already there: its field editor is the first responder.
            if window.firstResponder === field { return }
            if let editor = window.firstResponder as? NSTextView, editor.delegate === field { return }
            window.makeFirstResponder(field)
        }
    }
}
