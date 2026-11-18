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
                        if let cover = tile.coverURL {
                            RemoteImage(url: cover, side: ServerHubMetrics.gameTileWidth, bucket: .artwork) {
                                Color.clear
                            }
                            .scaledToFill()
                        } else if let icon = tile.iconURL {
                            // **No box art: the icon, not stretched over the tile**
                            // — Discord's own fallback (`coverFallbackIconUrl`). A
                            // 256-point icon filling a portrait tile read as a
                            // picture that had failed to load (Alex, 2026-11-18).
                            ZStack {
                                RemoteImage(url: icon, side: 64) { Color.clear }
                                    .scaledToFill()
                                    .scaleEffect(1.6)
                                    .blur(radius: 22)
                                    .saturation(1.3)
                                    .opacity(0.85)
                                RemoteImage(url: icon, side: 128) { Color.clear }
                                    .frame(width: 60, height: 60)
                                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
                                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                            }
                        }
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
