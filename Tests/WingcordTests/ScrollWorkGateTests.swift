import Foundation
import Testing
@testable import Wingcord

/// The app-wide scroll gate can no longer be held forever (BETA2.md D2).
///
/// Most of these read the gate's bookkeeping as a value, because the gate
/// itself is process-wide and other suites scroll their surfaces in parallel.
struct ScrollWorkGateTests {
    private final class Owner {}

    @Test("A hold inside its lease keeps the gate shut")
    func freshHoldIsActive() {
        var state = ScrollGateState()
        let now = ContinuousClock.now
        let owner = Owner()
        state.owners[ObjectIdentifier(owner)] = now
        #expect(state.isActive(at: now))
        #expect(state.isActive(at: now + .seconds(3)))
    }

    /// **WC-0AQB, WC-E5V8.** An owner freed mid-scroll left the gate shut for
    /// the rest of the run, and every drawn surface's pictures behind it.
    @Test("A hold nobody renews runs out")
    func staleHoldExpires() {
        var state = ScrollGateState()
        let now = ContinuousClock.now
        let owner = Owner()
        state.owners[ObjectIdentifier(owner)] = now
        let later = now + ScrollWorkGate.lease + .milliseconds(1)
        #expect(!state.isActive(at: later))
        #expect(state.dropExpired(at: later) == 1)
        #expect(state.owners.isEmpty)
    }

    @Test("One live hold keeps the gate shut while a stale one runs out")
    func liveHoldOutlastsStaleOne() {
        var state = ScrollGateState()
        let now = ContinuousClock.now
        // Kept alive: two temporaries can share an address, and so an identity.
        let stale = Owner(), live = Owner()
        state.owners[ObjectIdentifier(stale)] = now
        state.owners[ObjectIdentifier(live)] = now + .seconds(3)
        let later = now + ScrollWorkGate.lease + .milliseconds(500)
        #expect(state.isActive(at: later))
        #expect(state.dropExpired(at: later) == 1)
        #expect(state.owners.count == 1)
        withExtendedLifetime((stale, live)) {}
    }

    /// The gate end to end: a waiter behind a hold whose owner is gone is let
    /// through once the lease runs out, not never.
    ///
    /// **On a gate of its own.** The app's is shared with every suite that
    /// scrolls a surface, and waiting on it waited for them as well — 17 s in a
    /// full run. Here nothing but the lease can open it, so getting through at
    /// all is the proof; the time limit is what "never" would hit.
    ///
    /// **Three minutes, not one**: on GitHub's runner the whole run is starved
    /// — suites that take seconds here took 155 s there — and the one-second
    /// lease's task waited for a thread for about two minutes, failing `main`'s
    /// build on every push since 2026-11-16 though the waiter did get through
    /// (docs/BETA3.md §1.11). Still a limit, so "never" still fails.
    @Test("A waiter behind a forgotten hold is let through", .timeLimit(.minutes(3)))
    func waiterOutlivesForgottenHold() async {
        let gate = ScrollGate(lease: .seconds(1))
        let owner = Owner()
        let id = ObjectIdentifier(owner)
        // Taken, and never renewed or ended: the owner that lost track of it.
        gate.begin(owner: id)
        #expect(gate.isActive)
        await gate.waitUntilInactive()
        #expect(!gate.isActive)
        withExtendedLifetime(owner) {}
    }

    /// The hover router released the gate only from `tearDown`, which a list
    /// freed mid-scroll never reached.
    @Test("A hover router let go mid-scroll releases its hold")
    @MainActor
    func routerReleasesOnDeinit() {
        var router: SidebarHoverRouter? = SidebarHoverRouter()
        let id = ObjectIdentifier(router!)
        ScrollWorkGate.begin(owner: id)
        #expect(ScrollWorkGate.isHeldForTesting(by: id))
        router = nil
        #expect(!ScrollWorkGate.isHeldForTesting(by: id))
    }
}
