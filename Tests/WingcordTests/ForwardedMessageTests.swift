import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A forwarded message is first-class content (BETA2.md D6): its words select
/// and copy, its pictures are asked for, its breadcrumb goes to the original.
@MainActor
struct ForwardedMessageTests {
    private var style: MessageTextStyle { MessageTextStyle.current() }
    private let guildID = GuildID(rawValue: 900)
    private let sourceChannelID = ChannelID(rawValue: 901)

    private func row(_ message: Message, mentions: MentionContext = MentionContext()) -> MessageRow? {
        guard case .message(let row) = timelineRow(message, mentions: mentions)?.kind else { return nil }
        return row
    }

    private func timelineRow(_ message: Message, mentions: MentionContext = MentionContext()) -> TimelineRow? {
        let engine = TimelineLayoutEngine(presentationRevision: 0)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = engine.layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: 520,
                style: style,
                mentions: mentions,
                channelName: "general",
                authors: [
                    UserID(rawValue: 7): TimelineLayoutEngine.AuthorInfo(
                        name: "alex", colorValue: nil, avatarURL: nil,
                        monogram: "A", decorationURL: nil, isBot: false
                    )
                ],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )
        return laid.first
    }

    private func forward(note: String = "", _ snapshot: ForwardedMessage) -> Message {
        Message(
            id: MessageID(rawValue: 5 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 7),
            content: note,
            payload: MessagePayload(forwarded: snapshot)
        )
    }

    private var mentions: MentionContext {
        var context = MentionContext()
        context.currentGuildID = guildID
        context.channels[sourceChannelID] = LinkChannel(
            name: "releases", guildID: guildID, kind: .text, canView: true, isPost: false, parentID: nil
        )
        context.guildNames[GuildID(rawValue: 950)] = "Another Server"
        return context
    }

    /// "I can't even select or copy text from them": the quote's words were
    /// drawn by the quote and nothing else could reach them.
    @Test("A forward with no note of its own hands its words to the row")
    func wordsAreTheRowsText() throws {
        let row = try #require(row(forward(ForwardedMessage(content: "Release notes are up"))))
        let block = try #require(row.textBlock)
        #expect(block.text.attributed.string == "Release notes are up")
        let slot = try #require(row.forwarded)
        #expect(slot.bodyIsRowText)
        #expect(row.textOrigin == slot.bodyOrigin)
    }

    @Test("Beside a note, the row's text stays the note")
    func noteKeepsTheRowsText() throws {
        let row = try #require(row(forward(note: "this one", ForwardedMessage(content: "the original"))))
        #expect(row.textBlock?.text.attributed.string.hasPrefix("this one") == true)
        #expect(row.forwarded?.bodyIsRowText == false)
    }

    /// "Media from forwarded messages doesn't even load": nothing asked for it.
    @Test("A forward's pictures are asked for")
    func picturesAreRequested() throws {
        let picture = Attachment(
            id: AttachmentID(rawValue: 77),
            filename: "photo.png",
            url: "https://cdn.discordapp.com/attachments/1/2/photo.png",
            proxyURL: "https://media.discordapp.net/attachments/1/2/photo.png",
            contentType: "image/png",
            size: 1_000,
            width: 800,
            height: 600
        )
        let row = try #require(row(forward(ForwardedMessage(content: "", attachments: [picture]))))
        let requests = TimelineImageRequests.requests(for: [row], scale: 2, loadsArtwork: true)
        let asked = requests.map { (request: TimelineImageRequests.Request) in request.key.url.lastPathComponent }
        #expect(asked.contains { $0.hasPrefix("photo") })
    }

    @Test("A forward from this server names its channel and jumps to it")
    func breadcrumbInThisServer() throws {
        let original = MessageID(rawValue: 3 << 22)
        let snapshot = ForwardedMessage(
            content: "hi", channelID: sourceChannelID, guildID: guildID, messageID: original,
            timestamp: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let row = try #require(row(forward(snapshot), mentions: mentions))
        let slot = try #require(row.forwarded)
        let footer = try #require(slot.footer)
        #expect(footer.text.attributed.string.hasPrefix("#releases"))
        #expect(slot.jump == ForwardJump(guildID: guildID, channelID: sourceChannelID, messageID: original))
        #expect(slot.footerRect.width > 0)
        #expect(slot.footerIconURL == nil)
    }

    @Test("A forward from another server names the server")
    func breadcrumbFromAnotherServer() throws {
        let snapshot = ForwardedMessage(
            content: "hi", channelID: ChannelID(rawValue: 951), guildID: GuildID(rawValue: 950),
            messageID: MessageID(rawValue: 4 << 22)
        )
        let row = try #require(row(forward(snapshot), mentions: mentions))
        let footer = try #require(row.forwarded?.footer)
        #expect(footer.text.attributed.string.hasPrefix("Another Server"))
    }

    /// Discord draws no breadcrumb for an original in a conversation, and
    /// inventing a place is a claim the client cannot make.
    @Test("A forward from a conversation has no breadcrumb")
    func noBreadcrumbFromAConversation() throws {
        let snapshot = ForwardedMessage(
            content: "hi", channelID: ChannelID(rawValue: 4_000), guildID: nil,
            messageID: MessageID(rawValue: 4 << 22)
        )
        let row = try #require(row(forward(snapshot), mentions: mentions))
        #expect(row.forwarded?.footer == nil)
        #expect(row.forwarded?.jump == nil)
    }

    @Test("A forward's stickers are laid out")
    func stickersAreLaidOut() throws {
        let snapshot = ForwardedMessage(
            content: "", stickers: [StickerRef(id: 749_054_660_769_218_631, name: "Wave", format: .png)]
        )
        let row = try #require(row(forward(snapshot)))
        #expect(row.forwarded?.stickers.count == 1)
    }

    /// The snapshot's fields after the first three are new: a forward written
    /// to the message cache before them still reads back.
    @Test("A forward cached before stickers and the breadcrumb still decodes")
    func oldCacheDecodes() throws {
        let json = #"{"content":"old","attachments":[],"embeds":[]}"#
        let decoded = try JSONDecoder().decode(ForwardedMessage.self, from: Data(json.utf8))
        #expect(decoded.content == "old")
        #expect(decoded.stickers.isEmpty)
        #expect(decoded.messageID == nil)
    }

    @Test("Copy Text copies what a forward forwards")
    func copyTextIsOffered() {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 7)
        var index = ChannelIndex()
        index.upsert(Channel(
            id: ChannelID(rawValue: 1), kind: .directMessage, recipientIDs: [UserID(rawValue: 8)]
        ))
        model.channelIndex = index
        let message = forward(ForwardedMessage(content: "copy me"))
        #expect(model.permissionGate.actions(for: message).contains(.copyText))
        // Without the forward's words there is nothing to copy.
        let empty = forward(ForwardedMessage(content: ""))
        #expect(!model.permissionGate.actions(for: empty).contains(.copyText))
    }

    @Test("A forward is drawn")
    func render() throws {
        let snapshot = ForwardedMessage(
            content: "**Release notes are up** — see https://example.com/nightly",
            channelID: sourceChannelID, guildID: guildID, messageID: MessageID(rawValue: 3 << 22),
            timestamp: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let row = try #require(timelineRow(forward(snapshot), mentions: mentions))
        let height = Int(row.height + 8)
        let pixels = RenderProbe.pixels(width: 520, height: height) { context, _ in
            TimelineRowPainter.draw(
                row: row,
                in: CGRect(x: 0, y: 4, width: 520, height: row.height),
                context: context,
                style: self.style,
                state: TimelineRowPainter.State(),
                images: ImageStore.shared,
                scale: 1
            )
        }
        #expect(pixels.contains { $0 > 0 })
        ANSICodeBlockTests.save(pixels, width: 520, height: height, name: "forward")
    }
}
