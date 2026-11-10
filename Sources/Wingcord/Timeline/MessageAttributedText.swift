import AppKit
import CoreText
import Foundation
import Synchronization
import WingcordCore

/// Turns a parsed message into an attributed string CoreText can lay out.
///
/// Two properties matter more than anything else here:
///
/// **Inline emoji are `CTRunDelegate` placeholders, not views.** An object
/// replacement character carrying a run delegate reserves exactly the right
/// ascent, descent and width in the line, so the text wraps around the emoji
/// correctly and the painter draws the picture into the rect the delegate
/// reserved. The alternative — hosting a view per emoji — puts an AppKit view
/// inside every message that has one, which is the cost the canvas exists to
/// avoid.
///
/// **The plain label is folded here, once.** A message paragraph carries link
/// attributes on its mentions, its channel chips and its URLs, and the
/// accessibility layer re-resolves every such run into attributes on **every
/// render** — reaching localized bundle string tables to answer what font a run
/// is in, per run, per frame, whether or not anyone is using VoiceOver. One
/// plain `String` label on one accessibility node removes all of it.
/// `@unchecked Sendable`: `attributed` is an immutable `NSAttributedString` —
/// `finish()` copies the mutable builder output rather than handing out the
/// buffer it was assembling into, so nothing can mutate it after the fact.
nonisolated struct MessageText: @unchecked Sendable {
    /// What CoreText lays out.
    let attributed: NSAttributedString
    /// Custom emoji, by the character index of their placeholder.
    let inlineEmoji: [Int: EmojiRef]
    /// SF Symbols set in a run of text, by the character index of their
    /// placeholder.
    ///
    /// **The same run-delegate trick the emoji use, for the same reason.** A
    /// symbol reserves its own box in the line and the painter fills it, so text
    /// wraps around it correctly — where a literal character would be whatever
    /// the font happened to have and a hosted view would be an `NSView` inside
    /// every message that carries one.
    let inlineSymbols: [Int: String]
    /// Link destinations, by character range.
    let links: [LinkRun]
    /// Spoiler ranges, concealed until revealed.
    let spoilers: [NSRange]
    /// Runs that sit on a painted plate — a mention, a timestamp, inline code —
    /// in order of appearance. See `Plate`.
    let plates: [Plate]
    /// Each quote's whole range, for the rule drawn down its leading edge.
    let quotes: [NSRange]
    /// Each fenced block's whole range, for the box drawn around it.
    let codeBlocks: [NSRange]
    /// The folded plain text, for one accessibility node.
    let plainLabel: String
    /// Runs an `ansi` block draws a line over (`53`). CoreText has no
    /// overline, so the painter rules them from the measured lines.
    var overlines: [NSRange] = []
    /// Whether a fenced block in it was drawn plain while highlight.js is
    /// still answering — a row the transcript lays out again when it has
    /// (`CodeHighlighter.didLand`).
    var awaitsHighlighting = false
    /// The "(edited)" set after a changed message's words — see
    /// `appendingEditedMark(at:style:)`. Nil for every other text.
    var editedMark: EditedMark?

    /// Where a selection may reach: the end of the words, short of the
    /// "(edited)" after them, which is a fact about the message rather than
    /// part of what it says — a copy that took it along would paste it.
    var selectableLength: Int { editedMark?.bodyLength ?? attributed.length }

    struct EditedMark: Sendable {
        /// The marker's own characters, for the rectangle its tooltip
        /// answers over.
        var range: NSRange
        /// How long the words are without it.
        var bodyLength: Int
        /// When the words were last changed — what the tooltip says.
        var editedAt: Date
    }

    struct LinkRun: Sendable {
        var range: NSRange
        var target: LinkTarget
    }

    /// A run drawn on a plate of its own.
    ///
    /// **Painted, not attributed.** CoreText's `.backgroundColor` fills a flat
    /// box per glyph run: no corner, no hairline, no hover, and hard against
    /// the letters either side. Discord's chips have all four, so the builder
    /// records the run and its kind, reserves the chip's side padding in the
    /// line, and the painter draws the plate from the measured rectangles —
    /// with its colour resolved at paint time, so a theme change is a repaint.
    /// `@unchecked Sendable`: a role's plate carries `CGColor`s and a
    /// `CGGradient`, immutable once made — built with the layout, off the main
    /// actor, so a repaint allocates nothing.
    struct Plate: @unchecked Sendable {
        var range: NSRange
        var kind: Kind
        /// The air either side, which the first segment's plate reaches out to
        /// cover.
        var padding: CGFloat

        enum Kind {
            /// A person, a channel, `@everyone`, a command, a message link.
            /// Lights solid under the pointer, as Discord's `.interactive` does.
            case mention
            /// A role with a colour of its own: that colour at 10%, 30% under
            /// the pointer — Discord's inline style on a role mention.
            case role(fill: CGColor, hoverFill: CGColor)
            /// A role wearing a gradient: the plate in its first stop, and its
            /// glyphs painted through the gradient itself.
            case gradientRole(fill: CGColor, hoverFill: CGColor, gradient: CGGradient)
            /// `<t:…>` — the text's own ink on a grey plate.
            case timestamp
            /// Inline code: the code tint and a hairline.
            case code
            /// The words an AutoMod rule matched — Discord's `.highlight`,
            /// its yellow at 30% and nothing else: no corner, no air.
            case highlight
        }

        /// Whether the pointer changes it — the plates that are links.
        var isInteractive: Bool {
            switch kind {
            case .mention, .role, .gradientRole: true
            case .timestamp, .code, .highlight: false
            }
        }
    }

    enum LinkTarget: Hashable, Sendable {
        case url(String)
        case user(UserID)
        case role(RoleID)
        /// A channel, or one message in it — a `<#id>` mention or a link
        /// somebody pasted. A **destination inside the app** rather than a URL:
        /// followed by going there, not by handing it to a browser that would
        /// ask the reader to sign in again. The URL, when there is one, is
        /// where a channel this account cannot name is opened instead.
        case channelLink(ChannelLink, url: String?)
        /// A place in the server — `<id:guide>` — and the role, for
        /// `<id:linked-roles:123>`.
        case staticRoute(StaticRoute, itemID: UInt64?)
        /// A game — `<@$id>` — whose page the chip opens.
        case game(ApplicationID)
    }
}

