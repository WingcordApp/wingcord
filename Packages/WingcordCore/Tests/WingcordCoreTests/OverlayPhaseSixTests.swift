import CoreGraphics
import Foundation
import Testing
@testable import WingcordCore

/// docs/CLIPS-PRESENCE.md, Phase 6: layout presets, Streamer Mode, Registered
/// Games and the soundboard wheel — the parts of each with no window in them.
@Suite("Overlay, Streamer Mode and registered games")
struct OverlayPhaseSixTests {

    // MARK: Presets

    @Test("Default is the fresh install's layout, and is recognised as itself")
    func defaultPreset() {
        #expect(OverlayLayoutPreset.standard.layout == .default)
        #expect(OverlayLayoutPreset.matching(.default) == .standard)
        // A stored layout that never wrote a placement draws the same.
        #expect(OverlayLayoutPreset.matching(OverlayLayout(placements: [:])) == .standard)
    }

    @Test("Each preset is a whole layout, and only one of them matches")
    func presetsAreDistinct() {
        for preset in OverlayLayoutPreset.allCases {
            #expect(OverlayLayoutPreset.matching(preset.layout) == preset, "\(preset.rawValue)")
        }
        var moved = OverlayLayout.default
        moved.move(.voice, to: CGPoint(x: 0.3, y: 0.3))
        #expect(OverlayLayoutPreset.matching(moved) == nil)
    }

    @Test("Streaming draws nothing personal")
    func streamingPreset() {
        let visible = OverlayLayoutPreset.streaming.layout.visibleWidgets(locked: false)
        for kind in [OverlayWidgetKind.chat, .friends, .notifications, .activity] {
            #expect(!visible.contains(kind), "\(kind.rawValue)")
        }
        #expect(visible.contains(.voice))
        #expect(visible.contains(.quickActions))
    }

    @Test("Minimal keeps the call and nothing else")
    func minimalPreset() {
        let visible = Set(OverlayLayoutPreset.minimal.layout.visibleWidgets(locked: false))
        #expect(visible == [.voice, .quickActions, .notifications, .clips])
    }

    @Test("A saved layout's name is the first number free")
    func savedNames() {
        #expect(OverlaySavedLayout.nextName(after: []) == "Layout 1")
        let two = [
            OverlaySavedLayout(name: "Layout 1", layout: .default),
            OverlaySavedLayout(name: "Layout 2", layout: .default),
        ]
        #expect(OverlaySavedLayout.nextName(after: two) == "Layout 3")
        let renamed = [OverlaySavedLayout(name: "Layout 2", layout: .default)]
        #expect(OverlaySavedLayout.nextName(after: renamed) == "Layout 3")
    }

    // MARK: Streamer Mode

    @Test("Discord's defaults, and nothing happens while it is off")
    func streamerDefaults() {
        var settings = StreamerModeSettings()
        #expect(!settings.isEnabled)
        #expect(settings.turnsOnWithStreamingSoftware)
        #expect(settings.hidesPersonalInformation && settings.hidesInviteLinks)
        #expect(settings.disablesSounds && settings.disablesNotifications)
        #expect(!settings.hidesWindowsFromCapture)
        settings.hiddenOverlayWidgets = [.chat]
        // Every option means nothing while the mode is off — Discord's getters.
        #expect(!settings.hidesPersonalInformationNow)
        #expect(!settings.hidesInviteLinksNow)
        #expect(!settings.disablesSoundsNow)
        #expect(settings.hiddenOverlayWidgetsNow.isEmpty)
        settings.isEnabled = true
        #expect(settings.hidesPersonalInformationNow)
        #expect(settings.hiddenOverlayWidgetsNow == [.chat])
        #expect(!settings.hidesWindowsFromCaptureNow)
    }

    @Test("The streaming software turns it on and off, whatever it was")
    func streamerAutomatic() {
        var settings = StreamerModeSettings()
        let started = settings.streamingSoftwareChanged(running: true)
        #expect(started)
        #expect(settings.isEnabled)
        // Off by hand while OBS runs, then OBS quits: still off, nothing moved.
        settings.isEnabled = false
        let quit = settings.streamingSoftwareChanged(running: false)
        #expect(!quit)
        // On by hand, then OBS starts and quits: Discord's rule takes it off.
        settings.isEnabled = true
        settings.streamingSoftwareChanged(running: true)
        settings.streamingSoftwareChanged(running: false)
        #expect(!settings.isEnabled)
        // The automatic switch off: the software changes nothing.
        settings.turnsOnWithStreamingSoftware = false
        let ignored = settings.streamingSoftwareChanged(running: true)
        #expect(!ignored)
        #expect(!settings.isEnabled)
    }

    @Test("Settings survive a round trip, and an old blob reads as defaults")
    func streamerCoding() throws {
        var settings = StreamerModeSettings()
        settings.isEnabled = true
        settings.hidesWindowsFromCapture = true
        settings.hiddenOverlayWidgets = [.friends, .notifications]
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(StreamerModeSettings.self, from: data) == settings)

        let old = Data(#"{"isEnabled":true,"hiddenOverlayWidgets":["chat","someday"]}"#.utf8)
        let read = try JSONDecoder().decode(StreamerModeSettings.self, from: old)
        #expect(read.isEnabled)
        #expect(read.disablesSounds)
        #expect(read.hiddenOverlayWidgets == [.chat])
    }

