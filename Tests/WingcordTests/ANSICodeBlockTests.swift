import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Wingcord
@testable import WingcordCore

/// An `ansi` code block is drawn in its colours, with its escapes gone — Alex's
/// image 19 (the escapes printed) against image 20 (Discord, in colour).
@MainActor
@Suite("ANSI code blocks")
struct ANSICodeBlockTests {

    /// Alex's message: "Test test test", the first word red, green, blue, red
    /// in 24-bit colour, then two words in gradients.
    static let alexMessage = "```ansi\n"
        + "\u{1B}[38;2;255;0;0mT\u{1B}[38;2;0;255;0me\u{1B}[38;2;0;0;255ms\u{1B}[38;2;255;0;0mt\u{1B}[0m "
        + "\u{1B}[38;2;253;152;85mt\u{1B}[38;2;238;133;110me\u{1B}[38;2;223;115;136ms\u{1B}[38;2;209;97;162mt\u{1B}[0m "
        + "\u{1B}[38;2;163;84;84mt\u{1B}[38;2;255;178;178me\u{1B}[38;2;163;84;84ms\u{1B}[38;2;255;178;178mt\u{1B}[0m"
        + "\n```"

    private var style: MessageTextStyle { MessageTextStyle.current() }

    private func row(content: String) -> TimelineRow {
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 7),
            content: content
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
                        name: "alex", colorValue: nil, avatarURL: nil,
                        monogram: "A", decorationURL: nil, isBot: false
                    )
                ],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )[0]
    }

    private func textBlock(_ row: TimelineRow) -> TimelineTextBlock? {
        guard case .message(let message) = row.kind else { return nil }
        return message.textBlock
    }

    @Test("The escapes leave the text and the colours stay on it")
    func text() throws {
        let block = try #require(textBlock(row(content: Self.alexMessage)))
        let attributed = block.text.attributed
        #expect(attributed.string == "Test test test")
        #expect(!attributed.string.contains("\u{1B}"))
        #expect(!attributed.string.contains("[38"))
        let red = try #require(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let green = try #require(attributed.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor)
        #expect(red.usingColorSpace(.sRGB)?.redComponent == 1)
        #expect(red.usingColorSpace(.sRGB)?.greenComponent == 0)
        #expect(green.usingColorSpace(.sRGB)?.greenComponent == 1)
        #expect(block.text.codeBlocks.count == 1)
    }

    @Test("A block in a language is drawn plain, then in Discord's colours once highlight.js answers")
    func highlightedBlock() async throws {
        // A text nobody has asked about, so the highlighter's cache is cold.
        let code = "let answer\(Int.random(in: 1_000...999_999)) = 42"
        let content = "```swift\n\(code)\n```"
        let message = Message(
            id: MessageID(rawValue: 2 << 22), channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 7), content: content
        )
        let engine = TimelineLayoutEngine(presentationRevision: 0)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        func layout() -> TimelineTextBlock? {
            let row = engine.layout(
                TimelineLayoutEngine.Input(
                    items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                    width: 480,
                    style: style,
                    mentions: MentionContext(),
                    channelName: "general",
                    authors: [:],
                    calendar: .current,
                    settings: .comfortable
                ),
                cache: &cache
            )[0]
            guard case .message(let laid) = row.kind else { return nil }
            return laid.textBlock
        }

        let first = try #require(layout())
        #expect(first.text.awaitsHighlighting)
        #expect(cache[message.id]?.awaitingHighlightAt != nil)

        // The answer the layout asked for.
        _ = await CodeHighlighter.shared.tokens(for: code, language: "swift")

        // The same cache: the row is stale by the highlighter's revision.
        let second = try #require(layout())
        #expect(!second.text.awaitsHighlighting)
        #expect(cache[message.id]?.awaitingHighlightAt == nil)
        let keyword = second.text.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(keyword == style.codePalette.keyword)
        #expect(second.size.height == first.size.height)
    }

    @Test("A block that is not ansi keeps its escapes as text")
    func otherLanguages() throws {
        let block = try #require(textBlock(row(content: "```\n\u{1B}[31mred\n```")))
        #expect(block.text.attributed.string.contains("[31m"))
    }

    @Test("Bold, a background and an overline are drawn as Discord draws them")
    func decorations() throws {
        let content = "```ansi\n\u{1B}[1mbold\u{1B}[0m \u{1B}[41mground\u{1B}[0m \u{1B}[53mover\n```"
        let block = try #require(textBlock(row(content: content)))
        let attributed = block.text.attributed
        let bold = try #require(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(attributed.attribute(.backgroundColor, at: 5, effectiveRange: nil) != nil)
        #expect(block.text.overlines == [NSRange(location: 12, length: 4)])
    }

    @Test("The colours reach the screen")
    func render() throws {
        let row = row(content: Self.alexMessage)
        let height = Int(row.height + 8)
        let pixels = RenderProbe.pixels(width: 480, height: height) { context, _ in
            TimelineRowPainter.draw(
                row: row,
                in: CGRect(x: 0, y: 4, width: 480, height: row.height),
                context: context,
                style: self.style,
                state: TimelineRowPainter.State(),
                images: ImageStore.shared,
                scale: 1
            )
        }
        var red = 0, green = 0, blue = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
            if r > 180, g < 90, b < 90 { red += 1 }
            if g > 180, r < 90, b < 90 { green += 1 }
            if b > 180, r < 90, g < 90 { blue += 1 }
        }
        #expect(red > 10)
        #expect(green > 10)
        #expect(blue > 10)
        Self.save(pixels, width: 480, height: height, name: "ansi-alex")
    }

    /// Writes the bitmap where `WINGCORD_RENDER_DIR` says, for a look with the
    /// screen locked. Nothing otherwise.
    static func save(_ pixels: [UInt8], width: Int, height: Int, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] else { return }
        var bytes = pixels
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else { return }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}
