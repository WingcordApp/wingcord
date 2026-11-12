import CoreGraphics
import Foundation
import os
import WingcordCore

/// The two colours an invitation card is painted in, and whether its app has a
/// cover to lay over them.
///
/// Packed sRGB, so the value is `Hashable` and the canvas can compare a table
/// of them on every update — see `TimelineCanvasView.apply(activityAccents:)`.
nonisolated struct ActivityCardTint: Hashable, Sendable {
    var primary: UInt32
    var secondary: UInt32
    /// Whether `ActivityCardCovers` holds this app's cover. Part of the value
    /// so that a cover landing after the colours is a change the canvas sees.
    var hasCover = false
}

/// Discord's colours for a card that belongs to an app — its game invitation
/// (`572211.h`), read out of the bundle rather than matched by eye.
///
/// ```js
/// let {primaryColor, secondaryColor} = useColors(iconSrc ?? staticBannerSrc)
/// background: `linear-gradient(45deg, ${primaryColor}, ${secondaryColor})`
/// ```
///
/// where the two are the palette's first two swatches (`654107.rh`), each put
/// through `823545`: darkened in CIE Lab, half a step at a time and at most
/// seven times, until its darkness — `1 - (.299 r + .587 g + .114 b) / 255` —
/// reaches 0.725. That is what lets every card carry white words whatever the
/// app's icon is.
nonisolated enum InviteCardColours {
    /// The darkness a colour is taken down to.
    static let darkness = 0.725
    /// What a card wears before its app's icon has been read, and for an app
    /// with none: Discord's `BACKGROUND_SURFACE_HIGH` in its dark theme, twice.
    static let neutral: UInt32 = 0x2B_2D_31

    /// The pair for a palette, in Discord's order.
    static func pair(from palette: [UInt32]) -> (primary: UInt32, secondary: UInt32) {
        let first = palette.first ?? neutral
        let second = palette.count > 1 ? palette[1] : first
        return (darkened(first), darkened(second))
    }

    /// `1 - brightness`, by the weights Discord uses (`317097.OK`).
    static func darknessOf(_ rgb: UInt32) -> Double {
        let red = Double((rgb >> 16) & 0xFF), green = Double((rgb >> 8) & 0xFF), blue = Double(rgb & 0xFF)
        return 1 - (0.299 * red + 0.587 * green + 0.114 * blue) / 255
    }

    /// A colour taken down until white reads on it — `823545`'s loop.
    static func darkened(_ rgb: UInt32) -> UInt32 {
        var colour = rgb
        var step = 1
        while step < 8, darknessOf(colour) < darkness {
            colour = labDarkened(colour, by: 0.5)
            step += 1
        }
        return colour
    }

    // MARK: chroma.js's `darken`

    // `darken(amount)` is `lab[0] -= 18 * amount` in CIE Lab under D65, which
    // is what these constants are: chroma.js's own.
    private static let whiteX = 0.950470, whiteY = 1.0, whiteZ = 1.088830
    private static let t0 = 0.137931034, t1 = 0.206896552, t2 = 0.12841855, t3 = 0.008856452

    static func labDarkened(_ rgb: UInt32, by amount: Double) -> UInt32 {
        func linear(_ byte: UInt32) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func forward(_ value: Double) -> Double {
            value > t3 ? cbrt(value) : value / t2 + t0
        }
        func backward(_ value: Double) -> Double {
            value > t1 ? value * value * value : t2 * (value - t0)
        }
        func encoded(_ value: Double) -> UInt32 {
            let channel = value <= 0.00304 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
            return UInt32(min(255, max(0, (255 * channel).rounded())))
        }
        let red = linear((rgb >> 16) & 0xFF), green = linear((rgb >> 8) & 0xFF), blue = linear(rgb & 0xFF)
        let x = forward((0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / whiteX)
        let y = forward((0.2126729 * red + 0.7151522 * green + 0.0721750 * blue) / whiteY)
        let z = forward((0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / whiteZ)
        let lightness = 116 * y - 16 - 18 * amount
        let a = 500 * (x - y), b = 200 * (y - z)

        let backY = (lightness + 16) / 116
        let backX = backY + a / 500, backZ = backY - b / 200
        let outY = whiteY * backward(backY), outX = whiteX * backward(backX), outZ = whiteZ * backward(backZ)
        let outRed = encoded(3.2404542 * outX - 1.5371385 * outY - 0.4985314 * outZ)
        let outGreen = encoded(-0.9692660 * outX + 1.8760108 * outY + 0.0415560 * outZ)
        let outBlue = encoded(0.0556434 * outX - 0.2040259 * outY + 1.0572252 * outZ)
        return outRed << 16 | outGreen << 8 | outBlue
    }

    static func cgColor(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// The covers an invitation card lays over its colours, decoded.
///
/// **Held here rather than peeked from the image cache.** The card's cover is
/// paint state — it arrives after the card is laid out and nothing in the
/// layout asks the prefetch pass for it — so a cache that evicted it would
/// leave a card with no way to ask again (`INVARIANTS.md` §2.5). There is one
/// per app that has a card on screen, at 600 pixels wide.
@MainActor
enum ActivityCardCovers {
    private static var images: [ApplicationID: CGImage] = [:]

    static func cover(for application: ApplicationID) -> CGImage? { images[application] }

    static func set(_ image: CGImage, for application: ApplicationID) { images[application] = image }
}

/// The two colours of a picture, for a card painted from it — a Listen Along
/// invitation's album art.
///
/// **Read at paint time, once per picture.** The card's art is the host's
/// presence, which changes with every track; quantising it is a millisecond or
/// two the first time a cover is drawn and a dictionary read after. Kept
/// behind a lock because the painter is not the main actor's.
nonisolated enum ArtworkCardColours {
    private static let cache = OSAllocatedUnfairLock<[URL: ActivityCardTint]>(initialState: [:])
    private static let limit = 48

    static func tint(for url: URL, image: CGImage) -> ActivityCardTint {
        if let known = cache.withLock({ $0[url] }) { return known }
        let pair = InviteCardColours.pair(from: ProfileThemePalette.derive(from: image))
        let tint = ActivityCardTint(primary: pair.primary, secondary: pair.secondary)
        cache.withLock { table in
            if table.count >= limit { table.removeAll(keepingCapacity: true) }
            table[url] = tint
        }
        return tint
    }
}
