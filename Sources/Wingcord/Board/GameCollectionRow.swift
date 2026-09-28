import SwiftUI

/// "Game Collection" on the popout: a label, up to four game marks, and how
/// many more there are — Discord's breadcrumb (module `657538`).
///
/// **A destination, not a statement.** Pressing it opens the board, which is
/// why the whole card is one control rather than a label beside four clickable
/// marks. Four marks each opening a different game would put four decisions on
/// a card whose job is to summarise.
///
/// **The count rides the last mark**, which dims under it: Discord never draws
/// a fifth slot for the number.
struct GameCollectionRow: View {
    var collection: GameCollection
    var ground: ProfileGround
    /// The column beside a conversation, where Discord sets the label a size up.
    var isColumn = false
    var openBoard: () -> Void

    private static let side = GameArt.markSide
    /// Discord's `--radius-xs`.
    private static let corner: CGFloat = 4

    var body: some View {
        ProfilePanelButton(ground: ground, action: openBoard) {
            HStack(spacing: Spacing.base) {
                Text("Game Collection")
                    .font(.system(isColumn ? .subheadline : .caption, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)

                Spacer(minLength: Spacing.base)

                HStack(spacing: Spacing.tight) {
                    ForEach(Array(collection.covers.enumerated()), id: \.element.id) { index, game in
                        mark(game, carriesCount: index == collection.covers.count - 1)
                    }
                }
            }
            .frame(height: Self.side)
            .padding(Spacing.base)
        }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Opens their board"))
    }

    /// One mark on its plate: `--background-mod-strong`, which a themed card
    /// makes white at 24 % on dark and black at 32 % on light.
    private func mark(_ game: BoardGame, carriesCount: Bool) -> some View {
        let counted = carriesCount && collection.overflow > 0
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        return RemoteImage(url: game.coverURL, side: Self.side, bucket: .artwork) {
            Color.clear
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: Self.side, height: Self.side)
        .background(markPlate, in: shape)
        .clipShape(shape)
        .opacity(counted ? 0.5 : 1)
        .overlay {
            if counted {
                Text("+\(collection.overflow)")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: Self.side, height: Self.side)
                    .background(.black.opacity(0.6), in: shape)
            }
        }
    }

    private var markPlate: Color {
        guard ground.accent != nil else { return Palette.edgeStrong }
        return ground.wantsDarkInk ? .black.opacity(0.32) : .white.opacity(0.24)
    }

    private var accessibilityLabel: String {
        let total = collection.covers.count + collection.overflow
        return total == 1 ? "Game collection, 1 game" : "Game collection, \(total) games"
    }
}
