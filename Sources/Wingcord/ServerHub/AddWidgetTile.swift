import SwiftUI
import WingcordCore

/// One widget in Add Widget: its picture, its name and what it costs.
struct AddWidgetTile: View {
    var entry: GuildSpaceCatalogEntry
    var action: () -> Void

    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                ZStack {
                    shape.fill(Palette.hoverFill)
                    RemoteImage(url: reduceMotion ? entry.staticImageURL : (entry.animatedImageURL ?? entry.staticImageURL), side: 200) {
                        Image(systemName: ServerHubWidgetNames.symbol(entry.kind) ?? "square.grid.2x2")
                            .font(.system(size: 30))
                            .foregroundStyle(Ink.tertiary)
                    }
                    .scaledToFill()
                    if isHovering {
                        Label("Add Widget", systemImage: "plus.circle.fill")
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Spacing.snug)
                            .padding(.vertical, 6)
                            // A control over a picture: clear glass (`chromeOverMedia`).
                            .chromeOverMedia(in: .capsule)
                            .transition(.materialize)
                    }
                }
                .frame(height: 110)
                .clipShape(shape)
                .overlay { shape.strokeBorder(isHovering ? Palette.accent : Ink.quaternary, lineWidth: isHovering ? 2 : 1) }
                Text(entry.name)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                if let price = entry.boostPrice, price > 0 {
                    Label(GuildSpaceFormatting.count(price, "Boost", "Boosts"), systemImage: "diamond.fill")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFF73FA))
                } else {
                    Text("Free")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityLabel(Text("Add \(entry.name)"))
    }
}
