import Foundation

// MARK: - A theme somebody shared
//
// Discord's message field `shared_client_theme` (web build 641803): the custom
// theme its editor was showing when the sender pressed Share — the gradient's
// colours, its angle, the editor's Color Intensity and which room it sat on.
// The transcript draws it as Discord's card (`tR`: a gradient swatch, "Custom
// Theme", "Created by" and Preview); Wingcord adds Save, and keeps saved ones
// in Settings › Appearance (docs/CLIPS-PRESENCE.md, D25).
//
// The colours render through Discord's own custom-theme generator, which
// `ServerTheme` already carries for a server's theme: the same function, fed
// from here.

public struct SharedClientTheme: Hashable, Sendable, Codable {
    /// The gradient's colours, first to last, spread evenly along the line —
    /// 24-bit sRGB. One colour is drawn as itself twice, as Discord draws it.
    public var colors: [UInt32]
    /// CSS degrees.
    public var gradientAngle: Double
    /// Discord's `base_mix`, `0...100` — the editor's Color Intensity. Its
    /// editor starts at 74.
    public var baseMix: Double
    /// The proto `Theme` the sender was in: 1 dark, 2 light, 3 darker, 4
    /// midnight. Only light is a light room.
    public var baseTheme: Int

    public static let defaultBaseMix: Double = 74

    public init(colors: [UInt32], gradientAngle: Double, baseMix: Double = defaultBaseMix, baseTheme: Int = 1) {
        self.colors = colors
        self.gradientAngle = gradientAngle
        self.baseMix = min(100, max(0, baseMix))
        self.baseTheme = baseTheme
    }

    /// Whether the sender's room was the light one.
    public var isLight: Bool { baseTheme == 2 }

    /// The swatch's stops: every colour, one doubled so a single colour still
    /// spans the line.
    public var gradientStops: [UInt32] {
        colors.count == 1 ? [colors[0], colors[0]] : colors
    }

    /// Discord's check before it keeps one (`74396`'s `d`): colours, and a
    /// room it knows.
    public var isValid: Bool { !colors.isEmpty && (1...4).contains(baseTheme) }

    /// The wire's colours: `"5865F2"`, no `#`.
    public static func hex(_ color: UInt32) -> String {
        String(format: "%06X", color & 0xFF_FF_FF)
    }

    /// A colour off the wire, with or without its `#`.
    public static func color(fromHex text: String) -> UInt32? {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return value
    }
}
