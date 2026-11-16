import SwiftUI

/// The games behind a place: their icons, overlapping, and how many more.
struct LeaderboardGamesStack: View {
    var games: [LeaderboardCardModel.Game]
    var more: Int

    private let side = ServerHubMetrics.leaderboardGameIcon

    var body: some View {
        HStack(spacing: -side * 0.28) {
            ForEach(games) { game in
                RemoteImage(url: game.iconURL, side: side) {
                    RoundedRectangle(cornerRadius: 6).fill(Palette.hoverFill)
                }
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(.rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.quaternary, lineWidth: 1) }
                .help(game.name)
            }
            if more > 0 {
                Text("+\(more)")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(minWidth: side, minHeight: side)
                    .padding(.horizontal, 2)
                    .background(Palette.hoverFill, in: .rect(cornerRadius: 6))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(games.map(\.name).formatted() + (more > 0 ? " and \(more) more" : "")))
    }
}
