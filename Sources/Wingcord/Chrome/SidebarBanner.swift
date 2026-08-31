import SwiftUI
import WingcordCore

/// The server's banner: artwork behind the channel list, rounded like a card.
///
/// **A fixed height that travels with the list, and nothing else.** It used to
/// grow and zoom when the list was pulled past its top, driven by the scroll
/// view's elastic offset — an effect that needed a held high-water mark, a
/// scroll-phase observer and a second animation curve to stop it collapsing
/// between trackpad flicks, and that deformed the column's geometry under
/// everything else drawn there. It is one rectangle now.
struct SidebarBanner: View {
    var header: SidebarHeader
    /// The chrome overhang this runs under, and the scroll that carries it up.
    ///
    /// **The same value the name pill is placed from.** They are one object
    /// drawn in two layers, and handing each of them its own copy of the
    /// arithmetic is how the pill ended up sitting in a band of empty column
    /// below the artwork rather than in its corner.
    var layout: SidebarBannerLayout

    // MARK: What the two layers are fetched at
    //
    // Separate numbers, because the two are bounded by different things. The
    // still is one bitmap and can afford the sharpest rendition the CDN serves.
    // The filmstrip is that bitmap N times over in RAM, so every pixel of
    // over-decode costs N times, and asking for more than the column can show is
    // paid for entirely in dropped frames.

    /// The still layer. One frame, so it takes the sharp rendition.
    private static let stillSide: CGFloat = 512

    /// The animated layer, in points.
    ///
    /// **Sized to what the column actually shows, not to the source.** A guild
    /// banner is a 16:9 strip aspect-filled into a block roughly 220 wide and
    /// 200 tall; the binding edge is the height, so covering it needs
    /// `200 * 16/9` of width and nothing more. Asking for 512 left every frame
    /// at the source's own 960x540 — 2 MB each, five times what the column can
    /// draw — and the frame budget then bought three of them.
    private static let filmSide: CGFloat = 360

    /// What that filmstrip may hold.
    ///
    /// The default budget is sized for a 33 KB decoration frame. A banner frame
    /// at the size above is around a megabyte, so it needs a budget in the same
    /// units it will be spent in. This is one asset, on screen for as long as
    /// the server is open and evicted when it is not, against a 64 MB store —
    /// the same trade the profile effect's layers already make.
    private static let filmBudget = 20 * 1024 * 1024

    var body: some View {
        artwork
            .frame(height: layout.bannerRestingHeight)
            .overlay(alignment: .bottom) { bottomScrim }
            // **Rounded on the leading side, square on the trailing one.**
            //
            // The trailing edge is not an edge of the banner — it is where the
            // sidebar column ends and the reading surface begins. A radius there
            // rounds the artwork away from a boundary that is already a hard
            // vertical line, which reads as the picture having shrunk back from
            // the seam. The leading side has no such boundary: it meets the rail
            // and the window's own corner, so it keeps its radius.
            .clipShape(
                .rect(
                    topLeadingRadius: Radius.card,
                    bottomLeadingRadius: Radius.card,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
            .padding(.leading, Spacing.base)
            .offset(y: -layout.travel)
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
                ZStack {
                    RemoteImage(url: header.bannerURL, side: Self.stillSide, bucket: .artwork) {
                        Color.clear
                    }
                    .aspectRatio(contentMode: .fill)

                    // A boosted server's banner can be animated, and only then
                    // is there a second layer at all — the extension says so
                    // outright, so a still banner never pays for the fetch, the
                    // multi-frame decode, or the view and coordinator that would
                    // hold the answer.
                    if let url = header.bannerURL, CDN.canAnimate(url) {
                        AnimatedDecoration(
                            url: url,
                            side: Self.filmSide,
                            gravity: .resizeAspectFill,
                            byteBudget: Self.filmBudget
                        )
                    }
                }
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
