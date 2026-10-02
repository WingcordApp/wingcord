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
    /// What a click on a link does. Nil draws links as ordinary accent text and
    /// takes no clicks, which is the honest answer on a surface with nothing to
    /// open them with — `INVARIANTS.md` §5.5.
    var onLink: ((String) -> Void)?
    /// Whether this prose's animated emoji may move at all, before the
    /// reader's own preferences are asked.
    ///
    /// **The DM column passes its hover.** It stays on screen for as long as
    /// the conversation does, and Discord plays a sidebar bio's emoji only
    /// while the pointer is on the sidebar (`animateOnHoverOrFocusOnly`).
    /// Everywhere else the prose was opened to be read, and plays.
    var animates = true

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
                        playsEmoji: animates,
                        onEmoji: onEmoji,
                        onLink: onLink
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
    var playsEmoji: Bool
    var onEmoji: ((EmojiRef) -> Void)?
    var onLink: ((String) -> Void)?

    var body: some View {
        FlowLayout(spacing: spacing) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .word(let text, let style, let destination):
                    ProseWord(
                        text: text,
                        style: style,
                        font: font,
                        color: color,
                        // **Offered only where it can be honoured.** A run with
                        // no destination, or a surface with no opener, gets
                        // plain text and no pointer — an inert control that
                        // looks live is exactly what §5.5 forbids.
                        open: destination.flatMap { url in
                            onLink.map { handler in { handler(url) } }
                        }
                    )
                case .emoji(let emoji):
                    ProseEmoji(
                        emoji: emoji,
                        side: emojiSide,
                        plays: playsEmoji,
                        onTap: onEmoji
                    )
                }
            }
        }
    }
}

/// One run of letters, and the click on it when it goes somewhere.
///
/// **Two branches rather than one always-tappable view.** A `Button` per word
/// would put a gesture responder behind every word of every bio in the app; the
/// overwhelming majority of runs are prose, and prose costs a `Text`.
private struct ProseWord: View {
    var text: String
    var style: ProseStyle
    var font: Font
    var color: Color
    var open: (() -> Void)?

    var body: some View {
        let label = Text(text)
            .font(style.font(base: font))
            .foregroundStyle(style.color(base: color))
            .strikethrough(style.inline.contains(.strikethrough))
            .underline(style.inline.contains(.underline))

        if let open {
            Button(action: open) { label.contentShape(.rect) }
                .buttonStyle(.plain)
                // The pointer is the affordance. A link that never changes the
                // cursor reads as coloured text, which is what the accent alone
                // was saying.
                .pointerStyle(.link)
        } else {
            label
        }
    }
}

/// One inline emoji, and the click that asks where it came from.
///
/// **The picture is `ExpressionGlyph`'s**, still and film alike — a standard
/// emoji is a segment too, so a click on it opens its card the way a custom
/// one's does: Discord's flyout for a default emoji.
private struct ProseEmoji: View {
    var emoji: EmojiRef
    var side: CGFloat
    /// Whether the moving form may play — the prose's own gate. The reader's
    /// preference and Reduce Motion are asked after it, by `AnimatedPicture`.
    var plays: Bool
    var onTap: ((EmojiRef) -> Void)?

    var body: some View {
        let art = ExpressionGlyph(emoji: emoji, side: side, plays: plays)
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
        /// A run of letters. The third field is where a click on it goes, and
        /// it is what makes a link in a bio a link rather than blue text.
        ///
        /// **On the word, not on the style.** `ProseStyle` decides how a run is
        /// drawn and is compared for equality across runs; a destination is per
        /// occurrence — two links in one bio share a style and go to different
        /// places.
        case word(String, ProseStyle, String?)
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

        func word(_ text: String, _ style: ProseStyle, _ destination: String? = nil) {
            emit(.word(text, style, destination))
        }

        func breakLine() {
            lines.append(current)
            current = []
        }

        func append(_ nodes: [InlineNode], style: ProseStyle, destination: String? = nil) {
            for node in nodes {
                switch node {
                case .text(let value):
                    for run in value.split(separator: " ", omittingEmptySubsequences: true) {
                        // A standard emoji leaves the word as a segment of its
                        // own, so it can be clicked — but not out of a link,
                        // where the whole run is the link.
                        guard destination == nil, run.contains(where: \.isEmojiCluster) else {
                            word(String(run), style, destination)
                            continue
                        }
                        var letters = ""
                        for character in run {
                            if character.isEmojiCluster {
                                if !letters.isEmpty { word(letters, style); letters = "" }
                                emit(.emoji(EmojiRef(name: String(character))))
                            } else {
                                letters.append(character)
                            }
                        }
                        if !letters.isEmpty { word(letters, style) }
                    }
                case .styled(let inline, let children):
                    append(children, style: style.adding(inline), destination: destination)
                case .code(let value):
                    word(value, style.asCode, destination)
                case .link(let label, let url):
                    // **The destination travels with the label.** It used to be
                    // discarded here, which drew every link in a bio in the
                    // accent colour with nothing behind it — a control that
                    // looks live and does nothing, which `INVARIANTS.md` §5.5
                    // exists to forbid.
                    append(label, style: style.asLink, destination: url)
                case .autoLink(let url):
                    word(url, style.asLink, url)
                case .customEmoji(let emoji):
                    emit(.emoji(emoji))
                case .userMention(let id):
                    let name = mentions?.userNames[id].map { "@\($0)" } ?? "@unknown"
                    word(name, style.asMention)
                case .roleMention(let id):
                    // Discord's words for a role nobody can name, as plain text.
                    if let role = mentions?.roles[id] {
                        word("@\(role.name)", style.asMention)
                    } else {
                        word("@unknown-role", style)
                    }
                case .channelMention(let id):
                    // Discord's word for a channel nobody here can name.
                    let name = mentions?.channels[id].map { "#\($0.name)" } ?? "#unknown"
                    word(name, style.asMention)
                case .commandMention(let name, _):
                    word("/\(name)", style.asMention)
                case .gameMention(let id):
                    word(mentions?.gameNames[id] ?? "unknown-game", style.asMention)
                case .staticRoute(let route, _):
                    // A place in a server, named as its chip names it.
                    for run in route.title.split(separator: " ") {
                        word(String(run), style.asMention)
                    }
                case .everyoneMention:
                    word("@everyone", style.asMention)
                case .hereMention:
                    word("@here", style.asMention)
                case .timestamp(let date, let timestampStyle):
                    // A moment in the reader's own zone and locale, which is why
                    // it is a node and not text.
                    word(timestampStyle.format(date), style.asMention)
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
                    word(String(line), style.asCode)
                    breakLine()
                }
            case .quote(let children):
                for child in children { append(child, style: style.asQuote) }
            case .list(let ordered, let start, let items):
                for (offset, item) in items.enumerated() {
                    word(ordered ? "\(start + offset)." : "•", style)
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
