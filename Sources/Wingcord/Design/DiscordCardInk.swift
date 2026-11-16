import CoreGraphics
import Foundation

/// **Discord's own card, and the grey buttons on it, whatever room they are
/// in** (Alex, 2026-11-16: embeds, invites and app cards "keep their colors
/// despite the theme"). Opaque, so neither a tinted bubble nor a wallpaper
/// shows through, and never the app's accent.
///
/// Read off Discord's stylesheet for each of its base themes:
/// `--background-surface-high` (an embed's ground), `--border-subtle` (its
/// edge) and `--control-secondary-*` (a grey button on it). The grey is
/// `hsla(240, 4%, 61%)` at the stated strength, laid over the card here so a
/// painter fills once. Checked against his screenshots: #323237 buttons on a
/// #242429 card (Dark), #1B1B1E on #0A0A0C (Onyx).
nonisolated struct DiscordCardInk: @unchecked Sendable {
    /// Which of Discord's base themes the room stands for.
    enum Base: Sendable, Equatable {
        /// `theme-midnight`: a near-black card. The house's True Black, and
        /// every room a theme tints, as his themed Discord shows it (a
        /// near-black card on an olive room).
        case onyx
        /// `theme-darker`.
        case dark
        /// `theme-dark`.
        case ash
        /// `theme-light`.
        case light
    }

    let base: Base
    let card: CGColor
    let border: CGColor
    let secondaryFill: CGColor
    let secondaryHover: CGColor
    let secondaryText: CGColor
    let secondaryBorder: CGColor
    /// A grey button that sits on a bubble rather than in a card. Discord's
    /// grey is translucent and takes whatever is behind it; a bubble is
    /// lighter than Discord's ground and may be tinted, so here it is laid
    /// over Dark's card instead (#323237, his screenshot) — raised above a
    /// True Black bubble, and neutral on a coloured one. The other bases' own
    /// card already sits there.
    let looseFill: CGColor
    let looseHover: CGColor

    init(_ base: Base) {
        self.base = base
        // card, --border-subtle, hover strength, --control-secondary-border,
        // --control-secondary-text-default.
        let tokens: (card: UInt32, border: Double, hover: Double, edge: Double, text: UInt32) = switch base {
        case .onyx: (0x0A_0A_0C, 0.2, 0.2, 0.16, 0xDB_DB_DE)
        case .dark: (0x24_24_29, 0.12, 0.16, 0.04, 0xFA_FA_FA)
        case .ash: (0x38_3B_40, 0.12, 0.16, 0.04, 0xFF_FF_FF)
        case .light: (0xFF_FF_FF, 0.28, 0.16, 0.2, 0x29_29_2E)
        }
        card = Self.color(tokens.card)
        border = Self.grey(alpha: tokens.border)
        secondaryFill = Self.grey(over: tokens.card, alpha: 0.12)
        secondaryHover = Self.grey(over: tokens.card, alpha: tokens.hover)
        secondaryText = Self.color(tokens.text)
        secondaryBorder = Self.grey(alpha: tokens.edge)
        let looseGround: UInt32 = base == .onyx ? 0x24_24_29 : tokens.card
        looseFill = Self.grey(over: looseGround, alpha: 0.12)
        looseHover = Self.grey(over: looseGround, alpha: 0.16)
    }

    /// The base a room stands for: light for a light room; Onyx for a room a
    /// theme tints and for a near-black one; otherwise whichever of Dark and
    /// Ash its ground is nearer.
    static func base(for colors: ThemeColors) -> Base {
        if colors.appearance == .light { return .light }
        if colors.textTint != nil { return .onyx }
        let ground = InkContrast.luminance(colors.canvas)
        if ground <= InkContrast.luminance(0x0F_0F_11) { return .onyx }
        return ground >= InkContrast.luminance(0x2B_2B_30) ? .ash : .dark
    }

    /// `hsl(240 4% 61%)`, 152 152 160.
    private static let greyChannels: (CGFloat, CGFloat, CGFloat) = (152, 152, 160)

    private static func grey(alpha: CGFloat) -> CGColor {
        CGColor(
            srgbRed: greyChannels.0 / 255, green: greyChannels.1 / 255, blue: greyChannels.2 / 255, alpha: alpha
        )
    }

    private static func grey(over packed: UInt32, alpha: CGFloat) -> CGColor {
        func channel(_ shift: UInt32, _ grey: CGFloat) -> CGFloat {
            let ground = CGFloat((packed >> shift) & 0xFF)
            return (ground + (grey - ground) * alpha) / 255
        }
        return CGColor(
            srgbRed: channel(16, greyChannels.0), green: channel(8, greyChannels.1),
            blue: channel(0, greyChannels.2), alpha: 1
        )
    }

    private static func color(_ packed: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((packed >> 16) & 0xFF) / 255,
            green: CGFloat((packed >> 8) & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255,
            alpha: 1
        )
    }
}
