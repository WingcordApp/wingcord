import Foundation

// MARK: - Pacing a recovery without losing it
//
// The DAVE recovery — opcode 31, reset, fresh key package — has to be braked.
// The gateway answers a key package with a welcome immediately, so a refusal
// that triggers another attempt at once spins against a server that answers
// instantly: **sixty-seven rebuilds in three seconds**, measured against a peer
// that was reconnecting, each one a fresh signature key and a 400-byte frame
// thrown away by the next.
//
// Two ways to get the brake wrong, and this project has now shipped both:
//
//   * **Dropping the request inside the window.** Two refusals a hundred and
//     fifty milliseconds apart, and the second is discarded — no key package
//     leaves, the gateway has nothing to commit us with, and the session never
//     recovers. Measured as a call that transmitted nothing in either direction
//     for its whole life, with `out=0` and a healthy socket.
//   * **Acting on a deferred request without asking whether it is still
//     wanted.** Half a second is long enough for the group to establish on its
//     own, and the delayed rebuild then tears down a working one and takes the
//     send ratchet with it. Measured as `dave sending under epoch 2` followed
//     a hundred and seventy milliseconds later by `dave reset to v1`, and every
//     frame after that refused as `ours unkeyed`.
//
// So: hold the last request back, and re-ask the question when the brake lets
// go. The re-asking is the caller's — only it knows whether the group came up —
// and this type owns the timing decision alone, in one copy rather than the
// three near-identical ones the sessions used to carry.

/// When a paced recovery may run.
struct RecoveryPacer: Sendable {

    /// How long between attempts. Long enough to turn a storm into a retry,
    /// short enough that a recovery nobody notices stays one.
    static let interval = Duration.milliseconds(500)

    /// What the caller should do with a request.
    enum Decision: Equatable {
        /// Nothing has run recently. Go.
        case now
        /// Too soon. Wait this long, then ask the caller's own question again
        /// before acting — see the note above.
        case after(Duration)
        /// A deferred attempt is already scheduled; this request is folded into
        /// it rather than adding a second timer.
        case alreadyWaiting
    }

    private var last: ContinuousClock.Instant?
    private var isWaiting = false

    init() {}

    /// Asks whether a recovery may run now.
    ///
    /// `now` is a parameter so a test can drive the clock rather than sleep.
    mutating func request(at now: ContinuousClock.Instant = .now) -> Decision {
        guard let last, now - last < Self.interval else {
            self.last = now
            return .now
        }
        guard !isWaiting else { return .alreadyWaiting }
        isWaiting = true
        return .after(Self.interval - (now - last))
    }

    /// Told when a deferred attempt's wait has elapsed, whether or not the
    /// caller goes on to act on it.
    mutating func waitElapsed() { isWaiting = false }
}
