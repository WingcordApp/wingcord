import CoreGraphics
import WingcordCore

/// Discord's server mark, drawn: the flower-star rosette and the glyph cut
/// into it.
///
/// **One routine for every surface.** The mark sits in SwiftUI chrome — the
/// server name pill, the rail's label, the tag card — and in the transcript's
/// drawn invite card, and two drawings of one mark are two things that drift.
/// Both reach this through a `CGContext`: SwiftUI through a `Canvas`, the
/// transcript directly.
///
/// **The art is Discord's own**: the rosette is `814925`'s path and the glyphs
/// are its `HomeIcon`, `GlobeEarthIcon`, check, partner and staff icons,
/// resolved to the absolute move / line / cubic / close that `VectorPath`
/// reads. The resolution was checked by drawing both forms in Chrome at 20x:
/// they differ by half a pixel's antialiasing on a few dozen edge pixels out
/// of a hundred thousand.
nonisolated enum GuildMarkArt {

    /// Draws the mark filling `rect`, which should be square.
    ///
    /// `isLight` picks the plain community mark's colours, which are the only
    /// ones that follow the theme: white with a dark glyph on a dark theme,
    /// the reverse on a light one (`107773`'s dark and light pairs).
    static func draw(_ mark: GuildMark, in rect: CGRect, context: CGContext, isLight: Bool) {
        if mark.kind == .discoverable {
            return drawWebBadge(in: rect, context: context, isLight: isLight)
        }
        guard let rosette = placed("guild.rosette", rosettePath, side: rosetteSide, in: rect) else { return }
        let (fill, ink) = colors(for: mark, isLight: isLight)

        context.saveGState()
        context.addPath(rosette)
        if let fill {
            context.setFillColor(fill)
            context.fillPath()
        } else {
            // `rotate(45)` on a gradient in bounding-box units: the axis runs
            // from the top-left corner along the diagonal and ends at 0.707 of
            // it, with the end colour carried on past.
            context.clip()
            context.drawLinearGradient(
                boostGradient,
                start: rect.origin,
                end: CGPoint(x: rect.minX + rect.width * 0.7071, y: rect.minY + rect.height * 0.7071),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()

        let glyph = glyph(for: mark.kind)
        // Discord's own sizing: three quarters of the badge, less two points for
        // the house and the globe, which are drawn edge to edge in their box.
        let side = floor(rect.width * 0.75) - glyph.inset
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        context.setFillColor(ink)
        for (key, layer) in glyph.layers {
            guard let path = placed(key, layer, side: glyph.side, in: box) else { continue }
            context.addPath(path)
            context.fillPath(using: glyph.isEvenOdd ? .evenOdd : .winding)
        }
    }

    /// A discoverable server's mark, which is one drawing and not a rosette with
    /// a glyph in it: Discord's `ExperimentalWebBadgeIcon` (`682697`), a
    /// scalloped disc with a wire globe.
    ///
    /// **Never the boost gradient, and never the earth.** Discord's table has no
    /// entry for a discoverable server at all (`554783`: `[DISCOVERABLE]: {}`),
    /// so it takes neither a glyph nor a boosted ground — it draws this, in the
    /// theme's inverted badge pair: white with black lines on the dark themes,
    /// the reverse on the light one.
    private static func drawWebBadge(in rect: CGRect, context: CGContext, isLight: Bool) {
        let ground = isLight ? black : white
        let ink = isLight ? white : black
        if let disc = placed("guild.web.disc", webDisc, side: 24, in: rect) {
            context.addPath(disc)
            context.setFillColor(ground)
            context.fillPath()
        }
        context.setFillColor(ink)
        for (key, outline) in webGlobe {
            guard let line = placed(key, outline, side: 24, in: rect) else { continue }
            context.addPath(line)
            context.fillPath()
        }
    }

    /// The boost gem in the flyout's footer: three white layers at 55, 80 and
    /// 100 per cent, on a 17 x 22 grid.
    static func drawBoostGem(in rect: CGRect, context: CGContext) {
        // Fitted by height, centred across, which is what the SVG's default
        // `xMidYMid meet` does with a 17 x 22 box in a square.
        let scale = rect.height / 22
        let box = CGRect(
            x: rect.midX - 17 * scale / 2, y: rect.minY, width: 17 * scale, height: 22 * scale
        )
        for (key, outline, alpha) in gemLayers {
            guard let path = placed(key, outline, side: 22, in: CGRect(
                x: box.minX, y: box.minY, width: 22 * scale, height: 22 * scale
            )) else { continue }
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
            context.addPath(path)
            context.fillPath()
        }
    }

    // MARK: Colours — Discord's raw tokens, not this app's palette

    /// `GREEN_360`, `BRAND_500`, `PRIMARY_500`.
    private static let green = CGColor(srgbRed: 0x23 / 255, green: 0xA5 / 255, blue: 0x5A / 255, alpha: 1)
    private static let brand = CGColor(srgbRed: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255, alpha: 1)
    private static let neutral = CGColor(srgbRed: 0x4E / 255, green: 0x50 / 255, blue: 0x58 / 255, alpha: 1)
    private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// `BADGE_INVERTED_TEXT` on the dark themes, and the ground on the light.
    private static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    /// `PREMIUM_GUILD_BADGE_V2_BACKGROUND`: `PREMIUM_TIER_2_PURPLE` to
    /// `PREMIUM_TIER_2_PINK`.
    static let boostPurple = CGColor(srgbRed: 0xB4 / 255, green: 0x73 / 255, blue: 0xF5 / 255, alpha: 1)
    static let boostPink = CGColor(srgbRed: 0xE2 / 255, green: 0x92 / 255, blue: 0xAA / 255, alpha: 1)
    /// Immutable once built — `CGGradient` has no mutators — which is what makes
    /// sharing one across threads sound.
    private nonisolated(unsafe) static let boostGradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [boostPurple, boostPink] as CFArray,
        locations: [0, 1]
    )!

    /// The rosette's fill — nil for the boost gradient — and the glyph's ink.
    private static func colors(for mark: GuildMark, isLight: Bool) -> (fill: CGColor?, ink: CGColor) {
        switch mark.kind {
        case .staff, .verified, .verifiedAndPartnered:
            (green, white)
        case .partnered:
            (brand, white)
        case .community, .discoverable:
            if mark.isBoosted {
                (nil, white)
            } else {
                isLight ? (neutral, white) : (white, neutral)
            }
        }
    }

    // MARK: Paths

    private struct Glyph {
        /// Each layer with the key it is parsed under.
        var layers: [(key: String, outline: String)]
        /// The grid the glyph is authored on.
        var side: CGFloat
        var isEvenOdd: Bool
        /// Discord's `sizeAdjustment`.
        var inset: CGFloat
    }

    private static func glyph(for kind: GuildMark.Kind) -> Glyph {
        switch kind {
        case .staff:
            Glyph(layers: staff, side: 24, isEvenOdd: false, inset: 0)
        case .verified, .verifiedAndPartnered:
            Glyph(layers: [("guild.mark.check", check)], side: 24, isEvenOdd: true, inset: 0)
        case .partnered:
            Glyph(layers: partner, side: 16, isEvenOdd: false, inset: 0)
        case .community:
            Glyph(layers: [("guild.mark.home", home)], side: 24, isEvenOdd: false, inset: 2)
        case .discoverable:
            Glyph(layers: [("guild.mark.globe", globe)], side: 24, isEvenOdd: true, inset: 2)
        }
    }

    /// One outline scaled from its authoring grid into `rect`, parsed once per
    /// process through `MarkCache`.
    private static func placed(
        _ key: String, _ outline: String, side: CGFloat, in rect: CGRect
    ) -> CGPath? {
        guard let parsed = MarkCache.shared.path(for: key, outline: outline) else { return nil }
        let scale = min(rect.width, rect.height) / side
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        return parsed.copy(using: &transform)
    }

    /// `ExperimentalWebBadgeIcon`'s disc, on its own 24 grid.
    private static let webDisc = """
        M24 12 C24 13.2 22.05 14.1 21.75 15.15 C21.45 16.2 22.35 18.15 21.75 19.05 C21.15 19.95 \
        18.9 19.5 18 20.25 C17.1 21 16.8 22.95 15.75 23.4 C14.7 23.85 13.2 22.2 12 22.2 C10.8 22.2 \
        9.3 23.7 8.25 23.4 C7.2 23.1 6.9 20.85 6 20.25 C5.1 19.65 3 19.95 2.25 19.05 C1.5 18.15 \
        2.55 16.35 2.25 15.15 C1.95 13.95 0 13.2 0 12 C0 10.8 1.95 9.9 2.25 8.85 C2.55 7.8 1.65 \
        5.85 2.25 4.95 C2.85 4.05 5.1 4.5 6 3.75 C6.9 3 7.2 1.05 8.25 0.6 C9.3 0.15 10.8 1.8 12 1.8 \
        C13.2 1.8 14.7 0.3 15.75 0.6 C16.8 0.9 17.1 3 18 3.75 C18.9 4.5 21 4.05 21.75 4.95 C22.5 \
        5.85 21.45 7.65 21.75 8.85 C22.05 10.05 24 10.8 24 12 Z
        """

    /// Its globe: the rim, one meridian and the equator, each a filled outline.
    private static let webGlobe: [(key: String, outline: String)] = [
        ("guild.web.rim", """
            M17.69 12 C17.69 8.857 15.143 6.31 12 6.31 C8.857 6.31 6.31 8.857 6.31 12 C6.31 15.143 \
            8.857 17.69 12 17.69 L12 19 C8.134 19 5 15.866 5 12 C5 8.134 8.134 5 12 5 C15.866 5 19 \
            8.134 19 12 C19 15.866 15.866 19 12 19 L12 17.69 C15.143 17.69 17.69 15.143 17.69 12 Z
            """),
        ("guild.web.meridian", """
            M13.87 12 C13.87 10.21 13.54 8.65 13.06 7.6 C12.52 6.41 12.05 6.3 12 6.3 C11.95 6.3 11.48 \
            6.4 10.95 7.58 C10.377 8.978 10.098 10.479 10.13 11.99 C10.13 13.78 10.46 15.34 10.95 \
            16.39 C11.48 17.57 11.95 17.68 12 17.68 L12 19 C10.24 19 8.82 15.87 8.82 12 C8.82 8.13 \
            10.24 5 12 5 C13.76 5 15.18 8.13 15.18 12 C15.18 15.87 13.76 19 12 19 L12 17.69 C12.05 \
            17.69 12.52 17.59 13.06 16.41 C13.54 15.35 13.86 13.79 13.86 12 Z
            """),
        ("guild.web.equator", "M17.73 11.32 L17.73 12.64 L6.27 12.64 L6.27 11.32 L17.73 11.32 Z"),
    ]

    private static let rosetteSide: CGFloat = 16

    private static let rosettePath = """
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

    private static let home = """
        M2.4 8.4L10.78 1.94C11.5 1.386 12.5 1.386 13.22 1.94L21.61 8.39 \
        C22.23 8.864 22.51 9.653 22.34 10.41C22.17 11.17 21.58 11.76 20.82 11.93L20.5 12 \
        L19.68 20.2C19.58 21.22 18.72 22 17.69 22L16 22C15.45 22 15 21.55 15 21L15 16 \
        C15 14.34 13.66 13 12 13C10.34 13 9 14.34 9 16L9 21C9 21.55 8.552 22 8 22L6.31 22 \
        C5.283 22 4.423 21.22 4.32 20.2L3.5 12L3.18 11.93C2.42 11.76 1.825 11.17 1.656 10.41 \
        C1.487 9.653 1.773 8.864 2.39 8.39Z
        """

    private static let globe = """
        M23 12C23 18.08 18.08 23 12 23C5.925 23 1 18.08 1 12C1 5.925 5.925 1 12 1 \
        C18.08 1 23 5.925 23 12ZM18.84 17.85C20.77 15.6 21.46 12.54 20.69 9.675 \
        C19.92 6.811 17.79 4.509 15 3.52L15 4C15 5.657 13.66 7 12 7L11.23 7 \
        C11.1 7 11 7.1 11 7.23C11 8.76 9.76 10 8.23 10C8.1 10 8 10.1 8 10.23L8 11.75 \
        C8 11.89 8.11 12 8.25 12L13 12C14.66 12 16 13.34 16 15L16 15.77 \
        C16 15.9 16.1 16 16.23 16C17.43 16 18.46 16.77 18.84 17.85ZM3.18 10.18 \
        C2.669 12.66 3.227 15.24 4.715 17.29C6.203 19.33 8.484 20.66 11 20.94L11 18.24 \
        C11 18.1 10.9 18 10.77 18L10.12 18C8.949 18 8 17.05 8 15.88 \
        C8 15.32 7.78 14.78 7.38 14.38L3.18 10.18Z
        """

    private static let check = """
        M18.7 7.3C19.08 7.689 19.08 8.311 18.7 8.7L10.7 16.7 \
        C10.31 17.08 9.689 17.08 9.3 16.7L5.3 12.7C4.987 12.47 4.84 12.07 4.923 11.69 \
        C5.006 11.3 5.305 11.01 5.687 10.92C6.069 10.84 6.465 10.99 6.7 11.3L10 14.59 \
        L17.3 7.29C17.69 6.909 18.31 6.909 18.7 7.29Z
        """

    private static let partner: [(key: String, outline: String)] = [
        ("guild.mark.partner.0", """
        M10.5906 6.39993L9.19223 7.29993C8.99246 7.39993 8.89258 7.39993 8.69281 7.29993 \
        C8.59293 7.19993 8.39317 7.09993 8.29328 6.99993 \
        C7.89375 6.89993 7.5941 6.99993 7.29445 7.19993L6.79504 7.49993L4.29797 9.19993 \
        C3.69867 9.49993 2.99949 9.39993 2.69984 8.79993 \
        C2.30031 8.29993 2.50008 7.59993 2.99949 7.19993L5.99598 5.19993 \
        C6.79504 4.69993 7.79387 4.49993 8.69281 4.69993 \
        C9.49188 4.89993 10.0912 5.29993 10.5906 5.89993 \
        C10.7904 6.09993 10.6905 6.29993 10.5906 6.39993Z
        """),
        ("guild.mark.partner.1", """
        M13.4871 7.79985C13.4871 8.19985 13.2874 8.59985 12.9877 8.79985L9.89135 10.7999 \
        C9.29206 11.1999 8.69276 11.3999 7.99358 11.3999 \
        C7.69393 11.3999 7.49417 11.3999 7.19452 11.2999 \
        C6.39545 11.0999 5.79616 10.6999 5.29674 10.0999 \
        C5.19686 9.89985 5.29674 9.69985 5.39663 9.59985L6.79499 8.69985 \
        C6.89487 8.59985 7.09463 8.59985 7.19452 8.69985 \
        C7.39428 8.79985 7.59405 8.89985 7.69393 8.99985 \
        C8.09346 8.99985 8.39311 8.99985 8.69276 8.79985L9.39194 8.39985L11.3896 6.99985 \
        L11.6892 6.79985C12.1887 6.49985 12.9877 6.59985 13.2874 7.09985 \
        C13.4871 7.39985 13.4871 7.59985 13.4871 7.79985Z
        """),
    ]

    private static let staff: [(key: String, outline: String)] = [
        ("guild.mark.staff.0", """
        M2 20.59L2 19.4C2.004 19.14 2.112 18.88 2.3 18.7L4.7 16.28 \
        C4.889 16.09 5.144 15.99 5.41 15.99L6 15.99L15 6.99L14.15 6.14 \
        C14.05 6.044 13.97 5.928 13.92 5.8L12.43 2.07C12.36 1.884 12.4 1.672 12.54 1.531 \
        C12.68 1.389 12.89 1.346 13.08 1.42L16.81 2.92C16.94 2.969 17.05 3.044 17.15 3.14 \
        L17.79 3.78C17.98 3.591 18.23 3.484 18.5 3.484C18.77 3.484 19.02 3.591 19.21 3.78 \
        L20.21 4.78C20.4 4.968 20.51 5.223 20.51 5.49C20.51 5.757 20.4 6.012 20.21 6.2 \
        L21.79 7.78C21.98 7.968 22.09 8.223 22.09 8.49C22.09 8.757 21.98 9.012 21.79 9.2 \
        L20.21 10.78C20.02 10.97 19.77 11.08 19.5 11.08C19.23 11.08 18.98 10.97 18.79 10.78 \
        L17 9L8 18L8 18.59C7.996 18.85 7.888 19.11 7.7 19.29L5.3 21.71 \
        C5.111 21.9 4.856 22 4.59 22L3.4 22C3.136 22 2.885 21.89 2.7 21.7L2.28 21.3 \
        C2.093 21.11 1.988 20.86 1.99 20.59Z
        """),
        ("guild.mark.staff.1", """
        M8.23 10.23C8.43 10.43 8.74 10.43 8.93 10.23L10.23 8.93 \
        C10.42 8.736 10.42 8.424 10.23 8.23L6.5 4.5L6.8 4.2C7.181 3.811 7.181 3.189 6.8 2.8 \
        L6.3 2.3C6.1 2.1 5.85 2 5.6 2.08C5.17 2.22 4.43 2.57 3.5 3.5 \
        C2.866 4.077 2.379 4.797 2.08 5.6C2 5.85 2.11 6.1 2.29 6.3L2.79 6.8 \
        C2.978 6.989 3.233 7.096 3.5 7.096C3.767 7.096 4.022 6.989 4.21 6.8L4.5 6.5 \
        L8.23 10.23ZM13.77 15.06C13.58 15.25 13.58 15.57 13.77 15.76L15.5 17.5L16.94 19.9 \
        C16.98 19.97 17.03 20.03 17.09 20.09L18.82 21.82C18.92 21.92 19.08 21.92 19.18 21.82 \
        L21.82 19.18C21.92 19.08 21.92 18.92 21.82 18.82L20.1 17.1 \
        C20.04 17.04 19.97 16.99 19.9 16.95L17.5 15.5L15.77 13.77 \
        C15.58 13.58 15.26 13.58 15.07 13.77L13.77 15.07Z
        """),
    ]

    private static let gemLayers: [(key: String, outline: String, alpha: CGFloat)] = [
        ("guild.mark.gem.0", """
        M8.49999 3.7998L4.85999 7.4398L4.85999 12.5598L8.49999 16.1998L12.14 12.5598 \
        L12.14 7.4398L8.49999 3.7998ZM10.32 11.7998L8.49999 13.6265L6.67999 11.8065 \
        L6.67999 8.19314L8.49999 6.37314L10.32 8.19314L10.32 11.7998Z
        """, 0.55),
        ("guild.mark.gem.1", """
        M6.67999 8.19354L6.67999 11.8069L8.49999 13.6269L10.32 11.8069L10.32 8.19354 \
        L8.49999 6.37354L6.67999 8.19354Z
        """, 0.8),
        ("guild.mark.gem.2", "M8.5 3.7998L8.5 6.37314L10.32 8.19314L12.14 7.4398L8.5 3.7998Z", 1),
    ]
}
