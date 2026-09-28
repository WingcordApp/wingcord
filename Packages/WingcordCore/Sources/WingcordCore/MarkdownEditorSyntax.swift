import Foundation

/// One piece of markup in text being written, by where its markers are.
///
/// **Offsets are UTF-8 bytes into the whole text**, which is what the scanner
/// works in; the editor maps them to its own units once per pass.
public struct MarkdownSpan: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `**`, `*`, `__`, `_`, `~~`, `||` and their runs of three.
        case styled(InlineStyle)
        /// `` `code` ``.
        case code
        /// `[label](url)` — the label is the content, the rest is syntax.
        case link
        /// A fenced block: the fences are the syntax, `language` is the word
        /// after the opening one.
        case codeBlock(language: Range<Int>?)
        /// `> `, `>>> `, `# `, `## `, `### ` — a marker at the head of a line.
        case linePrefix
        /// `-# ` and the line it makes small.
        case subtext
    }

    public var kind: Kind
    /// The opening marker.
    public var open: Range<Int>
    /// The closing marker; empty for a line prefix, which has none.
    public var close: Range<Int>

    public init(kind: Kind, open: Range<Int>, close: Range<Int>) {
        self.kind = kind
        self.open = open
        self.close = close
    }

    /// What the markers enclose.
    public var content: Range<Int> { open.upperBound ..< max(open.upperBound, close.lowerBound) }
}

/// The markup in text as it is being written — Discord's live markdown in its
/// message box (the `syntaxBefore` / `syntaxAfter` classes of its textbox
/// stylesheet, `358931`): the markers stay where they were typed, and what they
/// enclose takes their style.
///
/// **The transcript's own rules**, read through the same scanner the message
/// is drawn with, so a word the box shows as bold is a word the message will
/// show as bold.
public enum MarkdownEditorSyntax {

    public static func spans(in text: String) -> [MarkdownSpan] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return [] }
        var spans: [MarkdownSpan] = []
        var segmentStart = 0
        var lineStart = 0
        var fence: (start: Int, openEnd: Int, language: Range<Int>?)?

        func scanInline(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            var scanner = InlineScanner(
                bytes: Array(bytes[range]), options: MarkdownParser.Options(),
                base: range.lowerBound, recordsSpans: true
            )
            _ = scanner.parse()
            spans.append(contentsOf: scanner.spans)
        }

        while lineStart <= bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
            let line = bytes[lineStart..<lineEnd]
            let isFence = line.starts(with: fenceMarker)

            if let open = fence {
                if isFence {
                    spans.append(MarkdownSpan(
                        kind: .codeBlock(language: open.language),
                        open: open.start ..< open.openEnd,
                        close: lineStart ..< lineStart + fenceMarker.count
                    ))
                    fence = nil
                    segmentStart = lineEnd
                }
            } else if isFence {
                scanInline(segmentStart ..< lineStart)
                let languageStart = lineStart + fenceMarker.count
                let language = languageStart < lineEnd ? languageStart ..< lineEnd : nil
                fence = (lineStart, lineEnd, language)
            } else if let prefix = linePrefix(line) {
                spans.append(MarkdownSpan(
                    kind: prefix == subtextMarker ? .subtext : .linePrefix,
                    open: lineStart ..< lineStart + prefix.count,
                    close: lineEnd ..< lineEnd
                ))
            }
            if lineEnd == bytes.count { break }
            lineStart = lineEnd + 1
        }
        if fence == nil { scanInline(segmentStart ..< bytes.count) }
        return spans
    }

    private static let fenceMarker = Array("```".utf8)
    private static let subtextMarker = Array("-# ".utf8)
    /// Longest first, so `>>> ` is not read as `> `.
    private static let prefixes = [">>> ", "### ", "## ", "# ", "-# ", "> "].map { Array($0.utf8) }

    private static func linePrefix(_ line: ArraySlice<UInt8>) -> [UInt8]? {
        prefixes.first { line.starts(with: $0) }
    }
}
