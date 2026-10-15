import Foundation

/// What Discord makes of the escape codes in an `ansi` code block — the
/// colours, the weights and the lines a terminal would draw.
///
/// **A port of the parser Discord draws with today**, module `626551` (Shiki's
/// MIT `ansi-sequence-parser`), the one behind its `2026-03-arborium-highlight`
/// experiment — and the reason a block of `38;2;r;g;b` arrives in colour there
/// (Alex's image 20). The older reading, highlight.js's `ansi` grammar
/// (`319888`), knows thirty-odd codes and draws 24-bit colour as plain text;
/// everything it reads, this reads the same way.
///
/// Its rules, all kept, quirks included, because a block is somebody's
/// terminal output and the point is that it looks here as it looks there:
///
/// - **Every CSI is taken out of the text**, whatever it is — a cursor move
///   or an erase is removed and changes nothing.
/// - Only `m` with no intermediate bytes and no private marker (`<=>?`) styles.
/// - **Resets apply before sets**, whatever their order: `31;0` is red.
/// - `ESC[m`, an empty parameter, does nothing (a terminal would reset).
/// - Parameters split on `;` only; `38:2:…` reads as `38` with nothing after.
///
/// What a span carries is what the parser keeps. **What is drawn is less**:
/// Discord's style function (`768947`'s `OT`) draws colour, background, bold,
/// italic, underline, strikethrough and overline, and never dim, reverse or
/// hidden — see `isDrawn`.
public enum ANSIEscapes {

    /// A colour a span asks for.
    public enum Color: Hashable, Sendable {
        /// One of the sixteen the room supplies — 0–7, then the bright 8–15
        /// (black, red, green, yellow, blue, magenta, cyan, white).
        case named(Int)
        /// `38;5;n`: 0–15 are the room's sixteen again, 16–255 are fixed. An
        /// index past 255 is kept and resolves to nothing.
        case table(Int)
        /// `38;2;r;g;b`, each clamped to 0–255 as Discord's hex does.
        case rgb(red: UInt8, green: UInt8, blue: UInt8)
    }

    public struct Decorations: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let bold = Decorations(rawValue: 1 << 0)
        public static let dim = Decorations(rawValue: 1 << 1)
        public static let italic = Decorations(rawValue: 1 << 2)
        public static let underline = Decorations(rawValue: 1 << 3)
        public static let reverse = Decorations(rawValue: 1 << 4)
        public static let hidden = Decorations(rawValue: 1 << 5)
        public static let strikethrough = Decorations(rawValue: 1 << 6)
        public static let overline = Decorations(rawValue: 1 << 7)

