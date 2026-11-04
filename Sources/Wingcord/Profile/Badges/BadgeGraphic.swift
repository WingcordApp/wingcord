import SwiftUI

/// A badge's artwork, large: the still at `height`, and its moving form over it
/// once that has frames.
///
/// **`height` is how tall the drawing is, and the two pictures get there
/// differently.** Discord's moving tenure badge is a 240 x 200 canvas with the
/// drawing in the middle 71 % of its height, which leaves the shine room to spill
/// past the ring; its still is drawn edge to edge. So Discord lays out one slot and
/// scales only the moving form to fill it (`461536`):
///
/// ```css
/// .graphic { height: 64px }
/// .graphicAnimated { transform: scale(1.4) }
/// ```
///
/// Measured against its own captures: 64 x 1.4 x 0.71 is the 63 points the badge
/// is across in its tooltip. The canvas overhangs the slot, as a transform doesn't
/// affect layout, and the text below sits over nothing but its empty margin.
///
/// **The slot is fixed whether or not anything has landed.** A popover takes its
/// size from the first layout, and this used to be a flexible box around a loading
/// plate: the picture then arrived into the plate's height, which is how Nitro Gold
/// came to be 28 points across on a 260-point card.
struct BadgeGraphic: View {
    var still: URL?
    /// Nil where the badge doesn't move, or the reader asked for less motion.
    var film: URL?
    var height: CGFloat

    @Environment(\.motion) private var motion
    @State private var isPlaying = false

    /// `.graphicAnimated`'s scale.
    static let filmScale: CGFloat = 1.4
    /// The widest still there is: a levelled badge's 156 x 100.
    private static let widestStill: CGFloat = 1.6

    var body: some View {
        ZStack {
            if let still {
                // **A space, not a spinner.** The card is already the answer to a
                // hover, and this lands in a frame from cache on every one after
                // the first.
                RemoteImage(url: still, side: height * Self.widestStill, bucket: .thumbnail) {
                    Color.clear
                }
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .opacity(isPlaying && film != nil ? 0 : 1)
                .animation(motion.fadeQuick, value: isPlaying)
            }
            if let film {
                AnimatedDecoration(
                    url: film,
                    // The decode's ceiling, in points. The canvas is wider than
                    // it's tall, and fitted by its height.
                    side: height * Self.filmScale * Self.widestStill,
                    onPlayback: { playing in
                        guard isPlaying != playing else { return }
                        isPlaying = playing
                    }
                )
                // Wide enough that the height is what fits it, as Discord's
                // `height: 100%; width: auto` does.
                .frame(width: height * Self.filmScale * Self.widestStill, height: height * Self.filmScale)
                .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        // A different picture puts its still back while the new one resolves.
        .onChange(of: film) { isPlaying = false }
        .accessibilityHidden(true)
    }
}
