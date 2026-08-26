import Foundation

/// Parses Discord's markdown dialect.
///
/// **A hand-written UTF-8 scanner, and that is a performance decision with a
/// measured predecessor.** A regex-driven tokenizer puts `Regex.init` on the
/// scroll path: a Swift regex literal written inside a function is re-parsed —
/// AST and all — on every call, and a client that tokenizes a hundred visible
/// messages per relayout spends a measurable share of a scroll inside the regex
/// parser rather than inside its own code. Hoisting the literals to statics
/// fixes that particular fire; not lighting it is better, and a scanner is also
/// three times faster than the fixed version.
///
/// Working in UTF-8 bytes is safe here because **every marker in this dialect is
/// ASCII**, and UTF-8 is self-synchronising: no byte of a multi-byte scalar ever
/// collides with an ASCII value. So the scanner can compare raw bytes and slice
/// text runs out by byte range without ever decoding a scalar it does not need
/// to look at — which is most of them.
public struct MarkdownParser: Sendable {

    public struct Options: Hashable, Sendable {
        /// Whether `#`, `-#`, list markers and quotes are honoured. Off for an
        /// embed footer or a channel-list preview, where a leading `#` is a
        /// character rather than a heading.
        public var allowsBlockSyntax: Bool
        /// Whether `@everyone` / `@here` become nodes.
        public var allowsMassMentions: Bool

        public init(allowsBlockSyntax: Bool = true, allowsMassMentions: Bool = true) {
            self.allowsBlockSyntax = allowsBlockSyntax
            self.allowsMassMentions = allowsMassMentions
        }

        public static let message = Options()
        /// A single-line context: a preview, a reply quote, an embed field.
        public static let inlineOnly = Options(allowsBlockSyntax: false)
    }

    public var options: Options

    public init(options: Options = .message) { self.options = options }

    public func parse(_ source: String) -> MarkdownDocument {
        guard !source.isEmpty else { return .empty }
        var bytes = Array(source.utf8)
        // A trailing newline would otherwise produce an empty final paragraph.
        while bytes.last == UInt8.newline { bytes.removeLast() }
        guard !bytes.isEmpty else { return .empty }
        var blocks: [BlockNode] = []
        var scanner = LineScanner(bytes: bytes)
        parseBlocks(&scanner, into: &blocks, quoteDepth: 0)
        return MarkdownDocument(blocks: blocks)
    }

    /// Convenience for the many places that want inline nodes and nothing else.
    public func parseInline(_ source: String) -> [InlineNode] {
        let bytes = Array(source.utf8)
        var inline = InlineScanner(bytes: bytes, options: options)
        return inline.parse()
    }

    // MARK: Blocks

