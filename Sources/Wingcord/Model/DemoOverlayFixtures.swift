import Foundation
import WingcordCore

// MARK: - Phase 6 in `--demo`
//
// docs/CLIPS-PRESENCE.md, Phase 6.7. Registered Games with something in it:
// the demo's game played two hours ago, three more in each state a switch can
// leave them in, and one added by hand — written once, into the demo's own
// defaults domain (`scripts/run-demo.sh` gives it its own bundle id), so the
// reader's switches survive the next demo run.

enum DemoOverlayFixtures {

    static func populate() {
        let store = RegisteredGamesStore.shared
        guard store.games.games.isEmpty else { return }
        let now = Date()
        func game(_ id: UInt64, _ name: String) -> DetectedGame {
            DetectedGame(
                id: ApplicationID(rawValue: id), name: name, startedAt: now,
                isLauncher: false, isTranslated: false, processIdentifier: 0
            )
        }
        store.noteRunning(
            game(DemoFixtures.battlefield.rawValue, "Battlefield 6"), at: now.addingTimeInterval(-2 * 3600)
        )

        let hades = game(1_200_000_000_000_000_001, "Hades II")
        store.noteRunning(hades, at: now.addingTimeInterval(-3 * 86400))
        if let entry = store.games.game(hades.id.rawValue) { store.setRecordsClips(false, for: entry) }

        let factorio = game(1_200_000_000_000_000_002, "Factorio")
        store.noteRunning(factorio, at: now.addingTimeInterval(-9 * 86400))
        if let entry = store.games.game(factorio.id.rawValue) { store.setShowsOverlay(false, for: entry) }

        let celeste = game(1_200_000_000_000_000_003, "Celeste")
        store.noteRunning(celeste, at: now.addingTimeInterval(-40 * 86400))
        if let entry = store.games.game(celeste.id.rawValue) { store.setDetected(false, for: entry) }

        // One added by hand, as "Add it!" files it.
        let path = "/Applications/RetroArch.app/Contents/MacOS/RetroArch"
        let id = RegisteredGamesStore.manualID(forExecutableAt: path)
        AppSettings.shared.addManualGame(name: "RetroArch", path: path, id: ApplicationID(rawValue: id))
        store.add(id: id, name: "RetroArch")
    }
}
