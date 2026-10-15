import AppKit
import Foundation
import Testing
@testable import Wingcord

/// Render Markdown draws what Discord's renderer (`456262`) draws: headings
/// in their faces, lists with their markers, a table as a table, code through
/// the code view, a link only where it is safe and a picture as its source.
@MainActor
@Suite("Render Markdown")
struct MarkdownPreviewTests {

    private func render(_ markdown: String) -> MarkdownPreview.Output {
        MarkdownPreview.render(markdown, style: .current()) { _ in nil }
    }

    private func attribute<T>(_ key: NSAttributedString.Key, of needle: String, in text: NSAttributedString) -> T? {
        let range = (text.string as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return text.attribute(key, at: range.location, effectiveRange: nil) as? T
    }

    @Test("Headings take the transcript's heading faces")
    func headings() throws {
        let text = render("# Title\n\nWords").text
        let title: NSFont = try #require(attribute(.font, of: "Title", in: text))
        let words: NSFont = try #require(attribute(.font, of: "Words", in: text))
        #expect(title.pointSize > words.pointSize)
        #expect(title.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test("Lists carry their markers, ordered ones their own numbers")
    func lists() {
        let text = render("- one\n- two\n  - nested\n\n3. three\n4. four").text.string
        #expect(text.contains("\t\u{2022}\tone"))
        #expect(text.contains("\t\u{25E6}\tnested"))
        #expect(text.contains("\t3.\tthree"))
        #expect(text.contains("\t4.\tfour"))
    }

    @Test("Emphasis, strength and strikes")
    func inline() throws {
        let text = render("*it* **bold** ~~gone~~ `code`").text
        let italic: NSFont = try #require(attribute(.font, of: "it", in: text))
        let bold: NSFont = try #require(attribute(.font, of: "bold", in: text))
        #expect(italic.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        let strike: Int? = attribute(.strikethroughStyle, of: "gone", in: text)
        #expect(strike == NSUnderlineStyle.single.rawValue)
        let code: NSFont = try #require(attribute(.font, of: "code", in: text))
        #expect(code.isFixedPitch)
    }

    @Test("A link is a link only where Discord would draw one")
    func links() {
        let text = render(
            "[docs](https://example.com/docs) <https://auto.example.com> https://bare.example.com "
                + "[https://evil.example.com](https://good.example.com)"
        ).text
        let docs: URL? = attribute(.link, of: "docs", in: text)
        #expect(docs?.absoluteString == "https://example.com/docs")
        let auto: URL? = attribute(.link, of: "https://auto.example.com", in: text)
        #expect(auto != nil)
        // markdown-it's linkify is off: a bare address is words.
        let bare: URL? = attribute(.link, of: "https://bare.example.com", in: text)
        #expect(bare == nil)
        // Words that are a URL are drawn as the source, unlinked.
        #expect(text.string.contains("[https://evil.example.com](https://good.example.com)"))
    }

    @Test("A picture is its source")
    func images() {
        let text = render("![Shot](https://example.com/shot.png)").text.string
        #expect(text == "![Shot](https://example.com/shot.png)")
    }

    @Test("A table is a table, its header row tinted")
    func tables() throws {
        let text = render("| A | B |\n| --- | ---: |\n| one | two |").text
        let style: NSParagraphStyle = try #require(attribute(.paragraphStyle, of: "two", in: text))
        let cell = try #require(style.textBlocks.last as? NSTextTableBlock)
        #expect(cell.table.numberOfColumns == 2)
        #expect(cell.startingRow == 1)
        #expect(cell.startingColumn == 1)
        #expect(style.alignment == .right)
        let header: NSParagraphStyle = try #require(attribute(.paragraphStyle, of: "A", in: text))
        #expect((header.textBlocks.last as? NSTextTableBlock)?.backgroundColor != nil)
    }

    @Test("Fenced code goes to the highlighter and sits on the code plate")
    func code() throws {
        let output = render("```swift\nlet x = 1\n```")
        #expect(output.codeBlocks == [MarkdownPreview.CodeBlock(language: "swift", code: "let x = 1")])
        let style: NSParagraphStyle = try #require(attribute(.paragraphStyle, of: "let x", in: output.text))
        #expect(style.textBlocks.last?.backgroundColor != nil)
    }

    @Test("A quote stands on the rule")
    func quotes() throws {
        let text = render("> quoted").text
        let style: NSParagraphStyle = try #require(attribute(.paragraphStyle, of: "quoted", in: text))
        let block = try #require(style.textBlocks.first)
        #expect(block.width(for: .border, edge: .minX) == 4)
    }

    @Test("The whole document draws")
    func draws() async throws {
        let markdown = """
        # Wingcord

        A native **macOS** client for *Discord*.

        ## Features

        - Frosted bubbles
        - A glass sidebar
          - Messages and Servers
        - `inline code` too

        1. Download
        2. Sign in

        > Every rule cost something.

        ```swift
        let greeting = "Hello"
        print(greeting)
        ```

        | Surface | Material |
        | --- | --- |
        | Sidebar | Liquid Glass |
        | Bubbles | Standard material |

        ---

        Read [the docs](https://example.com/docs).
        """
        _ = await CodeHighlighter.shared.tokens(for: "let greeting = \"Hello\"\nprint(greeting)", language: "swift")
        let output = MarkdownPreview.render(markdown, style: .current()) { block in
            CodeHighlighter.shared.cachedTokens(for: block.code, language: block.language) ?? nil
        }
        let view = CodeText.makeTextView()
        view.textStorage?.setAttributedString(output.text)
        view.frame = CGRect(x: 0, y: 0, width: 560, height: 10)
        view.textContainer?.size = CGSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let used = view.layoutManager!.usedRect(for: view.textContainer!)
        view.frame.size.height = used.height.rounded(.up)
        #expect(used.height > 300)
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"],
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        let ground = NSView(frame: view.bounds)
        ground.wantsLayer = true
        ground.layer?.backgroundColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).cgColor
        ground.addSubview(view)
        ground.appearance = NSAppearance(named: .darkAqua)
        ground.cacheDisplay(in: ground.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("markdown.png"))
    }

    @Test("Highlighted code blocks draw in the room's colours once the tokens are in")
    func highlighted() async throws {
        let code = "let x = 1"
        _ = await CodeHighlighter.shared.tokens(for: code, language: "swift")
        let output = MarkdownPreview.render("```swift\n\(code)\n```", style: .current()) { block in
            CodeHighlighter.shared.cachedTokens(for: block.code, language: block.language) ?? nil
        }
        let color: NSColor? = attribute(.foregroundColor, of: "let", in: output.text)
        #expect(color == MarkdownPreview.Style.current().palette.keyword)
    }
}
