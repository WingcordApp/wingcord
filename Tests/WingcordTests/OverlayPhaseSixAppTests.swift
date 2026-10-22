import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Phase 6's app side (docs/CLIPS-PRESENCE.md): Streamer Mode, Game Mode,
/// Registered Games and the soundboard wheel, without a window.
@MainActor
@Suite("Overlay, Streamer Mode, Game Mode and registered games — app side")
struct OverlayPhaseSixAppTests {

    private func defaults() -> UserDefaults {
        let name = "wingcord.tests.phase6.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Streamer Mode

    @Test("Streamer Mode keeps its settings between launches")
    func streamerPersists() {
        let store = defaults()
        let first = StreamerMode(defaults: store)
        #expect(!first.isEnabled)
        first.update {
            $0.isEnabled = true
            $0.hiddenOverlayWidgets = [.chat, .notifications]
        }
        let second = StreamerMode(defaults: store)
        #expect(second.isEnabled)
        #expect(second.hiddenOverlayWidgets == [.chat, .notifications])
        #expect(second.hidesInviteLinks)
        #expect(second.inviteText("https://discord.gg/abc123") == "https://discord.gg/••••••••")
        #expect(second.inviteCode("abc123") == "••••••••")
        second.toggle()
        #expect(!second.isEnabled)
        #expect(second.inviteCode("abc123") == "abc123")
        #expect(second.hiddenOverlayWidgets.isEmpty, "nothing withheld while it is off")
    }

    // MARK: Game Mode

    private func game(launcher: Bool = false) -> DetectedGame {
        DetectedGame(
            id: ApplicationID(rawValue: 42), name: "Hades", startedAt: .now,
            isLauncher: launcher, isTranslated: false, processIdentifier: 0
        )
    }

    @Test("Game Mode is on by default and active only for a game that is not a launcher")
    func gameModeActive() {
        let mode = GameMode(defaults: defaults())
        #expect(mode.isEnabled)
        #expect(!mode.isActive)
        mode.gameChanged(game(launcher: true))
        #expect(!mode.isActive)
        mode.gameChanged(game())
        #expect(mode.isActive)
        mode.isEnabled = false
        #expect(!mode.isActive)
        #expect(!mode.isThrottling)
        mode.gameChanged(nil)
    }

    // MARK: Registered games

    @Test("A game added by hand gets one id for its path, every launch, never a snowflake")
    func manualIDs() {
        let path = "/Applications/Retro.app/Contents/MacOS/Retro"
        let id = RegisteredGamesStore.manualID(forExecutableAt: path)
        #expect(id == RegisteredGamesStore.manualID(forExecutableAt: path))
        #expect(id != RegisteredGamesStore.manualID(forExecutableAt: path + "2"))
        #expect(id & (1 << 63) != 0)
        let detected = DetectedGame(
            id: ApplicationID(rawValue: id), name: "Retro", startedAt: .now,
            isLauncher: false, isTranslated: false, processIdentifier: 1
        )
        // Published by name alone — no application on Discord has this id.
        #expect(detected.isAddedByHand)
        #expect(detected.activity.applicationID == nil)
        #expect(game().activity.applicationID == ApplicationID(rawValue: 42))
    }

    @Test("Registered games keep their switches between launches, and adopt older hand-added ones")
    func registeredPersist() {
        let store = defaults()
        let first = RegisteredGamesStore(defaults: store)
        first.noteRunning(game())
        let hades = first.games.game(42)!
        first.setShowsOverlay(false, for: hades)
        first.adopt([AppSettings.ManualGame(name: "Retro", path: "/r", id: 7)])
        let second = RegisteredGamesStore(defaults: store)
        #expect(second.games.showsOverlay(42) == false)
        #expect(second.games.game(7)?.isAddedByHand == true)
        second.remove(7)
        #expect(second.games.game(7) == nil)
    }

    // MARK: The wheel

    @Test("The wheel offers favourites first, never a locked sound, and each sound once")
    func wheelSounds() {
        func sound(_ id: String, locked: Bool = false, favourite: Bool = false) -> SoundboardPresentation.Entry {
            .init(id: id, name: id, emoji: nil, emojiURL: nil, isLocked: locked, isFavorite: favourite, refusal: nil)
        }
        func section(
            _ id: String, _ kind: SoundboardPresentation.Kind, locked: Bool = false,
            _ sounds: [SoundboardPresentation.Entry]
        ) -> SoundboardPresentation.Section {
            .init(id: id, kind: kind, title: id, iconURL: nil, monogram: "", isLocked: locked, sounds: sounds)
        }
        let presentation = SoundboardPresentation(
            sections: [
                section("favorites", .favorites, [sound("b", favourite: true)]),
                section("frequent", .frequentlyUsed, [sound("z")]),
                section("home", .server, [sound("a"), sound("b", favourite: true), sound("x", locked: true)]),
                section("defaults", .defaults, [sound("quack")]),
                section("elsewhere", .server, locked: true, [sound("nope", locked: true)]),
            ],
            playsEverywhere: false,
            isSilenced: false
        )
        #expect(SoundboardWheelController.sounds(in: presentation).map(\.id) == ["b", "a", "quack"])
    }
}
