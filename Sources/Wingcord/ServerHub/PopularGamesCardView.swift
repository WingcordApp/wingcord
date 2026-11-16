import SwiftUI

/// Popular Games: the week's games as box art, how many played each, and how
/// many played anything.
///
/// **As many tiles as the card holds, each the card's own share** — Discord's
/// rule (`lv`): one to five, a tile for every 108 points.
struct PopularGamesCardView: View {
    var games: PopularGamesCardModel

    @Environment(AppModel.self) private var model
    @State private var visibleCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                ForEach(games.tiles.prefix(visibleCount)) { tile in
                    // A game opens its profile, as Discord's tile does.
                    Button { model.openGameProfile(tile.id) } label: {
                        PopularGameTileView(tile: tile)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the game\u{2019}s profile"))
                }
                // Fewer games than room: the tiles keep their size, not stretch.
                ForEach(0..<max(0, visibleCount - min(visibleCount, games.tiles.count)), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            .onGeometryChange(for: Int.self) { proxy in
                max(1, min(ServerHubMetrics.maxGameTiles, Int((proxy.size.width + Spacing.snug) / 108)))
            } action: { count in
                visibleCount = count
            }
            HStack(spacing: Spacing.base) {
                (Text(GuildSpaceFormatting.count(games.playerCount, "member", "members")).bold()
                    + Text(" played ")
                    + Text(GuildSpaceFormatting.count(games.gameCount, "game", "games")).bold()
                    + Text(" in the last 7 days"))
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
                Spacer(minLength: Spacing.base)
                if !games.faces.isEmpty {
                    FaceStack(faces: games.faces, badge: games.moreFaces > 0 ? "+\(games.moreFaces)" : nil)
                }
            }
        }
        .padding(Spacing.margin)
    }
}
