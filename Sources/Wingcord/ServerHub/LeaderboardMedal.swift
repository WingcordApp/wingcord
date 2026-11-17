import SwiftUI

/// Discord's medal for a place — its gold, silver and bronze rosettes, or the
/// trophy at the winner's foot — at 24 points, with the drawn medal standing
/// in while it loads.
struct LeaderboardMedal: View {
    var rank: Int
    /// The trophy rather than the gold rosette: the podium's winner.
    var isTrophy = false

    var body: some View {
        RemoteImage(
            url: isTrophy ? DiscordPodiumArt.trophy : DiscordPodiumArt.medal(rank),
            side: PodiumPlace.medalSide,
            bucket: .artwork
        ) {
            LeaderboardRankBadge(rank: rank)
                .scaleEffect(PodiumPlace.medalSide / 30)
        }
        .frame(width: PodiumPlace.medalSide, height: PodiumPlace.medalSide)
        .accessibilityLabel(Text("Rank \(rank)"))
    }
}
