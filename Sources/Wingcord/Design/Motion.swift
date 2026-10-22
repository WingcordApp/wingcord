import QuartzCore
import SwiftUI

// MARK: - Motion
//
// The whole app's motion vocabulary. Seven classes, no more. If a surface needs
// a spring that is not in this file, the answer is almost always that it belongs
// to one of these and the surface is miscategorising it.
//
// The non-negotiable behaviours this file exists to make cheap:
//
//   1. Respond on press, never on release. `.interactive()` glass gives this
//      natively; custom controls dip to `Motion.pressScale`.
//   2. 1:1 tracking. Drags stay glued to the pointer and respect grab offset.
//   3. Interruptible everything. Animate from the presentation value, never the
//      target. SwiftUI springs re-target from their current velocity and
//      position when `withAnimation` is called again mid-flight — so the rule is
//      simply: never guard a re-target behind "is animating", and never reset
//      state to the target before animating.
//   4. Velocity handoff. A spring starts at the pointer's exact release
//      velocity (`handoff(velocity:over:)`). No seam between drag and animation.
//   5. Momentum projection. Snap decisions use the projected resting point
//      (`projectedPosition`), never the release position.
//   6. Rubber-banding at every boundary (`rubberBand`).
//   7. Spatial symmetry. Whatever enters from the left dismisses to the left.
//   8. Materialise, don't fade (`.materialize`).
//   9. Reduce Motion collapses travel to a cross-fade; the material survives.
//
// WHY THESE NUMBERS ARE NOT THE IPHONE'S. The iOS design system this vocabulary
// comes from runs `standard` at a 0.35s response. Ported unchanged to a pointer
// that is already resting on the thing it clicked, 0.35 does not read as smooth
// — it reads as latency, because there is no finger travel to hide it behind and
// the user is looking directly at the control. Every class below is faster than
// its iOS twin, and `hover` exists here and has no iOS counterpart at all: a
// finger arrives and leaves, a pointer *dwells*.
//
// Past roughly 200ms a response animation stops reading as motion and starts
// reading as lag. Long explicit durations are for SELF-INITIATED motion only —
// a jump-to-message flash, a skeleton shimmer, an ambient drift — which is the
// category this file exempts from that bar.

nonisolated struct MotionClass: Equatable, Sendable {
    var response: Double
    var dampingFraction: Double

    /// The animation to hand to `withAnimation` or `.animation(_:value:)`.
    var animation: Animation {
        .spring(response: response, dampingFraction: dampingFraction)
    }

    /// The same spring as a value, for velocity handoff.
    var spring: Spring {
        Spring(response: response, dampingRatio: dampingFraction)
    }

    /// Reduced-motion substitute: a short cross-fade with no overshoot. The
    /// material is preserved — Reduce Motion removes travel, not glass.
    var reduced: Animation { .easeOut(duration: Motion.reducedDuration) }

    func resolved(reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }

    /// The same spring for a layer that moves by itself on the render server —
    /// a property `CALayer` animates, with no repaint per frame.
    ///
    /// **Built from the class's own two numbers**, as SwiftUI builds its
    /// spring from them: Core Animation's perceptual duration is the response,
    /// and its bounce is what the damping leaves of a critically damped settle.
    func layerSpring(keyPath: String) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: response, bounce: 1 - dampingFraction)
        animation.keyPath = keyPath
        animation.duration = animation.settlingDuration
        return animation
    }

    /// The same spring, started at the pointer's exact release velocity.
    ///
    /// `initialVelocity` is normalised: SwiftUI expects it in units of *fraction
    /// of the remaining distance per second*, so a 1200 pt/s flick across 300 pt
    /// of remaining travel is an initial velocity of 4.
    ///
    /// - Parameters:
    ///   - velocity: Release velocity in points per second, signed.
    ///   - distance: Remaining travel to the target, signed the same way.
    func handoff(velocity: CGFloat, over distance: CGFloat) -> Animation {
        guard abs(distance) > 0.001 else { return animation }
        return .interpolatingSpring(spring, initialVelocity: Double(velocity / distance))
    }
}

