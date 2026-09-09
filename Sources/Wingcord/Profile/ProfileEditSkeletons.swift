import SwiftUI
import WingcordCore

// The grey stand-ins the editor's rail draws where a cosmetic is not set.
//
// **Drawn, not the shipped artwork.** Discord serves these as PNGs
// (`discord.com/assets/2ca6b6f4a73913ed.png` and friends, 120 × 196 for the
// mini profile) in light grey on white, which would need recolouring for a dark
// rail, would not follow the reader's theme, and is their artwork rather than
// ours. The proportions below are read off those files; everything else is the
// app's own material — which is the same call `docs/` records for every Discord
// screenshot: read them for behaviour, build in Wingcord's own glass.

/// One grey bar standing in for a line of text.
///
/// **The numbers are Discord's own, from `placeholderUsername__62b8c`:** 14
/// tall, radius 8, half opacity, `#706f74` in dark. Everything that stands in
/// for text in this rail is this shape at a different width, so there is one
/// place to change if the rail's density ever does.
struct SkeletonBar: View {
    /// **A width, never a scale.** A fraction applied with `scaleEffect` would
    /// stretch the corner radius with the bar, so a wide line and a short one
    /// would round differently — callers do the arithmetic and hand over points.
    var width: CGFloat
    var height: CGFloat = 14

    var body: some View {
        RoundedRectangle(cornerRadius: min(8, height / 2), style: .continuous)
            .fill(Palette.skeletonInk)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

/// The mini profile card the Effect and Frame tiles stand a `+` over.
///
/// Proportions read off Discord's own 120 × 196 asset: a banner over the top
/// three tenths, the mark straddling its lower edge at a fifth of the width in,
/// then a name, a handle and four lines of bio.
struct MiniProfileSkeleton: View {
    /// The Frame tile's artwork is the same card with a dashed edge, because a
    /// frame is a thing drawn *around* a card rather than inside one.
    var isDashed = false

    private static let bannerFraction: CGFloat = 0.3
    private static let markFraction: CGFloat = 0.26
    /// The card's own gutter, per side.
    private static let inset: CGFloat = 0.07
    /// Every bar, as a fraction of the card's width. Two for the identity, a
    /// gap, then the bio.
    private static let lines: [CGFloat] = [0.44, 0.66, 0, 0.30, 0.82, 0.90, 0.72, 0.52]

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            let mark = side * Self.markFraction
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(Palette.skeletonBanner)
                    .frame(height: proxy.size.height * Self.bannerFraction)
                    .overlay(alignment: .bottomLeading) {
                        Circle()
                            .fill(Palette.skeletonInk)
                            .frame(width: mark, height: mark)
                            .padding(.leading, side * Self.inset)
                            .offset(y: mark / 2)
                    }
                VStack(alignment: .leading, spacing: side * 0.055) {
                    ForEach(Array(Self.lines.enumerated()), id: \.offset) { _, fraction in
                        // A zero-width line is the gap between the identity and
                        // the bio, kept as a row so the rhythm above and below
                        // it comes out of the same arithmetic.
                        // Each line is a fraction of the CARD, clamped to what
                        // is left inside its gutters — so a bar can reach the
                        // inner edge and never past it.
                        SkeletonBar(
                            width: min(side * fraction, side * (1 - Self.inset * 2)),
                            height: side * 0.065
                        )
                        .opacity(fraction == 0 ? 0 : 1)
                    }
                }
                .padding(.horizontal, side * Self.inset)
                .padding(.top, mark * 0.75)
                Spacer(minLength: 0)
            }
        }
        .background(Palette.skeletonPlate)
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        .overlay {
            if isDashed {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(
                        Palette.skeletonInk,
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

extension Palette {
    /// What a placeholder line is painted in.
    ///
    /// Discord's dark value is `#706f74`; this is the app's own equivalent so
    /// the rail follows the reader's theme rather than sitting at one grey under
    /// all of them. Half opacity is theirs and it is what keeps a skeleton
    /// reading as absence rather than as content.
    static let skeletonInk = Color.white.opacity(0.22)
    /// The plate a skeleton card sits on — one step up from the rail so the card
    /// has an edge without needing a stroke.
    static let skeletonPlate = Color.white.opacity(0.05)
    /// The banner band inside a skeleton card, a shade above the plate.
    static let skeletonBanner = Color.white.opacity(0.09)
    /// The rule between the rail's regions, and its outer edge — the same
    /// hairline the identity panel already draws down its own trailing side.
    static let railHairline = Color.white.opacity(0.10)
}
