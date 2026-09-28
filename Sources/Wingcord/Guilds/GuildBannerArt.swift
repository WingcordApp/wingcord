import CoreGraphics
import Foundation
import WingcordCore

/// The banner of Discord's server profile card, where the server has no
/// artwork for it: a glow of one colour (module `649640`).
///
/// **One drawing for both cards Discord draws it on** — the server tag's card
/// and an invite's — reached through a `CGContext` from SwiftUI and from the
/// transcript alike.
///
/// The colour is the server's brand colour, else the first swatch of its icon
/// (`aG`, through the same quantiser a profile's colours come from), else
/// Discord's neutral.
nonisolated enum GuildBannerArt {

    /// `GUILD_PROFILE_BANNER_BACKGROUND_DEFAULT`: `NEUTRAL_73` in a dark room,
    /// `NEUTRAL_40` in a light one.
    static func defaultColour(isLight: Bool) -> UInt32 { isLight ? 0x70717A : 0x2C2D32 }

    /// The icon a banner's colour is read from, at the size Discord reads it
    /// (64 pixels) — the one key the deriving and the drawing both use.
    static func paletteURL(guildID: GuildID, iconHash: String) -> URL? {
        CDN.guildIcon(guildID: guildID, hash: iconHash, side: 32)
    }

    /// The server's own header artwork, which Discord shows only for a server
    /// that is discoverable (`_3`): its custom banner.
    ///
    /// **`custom_banner_hash` is a discovery splash**, not a banner:
    /// `/discovery-splashes/{guild}/{hash}` answers 200 for it, where
    /// `/banners/` and `/clan-banners/` answer 404 (a real family, no such
    /// asset) and `/guild-profile-banners/`, `/profile-banners/` and
    /// `/tag-banners/` answer 403 (no such family). The ordinary `banner_hash`
    /// is the one over the channel list, which Discord's card never shows.
    static func artworkURL(
        guildID: GuildID, customBannerHash: String?, features: Set<String>, width: CGFloat
    ) -> URL? {
        guard features.contains("DISCOVERABLE"), let customBannerHash else { return nil }
        return CDN.guildDiscoverySplash(guildID: guildID, hash: customBannerHash, width: width)
    }

    /// Discord's `n6`: the colour brightened by 1.75, glowing up from below the
    /// banner's foot into the colour itself —
    /// `radial-gradient(105.43% 127.05% at 50.1% 127.05%, light 20.65%, colour 85.16%)`.
    static func drawGlow(_ colour: UInt32, in rect: CGRect, context: CGContext) {
        let light = ProfileThemeColors.brightened(colour, by: 1.75)
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [cgColor(light), cgColor(colour)] as CFArray,
            locations: [0.2065, 0.8516]
        ) else { return }
        context.saveGState()
        context.clip(to: rect)
        // The ellipse as the unit circle: stretch the space by its two radii
        // about its centre, then draw a circle of radius one.
        context.translateBy(x: rect.minX + rect.width * 0.501, y: rect.minY + rect.height * 1.2705)
        context.scaleBy(x: rect.width * 1.0543, y: rect.height * 1.2705)
        context.drawRadialGradient(
            gradient,
            startCenter: .zero, startRadius: 0,
            endCenter: .zero, endRadius: 1,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private static func cgColor(_ rgb: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255,
            green: CGFloat(rgb >> 8 & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
