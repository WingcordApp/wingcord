import AppKit
import Foundation
import QuartzCore

/// The one clock every animated image in the app runs on.
///
/// **One display link, not one per animation, and it does not exist at rest.**
/// A roster of decorated members is dozens of animations on screen at once; a
/// timer each is dozens of wakeups per frame, dozens of separate timebases that
/// drift apart, and — worse — a process that never idles. Here there is a single
/// link, created when the first subscriber appears and *invalidated* when the
/// last one leaves, so an app showing nothing animated costs exactly nothing.
///
/// Four things keep it cheap, and each is a measurable saving rather than a
/// tidiness:
///
///  1. **Capped at 24 fps.** Discord's decorations are authored around 10-20 fps
///     and every frame is a downsampled bitmap swap. Running the link at a
///     120 Hz display's native cadence would ask for five times the wakeups to
///     show the same pictures. `CAFrameRateRange` lets the system pick a
///     divisor rather than being told a hard interval.
///  2. **Silent while scrolling.** `ScrollWorkGate` is the app's one signal that
///     no spare frames exist. The clock keeps *time* through a scroll — so
///     playback resumes in phase rather than jumping — but calls nobody, which
///     is the whole cost.
///  3. **Silent while the app is not active.** An animation nobody is looking at
///     is pure heat. Subscribers stay registered; the link is torn down and
///     rebuilt around the active state.
///  4. **One timestamp, read by everyone.** Every subscriber draws from the same
///     `time`, so decorations stay in step instead of each drifting on its own
///     accumulated error.
@MainActor
final class AnimationClock {
    static let shared = AnimationClock()

    /// Seconds since the clock first started. The single timebase every animated
    /// image resolves its current frame against.
    private(set) var time: Double = 0

    private var link: CADisplayLink?
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]

    private struct Subscriber {
        var tick: () -> Void
        /// Whether this one keeps running through a scroll.
        var throughScroll: Bool
    }
    private var lastTimestamp: CFTimeInterval?
    private var isAppActive = true
    private var activeObservers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        activeObservers = [
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in MainActor.assumeIsolated { AnimationClock.shared.setActive(false) } },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in MainActor.assumeIsolated { AnimationClock.shared.setActive(true) } },
        ]
    }

    // MARK: Subscription

    /// Registers a callback, fired once per displayed frame.
    ///
    /// The token is the caller's identity, so subscribing twice replaces rather
    /// than duplicates — a view that is reconfigured mid-life cannot leak a
    /// second subscription.
    ///
    /// - Parameter throughScroll: Keeps this subscriber running while a scroll
    ///   is in progress. **The default is off and should stay off for anything
    ///   on the app's main surfaces** — parking playback is what buys a scroll
    ///   its frames. It is on for the expression picker, where the moving
    ///   pictures ARE the content being chosen and freezing them mid-scroll
    ///   reads as the picker having stalled; the cost there is bounded by a
    ///   popover's worth of small cells.
    func subscribe(
        _ token: ObjectIdentifier,
        throughScroll: Bool = false,
        tick: @escaping () -> Void
    ) {
        subscribers[token] = Subscriber(tick: tick, throughScroll: throughScroll)
        startIfNeeded()
    }

    func unsubscribe(_ token: ObjectIdentifier) {
        guard subscribers.removeValue(forKey: token) != nil else { return }
        stopIfIdle()
    }

    // MARK: The link

    private func setActive(_ active: Bool) {
        guard isAppActive != active else { return }
        isAppActive = active
        if active { startIfNeeded() } else { stop() }
    }

    private func startIfNeeded() {
        guard link == nil, isAppActive, !subscribers.isEmpty else { return }
        guard let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        // A range rather than a fixed rate: the system picks a cadence it can
        // hold, and on a 120 Hz display that is a divisor rather than a fight.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 24)
        link.add(to: .main, forMode: .common)
        lastTimestamp = nil
        self.link = link
    }

    private func stopIfIdle() {
        guard subscribers.isEmpty else { return }
        stop()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        // Advance from the link's own timestamps rather than from a wall clock:
        // it is the only source that stays in step with what the display
        // actually presented, and a missed frame then costs a longer step
        // instead of a permanent phase error.
        let now = link.timestamp
        if let lastTimestamp {
            // A step longer than a moment means the app was busy or asleep.
            // Clamped, or an animation catches up in one visible jump.
            time += min(now - lastTimestamp, 0.25)
        }
        lastTimestamp = now

        // Time moves for everyone; during a scroll only those who asked are
        // told. Playback then resumes in phase after the gesture rather than
        // restarting or lurching.
        if ScrollWorkGate.isActive {
            for subscriber in subscribers.values where subscriber.throughScroll {
                subscriber.tick()
            }
        } else {
            for subscriber in subscribers.values { subscriber.tick() }
        }
    }
}
