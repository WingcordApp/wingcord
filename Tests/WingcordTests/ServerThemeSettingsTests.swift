import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The Server Theme settings row and its picker's facts.
@Suite("Server Theme settings")
@MainActor
struct ServerThemeSettingsTests {

    private func settings(_ features: Set<String>) -> GuildSettings {
        GuildSettings(id: GuildID(rawValue: 1), name: "S", ownerID: UserID(rawValue: 9), features: features)
    }

    @Test("The row is offered where the server may wear a theme, to Manage Server")
    func rowGate() {
        let row = ServerSettingsSection.serverTheme
        #expect(row.isAvailable(in: settings(["GUILD_THEME"]), isOwner: false))
        #expect(!row.isAvailable(in: settings([]), isOwner: false))
        #expect(row.isReachable(with: .manageGuild))
        #expect(!row.isReachable(with: .manageRoles))
    }

    @Test("It sits between Server Tag and Engagement, as Discord's does")
    func rowPlace() {
        #expect(ServerSettingsSection.groups.first?.sections == [.profile, .tag, .serverTheme, .engagement, .boostPerks])
    }

    @Test("The picker lays out all ten presets, each named, Twilight first")
    func picker() {
        #expect(Set(ServerTheme.pickerOrder) == Set(GuildTheme.presetIDs))
        #expect(ServerTheme.pickerOrder.count == 10)
        #expect(ServerTheme.pickerOrder.first == 1)
        #expect(ServerTheme.pickerOrder.allSatisfy { ServerTheme.presetNames[$0] != nil })
        #expect(ServerTheme.presetNames[1] == "Twilight")
        #expect(ServerTheme.presetNames[10] == "Blurple")
    }
}
