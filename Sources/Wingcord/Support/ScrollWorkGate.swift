import Foundation
import Synchronization

/// One process-wide gate that says whether *any* surface is being scrolled.
///
/// **This is the cross-cutting performance primitive the app is built on.** A
/// scroll is the one interaction with no spare frames, and almost everything the
/// app does in the background is optional *right now* and wanted a fraction of a
/// second later: decoding animated emoji, prefetching images for rows the
/// gesture is about to pass, recomputing unread badges, refreshing a catalog.
/// Every one of those parks here.
///
/// Three properties matter:
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
///
/// The lock-backed state is re-checked after every wake, so a reordered executor
/// hop cannot start work underneath a newer gesture.
nonisolated enum ScrollWorkGate {

    private struct State {
        var owners: Set<ObjectIdentifier> = []
        var revision: UInt64 = 0
    }

    fileprivate struct Snapshot: Sendable {
        fileprivate var isActive: Bool
        fileprivate var revision: UInt64
    }

    private static let state = Mutex(State())
    private static let waiters = Waiters()

    static var isActive: Bool {
        state.withLock { !$0.owners.isEmpty }
    }

    /// Marks one surface as scrolling.
    ///
    /// Keyed by owner rather than counted, so a surface that somehow calls
    /// `begin` twice cannot leave the gate held — which matters because the
    /// failure mode of an unbalanced gate is every background task in the app
    /// suspended forever.
    static func begin(owner: ObjectIdentifier) {
        let revision: UInt64? = state.withLock { state in
            guard state.owners.insert(owner).inserted, state.owners.count == 1 else {
                return nil
            }
            state.revision &+= 1
            return state.revision
        }
        guard let revision else { return }
        Task { await waiters.stateChanged(revision: revision) }
    }

    static func endIfOwned(by owner: ObjectIdentifier) {
        let revision: UInt64? = state.withLock { state in
            guard state.owners.remove(owner) != nil, state.owners.isEmpty else {
                return nil
            }
            state.revision &+= 1
            return state.revision
        }
        guard let revision else { return }
        Task { await waiters.stateChanged(revision: revision) }
    }

    /// Suspends until nothing is scrolling. Returns immediately when nothing is.
    static func waitUntilInactive() async {
        while !Task.isCancelled, isActive {
            await waiters.wait()
        }
    }

    fileprivate static var snapshot: Snapshot {
        state.withLock { Snapshot(isActive: !$0.owners.isEmpty, revision: $0.revision) }
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

    func stateChanged(revision: UInt64) {
        let snapshot = ScrollWorkGate.snapshot
        // A stale notification — one whose revision has already been overtaken —
        // must not release waiters that a newer gesture has re-acquired.
        guard snapshot.revision == revision, revision >= appliedRevision else { return }
        appliedRevision = revision
        guard !snapshot.isActive else { return }
        let waiters = pending
        pending.removeAll(keepingCapacity: true)
        for continuation in waiters.values { continuation.resume() }
    }

    func wait() async {
        // Re-check inside the actor: the gate may have cleared between the
        // caller's check and this hop, and a waiter added after the release
        // would never be resumed.
        guard ScrollWorkGate.isActive else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            pending[id] = continuation
        }
    }
}
