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
            ForEach(blocks) { block in
                ProseBlockView(block: block, context: drawing)
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

    private var blocks: [ProseBlock] { ProseBlock.blocks(of: document, mentions: mentions) }

    /// What every block draws with, resolved once per body.
    private var drawing: ProseDrawing {
        ProseDrawing(
            font: font,
            color: color,
            emojiSide: emojiSide,
            spacing: Self.spaceWidth(for: font),
            playsEmoji: animates,
            onEmoji: onEmoji,
            onLink: onLink
        )
    }

    /// A space's width in the drawn font, used as the flow's gap.
    ///
    /// Measured rather than guessed at a constant: the gap between two words in
    /// a flow layout IS the space between them, and a fixed four points reads as
    /// double-spaced at caption size and cramped at title size.
    private static func spaceWidth(for font: Font) -> CGFloat {
        TimelineLayoutEngine.measure(" ", font: NSFont.resolved(font))
    }
}

/// Everything a block needs to draw its words, handed down whole.
private struct ProseDrawing {
    var font: Font
    var color: Color
    var emojiSide: CGFloat
    var spacing: CGFloat
    var playsEmoji: Bool
    var onEmoji: ((EmojiRef) -> Void)?
    var onLink: ((String) -> Void)?
}

// MARK: - Blocks

/// One block, drawn the way the transcript draws it — **the same structure,
/// not a flattening of it.** A quote has its rule and keeps its ink, a heading
/// its size, a list its markers hung outside the words, a fenced block its box.
/// The flat version drew a quote as grey text and a list as a line with a dot
/// in it, which is what bios looked like until this.
private struct ProseBlockView: View {
    var block: ProseBlock
    var context: ProseDrawing

    var body: some View {
        switch block.kind {
        case .lines(let lines):
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.isEmpty {
                        // A blank line is a paragraph break somebody typed. It
                        // has to take space, or the four-line bio they wrote
                        // collapses into one block.
                        Color.clear.frame(height: 1)
                    } else {
                        ProseLine(segments: line, context: context)
                    }
                }
            }
        case .quote(let children):
            // `.blockquoteContainer`: a 4-point rule, then the words 12 points
            // in, in the text's own ink.
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ProsePlates.quoteRule)
                    .frame(width: MessageTextStyle.quoteRuleWidth)
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(children) { ProseBlockView(block: $0, context: context) }
                }
                .padding(.leading, MessageTextStyle.quoteIndent - MessageTextStyle.quoteRuleWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let markers, let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(verbatim: markers[index])
                            .font(context.font)
                            .foregroundStyle(InkColor.secondary)
                            .frame(minWidth: 12, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(item) { ProseBlockView(block: $0, context: context) }
                        }
                    }
                }
            }
            .padding(.leading, 4)
        case .code(let code):
            Text(verbatim: code)
                .font(.system(size: NSFont.resolved(context.font).pointSize * 0.875, design: .monospaced))
                .foregroundStyle(context.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ProsePlates.codeFill, in: .rect(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(ProsePlates.codeBorder, lineWidth: 1)
                }
        }
    }
}

/// The transcript's plate colours, for prose — `TextPlateInk`, read once per
/// draw so a bio and a message sit on the same greys.
private enum ProsePlates {
    static var quoteRule: Color { color(ThemeInk.current.plates.quoteRule) }
    static var codeFill: Color { color(ThemeInk.current.plates.codeFill) }
    static var codeBorder: Color { color(ThemeInk.current.plates.codeBorder) }
    static var mentionFill: Color { color(ThemeInk.current.plates.mentionFill) }
    static var timestampFill: Color { color(ThemeInk.current.plates.timestampFill) }
    static var spoilerHidden: Color { color(ThemeInk.current.plates.spoilerHidden) }

    private static func color(_ cgColor: CGColor) -> Color {
        Color(nsColor: NSColor(cgColor: cgColor) ?? .clear)
    }
}

