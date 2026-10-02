import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Message requests through the store: out of the conversation list, onto a
/// page of their own, read beside it with the media held back.
@Suite("Message requests")
@MainActor
struct MessageRequestsPageTests {

    private let readerID = UserID(rawValue: 1)
    private let friend = ChannelID(rawValue: 3001)
    private let request = ChannelID(rawValue: 3002)
    private let spam = ChannelID(rawValue: 3003)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.users = [
            UserID(rawValue: 2): User(id: UserID(rawValue: 2), username: "friend"),
            UserID(rawValue: 3): User(id: UserID(rawValue: 3), username: "glassmage", displayName: "Glassmage"),
            UserID(rawValue: 4): User(id: UserID(rawValue: 4), username: "spammer"),
        ]
        var index = ChannelIndex()
        index.replacePrivateChannels([
            Channel(id: friend, kind: .directMessage, lastMessageID: MessageID(rawValue: 10 << 22), recipientIDs: [UserID(rawValue: 2)]),
            Channel(
                id: request, kind: .directMessage, lastMessageID: MessageID(rawValue: 30 << 22),
                recipientIDs: [UserID(rawValue: 3)], messageRequest: .pending
            ),
            Channel(
                id: spam, kind: .directMessage, lastMessageID: MessageID(rawValue: 20 << 22),
                recipientIDs: [UserID(rawValue: 4)], messageRequest: .spam
            ),
        ])
        model.channelIndex = index
        return model
    }

    private func channelRows(_ presentation: SidebarPresentation) -> [ChannelID] {
        presentation.rows.compactMap { if case .channel(let channel) = $0 { channel.id } else { nil } }
    }

    // MARK: The list

    @Test("Requests are not conversations; one row stands for them, counting the pending")
    func sidebar() {
        let presentation = model().sidebarPresentation
        #expect(channelRows(presentation) == [friend])
        #expect(presentation.rows.first == .messageRequests(pending: 1))
    }

    @Test("With nothing waiting there is no row at all")
    func noRow() {
        let model = model()
        var index = model.channelIndex
        index.remove(request)
        index.remove(spam)
        model.channelIndex = index
        #expect(model.sidebarPresentation.rows.allSatisfy {
            if case .messageRequests = $0 { false } else { true }
        })
    }

    // MARK: The page

    @Test("The row opens the page, a request opens beside it, and a conversation closes both")
    func navigation() {
        let model = model()
        model.openMessageRequests()
        #expect(model.sidebarTarget == .messageRequests)
        #expect(model.workspacePresentation == WorkspacePresentation(primary: .messageRequests, supplementary: nil))

        model.previewMessageRequest(request)
        #expect(model.workspacePresentation.supplementary == .messageRequestPreview(request))

        model.selectChannel(friend)
        #expect(!model.isMessageRequestsShown)
        #expect(model.previewedChannelID == nil)
    }

    @Test("Switching lists closes the request being read")
    func switchingTabs() {
        let model = model()
        model.openMessageRequests()
        model.previewMessageRequest(request)
        model.messageRequestsTab = .spam
        #expect(model.previewedChannelID == nil)
    }

    @Test("A request accepted somewhere else leaves the page's column")
    func acceptedElsewhere() {
        let model = model()
        model.openMessageRequests()
        model.previewMessageRequest(request)
        model.channelIndex.upsert(Channel(
            id: request, kind: .directMessage, lastMessageID: MessageID(rawValue: 30 << 22),
            recipientIDs: [UserID(rawValue: 3)]
        ))
        #expect(model.workspacePresentation.supplementary == nil)
        #expect(model.messageRequestRows(.requests).isEmpty)
    }

    @Test("Each list holds its own, named for the sender; the servers in common wait for the profile")
    func rows() {
        let model = model()
        let requests = model.messageRequestRows(.requests)
        #expect(requests.map(\.id) == [request])
        #expect(requests.first?.name == "Glassmage")
        #expect(requests.first?.mutualServers == nil)
        #expect(model.messageRequestRows(.spam).map(\.id) == [spam])
        #expect(model.pendingMessageRequestCount == 1)
        #expect(model.spamRequestCount == 1)
    }

    // MARK: The preview

    @Test("A request's transcript draws the words and counts the media in their place")
    func hiddenMedia() throws {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let picture = WingcordCore.Attachment(
            id: AttachmentID(rawValue: 1),
            filename: "1.jpg",
            url: "https://cdn.discordapp.com/attachments/1/2/1.jpg",
            proxyURL: "https://media.discordapp.net/attachments/1/2/1.jpg",
            contentType: "image/jpeg"
        )
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: request,
            authorID: UserID(rawValue: 3),
            content: "bro",
            payload: MessagePayload(attachments: [picture, picture])
        )
        func layout(hidesMedia: Bool) -> MessageRow? {
            var input = TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: 520,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "",
                authors: [:],
                calendar: .current,
                settings: PresentationRevision.shared.timeline
            )
            input.hidesMedia = hidesMedia
            let rows = TimelineLayoutEngine(presentationRevision: 1).layout(input, cache: &cache)
            guard case .message(let row)? = rows.first?.kind else { return nil }
            return row
        }
        let hidden = try #require(layout(hidesMedia: true))
        #expect(hidden.attachments.isEmpty)
        #expect(hidden.hiddenMedia?.tiles.count == 2)
        #expect(hidden.textBlock != nil)

        // Accepted: the same message, the cache notwithstanding, is whole again.
        let whole = try #require(layout(hidesMedia: false))
        #expect(whole.attachments.count == 2)
        #expect(whole.hiddenMedia == nil)
    }
}
