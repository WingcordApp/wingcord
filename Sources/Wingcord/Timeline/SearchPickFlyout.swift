import SwiftUI
import WingcordCore

/// The flyout behind a filter's "Add": a search field over the people (or the
/// channels) worth offering, each a row that ticks on and off.
///
/// **It stays open while picking**, so several people go in at one go, and
/// closes on a click outside. The field has the keyboard as it appears; ↑ and ↓
/// move through the rows and Return ticks the one lit.
struct SearchPickFlyout: View {
    var prompt: String
    var options: [SearchFilterOption]
    var chosen: Set<UInt64>
    var emptyText: String
    var toggle: (UInt64) -> Void

    @Environment(\.motion) private var motion
    @State private var query = ""
    @State private var highlighted = 0

    static let rowHeight: CGFloat = 38
    private static let rowGap: CGFloat = 2
    private static let listLimit: CGFloat = 300

    /// The list's height for `count` rows, up to the limit.
    ///
    /// **Counted, not left to the scroll view**: a scroll view takes all the
    /// height it is allowed, so a search down to one name left the flyout as
    /// tall as the whole list.
    private static func listHeight(rows count: Int) -> CGFloat {
        min(listLimit, CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * rowGap)
    }

    private var matches: [SearchFilterOption] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return options }
        return options.filter {
            $0.title.localizedStandardContains(words) || ($0.detail?.localizedStandardContains(words) ?? false)
        }
    }

    var body: some View {
        let matches = matches
        VStack(alignment: .leading, spacing: Spacing.base) {
            SearchField(
                prompt: prompt,
                text: $query,
                onMove: { step in
                    guard !matches.isEmpty else { return }
                    highlighted = min(max(highlighted + step, 0), matches.count - 1)
                },
                onSubmit: {
                    guard matches.indices.contains(highlighted) else { return }
                    toggle(matches[highlighted].id)
                },
                takesFocus: true
            )
            if matches.isEmpty {
                Text(options.isEmpty ? emptyText : "No matches")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.tight)
                    .padding(.vertical, Spacing.base)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Self.rowGap) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, option in
                                SearchPickRowView(
                                    option: option,
                                    isChosen: chosen.contains(option.id),
                                    isHighlighted: index == highlighted,
                                    pick: {
                                        highlighted = index
                                        toggle(option.id)
                                    }
                                )
                                .id(option.id)
                            }
                        }
                    }
                    .frame(height: Self.listHeight(rows: matches.count))
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: highlighted) { _, index in
                        guard matches.indices.contains(index) else { return }
                        withAnimation(motion.standard) { proxy.scrollTo(matches[index].id, anchor: nil) }
                    }
                }
            }
        }
        .padding(Spacing.snug)
        .frame(width: 300)
        .onChange(of: query) { highlighted = 0 }
    }
}

/// One person or channel in the flyout.
private struct SearchPickRowView: View {
    var option: SearchFilterOption
    var isChosen: Bool
    var isHighlighted: Bool
    var pick: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: Spacing.base) {
                if let avatarURL = option.avatarURL {
                    AvatarView(url: avatarURL, monogram: option.monogram ?? "?", side: 26)
                } else if let symbolName = option.symbolName {
                    Image(symbol: symbolName)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 26, height: 26)
                } else {
                    AvatarView(url: nil, monogram: option.monogram ?? "?", side: 26)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.title)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if let detail = option.detail, detail != option.title {
                        Text(detail)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(.body))
                    .foregroundStyle(isChosen ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: SearchPickFlyout.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(isHighlighted || isHovering ? Palette.hoverFill : .clear)
            }
            .contentShape(.rect(cornerRadius: Radius.chip))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}
