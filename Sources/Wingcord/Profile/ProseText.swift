import AppKit
import SwiftUI
import WingcordCore

/// Discord markdown, rendered in SwiftUI.
///
/// **The transcript's prose is drawn by CoreText; this is the other half.**
/// Everything outside the two canvases — a bio, a custom status, a server
/// description — was rendered with a plain `Text`, so `<:meow_love:12597…>`
/// arrived on screen as literal angle brackets and `<t:1784433600:t>` as a raw
/// epoch. Both are things people put in their bios constantly.
///
/// **A flow of segments rather than one concatenated `Text`, and that is what
/// buys the tap.** `Text` + `Text(Image)` gives perfect line breaking and no way
/// to know which emoji was clicked; a layout of per-word views gives a real
/// target for each picture, which is what makes "click an emoji to find out
/// where it is from" possible at all. The cost is one view per word, and a bio
/// is a few dozen — a price worth paying on a surface opened one at a time, and
/// one this app would never pay in a transcript.
///
/// The parse is cached process-wide: a profile card's body runs again on every
/// hover of every badge in it, and re-scanning the same bio each time is work
/// with a known answer.
struct ProseText: View {
    var markdown: String
    var font: Font
    var color: Color
    /// The side an inline custom emoji is drawn at. Derived by the caller from
    /// the text size, so a picture in a line of prose grows with the words.
    var emojiSide: CGFloat = 18
    /// Resolves mentions to names. Nil renders them in their placeholder form,
    /// which is what a surface with no session behind it can honestly say.
    var mentions: MentionContext?
    /// What a click on a custom emoji does. Nil makes them inert pictures.
    var onEmoji: ((EmojiRef) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.isEmpty {
                    // A blank line is a paragraph break somebody typed. It has
                    // to take space, or the four-line bio they wrote collapses
                    // into one block.
                    Color.clear.frame(height: 1)
                } else {
                    ProseLine(
                        segments: line,
                        font: font,
                        color: color,
                        emojiSide: emojiSide,
                        spacing: Self.spaceWidth(for: font),
                        onEmoji: onEmoji
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        // One plain string for one node, exactly as a transcript row carries —
        // letting the platform derive a label from a few dozen styled runs is
        // the cost `MarkdownDocument.plainText` exists to remove.
        .accessibilityLabel(Text(document.plainText))
    }

    private var document: MarkdownDocument { ProseCache.shared.document(for: markdown) }

    private var lines: [[ProseSegment]] { ProseSegment.lines(of: document, mentions: mentions) }

    /// A space's width in the drawn font, used as the flow's gap.
    ///
    /// Measured rather than guessed at a constant: the gap between two words in
    /// a flow layout IS the space between them, and a fixed four points reads as
    /// double-spaced at caption size and cramped at title size.
    private static func spaceWidth(for font: Font) -> CGFloat {
        TimelineLayoutEngine.measure(" ", font: NSFont.resolved(font))
    }
}

/// One line of prose.
///
/// Its own view so `FlowLayout`'s measurement cache belongs to the line rather
/// than to the whole block: a bio that changes one line re-measures one line.
private struct ProseLine: View {
    var segments: [ProseSegment]
    var font: Font
    var color: Color
    var emojiSide: CGFloat
    var spacing: CGFloat
    var onEmoji: ((EmojiRef) -> Void)?

    var body: some View {
        FlowLayout(spacing: spacing) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .word(let text, let style):
                    Text(text)
                        .font(style.font(base: font))
                        .foregroundStyle(style.color(base: color))
                        .strikethrough(style.inline.contains(.strikethrough))
                        .underline(style.inline.contains(.underline))
                case .emoji(let emoji):
                    ProseEmoji(emoji: emoji, side: emojiSide, onTap: onEmoji)
                }
            }
        }
    }
}

/// One inline custom emoji, and the click that asks where it came from.
private struct ProseEmoji: View {
    var emoji: EmojiRef
    var side: CGFloat
    var onTap: ((EmojiRef) -> Void)?