        /// The ones Discord draws. Dim, reverse and hidden are read and
        /// carried, and change nothing on screen.
        public static let isDrawn: Decorations = [.bold, .italic, .underline, .strikethrough, .overline]
    }

    /// A run of text and the style it was written in.
    public struct Span: Hashable, Sendable {
        public var text: String
        public var foreground: Color?
        public var background: Color?
        public var decorations: Decorations

        public init(text: String, foreground: Color? = nil, background: Color? = nil, decorations: Decorations = []) {
            self.text = text
            self.foreground = foreground
            self.background = background
            self.decorations = decorations
        }
    }

    // MARK: Parsing

    /// The block's text cut into styled runs, its escapes gone. Empty runs are
    /// never produced; an empty or escape-only block is no spans at all.
    public static func spans(in text: String) -> [Span] {
        let bytes = Array(text.utf8)
        var spans: [Span] = []
        var foreground: Color?
        var background: Color?
        var decorations: Decorations = []
        var position = 0
        repeat {
            let found = nextSequence(in: bytes, from: position)
            let end = found?.start ?? bytes.count
            if end > position {
                spans.append(Span(
                    text: String(decoding: bytes[position..<end], as: UTF8.self),
                    foreground: foreground,
                    background: background,
                    decorations: decorations
                ))
            }
            guard let found else { break }
            let commands = Self.commands(found.parameters)
            for command in commands {
                switch command {
                case .resetAll:
                    foreground = nil
                    background = nil
                    decorations = []
                case .resetForeground: foreground = nil
                case .resetBackground: background = nil
                case .resetDecoration(let decoration): decorations.remove(decoration)
                default: break
                }
            }
            for command in commands {
                switch command {
                case .setForeground(let color): foreground = color
                case .setBackground(let color): background = color
                case .setDecoration(let decoration): decorations.insert(decoration)
                default: break
                }
            }
            position = found.end
        } while position < bytes.count
        return spans
    }

    /// The text with every escape sequence taken out — what the spans spell.
    public static func plainText(of text: String) -> String {
        spans(in: text).map(\.text).joined()
    }

    /// Discord's inline reading of an `ansi` block (`999915`): only its SGR
    /// sequences — `ESC[` digits and `;`/`:` separators, `m` — removed, as a
    /// reply's one-line preview shows it.
    public static func strippingStyleSequences(from text: String) -> String {
        guard text.utf8.contains(0x1B) else { return text }
        let bytes = Array(text.utf8)
        var kept: [UInt8] = []
        kept.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x1B, let end = styleSequenceEnd(in: bytes, at: index) {
                index = end
            } else {
                kept.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: kept, as: UTF8.self)
    }

    /// `\x1B\[(\d+(?:[:;]\d+)*)m` at `start`: one or more digits, then any
    /// number of a separator and more digits, then `m`.
    private static func styleSequenceEnd(in bytes: [UInt8], at start: Int) -> Int? {
        var index = start + 1
        guard index < bytes.count, bytes[index] == 0x5B else { return nil }
        index += 1
        func digits() -> Bool {
            let first = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            return index > first
        }
        guard digits() else { return nil }
        while index < bytes.count, bytes[index] == 0x3A || bytes[index] == 0x3B {
            let separator = index
            index += 1
            guard digits() else {
                index = separator
                break
            }
        }
        guard index < bytes.count, bytes[index] == 0x6D else { return nil }
        return index + 1
    }

    // MARK: The sequence

    private struct Found {
        var start: Int
        var end: Int
        /// The SGR parameters split on `;`, or empty for a sequence that only
        /// comes out of the text.
        var parameters: [Substring]
    }

    /// The next `ESC [ params* intermediates* final` at or after `position`
    /// (`/\x1B\[([0-?]*)([ -/]*)([@-~])/`). The three byte classes do not
    /// overlap, so the match at an escape is decided without backtracking; an
    /// escape that does not start one is skipped and the search goes on.
    private static func nextSequence(in bytes: [UInt8], from position: Int) -> Found? {
        var cursor = position
        while cursor < bytes.count {
            guard let escape = bytes[cursor...].firstIndex(of: 0x1B) else { return nil }
            var index = escape + 1
            guard index < bytes.count, bytes[index] == 0x5B else {
                cursor = escape + 1
                continue
            }
            index += 1
            let parametersStart = index
            while index < bytes.count, (0x30...0x3F).contains(bytes[index]) { index += 1 }
            let parametersEnd = index
            while index < bytes.count, (0x20...0x2F).contains(bytes[index]) { index += 1 }
            let hasIntermediates = index > parametersEnd
            guard index < bytes.count, (0x40...0x7E).contains(bytes[index]) else {
                cursor = escape + 1
                continue
            }
            let final = bytes[index]
            let parameters = String(decoding: bytes[parametersStart..<parametersEnd], as: UTF8.self)
            let styles = final == 0x6D
                && !hasIntermediates
                && !(parameters.first.map { "<=>?".contains($0) } ?? false)
            return Found(
                start: escape,
                end: index + 1,
                parameters: styles ? parameters.split(separator: ";", omittingEmptySubsequences: false) : []
            )
        }
        return nil
    }

    private enum Command {
        case resetAll
        case setDecoration(Decorations)
        case resetDecoration(Decorations)
        case setForeground(Color)
        case resetForeground
        case setBackground(Color)
        case resetBackground
    }

    /// `1`–`9` as Discord numbers them; 5 and 6 (blink) are not among them.
    private static func decoration(_ code: Int) -> Decorations? {
        switch code {
        case 1: .bold
        case 2: .dim
        case 3: .italic
        case 4: .underline
        case 7: .reverse
        case 8: .hidden
        case 9: .strikethrough
        default: nil
        }
    }

    private static func commands(_ parameters: [Substring]) -> [Command] {
        var queue = parameters[...]
        var commands: [Command] = []
        while let parameter = queue.popFirst() {
            // `if (!r) continue` — an empty parameter is skipped, which is
            // why `ESC[m` does nothing.
            guard !parameter.isEmpty, let code = leadingInteger(parameter) else { continue }
            switch code {
            case 0:
                commands.append(.resetAll)
            case 1...9:
                if let decoration = decoration(code) { commands.append(.setDecoration(decoration)) }
            case 10...29:
                if let decoration = decoration(code - 20) {
                    commands.append(.resetDecoration(decoration))
                    // Dim and bold share one intensity: 22 ends both.
                    if decoration == .dim { commands.append(.resetDecoration(.bold)) }
                }
            case 30...37:
                commands.append(.setForeground(.named(code - 30)))
            case 38:
                if let color = extendedColor(&queue) { commands.append(.setForeground(color)) }
            case 39:
                commands.append(.resetForeground)
            case 40...47:
                commands.append(.setBackground(.named(code - 40)))
            case 48:
                if let color = extendedColor(&queue) { commands.append(.setBackground(color)) }
            case 49:
                commands.append(.resetBackground)
            case 53:
                commands.append(.setDecoration(.overline))
            case 55:
                commands.append(.resetDecoration(.overline))
            case 90...97:
                commands.append(.setForeground(.named(code - 90 + 8)))
            case 100...107:
                commands.append(.setBackground(.named(code - 100 + 8)))
            default:
                break
            }
        }
        return commands
    }

    /// `38`/`48`'s operands: `2;r;g;b` or `5;n`. Anything else takes the
    /// first operand and gives nothing back — as Discord's does, which shifts
    /// the kind off the queue before looking at it.
    private static func extendedColor(_ queue: inout ArraySlice<Substring>) -> Color? {
        guard let kind = queue.popFirst() else { return nil }
        if kind == "2" {
            let operands = queue.prefix(3)
            queue = queue.dropFirst(operands.count)
            let values = operands.compactMap(leadingInteger)
            guard operands.count == 3, values.count == 3 else { return nil }
            func channel(_ value: Int) -> UInt8 { UInt8(min(255, max(0, value))) }
            return .rgb(red: channel(values[0]), green: channel(values[1]), blue: channel(values[2]))
        }
        if kind == "5" {
            // `if (t)` — an empty operand is no colour. `Number()` rather than
            // `parseInt`: the operand must be a whole number to name an index.
            guard let operand = queue.popFirst(), !operand.isEmpty else { return nil }
            guard let index = Int(operand) else { return .table(-1) }
            return .table(index)
        }
        return nil
    }

    /// `Number.parseInt` on what a parameter can hold (`0`–`9` and `:;<=>?`):
    /// the leading digits, or nil when there are none.
    private static func leadingInteger(_ text: Substring) -> Int? {
        var value = 0
        var sawDigit = false
        for byte in text.utf8 {
            guard (0x30...0x39).contains(byte) else { break }
            sawDigit = true
            value = value &* 10 &+ Int(byte - 0x30)
            if value > 1_000_000 { value = 1_000_000 }
        }
        return sawDigit ? value : nil
    }

    // MARK: The 256 table

    /// A fixed entry of the 256-colour table: the 6×6×6 cube from 16, then 24
    /// greys from 232. Nil for 0–15, which the room supplies, and for anything
    /// past the table.
    public static func tableRGB(_ index: Int) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        switch index {
        case 16...231:
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let cube = index - 16
            return (levels[cube / 36], levels[(cube / 6) % 6], levels[cube % 6])
        case 232...255:
            let grey = UInt8(8 + (index - 232) * 10)
            return (grey, grey, grey)
        default:
            return nil
        }
    }
}
