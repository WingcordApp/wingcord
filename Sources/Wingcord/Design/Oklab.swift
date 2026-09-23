import Foundation

// MARK: - Oklab
//
// The colour space every theme in this app is derived in, and the reason the
// ten presets look like a set rather than like ten opinions.
//
// WHY NOT HSL, which is what a "pick a hue" control implies. HSL's lightness is
// arithmetic on the largest and smallest channel and has nothing to do with how
// bright a colour looks: `hsl(60 100% 50%)` and `hsl(240 100% 50%)` claim the
// same lightness, and one is yellow and the other is navy. A ramp built on it
// therefore has a different perceived contrast at every hue — the green theme's
// panels separate cleanly, the blue theme's are mud, and no amount of tuning one
// fixes the other because they do not share a scale.
//
// Oklab's L *is* perceived lightness. So the app's ramp is stated ONCE, as three
// lightness steps, and every theme — the ten presets, and anything the reader
// builds — gets exactly the same separation between the reading surface, a panel
// on it and a row inside that panel. That is what makes a hue a *choice* rather
// than a retune.
//
// Björn Ottosson's coefficients, transcribed rather than rederived.
// https://bottosson.github.io/posts/oklab/

/// A colour as lightness, chroma and hue — the polar form of Oklab.
///
/// `nonisolated` because a theme is resolved on the main actor and read from the
/// drawn canvases off it. Everything here is arithmetic on three doubles.
nonisolated struct Oklch: Hashable, Sendable {
    /// Perceived lightness. 0 is black, 1 is white. The app's grounds live
    /// between 0.10 and 0.25.
    var lightness: Double
    /// Colourfulness. 0 is a neutral grey at that lightness. Beyond about 0.37
    /// nothing is representable on a display at any hue.
    var chroma: Double
    /// Degrees. 0 is pink-red, 120 is green, 240 is blue.
    var hue: Double

    init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    // MARK: To sRGB

    /// The nearest **in-gamut** sRGB value, as the 24-bit integer the rest of
    /// the app passes colours around as.
    ///
    /// **Chroma is reduced until the colour fits; lightness and hue are not
    /// touched.** Clamping the three channels instead is the obvious answer and
    /// is wrong in a way that is invisible one colour at a time: it moves the
    /// hue *and* the lightness, so a ramp that leaves the gamut at one end comes
    /// back a different colour rather than a paler one. Since the ramp's whole
    /// value is that every theme separates identically, the one thing that may
    /// not drift is L.
    ///
    /// Sixteen bisections resolve chroma to one part in 65,536, which is far
    /// finer than the 8 bits it is about to be rounded into. It runs when a
    /// theme is installed and when the picker's field is rebuilt — never in a
    /// draw.
    func packedRGB() -> UInt32 {
        if let exact = Self.pack(linear: linearRGB(chroma: chroma)) { return exact }
        var low = 0.0
        var high = chroma
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if Self.pack(linear: linearRGB(chroma: middle)) == nil {
                high = middle
            } else {
                low = middle
            }
        }
        // `low` is the last chroma known to fit. At chroma 0 the colour is a
        // grey, which is in gamut at every lightness in 0...1 — so this cannot
        // fail to find one, and the fallback below is for a lightness outside
        // that range rather than for a hue.
        return Self.pack(linear: linearRGB(chroma: low))
            ?? Self.pack(linear: linearRGB(chroma: 0), clamping: true)
            ?? 0
    }

    /// The sRGB value a **browser** would paint for this colour: out-of-gamut
    /// channels clipped, where `packedRGB()` gives chroma up instead.
    ///
    /// For reproducing a CSS colour exactly, and nothing else. Near white, a
    /// `color-mix(in oklab, …)` of two in-gamut colours lands just outside sRGB
    /// — seven of Discord's twenty-four light surfaces do — and Chrome clips
    /// each channel. The house fit would come back a unit off on three of them.
    func clippedRGB() -> UInt32 {
        Self.pack(linear: linearRGB(chroma: chroma), clamping: true) ?? 0
    }

    /// Linear-light sRGB, unclamped, at an arbitrary chroma.
    private func linearRGB(chroma: Double) -> SIMD3<Double> {
        let hueRadians = hue * .pi / 180
        let a = chroma * cos(hueRadians)
        let b = chroma * sin(hueRadians)

        let longCube = lightness + 0.3963377774 * a + 0.2158037573 * b
        let mediumCube = lightness - 0.1055613458 * a - 0.0638541728 * b
        let shortCube = lightness - 0.0894841775 * a - 1.2914855480 * b

        let long = longCube * longCube * longCube
        let medium = mediumCube * mediumCube * mediumCube
        let short = shortCube * shortCube * shortCube

        return SIMD3(
            4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short,
            -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short,
            -0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short
        )
    }

    /// Gamma-encodes and packs, or returns nil if any channel left the cube.
    ///
    /// A hair of tolerance either side: the transform is a chain of cube roots
    /// and a colour that is mathematically on the boundary lands a few parts in
    /// 10^9 outside it, and rejecting those would cost the bisection its whole
    /// last step for a difference that cannot survive rounding to 8 bits.
    private static func pack(linear: SIMD3<Double>, clamping: Bool = false) -> UInt32? {
        var packed: UInt32 = 0
        for index in 0..<3 {
            var channel = linear[index]
            if !clamping {
                guard channel > -1e-7, channel < 1 + 1e-7 else { return nil }
            }
            channel = min(1, max(0, channel))
            let encoded = channel <= 0.0031308
                ? channel * 12.92
                : 1.055 * pow(channel, 1 / 2.4) - 0.055
            packed = packed << 8 | UInt32((encoded * 255).rounded())
        }
        return packed
    }

    // MARK: Mixing

    /// CSS `color-mix(in oklab, …)`: `weight` of the way from this colour to
    /// `other`, along a straight line through Oklab's **rectangular** form.
    ///
    /// Rectangular and not polar, because that is what the CSS space names and
    /// because the difference is not small: mixing in Oklch walks the hue round
    /// the wheel, and a grey — which has no hue — would drag the answer toward
    /// pink-red. Against Chrome's own `color-mix` over Discord's surfaces this
    /// lands on the same byte every time.
    func mixed(with other: Oklch, weight: Double) -> Oklch {
        let (a1, b1) = rectangular
        let (a2, b2) = other.rectangular
        let a = a1 + (a2 - a1) * weight
        let b = b1 + (b2 - b1) * weight
        let chroma = (a * a + b * b).squareRoot()
        var hue = chroma < 1e-9 ? 0 : atan2(b, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return Oklch(
            lightness: lightness + (other.lightness - lightness) * weight,
            chroma: chroma,
            hue: hue
        )
    }

    private var rectangular: (a: Double, b: Double) {
        let radians = hue * .pi / 180
        return (chroma * cos(radians), chroma * sin(radians))
    }

    // MARK: From sRGB

    /// The polar Oklab of a 24-bit sRGB value.
    ///
    /// Used to state the app's original near-black in the same terms every
    /// derived theme is stated in, and by the tests that pin the ramp.
    init(packedRGB value: UInt32) {
        func linear(_ byte: UInt32) -> Double {
            let channel = Double(byte) / 255
            return channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        let red = linear((value >> 16) & 0xFF)
        let green = linear((value >> 8) & 0xFF)
        let blue = linear(value & 0xFF)

        let long = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let medium = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let short = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)

        lightness = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short
        let a = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short
        let b = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short

        chroma = (a * a + b * b).squareRoot()
        // A grey has no hue, and `atan2(0, 0)` answering zero would make it
        // pink-red — which is fine while chroma is zero and wrong the moment
        // something adds chroma to a hue read back out of a grey.
        hue = chroma < 1e-9 ? 0 : (atan2(b, a) * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
    }
}
