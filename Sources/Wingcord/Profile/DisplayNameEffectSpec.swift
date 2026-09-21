import CoreGraphics
import QuartzCore

/// Discord's own numbers for the seven display-name effects, in one place.
///
/// **There are two renderers for this design and they must not drift.**
/// `DisplayNameEffectLayers` builds a Core Animation tree, which is right for a
/// profile card: a handful of names, declarative loops, no main-thread work.
/// `DisplayNameEffectPainter` draws the same design into a `CGContext`, which is
/// what the transcript needs, because that surface is one painted layer and has
/// no views to hang a layer tree on.
///
/// Neither is wrong, and that is exactly the danger — a keyframe corrected in
/// one and not the other produces two versions of one person's name in one
/// window, and the difference is a number nobody re-reads. So every duration,
/// keyTime, stop list and control point lives here and both read it.
///
/// The numbers themselves were read out of Discord's stylesheet rather than
/// measured. **Each keyframe set carries its own hold** — the movement occupies
/// about half the cycle and the rest is deliberately still. Easing across the
/// whole period instead reads as continuously restless.
nonisolated enum DisplayNameEffectSpec {

    /// The cycle every effect but Prism runs on.
    static let cycle: CFTimeInterval = 4
    /// Prism scrolls one tile per two seconds, linearly.
    static let prismCycle: CFTimeInterval = 2

    /// The easing every effect but Neon uses, as CSS control points.
    static let ease = UnitBezier(0.44, 0.29, 0.48, 1)
    /// Neon's own, which is sharper into the flicker.
    static let neonEase = UnitBezier(0.24, 0.31, 0.36, 0.93)

    // MARK: Neon

    enum Neon {
        static let keyTimes: [CGFloat] = [
            0, 0.15, 0.16, 0.18, 0.20, 0.22, 0.23, 0.25, 0.28, 0.50, 1,
        ]
        /// Which keyframes are the dimmed colour rather than white. The core
        /// blinks three times in the first quarter and then holds lit.
        static let isOff: [Bool] = [
            false, false, true, false, false, true, false, false, true, false, false,
        ]
        static func strokeWidth(em: CGFloat) -> CGFloat { 1 + 0.04 * em }
        static func glowRadius(em: CGFloat) -> CGFloat { 4 + 0.12 * em }
    }

    // MARK: Toon

    enum Toon {
        /// `background-size: 100% 400%` — the gradient is four times the line
        /// box and slides three of them.
        static let scale: CGFloat = 4
        static let stops: [CGFloat] = [0, 0.08, 0.15, 0.25, 0.45, 0.55, 0.75, 0.83, 0.90, 1]
        static let keyTimes: [CGFloat] = [0, 0.05, 0.55, 1]
        /// The sheen's centre, in multiples of the line height, at each keyTime.
        /// Rest is the gradient's top quarter aligned with the box.
        static let travel: [CGFloat] = [-1, -1, 2, 2]
        static func strokeWidth(em: CGFloat) -> CGFloat { 1.6 + 0.04 * em }
    }

    // MARK: Pop

    enum Pop {
        static let keyTimes: [CGFloat] = [0, 0.18, 0.35, 0.50, 1]
        /// The letters' lift, in ems. y-up, so CSS's downward translations come
        /// back negated.
        static let letters: [CGFloat] = [0, 0.05, -0.08, 0, 0]
        /// The extrusion's, which moves the other way — **their separation is
        /// the effect**, so these two tables are read together or not at all.
        static let shadow: [CGFloat] = [-0.08, -0.13, 0, -0.08, -0.08]
        /// How far the extrusion sits below the letters at rest, in ems.
        static let lift: CGFloat = 0.08
        static let sweepStops: [CGFloat] = [0, 0.06, 0.20, 0.50, 0.56, 0.70, 1]
        static let sweepKeyTimes: [CGFloat] = [0, 0.5, 1]
        static func outlineWidth(em: CGFloat) -> CGFloat { 1.2 + 0.04 * em }
    }

    // MARK: Gummy

    enum Gummy {
        static let keyTimes: [CGFloat] = [0, 0.07, 0.14, 0.21, 0.28, 0.35, 1]
        static let scaleX: [CGFloat] = [1.0, 1.28, 0.82, 1.1, 0.96, 1.0, 1.0]
        static let scaleY: [CGFloat] = [1.0, 0.72, 1.18, 0.9, 1.04, 1.0, 1.0]
        /// Seconds each letter lags the one before it.
        static let stagger: CFTimeInterval = 0.05
    }

    // MARK: Gradient

    enum Gradient {
        /// `linear-gradient(to bottom right, colors[0] 10%, colors[1] 90%)`.
        ///
        /// **The stops are 10% and 90%, not 0 and 100.** Each endpoint colour is
        /// held across a tenth of the diagonal, so a short name still shows both
        /// rather than reading as one muddy midpoint.
        static let stops: [CGFloat] = [0.1, 0.9]
    }
}

