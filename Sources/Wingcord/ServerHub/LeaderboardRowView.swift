import SwiftUI

/// One place on a leaderboard: rank, face, name and last game, the value, and
/// the games behind it.
struct LeaderboardRowView: View {
    var row: LeaderboardCardModel.Row

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.snug) {
            LeaderboardRankBadge(rank: row.rank)
            AvatarView(url: row.avatarURL, monogram: row.isHidden ? "" : row.monogram, side: ServerHubMetrics.leaderboardAvatar)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(row.nameColor.map { AnyShapeStyle(Color(hex: $0)) } ?? AnyShapeStyle(Ink.primary))
                    .lineLimit(1)
                if let lastPlayed = row.lastPlayed {
                    Text(lastPlayed)
                        .font(.system(.callout))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                Label(row.value, systemImage: row.valueSymbol)
                    .labelStyle(LeaderboardValueLabelStyle())
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .monospacedDigit()
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                }
            }
            .fixedSize()
            if !row.games.isEmpty {
                LeaderboardGamesStack(games: row.games, more: row.moreGames)
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(minHeight: ServerHubMetrics.leaderboardRowHeight)
        .background {
            RoundedRectangle(cornerRadius: Radius.chip)
                .fill(row.isReader ? Palette.accent.opacity(0.14) : (isHovering ? Palette.hoverFill : .clear))
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityElement(children: .combine)
    }
}
