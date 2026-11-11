import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The sidebar's Servers page while Home is selected.
///
/// Alex, 2026-11-10: "I can select them in the channel list, but nothing
/// happens". The Messages and Servers switch only moves the pages, so after
/// going Home the Servers page still lists the last server — and a server's
/// page was only ever drawn for the selected server.
@Suite("Servers page selection")
@MainActor
struct ServersPageSelectionTests {

    private let guildID = GuildID(rawValue: 1000)
    private let readerID = UserID(rawValue: 1)
    private let faq = ChannelID(rawValue: 2002)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds[guildID] = Guild(id: guildID, name: "The Iris Project", ownerID: readerID, features: ["COMMUNITY"])
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: ChannelID(rawValue: 2001), kind: .text, guildID: guildID, name: "general", position: 0),
                Channel(id: faq, kind: .text, guildID: guildID, name: "faq", position: 1),
            ],
            inGuild: guildID
        )
        model.channelIndex = index
        model.selectedGuildID = guildID
        // Home, as the rail's Home button leaves it.
        model.selectGuild(nil)
        return model
    }

    @Test("A server page opened from its list while Home is selected opens, in that server")
    func surfaceWhileHome() {
        let model = model()
        #expect(model.selectedGuildID == nil)
        model.openSurface(.browseChannels, inGuild: guildID)
        #expect(model.selectedGuildID == guildID)
        #expect(model.workspacePresentation.primary == .guildSurface(guildID, .browseChannels))
        #expect(model.sidebarTarget == .surface(.browseChannels))
    }

    @Test("A channel opened from that list selects its server, and keeps the channel")
    func channelWhileHome() {
        let model = model()
        model.selectChannel(faq)
        #expect(model.selectedGuildID == guildID)
        #expect(model.selectedChannelID == faq)
    }
}
