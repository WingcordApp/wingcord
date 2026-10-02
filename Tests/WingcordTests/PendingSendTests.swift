import Foundation
import Testing
import WingcordCore
import WingcordNet
@testable import Wingcord

/// The reader's sends between Return and Discord's answer: drawn at once, woven
/// into the transcript, retired by the answer, and refused the way Discord's
/// own client refuses them.
@Suite("Pending sends")
@MainActor
struct PendingSendTests {

    private let channel = ChannelID(rawValue: 1001)
    private let me = UserID(rawValue: 7)

    private func model() -> AppModel {
        let model = AppModel()
        var index = ChannelIndex()
        index.replaceChannels(
            [Channel(id: channel, kind: .text, guildID: GuildID(rawValue: 100), name: "general")],
            inGuild: GuildID(rawValue: 100)
        )
        model.channelIndex = index
        model.mutateBox(channel) { box in
            box.messages = [Message(id: MessageID(rawValue: 10 << 22), channelID: channel, authorID: UserID(rawValue: 2), content: "hi")]
            box.hasMoreHistory = false
        }
        return model
    }

    private func entry(_ id: UInt64, state: OutgoingMessage.State = .sending, files: [PendingAttachment] = []) -> OutgoingMessage {
        let messageID = MessageID(rawValue: id << 22)
        return OutgoingMessage(
            id: messageID,
            request: .init(content: "on my way"),
            echo: Message(
                id: messageID,
                channelID: channel,
                authorID: me,
                content: "on my way",
                payload: MessagePayload(nonce: String(messageID.rawValue))
            ),
            state: state,
            files: files
        )
    }

    private func messageRows(_ rows: [TimelineItem]) -> [TimelineMessage] {
        rows.compactMap { if case .message(let message) = $0 { message } else { nil } }
    }

    // MARK: Woven in

    @Test("A send is drawn at once, after the server's messages, and marked as on its way")
    func echoIsDrawnPending() {
        let model = model()
        model.mutateBox(channel) { $0.outbox = [entry(20)] }
        let rows = messageRows(model.timelineRows(for: channel))
        #expect(rows.map(\.message.content) == ["hi", "on my way"])
        #expect(rows.last?.flags.contains(.pending) == true)
        #expect(rows.last?.flags.contains(.failed) == false)
    }

    @Test("A send is read the moment it is made, so no \"NEW\" is drawn in front of it")
    func ownSendIsRead() {
        let model = model()
        // Everything before the send has been read.
        model.readStates[channel] = ReadState(lastAcknowledgedID: MessageID(rawValue: 10 << 22))
        let send = entry(20)
        model.mutateBox(channel) { $0.outbox = [send] }
        // The echo is newer than the cursor, which is the whole of the bug…
        #expect(model.timelineRows(for: channel).contains(.unreadDivider))
        // …and the reader's own message moves the cursor, as Discord's does.
        model.acknowledgeOwnMessage(send.id, in: channel)
        #expect(!model.timelineRows(for: channel).contains(.unreadDivider))
        #expect(model.readStates[channel]?.lastAcknowledgedID == send.id)
        // Discord's copy, a moment later and a moment newer, moves it on; an
        // older one never moves it back.
        let answer = MessageID(rawValue: 21 << 22)
        model.acknowledgeOwnMessage(answer, in: channel)
        model.acknowledgeOwnMessage(send.id, in: channel)
        #expect(model.readStates[channel]?.lastAcknowledgedID == answer)
    }

    @Test("A refusal turns the same row red, and Clyde's notice follows it")
    func refusedRowAndNotice() {
        let model = model()
        model.mutateBox(channel) {
            $0.outbox = [entry(20, state: .failed)]
            $0.notices = [Clyde.notice("Your message could not be delivered.", in: channel, id: MessageID(rawValue: 21 << 22))]
        }
        let rows = messageRows(model.timelineRows(for: channel))
        #expect(rows.map(\.message.authorID) == [UserID(rawValue: 2), me, Clyde.userID])
        #expect(rows[1].flags.contains(.failed))
        #expect(rows[1].flags.contains(.pending) == false)
        #expect(rows[2].message.isEphemeral)
    }

    @Test("Nothing local is drawn into a window cut off from the present")
    func notIntoAnOldWindow() {
        let model = model()
        model.mutateBox(channel) {
            $0.outbox = [entry(20)]
            $0.hasMoreNewer = true
        }
        #expect(messageRows(model.timelineRows(for: channel)).map(\.message.content) == ["hi"])
    }

    @Test("Local messages take their place by id among the server's")
    func wovenByID() {
        let server = [5, 9, 30].map { Message(id: MessageID(rawValue: $0), channelID: channel, authorID: me) }
        let local = [31, 7].map { Message(id: MessageID(rawValue: $0), channelID: channel, authorID: me) }
        #expect(AppModel.woven(server, with: local).map(\.id.rawValue) == [5, 7, 9, 30, 31])
        #expect(AppModel.woven(server, with: []).map(\.id.rawValue) == [5, 9, 30])
    }

    // MARK: Retired by the answer

