import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The reader's user-colour saturation, where it has to be carried.
@Suite("User colour setting")
struct UserColorSettingTests {

    private func key(saturation: Double, inkCeiling: UInt32 = 0x18_18_1A) -> RosterMemoKey {
        RosterMemoKey(
            guildID: GuildID(rawValue: 1),
            channelID: ChannelID(rawValue: 2),
            memberListRevision: 7,
            memberRevision: 3,
            presenceRevision: 4,
            roleRevision: 5,
            structureRevision: 6,
            colorSaturation: saturation,
            inkCeiling: inkCeiling,
            typers: [],
            voice: RosterVoiceFacts()
        )
    }

    @Test("The roster memo can tell two saturations apart")
    func rosterKeyCarriesSaturation() {
        // **The trap this exists for.** A memo whose key omits a setting is
        // present, correct and never invalidated: the roster would keep serving
        // the colours it was built with until some unrelated revision happened
        // to move. Nothing about a member changes when this slider does, so
        // nothing else would.
        #expect(key(saturation: 1) != key(saturation: 0.5))
        #expect(key(saturation: 1) == key(saturation: 1))
    }

    @Test("The roster memo can tell two grounds apart")
    func rosterKeyCarriesTheGround() {
        // The same trap from the other side: a theme change moves which role
        // colours need lifting, and no member revision moves with it.
        #expect(key(saturation: 1, inkCeiling: 0x18_18_1A) != key(saturation: 1, inkCeiling: 0x3A_24_4C))
    }

    @Test("Turning it fully down greys a role without flattening the list")
    func fullyDownKeepsLightnessOrder() {
        // Two roles a reader could previously tell apart by brightness still
        // differ afterwards — which is the difference between a legible page
        // and a flattened one.
        let bright = UserColor.desaturated(0xF2_3F_43, by: 0)
        let dark = UserColor.desaturated(0x4A_10_12, by: 0)
        #expect(bright != dark)
        #expect((bright >> 16) > (dark >> 16))
    }

    @Test("Off by default, and off costs nothing")
    func defaultIsOff() {
        // The overwhelmingly common case. `UserColor` returns its input without
        // touching it at a factor of 1, so every colour in the window skips the
        // conversion entirely.
        let settings = AppSettings(defaults: UserDefaults(suiteName: #function)!)
        #expect(settings.userColorSaturation == 1)
        #expect(UserColor.desaturated(0x58_65_F2, by: settings.userColorSaturation) == 0x58_65_F2)
    }

    @Test("The slider cannot be driven outside its range")
    func clampsToRange() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: #function)!)
        settings.userColorSaturation = 4
        #expect(settings.userColorSaturation == 1)
        settings.userColorSaturation = -1
        #expect(settings.userColorSaturation == 0)
    }
}
