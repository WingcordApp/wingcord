import Foundation
import WingcordCore

/// Fetches a conversation's newest page while the pointer rests on its row,
/// so opening it finds the page here (docs/BETA3.md D7).
///
/// **Measured first, 2026-11-18:** every second of a channel's load was
/// Discord's own answer — the limiter waited 0 ms, Discord took 0.27–0.81 s
/// and up to 1.4 s for one channel — so the only way to make it feel instant is
/// not to wait at the click. A pointer resting on a row for 150 ms is nearly
/// always on its way to clicking it; one passing over is cancelled before
/// anything is asked. The session decides what is worth fetching
/// (`SessionController.prefetchNewestPage`).
@MainActor
final class HistoryPrefetcher {
    static let shared = HistoryPrefetcher()

    /// How long the pointer must rest on a row.
    static let dwell: Duration = .milliseconds(150)

    /// Set by the session: fetches one conversation's newest page.
    var prefetch: ((ChannelID) -> Void)?

    private var hoveredID: ChannelID?
    private var pending: Task<Void, Never>?

    func pointerEnteredRow(_ channelID: ChannelID) {
        hoveredID = channelID
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard let self, !Task.isCancelled, self.hoveredID == channelID else { return }
            self.prefetch?(channelID)
        }
    }

    func pointerLeftRow(_ channelID: ChannelID) {
        guard hoveredID == channelID else { return }
        hoveredID = nil
        pending?.cancel()
        pending = nil
    }
}
