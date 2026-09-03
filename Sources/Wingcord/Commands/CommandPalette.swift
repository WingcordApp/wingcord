import SwiftUI
import WingcordCore

/// The list that opens over the transcript when a draft begins with `/`.
///
/// **The same surface as the emoji completion list, one size up.** Both are
/// flyouts that grow upward out of the composer as the reader types, both are
/// keyboard-first, and both take the composer's own `.regular` glass so the two
/// read as one object rather than as a panel resting on a bar. What differs is
/// what a row has to say: an emoji is a name and a picture, and a command is a
/// name, a parameter list, a sentence and whose bot it is.
///
/// **No application rail.** Discord draws one down the left of its list. This
/// searches the application's name instead — typing `esm` narrows to esmBot's
/// commands — because a rail is a pointer affordance bolted to a surface that is
/// otherwise entirely keyboard-driven, and because a rail inside a flyout the
/// width of a composer costs a column the descriptions need.
///
/// **The selection is a travelling pill in a shared namespace**, exactly as the
/// completion list's is: one shape matched across the rows rather than a fill
/// appearing and disappearing per row. It is a tinted region *inside* the
/// panel's material and not a second glass body on it — `INVARIANTS.md` §4
/// rule 2.
struct CommandPalette: View {
    var query: String
    var sections: [CommandSection]
    var selection: Int
    var onPick: (CommandRow) -> Void
    var onHover: (Int) -> Void

    @Environment(\.motion) private var motion
    @Namespace private var selectionNamespace

    /// Tall enough for a section heading and four rows, which is the point where
    /// a reader stops scanning and starts typing. Past that the list scrolls.
    private static let maxHeight: CGFloat = 268
    private static let rowHeight: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            list
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// What the list is answering.
    ///
    /// The query is repeated back for the reason the emoji list repeats its
    /// shortcode: the list is derived from the draft, and a reader who typed
    /// `/base64 dec` needs to see which part of it was taken.
    private var header: some View {
        Text(query.isEmpty ? "COMMANDS" : "MATCHING  /\(query)")
            .font(Typeface.sectionHeader)
            .foregroundStyle(Ink.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Spacing.snug)
            .padding(.top, Spacing.snug)
            .padding(.bottom, Spacing.base)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var list: some View {
        if sections.isEmpty {
            empty
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // No `GlassEffectContainer` around these rows. A container
                    // PROMOTES its glass elements above ordinary siblings and
                    // renders them itself — §4 rule 4 — so a pill living in a
                    // row's `.background` would be lifted above the icon and the
                    // name it is meant to sit behind. There is no glass in here
                    // to contain anyway; the pill is a tinted region.
                    //
                    // **The headings are not pinned.** A pinned header over a
                    // `.regular` glass panel needs a material of its own to stop
                    // the rows showing through it, and a material inside glass
                    // is glass on glass — §4 rule 2. With six sections in a
                    // 268-point scroll view there is nothing a pin would buy.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Section {
                                rows(of: section)
                            } header: {
                                sectionHeader(section)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.base)
                    .padding(.bottom, Spacing.base)
                }
                .scrollIndicators(.never)
                .softScrollEdgesVertical()
                .frame(maxHeight: Self.maxHeight)
                // The keyboard moves the selection; the list has to follow it or
                // holding Down walks off the bottom into nothing.
                .onChange(of: selection) { _, index in
                    guard let id = flatRows.indices.contains(index) ? flatRows[index].id : nil
                    else { return }
                    // No anchor: SwiftUI then scrolls the minimum amount to
                    // bring the row in, which is right in both directions. A
                    // fixed anchor drags the list on every step in one of them.
                    withAnimation(motion.standard) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var flatRows: [CommandRow] { sections.flatMap(\.rows) }

    private func rows(of section: CommandSection) -> some View {
        // The flat index a row occupies, resolved once per section rather than
        // searched per row: `firstIndex(of:)` inside the loop would make drawing
        // the list quadratic in the number of commands it shows.
        let offset = sections
            .prefix { $0.id != section.id }
            .reduce(0) { $0 + $1.rows.count }

        return ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
            let position = offset + index
            CommandPaletteRow(row: row, isSelected: position == selection)
                .id(row.id)
                .matchedSelection(
                    isSelected: position == selection,
                    namespace: selectionNamespace
                )
                .frame(height: Self.rowHeight)
                .contentShape(.rect)
                .onHover { if $0 { onHover(position) } }
                .onTapGesture { onPick(row) }
        }
    }

    /// Whose commands these are: the application's mark and name, or a clock
    /// over the account's own most-used.
    private func sectionHeader(_ section: CommandSection) -> some View {
        HStack(spacing: Spacing.base) {
            if section.isFrequent {
                Image(systemName: "clock")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: Metrics.commandRowIcon, height: Metrics.commandRowIcon)
            } else {
                ApplicationMark(
                    url: section.iconURL,
                    monogram: String(section.title.prefix(1)).uppercased(),
                    side: Metrics.commandRowIcon
                )
            }
            Text(section.title)
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.tight)
        .padding(.vertical, Spacing.tight)
        .padding(.top, Spacing.base)
        .accessibilityAddTraits(.isHeader)
    }

