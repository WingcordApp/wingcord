import Testing
@testable import Wingcord
import WingcordCore

/// "Sync theme across my devices": Discord's gradient presets by the id the
/// account carries (`BackgroundGradientPresetId`), which is not the order the
/// picker shows them in.
@Suite("Theme sync")
@MainActor
struct ThemeSyncTests {
    @Test("Every theme has its own id, and an id names its theme back")
    func roundTrip() {
        let ids = DiscordTheme.allCases.map(\.presetID)
        #expect(Set(ids).count == ids.count)
        for theme in DiscordTheme.allCases {
            #expect(DiscordTheme(presetID: theme.presetID) == theme)
        }
    }

    /// Discord's enum, read from its bundle: Sepia before Strawberry
    /// Lemonade, 16 the Easter Egg no picker shows, 23 Hexagon, the Grand
    /// Theft Auto VI campaign's Vice City.
    @Test("The ids are Discord's, not the picker's order")
    func discordsNumbers() {
        #expect(DiscordTheme.mintApple.presetID == 0)
        #expect(DiscordTheme.underTheSea.presetID == 15)
        #expect(DiscordTheme.retroStorm.presetID == 17)
        #expect(DiscordTheme.sepia.presetID == 19)
        #expect(DiscordTheme.strawberryLemonade.presetID == 20)
        #expect(DiscordTheme.blurpleTwilight.presetID == 22)
        #expect(DiscordTheme(presetID: 16) == nil)
        #expect(DiscordTheme(presetID: 23) == .viceCity)
    }

    @Test("A light preset sits on Discord's Light, a dark one on its Dark")
    func bases() {
        #expect(DiscordTheme.desertKhaki.base == .light)
        #expect(DiscordTheme.sunset.base == .dark)
    }
}
