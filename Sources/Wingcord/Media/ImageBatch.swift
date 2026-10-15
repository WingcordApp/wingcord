import Foundation
import Synchronization

/// A surface's pictures, fetched together and shown as each one lands.
///
/// **Shown as they land, never when the slowest has.** Every surface that draws
/// from the caches — the transcript, the member list, the expression grid, the
/// pinned pane, a topic, search, the inbox — used to await its whole batch and
/// repaint once at the end. One slow download, a large photograph or a request
/// waiting out a dropped connection for up to the session's sixty seconds, then
/// kept every other picture in view on its placeholder, avatars included: the
/// "sometimes the images are bugged" shape. Each landing is reported now,
/// coalesced the way the highlighter's `didLand` is — the first waits
/// `coalescing` for company, and whatever lands meanwhile rides along in the
/// same report (REDESIGN.md D11).
nonisolated enum ImageBatch {

    /// How long a landing waits for others before it is reported: short enough
    /// that nobody sees it, long enough that a burst of avatars is one repaint.
    static let coalescing: TimeInterval = 0.05

    /// Runs every load at once and reports, on the main actor, the items that
    /// landed — a load answering `true` — in reports at most `coalescing` apart.
    /// Returns when every load has finished.
    ///
    /// A cancelled batch still reports what lands: the picture is in the cache
    /// either way, and the surface still has to draw it.
    static func load<Item: Sendable>(
        _ items: [Item],
        using load: @escaping @Sendable (Item) async -> Bool,
        landed: @escaping @MainActor @Sendable ([Item]) -> Void
    ) async {
        guard !items.isEmpty else { return }
        let reporter = LandingReporter(report: landed)
        await withTaskGroup(of: Item?.self) { group in
            for item in items {
                group.addTask { await load(item) ? item : nil }
            }
            for await item in group {
                if let item { reporter.add(item) }
            }
        }
    }

    /// The same for message rows' pictures, through `Request.load()`.
    static func load(
        _ requests: [TimelineImageRequests.Request],
        landed: @escaping @MainActor @Sendable ([TimelineImageRequests.Request]) -> Void
    ) async {
        await load(requests, using: { await $0.load() }, landed: landed)
    }
}

/// Hands over everything that landed in one report, `ImageBatch.coalescing`
/// after the first of them.
nonisolated final class LandingReporter<Item: Sendable>: Sendable {
    private let pending = Mutex<[Item]>([])
    private let report: @MainActor @Sendable ([Item]) -> Void

    init(report: @escaping @MainActor @Sendable ([Item]) -> Void) {
        self.report = report
    }

    func add(_ item: Item) {
        let isFirst = pending.withLock { items in
            items.append(item)
            return items.count == 1
        }
        guard isFirst else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + ImageBatch.coalescing) {
            let items = self.pending.withLock { items in
                let taken = items
                items.removeAll(keepingCapacity: true)
                return taken
            }
            MainActor.assumeIsolated { self.report(items) }
        }
    }
}
