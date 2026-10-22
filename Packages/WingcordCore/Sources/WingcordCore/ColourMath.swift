import Foundation

// MARK: - The colour picker's arithmetic
//
// docs/CLIPS-PRESENCE.md, Phase 9 — Wingcord's own colour picker (Alex: "cool,
// unique, playful, for example with haptics"). Everything here is the part that
// can be wrong without looking wrong: the hue that survives a trip through grey,
// the hex a reader types, the name a colour is called, and where the hue rail's
// detents pull. The view only draws it.

/// A colour as the picker holds it — hue, saturation and brightness, each 0…1.
///
/// **Held as HSB, not as the 24-bit value it saves to.** A colour dragged to
/// black or to grey has no hue left in RGB, so a picker that stored RGB would
/// snap its hue thumb back to red the moment the puck touched an edge. The
/// value is derived from this; this is never derived from the value except when
/// a colour arrives from outside.
public struct HSBColour: Hashable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = Self.wrap(hue)
        self.saturation = min(max(saturation, 0), 1)
        self.brightness = min(max(brightness, 0), 1)
    }

    /// From Discord's 24-bit integer. A grey keeps hue 0 — the caller that
    /// cares keeps the hue it had (`keepingHue(of:)`).
    public init(rgb: UInt32) {
        let red = Double((rgb >> 16) & 0xFF) / 255
        let green = Double((rgb >> 8) & 0xFF) / 255
        let blue = Double(rgb & 0xFF) / 255
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let delta = high - low
        var hue = 0.0
        if delta > 0 {
            if high == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if high == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
        }
        self.init(hue: hue, saturation: high == 0 ? 0 : delta / high, brightness: high)
    }

    /// The 24-bit value Discord stores.
    public var rgb: UInt32 {
        let h = hue * 6
        let sector = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let v = brightness
        let p = v * (1 - saturation)
        let q = v * (1 - saturation * f)
        let t = v * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch sector {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        func byte(_ x: Double) -> UInt32 { UInt32((min(max(x, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    /// This colour, with `other`'s hue where this one has none to speak of —
    /// so a value arriving as grey or black does not throw the rail back to red.
    public func keepingHue(of other: HSBColour) -> HSBColour {
        guard saturation < 0.001 || brightness < 0.001 else { return self }
        var kept = self
        kept.hue = other.hue
        if brightness < 0.001 { kept.saturation = other.saturation }
        return kept
    }

    private static func wrap(_ hue: Double) -> Double {
        let wrapped = hue.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }
}

public enum ColourText {
    /// "#F06EB3".
    public static func hex(_ rgb: UInt32) -> String {
        String(format: "#%06X", rgb & 0xFF_FF_FF)
    }

    /// What a reader types: `#f06eb3`, `f06eb3`, `#F6B` or `f6b`, with spaces
    /// around it. Nil for anything else — the field keeps its last good value.
    public static func parse(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        switch digits.count {
        case 3:
            let doubled = digits.map { "\($0)\($0)" }.joined()
            return UInt32(doubled, radix: 16)
        case 6:
            return UInt32(digits, radix: 16)
        default:
            return nil
        }
    }

    /// A name for the colour — "Bubblegum", "Deep Ocean", "Pastel Mint",
    /// "Charcoal". Playful on purpose; the hex beside it is the exact answer.
    public static func name(_ rgb: UInt32) -> String {
        name(HSBColour(rgb: rgb))
    }

    public static func name(_ colour: HSBColour) -> String {
        let s = colour.saturation
        let b = colour.brightness
        if b < 0.12 { return "Ink" }
        if s < 0.12 {
            switch b {
            case 0.93...: return "Snow"
            case 0.72...: return "Silver"
            case 0.45...: return "Slate"
            case 0.25...: return "Charcoal"
            default: return "Ink"
            }
        }
        let base = HueDetent.nearest(to: colour.hue).name
        if b < 0.38 { return "Midnight \(base)" }
        if b < 0.6 { return "Deep \(base)" }
        if s < 0.4, b > 0.82 { return "Pastel \(base)" }
        if s < 0.42 { return "Dusty \(base)" }
        return base
    }
}

/// A named hue the rail's thumb is drawn towards.
///
/// **Magnetic, not stepped.** Inside `pull` of a detent the thumb settles on
/// it and the trackpad ticks once; outside, the hue is wherever the pointer is.
/// So the rail feels like a dial with notches and still reaches every hue.
public struct HueDetent: Hashable, Sendable {
    public var hue: Double
    public var name: String

    /// Fourteen, spaced the way the eye spaces them rather than evenly — the
    /// greens are wide and the oranges narrow.
    public static let all: [HueDetent] = [
        HueDetent(hue: 0 / 360, name: "Cherry"),
        HueDetent(hue: 22 / 360, name: "Tangerine"),
        HueDetent(hue: 45 / 360, name: "Sunflower"),
        HueDetent(hue: 62 / 360, name: "Lemon"),
        HueDetent(hue: 88 / 360, name: "Lime"),
        HueDetent(hue: 125 / 360, name: "Clover"),
        HueDetent(hue: 155 / 360, name: "Mint"),
        HueDetent(hue: 180 / 360, name: "Lagoon"),
        HueDetent(hue: 200 / 360, name: "Sky"),
        HueDetent(hue: 222 / 360, name: "Ocean"),
        HueDetent(hue: 250 / 360, name: "Iris"),
        HueDetent(hue: 275 / 360, name: "Grape"),
        HueDetent(hue: 300 / 360, name: "Orchid"),
        HueDetent(hue: 325 / 360, name: "Bubblegum"),
        HueDetent(hue: 345 / 360, name: "Rose"),
    ]

    /// How far a detent reaches, as a fraction of the rail: about 3.6°.
    public static let pull = 0.01

    public static func nearest(to hue: Double) -> HueDetent {
        all.min { distance($0.hue, hue) < distance($1.hue, hue) } ?? all[0]
    }

    /// Where the thumb settles for a pointer at `hue`, and the detent it
    /// settled on, if any.
    public static func snap(_ hue: Double) -> (hue: Double, detent: HueDetent?) {
        let near = nearest(to: hue)
        return distance(near.hue, hue) <= pull ? (near.hue, near) : (hue, nil)
    }

    /// Where the rail's thumb settles for a pointer at `raw` (0…1 along the
    /// rail), the hue that means, and the notch it settled on.
    ///
    /// **Red is at both ends of the rail**, so the notch at hue 0 is reached
    /// from either end — and the thumb has to stay at the end the pointer is
    /// at. Snapping to the hue alone put a thumb dragged to the far right back
    /// at the far left (Alex, 2026-10-22).
    public static func settle(_ raw: Double) -> (position: Double, hue: Double, detent: HueDetent?) {
        let clamped = min(max(raw, 0), 1)
        let (hue, detent) = snap(clamped)
        let position = detent?.hue == 0 ? (clamped > 0.5 ? 1 : 0) : hue
        return (position, hue, detent)
    }

    /// Around the circle: 0.99 and 0.01 are close.
    public static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }
}

extension HSBColour {
    /// A colour somebody would plausibly choose — saturated but not neon, light
    /// enough to read white text on — for the picker's dice.
    public static func surprise<G: RandomNumberGenerator>(using generator: inout G) -> HSBColour {
        HSBColour(
            hue: Double.random(in: 0..<1, using: &generator),
            saturation: Double.random(in: 0.5...0.85, using: &generator),
            brightness: Double.random(in: 0.7...0.95, using: &generator)
        )
    }
}