    private var empty: some View {
        Text(query.isEmpty ? "No commands here" : "No commands match “/\(query)”")
            .font(.system(.subheadline))
            .foregroundStyle(Ink.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.snug)
    }
}

// MARK: - One row

/// `/name` with its parameters, the sentence under it, and whose bot it is.
///
/// The parameter hint sits **beside** the name rather than under it: it is part
/// of what the command is called from the reader's point of view — `/8ball
/// question` — and putting it on the description's line would make it read as
/// prose.
private struct CommandPaletteRow: View {
    var row: CommandRow
    var isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.snug) {
            ApplicationMark(
                url: row.iconURL,
                monogram: row.monogram,
                side: Metrics.commandRowIcon
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                    Text("/\(row.command.name)")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary))
                        .lineLimit(1)
                    if !row.hint.isEmpty {
                        Text(row.hint)
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(Ink.quaternary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: Spacing.base)
                    // The application's name, trailing. Four bots in the
                    // captured account register a `/help`, and this column is
                    // what tells them apart at a glance inside Frequently Used,
                    // where the section heading cannot.
                    Text(row.applicationName)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(Ink.quaternary)
                        .lineLimit(1)
                        .layoutPriority(-2)
                }
                if !row.command.summary.isEmpty {
                    Text(row.command.summary)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        // The description only where there is one. An empty hint is a hint
        // VoiceOver still announces the pause for.
        .accessibilityLabel(Text("/\(row.command.name), \(row.applicationName)"))
        .accessibilityHint(row.command.summary.isEmpty ? Text("") : Text(row.command.summary))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Shared pieces

/// An application's icon, with a monogram behind it until the artwork lands.
///
/// A rounded rectangle rather than a circle, for the reason `ActivityIcon` is
/// one: these are application icons, and every platform that draws one draws it
/// as a squircle. A circle here would read as a person.
struct ApplicationMark: View {
    var url: URL?
    var monogram: String
    var side: CGFloat

    var body: some View {
        RemoteImage(url: url, side: side) {
            Text(monogram)
                .font(.system(size: side * 0.42, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: side, height: side)
                .background(Palette.surfaceRaised)
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: side * 0.28, style: .continuous))
        .accessibilityHidden(true)
    }
}

extension View {
    /// The one travelling selection pill, shared by the palette and the option
    /// list so a command and its choices are marked the same way.
    ///
    /// A constant id, because there is only ever a single selection — giving
    /// each row its own would make the mark cut rather than travel.
    func matchedSelection(isSelected: Bool, namespace: Namespace.ID) -> some View {
        background {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Palette.selectionFill)
                    .matchedGeometryEffect(id: "command.selection", in: namespace)
            }
        }
    }
}
