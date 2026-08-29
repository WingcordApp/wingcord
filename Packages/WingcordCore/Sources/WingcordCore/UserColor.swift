import Foundation

/// Colour that came from a person rather than from the app.
///
/// A role's colour, a profile's theme, a name tinted by seniority — everything
/// `Tokens.swift` means by "colour comes from user content". The app's own
/// chrome is achromatic by design and is deliberately **not** in scope here.
///
/// **Saturated colour is fatiguing, and user colour is the part an app cannot
/// art-direct.** Nobody can be stopped from choosing neon magenta as a role
/// colour, and for readers with visual stress, migraine sensitivity or some
/// low-vision conditions that is not a matter of taste. Discord's answer is a
/// single multiplier applied to every user colour, and this is the same one —
/// captured from its own bundle, where a shared hook converts each colour to
/// HSL, scales the saturation, and converts back:
///
/// ```js
/// let {h, s, l} = tinycolor(colour).toHsl();
/// tinycolor({h, s: s * factor, l}).toHexString();
/// ```
///
/// **Hue and lightness are untouched, and that is the whole design.** A colour
/// keeps its identity and its weight on the page — a dark role stays dark, a
/// pale one stays pale, and two roles that were distinguishable by lightness
/// still are. At a factor of zero every user colour becomes the grey of exactly
/// its own brightness, which is a legible page rather than a flattened one.
public enum UserColor {
    /// `value` with its saturation scaled by `factor`, as a 24-bit RGB value.
    ///
    /// A factor of 1 returns the input untouched and without arithmetic, which
    /// is the overwhelmingly common case — the setting is off by default, so
    /// this must cost nothing when it is.
    public static func desaturated(_ value: UInt32, by factor: Double) -> UInt32 {
        guard factor < 1 else { return value }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255

        let highest = max(red, max(green, blue))
        let lowest = min(red, min(green, blue))
        // Already grey: there is no saturation to scale and no hue to preserve,
        // and the round trip would only introduce rounding error.
        guard highest > lowest else { return value }

        let lightness = (highest + lowest) / 2
        let range = highest - lowest
        let saturation = (lightness > 0.5 ? range / (2 - highest - lowest) : range / (highest + lowest))
            * max(factor, 0)

        var hue: Double
        if highest == red {
            hue = (green - blue) / range + (green < blue ? 6 : 0)
        } else if highest == green {
            hue = (blue - red) / range + 2
        } else {
            hue = (red - green) / range + 4
        }
        hue /= 6

        let upper = lightness < 0.5
            ? lightness * (1 + saturation)
            : lightness + saturation - lightness * saturation
        let lower = 2 * lightness - upper
        return pack(
            channel(lower, upper, hue + 1.0 / 3),
            channel(lower, upper, hue),
            channel(lower, upper, hue - 1.0 / 3)
        )
    }

    private static func channel(_ lower: Double, _ upper: Double, _ hue: Double) -> Double {
        var hue = hue
        if hue < 0 { hue += 1 }
        if hue > 1 { hue -= 1 }
        if hue < 1.0 / 6 { return lower + (upper - lower) * 6 * hue }
        if hue < 1.0 / 2 { return upper }
        if hue < 2.0 / 3 { return lower + (upper - lower) * (2.0 / 3 - hue) * 6 }
        return lower
    }

    private static func pack(_ red: Double, _ green: Double, _ blue: Double) -> UInt32 {
        func byte(_ value: Double) -> UInt32 {
            UInt32(min(255, max(0, (value * 255).rounded())))
        }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}
