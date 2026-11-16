import SwiftUI

/// One widget on the page.
///
/// **A content card** — the house card, material and hairline, as every
/// surface page's (`SurfaceCard`). Games and music lay their top picture,
/// blurred, under the material, so the card takes the colour of what it's
/// about without a single control in the content layer turning to glass.
struct ServerHubCard: View {
    var widget: ServerHubPresentation.Widget
    var isEditing: Bool
    var isWide: Bool

    @Environment(\.motion) private var motion

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: ServerHubMetrics.cardRadius) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ServerHubCardHeader(widget: widget, isEditing: isEditing)
            ServerHubCardBody(widget: widget, isWide: isWide)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ServerHubCardBackdrop(url: widget.backdropURL)
        }
        .clipShape(shape)
        .structuralSurface(in: shape)
        .overlay {
            shape.strokeBorder(isEditing ? Palette.accent.opacity(0.45) : Ink.quaternary, lineWidth: isEditing ? 1.5 : 1)
        }
        .overlay {
            if widget.isLocked {
                ServerHubLockedPlate(name: widget.title, boostPrice: widget.boostPrice)
                    .clipShape(shape)
            }
        }
        .contentShape(.dragPreview, shape)
        .animation(motion.standard, value: isEditing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(widget.title))
    }
}

extension ServerHubPresentation.Widget {
    /// The picture a card wears blurred under its material.
    var backdropURL: URL? {
        switch content {
        case .popularGames(let games): games.backdropURL
        case .popularMusic(let music): music.backdropURL
        default: nil
        }
    }
}
