import SwiftUI

/// A surface lit by one picture.
///
/// **This is what glass on a profile was missing.** `.glassEffect(.clear)` only
/// reads as glass when there is something behind it to refract; the old profile
/// put a 150-point banner at the top and flat paint everywhere else, so every
/// card below it was clear glass over nothing — which renders as a faintly
/// lighter rectangle and is exactly why the surface felt dead. The banner is
/// still the banner; this is the *same picture* spread under the whole sheet as
/// a field of colour, and the slabs on top of it then have something to bend.
///
/// **It costs almost nothing.** The image is fetched at a 64-point rung and
/// scaled across a thousand points — a 64-pixel picture blurred that far *is* a
/// gradient mesh, and it is the person's own one by construction rather than a
/// palette somebody guessed. Nothing here samples pixels, quantises, or runs on
/// a clock.
///
/// A surface with no artwork gets the ground it already had. That branch is the
/// common one — most accounts have no banner — and it has to look deliberate,
/// which is why the fallback is a real two-stop wash rather than a flat fill.
struct AmbientArtwork: View {
    /// The picture to light the surface with. Nil falls back to `tint`.
    var url: URL?
    /// The surface's own colour, from the person's theme or the game's art.
    /// Used alone when there is no picture, and washed over one when there is.
    var tint: Color?
    /// How strongly the picture reads. Low on purpose: this is light, not
    /// content, and text sits on it.
    var strength: Double = 0.5
    /// How far the field has been scrolled, for the parallax. Points.
    var offset: CGFloat = 0

    /// The rung the picture is fetched at.
    ///
    /// Sixty-four, and that is not a placeholder to be raised later. The field
    /// is blurred past any detail a larger fetch would carry, so a bigger rung
    /// buys nothing and costs a real download on a surface that opens on a
    /// click.
    private static let rung: CGFloat = 64
    /// Scale, so the blur's soft edges never reach the sheet's own edges.
    private static let overscan: CGFloat = 1.35
    /// How much of the scroll the field takes. A third: enough to feel like
    /// depth, not enough to read as a second thing moving.
    private static let parallax: CGFloat = 0.3
    /// How far the field may travel, whatever the scroll says.
    ///
    /// **Unclamped, the parallax slides the picture's own edge into view.** The
    /// field is the artwork scaled by `overscan` — 17.5% of spare height at each
    /// end — and a long page scrolls further than that, so past a few hundred
    /// points the blurred image runs out and what is under it is a hard
    /// horizontal line with `Palette.surface` below it. That is exactly the
    /// "colour cutting off at the bottom" of a scrolled game profile. Sixty
    /// points of travel is inside the overscan for any sheet taller than 350,
    /// which every surface that uses this is.
    private static let maximumTravel: CGFloat = 60

    var body: some View {
        ZStack {
            // The floor. Everything above is translucent, and without this the
            // window shows through on a themeless account.
            Palette.surface

            if let url {
                // **`Color.clear` under the picture, never the picture as a
                // sibling** — the trap the banner in both profile surfaces is
                // already written against, and this field had it. An
                // aspect-**filled** image reports the size it grew to, so a
                // 2.5:1 banner filling a 680 × 726 column reports 1,750 wide;
                // a `ZStack` then sizes itself to that AND re-proposes it to
                // every flexible sibling at placement, so `Palette.surface` —
                // an opaque colour — spread 535 points past each edge.
                //
                // The `.background` this is applied through does not clip, and
                // in the full profile the content column is drawn *after* the
                // identity panel: the panel was painted over. Measured on the
                // report's own capture — a 1,040-point sheet whose 360-point
                // rail was 336.5 points of visible panel — which is the whole
                // of "the profile bugs out when there is a banner", and, with
                // the square avatar the fallback uses, of the trailing gutter
                // that came out 23 points narrower than the leading one.
                Color.clear.overlay {
                    RemoteImage(url: url, side: Self.rung, bucket: .thumbnail) { Color.clear }
                        .aspectRatio(contentMode: .fill)
                        // `opaque: true` — a transparent blur samples the clear
                        // pixels outside the picture and pulls the whole field
                        // toward grey at the edges.
                        .blur(radius: 60, opaque: true)
                        .scaleEffect(Self.overscan)
                        .offset(y: -min(max(offset, 0) * Self.parallax, Self.maximumTravel))
                        .saturation(1.25)
                        .opacity(strength)
                }
            }

            if let tint {
                // Over the picture, not under it. A tint beneath a filling image
                // is a tint nobody sees.
                LinearGradient(
                    colors: [tint.opacity(url == nil ? 0.42 : 0.22), tint.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.plusLighter)
            }

            // A vignette, so the slabs near the edges keep their contrast and
            // the sheet's corners stay dark enough to read as an edge.
            RadialGradient(
                colors: [.clear, .black.opacity(0.45)],
                center: .center,
                startRadius: 120,
                endRadius: 720
            )
        }
        .compositingGroup()
        // **The overscan is meant to be cropped.** The field is the artwork
        // grown past the box on purpose so the blur's soft edges never reach
        // its own — which only works if something takes the surplus off. It
        // also keeps the rasterised buffer the size of the surface rather than
        // the size of the picture that lights it.
        .clipped()
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Lights this surface with `url`, tinted by `tint`.
    ///
    /// Applied as a `.background` rather than a `ZStack` sibling so the field
    /// never contributes to the surface's own layout — a filling image reports
    /// its own size upward, and a stack holding one sets the sheet's width to
    /// the picture's.
    ///
    /// **That is only half the guard, and the other half is inside the field.**
    /// A background is sized from its host but is neither bounded nor clipped
    /// by it: whatever the field reports, it is drawn centred on the host and
    /// allowed to run past it, over anything drawn earlier. So the picture must
    /// contribute no size *there* either — see the body.
    func ambientArtwork(
        _ url: URL?,
        tint: Color?,
        strength: Double = 0.5,
        offset: CGFloat = 0
    ) -> some View {
        background {
            AmbientArtwork(url: url, tint: tint, strength: strength, offset: offset)
        }
    }
}
