import Foundation
import Observation
import WingcordCore

// MARK: - Registered Games, kept on this Mac
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D22.3). The list and its switches are
// `RegisteredGames` (Core); this keeps them between launches and is where the
// three switches are read:
//
//   * detection — `SessionController.applyRunningGame` publishes nothing for a
//     game switched off, so it has no activity, no overlay, no clips and no
//     Game Mode;
//   * overlay — `OverlayController.refreshPresentation`;
//   * clips — `AppModel.refreshOverlay`, which arms the buffer.
//
// Games added by hand are still filed by executable path in
// `AppSettings.manualGames`, which is what the detector matches on; they appear
// here as well, marked as the reader's own, which is what makes them
// removable.

@Observable
@MainActor
final class RegisteredGamesStore {
    static let shared = RegisteredGamesStore()

    private(set) var games: RegisteredGames

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "activity.registeredGames"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        games = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(RegisteredGames.self, from: $0) }
            ?? RegisteredGames()
    }

    // MARK: Seeing them

    /// A game is running, or has just stopped: its "Last played" moves on.
    func noteRunning(_ game: DetectedGame, at date: Date = Date()) {
        change { $0.noteRunning(id: game.id.rawValue, name: game.name, at: date) }
    }

    /// Games the reader added by hand before this list existed join it, once.
    func adopt(_ manual: [AppSettings.ManualGame]) {
        let missing = manual.filter { games.game($0.id)?.isAddedByHand != true }
        guard !missing.isEmpty else { return }
        change { games in
            for entry in missing {
                games.add(id: entry.id, name: entry.name, at: .distantPast)
            }
        }
    }

    func add(id: UInt64, name: String) {
        change { $0.add(id: id, name: name, at: Date()) }
    }

    func remove(_ id: UInt64) {
        change { $0.remove(id) }
    }

    // MARK: The switches

    func setDetected(_ on: Bool, for game: RegisteredGame) {
        change { $0.setDetected(on, for: game.id, name: game.name) }
    }

    func setShowsOverlay(_ on: Bool, for game: RegisteredGame) {
        change { $0.setShowsOverlay(on, for: game.id, name: game.name) }
    }

    func setRecordsClips(_ on: Bool, for game: RegisteredGame) {
        change { $0.setRecordsClips(on, for: game.id, name: game.name) }
    }

    private func change(_ body: (inout RegisteredGames) -> Void) {
        var next = games
        body(&next)
        guard next != games else { return }
        games = next
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.key)
    }

    // MARK: Ids for games added by hand

    /// A stable id for an executable nobody's database knows.
    ///
    /// **FNV-1a over the path, not `hashValue`**, which Swift seeds afresh
    /// every launch — an id derived from it named the same executable
    /// differently each time the app started. The top bit is set so it can
    /// never be mistaken for a Discord snowflake, which stays far below it
    /// for centuries.
    nonisolated static func manualID(forExecutableAt path: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash | (1 << 63)
    }
}
