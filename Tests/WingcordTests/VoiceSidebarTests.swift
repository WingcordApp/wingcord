import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// What a voice channel's row is handed.
///
/// **The defect underneath these was one absent event, and no test could have
/// seen it** — the store was correct, the projection was correct, and the table
/// they both read was empty because `READY_SUPPLEMENTAL` was never decoded. What
/// *is* worth pinning is the projection above that table: who ends up in a row,
/// what is resolved onto them, and the two rules that are invisible in a
/// rendered list — a limit of zero is no limit, and an over-full room is still
/// full.
@Suite("The voice channel's row")
@MainActor
struct VoiceSidebarTests {

    private let guildID = GuildID(rawValue: 1000)
    private let readerID = UserID(rawValue: 1)
    private let voiceID = ChannelID(rawValue: 2002)
    private let applicationID = ApplicationID(rawValue: 1158877933042143272)

    /// The reader owns the fixture server, which is the shortest way past
    /// `PermissionGate` — it fails closed on every unknown, and a store with no
    /// account resolves every channel to invisible.
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds[guildID] = Guild(id: guildID, name: "The Iris Project", ownerID: readerID)
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: ChannelID(rawValue: 2001), kind: .text, guildID: guildID, name: "general", position: 0),
                Channel(
                    id: voiceID, kind: .voice, guildID: guildID, name: "Team 683",
                    position: 1, userLimit: 5
                ),
            ],
            inGuild: guildID
        )
        model.channelIndex = index
        model.selectedGuildID = guildID
        return model
    }

    private func join(_ model: AppModel, _ userID: UserID, streaming: Bool = false) {
        model.users[userID] = User(id: userID, username: "person\(userID.rawValue)")
        model.voiceStates[userID] = VoiceState(
            userID: userID,
            channelID: voiceID,
            guildID: guildID,
            sessionID: "s",
            isStreaming: streaming
        )
    }

    /// The row the sidebar actually builds, not a helper beside it — a projection
    /// tested through its own helper is a projection nothing has checked.
    private func voiceRow(_ model: AppModel) -> SidebarChannel? {
        for row in model.sidebarPresentation.rows {
            if case .channel(let channel) = row, channel.id == voiceID { return channel }
        }
        return nil
    }

    @Test("Everybody in the room reaches the row, in join order")
    func peopleReachTheRow() throws {
        let model = model()
        join(model, UserID(rawValue: 30))
        join(model, UserID(rawValue: 20))
        let row = try #require(voiceRow(model))
        // Ordered by id, which is join time — sorting by name reshuffles the
        // strip whenever somebody is renamed.
        #expect(row.voiceMembers.map(\.id) == [UserID(rawValue: 20), UserID(rawValue: 30)])
    }

    /// **The guard that stops the lookup for text channels is a performance
    /// rule, and a performance rule nothing checks is a rule that gets removed.**
    @Test("A text channel is handed no voice fields at all")
    func textChannelsPayNothing() throws {
        let model = model()
        join(model, UserID(rawValue: 20))
        var text: SidebarChannel?
        for row in model.sidebarPresentation.rows {
            if case .channel(let channel) = row, channel.kind == .text { text = channel }
        }
        let row = try #require(text)
        #expect(row.voiceMembers.isEmpty)
        #expect(row.voiceLimit == 0)
        #expect(row.voiceStatus.isEmpty)
    }

    @Test("A room's label and its clock reach the row, split into runs")
    func labelAndClock() throws {
        let model = model()
        let started = Date.now.addingTimeInterval(-60)
        model.voiceChannelInfo[voiceID] = VoiceChannelInfo(
            status: "<:eu:9> comp", sessionStartedAt: started
        )
        let row = try #require(voiceRow(model))
        #expect(row.voiceStatus == [
            .emoji(EmojiRef(id: EmojiID(rawValue: 9), name: "eu")),
            .text(" comp"),
        ])
        #expect(row.voiceStartedAt == started)
        #expect(row.voiceLimit == 5)
    }

    /// Nil and zero both mean "no ceiling" on the wire, and the row draws no
    /// counter for either — `03 / 00` is not a fact about anything.
    @Test("A channel with no limit reports zero rather than a limit of nothing")
    func noLimit() throws {
        let model = model()
        var channel = try #require(model.channelIndex[voiceID])
        channel.userLimit = nil
        model.channelIndex.upsert(channel)
        #expect(voiceRow(model)?.voiceLimit == 0)
    }

    /// A moderator can move somebody into a full room and a limit can be lowered
    /// under the people already in it — Discord's own list draws `06 / 05`. A
    /// fullness test written as `==` calls that room joinable.
    @Test("A room over its limit is still full")
    func overFull() throws {
        let model = model()
        for id in 20..<26 { join(model, UserID(rawValue: UInt64(id))) }
        let row = try #require(voiceRow(model))
        #expect(row.voiceMembers.count == 6)
        #expect(row.voiceMembers.count >= row.voiceLimit)
    }

    @Test("What somebody is playing and the status they set are resolved onto the chip")
    func presenceReachesTheChip() throws {
        let model = model()
        let userID = UserID(rawValue: 20)
        join(model, userID)
        model.presences[userID] = Presence(
            userID: userID,
            status: .online,
            activities: PresenceActivities(list: [
                Activity(kind: .custom, name: "Custom Status", state: "afk soon",
                         emoji: EmojiRef(id: EmojiID(rawValue: 77), name: "sleep")),
                Activity(kind: .playing, name: "Counter-Strike 2", applicationID: applicationID),
            ])
        )
        model.activityDirectory.apps[applicationID] = ActivityApp(
            id: applicationID, name: "Counter-Strike 2", iconHash: "abc"
        )
        let chip = try #require(voiceRow(model)?.voiceMembers.first)
        // A custom status is `state`; its `name` is the literal "Custom Status".
        #expect(chip.statusText == "afk soon")
        #expect(chip.statusEmoji?.id == EmojiID(rawValue: 77))
        #expect(chip.gameName == "Counter-Strike 2")
        #expect(chip.gameIconURL != nil)
    }

    /// An application nothing has resolved has no mark, and the row ends in
    /// nothing rather than in a placeholder — a grey square after every name
    /// says less than an empty trailing edge.
    @Test("An unresolved application leaves the row with no mark")
    func unresolvedApplicationDrawsNothing() throws {
        let model = model()
        let userID = UserID(rawValue: 20)
        join(model, userID)
        model.presences[userID] = Presence(
            userID: userID,
            status: .online,
            activities: PresenceActivities(list: [
                Activity(kind: .playing, name: "Something", applicationID: applicationID),
            ])
        )
        let chip = try #require(voiceRow(model)?.voiceMembers.first)
        #expect(chip.gameName == "Something")
        #expect(chip.gameIconURL == nil)
        #expect(!chip.hasAccessories)
    }

    /// **The key is built by the viewer**, because nothing dispatches a stream
    /// event to somebody who is not already watching. A guild share and a
    /// private call take different grammars, and this is the one that has a
    /// guild in it.
    @Test("A share carries the address of its stream")
    func streamKey() throws {
        let model = model()
        let userID = UserID(rawValue: 20)
        join(model, userID, streaming: true)
        let chip = try #require(voiceRow(model)?.voiceMembers.first)
        #expect(chip.isStreaming)
        #expect(chip.streamKey == "guild:1000:2002:20")
        #expect(chip.hasAccessories)
    }

    /// **Our own microphone is the engine's, not the server's.** The wire lags a
    /// mute by a round trip, and a row that takes half a second to cross out its
    /// own microphone reads as the button not having worked.
    @Test("The reader's own row answers to the engine rather than to the wire")
    func ownSwitchesAreLocal() throws {
        let model = model()
        join(model, readerID)
        model.isSelfMuted = true
        model.isSelfDeafened = true
        let chip = try #require(voiceRow(model)?.voiceMembers.first)
        #expect(chip.isMuted)
        #expect(chip.isDeafened)
    }
}
