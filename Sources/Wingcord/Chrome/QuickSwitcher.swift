import SwiftUI
import WingcordCore

/// ⌘K — everywhere the account can go, one field and a list.
///
/// **Regular glass over a dimmed window** — §4's default for a control floating
/// over content. The scrim under the panel is because switching is a modal act:
/// it dims what it interrupts.
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

    /// Wide enough for a channel name, its category and its server on one line
    /// without any of the three truncating on an ordinary account. Narrower and
    /// the server column — the whole answer to "which #general is this" — is the
    /// first thing to go.
    private static let width: CGFloat = 560
    /// Eight rows and a heading, which is where scanning stops and typing
    /// starts. Past that the list scrolls.
    private static let maxListHeight: CGFloat = 330
    private static let rowHeight: CGFloat = 38

    private var rows: [QuickSwitchRow] { sections.flatMap(\.rows) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            list
            protip
        }
        .frame(width: Self.width)
        // A navigation control over the window, like Spotlight: `.regular`
        // glass, the HIG's default for a control over content.
        .glassEffect(.regular, in: shape)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Quick switcher"))
    }

    /// `Radius.glass` — the house radius for a floating glass rect. `Radius.card`
    /// belongs to the two surfaces that are *lifted objects* rather than panels,
    /// and this is a panel.
    private var shape: RoundedRectangle {
        .rect(cornerRadius: Radius.glass, style: .continuous)
    }

    // MARK: The field

    /// **The panel's own head, with no box around it.**
    ///
    /// This app has exactly two field idioms and neither is a stroked
    /// rectangle. One is a capsule with `Palette.surfaceRaised` behind it and a
    /// still-life specular edge — the forum's search, the forward sheet's — and
    /// the other is the composer's, which is *bare text on a glass plate*
    /// because the plate is already the field's boundary. A panel that is itself
    /// one sheet of glass is the composer's case: the surface is the boundary,
    /// and drawing a second one inside it is a box inside a box.
    ///
    /// A capsule here would also mean an opaque fill across the top third of the
    /// one surface in this window whose whole character is what lenses through
    /// it. The hairline under the field is what separates the head from the
    /// list, and it is the same hairline the footer uses.
    private var field: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            // `.title3` is the app's own sheet-title size. The field *is* this
            // panel's title, and it is the only thing in it anybody types into.
            .font(.system(.title3))
            .foregroundStyle(InkColor.solid)
            .lineLimit(1)
            .focused($isFocused)
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.return) { commit() }
            .onKeyPress(.escape) { dismiss(); return .handled }
            .padding(.horizontal, Spacing.margin)
            .padding(.vertical, Spacing.snug)
            .overlay(alignment: .bottom) { Divider().overlay(Ink.quaternary) }
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
                    // No `GlassEffectContainer`: a container promotes its glass
                    // elements above ordinary siblings and renders them itself
                    // — §4 rule 4 — so a pill living in a row's background would
                    // be lifted above the name it sits behind. There is no glass
                    // in here to contain; the pill is a tinted region.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Section {
                                rows(of: section)
                            } header: {
                                if let title = section.title { heading(title) }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, Spacing.base)
                }
                .scrollIndicators(.automatic)
                .softScrollEdgesVertical()
                .frame(maxHeight: Self.maxListHeight)
                // **A ceiling, not a height.** A `ScrollView` in a stack is
                // greedy vertically, so a two-row answer reserved the whole cap
                // and the panel opened with three hundred points of void under
                // it. `fixedSize` proposes nil, which is what makes the scroll
                // view report its *content's* height — §1's rule, and the frame
                // above is what stops a long list growing past the cap.
                .fixedSize(horizontal: false, vertical: true)
                // **The selection pill travels; it does not cut.** That is
                // exactly what `Motion.glassMorph` names — see `Motion.swift`,
                // whose own comment gives "the selection pill travelling from
                // one channel row to the next" as the class's case. Declared by
                // the container that should animate, never wrapped around the
                // write: a `withAnimation` there would animate every view that
                // happened to re-lay-out while it ran.
                .animation(motion.glassMorph, value: selection)
                .onChange(of: selection) { _, index in
                    guard rows.indices.contains(index) else { return }
                    // No anchor: SwiftUI then scrolls the minimum amount to
                    // bring the row in, which is right in both directions.
                    withAnimation(motion.standard) { proxy.scrollTo(rows[index].id) }
                }
            }
        }
    }

    private func rows(of section: QuickSwitchSection) -> some View {
        // The flat index a row occupies, resolved once per section rather than
        // searched per row — `firstIndex(of:)` inside the loop would make
        // drawing the list quadratic in the number of rows it shows.
        let offset = sections
            .prefix { $0.id != section.id }
            .reduce(0) { $0 + $1.rows.count }

        return ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
            let position = offset + index
            QuickSwitchRowView(row: row, isSelected: position == selection)
                .id(row.id)
                .matchedSelection(isSelected: position == selection, namespace: selectionNamespace)
                .frame(height: Self.rowHeight)
                .contentShape(.rect)
                .onHover { if $0, selection != position { selection = position } }
                .onTapGesture { pick(row) }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Typeface.sectionHeader)
            .foregroundStyle(Ink.tertiary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.base)
            .padding(.top, Spacing.snug)
            .padding(.bottom, Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var empty: some View {
        HStack(spacing: Spacing.base) {
            if isLoadingGames {
                ProgressView().controlSize(.small)
            }
            Text(emptyLine)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }

    /// Three different nothings, and they are not the same news.
    ///
    /// A mode with nothing typed is waiting; a search with no hits is an answer;
    /// an untouched switcher on a session with no history is neither, and saying
    /// "nothing matches" there would be a refusal to a question nobody asked.
    private var emptyLine: String {
        if isLoadingGames { return "Looking for games…" }
        let query = QuickSwitchQuery.parse(text)
        if query.isEmpty {
            guard let filter else { return "Open a channel and it will show up here." }
            return "Start typing to search \(filter.title.lowercased())."
        }
        return "Nothing here matches “\(query.needle)”."
    }

    // MARK: The footer

    /// The grammar, stated where somebody will read it.
    ///
    /// **Kept, because the sigils are the whole of the feature's depth and
    /// nothing else in the window teaches them.** It is one line at the foot of
    /// a panel that is only ever open for a second or two.
    private var protip: some View {
        HStack(spacing: Spacing.base) {
            Text("Narrow with")
                .font(Typeface.rowSubtitle)
                .foregroundStyle(Ink.tertiary)
            // **Monospaced text, not keycaps.** The settings window's shortcut
            // rows are the app's one precedent for naming a key and they draw it
            // as `Text(keys).monospaced()` at `Ink.secondary`. A row of little
            // boxes would be a vocabulary this app has nowhere else.
            HStack(spacing: Spacing.snug) {
                ForEach(QuickSwitchFilter.allCases, id: \.self) { value in
                    Text(String(value.rawValue))
                        .foregroundStyle(
                            filter == value ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary)
                        )
                }
            }
            .font(Typeface.rowSubtitle.monospaced())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.base)
        .overlay(alignment: .top) { Divider().overlay(Ink.quaternary) }
        .animation(motion.hover, value: filter)
        // The sigils are a hint about typing, and every mode they name is
        // reachable by typing. A second reading of five punctuation marks is
        // noise in a list VoiceOver is already announcing row by row.
        .accessibilityHidden(true)
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

// MARK: - One row

/// A place, a person or a game, in one shape.
///
/// Four slots, and each of them is drawn only where it has something: a glyph or
/// a picture, the name, the quiet text beside it, and the server at the far end.
private struct QuickSwitchRowView: View {
    var row: QuickSwitchRow
    var isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            leading
            // **Full ink whether or not it is lit.** The travelling pill is
            // what marks the selection; dimming every other name as well makes
            // a list of nine places read as one place and eight refusals.
            Text(row.title)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.system(.body))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            if row.mentionCount > 0 {
                MentionBadge(count: row.mentionCount)
            }
            if let label = row.label {
                Text(label.uppercased())
                    .font(Typeface.categoryHeader)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-2)
            }
            Spacer(minLength: Spacing.base)
            if let trailing = row.trailing {
                Text(trailing)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-3)
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One node with a plain label — §2. A row's text is four `Text`s and
        // `.combine` would resolve each of them in order to merge it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var label: String {
        var parts = [row.title]
        if let subtitle = row.subtitle { parts.append(subtitle) }
        if let trailing = row.trailing { parts.append("in \(trailing)") }
        if row.mentionCount > 0 { parts.append("\(row.mentionCount) mentions") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var leading: some View {
        if let symbolName = row.symbolName {
            Image(symbol: symbolName)
                .font(.system(.callout))
                .foregroundStyle(Ink.tertiary)
                .frame(width: Metrics.avatarRow, height: Metrics.avatarRow)
        } else if row.isPerson {
            AvatarView(url: row.iconURL, monogram: row.monogram ?? "?", side: Metrics.avatarRow)
                .overlay(alignment: .bottomTrailing) {
                    if let status = row.status {
                        PresenceDot(status: status, side: Metrics.avatarRow * 0.38)
                            .offset(x: 1, y: 1)
                    }
                }
        } else if row.iconURL != nil || row.monogram != nil {
            ApplicationMark(
                url: row.iconURL,
                monogram: row.monogram ?? "?",
                side: Metrics.avatarRow
            )
        }
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