    private func parseBlocks(
        _ scanner: inout LineScanner,
        into blocks: inout [BlockNode],
        quoteDepth: Int
    ) {
        var paragraph: [ArraySlice<UInt8>] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inlineNodes(joining: paragraph)))
            paragraph.removeAll(keepingCapacity: true)
        }

        while let line = scanner.peekLine() {
            if !options.allowsBlockSyntax {
                scanner.advanceLine()
                paragraph.append(line)
                continue
            }

            // ``` opens a fenced block and everything to the closing fence is
            // literal, headings and quotes included. This must be tested first.
            if line.starts(with: ByteSequence.tripleBacktick) {
                flushParagraph()
                scanner.advanceLine()
                blocks.append(parseFencedCode(&scanner, openingLine: line))
                continue
            }

            if let level = headingLevel(of: line) {
                flushParagraph()
                scanner.advanceLine()
                let body = line.dropFirst(level + 1)
                blocks.append(.heading(level: level, inlineNodes(of: body)))
                continue
            }

            if line.starts(with: ByteSequence.subtext) {
                flushParagraph()
                scanner.advanceLine()
                blocks.append(.subtext(inlineNodes(of: line.dropFirst(3))))
                continue
            }

            if quoteDepth < 3, let stripped = quoteBody(of: line) {
                flushParagraph()
                // Gather the whole consecutive run of quoted lines and re-parse
                // it one level in, so a quote can contain a list or a code
                // block, which is what Discord does.
                var quoted: [UInt8] = Array(stripped)
                scanner.advanceLine()
                while let next = scanner.peekLine(), let body = quoteBody(of: next) {
                    quoted.append(.newline)
                    quoted.append(contentsOf: body)
                    scanner.advanceLine()
                }
                var inner = LineScanner(bytes: quoted)
                var innerBlocks: [BlockNode] = []
                parseBlocks(&inner, into: &innerBlocks, quoteDepth: quoteDepth + 1)
                blocks.append(.quote(innerBlocks))
                continue
            }

            if let marker = listMarker(of: line) {
                flushParagraph()
                blocks.append(parseList(&scanner, firstMarker: marker, quoteDepth: quoteDepth))
                continue
            }

            scanner.advanceLine()
            paragraph.append(line)
        }

        flushParagraph()
    }

    /// `#`, `##`, `###` followed by a space. Discord stops at three.
    private func headingLevel(of line: ArraySlice<UInt8>) -> Int? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == UInt8.hash, level < 3 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == UInt8.space else { return nil }
        return level
    }

    /// `> ` or `>>> `. Returns the line with the marker removed, or nil.
    ///
    /// A bare `>` with no following space is not a quote — it is a greater-than
    /// sign someone typed, and treating it as one turns every inequality in a
    /// maths discussion into a blockquote.
    private func quoteBody(of line: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        if line.starts(with: ByteSequence.tripleQuote) { return line.dropFirst(4) }
        if line.starts(with: ByteSequence.quote) { return line.dropFirst(2) }
        // A quote line with nothing after the marker is a blank quoted line.
        if line.count == 1, line.first == UInt8.greaterThan { return line.dropFirst(1) }
        return nil
    }

    private struct ListMarker {
        var ordered: Bool
        var number: Int
        /// Bytes to drop from the line to reach the content.
        var width: Int
        var indent: Int
    }

    private func listMarker(of line: ArraySlice<UInt8>) -> ListMarker? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == UInt8.space, indent < 8 {
            indent += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }

        let byte = line[index]
        if byte == .hyphen || byte == .asterisk {
            let next = line.index(after: index)
            guard next < line.endIndex, line[next] == UInt8.space else { return nil }
            return ListMarker(ordered: false, number: 0, width: indent + 2, indent: indent)
        }

        // `12. ` — at most three digits, which is Discord's cap and also stops a
        // year at the start of a line from becoming a list.
        var digits = 0
        var value = 0
        var cursor = index
        while cursor < line.endIndex, line[cursor].isASCIIDigit, digits < 3 {
            value = value * 10 + Int(line[cursor] - .zero)
            digits += 1
            cursor = line.index(after: cursor)
        }
        guard digits > 0, cursor < line.endIndex, line[cursor] == UInt8.period else { return nil }
        let afterPeriod = line.index(after: cursor)
        guard afterPeriod < line.endIndex, line[afterPeriod] == UInt8.space else { return nil }
        return ListMarker(ordered: true, number: value, width: indent + digits + 2, indent: indent)
    }

    private func parseList(
        _ scanner: inout LineScanner,
        firstMarker: ListMarker,
        quoteDepth: Int
    ) -> BlockNode {
        var items: [[BlockNode]] = []
        let ordered = firstMarker.ordered
        let start = firstMarker.number

        while let line = scanner.peekLine(),
              let marker = listMarker(of: line),
              marker.ordered == ordered
        {
            scanner.advanceLine()
            let content = line.dropFirst(marker.width)
            items.append([.paragraph(inlineNodes(of: content))])
        }

        return .list(ordered: ordered, startIndex: max(1, start), items: items)
    }

    private func parseFencedCode(
        _ scanner: inout LineScanner,
        openingLine: ArraySlice<UInt8>
    ) -> BlockNode {
        // Anything after the opening fence on the same line is the language tag.
        let tag = openingLine.dropFirst(3)
        let language = tag.isEmpty ? nil : String(decoding: tag, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)

        var body: [UInt8] = []
        var closed = false
        while let line = scanner.peekLine() {
            scanner.advanceLine()
            if line.starts(with: ByteSequence.tripleBacktick), line.count == 3 {
                closed = true
                break
            }
            if !body.isEmpty { body.append(.newline) }
            body.append(contentsOf: line)
        }

        // An unclosed fence is common — someone is mid-typing, or pasted a
        // snippet and forgot. Discord renders it as a code block to the end of
        // the message rather than reverting to prose, and matching that means a
        // half-typed block does not flicker between two layouts on every
        // keystroke.
        _ = closed
        return .codeBlock(
            language: language?.isEmpty == true ? nil : language,
            code: String(decoding: body, as: UTF8.self)
        )
    }

    // MARK: Inline

    private func inlineNodes(of slice: ArraySlice<UInt8>) -> [InlineNode] {
        var scanner = InlineScanner(bytes: Array(slice), options: options)
        return scanner.parse()
    }

    /// Joins the lines of one paragraph with explicit breaks.
    ///
    /// A soft newline inside a paragraph is a real line break in this dialect —
    /// unlike CommonMark, where it collapses to a space. Collapsing them turns
    /// every multi-line message into one run-on line.
    private func inlineNodes(joining lines: [ArraySlice<UInt8>]) -> [InlineNode] {
        if lines.count == 1 { return inlineNodes(of: lines[0]) }
        var joined: [UInt8] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { joined.append(.newline) }
            joined.append(contentsOf: line)
        }
        var scanner = InlineScanner(bytes: joined, options: options)
        return scanner.parse()
    }
}

