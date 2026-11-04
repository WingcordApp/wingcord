import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Discord's "(edited)" after a changed message's words, through the engine
/// the transcript calls (Alex, 2026-10-26: "edited markers on edited
/// messages" — only VoiceOver was ever told).
@MainActor
@Suite("Edited marker")
struct EditedMarkTests {
    private static let me = UserID(rawValue: 1)
    private static let them = UserID(rawValue: 2)
    private static let editedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func message(_ id: UInt64, _ author: UserID, _ content: String, edited: Bool) -> Message {
        Message(
            id: MessageID(rawValue: id),
            channelID: ChannelID(rawValue: 9),
            authorID: author,
            content: content,
            editedAt: edited ? Self.editedAt : nil
        )
    }

    private func rows(
        _ messages: [Message],
        arrangement: MessageArrangement = .bubbles(namesAuthors: true),
        cache: inout [MessageID: TimelineLayoutEngine.CacheEntry]
    ) -> [MessageRow] {
        TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: TimelineReducer.rows(messages: messages, failed: []),
                width: 800,
                style: MessageTextStyle.current(),
                mentions: MentionContext(selfIDs: [Self.me.rawValue]),
                channelName: "general",
                authors: [
                    Self.me: .init(
                        name: "Wren", colorValue: nil, avatarURL: nil,
                        monogram: "W", decorationURL: nil, isBot: false
                    ),
                    Self.them: .init(
                        name: "Alder", colorValue: nil, avatarURL: nil,
                        monogram: "A", decorationURL: nil, isBot: false
                    ),
                ],
                calendar: .current,
                settings: .comfortable,
                arrangement: arrangement
            ),
            cache: &cache
        ).compactMap {
            if case .message(let row) = $0.kind { row } else { nil }
        }
    }

    private func rows(
        _ messages: [Message],
        arrangement: MessageArrangement = .bubbles(namesAuthors: true)
    ) -> [MessageRow] {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return rows(messages, arrangement: arrangement, cache: &cache)
    }

    @Test("An edited message's words end in Discord's (edited), in bubbles and in columns; one nobody changed does not")
    func marksEditedWords() throws {
        for arrangement in [MessageArrangement.bubbles(namesAuthors: true), .columns] {
            let laid = rows(
                [message(1, Self.them, "see you at eight", edited: true),
                 message(2, Self.them, "or nine", edited: false)],
                arrangement: arrangement
            )
            let edited = try #require(laid[0].textBlock?.text)
            #expect(edited.attributed.string == "see you at eight (edited)")
            #expect(edited.editedMark?.editedAt == Self.editedAt)
            #expect(edited.selectableLength == ("see you at eight" as NSString).length)
            let plain = try #require(laid[1].textBlock?.text)
            #expect(plain.attributed.string == "or nine")
            #expect(plain.editedMark == nil)
            #expect(plain.selectableLength == plain.attributed.length)
        }
    }

    @Test("The marker is a size under the words, in the secondary ink")
    func markerIsQuiet() throws {
        let style = MessageTextStyle.current()
        let text = try #require(rows([message(1, Self.them, "hello", edited: true)]).first?.textBlock?.text)
        let mark = try #require(text.editedMark)
        let font = try #require(text.attributed.attribute(.font, at: mark.range.location, effectiveRange: nil) as? NSFont)
        let ink = try #require(text.attributed.attribute(.foregroundColor, at: mark.range.location, effectiveRange: nil) as? NSColor)
        #expect(font.pointSize < style.bodyFont.pointSize)
        // Compared resolved: two styles built apart hold equal colours in
        // different objects.
        func components(_ color: NSColor) -> [CGFloat] {
            guard let srgb = color.usingColorSpace(.sRGB) else { return [] }
            return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
        }
        let drawn = components(ink)
        #expect(drawn.count == 4)
        #expect(zip(drawn, components(style.secondaryColor)).allSatisfy { abs($0 - $1) < 0.01 })
        #expect(!zip(drawn, components(style.tertiaryColor)).allSatisfy { abs($0 - $1) < 0.01 })
        #expect((text.attributed.string as NSString).substring(with: mark.range) == "(edited)")
    }

    @Test("A bubble takes the marker in with its words")
    func bubbleHoldsTheMarker() throws {
        let laid = rows([message(1, Self.me, "on my way", edited: true)])
        let plain = rows([message(1, Self.me, "on my way", edited: false)])
        let bubble = try #require(laid.first?.bubbles?.bubble)
        let unedited = try #require(plain.first?.bubbles?.bubble)
        #expect(bubble.rect.width > unedited.rect.width)
        // Inside it, on the words' last line.
        let row = try #require(laid.first)
        let block = try #require(row.textBlock)
        let mark = try #require(block.editedMarkRect).offsetBy(dx: row.textOrigin.x, dy: row.textOrigin.y)
        #expect(bubble.rect.contains(mark))
        #expect(block.lineCount == 1)
    }

    @Test("After a fenced block the marker starts a line of its own, outside the block's box")
    func codeBlockKeepsItsBox() throws {
        let code = "```\nlet x = 1\n```"
        let edited = try #require(rows([message(1, Self.them, code, edited: true)], arrangement: .columns).first?.textBlock)
        let plain = try #require(rows([message(1, Self.them, code, edited: false)], arrangement: .columns).first?.textBlock)
        #expect(edited.lineCount == plain.lineCount + 1)
        let box = try #require(edited.codeBlockRects.first)
        let mark = try #require(edited.editedMarkRect)
        #expect(mark.minY >= box.maxY)
    }

    @Test("A selection stops where the words do: the marker is never selected or copied")
    func selectionStopsAtTheWords() throws {
        let row = try #require(rows([message(1, Self.them, "fixed the typo", edited: true)], arrangement: .columns).first)
        let block = try #require(row.textBlock)
        let length = block.text.selectableLength
        let mark = try #require(block.editedMarkRect)
        // On the marker, past it, and below the text: all the end of the words.
        #expect(block.characterIndex(at: CGPoint(x: mark.midX, y: mark.midY)) == length)
        #expect(block.characterIndex(at: CGPoint(x: block.size.width + 40, y: mark.midY)) == length)
        #expect(block.characterIndex(at: CGPoint(x: 0, y: block.size.height + 40)) == length)
        // A double-click on it takes the last word, not the marker.
        let word = block.wordRange(at: block.characterIndex(at: CGPoint(x: mark.midX, y: mark.midY)))
        #expect(NSMaxRange(word) <= length)
        // A triple-click's whole message copies as the words alone.
        let copied = TimelineCanvasView.plainText(of: block.text, in: NSRange(location: 0, length: length))
        #expect(copied == "fixed the typo")
    }

    /// `AFTER_ACCESSORIES` in Discord's `d3907dbcdbac69c5.js`: a bot editing its
    /// embed in place has no words to set the marker after.
    @Test("With no words, the marker goes under what the message holds")
    func noWordsGoesUnder() throws {
        let picture = WingcordCore.Attachment(
            id: AttachmentID(rawValue: 1),
            filename: "cat.png",
            url: "https://cdn.discordapp.com/attachments/1/2/cat.png",
            proxyURL: "https://media.discordapp.net/attachments/1/2/cat.png",
            contentType: "image/png",
            width: 400,
            height: 300
        )
        func held(editedAt: Date?, author: UserID = Self.them) -> Message {
            Message(
                id: MessageID(rawValue: 1),
                channelID: ChannelID(rawValue: 9),
                authorID: author,
                editedAt: editedAt,
                payload: MessagePayload(attachments: [picture])
            )
        }
        // In columns: under the picture, and the row is tall enough to hold it.
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let timeline = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: TimelineReducer.rows(messages: [held(editedAt: Self.editedAt)], failed: []),
                width: 800,
                style: MessageTextStyle.current(),
                mentions: MentionContext(selfIDs: [Self.me.rawValue]),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable,
                arrangement: .columns
            ),
            cache: &cache
        )
        let column = try #require(timeline.first { if case .message = $0.kind { true } else { false } })
        guard case .message(let row) = column.kind else { return }
        #expect(row.textBlock == nil)
        let foot = try #require(row.editedFoot)
        #expect((foot.block.text.attributed.string) == MessageText.editedWord)
        let picturesFoot = try #require(row.attachments.first).rect.maxY
        #expect(foot.origin.y >= picturesFoot)
        #expect(column.height >= foot.origin.y + foot.block.size.height)
        // The one place the tooltip asks.
        let mark = try #require(row.editedMark)
        #expect(mark.editedAt == Self.editedAt)
        #expect(mark.rect == CGRect(origin: foot.origin, size: foot.block.size))

        // In a bubble, on either side: inside it, under the picture.
        for author in [Self.me, Self.them] {
            let laid = try #require(rows([held(editedAt: Self.editedAt, author: author)]).first)
            let bubble = try #require(laid.bubbles?.bubble)
            let inBubble = try #require(laid.editedMark)
            #expect(bubble.rect.contains(inBubble.rect))
            let bubbledFoot = try #require(laid.attachments.first).rect.maxY
            #expect(inBubble.rect.minY >= bubbledFoot)
        }

        // Nobody changed it: nothing under it.
        #expect(try #require(rows([held(editedAt: nil)]).first).editedFoot == nil)
        #expect(try #require(rows([held(editedAt: nil)]).first).editedMark == nil)
        // With words it stays after the words, and the foot is not drawn too.
        let worded = try #require(rows([message(1, Self.them, "look", edited: true)]).first)
        #expect(worded.editedFoot == nil)
        #expect(worded.editedMark != nil)
    }

    @Test("An edit landing lays the row out again with the marker")
    func editRelaysTheRow() throws {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let before = try #require(rows([message(1, Self.them, "hello", edited: false)], cache: &cache).first?.textBlock)
        #expect(before.text.editedMark == nil)
        let after = try #require(rows([message(1, Self.them, "hello", edited: true)], cache: &cache).first?.textBlock)
        #expect(after.text.editedMark != nil)
    }

    @Test("Drawn after the words, inside the bubble, on both sides and in columns")
    func render() throws {
        let conversation = [
            message(1, Self.them, "the build is green again", edited: true),
            message(2, Self.me, "nice", edited: true),
            message(3, Self.me, "I moved the release to Thursday so the notes have a day to settle before anyone reads them", edited: true),
            message(4, Self.them, "```\nswift test\n```", edited: true),
        ]
        let width = 800
        var stacked: [(TimelineRow, CGFloat)] = []
        var total: CGFloat = 8
        for arrangement in [MessageArrangement.bubbles(namesAuthors: true), .columns] {
            var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
            let laid = TimelineLayoutEngine(presentationRevision: 1).layout(
                TimelineLayoutEngine.Input(
                    items: TimelineReducer.rows(messages: conversation, failed: []),
                    width: CGFloat(width),
                    style: MessageTextStyle.current(),
                    mentions: MentionContext(selfIDs: [Self.me.rawValue]),
                    channelName: "general",
                    authors: [
                        Self.me: .init(name: "Wren", colorValue: nil, avatarURL: nil, monogram: "W", decorationURL: nil, isBot: false),
                        Self.them: .init(name: "Alder", colorValue: nil, avatarURL: nil, monogram: "A", decorationURL: nil, isBot: false),
                    ],
                    calendar: .current,
                    settings: .comfortable,
                    arrangement: arrangement
                ),
                cache: &cache
            )
            for row in laid {
                if case .message = row.kind { stacked.append((row, total)) }
                total += row.height
            }
            total += 16
        }
        let scale = 2
        let style = MessageTextStyle.current()
        let pixels = RenderProbe.pixels(width: width * scale, height: Int(total) * scale) { context, frame in
            context.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
            context.fill(frame)
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            for (row, top) in stacked {
                TimelineRowPainter.draw(
                    row: row,
                    in: CGRect(x: 0, y: top, width: CGFloat(width), height: row.height),
                    context: context,
                    style: style,
                    state: TimelineRowPainter.State(),
                    images: ImageStore.shared,
                    scale: CGFloat(scale)
                )
            }
        }
        #expect(!pixels.isEmpty)
        ANSICodeBlockTests.save(pixels, width: width * scale, height: Int(total) * scale, name: "edited-marker")
    }

    @Test("The tooltip says the whole moment on the reader's clock")
    func tooltipSaysWhen() {
        let label = TimelineSettings.comfortable.fullTimestampLabel(Self.editedAt)
        // 1,790,000,000 is 21 September 2026, 14:13 UTC — September in every zone.
        #expect(label.contains("2026"))
        #expect(label.contains(" at "))
        #expect(label.contains("September"))
    }
}
