import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The plugin's check before a Fake Nitro send: links went in and the channel
/// will not embed them (Vencord's `hasBypass && !hasEmbedPerms`).
@Suite("Fake Nitro's embed check")
@MainActor
struct FakeNitroPromptTests {

    private let readerID = UserID(rawValue: 1)
    private let guildID = GuildID(rawValue: 100)
    private let talk = ChannelID(rawValue: 1001)
    private let dm = ChannelID(rawValue: 3001)

    private func model(everyone: Permissions) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds = [guildID: Guild(id: guildID, name: "Server", ownerID: UserID(rawValue: 2))]
        let role = RoleID(rawValue: guildID.rawValue)
        model.roles[guildID] = [role: Role(id: role, name: "@everyone", position: 0, permissions: everyone)]
        model.members[guildID] = [readerID: Member(userID: readerID, roleIDs: [])]
        var index = ChannelIndex()
        index.replaceChannels([Channel(id: talk, kind: .text, guildID: guildID, name: "general")], inGuild: guildID)
        index.replacePrivateChannels([Channel(id: dm, kind: .directMessage, name: "", recipientIDs: [UserID(rawValue: 2)])])
        model.channelIndex = index
        return model
    }

    @Test("A send with links asks where the channel will not embed them")
    func asksWithoutEmbeds() {
        let model = model(everyone: [.viewChannel, .sendMessages])
        #expect(model.needsFakeNitroEmbedPrompt(bypassed: true, in: talk))
        #expect(!model.needsFakeNitroEmbedPrompt(bypassed: false, in: talk))
    }

    @Test("Embed Links, or a conversation, needs no asking")
    func embedsAllowed() {
        let model = model(everyone: [.viewChannel, .sendMessages, .embedLinks])
        #expect(!model.needsFakeNitroEmbedPrompt(bypassed: true, in: talk))
        #expect(!model.needsFakeNitroEmbedPrompt(bypassed: true, in: dm))
    }
}
