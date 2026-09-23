import Foundation

// MARK: - Ink that can be read on the ground it is drawn on
//
// A theme moves the ground, and a colour chosen by somebody else — a role, a
// derived accent — was chosen against no ground at all. A navy role colour that
// reads on True Black is mud on a lifted Nightfall; a pale one that reads on
// Nightfall is glare on a light window. So a colour that sets TYPE is checked
// against the brightest ground it can land on, and moved just far enough to
// read there.
//
// **Moved in lightness only.** Hue and chroma are the colour's identity — the
// role still reads as the role — so the fix is the one a designer would make by
// hand: the same colour, a step lighter or darker. Chroma gives way only where
// the gamut runs out at that lightness, which `Oklch.packedRGB()` handles.

nonisolated enum InkContrast {
    /// WCAG 2's floor for body text. Names are the most-read coloured type in
    /// the app, so they get the body-text bar, not the large-text one.
    static let textMinimum = 4.5

    /// WCAG 2 relative luminance of a 24-bit sRGB colour.
    static func luminance(_ packed: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((packed >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `ink`, moved in lightness as little as it takes to read against
    /// `ground` at `minimum` — or unchanged when it already does.
    ///
    /// **Away from the ground**: lighter on a dark ground, darker on a light
    /// one. Sixteen bisections of Oklab lightness, which is finer than the
    /// eight bits the answer is rounded into.
    static func legible(_ ink: UInt32, on ground: UInt32, minimum: Double = textMinimum) -> UInt32 {
        guard ratio(ink, ground) < minimum else { return ink }
        let colour = Oklch(packedRGB: ink)
        // The far end of the move: white on a dark ground, black on a light
        // one. The crossover is where white and black read equally well.
        let lightens = luminance(ground) < 0.18
        var near = colour.lightness
        var far = lightens ? 1.0 : 0.0
        for _ in 0..<16 {
            let middle = (near + far) / 2
            let candidate = Oklch(lightness: middle, chroma: colour.chroma, hue: colour.hue).packedRGB()
            if ratio(candidate, ground) >= minimum { far = middle } else { near = middle }
        }
        return Oklch(lightness: far, chroma: colour.chroma, hue: colour.hue).packedRGB()
    }

    /// `top` laid over `bottom` at `opacity`, blended the way the window
    /// composites it: channel by channel in gamma-encoded sRGB.
    static func composite(_ top: UInt32, over bottom: UInt32, opacity: Double) -> UInt32 {
        func mix(_ shift: UInt32) -> UInt32 {
            let a = Double((top >> shift) & 0xFF)
            let b = Double((bottom >> shift) & 0xFF)
            return UInt32((a * opacity + b * (1 - opacity)).rounded())
        }
        return mix(16) << 16 | mix(8) << 8 | mix(0)
    }
}