    @Test("OBS and the Mac's other broadcasters are recognised")
    func streamingSoftware() {
        #expect(StreamingSoftware.match(bundleIdentifier: "com.obsproject.obs-studio", name: nil)?.name == "OBS")
        #expect(StreamingSoftware.match(bundleIdentifier: "x.y", name: "Streamlabs Desktop")?.name == "Streamlabs")
        #expect(StreamingSoftware.match(bundleIdentifier: "com.apple.Safari", name: "Safari") == nil)
    }

    @Test("What Streamer Mode leaves of an address, a number and an invite")
    func masks() {
        #expect(!StreamerModeMask.email("someone@example.com").contains("example"))
        #expect(StreamerModeMask.phone("+44 7700 900123").hasSuffix("23"))
        #expect(!StreamerModeMask.phone("+44 7700 900123").contains("7700"))
        #expect(StreamerModeMask.invite("https://discord.gg/abcDEF") == "https://discord.gg/••••••••")
    }

    // MARK: Registered games

    private let early = Date(timeIntervalSince1970: 1_700_000_000)
    private let late = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A game seen is kept, newest first, with every switch on")
    func seenGames() {
        var games = RegisteredGames()
        games.noteRunning(id: 1, name: "Celeste", at: early)
        games.noteRunning(id: 2, name: "Hades", at: late)
        #expect(games.byLastPlayed.map(\.name) == ["Hades", "Celeste"])
        #expect(games.isDetected(1) && games.showsOverlay(1) && games.recordsClips(1))
        // Never seen: detected, because the detector found it.
        #expect(games.isDetected(99))
        games.noteRunning(id: 1, name: "Celeste", at: late.addingTimeInterval(60))
        #expect(games.byLastPlayed.first?.id == 1)
        #expect(games.games.count == 2)
    }

    @Test("The switches hold, including on a game the list had not kept yet")
    func switches() {
        var games = RegisteredGames()
        games.setShowsOverlay(false, for: 7, name: "Factorio")
        #expect(!games.showsOverlay(7))
        #expect(games.isDetected(7))
        games.setDetected(false, for: 7, name: "Factorio")
        games.setRecordsClips(false, for: 7, name: "Factorio")
        #expect(!games.isDetected(7) && !games.recordsClips(7))
        // Seen again: the switches survive the note.
        games.noteRunning(id: 7, name: "Factorio", at: late)
        #expect(!games.showsOverlay(7))
    }

    @Test("Only a game added by hand can be removed, and its name is the reader's")
    func handAdded() {
        var games = RegisteredGames()
        games.noteRunning(id: 3, name: "Hades", at: early)
        let removedDetected = games.remove(3)
        #expect(!removedDetected)
        games.add(id: 4, name: "My Emulator", at: early)
        games.noteRunning(id: 4, name: "retroarch", at: late)
        #expect(games.game(4)?.name == "My Emulator")
        let removedOwn = games.remove(4)
        #expect(removedOwn)
        #expect(games.game(4) == nil)
    }

    @Test("The list stops growing, dropping the oldest nobody touched")
    func trimmed() {
        var games = RegisteredGames()
        games.setShowsOverlay(false, for: 0, name: "Kept")
        for index in 1 ... RegisteredGames.limit + 5 {
            games.noteRunning(id: UInt64(index), name: "Game \(index)", at: early.addingTimeInterval(Double(index)))
        }
        #expect(games.games.count == RegisteredGames.limit)
        #expect(games.game(0) != nil)
        #expect(games.game(1) == nil)
        #expect(games.game(UInt64(RegisteredGames.limit + 5)) != nil)
    }

    // MARK: The wheel

    @Test("The direction chooses the sound; the middle chooses none")
    func wheelSelection() {
        #expect(SoundboardWheelLayout.slot(at: CGVector(dx: 0, dy: -100)) == 0)
        #expect(SoundboardWheelLayout.slot(at: CGVector(dx: 100, dy: 0)) == 2)
        #expect(SoundboardWheelLayout.slot(at: CGVector(dx: 0, dy: 100)) == 4)
        #expect(SoundboardWheelLayout.slot(at: CGVector(dx: -100, dy: 0)) == 6)
        #expect(SoundboardWheelLayout.slot(at: CGVector(dx: 80, dy: -60)) == 1)
        #expect(SoundboardWheelLayout.slot(at: CGVector(dx: -80, dy: 60)) == 5)
        // Inside the dead zone: nothing.
        #expect(SoundboardWheelLayout.slot(at: CGVector(dx: 10, dy: 10)) == nil)
        // Towards a place this page has no sound for: nothing.
        #expect(SoundboardWheelLayout.slot(at: CGVector(dx: -100, dy: 0), count: 3) == nil)
    }

    @Test("Every sound sits inside the wheel, and pages hold eight")
    func wheelPlacement() {
        let bounds = CGRect(x: 0, y: 0, width: 288, height: 288)
        for slot in 0 ..< 8 {
            #expect(bounds.contains(SoundboardWheelLayout.frame(of: slot)), "slot \(slot)")
        }
        #expect(SoundboardWheelLayout.frame(of: 0).midX == 144)
        #expect(SoundboardWheelLayout.pages(of: Array(0 ..< 19)).map(\.count) == [8, 8, 3])
        #expect(SoundboardWheelLayout.pages(of: [Int]()).isEmpty)
    }
}
