import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The line under a name in the member list — Discord's `ActivityStatus` —
/// tested through the projection the canvas reads, never the helper (§2).
@MainActor
@Suite("Member list lines")
struct MemberListLineTests {

    private let reader = UserID(rawValue: 1)
    private let player = UserID(rawValue: 2)
    private let here = GuildID(rawValue: 100)
    private let elsewhere = GuildID(rawValue: 200)
    private let general = ChannelID(rawValue: 101)
    private let lounge = ChannelID(rawValue: 102)
    private let otherLounge = ChannelID(rawValue: 201)

    /// Two servers, each with `@everyone` allowed to see and join, and the
    /// reader looking at `#general` in the first.
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = reader
        model.users[reader] = User(id: reader, username: "alex")
        model.users[player] = User(id: player, username: "rowan")
        let owner = UserID(rawValue: 9)
        model.guilds = [
            here: Guild(id: here, name: "Here", ownerID: owner),
            elsewhere: Guild(id: elsewhere, name: "Elsewhere", ownerID: owner),
        ]
        for guild in [here, elsewhere] {
            let everyone = RoleID(rawValue: guild.rawValue)
            model.roles[guild] = [
                everyone: Role(
                    id: everyone, name: "@everyone", position: 0,
                    permissions: [.viewChannel, .connect]
                ),
            ]
        }
        model.members[here] = [
            reader: Member(userID: reader, roleIDs: []),
            player: Member(userID: player, roleIDs: []),
        ]
        model.members[elsewhere] = [reader: Member(userID: reader, roleIDs: [])]
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: general, kind: .text, guildID: here, name: "general"),
                Channel(id: lounge, kind: .voice, guildID: here, name: "Lounge"),
            ],
            inGuild: here
        )
        index.replaceChannels(
            [Channel(id: otherLounge, kind: .voice, guildID: elsewhere, name: "Other")],
            inGuild: elsewhere
        )
        model.channelIndex = index
        model.selectedGuildID = here
        model.selectedChannelID = general
        model.presences[player] = Presence(userID: player, status: .online)
        return model
    }

    private func line(_ model: AppModel) -> ActivityStatusLine? {
        model.rosterSections
            .lazy
            .compactMap { $0.members.first { $0.userID == self.player } }
            .first?
            .activityLine
    }

    /// **Alex's request, through the real roster**: a game and a custom status
    /// is the game's glyph, a bullet, and the status's emoji and words.
    @Test("An activity and a custom status: the glyph, then the status")
    func activityAndStatus() {
        let model = model()
        model.presences[player] = Presence(
            userID: player,
            status: .online,
            activities: PresenceActivities(list: [
                Activity(kind: .custom, name: "Custom Status", state: "brb", emoji: EmojiRef(name: "☕️")),
                Activity(kind: .playing, name: "Counter-Strike 2"),
            ])
        )
        let line = line(model)
        #expect(line?.glyph == .game)
        #expect(line?.text == nil)
        #expect(line?.statusText == "brb")
        #expect(line?.hasLead == true)
    }

    @Test("Somebody talking in a room the reader can see is 'In voice'")
    func inVoice() {
        let model = model()
        model.voiceStates[player] = VoiceState(userID: player, channelID: lounge, guildID: here)
        #expect(line(model)?.glyph == .voice)
        #expect(line(model)?.text == "In voice")
    }

    @Test("Offline is no line, whatever else is true")
    func offlineIsNoLine() {
        let model = model()
        model.presences[player] = Presence(
            userID: player,
            status: .offline,
            activities: PresenceActivities(list: [Activity(kind: .playing, name: "Counter-Strike 2")])
        )
        model.voiceStates[player] = VoiceState(userID: player, channelID: lounge, guildID: here)
        #expect(line(model) == nil)
    }

    /// **Why the key carries facts rather than `voiceRevision`**: a call in
    /// another server must not rebuild a roster of five hundred.
    @Test("A call in another server does not rebuild the list")
    func otherServersCallsKeepTheMemo() {
        let model = model()
        let before = model.rosterSections
        model.voiceStates[UserID(rawValue: 50)] = VoiceState(
            userID: UserID(rawValue: 50), channelID: otherLounge, guildID: elsewhere
        )
        model.voiceRevision &+= 1
        let after = model.rosterSections
        // The same buffer: the memo answered and nothing was rebuilt.
        #expect(before.withUnsafeBufferPointer(\.baseAddress)
            == after.withUnsafeBufferPointer(\.baseAddress))

        model.voiceStates[player] = VoiceState(userID: player, channelID: lounge, guildID: here)
        #expect(line(model)?.text == "In voice")
    }
}
