import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A conversation's row shows its newest message (REDESIGN.md R9): from its
/// transcript when one is loaded, from the preview request otherwise — and
/// never a message older than one already known.
@Suite("Conversation previews")
@MainActor
struct ConversationPreviewTests {
    private let readerID = UserID(rawValue: 1)
    private let friendID = UserID(rawValue: 2)
    private let channelID = ChannelID(rawValue: 3001)

    private func message(_ id: UInt64, _ text: String, from author: UserID) -> Message {
        Message(id: MessageID(rawValue: id << 22), channelID: channelID, authorID: author, content: text)
    }

    private func model(newest: UInt64) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.users = [friendID: User(id: friendID, username: "friend")]
        var index = ChannelIndex()
        index.replacePrivateChannels([
            Channel(id: channelID, kind: .directMessage, lastMessageID: MessageID(rawValue: newest << 22), recipientIDs: [friendID]),
        ])
        model.channelIndex = index
        return model
    }

    private func row(_ model: AppModel) -> SidebarChannel? {
        model.sidebarPresentation(for: nil).rows.lazy.compactMap {
            if case .channel(let channel) = $0 { channel } else { nil }
        }.first
    }

    @Test("A preview fills the row of a conversation nobody has opened")
    func fromPreview() throws {
        let model = model(newest: 20)
        #expect(row(model)?.preview == nil)
        model.receivePreviews([message(20, "see you **there**", from: friendID)])
        let preview = try #require(row(model)?.preview)
        #expect(preview.text == "see you there")
    }

    @Test("The reader's own words say so")
    func ownWords() throws {
        let model = model(newest: 20)
        model.receivePreviews([message(20, "on my way", from: readerID)])
        #expect(row(model)?.preview?.text == "You: on my way")
    }

    @Test("A preview older than what is known is ignored")
    func neverBackwards() {
        let model = model(newest: 30)
        model.receivePreviews([message(30, "newest", from: friendID)])
        model.receivePreviews([message(20, "older", from: friendID)])
        #expect(row(model)?.preview?.text == "newest")
    }

    @Test("A message the channel no longer names as newest is not a preview")
    func stale() {
        let model = model(newest: 40)
        model.receivePreviews([message(20, "old news", from: friendID)])
        #expect(row(model)?.preview == nil)
    }
}
