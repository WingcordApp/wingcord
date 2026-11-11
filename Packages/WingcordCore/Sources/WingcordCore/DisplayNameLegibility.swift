import Foundation

/// Discord's contrast step for a display name's colours.
///
/// **Every colour of a style is moved before anything is drawn with it** — its
/// `lZ` (`998304`), called from the name component itself: each chosen colour
/// is stepped in HSL lightness, a twentieth at a time and at most ten times,
/// until it reaches the effect's minimum contrast against the surface the name
/// is on. Lighter on a dark surface, darker on a light one.
///
/// This is why a navy gradient reads as sky blue in Discord's dark theme, and
/// drawing the wire's colours as sent is why the same name came out darker
/// here. The derived shades — Toon's highlights, Pop's outline, Neon's stroke —
/// are taken from the moved colour, so they move with it.
public extension DisplayNameStyle {

    /// What a name on a dark surface is checked against: Discord's own dark
    /// theme's `--background-base-low`.
    ///
    /// **Discord's ground, not this app's.** The point of the step is that a
    /// name looks the way its owner saw it when they chose it, and they chose
    /// it in Discord. This app's dark grounds are darker than that one, so a
    /// colour that reads there reads here with room to spare.
    static let darkGround: UInt32 = 0x36_38_3D
    /// The same for a light surface.
    static let lightGround: UInt32 = 0xFA_FA_FA

    /// The ground for a surface of the given appearance.
    static func ground(isDark: Bool) -> UInt32 { isDark ? darkGround : lightGround }
    /// What Toon is checked against, whatever it is drawn on: its own dark
    /// stroke is the ground its fill sits in.
    static let toonGround: UInt32 = 0x33_33_33

    /// The style with its colours moved to read on `ground`.
    func legible(on ground: UInt32) -> DisplayNameStyle {
        guard !colors.isEmpty else { return self }
        let against = effect == .toon ? Self.toonGround : ground
        let moved = colors.map { Self.legible($0, on: against, ratio: effect.minimumContrast) }
        guard moved != colors else { return self }
        return DisplayNameStyle(font: font, effect: effect, colors: moved)
    }

    /// One colour, stepped until it reads. Discord's loop, number for number.
    static func legible(_ color: UInt32, on ground: UInt32, ratio: Double) -> UInt32 {
        let groundLuminance = luminance(ground)
        let lightens = groundLuminance <= 0.5
        var shade = HSL(rgb: color)
        var packed = color
        for _ in 0..<10 {
            guard contrast(luminance(packed), groundLuminance) < ratio else { break }
            if lightens {
                guard shade.lightness < 95 else { break }
                shade.lightness += 5
            } else {
                guard shade.lightness > 5 else { break }
                shade.lightness -= 5
            }
            packed = shade.rgb
        }
        return packed
    }

    /// WCAG relative luminance, which is what chroma.js's `luminance` is.
    private static func luminance(_ packed: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((packed >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

public extension DisplayNameEffect {
    /// The contrast a colour of this effect is moved to (`898985`): three, or
    /// two and a half for the effects that are ramps and so never sit on one
    /// colour for long.
    var minimumContrast: Double {
        switch self {
        case .gradient, .glow, .prism: 2.5
        case .solid, .neon, .toon, .pop, .gummy: 3
        }
    }
}
