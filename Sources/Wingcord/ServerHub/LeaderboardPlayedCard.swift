import SwiftUI

/// What a place on the podium played, over it while the pointer rests there:
/// the games' icons and Discord's sentence ("Played ROBLOX, Fortnite and 3
/// others") — its pillar tooltip (`tf`), which has pictures in it, so it can't
/// be the system's.
///
/// **Regular glass**: a transient answer floating over content, carrying text
/// (HIG, Materials). It takes no clicks.
struct LeaderboardPlayedCard: View {
    var row: LeaderboardCardModel.Row

    var body: some View {
        VStack(spacing: Spacing.base) {
            if !row.games.isEmpty {
                LeaderboardGamesStack(games: row.games, more: row.moreGames)
            }
            Text(row.playedSummary ?? "No games played yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base + 2)
        .frame(width: 190)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.chip + 4))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