    var body: some View {
        let art = RemoteImage(
            url: emoji.id.flatMap { CDN.emoji(id: $0, animated: emoji.isAnimated, side: side) },
            side: side
        ) {
            // The box is reserved either way, so a line does not reflow when the
            // picture lands.
            Color.clear
        }
        .frame(width: side, height: side)

        if let onTap {
            Button { onTap(emoji) } label: { art.contentShape(.rect) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(":\(emoji.name):"))
        } else {
            art.accessibilityHidden(true)
        }
    }
}

// MARK: - Segments

/// One drawable piece of a line: a styled word, or a picture.
struct ProseSegment: Identifiable {
    enum Kind {
        case word(String, ProseStyle)
        case emoji(EmojiRef)
    }

    /// Position in the line. Stable because the line is rebuilt whole.
    let id: Int
    let kind: Kind

    /// Splits a document into lines of segments.
    ///
    /// Blocks become lines; a `lineBreak` inside one starts another. Everything
    /// the transcript understands is understood here, because it is the same
    /// tree — the only difference is what draws it.
    static func lines(of document: MarkdownDocument, mentions: MentionContext?) -> [[ProseSegment]] {
        var lines: [[ProseSegment]] = []
        var current: [ProseSegment] = []
        var counter = 0

        func emit(_ kind: Kind) {
            current.append(ProseSegment(id: counter, kind: kind))
            counter += 1
        }

        func breakLine() {
            lines.append(current)
            current = []
        }

        func append(_ nodes: [InlineNode], style: ProseStyle) {
            for node in nodes {
                switch node {
                case .text(let value):
                    for word in value.split(separator: " ", omittingEmptySubsequences: true) {
                        emit(.word(String(word), style))
                    }
                case .styled(let inline, let children):
                    append(children, style: style.adding(inline))
                case .code(let value):
                    emit(.word(value, style.asCode))
                case .link(let label, _):
                    append(label, style: style.asLink)
                case .autoLink(let url):
                    emit(.word(url, style.asLink))
                case .customEmoji(let emoji):
                    emit(.emoji(emoji))
                case .userMention(let id):
                    let name = mentions?.userNames[id].map { "@\($0)" } ?? "@unknown"
                    emit(.word(name, style.asMention))
                case .roleMention(let id):
                    let name = mentions?.roleNames[id].map { "@\($0)" } ?? "@role"
                    emit(.word(name, style.asMention))
                case .channelMention(let id):
                    let name = mentions?.channelNames[id].map { "#\($0)" } ?? "#channel"
                    emit(.word(name, style.asMention))
                case .commandMention(let name, _):
                    emit(.word("/\(name)", style.asMention))
                case .everyoneMention:
                    emit(.word("@everyone", style.asMention))
                case .hereMention:
                    emit(.word("@here", style.asMention))
                case .timestamp(let date, let timestampStyle):
                    // A moment in the reader's own zone and locale, which is why
                    // it is a node and not text.
                    emit(.word(Self.format(date, style: timestampStyle), style.asMention))
                case .lineBreak:
                    breakLine()
                }
            }
        }

        func append(_ block: BlockNode, style: ProseStyle) {
            switch block {
            case .paragraph(let nodes):
                append(nodes, style: style)
            case .heading(_, let nodes):
                append(nodes, style: style.asHeading)
            case .subtext(let nodes):
                append(nodes, style: style.asSubtext)
            case .codeBlock(_, let code):
                for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
                    emit(.word(String(line), style.asCode))
                    breakLine()
                }
            case .quote(let children):
                for child in children { append(child, style: style.asQuote) }
            case .list(let ordered, let start, let items):
                for (offset, item) in items.enumerated() {
                    emit(.word(ordered ? "\(start + offset)." : "•", style))
                    for child in item { append(child, style: style) }
                    breakLine()
                }
            }
        }