nonisolated enum Motion {

    // MARK: The classes

    /// The default. Disclosure, selection, a panel swapping contents.
    /// Critically damped — most state changes in a chat client are
    /// informational, not playful, and overshoot on something nobody pushed is
    /// unearned.
    static let standard = MotionClass(response: 0.22, dampingFraction: 1.00)

    /// Glass becoming other glass: a `glassEffectID` morph, a cluster reflowing,
    /// the selection pill travelling from one channel row to the next.
    static let glassMorph = MotionClass(response: 0.28, dampingFraction: 0.90)

    /// A micro-state already under the pointer — a row highlighting, a control
    /// brightening. **The class macOS needs and iOS has no use for.** Fast
    /// enough that moving down a list does not leave a trail of fading rows
    /// behind the pointer.
    static let hover = MotionClass(response: 0.12, dampingFraction: 1.00)

    /// A drag landing, a flick, a swipe-dismiss. **Always paired with
    /// `handoff(velocity:over:)`** — using this class without the released
    /// velocity puts back the seam the whole system exists to remove. Overshoot
    /// is a response to force; anything the user did not push uses `standard`.
    static let momentum = MotionClass(response: 0.32, dampingFraction: 0.80)

    /// A panel, popover, flyout or profile card arriving. Paired with
    /// `.materialize`.
    static let panel = MotionClass(response: 0.26, dampingFraction: 0.85)

    /// Larger travel that is not a gesture — a column appearing, the split view
    /// rebalancing, a folder expanding. Critically damped: a thing that has
    /// arrived somewhere should not wobble about it.
    static let reposition = MotionClass(response: 0.30, dampingFraction: 1.00)

    /// Live gesture tracking. Use this *or* no animation at all — the point is
    /// that the view tracks the pointer 1:1 and never lags behind it.
    static let liveTracking: Animation = .interactiveSpring()

    // MARK: Not classes, deliberately
    //
    // There is no position to overshoot in a fade, so a spring would describe
    // physics that are not happening.

    /// A hover highlight appearing or leaving, where a spring would be overkill.
    static let fadeQuick: Animation = .easeOut(duration: fadeQuickDuration)
    /// The house cross-fade.
    static let fade: Animation = .easeOut(duration: fadeDuration)

    /// The same two fades as plain durations.
    ///
    /// The drawn canvases are AppKit and cross-fade through
    /// `NSAnimationContext`, which takes a `TimeInterval` and cannot be handed a
    /// SwiftUI `Animation`. Declared here rather than as a number at the call
    /// site so the scroll-edge strip and a SwiftUI hover cannot drift apart.
    static let fadeQuickDuration: TimeInterval = 0.10
    static let fadeDuration: TimeInterval = 0.14

    // MARK: Shared constants

    /// Reduced-motion cross-fade duration.
    static let reducedDuration: TimeInterval = 0.15

    /// Custom controls dip to this on press. Glass with `.interactive()`
    /// already responds natively and must not also be scaled; doubling the
    /// response reads as mushy.
    static let pressScale: CGFloat = 0.97

    /// AppKit's scroll deceleration rate. Shared so every projection in the app
    /// agrees with the system's own scrolling.
    static let decelerationRate: CGFloat = 0.998

    // MARK: Momentum

    /// Where a flick would come to rest if allowed to decelerate.
    ///
    /// `current + (v / 1000) * rate / (1 - rate)`
    ///
    /// Snap decisions use this, never the release position. That is what makes a
    /// fast short flick commit while a slow long drag cancels, which is how
    /// people actually expect a gesture to read. Note this is the exponential
    /// decay form the platform ships, not the textbook `v²/(2a)`.
    static func projectedPosition(
        from current: CGFloat,
        velocity: CGFloat,
        decelerationRate rate: CGFloat = Motion.decelerationRate
    ) -> CGFloat {
        current + (velocity / 1000) * rate / (1 - rate)
    }

    // MARK: Rubber-banding

    /// Progressive resistance past a boundary — list ends, panel edges, zoom
    /// limits. Never a hard stop: a hard stop reads as frozen, continuous
    /// resistance reads as responsive with nothing more to show.
    ///
    /// - Parameters:
    ///   - offset: How far past the boundary the pointer has travelled, signed.
    ///   - limit: The dimension resistance is measured against, usually the
    ///     container's extent along that axis.
    ///   - coefficient: 0.55 is the system's. Lower is stiffer.
    static func rubberBand(
        offset: CGFloat,
        limit: CGFloat,
        coefficient: CGFloat = 0.55
    ) -> CGFloat {
        guard limit > 0 else { return 0 }
        let magnitude = abs(offset)
        let resisted = (1 - (1 / (magnitude * coefficient / limit + 1))) * limit
        return offset < 0 ? -resisted : resisted
    }

    /// Rubber-bands only outside `range`, and tracks 1:1 inside it.
    static func clampWithResistance(
        _ value: CGFloat,
        to range: ClosedRange<CGFloat>,
        limit: CGFloat,
        coefficient: CGFloat = 0.55
    ) -> CGFloat {
        if value < range.lowerBound {
            return range.lowerBound + rubberBand(
                offset: value - range.lowerBound, limit: limit, coefficient: coefficient
            )
        }
        if value > range.upperBound {
            return range.upperBound + rubberBand(
                offset: value - range.upperBound, limit: limit, coefficient: coefficient
            )
        }
        return value
    }
}

