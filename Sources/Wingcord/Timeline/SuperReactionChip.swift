import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// A super reaction chip's glow — Discord's `burstGlow`, baked once per shape
/// and colour.
///
/// **What Discord draws is a shadow and nothing else.** An empty box the size
/// of the chip's inside, at 35 % opacity, casting `box-shadow: 0 0 16px` in the
/// chip's accent — and CSS paints an outer shadow only *outside* the box that
/// casts it. So the chip is ringed with light that is brightest at its edge
/// and never lies on top of its own fill; that edge is the "outline" a super
/// reaction appears to have even when nobody reading it sent one.
///
/// **Baked, because a drawn row repaints whole.** A transcript repaint redraws
/// every row the dirty rectangle touches, and an animated emoji in the next
/// chip over asks for one twenty times a second. A shadow blur per chip per
/// repaint is the per-frame work this app does not do; one bitmap per (size,
/// colour, scale), drawn as an image, costs what drawing a picture costs.
nonisolated enum SuperReactionGlow {

    /// How far past the chip the baked bitmap reaches. A Gaussian of this
    /// radius has faded to nothing inside one and a half of them.
    private static let reach = (TimelineMetrics.superReactionGlowBlur * 1.5).rounded(.up)

    /// Draws the glow around a chip of `frame`, behind it.
    static func draw(around frame: CGRect, accent: UInt32, context: CGContext, scale: CGFloat) {
        guard let image = image(size: frame.size, accent: accent, scale: scale) else { return }
        TimelineRowPainter.drawFlipped(
            image, in: frame.insetBy(dx: -reach, dy: -reach), context: context
        )
    }

    /// Bounded: a long session sees many emoji and each palette is its own
    /// bitmap. Thirty-two is several screens of distinct super reactions.
    ///
    /// `nonisolated(unsafe)` because `NSCache` is not marked `Sendable` and is
    /// documented thread-safe; the reference itself never changes.
    private nonisolated(unsafe) static let cache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 32
        return cache
    }()

    private final class CGImageBox: Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static func image(size: CGSize, accent: UInt32, scale: CGFloat) -> CGImage? {
        let key = "\(Int(size.width * scale))x\(Int(size.height * scale)):\(accent):\(scale)" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }

        let canvas = CGSize(width: size.width + reach * 2, height: size.height + reach * 2)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int((canvas.width * scale).rounded(.up)),
                  height: Int((canvas.height * scale).rounded(.up)),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)

        // The box that casts it: the chip's inside, one border-width in, which
        // is where Discord's glow element sits.
        let radius = TimelineMetrics.reactionChipRadius - 1
        let caster = CGPath(
            roundedRect: CGRect(origin: CGPoint(x: reach, y: reach), size: size).insetBy(dx: 1, dy: 1),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        let color = SuperReactionInk.color(accent)
        // A shadow's blur is in the context's base space, which is pixels —
        // the scale transform above does not reach it.
        context.setShadow(
            offset: .zero,
            blur: TimelineMetrics.superReactionGlowBlur * scale,
            color: color.copy(alpha: TimelineMetrics.superReactionGlowOpacity)
        )
        context.addPath(caster)
        context.setFillColor(color)
        context.fillPath()
        // Then the caster itself is taken away — and with it the shadow under
        // it — leaving light only outside the box, as CSS draws it.
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setBlendMode(.clear)
        context.addPath(caster)
        context.fillPath()

        guard let image = context.makeImage() else { return nil }
        cache.setObject(CGImageBox(image), forKey: key)
        return image
    }
}

/// The shake a chip does while its effect starts — Discord's `shake` keyframes
/// (stylesheet `17256`), half a second, once, under full motion only.
///
/// Eleven stops of a translation of a point or two and a rotation of a degree,
/// each leg eased with CSS's default `ease` exactly as the stylesheet leaves
/// it. The chip turns about its own centre, which is CSS's default
/// `transform-origin`.
nonisolated enum SuperReactionShake {
    static let duration = 0.5

    /// `translate(x, y) rotate(degrees)` at 0 %, 10 % … 100 %.
    private static let stops: [(x: CGFloat, y: CGFloat, degrees: CGFloat)] = [
        (1, 1, 0), (-1, -1, -1), (-2, 0, 1), (2, 1, 0), (1, -1, 1), (-1, 1, -1),
        (-2, 1, 0), (2, 1, -1), (-1, -1, 1), (1, 1, 0), (1, -1, -1),
    ]

    /// Where the chip is `elapsed` seconds in, or nil once the shake is over.
    static func offset(at elapsed: Double) -> (dx: CGFloat, dy: CGFloat, radians: CGFloat)? {
        guard elapsed >= 0, elapsed < duration else { return nil }
        let position = elapsed / duration * Double(stops.count - 1)
        let leg = min(Int(position), stops.count - 2)
        let t = CGFloat(ease(position - Double(leg)))
        let from = stops[leg], to = stops[leg + 1]
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return (mix(from.x, to.x), mix(from.y, to.y), mix(from.degrees, to.degrees) * .pi / 180)
    }

    /// CSS `ease`, `cubic-bezier(0.25, 0.1, 0.25, 1)`: solve the curve's x for
    /// its parameter, then read y there.
    static func ease(_ x: Double) -> Double {
        let (x1, y1, x2, y2) = (0.25, 0.1, 0.25, 1.0)
        func curve(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        func slope(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
        }
        // Newton from the identity guess converges in a handful of steps on
        // this curve; the bisection fallback is for the flat stretch near the
        // ends, where the slope is too small to divide by.
        var t = x
        for _ in 0..<8 {
            let error = curve(t, x1, x2) - x
            if abs(error) < 1e-6 { return curve(t, y1, y2) }
            let d = slope(t, x1, x2)
            guard abs(d) > 1e-6 else { break }
            t -= error / d
        }
        var low = 0.0, high = 1.0
        t = x
        for _ in 0..<32 {
            let value = curve(t, x1, x2)
            if abs(value - x) < 1e-6 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return curve(t, y1, y2)
    }
}

/// A packed colour as the two types super reaction drawing hands to Core
/// Graphics and to the text drawer.
nonisolated enum SuperReactionInk {
    static func color(_ packed: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat(packed >> 16 & 0xFF) / 255,
            green: CGFloat(packed >> 8 & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func ink(_ packed: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat(packed >> 16 & 0xFF) / 255,
            green: CGFloat(packed >> 8 & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255,
            alpha: 1
        )
    }
}
