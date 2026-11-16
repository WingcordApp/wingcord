import Foundation
import Synchronization
import WingcordCore

/// One process-wide gate that says whether *any* surface is being scrolled.
///
/// **This is the cross-cutting performance primitive the app is built on.** A
/// scroll is the one interaction with no spare frames, and almost everything the
/// app does in the background is optional *right now* and wanted a fraction of a
/// second later: decoding animated emoji, prefetching images for rows the
/// gesture is about to pass, recomputing unread badges, refreshing a catalog.
/// Every one of those parks here.
///
/// Four properties matter:
///
///  - **It is global, not per-surface.** Scrolling the member list has to
///     suspend the timeline's optional work too, because they share one main
///     thread. A per-view flag lets the other surface keep spending the frames
///     this one needs.
///  - **It is counted, not a boolean.** Two surfaces can be mid-gesture at once
///     (a trackpad fling in one, a momentum scroll finishing in another), and a
///     boolean lets whichever ends first release the gate for both.
///  - **Waiting does not poll.** `waitUntilInactive()` suspends on a
///     continuation and is resumed when the count reaches zero. A polling loop
///     wakes the CPU on a timer during exactly the interval it is supposed to be
///     staying out of the way — which is worse than not gating at all.
///  - **A hold is a lease, and it runs out** (`lease`). The failure mode of a
///     gate that is never released is every background task in the app
///     suspended forever — and it happened: the channel list's hover router
///     took the gate on a scroll, was freed mid-gesture by a page change, and
///     nothing was left to release it. Every avatar, nameplate and attachment
///     the drawn surfaces fetch waited behind it for the rest of the run
///     (WC-0AQB, WC-E5V8: rail icons and profile cards loaded, the transcript
///     and the member list never did). No owner can do that now: one that has
///     not renewed its hold within the lease is let go, and the waiters wake.
///
/// The machinery is `ScrollGate`; this is the app's one instance of it.
nonisolated enum ScrollWorkGate {

    /// How long one owner may hold the gate without renewing it. Every surface
    /// ends its own hold within three seconds of its last scroll event (each
    /// has a timeout for a gesture whose end AppKit never posts), so a hold
    /// older than this has nobody behind it.
    static let lease: Duration = .seconds(4)

    private static let shared = ScrollGate()

    static var isActive: Bool { shared.isActive }

    /// Marks one surface as scrolling, or renews its hold.
    ///
    /// Keyed by owner rather than counted, so a surface that somehow calls
    /// `begin` twice cannot leave the gate held — which matters because the
    /// failure mode of an unbalanced gate is every background task in the app
    /// suspended forever.
    static func begin(owner: ObjectIdentifier) {
        shared.begin(owner: owner)
    }

    static func endIfOwned(by owner: ObjectIdentifier) {
        shared.endIfOwned(by: owner)
    }

    /// Suspends until nothing is scrolling. Returns immediately when nothing is.
    static func waitUntilInactive() async {
        await shared.waitUntilInactive()
    }

    /// Whether `owner` holds the gate. Tests only: the gate's own question is
    /// whether anybody does.
    static func isHeldForTesting(by owner: ObjectIdentifier) -> Bool {
        shared.isHeld(by: owner)
    }
}

