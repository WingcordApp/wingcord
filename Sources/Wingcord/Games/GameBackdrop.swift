import SwiftUI

/// The game's own picture across the top of its profile, ending in the colours
/// taken from it (Alex's idea, 2026-11-18: "when the background image smoothly
/// ends, the colors of it take over").
///
/// **Discord's picture and Discord's fade** (`backgroundArt` in its game
/// profile): the banner — and where there is none a screenshot — 500 points
/// tall, filling the width, masked from whole at the top through 55% by 50
/// points to nothing by 325. Discord fades it into its flat page colour; here
/// it fades into the field `AmbientArtwork` spreads from the same picture, so
/// the hand-off is the picture's own colours.
///
/// **Still, like that field**: a backdrop that moved with the scroll would
/// rewrite the page on every frame (see the field's own note in
/// `GameProfileView`). Under Reduce Transparency it steps aside and the colours
/// alone remain, as before.
struct GameBackdrop: View {
    var url: URL?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let height: CGFloat = 500

    var body: some View {
        if let url, !reduceTransparency {
            Color.clear
                .frame(height: Self.height)
                .overlay {
                    RemoteImage(url: url, side: 1400, bucket: .artwork) { Color.clear }
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.55), location: 50 / Self.height),
                            .init(color: .clear, location: 325 / Self.height),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
