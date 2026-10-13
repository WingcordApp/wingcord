import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A file attachment's card draws its name and size **inside the card**, at
/// whatever offset its row is drawn.
///
/// The card's glyph was placed in the shifted frame and its words at the
/// slot's row-space origins, so every file card below the canvas's first row
/// was a glyph on an empty plate (Alex's image 37, 2026-10-07). The check is
/// one card drawn twice, at the top of the bitmap and a hundred points down:
/// a painter that draws in the card's own frame paints the two identically.
@MainActor
@Suite("File card rendering")
struct FileCardRenderTests {

    private var style: MessageTextStyle { MessageTextStyle.current() }

    private func row(filename: String) -> TimelineRow {
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 7),
            content: "",
            payload: MessagePayload(attachments: [
                Attachment(
                    id: AttachmentID(rawValue: 3),
                    filename: filename,
                    url: "https://cdn.discordapp.com/attachments/1/3/\(filename)",
                    proxyURL: "https://media.discordapp.net/attachments/1/3/\(filename)",
                    contentType: "application/zip",
                    size: 221_000
                )
            ])
        )
        let engine = TimelineLayoutEngine(presentationRevision: 0)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return engine.layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: 480,
                style: style,
                mentions: MentionContext(),
                channelName: "general",
                authors: [
                    UserID(rawValue: 7): TimelineLayoutEngine.AuthorInfo(
                        name: "Staff", colorValue: nil, avatarURL: nil,
                        monogram: "S", decorationURL: nil, isBot: false
                    )
                ],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )[0]
    }

    /// The card's pixels, with the row drawn `offset` points down.
    private func cardPixels(filename: String, offset: CGFloat) throws -> [UInt8] {
        let row = row(filename: filename)
        guard case .message(let message) = row.kind, let card = message.attachments.first else {
            Issue.record("expected a message row with a file card")
            return []
        }
        #expect(card.kind == .file)
        let height = Int(offset + row.height + 10)
        let pixels = RenderProbe.pixels(width: 480, height: height) { context, _ in
            TimelineRowPainter.draw(
                row: row,
                in: CGRect(x: 0, y: offset, width: 480, height: row.height),
                context: context,
                style: self.style,
                state: TimelineRowPainter.State(),
                images: ImageStore.shared,
                scale: 1
            )
        }
        // The card's own box, where the row put it, in the bitmap's rows (the
        // probe flips the context, so a row in the bitmap is a row on screen
        // counted from the top).
        let box = card.rect.offsetBy(dx: 0, dy: offset).integral
        var region: [UInt8] = []
        for y in Int(box.minY)..<min(height, Int(box.maxY)) {
            for x in Int(box.minX)..<min(480, Int(box.maxX)) {
                let index = (y * 480 + x) * 4
                region.append(contentsOf: pixels[index..<index + 4])
            }
        }
        return region
    }

    @Test("The card draws the same wherever its row is")
    func cardIsTranslationInvariant() throws {
        // At offset zero row space and canvas space coincide, so even the old
        // painter drew this card right; a hundred points down it drew the
        // glyph in the card and the words a hundred points above it.
        let atTop = try cardPixels(filename: "lecture notes.zip", offset: 0)
        let lower = try cardPixels(filename: "lecture notes.zip", offset: 100)
        #expect(!atTop.isEmpty)
        #expect(atTop == lower)
    }
}
