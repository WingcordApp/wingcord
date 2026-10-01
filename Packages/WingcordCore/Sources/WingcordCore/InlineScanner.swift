import Foundation

/// Scans one paragraph's worth of bytes into inline nodes.
///
/// Recursive descent with lookahead rather than a delimiter stack: at each
/// marker the scanner looks forward for a matching close, and if there is none
/// the marker is emitted as literal text. That is exactly how Discord behaves —
/// a lone `*` is an asterisk, not the start of an unterminated emphasis that
/// swallows the rest of the message — and it means the scanner has no failure
/// mode where output is lost.
///
/// The literal buffer is flushed only when a node is emitted, so a message with
/// no markup produces exactly one `String` allocation for the whole paragraph.
struct InlineScanner {
    private let bytes: [UInt8]
    private let options: MarkdownParser.Options
    private var index: Int = 0
    private var literal: [UInt8] = []
    private var nodes: [InlineNode] = []
    /// Depth guard. Emphasis can nest, but a message consisting of two hundred
    /// asterisks must not recurse two hundred levels deep.
    private let depth: Int
    /// Where `bytes` starts in the text the outermost scanner was given, so a
    /// nested scanner's spans are recorded in the outer text's offsets.
    private let base: Int
    /// Whether to record `spans`. Off for a message, which is drawn from the
    /// nodes and has no use for where the markers were.
    private let recordsSpans: Bool
    /// Every piece of markup the scan accepted, by the bytes that open and
    /// close it — what the editor styles as it is typed. See
    /// `MarkdownEditorSyntax`.
    private(set) var spans: [MarkdownSpan] = []

    init(
        bytes: [UInt8],
        options: MarkdownParser.Options,
        depth: Int = 0,
        base: Int = 0,
        recordsSpans: Bool = false
    ) {
        self.bytes = bytes
        self.options = options
        self.depth = depth
        self.base = base
        self.recordsSpans = recordsSpans
        literal.reserveCapacity(min(bytes.count, 256))
    }