    @Test("Discord's answer retires the echo with its nonce, and only that one")
    func answerRetiresEcho() {
        var box = MessageBox()
        box.outbox = [entry(20), entry(22)]
        let answer = Message(
            id: MessageID(rawValue: 25 << 22),
            channelID: channel,
            authorID: me,
            content: "on my way",
            payload: MessagePayload(nonce: String((20 as UInt64) << 22))
        )
        box.receiveLive(answer, trimming: false)
        #expect(box.outbox.map(\.id.rawValue) == [22 << 22])
        #expect(box.messages.map(\.id) == [answer.id])
    }

    @Test("An answer held back from a window cut off from the present still retires its echo")
    func heldAnswerRetiresEcho() {
        var box = MessageBox()
        box.hasMoreNewer = true
        box.outbox = [entry(20)]
        box.receiveLive(
            Message(id: MessageID(rawValue: 25 << 22), channelID: channel, authorID: me, payload: MessagePayload(nonce: String((20 as UInt64) << 22))),
            trimming: false
        )
        #expect(box.outbox.isEmpty)
        #expect(box.heldLive.count == 1)
    }

    // MARK: What a refused one offers

    @Test("A refused send offers Resend, its words and Delete; one on its way offers nothing")
    func refusedActions() {
        let model = model()
        model.mutateBox(channel) { $0.outbox = [entry(20, state: .failed), entry(22)] }
        #expect(model.actions(for: MessageID(rawValue: 20 << 22), in: channel) == [.resend, .copyText, .delete])
        #expect(model.actions(for: MessageID(rawValue: 22 << 22), in: channel).isEmpty)
    }

    @Test("Deleting a refused send drops it here and asks nobody")
    func deleteIsLocal() {
        let model = model()
        model.mutateBox(channel) { $0.outbox = [entry(20, state: .failed)] }
        model.requestDelete(of: MessageID(rawValue: 20 << 22), in: channel)
        #expect(model.messages(in: channel)?.outbox.isEmpty == true)
        #expect(model.deleteRequest == nil)
    }

    // MARK: Nonces

    @Test("Two nonces minted in one millisecond are two snowflakes of that millisecond")
    func noncesInOneMillisecond() {
        let moment = Date(timeIntervalSince1970: 1_790_000_000.123)
        let first = SessionController.mintNonce(at: moment)
        let second = SessionController.mintNonce(at: moment)
        #expect(first != second)
        #expect(first.rawValue >> 22 == second.rawValue >> 22)
        #expect(abs(first.timestamp.timeIntervalSince(moment)) < 0.002)
    }
}

/// What a refused send says — Discord's `_sendMessage` failure branch.
@Suite("Send refusals")
struct SendRefusalTests {

    @Test("A dropped connection, a server error and AutoMod say nothing past the red")
    func silent() {
        #expect(SendRefusal.of(DiscordREST.Failure.transport("offline")) == .silent)
        #expect(SendRefusal.of(DiscordREST.Failure.api(status: 500, code: nil, message: nil)) == .silent)
        #expect(SendRefusal.of(DiscordREST.Failure.api(status: 400, code: 200_000, message: nil)) == .silent)
    }

    @Test("Slowmode sets the wait, and is not Clyde's")
    func slowmode() {
        #expect(SendRefusal.of(DiscordREST.Failure.slowmode(retryAfter: 12)) == .slowmode(retryAfter: 12))
    }

    @Test("A person who cannot be messaged gets Discord's default sentence, with its article")
    func undeliverable() throws {
        guard case .explained(let text) = SendRefusal.of(DiscordREST.Failure.forbidden(code: 50007)) else {
            Issue.record("expected Clyde")
            return
        }
        #expect(text.hasPrefix("Your message could not be delivered.\n\nYou can see the full list of reasons here: "))
        #expect(text.hasSuffix(SendRefusal.undeliverableArticle))
    }

    @Test("No server in common asks for a friend request, except of an app")
    func noMutualServers() {
        let person = SendRefusal.of(DiscordREST.Failure.api(status: 400, code: 50278, message: nil))
        let app = SendRefusal.of(DiscordREST.Failure.api(status: 400, code: 50278, message: nil), isBotDirectMessage: true)
        guard case .explained(let personText) = person, case .explained(let appText) = app else {
            Issue.record("expected Clyde for both")
            return
        }
        #expect(personText.contains("Send a friend request first"))
        #expect(!appText.contains("friend request"))
    }

    @Test("A code nobody has named still gets the default sentence")
    func unknownCode() {
        guard case .explained(let text) = SendRefusal.of(DiscordREST.Failure.api(status: 400, code: 99_999, message: nil)) else {
            Issue.record("expected Clyde")
            return
        }
        #expect(text.hasPrefix("Your message could not be delivered."))
    }

    @Test("The thread cap is worded as posts in a forum")
    func forumCap() {
        #expect(SendRefusal.of(DiscordREST.Failure.api(status: 400, code: 160_006, message: nil), isForumLike: true)
            == .explained("Your message could not be sent because this server has reached the maximum number of posts. Free up space by archiving a post."))
    }

    @Test("A missing permission is Discord's own short sentence")
    func missingPermission() {
        #expect(SendRefusal.of(DiscordREST.Failure.forbidden(code: 50013))
            == .explained("You don't have permission to do that here."))
    }
}
