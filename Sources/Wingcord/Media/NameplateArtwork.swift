import SwiftUI

/// What a nameplate's moving form costs, and where its slot in the film cache
/// is.
///
/// **One place, because the number is part of the key.** `AnimatedImageStore`
/// keys a filmstrip on its URL, its decode size *and* its byte budget — two
/// surfaces asking for the same plate with different budgets get two decodes of
/// the same asset and two copies of it resident.
enum NameplateFilm {
    /// How much decoded film one plate may hold.
    ///
    /// **Frames, measured, not a round number.** A 672x126 loop is thirty-nine
    /// frames; at the largest size any surface draws one — 320 points, so 640
    /// pixels on a Retina display — a frame is 307 KB and the whole loop is
    /// twelve megabytes. `AnimatedImage`'s 6 MB default would buy nineteen of
    /// them, which is a three-second loop running at six frames a second.
    static let byteBudget = 12 * 1024 * 1024

    /// The slot a plate's film occupies.
    ///
    /// The same key `AnimatedDecoration` builds from the same three inputs —
    /// deliberately, so the canvas roster and the composed surfaces share one
    /// decode of one asset rather than each holding their own.
    static func key(url: URL, width: CGFloat, scale: CGFloat) -> AnimatedImageStore.Key {
        AnimatedImageStore.Key(
            url: url,
            maximumPixelSize: Int((width * max(scale, 1)).rounded(.up)),
            byteBudget: byteBudget
        )
    }
}

/// A nameplate's artwork: the still, and the moving form over it where there is
/// somewhere to put motion.
///
/// **One view for every surface that draws a plate**, which is what stops the
/// six of them disagreeing about the two things a plate is easy to get wrong.
///
/// **The size.** A nameplate is a 672x126 strip, five and a third times as wide
/// as it is tall, and both stores key their decode on the *longest* side. Two
/// surfaces asked for it at the row's height — so a plate drawn two hundred and
/// forty points wide was decoded ninety-two pixels wide and stretched five times
/// over. `width` is the width, everywhere, and the still and the film are then
/// the same picture at the same sharpness.
///
/// **When it moves.** A plate moves where it is the thing being looked at, and
/// under the pointer where it is one row among many — never a column of them at
/// once, which reads as a list of artwork rather than a list of people. The
/// caller says which by driving `isAnimating`; nobody has to remember to put the
/// still back, because that is handled here.
///
/// The animated form is a **VP9-in-WebM** the app demuxes itself — see
/// `WebMFilmstrip` — and not every plate has one. A plate whose `.webm` answers
/// 404 reports back that it is a still, `AnimatedImageStore` remembers that
/// answer, and this view goes on drawing the PNG with nothing else to do.
struct NameplateArtwork<Placeholder: View>: View {
    /// The poster: `Nameplate.artworkURL`.
    var still: URL?
    /// The loop: `Nameplate.animatedArtworkURL`. Nil where the surface has
    /// nowhere to put motion, which is its own way of saying "never move".
    var animated: URL?
    /// The width the strip is drawn at, in points — its longest side, and what
    /// both the still and the filmstrip are decoded to fit.
    var width: CGFloat
    /// How the strip fills its box. `.fit` where the plate is fitted to a row's
    /// height and hung off its trailing edge; `.fill` where it is a background
    /// that has to cover.
    var contentMode: ContentMode = .fit
    /// Whether the moving form plays.
    var isAnimating: Bool = false
    @ViewBuilder var placeholder: Placeholder

    /// Whether the filmstrip has frames on screen, which is when the still goes.
    @State private var isPlaying = false

    @Environment(\.motion) private var motion

    /// Whether there is a moving form to put up at all.
    ///
    /// **Reduce Motion is answered by not fetching**, which is where a plate
    /// differs from an avatar decoration. `AnimatedDecoration` parks a
    /// decoration on its first frame rather than hiding it, because a
    /// decoration's artwork *is* the filmstrip. A nameplate has a separate still
    /// on the CDN and it is byte for byte the loop's first frame — checked — so
    /// decoding seventy-eight VP9 frames into twelve megabytes to show a picture
    /// that is already on screen buys nothing at all.
    private var playsFilm: Bool { isAnimating && animated != nil && !motion.reduceMotion }

    var body: some View {
        ZStack {
            RemoteImage(url: still, side: width, bucket: .artwork) {
                placeholder
            }
            .aspectRatio(contentMode: contentMode)
            // **Taken away once the film is up, and faded rather than cut.**
            // The still is the loop's own first frame — checked against a real
            // asset — but the shared clock is already somewhere else in the
            // cycle when playback starts, so a cut lands on an unrelated frame.
            // A hundred milliseconds covers the jump entirely, and the two are
            // never both fully present: an asset with a soft alpha edge shows as
            // two offset copies of itself.
            .opacity(isPlaying ? 0 : 1)
            .animation(motion.fadeQuick, value: isPlaying)

            if playsFilm, let animated {
                AnimatedDecoration(
                    url: animated,
                    side: width,
                    gravity: contentMode == .fill ? .resizeAspectFill : .resizeAspect,
                    byteBudget: NameplateFilm.byteBudget,
                    onPlayback: { playing in
                        guard isPlaying != playing else { return }
                        isPlaying = playing
                    }
                )
                .allowsHitTesting(false)
            }
        }
        // **The still comes back here, not at the call site.** The filmstrip
        // reports playback from its load and deliberately never from a view
        // update, so it has nothing to say on the way out — the view is simply
        // gone. Six surfaces each remembering to clear the flag is six places
        // for a plate to go permanently blank.
        //
        // Watched on `playsFilm` rather than on the flag the caller sets,
        // because the film can also disappear because the plate changed to one
        // with no moving form, or because Reduce Motion came on mid-hover.
        .onChange(of: playsFilm) { _, plays in
            if !plays { isPlaying = false }
        }
        .accessibilityHidden(true)
    }
}

extension NameplateArtwork where Placeholder == Color {
    /// The common case: nothing behind the strip while it loads, because the
    /// surface underneath is already the right ground.
    init(
        still: URL?,
        animated: URL?,
        width: CGFloat,
        contentMode: ContentMode = .fit,
        isAnimating: Bool = false
    ) {
        self.init(
            still: still,
            animated: animated,
            width: width,
            contentMode: contentMode,
            isAnimating: isAnimating
        ) {
            Color.clear
        }
    }
}
