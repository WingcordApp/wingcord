import Foundation
import Testing
import WingcordCore
import WingcordNet
@testable import Wingcord

/// The composer's `+`: which rows a conversation offers, what the ones that
/// are not a file panel do, and how a poll and a scheduled send go out.
@Suite("Composer menu")
@MainActor
struct ComposerMenuTests {

    private let readerID = UserID(rawValue: 1)
    private let ownerID = UserID(rawValue: 2)
    private let guildID = GuildID(rawValue: 100)
    /// `@everyone` may talk here and nothing more.
    private let talk = ChannelID(rawValue: 1001)
    /// A conversation, which has no permissions to withhold.
    private let dm = ChannelID(rawValue: 3001)

    private func model(everyone: Permissions = [.viewChannel, .sendMessages, .readMessageHistory]) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds = [guildID: Guild(id: guildID, name: "Server", ownerID: ownerID)]
        let role = RoleID(rawValue: guildID.rawValue)
        model.roles[guildID] = [role: Role(id: role, name: "@everyone", position: 0, permissions: everyone)]
        model.members[guildID] = [readerID: Member(userID: readerID, roleIDs: [])]
        var index = ChannelIndex()
        index.replaceChannels([Channel(id: talk, kind: .text, guildID: guildID, name: "general")], inGuild: guildID)
        index.replacePrivateChannels([
            Channel(id: dm, kind: .directMessage, name: "", recipientIDs: [ownerID]),
        ])
        model.channelIndex = index
        return model
    }

    // MARK: Who gets which row

    @Test("Polls need SEND_POLLS in a server and nothing in a conversation")
    func pollGate() {
        let plain = model()
        #expect(!plain.canPostPolls(in: talk))
        #expect(plain.canPostPolls(in: dm))
        #expect(model(everyone: [.viewChannel, .sendMessages, .sendPolls]).canPostPolls(in: talk))
        // The bit alone is not posting.
        #expect(!model(everyone: [.viewChannel, .sendPolls]).canPostPolls(in: talk))
    }

    @Test("Schedule Message waits for the account's scheduled list to answer")
    func scheduleGate() {
        let model = model()
        #expect(!model.canScheduleMessages(in: talk))
        model.inbox.scheduled = []
        #expect(model.canScheduleMessages(in: talk))
        #expect(model.canScheduleMessages(in: dm))
    }

    @Test("Use Apps makes the field a slash, whatever was typed")
    func useApps() {
        let model = model()
        model.mutateBox(talk) { $0.draft = "half a thought" }
        model.useApps(in: talk)
        #expect(model.messages(in: talk)?.draft == "/")
    }

    // MARK: Polls

    @Test("A poll is drawn at once, numbered from one and on its way")
    func pollEcho() throws {
        let model = model()
        var draft = PollDraft(question: "Lunch?", duration: .oneHour)
        draft.answers = [PollDraft.Answer(text: "Pizza"), PollDraft.Answer(text: "")]
        let id = MessageID(rawValue: 20 << 22)
        let echo = model.echo(of: .init(content: "", poll: draft), id: id, in: dm, author: readerID)
        let poll = try #require(echo.poll)
        #expect(poll.question == "Lunch?")
        #expect(poll.answers.map(\.id) == [1])
        #expect(poll.expiresAt == id.timestamp.addingTimeInterval(3600))
        #expect(SessionController.isSendable("", stickerIDs: [], attachments: [], poll: draft))
    }

    // MARK: Scheduling

    @Test("Escape's step and the bar's cross both leave scheduling")
    func leavingSchedule() {
        let model = model()
        let date = Date.now.addingTimeInterval(3600)
        model.setSchedule(date, in: talk)
        #expect(model.messages(in: talk)?.scheduledAt == date)
        model.setSchedule(nil, in: talk)
        #expect(model.messages(in: talk)?.scheduledAt == nil)
    }

    @Test("A full queue is Discord's limit sentence; anything else says it failed")
    func refusals() {
        let full = DiscordREST.Failure.api(status: 400, code: 640_003, message: "Too many")
        #expect(SessionController.schedulingFailure(full, hasNitro: false)
            == "Scheduled message limit reached. Get Nitro for 25 scheduled messages.")
        #expect(SessionController.schedulingFailure(full, hasNitro: true)
            == "You've reached the limit of 25 scheduled messages. Cancel one to schedule another.")
        #expect(SessionController.schedulingFailure(DiscordREST.Failure.transport("offline"), hasNitro: false)
            == "Failed to schedule message. offline")
    }
}
