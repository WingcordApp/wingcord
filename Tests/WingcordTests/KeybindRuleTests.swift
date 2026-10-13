import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// Discord's two keys in the composer that are not menu keys: Up edits the
/// newest message the reader may edit, and Escape ends by marking the channel
/// read (DESIGN-NOTES §10.2).
@MainActor
@Suite("Discord's composer keys")
struct KeybindRuleTests {
    private let guildID = GuildID(rawValue: 1)
    private let channelID = ChannelID(rawValue: 10)
    private let reader = UserID(rawValue: 7)

    private func model(_ messages: [Message]) -> AppModel {
        let model = AppModel()
        model.currentUserID = reader
        model.guilds[guildID] = Guild(id: guildID, name: "g", ownerID: reader)
        model.channelIndex.replaceChannels(
            [Channel(id: channelID, kind: .text, guildID: guildID, name: "general", lastMessageID: messages.last?.id)],
            inGuild: guildID
        )
        var box = MessageBox()
        box.messages = messages
        model.setMessages(box, in: channelID)
        return model
    }

    private func message(_ id: UInt64, by author: UInt64, kind: MessageKind = .default) -> Message {
        Message(
            id: MessageID(rawValue: id << 22),
            channelID: channelID,
            authorID: UserID(rawValue: author),
            content: "m\(id)",
            kind: kind
        )
    }

    /// Wingcord's Up replied to the newest message — Alex's "seems to be
    /// broken". Discord's edits the reader's own.
    @Test("Up edits the reader's newest message, past somebody else's")
    func upEdits() {
        let model = model([message(1, by: 7), message(2, by: 9)])
        #expect(model.editLatestOwnMessage(in: channelID))
        #expect(model.messages(in: channelID)?.editing?.messageID == MessageID(rawValue: 1 << 22))
    }

    /// A pin is the reader's own line and nobody can edit it.
    @Test("Up skips the reader's own system lines")
    func skipsSystemLines() {
        let model = model([message(1, by: 7), message(2, by: 7, kind: .channelPinnedMessage)])
        #expect(model.editLatestOwnMessage(in: channelID))
        #expect(model.messages(in: channelID)?.editing?.messageID == MessageID(rawValue: 1 << 22))
    }

    /// Discord recalls a newer slash command instead, which this client cannot
    /// rebuild yet — so it does nothing rather than edit something older.
    @Test("A newer slash command of the reader's leaves Up to the caret")
    func newerCommand() {
        var response = message(2, by: 99)
        response.payload = MessagePayload(
            interaction: MessageInteraction(userID: reader, name: "roll", commandType: 1)
        )
        let model = model([message(1, by: 7), response])
        #expect(!model.editLatestOwnMessage(in: channelID))
        #expect(model.messages(in: channelID)?.editing == nil)
    }

    @Test("Nothing of the reader's to edit leaves Up to the caret")
    func nothingToEdit() {
        #expect(!model([message(1, by: 9)]).editLatestOwnMessage(in: channelID))
    }

    /// Discord's Escape (module 92960): at the present, its last step marks
    /// the channel read — its Mark channel as read.
    @Test("Escape's last step marks an unread channel read")
    func escapeMarksRead() {
        let model = model([message(1, by: 9)])
        model.readStates[channelID] = ReadState()
        #expect(model.escapeTranscript(in: channelID))
        #expect(model.readStates[channelID]?.lastAcknowledgedID == MessageID(rawValue: 1 << 22))
        #expect(!model.escapeTranscript(in: channelID))
    }
}
