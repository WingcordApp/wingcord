import Foundation
import Testing
@testable import WingcordCore

/// Message requests in the channel index, their standing, Discord's compact
/// age, and what a request's preview draws of a message.
struct MessageRequestTests {

    private func conversation(
        _ id: UInt64,
        lastMessage: UInt64,
        standing: MessageRequestStanding? = nil
    ) -> Channel {
        Channel(
            id: ChannelID(rawValue: id),
            kind: .directMessage,
            lastMessageID: MessageID(rawValue: lastMessage),
            recipientIDs: [UserID(rawValue: id + 100)],
            messageRequest: standing
        )
    }

    // MARK: The index

    @Test("Requests and spam stay out of the conversation list, newest first in their own")
    func partitioned() {
        var index = ChannelIndex()
        index.replacePrivateChannels([
            conversation(1, lastMessage: 10),
            conversation(2, lastMessage: 40, standing: .pending),
            conversation(3, lastMessage: 30, standing: .spam),
            conversation(4, lastMessage: 20, standing: .pending),
        ])
        #expect(index.privateChannelIDs().map(\.rawValue) == [1])
        #expect(index.messageRequestIDs(.pending).map(\.rawValue) == [2, 4])
        #expect(index.messageRequestIDs(.spam).map(\.rawValue) == [3])
        #expect(index.allPrivateChannelIDs().map(\.rawValue) == [2, 3, 4, 1])
    }

    @Test("Accepting moves a conversation into the list, and is structural")
    func accepted() {
        var index = ChannelIndex()
        index.replacePrivateChannels([conversation(1, lastMessage: 10), conversation(2, lastMessage: 40, standing: .pending)])
        let before = index.structureRevision
        index.upsert(conversation(2, lastMessage: 40))
        #expect(index.privateChannelIDs().map(\.rawValue) == [2, 1])
        #expect(index.messageRequestIDs(.pending).isEmpty)
        #expect(index.structureRevision != before)
    }

    @Test("A new message reorders the requests too")
    func reorders() {
        var index = ChannelIndex()
        index.replacePrivateChannels([
            conversation(2, lastMessage: 40, standing: .pending),
            conversation(4, lastMessage: 20, standing: .pending),
        ])
        index.patchLastMessage(MessageID(rawValue: 50), in: ChannelID(rawValue: 4))
        #expect(index.messageRequestIDs(.pending).map(\.rawValue) == [4, 2])
    }

    @Test("A declined request leaves both lists")
    func declined() {
        var index = ChannelIndex()
        index.replacePrivateChannels([conversation(2, lastMessage: 40, standing: .pending)])
        index.remove(ChannelID(rawValue: 2))
        #expect(index.messageRequestIDs(.pending).isEmpty)
        #expect(index.allPrivateChannelIDs().isEmpty)
    }

    @Test("Spam wins over a request flag, as Discord's two stores have it")
    func standing() {
        #expect(MessageRequestStanding(isMessageRequest: true, isSpam: false) == .pending)
        #expect(MessageRequestStanding(isMessageRequest: true, isSpam: true) == .spam)
        #expect(MessageRequestStanding(isMessageRequest: false, isSpam: true) == .spam)
        #expect(MessageRequestStanding(isMessageRequest: false, isSpam: false) == nil)
    }

    // MARK: The age

    @Test("Discord's compact age, thresholds and all")
    func age() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func label(_ seconds: TimeInterval) -> String { RelativeAge.label(since: now.addingTimeInterval(-seconds), now: now) }
        #expect(label(5) == "1m ago")
        #expect(label(59 * 60) == "59m ago")
        #expect(label(3 * 3600) == "3h ago")
        #expect(label(5 * 86_400) == "5d ago")
        #expect(label(45 * 86_400) == ">30d ago")
        #expect(label(400 * 86_400) == ">1y ago")
    }

    // MARK: The preview

    @Test("A request's preview keeps the words and the reply, and counts the media")
    func restricted() {
        let attachment = Attachment(
            id: AttachmentID(rawValue: 1),
            filename: "1.jpg",
            url: "https://cdn.discordapp.com/attachments/1/1/1.jpg",
            proxyURL: "https://media.discordapp.net/attachments/1/1/1.jpg"
        )
        let reference = MessageReference(messageID: MessageID(rawValue: 5), channelID: ChannelID(rawValue: 2))
        let message = Message(
            id: MessageID(rawValue: 9),
            channelID: ChannelID(rawValue: 2),
            authorID: UserID(rawValue: 102),
            content: "bro",
            payload: MessagePayload(
                attachments: [attachment, attachment],
                embeds: [Embed(title: "A link")],
                reactions: [],
                stickers: [],
                reference: reference
            )
        )
        let (shown, hidden) = message.restrictedPreview
        #expect(hidden == 3)
        #expect(shown.content == "bro")
        #expect(shown.attachments.isEmpty)
        #expect(shown.embeds.isEmpty)
        #expect(shown.reference == reference)
    }

    @Test("A message with nothing to hide is drawn as it is")
    func nothingHidden() {
        let message = Message(id: MessageID(rawValue: 9), channelID: ChannelID(rawValue: 2), authorID: UserID(rawValue: 1), content: "hi")
        #expect(message.restrictedPreview.hiddenMedia == 0)
        #expect(message.restrictedPreview.message == message)
    }
}