/// One line of prose.
///
/// Its own view so `FlowLayout`'s measurement cache belongs to the line rather
/// than to the whole block: a bio that changes one line re-measures one line.
private struct ProseLine: View {
    var segments: [ProseSegment]
    var context: ProseDrawing

    var body: some View {
        FlowLayout(spacing: context.spacing) {
            ForEach(segments) { segment in
                segmentView(segment)
                    // A space only where one was written: pieces that touched
                    // in the text touch on screen, as Discord draws them.
                    .layoutValue(key: FlowGap.self, value: segment.joinsPrevious ? 0 : nil)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: ProseSegment) -> some View {
                switch segment.kind {
                case .word(let text, let style, let destination):
                    ProseWord(
                        text: text,
                        style: style,
                        font: context.font,
                        color: context.color,
                        // **Offered only where it can be honoured.** A run with
                        // no destination, or a surface with no opener, gets
                        // plain text and no pointer — an inert control that
                        // looks live is exactly what §5.5 forbids.
                        open: destination.flatMap { url in
                            context.onLink.map { handler in { handler(url) } }
                        }
                    )
                case .emoji(let emoji):
                    ProseEmoji(
                        emoji: emoji,
                        side: context.emojiSide,
                        plays: context.playsEmoji,
                        onTap: context.onEmoji
                    )
                case .chip(let parts, let style, let destination):
                    ProseWord(
                        text: "",
                        parts: parts,
                        style: style,
                        font: context.font,
                        color: context.color,
                        open: destination.flatMap { url in
                            context.onLink.map { handler in { handler(url) } }
                        }
                    )
                }
    }
}

/// One run of letters, and the click on it when it goes somewhere.
///
/// **Two branches rather than one always-tappable view.** A `Button` per word
/// would put a gesture responder behind every word of every bio in the app; the
/// overwhelming majority of runs are prose, and prose costs a `Text`.
///
/// **A run on a plate keeps it**: a timestamp on the grey the transcript gives
/// it, a mention on its tint, inline code in its box — and a spoiler under its
/// cover. The plate is the run's, so a three-word date is one pill.
private struct ProseWord: View {
    var text: String
    /// A chip's pieces, drawn in place of `text` when there are any — words
    /// and glyphs on one plate, so a "🔒 No Access" is one pill.
    var parts: [ProseChipPart] = []
    var style: ProseStyle
    var font: Font
    var color: Color
    var open: (() -> Void)?

    private var content: Text {
        guard !parts.isEmpty else { return Text(text) }
        return parts.reduce(Text(verbatim: "")) { line, part in
            switch part {
            case .text(let words, let italic):
                line + (italic ? Text(verbatim: words).italic() : Text(verbatim: words))
            case .symbol(let name):
                line + Text(Image(systemName: name))
            }
        }
    }

    var body: some View {
        let label = content
            .font(style.font(base: font))
            .foregroundStyle(style.color(base: color))
            .strikethrough(style.inline.contains(.strikethrough))
            .underline(style.inline.contains(.underline))
            .padding(.horizontal, style.plate == nil ? 0 : MessageTextStyle.chipPadding)
            .background {
                if let plate = style.plate {
                    RoundedRectangle(cornerRadius: plate == .code ? 4 : 3, style: .continuous)
                        .fill(plate.fill)
                        .overlay {
                            if plate == .code {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(ProsePlates.codeBorder, lineWidth: 1)
                            }
                        }
                }
            }

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

/// A block of prose, as `MarkdownDocument` has it: lines of words, a quote of
/// blocks, a list of items of blocks, or a fenced block.
struct ProseBlock: Identifiable {
    enum Kind {
        /// Lines of words. An empty line is a break somebody typed.
        case lines([[ProseSegment]])
        case quote([ProseBlock])
        /// Each item's marker — its number, or Discord's bullet — and its blocks.
        case list(markers: [String], items: [[ProseBlock]])
        case code(String)
    }

    let id: Int
    let kind: Kind

    /// The document's blocks, nested as it nests them. Everything the
    /// transcript understands is understood here, because it is the same tree
    /// — the only difference is what draws it.
    static func blocks(of document: MarkdownDocument, mentions: MentionContext?) -> [ProseBlock] {
        var counter = 0
        func nextID() -> Int {
            defer { counter += 1 }
            return counter
        }
        func convert(_ block: BlockNode, style: ProseStyle) -> ProseBlock {
            switch block {
            case .paragraph(let nodes):
                ProseBlock(id: nextID(), kind: .lines(ProseSegment.lines(of: nodes, style: style, mentions: mentions)))
            case .heading(let level, let nodes):
                ProseBlock(
                    id: nextID(),
                    kind: .lines(ProseSegment.lines(of: nodes, style: style.asHeading(level), mentions: mentions))
                )
            case .subtext(let nodes):
                ProseBlock(id: nextID(), kind: .lines(ProseSegment.lines(of: nodes, style: style.asSubtext, mentions: mentions)))
            case .codeBlock(_, let code):
                ProseBlock(id: nextID(), kind: .code(code))
            case .quote(let children):
                ProseBlock(id: nextID(), kind: .quote(children.map { convert($0, style: style) }))
            case .list(let ordered, let start, let items):
                ProseBlock(id: nextID(), kind: .list(
                    markers: items.indices.map { ordered ? "\(start + $0)." : "•" },
                    items: items.map { item in item.map { convert($0, style: style) } }
                ))
            }
        }
        return document.blocks.map { convert($0, style: .body) }
    }
}

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
        /// One of Discord's chips: a channel link or `<#id>` drawn as the place
        /// it names — its parts in order, on the mention plate, and where a
        /// click goes, if anywhere (`ProseSegment.channelChip`).
        case chip([ProseChipPart], ProseStyle, String?)
    }

    /// Position in the line. Stable because the line is rebuilt whole.
    let id: Int
    let kind: Kind
    /// No whitespace stood between this and the segment before it, so the two
    /// are drawn touching — a word and the emoji typed straight after it, or
    /// the pieces of a picture made of several custom emoji.
    var joinsPrevious = false

    /// Splits one block's words into lines; a `lineBreak` starts another.
    static func lines(of nodes: [InlineNode], style: ProseStyle, mentions: MentionContext?) -> [[ProseSegment]] {
        var lines: [[ProseSegment]] = []
        var current: [ProseSegment] = []
        var counter = 0
        /// Whether whitespace has been passed since the last segment.
        var passedSpace = false

        func emit(_ kind: Kind) {
            current.append(ProseSegment(
                id: counter,
                kind: kind,
                joinsPrevious: !current.isEmpty && !passedSpace
            ))
            counter += 1
            passedSpace = false
        }

        func word(_ text: String, _ style: ProseStyle, _ destination: String? = nil) {
            emit(.word(text, style, destination))
        }

        func breakLine() {
            lines.append(current)
            current = []
            passedSpace = false
        }

        func append(_ nodes: [InlineNode], style: ProseStyle, destination: String? = nil) {
            for node in nodes {
                switch node {
                case .text(let value):
                    // Walked a character at a time, so every segment knows
                    // whether a space came before it. A standard emoji leaves
                    // the word as a segment of its own, so it can be clicked —
                    // but not out of a link, where the whole run is the link.
                    var letters = ""
                    func flush() {
                        guard !letters.isEmpty else { return }
                        word(letters, style, destination)
                        letters = ""
                    }
                    for character in value {
                        if character == " " {
                            flush()
                            passedSpace = true
                        } else if destination == nil, character.isEmojiCluster {
                            flush()
                            emit(.emoji(EmojiRef(name: String(character))))
                        } else {
                            letters.append(character)
                        }
                    }
                    flush()
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
                    // A link into the account is a place, not a page on the
                    // web, and Discord draws it as a chip naming the place —
                    // in a bio or an event's place as in a message.
                    if let mentions, let link = ChannelLink.parse(url),
                       let chip = Self.channelChip(link, url: url, style: style, context: mentions) {
                        emit(chip)
                    } else {
                        word(url, style.asLink, url)
                    }
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
                    // The same chip a link draws: Discord's `<#id>` rule runs
                    // the channel through the identical builder.
                    if let mentions,
                       let chip = Self.channelChip(
                           ChannelLink(guildID: mentions.channels[id]?.guildID, channelID: id),
                           url: nil, style: style, context: mentions
                       ) {
                        emit(chip)
                    } else {
                        // Discord's word for a channel nobody here can name.
                        word("#unknown", style.asMention)
                    }
                case .commandMention(let name, _):
                    word("/\(name)", style.asMention)
                case .gameMention(let id):
                    word(mentions?.gameNames[id] ?? "unknown-game", style.asMention)
                case .staticRoute(let route, _):
                    // A place in a server, named as its chip names it — one
                    // plate, not one per word.
                    word(route.title, style.asMention)
                case .everyoneMention:
                    word("@everyone", style.asMention)
                case .hereMention:
                    word("@here", style.asMention)
                case .timestamp(let date, let timestampStyle):
                    // A moment in the reader's own zone and locale, which is
                    // why it is a node and not text — and **one** run on the
                    // transcript's grey plate, in the words' own ink. It was
                    // drawn in the accent, as if it were a link.
                    word(timestampStyle.format(date), style.asTimestamp)
                case .lineBreak:
                    breakLine()
                }
            }
        }

        append(nodes, style: style)
        breakLine()
        // The trailing break always leaves one empty line behind it.
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

// MARK: - Channel chips

/// One piece of a chip: words, or a glyph drawn in the words' own ink.
enum ProseChipPart: Equatable {
    case text(String, italic: Bool = false)
    case symbol(String)
}

extension ProseSegment {
    /// Discord's channel chip for prose, in the transcript's order
    /// (`MessageTextBuilder.Builder.appendChannelChip`, Discord's `F` and `k`
    /// in module `999915`):
    ///
    /// - a channel the reader cannot see reads "No Access", behind a lock, and
    ///   goes nowhere;
    /// - a category is not a destination, and is written as plain `#name`;
    /// - a conversation reads `@name › 💬`;
    /// - in this server: `#channel`, `#channel › 💬` for one message in it, or
    ///   `#forum › post` for one message in a post;
    /// - in another server: `Server › #channel`, or `Server › 💬`;
    /// - a channel nobody here can name reads *unknown*, after its server when
    ///   that is one the account is in.
    ///
    /// - Returns: nil where Discord leaves a link a plain URL.
    static func channelChip(
        _ link: ChannelLink,
        url: String?,
        style: ProseStyle,
        context: MentionContext
    ) -> Kind? {
        let mention = style.asMention
        guard let channel = link.threadID.flatMap({ context.channels[$0] })
            ?? context.channels[link.channelID]
        else {
            let server = link.guildID.flatMap { id in
                id == context.currentGuildID ? nil : context.guildNames[id]
            }
            let unknown: [ProseChipPart] = [.text("#"), .text("unknown", italic: true)]
            // A link still opens its URL; a bare mention of a channel nobody
            // can name has nowhere to go.
            return .chip(server.map { [.text(chipName($0))] + chevron + unknown } ?? unknown, mention, url)
        }
        guard channel.canView else {
            return .chip([.symbol("lock.fill"), .text(" No Access")], mention, nil)
        }
        guard channel.isMentionable else {
            return .word("#" + chipName(channel.name), style, nil)
        }
        guard let guildID = channel.guildID else {
            guard channel.isConversation else { return nil }
            return .chip(part(channel) + chevron + [message(isPost: false)], mention, url)
        }
        guard let server = context.guildNames[guildID] else {
            guard url == nil else { return nil }
            return .word("#unknown-channel", style, nil)
        }
        let hasMessage = link.messageID != nil
        if guildID == context.currentGuildID {
            if !hasMessage {
                return .chip(part(channel), mention, url)
            }
            if channel.isPost, let forum = channel.parentID.flatMap({ context.channels[$0] }) {
                return .chip(part(forum) + chevron + part(channel), mention, url)
            }
            return .chip(part(channel) + chevron + [message(isPost: channel.isPost)], mention, url)
        }
        let last = hasMessage && !channel.isPost ? [message(isPost: false)] : part(channel)
        return .chip([.text(chipName(server))] + chevron + last, mention, url)
    }

    private static let chevron: [ProseChipPart] = [.text(" "), .symbol("chevron.compact.right"), .text(" ")]

    private static func part(_ channel: LinkChannel) -> [ProseChipPart] {
        switch channel.kind {
        case .text: [.text("#" + chipName(channel.name))]
        case .directMessage: [.text("@" + chipName(channel.name))]
        default: [.symbol(channel.kind.symbolName), .text(" " + chipName(channel.name))]
        }
    }

    private static func message(isPost: Bool) -> ProseChipPart {
        .symbol(isPost ? "doc.text.fill" : "text.bubble.fill")
    }

    /// A name in a chip, cut at Discord's thirty-two characters.
    private static func chipName(_ name: String) -> String {
        name.count > 32 ? String(name.prefix(32)) + "…" : name
    }
}

/// How one run of prose is drawn.
struct ProseStyle: Equatable {
    var inline: InlineStyle = []
    var role: Role = .body

    enum Role: Equatable {
        case body
        /// `#`, `##`, `###` — Discord's sizes, as the transcript scales them.
        case heading(Int)
        case subtext
        case code
        case link
        case mention
        case timestamp
    }

    /// What a run sits on, if anything.
    enum Plate: Equatable {
        case mention
        case timestamp
        case code
        case spoiler

        var fill: Color {
            switch self {
            case .mention: ProsePlates.mentionFill
            case .timestamp: ProsePlates.timestampFill
            case .code: ProsePlates.codeFill
            case .spoiler: ProsePlates.spoilerHidden
            }
        }
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
    var asTimestamp: ProseStyle { withRole(.timestamp) }
    var asSubtext: ProseStyle { withRole(.subtext) }
    func asHeading(_ level: Int) -> ProseStyle { withRole(.heading(level)) }

    private func withRole(_ role: Role) -> ProseStyle {
        var copy = self
        copy.role = role
        return copy
    }

    var plate: Plate? {
        if inline.contains(.spoiler) { return .spoiler }
        switch role {
        case .mention: return .mention
        case .timestamp: return .timestamp
        case .code: return .code
        default: return nil
        }
    }

    func font(base: Font) -> Font {
        let size = NSFont.resolved(base).pointSize
        var font = switch role {
        case .code: Font.system(size: size * 0.875, design: .monospaced)
        // The transcript's own scales (`MessageTextStyle.heading`).
        case .heading(let level):
            Font.system(size: size * (level == 1 ? 1.42 : level == 2 ? 1.24 : 1.10), weight: .bold)
        case .subtext: Font.system(size: size * 0.8125)
        case .mention: base.weight(.medium)
        default: base
        }
        if inline.contains(.bold) { font = font.bold() }
        if inline.contains(.italic) { font = font.italic() }
        return font
    }

    func color(base: Color) -> Color {
        // A spoiler in a bio is concealed the same way it is in a message:
        // the text is there, under a cover, until the reader asks.
        if inline.contains(.spoiler) { return .clear }
        switch role {
        case .link, .mention: return Palette.accent
        case .subtext: return InkColor.tertiary
        default: return base
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
