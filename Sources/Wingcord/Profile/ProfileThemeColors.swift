import Foundation

/// What Discord turns a profile's two colours into.
///
/// **A port, read out of Discord's own bundle and its own stylesheet, not fitted
/// to a screenshot.** `ProfileThemePalette` answers where the pair comes from
/// when nobody chose one; this answers what every surface does with the pair
/// afterwards — and the two halves had been separated for long enough that the
/// second was being guessed at while the first was exact.
///
/// The whole of it is four functions and one stylesheet. From
/// `useProfileThemeStyle` (webpack `920601`) and `253781.css`:
///
/// ```css
/// .outer.custom-user-profile-theme {            /* the rim: the RAW pair */
///   background: linear-gradient(var(--primary) var(--banner-height),
///                               var(--secondary) calc(100% - var(--footer-height)));
///   padding: 2px;                               /* 4px on the modal */
/// }
/// .custom-user-profile-theme .inner {           /* popout, sidebar, identity card */
///   background: linear-gradient(var(--start), var(--start) var(--banner-height), var(--end));
/// }
/// .custom-user-profile-theme.user-profile-modal-v2 .inner {   /* the full profile */
///   background: linear-gradient(color-mix(in oklab, var(--overlay) 80%, var(--modal-bg)),
///                               color-mix(in oklab, var(--overlay) 20%, var(--modal-bg)) 300px);
/// }
/// ```
///
/// where `--start` is `color-mix(in oklab, var(--overlay) 100%, var(--primary))`
/// and `--end` the same over the secondary. **`color-mix(in oklab, X 100%, Y)`
/// is X** — the second colour contributes nothing at 100% — so the inner of a
/// popout is a FLAT translucent veil and the gradient a reader sees through it
/// is the outer's. Checked in a browser rather than reasoned about, because the
/// rule reads like a blend and is not one.
///
/// `--overlay` is the design token `PROFILE_GRADIENT_OVERLAY`: **black at 0.6 on
/// a dark theme, white at 0.6 on a light one** (0.8 for both when the reader
/// turns on "sync profile theme with my theme", which this client has no
/// equivalent of). So a themed card is the person's gradient at **40 %** over
/// black or white, and nothing else.
///
/// **The theme is the PROFILE's, not the app's** — `isDark(_:)` below — which is
/// the whole of "a light card in a dark app", and the reason two accounts side
/// by side can be a near-white card and a near-black one.
///
/// Verified against Discord's own rendering for two accounts, sampled off
/// screenshots, every prediction within a unit:
///
/// ```
/// robinresting  #8c8981 / #d8d7d6   modal body  #e5e5e3 → #d4d3d0   measured #e5e5e3 → #d4d3d0
///                                     identity    #d1d0cd → #efefef   measured #d2d1ce → #efefee
///                                     button      #35332c             measured #35332d
/// spiwal          #07ADEA / #4F003B   modal base  #c8c8dc             measured #c8c9dc
///                                     button      #005287             measured #005187
/// ```
///
/// The remaining unit on spiwal's identity ramp is the screenshot's Display P3
/// against this arithmetic's sRGB — greys are identical in both, which is why
/// the grey account lands exactly and the cyan one lands within three.
///
/// Packed 24-bit sRGB in and out, because that is what `theme_colors` carries
/// and what the quantiser answers with; going through `Color` would cost a
/// bridge per read and lose the exactness the whole file is for.
nonisolated enum ProfileThemeColors {
    // MARK: The profile's own theme

    /// Whether this profile draws itself DARK.
    ///
    /// **YIQ brightness, not relative luminance and not Oklab** — Discord's
    /// `1 - (0.299r + 0.587g + 0.114b) / 255 > 0.5`, which is a different
    /// question from either and answers differently near the middle. Both of
    /// the accounts this was checked against sit within four hundredths of the
    /// threshold, so a "close enough" luminance here is not close enough: it
    /// decides whether the card is near-white or near-black.
    ///
    /// The **primary** alone decides. The secondary can be anything.
    static func isDark(_ primary: UInt32) -> Bool {
        let red = Double((primary >> 16) & 0xFF)
        let green = Double((primary >> 8) & 0xFF)
        let blue = Double(primary & 0xFF)
        return 1 - (0.299 * red + 0.587 * green + 0.114 * blue) / 255 > 0.5
    }

    // MARK: The veil

    /// Discord's overlay, applied: `colour` at 40 % over black or white.
    ///
    /// One plain sRGB composite. The stylesheet wraps it in a `color-mix` that
    /// resolves to the overlay alone, and the overlay is opaque black or opaque
    /// white at 0.6 — so there is no colour-space subtlety here at all, and
    /// SwiftUI's own `Color.mix(with:by:)` would introduce one by interpolating
    /// perceptually.
    static func veiled(_ colour: UInt32, dark: Bool, alpha: Double = 0.6) -> UInt32 {
        let over = dark ? 0.0 : 255.0
        return pack(channels(colour).map { $0 * (1 - alpha) + over * alpha })
    }

    // MARK: The full profile's base

    /// The colour the full profile's modal is built on — Discord's `v2`.
    ///
    /// **The Lab midpoint of the pair, with its lightness forced into a band.**
    /// `clamp(l, 0.8, 1)` on a light profile and `clamp(l, 0, 0.1)` on a dark
    /// one, which is what makes the modal a near-white or a near-black card
    /// that still carries the person's hue. The midpoint is taken in CIE Lab
    /// and the clamp is applied in HSL — two spaces in four lines, and swapping
    /// either one moves the answer.
    ///
    /// `theme` is passed only when the reader has asked for profiles to follow
    /// the app's own theme; left nil, the profile decides for itself.
    static func modalBackground(
        primary: UInt32,
        secondary: UInt32,
        forcedDark theme: Bool? = nil
    ) -> UInt32 {
        let dark = theme ?? isDark(primary)
        let first = lab(of: channels(primary)), second = lab(of: channels(secondary))
        let midpoint = rgb(fromLab: [
            (first[0] + second[0]) / 2,
            (first[1] + second[1]) / 2,
            (first[2] + second[2]) / 2,
        ])
        var (hue, saturation, lightness) = hsl(of: midpoint)
        // Two decimals, exactly as the reference rounds before it clamps: a
        // lightness of 0.804 and one of 0.7951 are the same answer afterwards
        // and a lightness of 0.7949 is not.
        lightness = (lightness * 100).rounded() / 100
        lightness = dark ? min(max(lightness, 0), 0.1) : min(max(lightness, 0.8), 1)
        return pack(rgb(fromHSL: (hue, saturation, lightness)))
    }

    /// One stop of the modal's own ramp: the overlay mixed into the base and
    /// composited back over it.
    ///
    /// **This one genuinely is an Oklab mix**, unlike the popout's — the
    /// percentages are 80 and 20 rather than 100, so both colours contribute
    /// and the space matters. The overlay is neutral, so in polar Oklab the
    /// hue survives untouched, the chroma is scaled and only the lightness
    /// takes the overlay's: three lines rather than a matrix round trip.
    ///
    /// - Parameter fraction: how much of the overlay. Discord's two stops are
    ///   0.8 at the modal's top and 0.2 at 300 points down, flat after.
    static func modalRamp(over base: UInt32, dark: Bool, fraction: Double) -> UInt32 {
        let overlayAlpha = 0.6
        let overlayLightness = dark ? 0.0 : 1.0
        let baseColour = Oklch(packedRGB: base)
        let alpha = fraction * overlayAlpha + (1 - fraction)
        guard alpha > 0 else { return base }
        let mixed = Oklch(
            lightness: (fraction * overlayAlpha * overlayLightness
                + (1 - fraction) * baseColour.lightness) / alpha,
            chroma: baseColour.chroma * (1 - fraction) / alpha,
            hue: baseColour.hue
        )
        let source = channels(mixed.packedRGB()), ground = channels(base)
        return pack((0..<3).map { source[$0] * alpha + ground[$0] * (1 - alpha) })
    }

    // MARK: The primary button

    /// `--profile-gradient-button-color`: the person's primary, darkened until
    /// it can carry white text.
    ///
    /// Discord's `ensureContrast(primary, base: white, ratio: 7)` with its own
    /// tolerance of 3 — so the answer is the first step whose WCAG contrast
    /// against **white** lands in `7...10`, and a step is ±18 of CIE Lab
    /// lightness, which is `chroma.darken()`'s whole definition.
    ///
    /// It is a real function of the colour rather than a shade of it: a grey
    /// profile's button comes out `#35332c` and a cyan one's `#005287`, both
    /// measured off Discord within a unit.
    static func buttonFill(_ primary: UInt32) -> UInt32 {
        let white = 1.0
        let floor = 7.0, ceiling = 10.0
        var colour = channels(primary)
        var ratio = contrast(luminance(colour), white)
        for _ in 0..<100 {
            let tooLow = ratio < floor, tooHigh = ratio > ceiling
            guard tooLow || tooHigh else { break }
            let lighterThanBase = luminance(colour) > white
            let step = (tooHigh && lighterThanBase) || (tooLow && !lighterThanBase) ? -18.0 : 18.0
            var moved = lab(of: colour)
            moved[0] += step
            colour = rgb(fromLab: moved)
            ratio = contrast(luminance(colour), white)
        }
        return pack(colour)
    }

    // MARK: - Arithmetic
    //
    // Everything below is transcribed: CIE Lab with `chroma-js`'s own D65 white
    // point, and that library's HSL. They are the spaces Discord's two colour
    // functions are written in, and substituting a nicer one moves the answer.

    private static func channels(_ value: UInt32) -> [Double] {
        [Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF)]
    }

    private static func pack(_ channels: [Double]) -> UInt32 {
        var packed: UInt32 = 0
        for channel in channels {
            packed = packed << 8 | UInt32(min(255, max(0, channel)).rounded())
        }
        return packed
    }

    private static func toLinear(_ channel: Double) -> Double {
        let value = channel / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func toEncoded(_ linear: Double) -> Double {
        let value = linear <= 0.00304 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return min(255, max(0, value * 255))
    }

    private static func luminance(_ channels: [Double]) -> Double {
        0.2126 * toLinear(channels[0]) + 0.7152 * toLinear(channels[1])
            + 0.0722 * toLinear(channels[2])
    }

    private static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    // D65, and the exact constants `chroma-js` carries.
    private static let whiteX = 0.95047, whiteY = 1.0, whiteZ = 1.08883
    private static let labT0 = 0.137931034, labT1 = 0.206896552
    private static let labT2 = 0.12841855, labT3 = 0.008856452

    private static func lab(of channels: [Double]) -> [Double] {
        let red = toLinear(channels[0]), green = toLinear(channels[1])
        let blue = toLinear(channels[2])
        func f(_ t: Double) -> Double { t > labT3 ? cbrt(t) : t / labT2 + labT0 }
        let x = f((0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / whiteX)
        let y = f((0.2126729 * red + 0.7151522 * green + 0.0721750 * blue) / whiteY)
        let z = f((0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / whiteZ)
        return [max(0, 116 * y - 16), 500 * (x - y), 200 * (y - z)]
    }

    private static func rgb(fromLab lab: [Double]) -> [Double] {
        func f(_ t: Double) -> Double { t > labT1 ? t * t * t : labT2 * (t - labT0) }
        let y = (lab[0] + 16) / 116
        let x = whiteX * f(y + lab[1] / 500)
        let z = whiteZ * f(y - lab[2] / 200)
        let luminance = whiteY * f(y)
        return [
            toEncoded(3.2404542 * x - 1.5371385 * luminance - 0.4985314 * z),
            toEncoded(-0.9692660 * x + 1.8760108 * luminance + 0.0415560 * z),
            toEncoded(0.0556434 * x - 0.2040259 * luminance + 1.0572252 * z),
        ]
    }

    private static func hsl(of channels: [Double]) -> (Double, Double, Double) {
        let red = channels[0] / 255, green = channels[1] / 255, blue = channels[2] / 255
        let lowest = min(red, green, blue), highest = max(red, green, blue)
        let lightness = (highest + lowest) / 2
        guard highest > lowest else { return (0, 0, lightness) }
        let spread = highest - lowest
        let saturation = lightness < 0.5
            ? spread / (highest + lowest)
            : spread / (2 - highest - lowest)
        var hue: Double
        if red == highest {
            hue = (green - blue) / spread
        } else if green == highest {
            hue = 2 + (blue - red) / spread
        } else {
            hue = 4 + (red - green) / spread
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }

    /// **Rounds, and the Lab conversion above deliberately does not.** The
    /// reference's Lab round trip keeps its floats — the midpoint's lightness is
    /// read off unrounded channels — and only its HSL conversion quantises. Put
    /// a rounding in the Lab step, or leave it out of this one, and the modal's
    /// base moves by a unit on most profiles.
    private static func rgb(fromHSL hsl: (Double, Double, Double)) -> [Double] {
        let (hue, saturation, lightness) = hsl
        guard saturation > 0 else {
            let grey = (lightness * 255).rounded()
            return [grey, grey, grey]
        }
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let offset = lightness - chroma / 2
        let triple: (Double, Double, Double) = switch sector {
        case ..<1: (chroma, second, 0)
        case ..<2: (second, chroma, 0)
        case ..<3: (0, chroma, second)
        case ..<4: (0, second, chroma)
        case ..<5: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        return [
            ((triple.0 + offset) * 255).rounded(),
            ((triple.1 + offset) * 255).rounded(),
            ((triple.2 + offset) * 255).rounded(),
        ]
    }
}
