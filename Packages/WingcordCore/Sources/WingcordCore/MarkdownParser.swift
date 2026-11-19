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

            // A fence at the start of a line opens Discord's code block, and
            // everything to the closing fence is literal, headings and quotes
            // included — so it is tested first. A fence that never closes is
            // not a block in Discord (its rule needs the closing fence), and
            // the line falls through to its other readings.
            if line.starts(with: ByteSequence.tripleBacktick),
               let block = Self.codeBlock(in: scanner.bytes, at: line.startIndex)
            {
                flushParagraph()
                blocks.append(block.node(in: scanner.bytes))
                scanner.resume(after: block.end)
                continue
            }

            if let heading = Self.heading(in: line) {
                flushParagraph()
                scanner.advanceLine()
                blocks.append(.heading(level: heading.level, inlineNodes(of: heading.body)))
                continue
            }

            if let body = Self.subtextBody(of: line) {
                flushParagraph()
                scanner.advanceLine()
                blocks.append(.subtext(inlineNodes(of: body)))
                continue
            }

            // **Discord's quotes don't nest** (its rule returns nothing while
            // `inQuote`): inside one, a `>` is a character.
            if quoteDepth == 0, let contentStart = Self.quoteToEndStart(of: line) {
                // `>>> ` takes the rest of the message, every line of it —
                // Discord's `^( *>>> +([\s\S]*))`.
                flushParagraph()
                var inner = LineScanner(bytes: Array(scanner.bytes[contentStart...]))
                var innerBlocks: [BlockNode] = []
                parseBlocks(&inner, into: &innerBlocks, quoteDepth: quoteDepth + 1)
                blocks.append(.quote(innerBlocks))
                scanner.seekToEnd()
                continue
            }

            if quoteDepth == 0, let stripped = Self.quoteBody(of: line) {
                flushParagraph()
                // Gather the whole consecutive run of quoted lines and re-parse
                // it one level in, so a quote can contain a list or a code
                // block, which is what Discord does. A `>>> ` line ends the run:
                // it starts a quote of its own that takes the rest.
                var quoted: [UInt8] = Array(stripped)
                scanner.advanceLine()
                while let next = scanner.peekLine(),
                      Self.quoteToEndStart(of: next) == nil,
                      let body = Self.quoteBody(of: next)
                {
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

            // Words, and perhaps a code block opening after them. Discord's
            // rule matches wherever a fence starts outside an inline code span,
            // so `see ```this``` here` is words, a block, and words.
            if let block = Self.codeBlock(after: line, in: scanner.bytes) {
                let before = scanner.bytes[line.startIndex..<block.start]
                if before.contains(where: { $0 != UInt8.space }) { paragraph.append(before) }
                flushParagraph()
                blocks.append(block.node(in: scanner.bytes))
                scanner.resume(after: block.end)
                continue
            }

            scanner.advanceLine()
            paragraph.append(line)
        }

        flushParagraph()
    }

    // MARK: Code blocks

    /// A code block found in the bytes: where its fences are, and what is
    /// between them.
    struct CodeBlockMatch: Equatable {
        /// The opening fence's first backtick.
        var start: Int
        var language: Range<Int>?
        var body: Range<Int>
        /// Past the closing fence.
        var end: Int

        func node(in bytes: [UInt8]) -> BlockNode {
            .codeBlock(
                language: language.map { String(decoding: bytes[$0], as: UTF8.self) },
                code: String(decoding: bytes[body], as: UTF8.self)
            )
        }
    }

    /// Discord's code block opening at `start`, read by its own rule (its
    /// bundle): `^```(?:([a-z0-9_+\-.#]+?)\n)?\n*([^\n][^]*?)\n*```` — case
    /// insensitive.
    ///
    /// **A language only when it is one word followed by a line break.** The
    /// old reading took everything after the opening fence on its line as the
    /// language, so a one-line block — ```` ```1) All previously agreed…``` ````,
    /// six of them in a row in a server's rules — came out as a "language" and
    /// an empty box (Alex's image 238, 2026-11-19). **The block ends at the
    /// next fence wherever it is**, at the end of a line of code as well as on
    /// a line of its own; the line breaks round the code are not part of it.
    /// **No closing fence, no block**: the rule needs one, and Discord shows
    /// the backticks as they were typed.
    static func codeBlock(in bytes: [UInt8], at start: Int) -> CodeBlockMatch? {
        guard start + 3 <= bytes.count,
              bytes[start] == UInt8.backtick,
              bytes[start + 1] == UInt8.backtick,
              bytes[start + 2] == UInt8.backtick
        else { return nil }
        let afterFence = start + 3

        // The optional language, and the regex's backtracking: when the block
        // fails with the word read as a language — ```` ```js\n``` ```` — it is
        // read again without one, and the word is the code.
        var probe = afterFence
        while probe < bytes.count, bytes[probe].isCodeLanguageByte { probe += 1 }
        if probe > afterFence, probe < bytes.count, bytes[probe] == UInt8.newline,
           let block = codeBody(in: bytes, start: start, from: probe + 1, language: afterFence..<probe)
        {
            return block
        }
        return codeBody(in: bytes, start: start, from: afterFence, language: nil)
    }

    /// `\n*([^\n][^]*?)\n*```` from `cursor`.
    private static func codeBody(
        in bytes: [UInt8],
        start: Int,
        from cursor: Int,
        language: Range<Int>?
    ) -> CodeBlockMatch? {
        var bodyStart = cursor
        while bodyStart < bytes.count, bytes[bodyStart] == UInt8.newline { bodyStart += 1 }
        // `[^\n]`: the code has at least one character, and the newlines were
        // just skipped, so whatever is here qualifies.
        guard bodyStart < bytes.count else { return nil }
        var search = bodyStart + 1
        while search + 3 <= bytes.count {
            if bytes[search] == UInt8.backtick,
               bytes[search + 1] == UInt8.backtick,
               bytes[search + 2] == UInt8.backtick
            {
                var bodyEnd = search
                while bodyEnd > bodyStart + 1, bytes[bodyEnd - 1] == UInt8.newline { bodyEnd -= 1 }
                return CodeBlockMatch(start: start, language: language, body: bodyStart..<bodyEnd, end: search + 3)
            }
            search += 1
        }
        return nil
    }

    /// The first code block that opens on `line` outside an inline code span
    /// or an escape — where Discord's rule would match first, reading the line
    /// from the left.
    static func codeBlock(after line: ArraySlice<UInt8>, in bytes: [UInt8]) -> CodeBlockMatch? {
        var index = line.startIndex
        let end = line.endIndex
        while index < end {
            let byte = bytes[index]
            if byte == UInt8.backslash {
                // An escaped character is never a marker.
                index += 2
                continue
            }
            guard byte == UInt8.backtick else {
                index += 1
                continue
            }
            var run = 0
            while index + run < end, bytes[index + run] == UInt8.backtick { run += 1 }
            if run >= 3, let block = codeBlock(in: bytes, at: index) { return block }
            // An inline code span is literal: a fence inside one opens nothing.
            index = inlineCodeEnd(in: bytes, from: index + run, runLength: run, limit: end) ?? index + run
        }
        return nil
    }

    /// Past the run of exactly `runLength` backticks that closes an inline code
    /// span, on the same line, around at least one character.
    private static func inlineCodeEnd(in bytes: [UInt8], from start: Int, runLength: Int, limit: Int) -> Int? {
        var cursor = start
        while cursor < limit {
            guard bytes[cursor] == UInt8.backtick else {
                cursor += 1
                continue
            }
            let closeStart = cursor
            while cursor < limit, bytes[cursor] == UInt8.backtick { cursor += 1 }
            if cursor - closeStart == runLength, closeStart > start { return cursor }
        }
        return nil
    }

    // MARK: Headings, subtext, quotes

    /// Discord's heading, `^ *(#{1,3})(?:\s+)((?!\s*#{1,3}\s)[^\n]+?)#*\s*(?:\n|$)`:
    /// spaces may come before the marks, any run of spaces after them, and
    /// closing marks at the end are dropped. A second marker straight after the
    /// first — `# # words` — is not a heading.
    static func heading(in line: ArraySlice<UInt8>) -> (level: Int, body: ArraySlice<UInt8>)? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == UInt8.space { index += 1 }
        var level = 0
        while index < line.endIndex, line[index] == UInt8.hash, level < 3 {
            level += 1
            index += 1
        }
        guard level > 0, index < line.endIndex, line[index].isInlineSpace else { return nil }
        while index < line.endIndex, line[index].isInlineSpace { index += 1 }
        guard index < line.endIndex else { return nil }

        // `(?!\s*#{1,3}\s)`
        var marks = 0
        var probe = index
        while probe < line.endIndex, line[probe] == UInt8.hash, marks < 4 {
            marks += 1
            probe += 1
        }
        if (1...3).contains(marks), probe < line.endIndex, line[probe].isInlineSpace { return nil }

        // `[^\n]+?#*\s*`: closing marks and the spaces round them come off,
        // and at least one character stays.
        var end = line.endIndex
        while end > index + 1, line[end - 1].isInlineSpace { end -= 1 }
        while end > index + 1, line[end - 1] == UInt8.hash { end -= 1 }
        while end > index + 1, line[end - 1].isInlineSpace { end -= 1 }
        return (level, line[index..<end])
    }

    /// Discord's subtext, `^ *-# +((?!-#)[^\n]+)(?:\n|$)`.
    static func subtextBody(of line: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == UInt8.space { index += 1 }
        guard index + 2 < line.endIndex,
              line[index] == UInt8.hyphen,
              line[index + 1] == UInt8.hash,
              line[index + 2] == UInt8.space
        else { return nil }
        index += 2
        while index < line.endIndex, line[index] == UInt8.space { index += 1 }
        guard index < line.endIndex else { return nil }
        if line[index...].starts(with: ByteSequence.subtextMark) { return nil }
        return line[index...]
    }

    /// `> words`: Discord's `^ *>(?!>>) +`, and the marker comes off with one
    /// space (`^ *> ?`). Returns the line's words, or nil.
    ///
    /// A `>` with no space after it is not a quote — it is a greater-than sign
    /// someone typed, and treating it as one turns every inequality in a maths
    /// discussion into a blockquote. **That includes a `>` alone on its line**:
    /// Discord's rule needs the space, so a bare `>` ends a quote rather than
    /// adding a blank line to it.
    static func quoteBody(of line: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == UInt8.space { index += 1 }
        guard index + 1 < line.endIndex,
              line[index] == UInt8.greaterThan,
              line[index + 1] == UInt8.space
        else { return nil }
        return line[(index + 2)...]
    }

    /// `>>> words`: where the quote's words start — they run to the end of the
    /// message — or nil. Discord's `^ *>>> +`, the marker taken off with one
    /// space (`^ *>>> ?`).
    static func quoteToEndStart(of line: ArraySlice<UInt8>) -> Int? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == UInt8.space { index += 1 }
        guard index + 3 < line.endIndex,
              line[index] == UInt8.greaterThan,
              line[index + 1] == UInt8.greaterThan,
              line[index + 2] == UInt8.greaterThan,
              line[index + 3] == UInt8.space
        else { return nil }
        return index + 4
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

    /// Carries on after a block that ended at `end`, perhaps mid-line: the
    /// spaces after it are skipped, and a line break right after it ends its
    /// line rather than leaving an empty one.
    mutating func resume(after end: Int) {
        var probe = end
        while probe < bytes.count, bytes[probe] == UInt8.space { probe += 1 }
        if probe < bytes.count, bytes[probe] == UInt8.newline { probe += 1 }
        index = probe
    }

    /// Past everything — a `>>> ` quote took the rest.
    mutating func seekToEnd() { index = bytes.count }
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

    /// `\s` without the line break: a space or a tab.
    var isInlineSpace: Bool { self == .space || self == 0x09 }

    /// A code block's language, `[a-z0-9_+\-.#]`, either case (the rule is
    /// case insensitive).
    var isCodeLanguageByte: Bool {
        (self >= 0x30 && self <= 0x39)
            || (self >= 0x41 && self <= 0x5A)
            || (self >= 0x61 && self <= 0x7A)
            || self == .underscore || self == 0x2B || self == .hyphen || self == .period || self == .hash
    }

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
    static let subtextMark: [UInt8] = [.hyphen, .hash]
}
