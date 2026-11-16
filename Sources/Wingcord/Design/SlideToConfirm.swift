import SwiftUI

// MARK: - Slide to confirm
//
// iOS's slide to power off, on a Mac: a track, a knob of real Liquid Glass a
// little taller than the track, and the words under the knob, so its rim bends
// them as it passes (Alex, 2026-11-04). Used where one stray click must not be
// enough: accepting an invite.
//
// **The track is a plain fill and not glass.** Glass can't refract glass, and the
// words have to be under the knob for it to have anything to bend. `.regular` and
// not `.clear`: probed side by side over text, clear warps the words right across
// the knob and fights whatever is on it, where regular keeps the middle calm and
// bends them at the rim, as the system's own does.
//
// **Not drag-only.** The HIG on custom gestures: "not the only way to perform an
// important action". Return sends the knob across by itself, Space does with Full
// Keyboard Access, and VoiceOver gets one button. A plain click nudges the knob,
// which shows what the gesture is rather than doing nothing.

/// What a release decides. Plain numbers, so the rule can be pinned by a test.
nonisolated enum SlideRule {
    enum Outcome: Equatable {
        case commit
        case returnHome
    }

    /// How close to the end counts as the end.
    static let endTolerance: CGFloat = 2

    /// Commits at the end, or on a throw that would carry past it from at least
    /// halfway. From further back a throw isn't asking for this: the point of the
    /// control is that a stray flick can't do it.
    static func outcome(position: CGFloat, velocity: CGFloat, travel: CGFloat) -> Outcome {
        guard travel > 0 else { return .returnHome }
        if position >= travel - endTolerance { return .commit }
        guard velocity > 0, position >= travel / 2 else { return .returnHome }
        return Motion.projectedPosition(from: position, velocity: velocity) >= travel ? .commit : .returnHome
    }

    /// How old the last movement can be for a release to count as a throw.
    static let throwWindow: TimeInterval = 0.06

    /// The speed a release carries: what the gesture reported, unless the pointer
    /// had already stopped. **The report is stale after a pause**: dragged fast,
    /// held still and let go, it still says fast, and a held knob would be thrown.
    static func releaseVelocity(reported: CGFloat, sinceLastMovement: TimeInterval) -> CGFloat {
        sinceLastMovement > throwWindow ? 0 : reported
    }

    /// The words fade as the knob reaches them, gone a little before the end.
    static func wordsOpacity(position: CGFloat, travel: CGFloat) -> Double {
        guard travel > 0 else { return 1 }
        return Double(max(0, min(1, 1 - position / (travel * 0.72))))
    }

    /// How far a pull may stretch past home before it stops giving.
    static let homeGive: CGFloat = 10

    /// Where a drag puts the knob for a pointer that wants `wanted`.
    ///
    /// **A hard stop at the end**, as the system's own slider has (#6,
    /// WC-4AC1). The pull used to stretch past the end by a quarter of the
    /// track, and the knob sailed out of the bar it was supposed to be riding
    /// in. Home keeps a little give, so a pull the wrong way still answers.
    static func dragPosition(wanted: CGFloat, travel: CGFloat) -> CGFloat {
        guard travel > 0 else { return 0 }
        if wanted >= travel { return travel }
        return Motion.clampWithResistance(wanted, to: 0...travel, limit: homeGive)
    }

    /// How long the knob takes to settle `distance` points after a release at
    /// `velocity` points per second: what an ease-out needs for its first
    /// moment to move at about the release's speed, within limits that keep a
    /// slow release from crawling and a fling from snapping.
    ///
    /// **An ease-out rather than a spring**, because an ease-out cannot pass
    /// its target: the spring this used to land on carried the knob past the
    /// end of the bar again after every throw.
    static func settleDuration(distance: CGFloat, velocity: CGFloat) -> Double {
        let distance = abs(distance)
        guard distance > 0.5 else { return 0.12 }
        // An ease-out (0, 0, 0.58, 1) starts at about 1.7 × its average speed.
        let speed = max(abs(velocity), 400)
        return Double(min(0.32, max(0.12, 1.7 * distance / speed)))
    }
}

