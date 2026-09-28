import Foundation

/// A mark the selection toolbar can put around text.
nonisolated enum MarkdownFormat: CaseIterable, Hashable, Sendable {
    case bold, italics, underline, strikethrough, inlineCode, spoiler

    /// Discord's own markers (`u` in module `339871`).
    var marker: String {
        switch self {
        case .bold: "**"
        case .italics: "*"
        case .underline: "__"
        case .strikethrough: "~~"
        case .inlineCode: "`"
        case .spoiler: "||"
        }
    }
}

/// Text and the selection in it after a format was toggled.
nonisolated struct FormattingEdit: Equatable, Sendable {
    var text: String
    /// In UTF-16 units, as the text view keeps it.
    var selection: NSRange
}

/// Discord's formatting toggles (module `339871`), on plain text.
///
/// **Its rule for "already formatted" is where the markers are, not what the
/// text renders as.** It looks outward from each edge of the selection across
/// marker characters only, and a format is on when its marker sits against
/// both edges — so selecting `bold` in `**bold**` finds `**` either side and
/// takes them off, where selecting `ld` does not. The special cases are its
/// own: `***` is italics and bold together, `___` italics and underline, and
/// a marker found inside a longer run of the same character does not count
/// (`*` inside `**` is not italics).
nonisolated enum FormattingToggle {

    /// The formats whose markers wrap the selection (`c` in the module).
    static func activeFormats(in text: String, selection: NSRange) -> Set<MarkdownFormat> {
        let units = Array(text.utf16)
        let before = markers(around: selection.location, in: units)
        let after = markers(around: NSMaxRange(selection), in: units)
        return Set(before.keys.filter { after[$0] != nil })
    }

    /// Puts `format` around the selection, or takes it off (`Px`).
    static func toggle(_ format: MarkdownFormat, in text: String, selection: NSRange) -> FormattingEdit {
        let units = Array(text.utf16)
        let start = selection.location
        let end = NSMaxRange(selection)
        let before = markers(around: start, in: units)
        let after = markers(around: end, in: units)

        if let open = before[format], let close = after[format] {
            var edited = units
            edited.removeSubrange(close.location ..< close.location + close.length)
            edited.removeSubrange(open.location ..< open.location + open.length)
            let newStart = start >= open.location ? start - open.length : start
            var newEnd = end >= open.location ? end - open.length : end
            if end > close.location { newEnd -= close.length }
            let anchor = max(0, newStart)
            return FormattingEdit(
                text: String(decoding: edited, as: UTF16.self),
                selection: NSRange(location: anchor, length: max(0, newEnd - anchor))
            )
        }

        let marker = Array(format.marker.utf16)
        var edited = units
        edited.insert(contentsOf: marker, at: end)
        edited.insert(contentsOf: marker, at: start)
        return FormattingEdit(
            text: String(decoding: edited, as: UTF16.self),
            selection: NSRange(location: start + marker.count, length: end - start)
        )
    }

    /// Quotes every line the selection touches, or unquotes them all when
    /// every one already is (`fO`, where a quote is a block Discord's editor
    /// draws with a rule and this one writes as `> `).
    static func toggleQuote(in text: String, selection: NSRange) -> FormattingEdit {
        let string = text as NSString
        let lines = string.lineRange(for: selection)
        var starts: [Int] = []
        var cursor = lines.location
        while cursor < NSMaxRange(lines) || (starts.isEmpty && cursor == lines.location) {
            starts.append(cursor)
            let line = string.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(line)
            if next <= cursor { break }
            cursor = next
        }
        let prefix = "> "
        let allQuoted = starts.allSatisfy { string.substring(from: $0).hasPrefix(prefix) }
        let edited = NSMutableString(string: text)
        var shiftBeforeStart = 0
        var shiftTotal = 0
        // From the last line up, so earlier offsets stay where they were.
        for lineStart in starts.reversed() {
            let quoted = (edited as String as NSString).substring(from: lineStart).hasPrefix(prefix)
            if allQuoted, quoted {
                edited.deleteCharacters(in: NSRange(location: lineStart, length: 2))
                shiftTotal -= 2
                if lineStart < selection.location { shiftBeforeStart -= 2 }
            } else if !allQuoted, !quoted {
                edited.insert(prefix, at: lineStart)
                shiftTotal += 2
                if lineStart <= selection.location { shiftBeforeStart += 2 }
            }
        }
        // The start moves with the prefixes at or before it — and never back past
        // its own line's start, which is where a removed prefix under it went.
        let location = max(lines.location, selection.location + shiftBeforeStart)
        let end = NSMaxRange(selection) + shiftTotal
        return FormattingEdit(
            text: edited as String,
            selection: NSRange(location: location, length: max(0, end - location))
        )
    }

    // MARK: Discord's scan (`d`, `h`, `m`, `f`)

    private struct Found {
        var location: Int
        var length: Int
    }

    private static let markerCharacters: Set<UInt16> = Set("*_~`|".utf16)

    /// The markers in the run of marker characters around `point`.
    private static func markers(around point: Int, in units: [UInt16]) -> [MarkdownFormat: Found] {
        var lower = min(point, units.count)
        while lower > 0, markerCharacters.contains(units[lower - 1]) { lower -= 1 }
        var upper = min(point, units.count)
        while upper < units.count, markerCharacters.contains(units[upper]) { upper += 1 }
        let run = Array(units[lower..<upper])
        var found: [MarkdownFormat: Found] = [:]

        func triple(_ syntax: String, _ first: MarkdownFormat, _ second: MarkdownFormat) {
            let marks = Array(syntax.utf16)
            guard let at = index(of: marks, in: run) else { return }
            found[first] = Found(location: lower + at, length: 1)
            found[second] = Found(location: lower + at + 1, length: marks.count - 1)
        }
        func single(_ syntax: String, _ format: MarkdownFormat) {
            let marks = Array(syntax.utf16)
            guard let at = index(of: marks, in: run) else { return }
            found[format] = Found(location: lower + at, length: marks.count)
        }

        triple("***", .italics, .bold)
        triple("___", .italics, .underline)
        single("**", .bold)
        single("*", .italics)
        single("_", .italics)
        single("__", .underline)
        single("`", .inlineCode)
        single("~~", .strikethrough)
        single("||", .spoiler)
        return found
    }

    /// `f`: the first place `syntax` occurs in `run`, unless the same
    /// character sits against it on either side.
    private static func index(of syntax: [UInt16], in run: [UInt16]) -> Int? {
        guard !syntax.isEmpty, run.count >= syntax.count else { return nil }
        guard let at = (0...(run.count - syntax.count)).first(where: {
            Array(run[$0 ..< $0 + syntax.count]) == syntax
        }) else { return nil }
        let first = syntax[0]
        if at > 0, run[at - 1] == first { return nil }
        if at + syntax.count < run.count, run[at + syntax.count] == first { return nil }
        return at
    }
}
