import AppKit
import Foundation
import SwiftUI
import WingcordCore

/// Discord's Render Markdown (`456262`, decision 9b): a `.md` file's preview
/// drawn as a document — headings, lists, quotes, tables, code — rather than
/// as its source.
///
/// **Apple's Markdown, Discord's set.** Foundation parses (full syntax: GFM
/// tables and strikethrough included); what is drawn is what Discord's
/// renderer draws, in its spacing (`markdownView_d6ca48`): paragraphs, lists
/// and blocks 8 apart, a quote on the transcript's rule, code through the code
/// view and highlighted, tables ruled with a tinted header row, a link only
/// where it is safe — written as `<url>` or `[words](url)` whose words are not
/// themselves a URL — and an image as its source, `![alt](src)`. Five
/// thousand runs at most, then "…", as Discord stops at five thousand tokens.
///
/// **Drawn by TextKit 1**, whose text blocks and tables are the system's own
/// answer for a quote's rule, a code block's plate and a table's grid — and
/// whose text view selects across all of it, as a page does.
nonisolated enum MarkdownPreview {

    /// Everything the document is drawn in, resolved on the main actor.
    struct Style: @unchecked Sendable {
        var body: NSFont
        var bold: NSFont
        var italic: NSFont
        var boldItalic: NSFont
        var headings: [NSFont]
        var inlineCode: NSFont
        var ink: NSColor
        /// A quote's words — Discord's `blockquote { color: --text-subtle }`.
        var quoteInk: NSColor
        var linkInk: NSColor
        var codeFill: NSColor
        var codeBorder: NSColor
        var quoteRule: NSColor
        var hairline: NSColor
        var headerFill: NSColor
        var palette: CodePalette

        @MainActor
        static func current() -> Style {
            let text = PresentationRevision.shared.style
            let ink = ThemeInk.current
            return Style(
                body: text.bodyFont,
                bold: text.boldFont,
                italic: text.italicFont,
                boldItalic: text.boldItalicFont,
                headings: (1...3).compactMap { text.heading(level: $0)[.font] as? NSFont }
                    + Array(repeating: text.boldFont, count: 3),
                inlineCode: text.codeFont,
                ink: text.primaryColor,
                quoteInk: text.secondaryColor,
                linkInk: text.linkColor,
                codeFill: NSColor(cgColor: ink.plates.codeFill) ?? .quaternaryLabelColor,
                codeBorder: NSColor(cgColor: ink.plates.codeBorder) ?? .separatorColor,
                quoteRule: NSColor(cgColor: ink.plates.quoteRule) ?? .tertiaryLabelColor,
                hairline: NSColor(cgColor: ink.lift(0.12)) ?? .separatorColor,
                headerFill: NSColor(cgColor: ink.lift(0.06)) ?? .quaternaryLabelColor,
                palette: text.codePalette
            )
        }
    }

    /// A fenced block, as the highlighter is asked about it.
    struct CodeBlock: Hashable, Sendable {
        var language: String
        var code: String
    }

    struct Output: @unchecked Sendable {
        var text: NSAttributedString
        var codeBlocks: [CodeBlock]
    }

    /// Discord's `j`: a URL somewhere in a link's words or title makes the
    /// link a lie it will not draw.
    static func looksLikeURL(_ text: String) -> Bool {
        text.range(of: #"(?:https?|steam)://[^\s<]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A text block TextKit will draw. **One with no width is laid out and
    /// never drawn** — its padding half applied, its ground and edges missing
    /// (probed): a block needs a content width before it has a frame to paint.
    static func fullWidthBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    /// Space between blocks — Discord's `margin-block-end: var(--space-8)`.
    static let blockGap: CGFloat = 8
    /// How far each list level steps in, and the column its marker sits in.
    static let listIndent: CGFloat = 22
    static let maximumRuns = 5_000

    /// The document, and its fenced blocks for the highlighter. `tokens`
    /// answers for a block already highlighted; one it has no answer for is
    /// drawn plain until asked.
    static func render(
        _ markdown: String,
        style: Style,
        tokens: @escaping (CodeBlock) -> [CodeHighlighter.Token]?
    ) -> Output {
        guard let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return Output(text: NSAttributedString(string: markdown, attributes: [.font: style.body, .foregroundColor: style.ink]), codeBlocks: [])
        }
        var builder = Builder(source: markdown, style: style, tokens: tokens)
        builder.build(parsed)
        return Output(text: builder.output, codeBlocks: builder.codeBlocks)
    }

    private struct Builder {
        let source: String
        let style: Style
        let tokens: (CodeBlock) -> [CodeHighlighter.Token]?
        var output = NSMutableAttributedString()
        var codeBlocks: [CodeBlock] = []
        /// The words' ink for the block being laid — subtler inside a quote.
        private var ink: NSColor

        /// One text block per quote, code block and table cell, kept by the
        /// parser's identity so every paragraph inside shares it.
        private var quoteBlocks: [Int: NSTextBlock] = [:]
        private var codeBlockBlocks: [Int: NSTextBlock] = [:]
        private var tables: [Int: NSTextTable] = [:]
        private var runCount = 0
        private var truncated = false

        /// Every paragraph laid down, with the list and quote it is in — the
        /// spacing that depends on what comes next is settled once it is all
        /// down (`settleSpacing`).
        private struct Emitted {
            var range: NSRange
            var list: Int?
            var quote: Int?
        }
        private var emitted: [Emitted] = []

        init(source: String, style: Style, tokens: @escaping (CodeBlock) -> [CodeHighlighter.Token]?) {
            self.source = source
            self.style = style
            self.tokens = tokens
            ink = style.ink
        }

        mutating func build(_ parsed: AttributedString) {
            var previous: PresentationIntent?
            for (intent, range) in parsed.runs[\.presentationIntent] {
                guard !truncated else { break }
                guard let intent else { continue }
                block(intent, content: parsed[range], after: previous)
                previous = intent
            }
            settleSpacing()
            if truncated {
                output.append(NSAttributedString(string: "\u{2026}", attributes: [.font: style.body, .foregroundColor: style.ink]))
            }
            // The last block's trailing break would be an empty line under it.
            while output.string.hasSuffix("\n") {
                output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
            }
        }

        /// A list's items sit together and the list ends 8 above what follows
        /// (`.list { margin-block: 0 8px }`, `li { margin-bottom: 0 }`); the
        /// last paragraph in a quote leaves the quote's own padding and margin
        /// to close it (`blockquote > :last-child { margin-block-end: 0 }`).
        private mutating func settleSpacing() {
            for (index, entry) in emitted.enumerated() {
                let next = emitted.indices.contains(index + 1) ? emitted[index + 1] : nil
                var spacing: CGFloat?
                if let list = entry.list {
                    spacing = next?.list == list && next?.range.location == NSMaxRange(entry.range) ? 0 : Self.gap
                }
                if let quote = entry.quote, next?.quote != quote {
                    spacing = 0
                }
                guard let spacing, entry.range.length > 0,
                      let current = output.attribute(.paragraphStyle, at: entry.range.location, effectiveRange: nil) as? NSParagraphStyle,
                      current.paragraphSpacing != spacing,
                      let copy = current.mutableCopy() as? NSMutableParagraphStyle
                else { continue }
                copy.paragraphSpacing = spacing
                output.addAttribute(.paragraphStyle, value: copy, range: entry.range)
            }
        }

        private mutating func record(from start: Int, components: [PresentationIntent.IntentType]) {
            let range = NSRange(location: start, length: output.length - start)
            var list: Int?
            var quote: Int?
            for component in components {
                switch component.kind {
                case .orderedList, .unorderedList: list = component.identity
                case .blockQuote: quote = quote ?? component.identity
                default: break
                }
            }
            emitted.append(Emitted(range: range, list: list, quote: quote))
        }

        // MARK: Blocks

        private mutating func block(_ intent: PresentationIntent, content: AttributedSubstring, after previous: PresentationIntent?) {
            let components = intent.components
            guard let innermost = components.first else { return }
            let quotes = components.filter { if case .blockQuote = $0.kind { true } else { false } }
            var textBlocks: [NSTextBlock] = []
            for quote in quotes.reversed() { textBlocks.append(quoteBlock(for: quote)) }
            let start = output.length
            defer { record(from: start, components: components) }
            ink = quotes.isEmpty ? style.ink : style.quoteInk

            switch innermost.kind {
            case .codeBlock(let hint):
                let language = hint?.split(separator: " ").first.map(String.init) ?? ""
                var code = String(content.characters)
                if code.hasSuffix("\n") { code.removeLast() }
                codeBlocks.append(CodeBlock(language: language, code: code))
                textBlocks.append(codeBlock(for: innermost))
                let attributed = NSMutableAttributedString(
                    attributedString: CodeText.highlighted(
                        code,
                        tokens: language.isEmpty ? nil : tokens(CodeBlock(language: language, code: code)),
                        palette: style.palette
                    )
                )
                attributed.append(NSAttributedString(string: "\n", attributes: CodeText.attributes))
                let paragraph = (CodeText.attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                paragraph.textBlocks = textBlocks
                attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
                output.append(attributed)

            case .thematicBreak:
                let rule = MarkdownPreview.fullWidthBlock()
                rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
                rule.setBorderColor(style.hairline, for: .minY)
                rule.setWidth(Self.gap, type: .absoluteValueType, for: .margin, edge: .maxY)
                rule.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = textBlocks + [rule]
                paragraph.maximumLineHeight = 1
                output.append(NSAttributedString(string: "\u{200B}\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 1), .paragraphStyle: paragraph,
                ]))

            case .tableCell(let column):
                tableCell(components: components, column: column, content: content, textBlocks: textBlocks)

            case .header(let level):
                let font = style.headings[max(0, min(level - 1, style.headings.count - 1))]
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = textBlocks
                // `margin: 16px 0 8px`, collapsing with the 8 the block above
                // ends on — and none at the top (`:first-child`).
                paragraph.paragraphSpacingBefore = output.length == 0 ? 0 : Self.gap
                paragraph.paragraphSpacing = level <= 3 ? Self.gap : 4
                appendInline(content, base: font, paragraph: paragraph)

            default:
                paragraphBlock(components: components, content: content, textBlocks: textBlocks, after: previous)
            }
        }

        static let gap = MarkdownPreview.blockGap

        /// A paragraph — in a list item, a quote, or on its own.
        private mutating func paragraphBlock(
            components: [PresentationIntent.IntentType],
            content: AttributedSubstring,
            textBlocks: [NSTextBlock],
            after previous: PresentationIntent?
        ) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = textBlocks
            paragraph.lineSpacing = 2
            // The list items around this paragraph, outermost first.
            var items: [(ordinal: Int, ordered: Bool, identity: Int)] = []
            for (index, component) in components.enumerated() {
                guard case .listItem(let ordinal) = component.kind else { continue }
                let ordered = components.dropFirst(index + 1).first.map {
                    if case .orderedList = $0.kind { true } else { false }
                } ?? false
                items.insert((ordinal, ordered, component.identity), at: 0)
            }
            var marker = ""
            if let item = items.last {
                let depth = CGFloat(items.count - 1)
                let base = depth * MarkdownPreview.listIndent
                let markerEdge = base + MarkdownPreview.listIndent - 6
                let textEdge = base + MarkdownPreview.listIndent
                // A list item's first paragraph carries its marker; the ones
                // after it hang under its words.
                let isFirstParagraph = !(previous?.components.contains { $0.identity == item.identity } ?? false)
                paragraph.firstLineHeadIndent = isFirstParagraph ? base : textEdge
                paragraph.headIndent = textEdge
                paragraph.tabStops = [
                    NSTextTab(textAlignment: .right, location: markerEdge),
                    NSTextTab(textAlignment: .left, location: textEdge),
                ]
                if isFirstParagraph {
                    let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
                    marker = "\t" + (item.ordered ? "\(item.ordinal)." : bullets[min(items.count - 1, bullets.count - 1)]) + "\t"
                }
                // Items sit together; `settleSpacing` gives the list its 8.
                paragraph.paragraphSpacing = 0
            } else {
                paragraph.paragraphSpacing = Self.gap
            }
            if !marker.isEmpty {
                output.append(NSAttributedString(string: marker, attributes: [
                    .font: style.body, .foregroundColor: ink, .paragraphStyle: paragraph,
                ]))
            }
            appendInline(content, base: style.body, paragraph: paragraph)
        }

        private mutating func tableCell(
            components: [PresentationIntent.IntentType],
            column: Int,
            content: AttributedSubstring,
            textBlocks: [NSTextBlock]
        ) {
            var row = 0
            var isHeader = false
            var columns: [PresentationIntent.TableColumn] = []
            var tableIdentity = 0
            for component in components {
                switch component.kind {
                case .tableHeaderRow: isHeader = true
                case .tableRow(let index): row = index
                case .table(let found):
                    columns = found
                    tableIdentity = component.identity
                default: break
                }
            }
            let table: NSTextTable
            if let known = tables[tableIdentity] {
                table = known
            } else {
                table = NSTextTable()
                table.numberOfColumns = max(1, columns.count)
                table.collapsesBorders = true
                table.hidesEmptyCells = false
                table.layoutAlgorithm = .automaticLayoutAlgorithm
                table.setWidth(Self.gap, type: .absoluteValueType, for: .margin, edge: .maxY)
                tables[tableIdentity] = table
            }
            let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            cell.setWidth(1, type: .absoluteValueType, for: .border)
            cell.setBorderColor(style.hairline)
            cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
            cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
            cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
            cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxX)
            cell.verticalAlignment = .topAlignment
            if isHeader { cell.backgroundColor = style.headerFill }
            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = textBlocks + [cell]
            if columns.indices.contains(column) {
                switch columns[column].alignment {
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                default: paragraph.alignment = .natural
                }
            }
            appendInline(content, base: isHeader ? NSFontManager.shared.convert(style.body, toHaveTrait: .boldFontMask) : style.body, paragraph: paragraph)
        }

        private mutating func quoteBlock(for component: PresentationIntent.IntentType) -> NSTextBlock {
            if let known = quoteBlocks[component.identity] { return known }
            let block = MarkdownPreview.fullWidthBlock()
            block.setWidth(4, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(style.quoteRule, for: .minX)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(Self.gap, type: .absoluteValueType, for: .margin, edge: .maxY)
            quoteBlocks[component.identity] = block
            return block
        }

        private mutating func codeBlock(for component: PresentationIntent.IntentType) -> NSTextBlock {
            if let known = codeBlockBlocks[component.identity] { return known }
            let block = MarkdownPreview.fullWidthBlock()
            block.backgroundColor = style.codeFill
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(style.codeBorder)
            block.setWidth(8, type: .absoluteValueType, for: .padding)
            block.setWidth(Self.gap, type: .absoluteValueType, for: .margin, edge: .maxY)
            codeBlockBlocks[component.identity] = block
            return block
        }

        // MARK: Inline

        /// One block's runs: emphasis, strength, strikes, code, links and
        /// pictures as Discord draws them, then the paragraph's end.
        private mutating func appendInline(_ content: AttributedSubstring, base: NSFont, paragraph: NSParagraphStyle) {
            for run in content.runs {
                runCount += 1
                if runCount > MarkdownPreview.maximumRuns {
                    truncated = true
                    break
                }
                var text = String(content[run.range].characters)
                let inline = run.inlinePresentationIntent ?? []
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: ink,
                    .paragraphStyle: paragraph,
                ]
                if inline.contains(.lineBreak) {
                    // Discord's `br`: a line break inside the paragraph.
                    text = "\u{2028}"
                }
                attributes[.font] = font(for: inline, base: base)
                if inline.contains(.code) {
                    attributes[.font] = style.inlineCode
                    attributes[.backgroundColor] = style.codeFill
                }
                if inline.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let image = run.imageURL {
                    // A picture is its source, as Discord's renderer writes it.
                    text = "![\(text)](\(image.absoluteString))"
                } else if let url = run.link {
                    if let target = safeLink(url, text: text) {
                        attributes[.link] = target
                        attributes[.foregroundColor] = style.linkInk
                    } else if text != url.absoluteString {
                        text = "[\(text)](\(url.absoluteString))"
                    }
                }
                output.append(NSAttributedString(string: text, attributes: attributes))
            }
            output.append(NSAttributedString(string: "\n", attributes: [
                .font: base, .foregroundColor: ink, .paragraphStyle: paragraph,
            ]))
        }

        private func font(for inline: InlinePresentationIntent, base: NSFont) -> NSFont {
            let bold = inline.contains(.stronglyEmphasized)
            let italic = inline.contains(.emphasized)
            guard bold || italic else { return base }
            if base == style.body {
                return bold && italic ? style.boldItalic : bold ? style.bold : style.italic
            }
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            return NSFontManager.shared.convert(base, toHaveTrait: traits)
        }

        /// The URL a link may open, or nil to draw it as its source.
        ///
        /// Discord draws a link only when its words — and its title — are not
        /// themselves a URL (`_(l) || _(s)`), so a link cannot say one place
        /// and go to another; an autolink, `<url>`, is drawn as its address.
        /// It does not link a bare address at all (markdown-it's `linkify` is
        /// off), which Foundation does — so a link whose words are its own
        /// address is one only where the source wrote it in angle brackets.
        private func safeLink(_ url: URL, text: String) -> URL? {
            guard let scheme = url.scheme?.lowercased(), ["http", "https", "steam"].contains(scheme) else { return nil }
            if text == url.absoluteString {
                return source.contains("<\(text)>") ? url : nil
            }
            return MarkdownPreview.looksLikeURL(text) ? nil : url
        }
    }
}

