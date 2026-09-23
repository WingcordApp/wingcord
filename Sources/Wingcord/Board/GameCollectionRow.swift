import SwiftUI

/// "Game Collection" on the small card: a label, a few covers, and how many more
/// there are.
///
/// **A destination, not a statement.** It is the only thing on the card that
/// says a person has a board at all, and pressing it opens that board — which is
/// why the whole row is one control rather than a label beside four clickable
/// covers. Four covers each opening a different game would put four decisions on
/// a card whose job is to summarise.
///
/// The same object the mutual-servers row is, one line down, and deliberately:
/// they answer the same shape of question and two arrangements for one shape is
/// two places for the chevron to drift.
struct GameCollectionRow: View {
    var collection: GameCollection
    /// The card's own surface, so this panel is the same one every other panel
    /// on the profile is.
    ///
    /// **It used to be a hard-coded `white 0.04`**, which is why it and the
    /// activity card under it drew as two different panels on the same themed
    /// card — one a wash of white, the other Discord's own
    /// `--profile-gradient-section-box`. That token is measured (black at 45 %
    /// under every dark theme, white at 45 % under the light one) and
    /// `ProfileGround.panelFill` already carries it; the comment on
    /// `CurrentActivityCard` has said all along that the Game Collection and
    /// In-voice cards take the same fill, and this was the one that did not.
    var ground: ProfileGround
    /// What pressing it does. The card already owns the one route to the full
    /// profile — the avatar uses it too — so this takes that closure rather than
    /// reaching for the store and re-deriving an anchor the card already has.
    var openBoard: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    private static let markSide: CGFloat = GameArt.markSide

    var body: some View {
        Button(action: openBoard) {
            HStack(spacing: Spacing.base) {
                Text("Game Collection")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)

                Spacer(minLength: Spacing.base)

                HStack(spacing: 5) {
                    ForEach(collection.covers) { game in
                        GameMark(game: game, side: Self.markSide)
                    }
                    if collection.overflow > 0 {
                        overflowChip
                    }
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(isHovered ? AnyShapeStyle(Palette.hoverFill) : ground.panelFill)
            }
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering != isHovered else { return }
            isHovered = hovering
        }
        .animation(motion.hover, value: isHovered)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Opens their board"))
    }

    /// The count of what did not fit.
    ///
    /// A square the size of a cover rather than a pill, so the row stays one
    /// strip of five slots of which the last happens to be a number — and it
    /// takes the covers' own corner, so the five slots are one shape.
    private var overflowChip: some View {
        Text("+\(collection.overflow)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(InkColor.secondary)
            .frame(width: Self.markSide, height: Self.markSide)
            .background {
                RoundedRectangle(cornerRadius: Self.markSide * 0.22, style: .continuous)
                    .fill(Palette.surfaceRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Self.markSide * 0.22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
    }

    private var accessibilityLabel: String {
        let total = collection.covers.count + collection.overflow
        return total == 1 ? "Game collection, 1 game" : "Game collection, \(total) games"
    }
}
