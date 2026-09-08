import Foundation
import WingcordCore
import WingcordNet

// The quick switcher's two requests, which are the only two it has.
//
// Everything else on its list — servers, channels, voice channels, people — is
// answered out of tables this client already holds, which is exactly what
// `quick switcher.har` shows the reference client doing.

extension SessionController {

    /// Discord's own guild-and-channel frecency, which is what orders the list.
    ///
    /// **Once per session, on the first ⌘K.** It is field 12 of the same
    /// twenty-eight-kilobyte settings protobuf the Recents row and the `/` list
    /// read, and the route has no conditional — asking for it again is the whole
    /// blob again for a table that moves when the account navigates on *another*
    /// device. The latch is a flag rather than "is the table empty", because an
    /// account that has never been anywhere answers an empty one and that is a
    /// real answer.
    func loadNavigationFrecency() {
        guard !hasLoadedNavigationFrecency else { return }
        hasLoadedNavigationFrecency = true
        Task { [weak self] in
            guard let self else { return }
            do {
                model.placeFrecency = try await rest.navigationFrecency()
                Self.trace("switcher: frecency → \(model.placeFrecency.count) places")
            } catch {
                // No retry and no notice. The switcher works without it — the
                // list simply falls back to matching alone — so a failure here
                // is not something to interrupt anybody about.
                Self.trace("switcher: frecency failed — \(Self.describe(error))")
            }
        }
    }

    /// `/games/autocomplete?q=` — the one route the switcher calls.
    ///
    /// **Debounced and deduplicated, where the reference client is neither.**
    /// The capture fires one request per keystroke and repeats itself twice for
    /// the same `q`; both are its rate budget to spend. A short wait costs
    /// nothing anybody can see and turns `grand theft` from eleven requests into
    /// two.
    ///
    /// The needle travels with the answer so the panel can refuse to draw a list
    /// that answers a question nobody is asking any more — see
    /// `QuickSwitchState.gamesNeedle`.
    func searchGames(matching needle: String) {
        guard model.quickSwitch?.gamesNeedle != needle else { return }
        gameSearchTask?.cancel()
        model.quickSwitch?.isSearchingGames = true

        gameSearchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.gameSearchDebounce)
            guard let self, !Task.isCancelled else { return }
            defer { if !Task.isCancelled { model.quickSwitch?.isSearchingGames = false } }
            do {
                let games = try await rest.searchGames(needle)
                guard !Task.isCancelled, model.quickSwitch != nil else { return }
                model.quickSwitch?.games = games
                model.quickSwitch?.gamesNeedle = needle
            } catch {
                guard !Task.isCancelled, model.quickSwitch != nil else { return }
                // **Answered as empty rather than left alone.** Leaving the
                // previous hits up would draw `Grand Theft Auto V` under a field
                // that says something else entirely, which reads as a list that
                // stopped responding rather than as a request that failed.
                model.quickSwitch?.games = []
                model.quickSwitch?.gamesNeedle = needle
                Self.trace("switcher: games failed — \(Self.describe(error))")
            }
        }
    }

    func cancelGameSearch() {
        gameSearchTask?.cancel()
        gameSearchTask = nil
    }

    /// Long enough to skip the characters somebody types on the way to a word,
    /// short enough that the row is there by the time they stop.
    static let gameSearchDebounce = Duration.milliseconds(180)
}