/// The gate's machinery: who holds it, since when, and who waits on it.
///
/// **A type, of which the app has one** (`ScrollWorkGate`), so a test can make
/// a gate of its own. The app's is shared with every suite that scrolls a
/// surface, and a test of the lease that waited on it waited for all of them
/// too — 17 s in a full run, against a lease of four.
///
/// The lock-backed state is re-checked after every wake, so a reordered executor
/// hop cannot start work underneath a newer gesture.
nonisolated final class ScrollGate: Sendable {
    fileprivate struct Snapshot: Sendable {
        fileprivate var isActive: Bool
        fileprivate var revision: UInt64
    }

    let lease: Duration
    private let state: Mutex<ScrollGateState>
    private let waiters = Waiters()

    init(lease: Duration = ScrollWorkGate.lease) {
        self.lease = lease
        state = Mutex(ScrollGateState(lease: lease))
    }

    var isActive: Bool {
        let now = ContinuousClock.now
        return state.withLock { $0.isActive(at: now) }
    }

    func begin(owner: ObjectIdentifier) {
        let now = ContinuousClock.now
        let revision: UInt64? = state.withLock { state in
            let wasActive = state.isActive(at: now)
            state.owners[owner] = now
            _ = state.dropExpired(at: now)
            guard !wasActive else { return nil }
            state.revision &+= 1
            return state.revision
        }
        guard let revision else { return }
        Task { await waiters.stateChanged(revision: revision, on: self) }
    }

    func endIfOwned(by owner: ObjectIdentifier) {
        let now = ContinuousClock.now
        let revision: UInt64? = state.withLock { state in
            guard state.owners.removeValue(forKey: owner) != nil else { return nil }
            _ = state.dropExpired(at: now)
            guard state.owners.isEmpty else { return nil }
            state.revision &+= 1
            return state.revision
        }
        guard let revision else { return }
        Task { await waiters.stateChanged(revision: revision, on: self) }
    }

    func waitUntilInactive() async {
        while !Task.isCancelled, isActive {
            await waiters.wait(on: self)
        }
    }

    func isHeld(by owner: ObjectIdentifier) -> Bool {
        state.withLock { $0.owners[owner] != nil }
    }

    fileprivate var snapshot: Snapshot {
        let now = ContinuousClock.now
        return state.withLock { Snapshot(isActive: $0.isActive(at: now), revision: $0.revision) }
    }

    /// When the oldest hold runs out, or nil when nothing is held.
    fileprivate var nextExpiry: ContinuousClock.Instant? {
        state.withLock { $0.owners.values.min().map { $0 + lease } }
    }

    /// Lets go of owners whose lease ran out. Returns the new revision when
    /// that left the gate open, for the waiters to act on.
    fileprivate func expireStaleOwners() -> UInt64? {
        let now = ContinuousClock.now
        return state.withLock { state in
            guard state.dropExpired(at: now) > 0, state.owners.isEmpty else { return nil }
            state.revision &+= 1
            return state.revision
        }
    }
}

/// Who holds the gate, and since when — the gate's bookkeeping as a plain value,
/// so its lease rule can be tested without the process-wide gate.
nonisolated struct ScrollGateState: Sendable {
    /// Each owner, and when it last said it was scrolling.
    var owners: [ObjectIdentifier: ContinuousClock.Instant] = [:]
    var revision: UInt64 = 0
    var lease: Duration = ScrollWorkGate.lease

    func isActive(at now: ContinuousClock.Instant) -> Bool {
        owners.values.contains { now - $0 < lease }
    }

    /// Lets go of every owner whose lease ran out, and says how many.
    mutating func dropExpired(at now: ContinuousClock.Instant) -> Int {
        let before = owners.count
        owners = owners.filter { now - $0.value < lease }
        return before - owners.count
    }
}

/// Holds the suspended waiters.
///
/// An actor rather than a lock around an array of continuations: resuming a
/// continuation while holding a lock is a way to re-enter it, and there is no
/// need for the resume path to be synchronous.
private actor Waiters {
    private var pending: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var appliedRevision: UInt64 = 0
    /// Wakes at the oldest hold's expiry while anybody is waiting — the one
    /// timer, and only while there is a waiter for it to free.
    private var expiry: Task<Void, Never>?

    func stateChanged(revision: UInt64, on gate: ScrollGate) {
        let snapshot = gate.snapshot
        // A stale notification — one whose revision has already been overtaken —
        // must not release waiters that a newer gesture has re-acquired.
        guard snapshot.revision == revision, revision >= appliedRevision else { return }
        appliedRevision = revision
        guard !snapshot.isActive else { return }
        releaseAll()
    }

    func wait(on gate: ScrollGate) async {
        // Re-check inside the actor: the gate may have cleared between the
        // caller's check and this hop, and a waiter added after the release
        // would never be resumed.
        guard gate.isActive else { return }
        armExpiry(on: gate)
        let id = UUID()
        await withCheckedContinuation { continuation in
            pending[id] = continuation
        }
    }

    private func releaseAll() {
        expiry?.cancel()
        expiry = nil
        let waiters = pending
        pending.removeAll(keepingCapacity: true)
        for continuation in waiters.values { continuation.resume() }
    }

    private func armExpiry(on gate: ScrollGate) {
        guard expiry == nil, let deadline = gate.nextExpiry else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(until: deadline + .milliseconds(20), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.expiryFired(on: gate)
        }
    }

    private func expiryFired(on gate: ScrollGate) {
        expiry = nil
        if let revision = gate.expireStaleOwners() {
            // **Said once, in the log a report carries**: a hold that ran out
            // is a surface that lost track of its own scroll, and the next one
            // is easier to find with the line there.
            Log.info(.perf, "a scroll held the background work past its lease; let go")
            stateChanged(revision: revision, on: gate)
        } else if !gate.isActive {
            releaseAll()
        } else if !pending.isEmpty {
            // Renewed meanwhile: wait for that hold's own expiry.
            armExpiry(on: gate)
        }
    }
}
