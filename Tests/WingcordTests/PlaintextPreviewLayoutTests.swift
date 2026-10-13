import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// A text file in a message: Discord's preview takes the place of its file
/// card once the card has measured, and gives it back when the file cannot be
/// had.
@MainActor
struct PlaintextPreviewLayoutTests {

    private func attachment(_ name: String, id: UInt64 = 1, type: String? = "text/plain; charset=utf-8") -> WingcordCore.Attachment {
        WingcordCore.Attachment(
            id: AttachmentID(rawValue: id),
            filename: name,
            url: "https://cdn.discordapp.com/attachments/1/2/\(name)?ex=6abcc102&is=6abb6f82&hm=2ba6",
            proxyURL: "https://media.discordapp.net/attachments/1/2/\(name)?ex=6abcc102&is=6abb6f82&hm=2ba6",
            contentType: type,
            size: 14_072
        )
    }

    private func laidOut(_ attachments: [WingcordCore.Attachment], sizes: [HostedCardKey: CGSize]) -> MessageRow? {
        let items: [TimelineItem] = [.message(TimelineMessage(
            message: Message(
                id: MessageID(rawValue: 1),
                channelID: ChannelID(rawValue: 1),
                authorID: UserID(rawValue: 1),
                content: "",
                payload: MessagePayload(attachments: attachments)
            ),
            flags: [.head, .tail]
        ))]
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: items,
                width: 700,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable,
                hostedCardSizes: sizes.mapValues { size in
                    var measure = HostedCardMeasure()
                    _ = measure.note(size)
                    return measure
                }
            ),
            cache: &cache
        )
        guard let first = laid.first, case .message(let row) = first.kind else { return nil }
        return row
    }

    @Test("Until the preview has measured, the file is a file card")
    func unmeasured() throws {
        let row = try #require(laidOut([attachment("notes.txt")], sizes: [:]))
        #expect(row.attachments.map(\.kind) == [.file])
        #expect(row.hostedCards.isEmpty)
    }

    @Test("A measured preview keeps its slot's place and the hosted card sits on it")
    func measured() throws {
        let file = attachment("notes.txt")
        let key = HostedCardKey.plaintext(PlaintextCardKey(file))
        let row = try #require(laidOut([file], sizes: [key: CGSize(width: 432, height: 185)]))
        #expect(row.attachments.map(\.kind) == [.textPreview])
        #expect(row.hostedCards.map(\.key) == [key])
        #expect(row.hostedCards.first?.rect == row.attachments.first?.rect)
        #expect(row.attachments.first?.rect.height == 185)
    }

    /// The canvas finds an attachment by its slot's place, so a preview keeps
    /// one and the file after it is still the second.
    @Test("A preview keeps the attachments' order for the files after it")
    func order() throws {
        let text = attachment("notes.txt", id: 1)
        let zip = attachment("archive.zip", id: 2, type: "application/zip")
        let key = HostedCardKey.plaintext(PlaintextCardKey(text))
        let row = try #require(laidOut([text, zip], sizes: [key: CGSize(width: 432, height: 185)]))
        #expect(row.attachments.map(\.kind) == [.textPreview, .file])
        #expect(row.attachments.map(\.filename) == ["notes.txt", "archive.zip"])
    }

    @Test("Only a name Discord previews, case and all, carries a card")
    func gate() {
        func message(_ name: String) -> Message {
            Message(
                id: MessageID(rawValue: 1),
                channelID: ChannelID(rawValue: 1),
                authorID: UserID(rawValue: 1),
                content: "",
                payload: MessagePayload(attachments: [attachment(name)])
            )
        }
        #expect(TimelineLayoutEngine.carriesCards(message("notes.txt")))
        #expect(!TimelineLayoutEngine.carriesCards(message("notes.TXT")))
        #expect(!TimelineLayoutEngine.carriesCards(message("archive.zip")))
    }

    /// Folded, the text area is Discord's 126 whatever the file says, and the
    /// footer's row is fixed — so the card measured before anything is
    /// fetched is the card that draws: 126, the hairline, 34 and 12 above and
    /// below it.
    @Test("A preview measures the same before its file arrives")
    func measuresFolded() {
        let model = AppModel()
        let key = PlaintextCardKey(attachment("notes.txt"))
        let size = HostedCardHosts.measure(.plaintext(key), model: model)
        // Typed: inside `#expect` the sum does not take the left side's type.
        let folded: CGFloat = 126 + 1 + 34 + 24
        #expect(size.height == folded)
        #expect(size.width == Metrics.embedMaxWidth)
    }

    /// Discord's `hadError`: what cannot be fetched draws as a file card.
    @Test("A file that cannot be fetched gives its place back to the file card")
    func failure() async {
        let model = AppModel()
        var file = attachment("notes.txt")
        file.url = "file:///nonexistent/notes.txt"
        let key = PlaintextCardKey(file)
        model.noteHostedCardSize(CGSize(width: 432, height: 185), for: .plaintext(key))
        let before = model.cardRevision
        await model.loadPlaintextPreview(key)
        #expect(model.plaintextPreview(key).contents == .failed)
        #expect(model.hostedCardSizes[.plaintext(key)] == nil)
        #expect(model.cardRevision != before)
    }
}
