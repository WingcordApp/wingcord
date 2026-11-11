import Foundation

/// The six shades a styled display name is painted from, derived from the one
/// colour its owner picked.
///
/// **Hue and saturation are held; only lightness moves, and it SCALES.** Every
/// shade is `main` with its lightness multiplied — 1.2, 1.6, 0.4, 0.2 — which is
/// why a pale pick produces a white `light2` on its own rather than needing a
/// case for it. Solved against four captured palettes across three hues and two
/// saturation levels; every one lands within 0.16 of the measured lightness.
///
/// **The multipliers are not offsets, and one sample cannot tell them apart.**
/// A palette whose main sits at L 54 makes 1.6 and 0.4 look like ±32.5, and a
/// palette whose main sits at L 67 makes `neonStroke` look like `l * 0.89` when
/// it is a flat 60. Both were fitted, believed, and wrong. Anything added here
/// wants two palettes before it is trusted.
///
/// Built once where a profile is resolved, never inside a draw — the same rule
/// `UserColor` follows, and for the same reason.
public struct DisplayNamePalette: Hashable, Sendable {
    /// The colour the account chose. `colors[0]` on the wire.
    public let main: UInt32
    /// Toon's mid highlight and Pop's extrusion light. `l * 1.2`.
    public let light1: UInt32
    /// Toon's near-white. `l * 1.6`, **clamped**, so a bright pick lands on pure
    /// white and collapses the stops that use it. That is the effect changing
    /// character on its own, and it is correct.
    public let light2: UInt32
    /// Pop's outline. `l * 0.2`.
    public let dark2: UInt32
    /// Toon's outline and fill under the gradient. `l * 0.4`, never under 12.
    public let toonStroke: UInt32
    /// Neon's stroke: saturation lifted by 1.2 and clamped, lightness a tenth
    /// over the source and capped at 60.
    public let neonStroke: UInt32
    /// The colour Neon's white core drops to on each flicker. Read out of the
    /// keyframe rather than fitted — its `min(1, s)` guard is what keeps a fully
    /// grey pick grey instead of flashing it coloured.
    public let flickerOff: UInt32

    public init(main: UInt32) {
        let base = HSL(rgb: main)
        self.main = main
        light1 = base.scalingLightness(by: 1.2).rgb
        light2 = base.scalingLightness(by: 1.6).rgb
        dark2 = base.scalingLightness(by: 0.2).rgb
        // `max(.12, .4 * l)`: the floor is what keeps Toon's outline from
        // going to black under a dark pick.
        toonStroke = HSL(
            hue: base.hue,
            saturation: base.saturation,
            lightness: max(12, base.lightness * 0.4)
        ).rgb
        // `min(.6, l + .1)`: a tenth lighter than the pick, and never past 60.
        neonStroke = HSL(
            hue: base.hue,
            saturation: min(100, base.saturation * 1.2),
            lightness: min(60, base.lightness + 10)
        ).rgb
        flickerOff = HSL(
            hue: base.hue,
            saturation: min(100, min(1, base.saturation) * (base.saturation * 1.1 + 10)),
            lightness: 85
        ).rgb
    }
}

/// CSS `hsl()`, which is the space Discord derives in.
///
/// Not a general colour type: it exists so the derivation above reads as the
/// arithmetic it is, and it round-trips through 8-bit RGB because that is what
/// the wire carries and what the comparison against Discord's own output was
/// made in.
struct HSL {
    /// Degrees, 0..<360.
    var hue: Double
    /// Percent, 0...100.
    var saturation: Double
    /// Percent, 0...100.
    var lightness: Double

    init(hue: Double, saturation: Double, lightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    init(rgb: UInt32) {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        let high = max(r, g, b)
        let low = min(r, g, b)
        let span = high - low
        lightness = (high + low) * 50

        guard span > 0 else {
            hue = 0
            saturation = 0
            return
        }
        // The denominator flips at L 50%: above it the span is measured against
        // the headroom to white, below it against the floor. Using one branch
        // for both is how a light colour comes back desaturated.
        saturation = (high + low > 1 ? span / (2 - high - low) : span / (high + low)) * 100
        let sector: Double =
            if high == r { (g - b) / span + (g < b ? 6 : 0) }
            else if high == g { (b - r) / span + 2 }
            else { (r - g) / span + 4 }
        hue = sector * 60
    }

    /// The same colour with its lightness multiplied, clamped to white.
    func scalingLightness(by factor: Double) -> HSL {
        HSL(hue: hue, saturation: saturation, lightness: min(100, lightness * factor))
    }

    var rgb: UInt32 {
        let l = lightness / 100
        let s = saturation / 100
        guard s > 0 else {
            let grey = UInt32((l * 255).rounded())
            return grey << 16 | grey << 8 | grey
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let h = hue / 360
        let r = Self.channel(p, q, h + 1.0 / 3)
        let g = Self.channel(p, q, h)
        let b = Self.channel(p, q, h - 1.0 / 3)
        return UInt32((r * 255).rounded()) << 16
            | UInt32((g * 255).rounded()) << 8
            | UInt32((b * 255).rounded())
    }

    private static func channel(_ p: Double, _ q: Double, _ offset: Double) -> Double {
        var t = offset
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
}
