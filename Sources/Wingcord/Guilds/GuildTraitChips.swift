import SwiftUI
import WingcordCore

/// One of the words a server describes itself with, in its chip — the server
/// card's squircle: its emoji, and the word.
struct GuildTraitChip: View {
    var trait: GuildTrait
    /// Whether the word may wrap: in the flyout of the rest, as in Discord's
    /// tooltip (`ellipsize: false`). On a card it stays on one line.
    var wraps = false

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if let emoji = trait.emoji {
                ExpressionGlyph(emoji: emoji, side: 12)
            }
            Text(trait.label)
                .font(.system(.caption2))
                .foregroundStyle(InkColor.primary)
                .lineLimit(wraps ? nil : 1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .plainChip(in: .rect(cornerRadius: 8))
    }
}

/// Discord's "+ N more" (`vGclWm`): a chip like the traits it stands for,
/// which opens the rest in a flyout.
///
/// **On a press.** Discord's opens on hover, as a tooltip (`3666`'s `g2`);
/// Alex asked for the press (DESIGN-NOTES §0, 2026-10-07).
struct MoreTraitsChip: View {
    var traits: [GuildTrait]

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            Text("+ \(traits.count) more")
                .font(.system(.caption2))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .plainChip(in: .rect(cornerRadius: 8))
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            GuildTraitsFlyout(traits: traits)
        }
    }
}

/// The traits a card had no room for, as Discord's tooltip lays them: chips
/// that wrap, four points apart (`.tooltip__3ff92{flex-wrap:wrap;gap:4px}`),
/// at a tooltip's width — the one `GuildMarkFlyout` keeps.
struct GuildTraitsFlyout: View {
    var traits: [GuildTrait]

    var body: some View {
        CappedWidth(max: GuildMarkFlyout.maxWidth) {
            FlowLayout(spacing: Spacing.tight) {
                ForEach(traits) { GuildTraitChip(trait: $0, wraps: true) }
            }
        }
        .padding(Spacing.snug)
        // The popover's glass is the body; a second ground would frost it.
        .presentationBackground(.clear)
    }
}