/// A rendered document in a text view that sizes to its height at the width
/// it is given — the card's, inside its scroller.
struct MarkdownDocumentText: NSViewRepresentable {
    var text: NSAttributedString
    var linkInk: NSColor
    var open: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    func makeNSView(context: Context) -> NSTextView {
        let view = CodeText.makeTextView()
        view.textContainer?.widthTracksTextView = false
        view.delegate = context.coordinator
        view.linkTextAttributes = [.foregroundColor: linkInk, .cursor: NSCursor.pointingHand]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.open = open
        if view.textStorage?.isEqual(to: text) != true {
            view.textStorage?.setAttributedString(text)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width ?? 480
        guard width.isFinite, width > 0 else { return nil }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width, height: max(CodeText.lineHeight, used.height.rounded(.up)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: (URL) -> Void

        init(open: @escaping (URL) -> Void) { self.open = open }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            open(url)
            return true
        }
    }
}

/// A markdown file's text, rendered — the card's lines or the whole file —
/// with its fenced blocks highlighted as soon as highlight.js has answered,
/// and the notice under it in Discord's subtle line (`markdownEllipsis`).
struct RenderedMarkdown: View {
    var text: String
    var notice: String

    @Environment(AppModel.self) private var model
    /// Moves when a fenced block's highlighting lands, so the document is
    /// drawn again with it.
    @State private var highlighted = 0

    var body: some View {
        let style = MarkdownPreview.Style.current()
        let output = MarkdownPreview.render(text, style: style) { block in
            CodeHighlighter.shared.cachedTokens(for: block.code, language: block.language) ?? nil
        }
        VStack(alignment: .leading, spacing: 0) {
            MarkdownDocumentText(text: output.text, linkInk: style.linkInk) { url in
                model.openLink(url.absoluteString)
            }
            // Discord's `markdownView`: 8 above and below, 16 either side.
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            if !notice.isEmpty {
                Text(verbatim: notice)
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .id(highlighted)
        .task(id: output.codeBlocks) {
            var landed = false
            for block in output.codeBlocks where !block.language.isEmpty
                && CodeHighlighter.shared.cachedTokens(for: block.code, language: block.language) == nil
            {
                if await CodeHighlighter.shared.tokens(for: block.code, language: block.language) != nil {
                    landed = true
                }
            }
            guard landed, !Task.isCancelled else { return }
            highlighted &+= 1
        }
    }
}
