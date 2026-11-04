import SwiftUI

/// The card a Nitro tenure badge opens under the pointer.
///
/// Every other badge on the row gets a one-line label — `BadgeFlyout` — because
/// a line is all Discord says about them. A tenure badge is the one it gives a
/// whole card to: the tier's own artwork, its name in the Nitro face, and the
/// date the subscription started.
///
/// **The wash behind it is Discord's, transcribed from the rule rather than
/// eyeballed off the picture:**
///
/// ```css
/// background: linear-gradient(270deg in oklab, var(--end) 0, var(--start) 100%);
/// mask-image: radial-gradient(100% 100% at 50% 100%, transparent 60%, #000 100%);
/// ```
///
/// Two things in that are easy to get backwards and both are visible. `270deg`
/// points the gradient line to the LEFT, so the stop written at `0` lands on the
/// right and **the start colour is the one on the leading edge** — which is the
/// half a reader actually notices. And the mask is an ellipse the size of the
/// whole card centred on its BOTTOM edge, transparent inside 60 % of that: the
/// wash is therefore absent along the foot, strongest in the top corners, and
/// the card fades into its own surface rather than ending in a band.
///
/// The two stops are the tier's `EXPRESSIVE_GRADIENT_TENURE_BADGE_*` tokens at
/// the 0.3 they carry — see `PremiumTenure`.
///
/// **One thing deliberately approximate:** Discord interpolates that gradient in
/// Oklab and SwiftUI's `LinearGradient` does not. The endpoints are exact and
/// the difference in the middle of a 30 %-opacity wash is a unit or two, which
/// is not worth a hand-sampled sixteen-stop gradient that would then be wrong
/// the moment the tokens move.
struct TenureBadgeFlyout: View {
    @Environment(\.colorScheme) private var colorScheme
    var tenure: PremiumTenure
    /// When the subscription started, from the profile route. Nil where it has
    /// not arrived — the card then names the tier and says nothing it cannot
    /// support, rather than drawing an empty line.
    var premiumSince: Date?
    /// Opening the page. **On the CARD, not only on the badge**, because a
    /// `.popover` is an `NSPopover` with transient behaviour: while one is up,
    /// a click anywhere outside it is consumed by its own dismissal, and the
    /// badge under the pointer is always outside it. Discord has no such
    /// problem — its flyout is an overlay in the same window — so the badge
    /// keeps its own tap for the keyboard and for a reader who never hovers.
    var open: () -> Void
    /// Whether the pointer is on the card, which the row needs in order to keep
    /// it up: the card sits directly above the badge, so moving onto it leaves
    /// the badge and would otherwise dismiss the thing being moved onto.
    var hovering: (Bool) -> Void

    /// Measured off Discord's own card at 2x: 480 x 393 device pixels.
    private static let width: CGFloat = 240
    /// The artwork's slot is 6:4 of the card's width; the drawing is centred in
    /// it and fitted to its HEIGHT.
    ///
    /// **Fitted to the height, because these are not square and are not all the
    /// same shape.** Authored, in order: 60x61, 61x61, 68x69, 69x69, 78x69,
    /// 84x69, 99x69, 104x69 — one height, growing sideways as the wings and
    /// ornaments appear, which is the `hasWideArt` flag in Discord's own table.
    /// Its stylesheet says `height: 75px; width: auto` for the same reason.
    /// Forcing a square frame squashes Diamond and crushes Opal.
    private static let artwork: CGFloat = 88

    var body: some View {
        VStack(spacing: 0) {
            RemoteImage(
                url: tenure.artworkURL,
                // The decode cap is the LONGEST side, and the widest tier is
                // 104:69 — so a cap of the height alone would decode Opal at
                // 88 across and 58 tall and then upscale it back.
                side: Self.artwork * PremiumTenure.widestAspect,
                bucket: .artwork
            ) {
                // **A space, not a spinner.** The card is already the answer to
                // a hover; a placeholder that announces itself would be chrome
                // about chrome, and the drawing lands in one frame from cache
                // on every hover after the first.
                Color.clear
            }
            .aspectRatio(contentMode: .fit)
            .frame(height: Self.artwork)
            .frame(height: Self.width * 4 / 6)

            Text(tenure.nitroName.uppercased())
                .font(.system(size: 27, weight: .heavy, design: .default).italic())
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let line = tenure.subscriberLine(since: premiumSince) {
                Text(line)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.bottom, Spacing.group)
        .frame(width: Self.width)
        // **Opaque, and Discord's is too.** A card this size over the popover's
        // own material reads as a pane of glass with somebody's banner showing
        // through it; the wash below is a 30 % tint and needs a ground of its
        // own to be a colour rather than a haze.
        .background(alignment: .center) { wash.background(ProfileFlyoutGround.raised(in: colorScheme)) }
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover(perform: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// The tier's colour, laid over whatever surface the presentation supplies.
    private var wash: some View {
        LinearGradient(
            colors: [tenure.gradientColors.start, tenure.gradientColors.end],
            startPoint: .leading,
            endPoint: .trailing
        )
        .mask {
            EllipticalGradient(
                stops: [
                    .init(color: .clear, location: 0.6),
                    .init(color: .black, location: 1),
                ],
                center: .bottom,
                startRadiusFraction: 0,
                endRadiusFraction: 1
            )
        }
    }
}
