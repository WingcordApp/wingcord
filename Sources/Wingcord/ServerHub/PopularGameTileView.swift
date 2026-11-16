import SwiftUI

/// One game: its box art, its name, and how many of the server played it.
struct PopularGameTileView: View {
    var tile: PopularGamesCardModel.Tile

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1 / ServerHubMetrics.gameTileAspect, contentMode: .fit)
                .overlay {
                    ZStack {
                        shape.fill(Palette.hoverFill)
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Ink.tertiary)
                        RemoteImage(url: tile.coverURL ?? tile.iconURL, side: ServerHubMetrics.gameTileWidth, bucket: .artwork) {
                            Color.clear
                        }
                        .scaledToFill()
                    }
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(Ink.quaternary, lineWidth: 1) }
                .shadow(color: .black.opacity(isHovering ? 0.35 : 0.2), radius: isHovering ? 12 : 6, y: isHovering ? 6 : 3)
                .scaleEffect(isHovering ? 1.03 : 1)
            Text(tile.name)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Label("\(tile.players.formatted())", systemImage: "person.fill")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(tile.name), \(GuildSpaceFormatting.count(tile.players, "player", "players"))"))
    }
}
