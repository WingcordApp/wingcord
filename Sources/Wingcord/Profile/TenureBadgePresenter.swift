import SwiftUI

/// What clicking a Nitro tenure badge opens: all eight tiers, with the wearer's
/// own raised and dated.
///
/// **A layer in the window, not a `.sheet`**, for the two reasons
/// `GameProfilePresenter` already records: a presentation is an `NSWindow` that
/// paints its own backdrop behind everything in it and
/// `.presentationBackground(.clear)` does not suppress it, and this page is
/// raised from *inside* another layer — a badge row that lives in a popover on
/// the mini card and in a column on the full profile. A sheet presented from a
/// view that is itself being torn down is a race; writing a request to the store
/// and reading it here has no such window.
struct TenureBadgePresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                ZStack {
                    if let request = model.tenureBadgeRequest {
                        Button { model.tenureBadgeRequest = nil } label: {
                            Color.black.opacity(0.5).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .cancelAction(unless: model.isCovered(.tenureBadge))
                        .accessibilityLabel(Text("Close badge details"))
                        .transition(.opacity)

                        TenureBadgeSheet(
                            worn: request.tenure,
                            premiumSince: request.premiumSince,
                            width: TenureBadgeSheet.width(in: proxy.size.width),
                            dismiss: { model.tenureBadgeRequest = nil }
                        )
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                // Declared by the container rather than by the writer: a
                // `withAnimation` around a store write opens a global
                // transaction and animates every view that happens to
                // re-lay-out while it runs.
                .animation(motion.panel, value: model.tenureBadgeRequest)
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    func presentsTenureBadge() -> some View {
        modifier(TenureBadgePresenter())
    }
}

/// The page itself.
///
/// **Discord's own stylesheet, transcribed.** Its container is
///
/// ```css
/// background: url(<texture>) no-repeat fixed 50%,
///             linear-gradient(204.56deg, #251045 -7.15%, #301d42 20.93%,
///                                        #24415c 60.11%, #1a1440 98.95%);
/// min-width: 630px; padding-top: 24px; padding-bottom: 48px;
/// ```
///
/// and the grid is `flex-wrap` with a 24-point gap over tiles of at least 115,
/// which is four across at that width — the arrangement in the capture. The
/// worn tier is the one `.earnedBadge` raises: a filled, rounded plate behind
/// the tile with the subscription date under its requirement.
///
/// **Always all eight, and the wearer's is only highlighted.** The page exists
/// to say what the badge a reader just clicked *is* and what comes after it, so
/// showing only what somebody has earned would answer half the question.
struct TenureBadgeSheet: View {
    /// The tier this account wears, or nil when the page is opened without one.
    var worn: PremiumTenure?
    var premiumSince: Date?
    /// How wide the page actually is, from the window — see `width(in:)`.
    var width: CGFloat
    var dismiss: () -> Void

    /// `min-width: 630px; max-width: 65vw`, and the grid takes whatever that
    /// gives it.
    ///
    /// **The page is a proportion of the window, not a constant**, which is what
    /// makes it six tiles across on a full-screen window and four on a narrow
    /// one — Discord wraps the remaining two onto a second row either way. A
    /// fixed 640 is the minimum, and the minimum is the *worst* case rather than
    /// the design.
    static func width(in container: CGFloat) -> CGFloat {
        max(minimumWidth, min(container * 0.65, container - inset * 2))
    }

    private static let minimumWidth: CGFloat = 630
    /// How much of the window stays visible around it at the narrowest.
    private static let inset: CGFloat = 32

    /// The eight, split into rows that fit — and **centred**, which is why this
    /// is not `FlowLayout`.
    ///
    /// That layout is leading-aligned, which is right for a badge row and for
    /// role chips and wrong here: Discord's grid is `justify-content: center`,
    /// so a last row of two sits under the middle of the one above rather than
    /// against its left edge. Eight fixed tiles do not need a flow layout to
    /// find that out — the count is arithmetic on one width.
    private var rows: [[PremiumTenure]] {
        let usable = width - Self.gap * 2
        let columns = max(1, Int((usable + Self.gap) / (Self.tile + Self.gap)))
        return stride(from: 0, to: PremiumTenure.all.count, by: columns).map {
            Array(PremiumTenure.all[$0..<min($0 + columns, PremiumTenure.all.count)])
        }
    }

    /// `.badgeImage { height: 75px; width: auto }` — the HEIGHT, because the
    /// eight drawings share one and grow sideways. See `PremiumTenure`.
    private static let artwork: CGFloat = 75
    /// `.badge > div { min-width: 115px }` and `.badgeList { gap: 24px }`.
    private static let tile: CGFloat = 115
    private static let gap: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            Text("Join Nitro & Unlock an Evolving Profile Badge")
                .font(.system(size: 32, weight: .heavy))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                // `.header { max-width: 700px }` — it wraps at its own measure
                // rather than running the full width of a wide page.
                .frame(maxWidth: 700)
                .padding(.horizontal, Spacing.group)
                .padding(.bottom, Spacing.base)

            Text("Plus unlock perks like custom emoji, HD Streaming, and so much more.")
                .font(.system(.body, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, Spacing.group)
                .padding(.bottom, Spacing.section)

            VStack(spacing: Self.gap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(row) { tier in
                            tile(tier)
                        }
                    }
                }
            }
            .padding(Self.gap)
        }
        .padding(.top, Spacing.group)
        .padding(.bottom, 48)
        .frame(width: width)
        .background { ground }
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay(alignment: .topTrailing) { closeButton }
        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
        // The page is authored dark whatever the reader's profile theme did to
        // the surface it was opened from — Discord marks its own modal
        // `theme-dark` for the same reason.
        .environment(\.colorScheme, .dark)
        .accessibilityAddTraits(.isModal)
    }

    private func tile(_ tier: PremiumTenure) -> some View {
        let isWorn = tier.id == worn?.id
        return VStack(spacing: 0) {
            RemoteImage(
                url: tier.artworkURL,
                side: Self.artwork * PremiumTenure.widestAspect,
                bucket: .artwork
            ) {
                Color.clear
            }
            .aspectRatio(contentMode: .fit)
            .frame(height: Self.artwork)
            .padding(.bottom, Spacing.snug)

            Text(tier.name)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 2)

            Text(tier.requirement)
                .font(.system(.caption))
                .foregroundStyle(.white.opacity(0.85))

            if isWorn, let line = tier.subscriberLine(since: premiumSince) {
                Text(line)
                    .font(.system(.caption))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    // `.earnedBadgeSubSince { max-width: 100px }` — it wraps
                    // onto two lines rather than widening the tile and
                    // rearranging the whole grid around one account's date.
                    .frame(maxWidth: 100)
                    // **And it has to be allowed to wrap.** A `Text` in a
                    // layout that proposes its ideal width reports one line and
                    // then gets truncated by the `maxWidth` above — "Subscriber
                    // since 1…" — because nothing ever asked it how tall it
                    // would be at 100 points. This is that question.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        // `min-width`, not a width: Opal is half as wide again as Bronze, and
        // a fixed tile would crop its wings instead of widening its own column
        // the way a flex row does.
        .frame(minWidth: Self.tile)
        .background {
            if isWorn {
                // **`margin: -12px; padding: 12px`** — the plate grows outward
                // and the tile's layout width does not change, so the row it
                // lands in still has the same column count as every other. A
                // padding on the tile itself would widen one column and be the
                // difference between six across and five.
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .padding(-Spacing.snug)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The gradient behind it, with its stops remapped into `0...1`.
    ///
    /// CSS writes the first at `-7.15 %` and the last at `98.95 %`, which is a
    /// gradient line running past both corners; SwiftUI takes locations in
    /// `0...1`, so the ENDPOINTS move instead and the interior stops are
    /// rescaled against the shortened span. Same picture, stated the way this
    /// framework states it.
    ///
    /// `204.56deg` in CSS is measured clockwise from "up", so the line runs to
    /// the lower left — which is why the start lands off the top-right corner.
    private var ground: some View {
        LinearGradient(
            stops: [
                .init(color: Color(hex: 0x25_10_45), location: 0),
                .init(color: Color(hex: 0x30_1D_42), location: 0.265),
                .init(color: Color(hex: 0x24_41_5C), location: 0.634),
                .init(color: Color(hex: 0x1A_14_40), location: 1),
            ],
            startPoint: UnitPoint(x: 0.835, y: -0.170),
            endPoint: UnitPoint(x: 0.213, y: 1.074)
        )
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, height: 28)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .padding(Spacing.base)
        .help("Close")
        .accessibilityLabel(Text("Close"))
    }
}
