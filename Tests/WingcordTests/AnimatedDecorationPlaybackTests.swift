import Foundation
import Testing
@testable import Wingcord

/// When `AnimatedDecoration` is allowed to say whether it has frames on screen.
///
/// **The answer is "never during a SwiftUI update", and this suite exists
/// because breaking that is invisible.** `configure` runs from `updateNSView`,
/// and two of its three paths call `install` synchronously from there. A
/// callback made on that stack is a `@State` write during a view update — it
/// compiles, it raises no error a person will see, and the write simply does not
/// stick.
///
/// What it looked like in the app: an animated server icon played correctly the
/// **first** time it was hovered and drew a second, offset copy of itself behind
/// the film on every hover after that. The first hover misses the filmstrip
/// cache, so the report came from the load's continuation and landed; every
/// later hover hit the cache, reported from inside the update, and the still
/// underneath was never taken away.
@Suite("Animated decoration playback reporting")
@MainActor
struct AnimatedDecorationPlaybackTests {

    /// A URL nothing has ever fetched, so `configure` takes the uncached path —
    /// `setImage(nil)`, unsubscribe, report `false` — with no store to prime.
    private var uncachedURL: URL {
        URL(string: "https://cdn.discordapp.com/icons/1/a_\(UUID().uuidString).gif")!
    }

    /// Lets the deferred report run.
    ///
    /// A sleep rather than `Task.yield()`: the report is enqueued as a *new*
    /// main-actor task, and yielding once only guarantees this test suspends —
    /// not that the task it is waiting on has been scheduled and finished.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// A coordinator with a live view, and **the view handed back with it.**
    ///
    /// `Coordinator.view` is `weak` — it belongs to the representable, not to
    /// the coordinator — so a view created and dropped here is deallocated
    /// before the deferred report runs, `report`'s liveness guard fires, and the
    /// test measures its own mistake rather than the code. The caller holds it.
    private func makeCoordinator() -> (AnimatedDecoration.Coordinator, AnimatedLayerView) {
        let coordinator = AnimatedDecoration.Coordinator()
        let view = AnimatedLayerView(gravity: .resizeAspectFill)
        coordinator.view = view
        return (coordinator, view)
    }

    @Test("A playback report never lands during the configure that raised it")
    func reportIsDeferredOutOfTheUpdatePass() async {
        let (coordinator, view) = makeCoordinator()
        defer { withExtendedLifetime(view) {} }
        var reports: [Bool] = []
        coordinator.onPlayback = { reports.append($0) }

        coordinator.configure(
            url: uncachedURL,
            pixelSize: 88,
            byteBudget: 1 << 20,
            isAnimated: true
        )

        // **The assertion that would have caught the bug.** `configure` is the
        // body of `updateNSView`; anything it reports synchronously is a state
        // write inside a view update.
        #expect(reports.isEmpty)

        await settle()
        #expect(reports == [false])
    }

    /// A report belonging to a configuration that has been replaced must not
    /// arrive: it would describe the wrong asset, and on the way in that means
    /// hiding the still for a film that is not there.
    @Test("A report is dropped when the decoration is reconfigured under it")
    func staleReportIsDropped() async {
        let (coordinator, view) = makeCoordinator()
        defer { withExtendedLifetime(view) {} }
        var reports: [Bool] = []
        coordinator.onPlayback = { reports.append($0) }

        coordinator.configure(url: uncachedURL, pixelSize: 88, byteBudget: 1 << 20, isAnimated: true)
        coordinator.configure(url: uncachedURL, pixelSize: 88, byteBudget: 1 << 20, isAnimated: true)
        await settle()

        // Two configures, and only the live one is entitled to speak.
        #expect(reports == [false])
    }

    /// The same for a decoration that has left the tree — which is exactly what
    /// a rail tile does every time the pointer leaves it.
    @Test("A report is dropped when the decoration is torn down under it")
    func reportAfterTeardownIsDropped() async {
        let (coordinator, view) = makeCoordinator()
        defer { withExtendedLifetime(view) {} }
        var reports: [Bool] = []
        coordinator.onPlayback = { reports.append($0) }

        coordinator.configure(url: uncachedURL, pixelSize: 88, byteBudget: 1 << 20, isAnimated: true)
        coordinator.tearDown()
        await settle()

        #expect(reports.isEmpty)
    }
}
