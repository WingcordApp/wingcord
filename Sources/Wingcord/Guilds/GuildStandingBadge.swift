import SwiftUI
import WingcordCore

/// Discord's rosette, drawn.
///
/// **One outline, three fills.** Partner, verified and community are the *same*
/// shape in Discord's own artwork — the difference is entirely the colour it is
/// filled with — so shipping three bitmaps would be shipping the same picture
/// three times and re-cutting all of them whenever one is retuned.
///
/// A `Shape` for the same reasons `BrandGlyph` is one: it scales to any box
/// without a second asset, carries no bitmap to decode, and is on screen in the
/// frame the card first draws rather than after a round trip.
nonisolated struct GuildRosette: Shape {
    /// The grid the outline is authored on.
    private static let side: CGFloat = 16

    /// Discord's own path, resolved to absolute move/cubic/close at authoring
    /// time — which is all `VectorPath` has cases for, and therefore all it can
    /// be wrong about.
    private static let outline = """
        M5.52995 0.431867C6.27995 0.181867 7.2 1.23199 8 1.23199C8.8 1.23199 9.75007 0.231867 \
        10.4701 0.431867C11.19 0.631965 11.38 2.07173 12 2.52171C12.62 2.9717 14.0003 2.70184 \
        14.4603 3.32184C14.9199 3.94191 14.2303 5.16178 14.4603 5.91169C14.6903 6.66159 \
        15.9998 7.21166 16 8.00153C16 8.79146 14.72 9.38146 14.4798 10.0914C14.2398 10.8014 \
        14.9198 12.0919 14.4798 12.6819C14.0397 13.2716 12.6401 13.0321 12.0202 13.482C11.4002 \
        13.932 11.2298 15.3219 10.4798 15.5719C9.72987 15.8216 8.80967 14.7717 8.00973 \
        14.7717C7.2098 14.7719 6.25964 15.7718 5.53971 15.5719C4.81995 15.3716 4.61982 13.9321 \
        4 13.482C3.38 13.032 1.99971 13.3019 1.53971 12.6819C1.07975 12.0619 1.76971 10.8414 \
        1.53971 10.0914C1.30939 9.34159 0 8.79139 0 8.00153C0.000177681 7.21159 1.2802 6.62163 \
        1.52018 5.91169C1.76012 5.20167 1.08021 3.91183 1.52018 3.32184C1.96018 2.73184 \
        3.36999 3.0017 4 2.52171C4.62997 2.04173 4.78003 0.681954 5.52995 0.431867Z
        """

    func path(in rect: CGRect) -> Path {
        // Parsed once for the process, through the same cache the brand marks
        // use: a `Shape` is asked for its path again on every size change, and
        // re-scanning three hundred coordinates each time is work with a known
        // answer.
        guard let parsed = MarkCache.shared.path(for: "guild.rosette", outline: Self.outline)
        else { return Path() }
        // Uniform, so a mark authored square stays square in a rect that is not.
        let scale = min(rect.width, rect.height) / Self.side
        var transform = CGAffineTransform(
            translationX: rect.midX - Self.side * scale / 2,
            y: rect.midY - Self.side * scale / 2
        )
        .scaledBy(x: scale, y: scale)
        guard let scaled = parsed.copy(using: &transform) else { return Path() }
        return Path(scaled)
    }
}

/// The mark beside a server's name: what Discord says the server *is*.
///
/// **One mark, never a row of them.** A partnered server is also a community and
/// usually also discoverable, and drawing every rosette it qualifies for is
/// three marks saying one thing — `GuildProfile.standing` picks the highest and
/// this draws it.
///
/// The colours are Discord's own tokens rather than this app's palette, for the
/// same reason `BrandMark` carries brand colours: this is a mark issued by
/// somebody else, and recolouring it to the house achromatic would make it stop
/// meaning what it means.
struct GuildStandingBadge: View {
    var standing: GuildProfile.Standing
    var side: CGFloat = 16

    var body: some View {
        GuildRosette()
            .fill(fill)
            .frame(width: side, height: side)
            .overlay {
                // The check is a *hole* in the rosette rather than a glyph on
                // top of it, so it takes whatever is behind the card — the same
                // relationship the profile avatar has with its banner. A painted
                // white tick reads as a sticker on a coloured blob at sixteen
                // points; a cut-out reads as one object.
                Image(systemName: "checkmark")
                    .font(.system(size: side * 0.46, weight: .black))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(Text(standing.label))
            .help(standing.label)
    }

    private var fill: AnyShapeStyle {
        switch standing {
        case .partner:
            AnyShapeStyle(Color(hex: 0x5865F2))
        case .verified:
            AnyShapeStyle(Color(hex: 0x23A55A))
        case .discoverable, .community:
            // The gradient Discord gives a community mark, which is the one of
            // the three that is not a single flat token.
            AnyShapeStyle(LinearGradient(
                colors: [Color(hex: 0x5865F2), Color(hex: 0x00A8FC)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
    }
}
