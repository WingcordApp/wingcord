import SwiftUI
import WingcordCore

/// The server's banner: artwork behind the channel list, **a plain rectangle**
/// across the column (Alex, 2026-10-26, screenshot 19 — "this weird rounded
/// shape": it was rounded on the leading side only, inset from the rail).
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
    /// Whether an animated banner moves now.
    ///
    /// **Discord's rule, read out of its guild header** (`er`): five seconds
    /// each time the banner comes into view — and only when the reader lets
    /// things play — then only while the pointer is over it. A banner that
    /// moved for as long as its server was open was a megabyte-a-frame film
    /// decoding behind a list nobody was looking at.
    var animates: Bool

    // MARK: What the two layers are fetched at
    //
    // Separate numbers, because the two are bounded by different things. The
    // still is one bitmap and can afford the sharpest rendition the CDN serves.
    // The moving one is decoded frame after frame, so every pixel of
    // over-decode is paid for on every frame.

    /// The still layer. One frame, so it takes the sharp rendition.
    private static let stillSide: CGFloat = 512

    /// The animated layer, in points.
    ///
    /// **Sized to what the column actually shows, not to the source.** A guild
    /// banner is a 16:9 strip aspect-filled into a block roughly 220 wide and
    /// 200 tall; the binding edge is the height, so covering it needs
    /// `200 * 16/9` of width and nothing more. Asking for 512 left every frame
    /// at the source's own 960x540 — 2 MB each, five times what the column can
    /// draw.
    private static let filmSide: CGFloat = 360

    var body: some View {
        artwork
            .frame(height: layout.bannerRestingHeight)
            .overlay(alignment: .bottom) { bottomScrim }
            // Edge to edge, square: the column's own band, as Discord draws
            // it. Its foot is the scrim's soft edge, not a corner.
            .clipped()
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
                    // hold the answer. And only while it is moving: the film
                    // leaves with the pointer and the still is the banner again.
                    if animates, let url = header.bannerURL, CDN.canAnimate(url) {
                        AnimatedDecoration(
                            url: url,
                            side: Self.filmSide,
                            gravity: .resizeAspectFill
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
