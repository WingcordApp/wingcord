import AppKit
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A system line names somebody in their style — Discord's `447215`: the face
/// everywhere, the whole effect under the pointer in a private channel only.
@MainActor
@Suite("System lines' lit names")
struct SystemLineNameEffectTests {

    private let author = UserID(rawValue: 7)
    private let worn = DisplayNameStyle(font: .default, effect: .gradient, colors: [0xFF5555, 0x5555FF])

    private func row(in guildID: GuildID?, styled: Bool = true, width: CGFloat = 480) -> MessageRow? {
        guard case .message(let row) = timelineRow(in: guildID, styled: styled, width: width)?.kind else { return nil }
        return row
    }

    private func timelineRow(in guildID: GuildID?, styled: Bool = true, width: CGFloat = 480) -> TimelineRow? {
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: author,
            kind: .channelPinnedMessage
        )
        var info = TimelineLayoutEngine.AuthorInfo(
            name: "Voltcast", colorValue: nil, avatarURL: nil,
            monogram: "E", decorationURL: nil, isBot: false
        )
        info.nameStyle = styled ? worn : nil
        let engine = TimelineLayoutEngine(presentationRevision: 0)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        var input = TimelineLayoutEngine.Input(
            items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
            width: width,
            style: MessageTextStyle.current(),
            mentions: MentionContext(),
            channelName: "dm",
            authors: [author: info],
            calendar: .current,
            settings: .comfortable
        )
        input.guildID = guildID
        return engine.layout(input, cache: &cache).first
    }

    @Test("In a DM the line carries the name's style, place and a clear-name copy")
    func directMessage() throws {
        let row = try #require(row(in: nil))
        let slot = try #require(row.systemName)
        #expect(slot.style == worn)
        #expect(slot.name == "Voltcast")
        #expect(slot.width > 20)
        // On the sentence's own line, inside its block.
        let block = try #require(row.textBlock)
        #expect(slot.origin.x >= row.textOrigin.x)
        #expect(slot.origin.y >= row.textOrigin.y - 2)
        #expect(slot.origin.y < row.textOrigin.y + block.size.height)
        // The copy is laid out the same; only the name's ink differs.
        #expect(slot.unnamedBlock.size == block.size)
        #expect(slot.unnamedBlock.text.attributed.string == block.text.attributed.string)
        let start = (block.text.attributed.string as NSString).range(of: "Voltcast").location
        let ink = slot.unnamedBlock.text.attributed.attribute(.foregroundColor, at: start, effectiveRange: nil) as? NSColor
        #expect(ink?.alphaComponent == 0)
    }

    @Test("In a server, or for a name with no style, there is nothing to light")
    func serverAndPlain() {
        #expect(row(in: GuildID(rawValue: 9))?.systemName == nil)
        #expect(row(in: nil, styled: false)?.systemName == nil)
    }

    @Test("Under the pointer the name is painted in its colours; at rest it is not")
    func render() throws {
        let row = try #require(timelineRow(in: nil))
        guard case .message(let message) = row.kind else { Issue.record("not a message row"); return }
        let slot = try #require(message.systemName)
        let run = try #require(DisplayNameGlyphRun(
            text: slot.name, font: slot.face, tracking: slot.tracking,
            perGlyph: false, maximumWidth: slot.width + 8
        ))
        let prepared = DisplayNameEffectPainter.prepare(
            run: run, style: slot.style, pointSize: slot.face.pointSize,
            characterCount: slot.name.utf16.count
        )
        let height = Int(row.height + 8)
        func paint(hovered: Bool) -> [UInt8] {
            RenderProbe.pixels(width: 480, height: height) { context, _ in
                var state = TimelineRowPainter.State()
                state.isHovered = hovered
                TimelineRowPainter.draw(
                    row: row,
                    in: CGRect(x: 0, y: 4, width: 480, height: row.height),
                    context: context,
                    style: MessageTextStyle.current(),
                    state: state,
                    images: ImageStore.shared,
                    scale: 1,
                    styledAuthorName: hovered ? prepared : nil
                )
            }
        }
        func tinted(_ pixels: [UInt8]) -> (red: Int, blue: Int) {
            var red = 0, blue = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let (r, g, b) = (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
                if r > 150, g < 120, b < 140 { red += 1 }
                if b > 150, r < 140, g < 120 { blue += 1 }
            }
            return (red, blue)
        }
        let lit = paint(hovered: true)
        let rest = paint(hovered: false)
        #expect(tinted(lit).red > 5)
        #expect(tinted(lit).blue > 5)
        #expect(tinted(rest).red == 0)
        ANSICodeBlockTests.save(lit, width: 480, height: height, name: "system-line-lit")
        ANSICodeBlockTests.save(rest, width: 480, height: height, name: "system-line-rest")
    }
}
