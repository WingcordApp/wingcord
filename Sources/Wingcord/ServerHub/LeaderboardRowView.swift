import SwiftUI

/// One place on a leaderboard, laid out as Discord's row (`ti`, `.row_Ly3Qke`):
/// the place — a medal for the first three — the face, the name in its own
/// face and colour over "Last played …", the value, and the games behind it
/// where the card is wide enough for them.
struct LeaderboardRowView: View {
    var row: LeaderboardCardModel.Row
    /// Discord hides the games column on a card narrower than 450 points
    /// (`@container (max-width: 450px)`), which is the page's side column.
    var showsGames: Bool

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.base) {
            rank
            AvatarView(url: row.avatarURL, monogram: row.isHidden ? "" : row.monogram, side: ServerHubMetrics.leaderboardAvatar)
            VStack(alignment: .leading, spacing: 1) {
                LeaderboardName(row: row, size: 14)
                if let lastPlayed = row.lastPlayed {
                    Text(lastPlayed)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                Label(row.value, systemImage: row.valueSymbol)
                    .labelStyle(LeaderboardValueLabelStyle())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .monospacedDigit()
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                }
            }
            .fixedSize()
            if showsGames {
                LeaderboardGamesStack(games: row.games, more: row.moreGames)
                    .frame(width: 80, alignment: .trailing)
                    .help(row.playedSummary ?? "")
            }
        }
        .padding(Spacing.base)
        .background { ground }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityElement(children: .combine)
    }

    /// A medal for the first three, a number after (`ta`).
    @ViewBuilder
    private var rank: some View {
        if row.rank <= 3 {
            LeaderboardMedal(rank: row.rank)
        } else {
            Text("\(row.rank)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
                .frame(width: PodiumPlace.medalSide)
                .accessibilityLabel(Text("Rank \(row.rank)"))
        }
    }

    /// The reader's own row: Discord's blurple fading out to the right over a
    /// raised surface, with a hairline (`.rowCurrentUser`); anyone else's
    /// lights under the pointer.
    @ViewBuilder
    private var ground: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row)
        if row.isReader {
            shape
                .fill(
                    LinearGradient(
                        colors: [Palette.accent.opacity(isHovering ? 0.18 : 0.12), Palette.accent.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .background(shape.fill(Palette.selectionFill))
                .overlay(shape.strokeBorder(Palette.edge, lineWidth: 1))
        } else {
            shape.fill(isHovering ? Palette.hoverFill : .clear)
        }
    }
}
