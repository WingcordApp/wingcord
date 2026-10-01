import AppKit
import CoreText
import Foundation
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
        }

        /// Whether the pointer changes it — the plates that are links.
        var isInteractive: Bool {
            switch kind {
            case .mention, .role, .gradientRole: true
            case .timestamp, .code: false
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
    var token: UInt64 = 0
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
            case .codeBlock(_, let code):
                let start = output.length
                appendRaw(code, attributes: style.codeBlock)
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
                for (offset, item) in items.enumerated() {
                    if offset > 0 { appendRaw("\n", attributes: style.body) }
                    let marker = ordered ? "\(startIndex + offset). " : "• "
                    appendRaw(marker, attributes: style.listMarker)
                    for child in item { append(child) }
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
                plainLabel: plainLabel
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
