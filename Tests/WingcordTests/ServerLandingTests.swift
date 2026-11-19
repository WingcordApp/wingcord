import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Where a server opens, and where it moves when the open channel can't be
/// seen any more (docs/BETA3.md §7: R5, R6 and the landing rule).
@MainActor
@Suite("Server landing")
struct ServerLandingTests {
    private let guildID = GuildID(rawValue: 1_000)
    private let readerID = UserID(rawValue: 42)
    private let lounge = ChannelID(rawValue: 2_001)
    private let welcome = ChannelID(rawValue: 2_002)
    private let hidden = ChannelID(rawValue: 2_003)

    /// A voice room at the top, a text channel the reader can see, and one
    /// hidden from `@everyone` — the shape of a server just joined again.
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds[guildID] = Guild(id: guildID, name: "Somewhere", ownerID: UserID(rawValue: 99))
        let everyone = RoleID(rawValue: guildID.rawValue)
        model.roles[guildID] = [
            everyone: Role(id: everyone, name: "@everyone", permissions: [.viewChannel, .readMessageHistory, .sendMessages])
        ]
        model.members[guildID] = [
            readerID: Member(userID: readerID, roleIDs: [], joinedAt: .distantPast, isPending: false)
        ]
        let denied = PermissionOverwrite(id: guildID.rawValue, subject: .role, allow: [], deny: [.viewChannel])
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: lounge, kind: .voice, guildID: guildID, name: "Lounge", position: 0),
                Channel(id: welcome, kind: .text, guildID: guildID, name: "welcome", position: 1),
                Channel(id: hidden, kind: .text, guildID: guildID, name: "___hidden___", position: 2, overwrites: [denied]),
            ],
            inGuild: guildID
        )
        model.channelIndex = index
        return model
    }

    /// Discord's `getDefaultChannel`: selectable channels only, voice when
    /// asked for — and nothing asks.
    @Test("A server opens on its first text channel, never a voice room")
    func landsOnText() {
        let model = model()
        #expect(model.firstReadableChannel(inGuild: guildID) == welcome)
        model.selectGuild(guildID)
        #expect(model.selectedChannelID == welcome)
    }

    @Test("A remembered channel that can't be seen any more gives way")
    func rememberedButHidden() {
        let model = model()
        model.lastChannelByGuild[guildID] = hidden
        model.selectGuild(guildID)
        #expect(model.selectedChannelID == welcome)
    }

    /// His image 242 (2026-11-19): rejoined, and left on the old channel,
    /// now `___hidden___`, under "Messages did not load".
    @Test("The open channel moves off one that became hidden")
    func movesOffHidden() {
        let model = model()
        model.selectedGuildID = guildID
        model.selectedChannelID = hidden
        model.moveOffHiddenChannel(inGuild: guildID)
        #expect(model.selectedChannelID == welcome)
    }

    @Test("Follows the reader can't see don't narrow the list to nothing")
    func hiddenFollowsDontFilter() {
        let model = model()
        model.guildUserSettings[guildID] = GuildUserSettings(
            guildID: guildID, flags: GuildUserSettingsFlags.optInChannelsOn
        )
        model.followedChannelIDs = [hidden]
        #expect(!model.hidesUnfollowedChannels(inGuild: guildID))
        model.followedChannelIDs = [hidden, welcome]
        #expect(model.hidesUnfollowedChannels(inGuild: guildID))
    }
}