// `nonisolated` on the extension, not on the member: the app target defaults to
// main-actor isolation, and an extension that inherits it puts an actor hop in
// front of a value initialiser the layout engine calls dozens of times per
// embed — off the main actor by construction. See `INVARIANTS.md` §5.
nonisolated extension MessageText {
    /// A run of already-styled text with no markdown behind it.
    ///
    /// The pieces of an embed — an author's name, a title, a footer — are plain
    /// strings in known styles, and running them through the markdown builder
    /// would be a parse per part per embed to discover there is nothing to
    /// parse. They still become a `TimelineTextBlock`, so they wrap, measure and
    /// hit-test exactly like a message body does.
    static func plain(_ attributed: NSAttributedString, links: [LinkRun] = []) -> MessageText {
        MessageText(
            attributed: attributed,
            inlineEmoji: [:],
            inlineSymbols: [:],
            links: links,
            spoilers: [],
            plates: [],
            quotes: [],
            codeBlocks: [],
            plainLabel: attributed.string
        )
    }

    /// Pieces built apart — a sentence's words and a channel's chip — as one
    /// text, every range moved to where its piece now starts.
    static func joined(_ pieces: [MessageText]) -> MessageText {
        let attributed = NSMutableAttributedString()
        var inlineEmoji: [Int: EmojiRef] = [:]
        var inlineSymbols: [Int: String] = [:]
        var links: [LinkRun] = []
        var spoilers: [NSRange] = []
        var plates: [Plate] = []
        var quotes: [NSRange] = []
        var codeBlocks: [NSRange] = []
        var overlines: [NSRange] = []
        var awaits = false
        var label = ""
        for piece in pieces {
            let offset = attributed.length
            func moved(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
            attributed.append(piece.attributed)
            for (index, emoji) in piece.inlineEmoji { inlineEmoji[index + offset] = emoji }
            for (index, symbol) in piece.inlineSymbols { inlineSymbols[index + offset] = symbol }
            links += piece.links.map { LinkRun(range: moved($0.range), target: $0.target) }
            spoilers += piece.spoilers.map(moved)
            plates += piece.plates.map { Plate(range: moved($0.range), kind: $0.kind, padding: $0.padding) }
            quotes += piece.quotes.map(moved)
            codeBlocks += piece.codeBlocks.map(moved)
            overlines += piece.overlines.map(moved)
            awaits = awaits || piece.awaitsHighlighting
            label += piece.plainLabel
        }
        return MessageText(
            attributed: attributed,
            inlineEmoji: inlineEmoji,
            inlineSymbols: inlineSymbols,
            links: links,
            spoilers: spoilers,
            plates: plates,
            quotes: quotes,
            codeBlocks: codeBlocks,
            plainLabel: label,
            overlines: overlines,
            awaitsHighlighting: awaits
        )
    }

    /// The same text with `ranges` lit as Discord lights what an AutoMod rule
    /// matched. Kept in the plates' order of appearance, which the painter's
    /// walk assumes.
    func highlighting(_ ranges: [NSRange]) -> MessageText {
        guard !ranges.isEmpty else { return self }
        let added = ranges.map { Plate(range: $0, kind: .highlight, padding: 0) }
        return MessageText(
            attributed: attributed,
            inlineEmoji: inlineEmoji,
            inlineSymbols: inlineSymbols,
            links: links,
            spoilers: spoilers,
            plates: (plates + added).sorted { $0.range.location < $1.range.location },
            quotes: quotes,
            codeBlocks: codeBlocks,
            plainLabel: plainLabel,
            overlines: overlines,
            awaitsHighlighting: awaitsHighlighting,
            editedMark: editedMark
        )
    }

    /// The words up to `length` and an ellipsis after them: what text clamped to a
    /// number of lines draws. Every range is cut to what is left.
    func truncated(to length: Int, ellipsis attributes: [NSAttributedString.Key: Any]) -> MessageText {
        let end = min(max(0, length), attributed.length)
        let cut = NSMutableAttributedString(
            attributedString: attributed.attributedSubstring(from: NSRange(location: 0, length: end))
        )
        cut.append(NSAttributedString(string: "\u{2026}", attributes: attributes))
        func clipped(_ range: NSRange) -> NSRange? {
            guard range.location < end else { return nil }
            return NSRange(location: range.location, length: min(range.length, end - range.location))
        }
        return MessageText(
            attributed: cut,
            inlineEmoji: inlineEmoji.filter { $0.key < end },
            inlineSymbols: inlineSymbols.filter { $0.key < end },
            links: links.compactMap { run in clipped(run.range).map { LinkRun(range: $0, target: run.target) } },
            spoilers: spoilers.compactMap(clipped),
            plates: plates.compactMap { plate in
                clipped(plate.range).map { Plate(range: $0, kind: plate.kind, padding: plate.padding) }
            },
            quotes: quotes.compactMap(clipped),
            codeBlocks: codeBlocks.compactMap(clipped),
            plainLabel: plainLabel,
            overlines: overlines.compactMap(clipped),
            awaitsHighlighting: awaitsHighlighting
        )
    }

    /// The same words with Discord's "(edited)" after the last of them.
    ///
    /// **In the words, not beside them**, so it wraps where they wrap: on the
    /// last line while it fits there, on a line of its own when it does not —
    /// and a bubble that hugs its words takes it in with them. After a fenced
    /// block it starts a line of its own, as Discord's does under the block,
    /// or the block's box would take it in.
    func appendingEditedMark(at editedAt: Date, style: MessageTextStyle) -> MessageText {
        let output = NSMutableAttributedString(attributedString: attributed)
        let bodyLength = output.length
        let endsInBlock = codeBlocks.last.map { NSMaxRange($0) >= bodyLength } ?? false
        output.append(NSAttributedString(string: endsInBlock ? "\n" : " ", attributes: style.editedMark))
        let range = NSRange(location: output.length, length: (Self.editedWord as NSString).length)
        output.append(NSAttributedString(string: Self.editedWord, attributes: style.editedMark))
        return MessageText(
            attributed: output,
            inlineEmoji: inlineEmoji,
            inlineSymbols: inlineSymbols,
            links: links,
            spoilers: spoilers,
            plates: plates,
            quotes: quotes,
            codeBlocks: codeBlocks,
            plainLabel: plainLabel,
            overlines: overlines,
            awaitsHighlighting: awaitsHighlighting,
            editedMark: EditedMark(range: range, bodyLength: bodyLength, editedAt: editedAt)
        )
    }

    /// Discord's word for it, in its parentheses (`C8sXIM`, "edited").
    static let editedWord = "(edited)"
}

/// Everything the builder needs from the session to resolve a mention into a
/// name. A value, so building a message's text never touches the store.
nonisolated struct MentionContext: Sendable {
    var userNames: [UserID: String] = [:]
    /// Every role the account can see, **in every server**, by id.
    ///
    /// Not the selected server's: Discord resolves a role mention against the
    /// message's own channel, and a role id is a snowflake no other server
    /// shares — so one table keyed by id answers for the inbox, search and a
    /// forwarded message exactly as it does for the transcript, where a table of
    /// the selected server's roles drew every other server's as "@role".
    var roles: [RoleID: MentionRole] = [:]
    /// Every channel the account knows, for the chips `<#id>` mentions and
    /// channel links draw — see `LinkChannel`. **Shared, not copied**: it is
    /// memoized on the channel tree alone (`AppModel.linkChannelTable`), so a
    /// context rebuilt for a roster change hands on the same buffer.
    var channels: [ChannelID: LinkChannel] = [:]
    /// Server names, for a chip pointing into another server.
    var guildNames: [GuildID: String] = [:]
    /// The server the text is drawn in. A chip into any other names its
    /// server first — Discord's rule.
    var currentGuildID: GuildID?
    /// The reader's own ids, so a mention of them is drawn differently.
    var selfIDs: Set<UInt64> = []
    /// The games `<@$id>` mentions name — only those, so a board loading its
    /// fifty games does not relay every row in the transcript.
    var gameNames: [ApplicationID: String] = [:]

    /// A token that changes whenever any of the above could change.
    ///
    /// **This is the memo key, and it has to carry every input.** A cache keyed
    /// on the message text alone serves whichever surface rendered it first — so
    /// an embed rendered in a context with no names caches the placeholder form
    /// (`@user`, `#channel`) and the transcript then serves that to everyone,
    /// forever. Closures have no identity to hash; a generation does.
    ///
    /// **A context that names only some people leaves them out of it**
    /// (`AppModel.mentionContext(naming:)`): whoever keys on that one checks the
    /// names it used itself, as the transcript's rows do.
    var token: UInt64 = 0
    /// Where the user mentions looked up here are noted, for a caller that
    /// checks a cached text against the names it was set from. Nil everywhere
    /// else. See `MentionLookups`.
    var lookups: MentionLookups?
}

/// Which user mentions a builder asked a context about.
///
/// **The names a row was set from are part of what it was laid out against.**
/// The row cache keyed on a counter that moved whenever any user record
/// anywhere changed, so a stranger writing in another server relaid every
/// loaded row of the open transcript. A row now remembers the few names its
/// words asked for, and this is how the layout engine learns which those were
/// without every builder reporting them.
nonisolated final class MentionLookups: Sendable {
    private struct State {
        var pending: [UserID] = []
        var pass: Set<UserID> = []
    }

    private let state = Mutex(State())

    /// A builder looked this person up.
    func note(_ userID: UserID) {
        state.withLock { $0.pending.append(userID) }
    }

    /// Everybody looked up since the last call.
    func take() -> [UserID] {
        state.withLock { state in
            let taken = state.pending
            state.pending = []
            return taken
        }
    }

    /// Everybody one layout pass's rows name: those it built, and those it
    /// took from its cache.
    func finishPass(_ asked: Set<UserID>) {
        state.withLock { $0.pass = asked }
    }

    var askedInPass: Set<UserID> {
        state.withLock { $0.pass }
    }
}

/// What a channel chip needs to know about one channel.
nonisolated struct LinkChannel: Sendable {
    var name: String
    /// Nil for a conversation.
    var guildID: GuildID?
    var kind: ChannelKind
    /// Whether the reader may open it. A chip for one they may not reads
    /// "No Access", as Discord's does.
    var canView: Bool
    /// A forum or media post, which Discord names beside its forum.
    var isPost: Bool
    var parentID: ChannelID?

    /// Discord's `isMentionable`: everything but a category.
    var isMentionable: Bool { kind != .category && kind != .unknown }
    var isConversation: Bool { kind == .directMessage || kind == .groupDirectMessage }
}

/// What a role mention draws: the name, and the colour or gradient it wears —
/// each already through the reader's role-colour settings, so nil where the
/// mention is drawn in the plain mention ink.
nonisolated struct MentionRole: Sendable {
    var name: String
    var color: UInt32?
    var gradient: [UInt32]?
}

nonisolated enum MessageTextBuilder {

    /// Builds the attributed form.
    ///
    /// `nonisolated` and free of store access, so it can run on the layout task
    /// rather than on the main actor.
    static func build(
        document: MarkdownDocument,
        context: MentionContext,
        style: MessageTextStyle
    ) -> MessageText {
        var builder = Builder(context: context, style: style)
        builder.append(document.blocks)
        return builder.finish(plainLabel: document.plainText)
    }

    private struct Builder {
        let context: MentionContext
        let style: MessageTextStyle
        var output = NSMutableAttributedString()
        var inlineEmoji: [Int: EmojiRef] = [:]
        var inlineSymbols: [Int: String] = [:]
        var links: [MessageText.LinkRun] = []
        var spoilers: [NSRange] = []
        var plates: [MessageText.Plate] = []
        var quotes: [NSRange] = []
        var codeBlocks: [NSRange] = []
        var overlines: [NSRange] = []
        var awaitsHighlighting = false
        /// Whether the blocks being appended are inside a quote, whose own text
        /// is drawn in the subtle ink.
        var inQuote = false

        mutating func append(_ blocks: [BlockNode]) {
            for (index, block) in blocks.enumerated() {
                if index > 0 { appendRaw("\n", attributes: style.body) }
                append(block)
            }
        }

        mutating func append(_ block: BlockNode) {
            switch block {
            case .paragraph(let nodes):
                append(nodes, attributes: inQuote ? style.quoteBody : style.body)
            case .heading(let level, let nodes):
                append(nodes, attributes: style.heading(level: level))
            case .subtext(let nodes):
                append(nodes, attributes: style.subtext)
            case .codeBlock(let language, let code):
                let start = output.length
                if language?.lowercased() == "ansi" {
                    appendANSI(code)
                } else if let language, !language.isEmpty {
                    appendHighlighted(code, language: language)
                } else {
                    appendRaw(code, attributes: style.codeBlock)
                }
                let range = NSRange(location: start, length: output.length - start)
                guard range.length > 0 else { return }
                codeBlocks.append(range)
                // The box's margin and padding, on the first and last line —
                // every line of a block is a paragraph to CoreText.
                setMargins(
                    of: range,
                    base: style.codeBlock[.paragraphStyle] as? NSParagraphStyle,
                    before: style.codeBlockLeading,
                    after: style.codeBlockPadding + style.paragraphSpacing
                )
            case .quote(let children):
                // The rule is painted from the quote's measured lines; here the
                // quote is an indent, so the text wraps inside the rule rather
                // than under it.
                let start = output.length
                let wasInQuote = inQuote
                inQuote = true
                append(children)
                inQuote = wasInQuote
                let range = NSRange(location: start, length: output.length - start)
                guard range.length > 0 else { return }
                quotes.append(range)
                output.addAttribute(.paragraphStyle, value: style.quoteParagraph, range: range)
                setMargins(
                    of: range,
                    base: style.quoteParagraph,
                    before: MessageTextStyle.quoteMargin,
                    after: MessageTextStyle.quoteMargin + style.paragraphSpacing
                )
            case .list(let ordered, let startIndex, let items):
                // Discord's indent (`.markup ul`, `ol`): 1em for bullets, and
                // for numbers `.4em` and `.6em` a digit of the longest.
                let digits = String(startIndex + max(0, items.count - 1)).count
                let em = style.bodyFont.pointSize
                let indent = ordered ? em * (0.4 + 0.6 * CGFloat(digits)) : em
                for (offset, item) in items.enumerated() {
                    if offset > 0 { appendRaw("\n", attributes: style.body) }
                    let start = output.length
                    let marker = ordered ? "\(startIndex + offset). " : "• "
                    let markerText = NSAttributedString(string: marker, attributes: style.listMarker)
                    appendRaw(marker, attributes: style.listMarker)
                    for child in item { append(child) }
                    let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(markerText), nil, nil, nil))
                    output.addAttribute(
                        .paragraphStyle,
                        value: style.listParagraph(marker: width, indent: indent),
                        range: NSRange(location: start, length: output.length - start)
                    )
                }
            }
        }

        /// Gives a block's first line the space above it and its last line the
        /// space below, keeping `base` for everything else.
        mutating func setMargins(
            of range: NSRange,
            base: NSParagraphStyle?,
            before: CGFloat,
            after: CGFloat
        ) {
            guard let base else { return }
            let text = output.mutableString
            let first = text.paragraphRange(for: NSRange(location: range.location, length: 0))
            let last = text.paragraphRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
            if first == last {
                output.addAttribute(
                    .paragraphStyle,
                    value: style.paragraph(base, before: before, after: after),
                    range: first
                )
            } else {
                output.addAttribute(
                    .paragraphStyle, value: style.paragraph(base, before: before), range: first
                )
                output.addAttribute(
                    .paragraphStyle, value: style.paragraph(base, after: after), range: last
                )
            }
        }

        mutating func append(_ nodes: [InlineNode], attributes: [NSAttributedString.Key: Any]) {
            for node in nodes {
                switch node {
                case .text(let value):
                    appendRaw(value, attributes: attributes)

                case .styled(let inlineStyle, let children):
                    var merged = attributes
                    style.apply(inlineStyle, to: &merged)
                    let start = output.length
                    append(children, attributes: merged)
                    if inlineStyle.contains(.spoiler), output.length > start {
                        spoilers.append(NSRange(location: start, length: output.length - start))
                    }

                case .code(let value):
                    let start = beginPlate(padding: style.codePadding)
                    appendRaw(value, attributes: style.inlineCode)
                    endPlate(from: start, kind: .code, padding: style.codePadding)

                case .link(let label, let url):
                    let start = output.length
                    append(label, attributes: style.link(base: attributes))
                    links.append(.init(
                        range: NSRange(location: start, length: output.length - start),
                        target: .url(url)
                    ))

                case .autoLink(let url):
                    // A link into this account is a place, not a page on the
                    // web, and Discord draws it as a chip naming the place.
                    if let link = ChannelLink.parse(url),
                       appendChannelChip(link, url: url, base: attributes)
                    {
                        continue
                    }
                    let start = output.length
                    appendRaw(url, attributes: style.link(base: attributes))
                    links.append(.init(
                        range: NSRange(location: start, length: output.length - start),
                        target: .url(url)
                    ))

                case .userMention(let userID):
                    context.lookups?.note(userID)
                    let name = context.userNames[userID].map { "@\($0)" } ?? "@unknown"
                    appendMention(name, base: attributes, target: .user(userID))

                case .roleMention(let roleID):
                    // **An unknown role is text, not a chip** — Discord's own
                    // words, and no plate or link claiming a destination the
                    // reader cannot open.
                    guard let role = context.roles[roleID] else {
                        appendRaw("@unknown-role", attributes: attributes)
                        continue
                    }
                    let kind = Self.plateKind(for: role)
                    appendMention(
                        "@\(role.name)",
                        base: attributes,
                        tint: role.gradient?.first ?? role.color,
                        kind: kind,
                        target: .role(roleID)
                    )

                case .channelMention(let channelID):
                    // The same chip a link draws: Discord's `<#id>` rule runs
                    // the channel through the identical builder.
                    let link = ChannelLink(
                        guildID: context.channels[channelID]?.guildID, channelID: channelID
                    )
                    appendChannelChip(link, url: nil, base: attributes)

                case .staticRoute(let route, let itemID):
                    appendStaticRoute(route, itemID: itemID, base: attributes)

                case .commandMention(let name, _):
                    appendMention("/\(name)", base: attributes)

                case .gameMention(let gameID):
                    // Discord's chip (`266645`): the game's mark and its name,
                    // "unknown-game" until the game is known.
                    let start = beginPlate(padding: MessageTextStyle.chipPadding)
                    appendInlineSymbol("gamecontroller.fill", base: attributes)
                    appendRaw(
                        " " + (context.gameNames[gameID] ?? "unknown-game"),
                        attributes: style.mention(base: attributes)
                    )
                    endPlate(
                        from: start, kind: .mention, padding: MessageTextStyle.chipPadding,
                        target: .game(gameID)
                    )

                case .everyoneMention:
                    appendMention("@everyone", base: attributes)

                case .hereMention:
                    appendMention("@here", base: attributes)

                case .customEmoji(let emoji):
                    appendInlineEmoji(emoji, base: attributes)

                case .timestamp(let date, let timestampStyle):
                    let start = beginPlate(padding: MessageTextStyle.chipPadding)
                    appendRaw(timestampStyle.format(date), attributes: attributes)
                    endPlate(from: start, kind: .timestamp, padding: MessageTextStyle.chipPadding)

                case .lineBreak:
                    appendRaw("\n", attributes: attributes)
                }
            }
        }

        mutating func appendRaw(_ value: String, attributes: [NSAttributedString.Key: Any]) {
            guard !value.isEmpty else { return }
            output.append(NSAttributedString(string: value, attributes: attributes))
        }

        /// An `ansi` block, as Discord draws one (`768947`'s `OT` over the
        /// spans of `626551` — see `ANSIEscapes`): each run in its colour, on
        /// its background, bold, italic, underlined, struck or overlined; dim,
        /// reverse and hidden read and not drawn. The escapes themselves are
        /// gone from the text.
        mutating func appendANSI(_ code: String) {
            let base = style.codeBlock
            let palette = style.codePalette
            let font = style.codeBlockFont
            for span in ANSIEscapes.spans(in: code) {
                var attributes = base
                if let color = span.foreground.flatMap(palette.color(for:)) {
                    attributes[.foregroundColor] = color
                }
                if let color = span.background.flatMap(palette.color(for:)) {
                    attributes[.backgroundColor] = color
                }
                let bold = span.decorations.contains(.bold)
                let italic = span.decorations.contains(.italic)
                if bold || italic {
                    attributes[.font] = Self.codeFace(font, bold: bold, italic: italic)
                }
                if span.decorations.contains(.underline) {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if span.decorations.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                let start = output.length
                appendRaw(span.text, attributes: attributes)
                if span.decorations.contains(.overline), output.length > start {
                    overlines.append(NSRange(location: start, length: output.length - start))
                }
            }
        }

        /// A fenced block in a language, highlighted as Discord highlights it
        /// (REDESIGN.md D2) — when highlight.js has answered. **A layout cannot
        /// wait**, so a block it has not answered for is drawn plain, asked
        /// about, and marked: the row is laid again when the answer lands, at
        /// the same height, because the faces are monospaced at one width.
        mutating func appendHighlighted(_ code: String, language: String) {
            let start = output.length
            appendRaw(code, attributes: style.codeBlock)
            guard !code.isEmpty else { return }
            switch CodeHighlighter.shared.cachedTokens(for: code, language: language) {
            case .some(.some(let tokens)):
                let block = NSMutableAttributedString(attributedString: output.attributedSubstring(
                    from: NSRange(location: start, length: output.length - start)
                ))
                block.applyHighlighting(tokens, palette: style.codePalette, font: style.codeBlockFont)
                output.replaceCharacters(in: NSRange(location: start, length: output.length - start), with: block)
            case .some(.none):
                break
            case .none:
                CodeHighlighter.shared.prefetch(code, language: language)
                awaitsHighlighting = true
            }
        }

        /// The block's monospaced face, bolder or slanted.
        private static func codeFace(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
            var face = bold ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold) : font
            if italic {
                let traits = face.fontDescriptor.symbolicTraits.union(.italic)
                face = NSFont(descriptor: face.fontDescriptor.withSymbolicTraits(traits), size: face.pointSize) ?? face
            }
            return face
        }

        /// A role's plate: its colour, or its gradient, or the plain mention
        /// plate for a role that wears no colour at all.
        private static func plateKind(for role: MentionRole) -> MessageText.Plate.Kind {
            guard let first = role.gradient?.first ?? role.color else { return .mention }
            let fill = cgColor(first, alpha: 0.1)
            let hoverFill = cgColor(first, alpha: 0.3)
            if let stops = role.gradient,
               let gradient = CGGradient(
                   colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: stops.map { cgColor($0, alpha: 1) } as CFArray,
                   locations: nil
               )
            {
                return .gradientRole(fill: fill, hoverFill: hoverFill, gradient: gradient)
            }
            return .role(fill: fill, hoverFill: hoverFill)
        }

        private static func cgColor(_ packed: UInt32, alpha: CGFloat) -> CGColor {
            CGColor(
                srgbRed: CGFloat((packed >> 16) & 0xFF) / 255,
                green: CGFloat((packed >> 8) & 0xFF) / 255,
                blue: CGFloat(packed & 0xFF) / 255,
                alpha: alpha
            )
        }

        mutating func appendMention(
            _ label: String,
            base: [NSAttributedString.Key: Any],
            tint: UInt32? = nil,
            kind: MessageText.Plate.Kind = .mention,
            target: MessageText.LinkTarget? = nil
        ) {
            let start = beginPlate(padding: MessageTextStyle.chipPadding)
            appendRaw(label, attributes: style.mention(base: base, tint: tint))
            endPlate(from: start, kind: kind, padding: MessageTextStyle.chipPadding, target: target)
        }

        /// One piece of a channel chip.
        private enum ChipPart {
            case guild(String)
            case channel(LinkChannel)
            /// A channel this account cannot name — Discord's italic "unknown".
            case unknownChannel
            /// One message, or one post, in the channel named before it.
            case message(isPost: Bool)
            /// A place in the server: its glyph and its name.
            case place(symbol: String, title: String)
            /// A name and nothing else — the role a linked-roles chip names.
            case name(String)
        }

        /// Discord's `staticRouteLink` — `<id:guide>` — as the chip a channel
        /// mention is, led by the place's glyph: "Server Guide", "Browse
        /// Channels", "Channels & Roles", or "Linked Roles › Role" when it
        /// names a role (modules `78390` and `999915`).
        ///
        /// **The sidebar's glyphs for the same places**, so the chip and the
        /// row it leads to read as one destination; Discord does the same with
        /// its own icons.
        mutating func appendStaticRoute(
            _ route: StaticRoute, itemID: UInt64?, base: [NSAttributedString.Key: Any]
        ) {
            let symbol = switch route {
            case .home, .guide: "signpost.right.fill"
            case .browse, .customize: "square.grid.2x2"
            case .linkedRoles: "link"
            }
            let place = ChipPart.place(symbol: symbol, title: route.title)
            let target = MessageText.LinkTarget.staticRoute(route, itemID: itemID)
            // Discord names the role only on a linked-roles chip, and only one
            // it can find.
            if route == .linkedRoles,
               let name = itemID.flatMap({ context.roles[RoleID(rawValue: $0)]?.name })
            {
                appendChip(place, .name(name), base: base, target: target)
            } else {
                appendChip(nil, place, base: base, target: target)
            }
        }

        /// Discord's channel chip, `F` and `k` beside `channelOrMessageUrl` in
        /// its markdown rules (module `999915`), in its order:
        ///
        /// - a channel the reader cannot see reads "No Access", behind a lock;
        /// - a category is not a destination, and is written as plain `#name`;
        /// - a conversation reads `@name › 💬`;
        /// - in this server: `#channel`, or `#channel › 💬` for one message in
        ///   it, or `#forum › post` for one message in a post;
        /// - in another server: `Server › #channel`, or `Server › 💬`;
        /// - a channel nobody here can name reads *unknown*, after its server
        ///   when that is one the account is in.
        ///
        /// **A message chip and a mention differ by the chevron and the mark
        /// after it** — `INVARIANTS.md` §5.5: two things that go to different
        /// places must not look the same.
        ///
        /// - Returns: false where Discord leaves the link a plain URL.
        @discardableResult
        mutating func appendChannelChip(
            _ link: ChannelLink,
            url: String?,
            base: [NSAttributedString.Key: Any]
        ) -> Bool {
            let target = MessageText.LinkTarget.channelLink(link, url: url)
            // The post first, then its forum — Discord's `mediaPostLink`.
            guard let channel = link.threadID.flatMap({ context.channels[$0] })
                ?? context.channels[link.channelID]
            else {
                let server = link.guildID.flatMap { id in
                    id == context.currentGuildID ? nil : context.guildNames[id]
                }
                // A link still opens its URL; a bare mention of a channel
                // nobody can name has nowhere to go, so it is no control.
                appendChip(
                    server.map(ChipPart.guild),
                    .unknownChannel,
                    base: base,
                    target: url == nil ? nil : target
                )
                return true
            }
            guard channel.canView else {
                let start = beginPlate(padding: MessageTextStyle.chipPadding)
                appendInlineSymbol("lock.fill", base: base)
                appendRaw(" No Access", attributes: style.mention(base: base))
                endPlate(from: start, kind: .mention, padding: MessageTextStyle.chipPadding)
                return true
            }
            guard channel.isMentionable else {
                appendRaw("#" + Self.chipName(channel.name), attributes: base)
                return true
            }
            guard let guildID = channel.guildID else {
                guard channel.isConversation else { return false }
                appendChip(.channel(channel), .message(isPost: false), base: base, target: target)
                return true
            }
            guard let server = context.guildNames[guildID] else {
                guard url == nil else { return false }
                appendRaw("#unknown-channel", attributes: base)
                return true
            }

            let hasMessage = link.messageID != nil
            if guildID == context.currentGuildID {
                if !hasMessage {
                    appendChip(nil, .channel(channel), base: base, target: target)
                } else if channel.isPost,
                          let forum = channel.parentID.flatMap({ context.channels[$0] })
                {
                    appendChip(.channel(forum), .channel(channel), base: base, target: target)
                } else {
                    appendChip(
                        .channel(channel), .message(isPost: channel.isPost),
                        base: base, target: target
                    )
                }
            } else {
                let part: ChipPart = hasMessage && !channel.isPost
                    ? .message(isPost: false)
                    : .channel(channel)
                appendChip(.guild(server), part, base: base, target: target)
            }
            return true
        }

        /// A plated chip: `lead › part`, or `part` alone, as one target.
        private mutating func appendChip(
            _ lead: ChipPart?,
            _ part: ChipPart,
            base: [NSAttributedString.Key: Any],
            target: MessageText.LinkTarget?
        ) {
            let start = beginPlate(padding: MessageTextStyle.chipPadding)
            if let lead {
                appendChipPart(lead, base: base)
                appendRaw(" ", attributes: style.mention(base: base))
                appendInlineSymbol("chevron.compact.right", base: base)
                appendRaw(" ", attributes: style.mention(base: base))
            }
            appendChipPart(part, base: base)
            endPlate(from: start, kind: .mention, padding: MessageTextStyle.chipPadding, target: target)
        }

        private mutating func appendChipPart(_ part: ChipPart, base: [NSAttributedString.Key: Any]) {
            let ink = style.mention(base: base)
            switch part {
            case .guild(let name):
                appendRaw(Self.chipName(name), attributes: ink)
            case .channel(let channel):
                switch channel.kind {
                case .text:
                    appendRaw("#" + Self.chipName(channel.name), attributes: ink)
                case .directMessage:
                    appendRaw("@" + Self.chipName(channel.name), attributes: ink)
                default:
                    appendInlineSymbol(channel.kind.symbolName, base: base)
                    appendRaw(" " + Self.chipName(channel.name), attributes: ink)
                }
            case .unknownChannel:
                var italic = ink
                style.apply(.italic, to: &italic)
                appendRaw("#", attributes: ink)
                appendRaw("unknown", attributes: italic)
            case .message(let isPost):
                appendInlineSymbol(isPost ? "doc.text.fill" : "text.bubble.fill", base: base)
            case .place(let symbol, let title):
                appendInlineSymbol(symbol, base: base)
                appendRaw(" " + title, attributes: ink)
            case .name(let name):
                appendRaw(Self.chipName(name), attributes: ink)
            }
        }

        /// A name in a chip, cut at Discord's thirty-two characters.
        private static func chipName(_ name: String) -> String {
            name.count > 32 ? String(name.prefix(32)) + "…" : name
        }

        /// Opens a plated run: the chip's leading air, kerned onto the character
        /// before it. Returns where the run starts.
        ///
        /// **Kern, not a placeholder character.** A spacer glyph is a break
        /// opportunity, and a chip whose padding wraps onto the line above
        /// paints a sliver there. At the start of a line there is nothing to
        /// kern and the plate overhangs by the padding instead.
        mutating func beginPlate(padding: CGFloat) -> Int {
            let start = output.length
            guard start > 0, output.mutableString.character(at: start - 1) != 0x0A else {
                return start
            }
            addKern(padding, at: start - 1)
            return start
        }

        /// Closes a plated run: its trailing air kerned onto its own last
        /// character, and the plate — and the link, when it is one — recorded.
        mutating func endPlate(
            from start: Int,
            kind: MessageText.Plate.Kind,
            padding: CGFloat,
            target: MessageText.LinkTarget? = nil
        ) {
            guard output.length > start else { return }
            addKern(padding, at: output.length - 1)
            let range = NSRange(location: start, length: output.length - start)
            plates.append(.init(range: range, kind: kind, padding: padding))
            if let target { links.append(.init(range: range, target: target)) }
        }

        private mutating func addKern(_ amount: CGFloat, at index: Int) {
            let existing = output.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat ?? 0
            output.addAttribute(
                .kern, value: existing + amount, range: NSRange(location: index, length: 1)
            )
        }

        /// Inserts a symbol into the run, in the mention's own colour.
        ///
        /// The box is square and sized to the text, so the glyph grows with the
        /// reader's text size instead of being pinned at a point value.
        mutating func appendInlineSymbol(
            _ name: String,
            base: [NSAttributedString.Key: Any]
        ) {
            let index = output.length
            inlineSymbols[index] = name

            let side = style.symbolSide
            let metrics = InlineBoxMetrics(
                ascent: side * 0.86,
                descent: side * 0.14,
                width: side
            )
            var attributes = style.mention(base: base)
            if let delegate = InlineBoxMetrics.makeRunDelegate(metrics) {
                attributes[kCTRunDelegateAttributeName as NSAttributedString.Key] = delegate
            }
            output.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
        }

        /// Inserts an object-replacement character carrying a run delegate that
        /// reserves the emoji's box.
        ///
        /// The delegate's callbacks are C function pointers with no captured
        /// state, so the metrics are read from a boxed value passed as the
        /// delegate's `refCon` — which is retained and released by the two
        /// lifecycle callbacks so it lives exactly as long as the delegate does.
        mutating func appendInlineEmoji(
            _ emoji: EmojiRef,
            base: [NSAttributedString.Key: Any]
        ) {
            let index = output.length
            inlineEmoji[index] = emoji

            let metrics = InlineBoxMetrics(
                ascent: style.emojiAscent,
                descent: style.emojiDescent,
                width: style.emojiWidth
            )
            var attributes = base
            if let delegate = InlineBoxMetrics.makeRunDelegate(metrics) {
                attributes[kCTRunDelegateAttributeName as NSAttributedString.Key] = delegate
            }
            output.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
        }

        func finish(plainLabel: String) -> MessageText {
            MessageText(
                // A copy, not the builder's own buffer: handing out the mutable
                // instance would let a later append change a string another
                // thread is already laying out.
                attributed: NSAttributedString(attributedString: output),
                inlineEmoji: inlineEmoji,
                inlineSymbols: inlineSymbols,
                links: links,
                spoilers: spoilers,
                plates: plates,
                quotes: quotes,
                codeBlocks: codeBlocks,
                plainLabel: plainLabel,
                overlines: overlines,
                awaitsHighlighting: awaitsHighlighting
            )
        }
    }
}

/// The box an inline image reserves in a line.
nonisolated final class InlineBoxMetrics: @unchecked Sendable {
    let ascent: CGFloat
    let descent: CGFloat
    let width: CGFloat

    init(ascent: CGFloat, descent: CGFloat, width: CGFloat) {
        self.ascent = ascent
        self.descent = descent
        self.width = width
    }

    static func makeRunDelegate(_ metrics: InlineBoxMetrics) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                Unmanaged<InlineBoxMetrics>.fromOpaque(pointer).release()
            },
            getAscent: { pointer in
                Unmanaged<InlineBoxMetrics>.fromOpaque(pointer).takeUnretainedValue().ascent
            },
            getDescent: { pointer in
                Unmanaged<InlineBoxMetrics>.fromOpaque(pointer).takeUnretainedValue().descent
            },
            getWidth: { pointer in
                Unmanaged<InlineBoxMetrics>.fromOpaque(pointer).takeUnretainedValue().width
            }
        )
        let retained = Unmanaged.passRetained(metrics).toOpaque()
        guard let delegate = CTRunDelegateCreate(&callbacks, retained) else {
            Unmanaged<InlineBoxMetrics>.fromOpaque(retained).release()
            return nil
        }
        return delegate
    }
}