/// A CSS `cubic-bezier` timing function, evaluated rather than handed to Core
/// Animation.
///
/// **The layer renderer never needs this and the painter cannot do without it.**
/// Core Animation is given the control points and interpolates on the render
/// server; a painter asked "what does this look like at t = 1.37s" has to solve
/// the curve itself, and a painter that instead eased linearly would show a
/// visibly different animation from the profile card's.
nonisolated struct UnitBezier {
    let p1x: CGFloat
    let p1y: CGFloat
    let p2x: CGFloat
    let p2y: CGFloat

    init(_ p1x: CGFloat, _ p1y: CGFloat, _ p2x: CGFloat, _ p2y: CGFloat) {
        self.p1x = p1x
        self.p1y = p1y
        self.p2x = p2x
        self.p2y = p2y
    }

    /// The Core Animation twin, so the layer renderer states the same curve
    /// without restating its numbers.
    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints: Float(p1x), Float(p1y), Float(p2x), Float(p2y)
        )
    }

    /// `y` at the given `x`, both in `0...1`.
    ///
    /// Newton-Raphson first, which converges in two or three steps for the
    /// shallow curves here, and bisection as the fallback for the flat regions
    /// where the derivative is near zero and Newton would step wildly.
    func value(at x: CGFloat) -> CGFloat {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        return curveY(at: solve(for: x))
    }

    private func curveX(at t: CGFloat) -> CGFloat {
        let u = 1 - t
        return 3 * u * u * t * p1x + 3 * u * t * t * p2x + t * t * t
    }

    private func curveY(at t: CGFloat) -> CGFloat {
        let u = 1 - t
        return 3 * u * u * t * p1y + 3 * u * t * t * p2y + t * t * t
    }

    private func slopeX(at t: CGFloat) -> CGFloat {
        let u = 1 - t
        return 3 * u * u * p1x + 6 * u * t * (p2x - p1x) + 3 * t * t * (1 - p2x)
    }

    private func solve(for x: CGFloat) -> CGFloat {
        var t = x
        for _ in 0..<8 {
            let error = curveX(at: t) - x
            if abs(error) < 1e-6 { return t }
            let slope = slopeX(at: t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }

        var low: CGFloat = 0
        var high: CGFloat = 1
        t = x
        while low < high {
            let value = curveX(at: t)
            if abs(value - x) < 1e-6 { return t }
            if value < x { low = t } else { high = t }
            let next = (high + low) / 2
            if abs(next - t) < 1e-9 { break }
            t = next
        }
        return t
    }
}

nonisolated extension DisplayNameEffectSpec {

    /// Where a keyframe table stands at `progress` through its cycle.
    ///
    /// **One function per *segment*, which is how a browser eases between
    /// keyframes.** A single curve applied across the whole run would ease the
    /// entire cycle and flatten every hold in it — and the holds are half of
    /// what these effects are.
    ///
    /// Returns the index of the segment's left keyframe and how far into it the
    /// clock has travelled, already eased. The caller interpolates whatever it
    /// holds, which for Neon is a colour and for everything else a number.
    static func segment(
        at progress: CGFloat,
        keyTimes: [CGFloat],
        easing: UnitBezier
    ) -> (index: Int, t: CGFloat) {
        guard keyTimes.count > 1 else { return (0, 0) }
        let clamped = min(max(progress, 0), 1)
        var index = keyTimes.count - 2
        for candidate in 0..<(keyTimes.count - 1) where clamped < keyTimes[candidate + 1] {
            index = candidate
            break
        }
        let start = keyTimes[index]
        let span = keyTimes[index + 1] - start
        guard span > 0 else { return (index, 0) }
        return (index, easing.value(at: (clamped - start) / span))
    }

    /// A numeric keyframe table, read at `progress`.
    static func interpolate(
        _ values: [CGFloat],
        keyTimes: [CGFloat],
        at progress: CGFloat,
        easing: UnitBezier
    ) -> CGFloat {
        guard values.count == keyTimes.count, values.count > 1 else {
            return values.first ?? 0
        }
        let (index, t) = segment(at: progress, keyTimes: keyTimes, easing: easing)
        return values[index] + (values[index + 1] - values[index]) * t
    }
}
