import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Another Fake Nitro user's animated sticker arrives as an upload named
/// `<sticker id>.gif`; where the reader's servers know the sticker it is drawn
/// as the sticker, through the engine the transcript calls.
@MainActor
@Suite("Fake Nitro GIF stickers")
struct FakeNitroGIFStickerTests {
    private static let author = UserID(rawValue: 2)
    private static let spin = StickerRef(id: 749_054_660_769_218_631, name: "spin", format: .apng)

    private func upload(_ name: String, id: UInt64 = 1) -> WingcordCore.Attachment {
        let url = "https://cdn.discordapp.com/attachments/9/\(id)/\(name)"
        return WingcordCore.Attachment(
            id: AttachmentID(rawValue: id), filename: name, url: url, proxyURL: url,
            contentType: "image/gif", width: 160, height: 160
        )
    }

    private func row(_ attachments: [WingcordCore.Attachment], known: [UInt64: StickerRef]) throws -> MessageRow {
        let message = Message(
            id: MessageID(rawValue: 1), channelID: ChannelID(rawValue: 9), authorID: Self.author,
            content: "", payload: MessagePayload(attachments: attachments)
        )
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let rows = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: TimelineReducer.rows(messages: [message]),
                width: 800,
                style: MessageTextStyle.current(),
                mentions: MentionContext(selfIDs: []),
                channelName: "general",
                authors: [Self.author: .init(
                    name: "Alder", colorValue: nil, avatarURL: nil, monogram: "A", decorationURL: nil, isBot: false
                )],
                calendar: .current,
                settings: .comfortable,
                fakeGIFStickers: known
            ),
            cache: &cache
        )
        return try #require(rows.lazy.compactMap { row -> MessageRow? in
            if case .message(let message) = row.kind { message } else { nil }
        }.first)
    }

    @Test("A GIF upload named for a known sticker is drawn as the sticker")
    func drawnAsSticker() throws {
        let laid = try row([upload("\(Self.spin.id).gif")], known: [Self.spin.id: Self.spin])
        #expect(laid.stickers.map(\.sticker) == [Self.spin])
        #expect(laid.attachments.isEmpty)
    }

    @Test("Unknown, it stays the GIF it is")
    func unknownStaysAttachment() throws {
        let laid = try row([upload("\(Self.spin.id).gif")], known: [:])
        #expect(laid.stickers.isEmpty)
        #expect(laid.attachments.count == 1)
    }

    /// The lightbox counts a message's attachments by position.
    @Test("Beside another file, every attachment stays one")
    func mixedStaysAttachments() throws {
        let laid = try row(
            [upload("\(Self.spin.id).gif"), upload("party.gif", id: 2)],
            known: [Self.spin.id: Self.spin]
        )
        #expect(laid.stickers.isEmpty)
        #expect(laid.attachments.count == 2)
    }
}