        for block in document.blocks {
            append(block, style: .body)
            breakLine()
        }
        // The trailing break always leaves one empty line behind it.
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// The same formatter vocabulary the transcript uses. Minute takes
    /// `.twoDigits` — the default-digits form renders minute zero as a bare `0`,
    /// so every time on the hour comes out as `22:0`.
    private static func format(_ date: Date, style: TimestampStyle) -> String {
        switch style {
        case .shortTime: date.formatted(.dateTime.hour().minute(.twoDigits))
        case .longTime: date.formatted(.dateTime.hour().minute(.twoDigits).second())
        case .shortDate: date.formatted(.dateTime.day().month().year())
        case .longDate: date.formatted(.dateTime.day().month(.wide).year())
        case .shortDateTime:
            date.formatted(.dateTime.day().month().year().hour().minute(.twoDigits))
        case .longDateTime:
            date.formatted(
                .dateTime.weekday(.wide).day().month(.wide).year().hour().minute(.twoDigits)
            )
        case .relative: date.formatted(.relative(presentation: .named))
        }
    }
}

/// How one run of prose is drawn.
struct ProseStyle: Equatable {
    var inline: InlineStyle = []
    var role: Role = .body

    enum Role: Equatable {
        case body
        case heading
        case subtext
        case code
        case link
        case mention
        case quote
    }

    static let body = ProseStyle()

    func adding(_ style: InlineStyle) -> ProseStyle {
        var copy = self
        copy.inline.formUnion(style)
        return copy
    }

    var asCode: ProseStyle { withRole(.code) }
    var asLink: ProseStyle { withRole(.link) }
    var asMention: ProseStyle { withRole(.mention) }
    var asHeading: ProseStyle { withRole(.heading) }
    var asSubtext: ProseStyle { withRole(.subtext) }
    var asQuote: ProseStyle { withRole(.quote) }

    private func withRole(_ role: Role) -> ProseStyle {
        var copy = self
        copy.role = role
        return copy
    }

    func font(base: Font) -> Font {
        var font = switch role {
        case .code: Font.system(.caption, design: .monospaced)
        case .heading: base.bold()
        case .subtext: Font.system(.caption2)
        default: base
        }
        if inline.contains(.bold) { font = font.bold() }
        if inline.contains(.italic) { font = font.italic() }
        return font
    }

    func color(base: Color) -> Color {
        switch role {
        case .link, .mention: Palette.accent
        case .subtext, .quote: InkColor.tertiary
        default:
            // A spoiler in a bio is concealed the same way it is in a message:
            // the text is there and unreadable until the reader asks.
            inline.contains(.spoiler) ? .clear : base
        }
    }
}

// MARK: - The parse cache

/// Parsed prose, held for the process.
///
/// A profile card's body runs again on every hover of every badge in it, and
/// re-scanning the same bio each time is work with a known answer. Bounded by
/// `NSCache`, which evicts under pressure on its own — these are strings, not
/// pixels, so the ceiling is generous and the cost of a miss is a rescan.
private final class ProseCache: @unchecked Sendable {
    static let shared = ProseCache()

    private let cache = NSCache<NSString, Box>()
    private let parser = MarkdownParser()
    private let lock = NSLock()

    private final class Box {
        let document: MarkdownDocument
        init(_ document: MarkdownDocument) { self.document = document }
    }

    private init() { cache.countLimit = 128 }

    func document(for markdown: String) -> MarkdownDocument {
        let key = markdown as NSString
        if let hit = cache.object(forKey: key) { return hit.document }
        lock.lock()
        defer { lock.unlock() }
        let parsed = parser.parse(markdown)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }
}

extension NSFont {
    /// The AppKit font a SwiftUI `Font` resolves to, for measurement only.
    ///
    /// SwiftUI does not publish this, and the flow's word gap has to be a real
    /// space in the real face or the prose reads double-spaced. The mapping
    /// covers the text styles this app actually draws prose in; anything else
    /// falls back to the body, which is the right shape if not the right size.
    static func resolved(_ font: Font) -> NSFont {
        switch font {
        case .caption: .preferredFont(forTextStyle: .caption1)
        case .caption2: .preferredFont(forTextStyle: .caption2)
        case .footnote: .preferredFont(forTextStyle: .footnote)
        case .subheadline: .preferredFont(forTextStyle: .subheadline)
        case .callout: .preferredFont(forTextStyle: .callout)
        case .headline: .preferredFont(forTextStyle: .headline)
        case .title3: .preferredFont(forTextStyle: .title3)
        default: .preferredFont(forTextStyle: .body)
        }
    }
}