/// The control's sizes. Outside the view, which is generic: Swift has no static
/// storage on a generic type.
private enum SlideMetrics {
    static let trackHeight: CGFloat = 44
    /// Taller than the track by 4 each way, as in Alex's picture.
    static let knobSide: CGFloat = 52
    static var overhang: CGFloat { (knobSide - trackHeight) / 2 }
    /// How far a plain click nudges the knob.
    static let nudge: CGFloat = 26
    /// A press this far off the knob still takes it.
    static let grabSlop: CGFloat = 6
    /// A press that moved less than this was a click.
    static let clickSlop: CGFloat = 3
}

struct SlideToConfirm<Knob: View>: View {
    /// The words in the track.
    var title: AttributedString
    /// What VoiceOver calls it: the act, not the gesture.
    var accessibilityTitle: String
    /// A write in flight, after a commit: the knob holds at the end with a
    /// spinner. When it goes false with the sheet still up, the act was refused,
    /// and the knob goes home.
    var isWorking = false
    /// Locked, and why, in the track's words.
    var lockedTitle: String?
    var confirm: () -> Void
    /// What the knob carries.
    @ViewBuilder var knob: Knob

    @Environment(\.motion) private var motion
    @Environment(\.isTopModal) private var isTop
    @Environment(\.controlActiveState) private var activeState

    /// The knob's travel from home, 0…`travel`, and a little past while it's
    /// being pulled against either end.
    @State private var position: CGFloat = 0
    @State private var width: CGFloat = 0
    /// Where a drag took the knob from. Nil before the first event of a press.
    @State private var grab: Grab?
    /// On its way home, or nudging, so a press takes it from where it appears.
    @State private var isSettling = false
    /// Committed: nothing moves it until the answer.
    @State private var isCommitted = false
    /// Against the end stop, so the haptic plays once per arrival.
    @State private var isAtEnd = false
    @State private var sweep: CGFloat = 0
    /// When the pointer last moved the knob, for telling a throw from a release.
    @State private var lastMovement: Date?

    private enum Grab: Equatable {
        case knob(from: CGFloat)
        /// Pressed on the track, not the knob: a click there nudges, a drag does
        /// nothing.
        case track
    }