// MARK: - Reduce Motion, resolved once

/// Reads the system's Reduce Motion setting once at the root and hands every
/// view a pre-resolved set of animations, so no surface has to remember to
/// check.
///
/// A plain value type over one `Bool`: stable identity, cheap equality, no
/// closures or class references that would invalidate dependents on every
/// update.
///
/// **Reading only one of the two possible signals is the bug this shape
/// prevents.** An app that honours its own preference by hand and never reads
/// the system's leaves a user who set Reduce Motion in System Settings with the
/// full animation set. There is one resolver and it is the only reader.
nonisolated struct MotionResolver: Equatable, Sendable {
    var reduceMotion: Bool = false

    var standard: Animation { Motion.standard.resolved(reduceMotion: reduceMotion) }
    var glassMorph: Animation { Motion.glassMorph.resolved(reduceMotion: reduceMotion) }
    var hover: Animation { Motion.hover.resolved(reduceMotion: reduceMotion) }
    var momentum: Animation { Motion.momentum.resolved(reduceMotion: reduceMotion) }
    var panel: Animation { Motion.panel.resolved(reduceMotion: reduceMotion) }
    var reposition: Animation { Motion.reposition.resolved(reduceMotion: reduceMotion) }

    /// A fade has no travel to remove, so Reduce Motion leaves it alone.
    var fade: Animation { Motion.fade }
    var fadeQuick: Animation { Motion.fadeQuick }

    /// Live tracking has no reduced variant — tracking a pointer 1:1 is not
    /// motion the user did not ask for, it *is* the user's motion.
    var liveTracking: Animation { Motion.liveTracking }

    /// Velocity handoff, resolved. Under Reduce Motion the momentum goes with
    /// the travel.
    func handoff(velocity: CGFloat, over distance: CGFloat) -> Animation {
        reduceMotion
            ? Motion.momentum.reduced
            : Motion.momentum.handoff(velocity: velocity, over: distance)
    }
}

extension EnvironmentValues {
    @Entry var motion = MotionResolver()
}

extension View {
    /// Apply once at the app root. Everything below reads `\.motion`.
    func resolvesMotion() -> some View {
        modifier(MotionResolutionModifier())
    }
}

private struct MotionResolutionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Game Mode reduces motion as the system setting does, while it
        // throttles — Discord's own Game Mode lever.
        content.environment(
            \.motion, MotionResolver(reduceMotion: reduceMotion || GameMode.shared.isThrottling)
        )
    }
}

// MARK: - Materialize
//
// Glass does not fade in. It materialises: blur radius and scale animate
// together, so the surface reads as condensing out of the background rather than
// being cross-dissolved on top of it.

nonisolated struct MaterializeTransition: Transition {
    var scale: CGFloat = 0.90
    var blur: CGFloat = 12
    /// The transform origin. Spatial symmetry means a surface grows from
    /// whatever summoned it — a trigger's nearest corner, a row, a thumbnail —
    /// and shrinks back into the same place. `.center` is only right for
    /// something that genuinely has no origin.
    var anchor: UnitPoint = .center

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : scale, anchor: anchor)
            .blur(radius: phase.isIdentity ? 0 : blur)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

extension Transition where Self == MaterializeTransition {
    /// The house enter/exit for any glass surface that is not morphing from a
    /// trigger. If it *is* morphing from a trigger, use `glassEffectID` in a
    /// shared namespace instead — a morph beats a transition every time.
    static var materialize: MaterializeTransition { MaterializeTransition() }

    /// Anchored to whatever summoned the surface.
    ///
    /// - Parameter blurring: pass `false` for a surface whose own ground is a
    ///   **material**. A blur forces an offscreen pass, and glass inside one has
    ///   no backdrop to sample: it paints black, at the layer's square bounds
    ///   rather than any rounded clip over it. Scale and opacity alone read
    ///   almost identically and cannot destroy it.
    static func materialize(
        from anchor: UnitPoint, blurring: Bool = true
    ) -> MaterializeTransition {
        MaterializeTransition(blur: blurring ? 12 : 0, anchor: anchor)
    }
}

// MARK: - Press response

extension View {
}