// MARK: - Line scanning

private struct LineScanner {
    let bytes: [UInt8]
    private var index: Int = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    /// The next line, without its terminator. Nil at the end.
    func peekLine() -> ArraySlice<UInt8>? {
        guard index < bytes.count else { return nil }
        var end = index
        while end < bytes.count, bytes[end] != UInt8.newline { end += 1 }
        return bytes[index..<end]
    }

    mutating func advanceLine() {
        while index < bytes.count, bytes[index] != UInt8.newline { index += 1 }
        if index < bytes.count { index += 1 }
    }
}

// MARK: - Byte helpers

extension UInt8 {
    static let newline: UInt8 = 0x0A
    static let space: UInt8 = 0x20
    static let hash: UInt8 = 0x23
    static let asterisk: UInt8 = 0x2A
    static let underscore: UInt8 = 0x5F
    static let tilde: UInt8 = 0x7E
    static let pipe: UInt8 = 0x7C
    static let backtick: UInt8 = 0x60
    static let backslash: UInt8 = 0x5C
    static let greaterThan: UInt8 = 0x3E
    static let lessThan: UInt8 = 0x3C
    static let hyphen: UInt8 = 0x2D
    static let period: UInt8 = 0x2E
    static let zero: UInt8 = 0x30
    static let nine: UInt8 = 0x39
    static let colon: UInt8 = 0x3A
    static let at: UInt8 = 0x40
    static let ampersand: UInt8 = 0x26
    static let openBracket: UInt8 = 0x5B
    static let closeBracket: UInt8 = 0x5D
    static let openParen: UInt8 = 0x28
    static let closeParen: UInt8 = 0x29

    var isASCIIDigit: Bool { self >= .zero && self <= .nine }

    /// The word-character test `_` emphasis depends on.
    ///
    /// Discord requires `_` to sit on a word boundary, which is what stops
    /// `snake_case_name` from rendering as "snake case name" with the middle
    /// italicised. `*` has no such rule.
    var isWordByte: Bool {
        (self >= 0x30 && self <= 0x39)
            || (self >= 0x41 && self <= 0x5A)
            || (self >= 0x61 && self <= 0x7A)
            || self == .underscore
            || self >= 0x80  // any non-ASCII scalar byte counts as a word byte
    }
}

private enum ByteSequence {
    static let tripleBacktick: [UInt8] = [.backtick, .backtick, .backtick]
    static let tripleQuote: [UInt8] = [.greaterThan, .greaterThan, .greaterThan, .space]
    static let quote: [UInt8] = [.greaterThan, .space]
    static let subtext: [UInt8] = [.hyphen, .hash, .space]
}
