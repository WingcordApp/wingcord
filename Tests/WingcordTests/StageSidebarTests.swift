import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// A stage channel is listed — under its category, with the others, as
/// Discord lists it. `ChannelKind.isConversation` does not count a stage, and
/// the list once admitted only conversations, forums and media: no stage
/// channel was ever drawn.
@MainActor
@Suite("Stage channels in the list")
struct StageSidebarTests {
    @Test("A stage channel under a category is listed beside the text channels")
    func stageIsListed() {
        let guildID = GuildID(rawValue: 1)
        let reader = UserID(rawValue: 7)
        let model = AppModel()
        model.currentUserID = reader
        model.guilds[guildID] = Guild(id: guildID, name: "g", ownerID: reader)
        let category = ChannelID(rawValue: 100)
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: category, kind: .category, guildID: guildID, name: "Text Channels", position: 0),
                Channel(id: ChannelID(rawValue: 101), kind: .text, guildID: guildID, name: "general",
                        parentID: category, position: 0),
                Channel(id: ChannelID(rawValue: 102), kind: .stage, guildID: guildID, name: "hello",
                        parentID: category, position: 1),
            ],
            inGuild: guildID
        )
        model.channelIndex = index
        model.selectedGuildID = guildID

        let listed = model.sidebarPresentation.rows.compactMap { row -> String? in
            if case .channel(let channel) = row { return channel.name }
            return nil
        }
        #expect(listed == ["general", "hello"])
    }
}
