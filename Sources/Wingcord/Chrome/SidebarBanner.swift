import SwiftUI

/// The server's banner: artwork behind the channel list, rounded like a card.
///
/// It grows **and zooms** when the list is pulled past the top. The zoom is the
/// half that is easy to leave out and that gives the effect away: growing the
/// box alone stretches the picture vertically, which reads as a rendering fault
/// rather than as a gesture. Scaling both axes by the same factor and clipping
/// is what makes the picture crop inward.
///
/// Both states come from one measured offset and neither needs to measure
/// anything itself: a pull is a negative offset, so grow downward from a fixed
/// top; a scroll is a positive one, so translate up at natural size. Only one is
/// ever non-zero.
struct SidebarBanner: View {
    var header: SidebarHeader
    var naturalHeight: CGFloat
    var scrollOffset: CGFloat

    var body: some View {
        let stretch = max(0, -scrollOffset)
        let travel = max(0, scrollOffset)
        let height = naturalHeight + stretch
        let zoom = naturalHeight > 0 ? height / naturalHeight : 1

        artwork
            .frame(height: naturalHeight)
            .scaleEffect(zoom, anchor: .center)
            .frame(height: height)
            // Outside the scaled artwork, so the block's bottom treatment stays
            // put instead of zooming away with the picture.
            .overlay(alignment: .bottom) { bottomScrim }
            .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
            .padding(.horizontal, Spacing.base)
            .offset(y: -travel)
            .allowsHitTesting(false)
    }

    /// The picture over the ground it loads onto.
    ///
    /// **The image is an overlay on a zero-content ground, never a sibling in
    /// the stack.** A filling image inside a `ZStack` reports the *image's* size
    /// to the layout, so the stack grows wider than the column and anything
    /// drawn on top of it is pushed under the rail and clipped. Laying it out
    /// against `Color.clear`, which accepts whatever width it is offered, keeps
    /// the geometry the column's and leaves the artwork purely decorative.
    ///
    /// The gradient underneath is a *loading ground*, not a substitute: this
    /// view is built only for a server that has a banner, so it is never left
    /// standing in for artwork that will not arrive.
    private var artwork: some View {
        Color.clear
            .background {
                LinearGradient(
                    colors: [Palette.surfaceRaised, Palette.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay {
                RemoteImage(url: header.bannerURL, side: 512, bucket: .artwork) {
                    Color.clear
                }
                .aspectRatio(contentMode: .fill)
            }
            .clipped()
            .accessibilityHidden(true)
    }

    /// Darkens the block's own foot toward the list below it, so the edge is a
    /// change of *shape* rather than a change of brightness.
    ///
    /// The alternative — fading the artwork's tint to transparent — reads as an
    /// abrupt cut even though nothing about the luminance is abrupt: a linear
    /// alpha ramp on a saturated colour drains the *saturation* out of a neutral
    /// ground, and the height where the last of the colour disappears is a hard
    /// line the eye finds. A deliberate edge reads as a boundary; a dissolving
    /// one reads as a mistake.
    private var bottomScrim: some View {
        LinearGradient(
            colors: [.clear, Palette.canvas.opacity(0.28), Palette.canvas.opacity(0.66)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 64)
        .allowsHitTesting(false)
    }
}