    mutating func parse() -> [InlineNode] {
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case .backslash:
                consumeEscape()
            case .backtick:
                if !consumeInlineCode() { consumeLiteralByte() }
            case .asterisk, .underscore, .tilde, .pipe:
                if !consumeEmphasis(marker: byte) { consumeLiteralByte() }
            case .lessThan:
                if !consumeAngleToken() { consumeLiteralByte() }
            case .openBracket:
                if !consumeLink() { consumeLiteralByte() }
            case .at:
                if !consumeMassMention() { consumeLiteralByte() }
            case .newline:
                flushLiteral()
                nodes.append(.lineBreak)
                index += 1
            case 0x68:  // 'h' — the only first byte a bare http(s) URL can have
                if !consumeAutoLink() { consumeLiteralByte() }
            default:
                consumeLiteralByte()
            }
        }
        flushLiteral()
        return nodes
    }

    // MARK: Literal handling

    private mutating func consumeLiteralByte() {
        literal.append(bytes[index])
        index += 1
    }

    private mutating func flushLiteral() {
        guard !literal.isEmpty else { return }
        nodes.append(.text(String(decoding: literal, as: UTF8.self)))
        literal.removeAll(keepingCapacity: true)
    }

    /// `\*` is an asterisk. `\a` is a backslash followed by an 'a'.
    ///
    /// Restricting escapes to punctuation is what keeps a Windows path readable:
    /// `C:\Users\alex` must not lose its backslashes, and it does the moment
    /// every character is escapable.
    private mutating func consumeEscape() {
        let next = index + 1
        guard next < bytes.count, bytes[next].isASCIIPunctuation else {
            consumeLiteralByte()
            return
        }
        literal.append(bytes[next])
        index = next + 1
    }

    // MARK: Code

    /// `` `code` `` and ``` ``code with a ` in it`` ```.
    ///
    /// The opening run's length decides the closing run's: that is what lets a
    /// code span contain backticks, and it is the reason this counts rather than
    /// looking for a single character.
    private mutating func consumeInlineCode() -> Bool {
        var openLength = 0
        var cursor = index
        while cursor < bytes.count, bytes[cursor] == UInt8.backtick, openLength < 3 {
            openLength += 1
            cursor += 1
        }
        let contentStart = cursor

        while cursor < bytes.count {
            guard bytes[cursor] == UInt8.backtick else {
                cursor += 1
                continue
            }
            var closeLength = 0
            let closeStart = cursor
            while cursor < bytes.count, bytes[cursor] == UInt8.backtick {
                closeLength += 1
                cursor += 1
            }
            if closeLength == openLength {
                let content = bytes[contentStart..<closeStart]
                guard !content.isEmpty else { return false }
                flushLiteral()
                // A single leading and trailing space is stripped, so
                // `` ` `` renders as a backtick rather than as a padded span.
                var text = String(decoding: content, as: UTF8.self)
                if text.count > 1, text.hasPrefix(" "), text.hasSuffix(" ") {
                    text = String(text.dropFirst().dropLast())
                }
                nodes.append(.code(text))
                if recordsSpans {
                    spans.append(MarkdownSpan(
                        kind: .code,
                        open: base + index ..< base + contentStart,
                        close: base + closeStart ..< base + cursor
                    ))
                }
                index = cursor
                return true
            }
        }
        return false
    }

    // MARK: Emphasis

    private mutating func consumeEmphasis(marker: UInt8) -> Bool {
        guard depth < 6 else { return false }

        var runLength = 0
        var cursor = index
        while cursor < bytes.count, bytes[cursor] == marker, runLength < 3 {
            runLength += 1
            cursor += 1
        }

        // `~` and `|` are only markers when doubled. A single one is a tilde or
        // a pipe someone typed.
        if (marker == .tilde || marker == .pipe), runLength < 2 { return false }

        let style = Self.style(marker: marker, runLength: runLength)
        guard !style.isEmpty else { return false }

        // **Each marker keeps Discord's own rule, and they differ** — the
        // patterns are simple-markdown's `em`, `strong`, `u`, `del` and
        // Discord's spoiler, read out of its bundle:
        //
        //  - `**`, `__` and `||` take anything between them, spaces at the
        //    edges included (`/^\|\|([\s\S]+?)\|\|/`).
        //  - `*` and `~~` must hug their content: no space after the opening
        //    run, none before the closing one — `a * b * c` is arithmetic.
        //  - a single `_` needs a word boundary outside, which keeps
        //    `snake_case_name` intact; `__` has none.
        //
        // A run of three carries the single marker's emphasis too, so it
        // follows the single marker's rule.
        let hugsContent = (marker == .asterisk && runLength != 2) || marker == .tilde
        let needsWordBoundary = marker == .underscore && runLength != 2

        if needsWordBoundary {
            let before = index > 0 ? bytes[index - 1] : UInt8.space
            if before.isWordByte { return false }
        }

        let contentStart = cursor
        guard contentStart < bytes.count else { return false }
        if hugsContent,
           bytes[contentStart] == UInt8.space || bytes[contentStart] == UInt8.newline
        {
            return false
        }

        guard let closeStart = findClosingRun(
            marker: marker,
            length: runLength,
            from: contentStart,
            hugsContent: hugsContent
        ) else { return false }

        if needsWordBoundary {
            let after = closeStart + runLength < bytes.count
                ? bytes[closeStart + runLength]
                : UInt8.space
            if after.isWordByte { return false }
        }

        let content = Array(bytes[contentStart..<closeStart])
        guard !content.isEmpty else { return false }

        flushLiteral()
        var inner = InlineScanner(
            bytes: content, options: options, depth: depth + 1,
            base: base + contentStart, recordsSpans: recordsSpans
        )
        nodes.append(.styled(style, inner.parse()))
        if recordsSpans {
            spans.append(MarkdownSpan(
                kind: .styled(style),
                open: base + index ..< base + contentStart,
                close: base + closeStart ..< base + closeStart + runLength
            ))
            spans.append(contentsOf: inner.spans)
        }
        index = closeStart + runLength
        return true
    }

    private static func style(marker: UInt8, runLength: Int) -> InlineStyle {
        switch marker {
        case .asterisk:
            switch runLength {
            case 1: [.italic]
            case 2: [.bold]
            default: [.bold, .italic]
            }
        case .underscore:
            // `___x___` is underline + italic, matching Discord.
            switch runLength {
            case 1: [.italic]
            case 2: [.underline]
            default: [.underline, .italic]
            }
        case .tilde: [.strikethrough]
        case .pipe: [.spoiler]
        default: []
        }
    }

    /// Finds the start of a closing run of exactly `length` markers.
    ///
    /// Skips over inline code spans and escapes, so `*a `b*c` d*` closes on the
    /// last asterisk rather than the one inside the code. Where the marker must
    /// hug its content it refuses to close on a whitespace-preceded run, so
    /// `*a * b*` is one span and not two.
    private func findClosingRun(
        marker: UInt8,
        length: Int,
        from start: Int,
        hugsContent: Bool
    ) -> Int? {
        var cursor = start
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == .backslash {
                cursor += 2
                continue
            }
            if byte == .backtick {
                // Step over a balanced code span so its contents cannot close
                // the emphasis.
                var openLength = 0
                var probe = cursor
                while probe < bytes.count, bytes[probe] == UInt8.backtick {
                    openLength += 1
                    probe += 1
                }
                var closed = false
                while probe < bytes.count {
                    if bytes[probe] == UInt8.backtick {
                        var closeLength = 0
                        while probe < bytes.count, bytes[probe] == UInt8.backtick {
                            closeLength += 1
                            probe += 1
                        }
                        if closeLength == openLength { closed = true; break }
                        continue
                    }
                    probe += 1
                }
                cursor = closed ? probe : cursor + openLength
                continue
            }
            if byte == marker {
                var runLength = 0
                let runStart = cursor
                while cursor < bytes.count, bytes[cursor] == marker {
                    runLength += 1
                    cursor += 1
                }
                let previous = runStart > start ? bytes[runStart - 1] : UInt8.space
                let hugged = !hugsContent || (previous != .space && previous != .newline)
                if runLength >= length, runStart > start, hugged {
                    // Close on the LAST `length` markers of the run, so
                    // `***x***` gives one bold-italic span rather than a bold
                    // span containing a stray asterisk.
                    return runStart + (runLength - length)
                }
                continue
            }
            cursor += 1
        }
        return nil
    }

    // MARK: Angle-bracket tokens

    /// `<@123>`, `<@!123>`, `<@&123>`, `<#123>`, `<:n:1>`, `<a:n:1>`,
    /// `<t:1:F>`, `</cmd:1>`, `<id:guide>`, and `<https://…>`.
    private mutating func consumeAngleToken() -> Bool {
        guard let close = firstIndex(of: .greaterThan, from: index + 1, limit: 128) else {
            return false
        }
        let body = bytes[(index + 1)..<close]
        guard !body.isEmpty else { return false }

        guard let node = Self.angleNode(body) else { return false }
        flushLiteral()
        nodes.append(node)
        index = close + 1
        return true
    }

    private static func angleNode(_ body: ArraySlice<UInt8>) -> InlineNode? {
        var cursor = body.startIndex
        let first = body[cursor]

        switch first {
        case .at:
            cursor = body.index(after: cursor)
            guard cursor < body.endIndex else { return nil }
            if body[cursor] == UInt8.ampersand {
                cursor = body.index(after: cursor)
                guard let value = digits(body[cursor...]) else { return nil }
                return .roleMention(RoleID(rawValue: value))
            }
            // `<@$123>` — a game, Discord's `@game` mention (`827669`).
            if body[cursor] == 0x24 {
                cursor = body.index(after: cursor)
                guard let value = digits(body[cursor...]) else { return nil }
                return .gameMention(ApplicationID(rawValue: value))
            }
            // `<@!123>` is the legacy nickname-mention form and means the same
            // thing. Accepting only `<@123>` leaves old messages showing raw
            // markup.
            if body[cursor] == 0x21 { cursor = body.index(after: cursor) }
            guard let value = digits(body[cursor...]) else { return nil }
            return .userMention(UserID(rawValue: value))

        case .hash:
            guard let value = digits(body.dropFirst()) else { return nil }
            return .channelMention(ChannelID(rawValue: value))

        case 0x69:  // 'i' — `<id:guide>`, or `<id:linked-roles:123>`
            let text = String(decoding: body, as: UTF8.self)
            guard text.hasPrefix("id:") else { return nil }
            let parts = text.dropFirst(3).split(separator: ":", omittingEmptySubsequences: false)
            guard let route = parts.first.flatMap({ StaticRoute(rawValue: String($0)) }),
                  parts.count <= 2
            else { return nil }
            guard parts.count == 2 else { return .staticRoute(route, itemID: nil) }
            guard let item = digits(Array(parts[1].utf8)[...]) else { return nil }
            return .staticRoute(route, itemID: item)

        case 0x2F:  // '/' — a slash-command mention
            let rest = body.dropFirst()
            guard let colon = rest.firstIndex(of: .colon) else { return nil }
            let name = String(decoding: rest[rest.startIndex..<colon], as: UTF8.self)
            guard !name.isEmpty, let value = digits(rest[rest.index(after: colon)...])
            else { return nil }
            return .commandMention(name: name, id: value)

        case .colon, 0x61:  // ':' static emoji, 'a' possibly animated
            var animated = false
            var rest = body
            if first == 0x61 {
                // Only `a:` counts; a word starting with 'a' is not an emoji.
                guard body.count > 1, body[body.index(after: body.startIndex)] == UInt8.colon
                else { return nil }
                animated = true
                rest = body.dropFirst()
            }
            rest = rest.dropFirst()  // the leading ':'
            guard let colon = rest.firstIndex(of: .colon) else { return nil }
            let name = String(decoding: rest[rest.startIndex..<colon], as: UTF8.self)
            guard !name.isEmpty, let value = digits(rest[rest.index(after: colon)...])
            else { return nil }
            return .customEmoji(EmojiRef(id: EmojiID(rawValue: value), name: name, isAnimated: animated))

        case 0x74:  // 't' — a timestamp
            guard body.count > 1, body[body.index(after: body.startIndex)] == UInt8.colon
            else { return nil }
            let rest = body.dropFirst(2)
            var styleCharacter: Character = "f"
            var digitsSlice = rest
            if let colon = rest.firstIndex(of: .colon) {
                digitsSlice = rest[rest.startIndex..<colon]
                let styleSlice = rest[rest.index(after: colon)...]
                if let byte = styleSlice.first {
                    styleCharacter = Character(Unicode.Scalar(byte))
                }
            }
            guard let seconds = digits(digitsSlice) else { return nil }
            let style = TimestampStyle(rawValue: styleCharacter) ?? .shortDateTime
            return .timestamp(Date(timeIntervalSince1970: Double(seconds)), style)

        default:
            // `<https://example.com>` — a link with its embed suppressed.
            let text = String(decoding: body, as: UTF8.self)
            guard text.hasPrefix("http://") || text.hasPrefix("https://") else { return nil }
            return .autoLink(text)
        }
    }

    /// Parses a run of ASCII digits into a `UInt64`, rejecting anything else in
    /// the slice. Overflow returns nil rather than wrapping — a snowflake that
    /// does not fit is not a snowflake.
    private static func digits(_ slice: ArraySlice<UInt8>) -> UInt64? {
        guard !slice.isEmpty, slice.count <= 20 else { return nil }
        var value: UInt64 = 0
        for byte in slice {
            guard byte.isASCIIDigit else { return nil }
            let (multiplied, overflow1) = value.multipliedReportingOverflow(by: 10)
            guard !overflow1 else { return nil }
            let (added, overflow2) = multiplied.addingReportingOverflow(UInt64(byte - .zero))
            guard !overflow2 else { return nil }
            value = added
        }
        return value
    }

    // MARK: Links

    /// `[label](https://example.com)`.
    ///
    /// The URL scheme is checked, and that check is a security boundary rather
    /// than a formatting nicety: a masked link is text the sender chose pointing
    /// at a destination the reader cannot see, so anything that is not http(s)
    /// or discord:// is left as literal text. `javascript:` and `file:` reaching
    /// an opener is how a chat client becomes an attack surface.
    private mutating func consumeLink() -> Bool {
        guard let labelEnd = matchingBracket(from: index) else { return false }
        let parenStart = labelEnd + 1
        guard parenStart < bytes.count, bytes[parenStart] == UInt8.openParen,
              let parenEnd = firstIndex(of: .closeParen, from: parenStart + 1, limit: 2048)
        else { return false }

        let urlBytes = bytes[(parenStart + 1)..<parenEnd]
        var url = String(decoding: urlBytes, as: UTF8.self)
        // **`[label](<url>)` is a link whose target is wrapped to suppress the
        // embed**, and it is the form most posts that carry a link actually
        // use — every announcement in Discord's own game servers is written
        // this way. Unhandled, the angle brackets are part of the string, the
        // scheme check below rejects it, and the whole construct prints as
        // literal markup: `[netflix.com/GTAVI](<https://netflix.com/GTAVI>)`
        // in the middle of a sentence.
        if url.hasPrefix("<"), let close = url.firstIndex(of: ">") {
            url = String(url[url.index(after: url.startIndex)..<close])
        } else if let space = url.firstIndex(of: " ") {
            // Discord allows `(url "title")`; the title is dropped.
            url = String(url[url.startIndex..<space])
        }
        guard Self.isSafeLinkURL(url) else { return false }

        let labelBytes = Array(bytes[(index + 1)..<labelEnd])
        guard !labelBytes.isEmpty else { return false }

        flushLiteral()
        var inner = InlineScanner(
            bytes: labelBytes, options: options, depth: depth + 1,
            base: base + index + 1, recordsSpans: recordsSpans
        )
        nodes.append(.link(label: inner.parse(), url: url))
        if recordsSpans {
            spans.append(MarkdownSpan(
                kind: .link,
                open: base + index ..< base + index + 1,
                close: base + labelEnd ..< base + parenEnd + 1
            ))
            spans.append(contentsOf: inner.spans)
        }
        index = parenEnd + 1
        return true
    }

    static func isSafeLinkURL(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return lowered.hasPrefix("https://")
            || lowered.hasPrefix("http://")
            || lowered.hasPrefix("discord://")
    }

    /// Finds the `]` matching the `[` at `from`, allowing nested brackets.
    private func matchingBracket(from start: Int) -> Int? {
        var depth = 0
        var cursor = start
        while cursor < bytes.count, cursor - start < 1024 {
            switch bytes[cursor] {
            case .backslash: cursor += 1
            case .openBracket: depth += 1
            case .closeBracket:
                depth -= 1
                if depth == 0 { return cursor }
            default: break
            }
            cursor += 1
        }
        return nil
    }

    /// A bare `http://` or `https://` URL in prose.
    private mutating func consumeAutoLink() -> Bool {
        guard matches(prefix: ByteSequence.https) || matches(prefix: ByteSequence.http) else {
            return false
        }
        // A URL must start at a boundary, or `xhttps://…` inside a word links.
        if index > 0, bytes[index - 1].isWordByte { return false }

        var cursor = index
        while cursor < bytes.count, !bytes[cursor].isURLTerminator { cursor += 1 }
        // Trailing punctuation belongs to the sentence, not the URL — except a
        // closing paren that balances one inside the URL, which is how Wikipedia
        // links survive.
        var end = cursor
        while end > index, bytes[end - 1].isTrailingPunctuation {
            if bytes[end - 1] == UInt8.closeParen,
               countByte(.openParen, in: index..<end) >= countByte(.closeParen, in: index..<end)
            { break }
            end -= 1
        }
        guard end - index > 8 else { return false }

        flushLiteral()
        nodes.append(.autoLink(String(decoding: bytes[index..<end], as: UTF8.self)))
        index = end
        return true
    }

    private func countByte(_ byte: UInt8, in range: Range<Int>) -> Int {
        var count = 0
        for cursor in range where bytes[cursor] == byte { count += 1 }
        return count
    }

    // MARK: Mass mentions

    private mutating func consumeMassMention() -> Bool {
        guard options.allowsMassMentions else { return false }
        if matches(prefix: ByteSequence.everyone) {
            flushLiteral()
            nodes.append(.everyoneMention)
            index += ByteSequence.everyone.count
            return true
        }
        if matches(prefix: ByteSequence.here) {
            flushLiteral()
            nodes.append(.hereMention)
            index += ByteSequence.here.count
            return true
        }
        return false
    }

    // MARK: Scanning helpers

    private func matches(prefix: [UInt8]) -> Bool {
        guard index + prefix.count <= bytes.count else { return false }
        for offset in 0..<prefix.count where bytes[index + offset] != prefix[offset] {
            return false
        }
        return true
    }

    /// Bounded forward search. The limit matters: an unmatched `<` in a long
    /// message would otherwise scan to the end on every occurrence, which is
    /// quadratic on exactly the pathological input someone will paste.
    private func firstIndex(of byte: UInt8, from start: Int, limit: Int) -> Int? {
        var cursor = start
        let end = min(bytes.count, start + limit)
        while cursor < end {
            if bytes[cursor] == byte { return cursor }
            cursor += 1
        }
        return nil
    }
}

extension UInt8 {
    var isASCIIPunctuation: Bool {
        (self >= 0x21 && self <= 0x2F)
            || (self >= 0x3A && self <= 0x40)
            || (self >= 0x5B && self <= 0x60)
            || (self >= 0x7B && self <= 0x7E)
    }

    var isURLTerminator: Bool {
        self == .space || self == .newline || self == .lessThan || self == .greaterThan
            || self == 0x22 || self == 0x09
    }

    var isTrailingPunctuation: Bool {
        self == .period || self == 0x2C || self == .colon || self == 0x3B
            || self == 0x21 || self == 0x3F || self == .closeParen || self == .closeBracket
    }
}

private enum ByteSequence {
    static let everyone = Array("@everyone".utf8)
    static let here = Array("@here".utf8)
    static let http = Array("http://".utf8)
    static let https = Array("https://".utf8)
}
