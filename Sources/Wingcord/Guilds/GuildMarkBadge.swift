import SwiftUI
import WingcordCore

/// The mark beside a server's name: what Discord says the server *is*.
///
/// **One mark, never a row of them** — `GuildMark` picks the one Discord would.
/// The colours are Discord's own rather than this app's palette, for the reason
/// `BrandMark` carries brand colours: a mark issued by somebody else stops
/// meaning what it means once it is recoloured to the house achromatic.
///
/// Pointing at it says what it means — Discord's own flyout, see
/// `GuildMarkFlyout`. Where the mark sits inside something that takes no
/// pointer (the rail's label), the flyout simply never opens.
struct GuildMarkBadge: View {
    var mark: GuildMark
    var side: CGFloat = 18

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isLight = colorScheme == .light
        Canvas { context, size in
            context.withCGContext { cg in
                GuildMarkArt.draw(mark, in: CGRect(origin: .zero, size: size), context: cg, isLight: isLight)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(Text(mark.accessibilityLabel))
        .hoverFlyout(edge: .bottom) { GuildMarkFlyout(mark: mark) }
    }
}

/// What the mark means, under the pointer — Discord's badge tooltip (`P` and
/// `V` in module `107773`, its stylesheet `818357`).
///
/// **Centred lines, Discord's words**: the title, a subtitle for the verified
/// and partnered kinds, and who may join. A boosted server adds the strip
/// Discord draws in its boost gradient — the level on one half, the count on
/// the other.
struct GuildMarkFlyout: View {
    var mark: GuildMark

    /// Discord's tooltip is 190 wide at most, which is what wraps "People with
    /// an invite link can join." onto a second line in its own flyout.
    static let maxWidth: CGFloat = 190

    var body: some View {
        // Measured at the width it is drawn at — `CappedWidth` — or "People
        // with an invite link can join." wraps past the glass sized for it.
        CappedWidth(max: Self.maxWidth) {
            content
        }
        // It is an answer about the thing under the pointer, so it must never
        // become the thing under the pointer.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(mark.title)
                    .font(.system(.callout, weight: .bold))
                    .foregroundStyle(InkColor.primary)
                if let subtitle = mark.subtitle {
                    Text(subtitle)
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(InkColor.secondary)
                }
                if let detail = mark.detail {
                    Text(detail)
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(InkColor.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)

            if mark.isBoosted { boostStrip }
        }
    }

    /// Level and boosts, split evenly, on Discord's gradient.
    private var boostStrip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Canvas { context, size in
                    context.withCGContext { cg in
                        GuildMarkArt.drawBoostGem(in: CGRect(origin: .zero, size: size), context: cg)
                    }
                }
                .frame(width: 18, height: 18)
                // Discord's own nudge: two down, four back into the word.
                .padding(.top, 2)
                .padding(.leading, -4)
                Text(mark.boostLevel)
            }
            .frame(maxWidth: .infinity)
            .padding(4)

            Rectangle()
                .fill(Palette.canvas)
                .frame(width: 1)

            Text(mark.boostCountLabel)
                .frame(maxWidth: .infinity)
                .padding(4)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .background(LinearGradient(
            colors: [Color(cgColor: GuildMarkArt.boostPurple), Color(cgColor: GuildMarkArt.boostPink)],
            startPoint: .leading,
            endPoint: .trailing
        ))
    }
}