    private var travel: CGFloat { max(0, width - SlideMetrics.trackHeight) }
    private var isLocked: Bool { lockedTitle != nil }
    private var canSlide: Bool { !isLocked && !isWorking && !isCommitted }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Self.trackFill)
            Capsule().strokeBorder(Palette.edge)
            words
            knobView
                .offset(x: position - SlideMetrics.overhang)
        }
        .frame(height: SlideMetrics.trackHeight)
        .padding(.vertical, SlideMetrics.overhang)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(.rect)
        .gesture(drag)
        .background(returnKey)
        .focusable(!isLocked)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard canSlide else { return .ignored }
            fly()
            return .handled
        }
        .onChange(of: isWorking) { _, working in
            // Refused: back to where it can be tried again.
            guard !working, isCommitted else { return }
            isCommitted = false
            isAtEnd = false
            goHome(velocity: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(lockedTitle ?? accessibilityTitle))
        .accessibilityHint(isLocked ? Text(verbatim: "") : Text("Slide, or press Return"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if canSlide { fly() } }
    }

    private static var trackFill: Color { Color.relative(dark: 0.09, light: 0.07) }

    // MARK: The words

    private var words: some View {
        let label = Text(lockedTitle.map { AttributedString($0) } ?? title)
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        return ZStack {
            label.foregroundStyle(InkColor.primary.opacity(isLocked ? 0.62 : 0.78))
            // A slow sweep of light, while it's waiting to be moved. Off under
            // Reduce Motion, in a window that isn't the key one, and as soon as
            // the knob has been taken.
            if !isLocked, !motion.reduceMotion, activeState == .key, position == 0 {
                label
                    .foregroundStyle(InkColor.solid)
                    .mask {
                        LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.sweepWidth)
                            .offset(x: sweep)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { startSweep() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, SlideMetrics.trackHeight + Spacing.tight)
        .padding(.trailing, Spacing.margin)
        .opacity(isLocked ? 1 : SlideRule.wordsOpacity(position: position, travel: travel))
        .allowsHitTesting(false)
    }

    private static var sweepWidth: CGFloat { 96 }

    /// Across the words and on past them, which is the pause between sweeps.
    private func startSweep() {
        sweep = -Self.sweepWidth
        withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
            sweep = max(width, 320) * 1.6
        }
    }

    // MARK: The knob

    private var knobView: some View {
        Group {
            if isWorking {
                ProgressView().controlSize(.small)
            } else if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(InkColor.primary.opacity(0.7))
            } else {
                knob
            }
        }
        .frame(width: SlideMetrics.knobSide, height: SlideMetrics.knobSide)
        .contentShape(.circle)
        .glassEffect(isLocked ? .regular : .regular.interactive(), in: .circle)
        .allowsHitTesting(false)
    }

    // MARK: The gesture

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard canSlide else { return }
                if grab == nil { grab = takeHold(at: value.startLocation.x) }
                guard case .knob(let from) = grab else { return }
                lastMovement = value.time
                let wanted = from + value.translation.width
                let next = SlideRule.dragPosition(wanted: wanted, travel: travel)
                if isSettling {
                    // Caught in flight: on from where it appears, not a jump.
                    isSettling = false
                    withAnimation(motion.liveTracking) { position = next }
                } else {
                    position = next
                }
                let reached = wanted >= travel
                if reached != isAtEnd {
                    isAtEnd = reached
                    if reached { Haptics.bump() }
                }
            }
            .onEnded { value in
                defer { grab = nil }
                guard canSlide else { return }
                let moved = abs(value.translation.width) + abs(value.translation.height)
                if moved < SlideMetrics.clickSlop, !isAtEnd {
                    nudge()
                    return
                }
                guard case .knob = grab else { return }
                let velocity = SlideRule.releaseVelocity(
                    reported: value.velocity.width,
                    sinceLastMovement: lastMovement.map { value.time.timeIntervalSince($0) } ?? .infinity
                )
                switch SlideRule.outcome(position: position, velocity: velocity, travel: travel) {
                case .commit: commit(velocity: velocity)
                case .returnHome:
                    isAtEnd = false
                    goHome(velocity: velocity)
                }
            }
    }

    private func takeHold(at x: CGFloat) -> Grab {
        let left = position - SlideMetrics.overhang - SlideMetrics.grabSlop
        let right = left + SlideMetrics.knobSide + 2 * SlideMetrics.grabSlop
        guard x >= left, x <= right else { return .track }
        // In flight the logical position is already home, so it's taken from
        // under the pointer. At rest, from where it is, keeping the grab offset.
        return .knob(from: isSettling ? x - SlideMetrics.knobSide / 2 + SlideMetrics.overhang : position)
    }

    /// Lands at the end at the release's speed, and acts on the same frame.
    private func commit(velocity: CGFloat) {
        isCommitted = true
        Haptics.pop()
        withAnimation(settle(over: travel - position, velocity: velocity)) {
            position = travel
        }
        confirm()
    }

    private func goHome(velocity: CGFloat) {
        isSettling = true
        let animation = motion.reduceMotion
            ? Motion.reposition.reduced
            : settle(over: position, velocity: velocity)
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            position = 0
        } completion: {
            isSettling = false
        }
    }

    /// An ease-out that starts at about the release's speed and never passes
    /// where it is going — see `SlideRule.settleDuration`.
    private func settle(over distance: CGFloat, velocity: CGFloat) -> Animation {
        .timingCurve(0, 0, 0.58, 1, duration: SlideRule.settleDuration(distance: distance, velocity: velocity))
    }

    /// A plain click: out a little and back, the shape of the gesture. Under
    /// Reduce Motion there's no travel to show, and the words already say it.
    private func nudge() {
        guard !motion.reduceMotion, position == 0, !isSettling else { return }
        isSettling = true
        withAnimation(Motion.hover.animation, completionCriteria: .logicallyComplete) {
            position = SlideMetrics.nudge
        } completion: {
            // Critically damped from rest: home, and not a point past it.
            withAnimation(Motion.reposition.animation, completionCriteria: .logicallyComplete) {
                position = 0
            } completion: {
                isSettling = false
            }
        }
    }

    /// Return, Space or VoiceOver: the knob crosses by itself, then acts.
    private func fly() {
        guard canSlide else { return }
        isCommitted = true
        if motion.reduceMotion {
            position = travel
            confirm()
            return
        }
        withAnimation(Motion.reposition.animation, completionCriteria: .logicallyComplete) {
            position = travel
        } completion: {
            Haptics.pop()
            confirm()
        }
    }

    /// A button with no face, because only a button takes the default key.
    private var returnKey: some View {
        Button(action: fly) { EmptyView() }
            .buttonStyle(.plain)
            .keyboardShortcut(isTop && canSlide ? .defaultAction : nil)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
