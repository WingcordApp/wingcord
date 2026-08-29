import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

/// One row's geometry and everything the painter needs to draw it.
///
/// A value, so a row can be laid out on a background task and handed to the main
/// actor as a plain result. The one reference it holds — the text block — is
/// immutable and shared, which is what makes reusing a layout across a rows
/// change a pointer copy rather than a re-framesetting.
nonisolated struct TimelineRow: Sendable {
    var height: CGFloat
    var kind: Kind

    enum Kind: Sendable {
        case daySeparator(label: String)
        case unreadDivider
        case conversationStart(name: String)
        case skeleton(index: Int)
        case loadingFirstPage
        case historyUnavailable(reason: String)
        case message(MessageRow)
    }

    var messageID: MessageID? {
        if case .message(let row) = kind { return row.id }
        return nil
    }

    var isSelectable: Bool {
        if case .message = kind { return true }
        return false
    }
}

/// A message row, laid out.
nonisolated struct MessageRow: @unchecked Sendable {
    var id: MessageID
    var authorID: UserID
    var isRunHead: Bool
    var mentionsMe: Bool
    var isPending: Bool
    var isFailed: Bool

    /// Present only on a run head. Everything else in the run leaves the gutter
    /// empty and reveals a compact timestamp there on hover.
    var avatarRect: CGRect?
    var avatarURL: URL?
    var avatarMonogram: String
    var decorationURL: URL?

    var authorName: String
    /// The styled face and tracking the name was measured in, carried so the
    /// painter draws in the same one.
    var authorFace: NSFont?
    var authorTracking: CGFloat = 0
    var authorColor: NSColor?
    var authorRect: CGRect
    var timestampText: String
    var timestampRect: CGRect
    /// The compact `HH:mm` shown in the gutter on hover, for a continuation row.
    var gutterTimestampText: String

    var isBot: Bool

    /// Laid-out body text. Nil for a message with no textual content.
    var textBlock: TimelineTextBlock?
    var textOrigin: CGPoint

    var attachments: [AttachmentSlot]
    var stickers: [StickerSlot]
    var embeds: [EmbedSlot]
    /// The controls an app attached, laid out into rows.
    var components: [ComponentSlot]
    /// The poll, when the message is one.
    var poll: PollSlot?
    var reactions: [ReactionSlot]

    /// A system event's gutter glyph — a join, a boost, a pin.
    ///
    /// **A field on the ordinary row rather than a row kind of its own.** A
    /// system message is still a message: it has an id, an author, a timestamp,
    /// reactions and a place in the layout cache, and the only things that
    /// differ are that the gutter holds a symbol instead of a face and the
    /// sentence is composed rather than typed. A separate kind would duplicate
    /// the cache key, the height calculation and the hit testing to change two
    /// of them.

    /// A system event's gutter glyph — a join, a boost, a pin.
    ///
    /// **A field on the ordinary row rather than a row kind of its own.** A
    /// system message is still a message: it has an id, an author, a timestamp,
    /// reactions and a place in the layout cache, and the only things that
    /// differ are that the gutter holds a symbol instead of a face and the
    /// sentence is composed rather than typed. A separate kind would duplicate
    /// the cache key, the height calculation and the hit testing to change two
    /// of them.
    var systemSymbol: String?
    var systemTint: NSColor?

    /// One plain string for one accessibility node.
    ///
    /// **This is the whole accessibility surface of a message row, deliberately.**
    /// Letting the platform derive a label from styled text carrying link
    /// attributes makes it re-resolve every run into attributes on every render —
    /// reaching localized bundle string tables to answer what font a run is in,
    /// per run, per frame — and that happens whether or not anyone is using
    /// VoiceOver, because on a real Mac something always holds the accessibility
    /// API open.
    var accessibilityLabel: String
}

nonisolated struct AttachmentSlot: Sendable {
    var rect: CGRect
    var url: URL?
    var isSpoiler: Bool
    var isVideo: Bool
    var altText: String?
    /// The pixel width the image should be decoded at.
    var decodeWidth: CGFloat
}

/// A sticker's box.
///
/// **Its own slot rather than an attachment.** A sticker is not a file somebody
/// uploaded — it has a fixed authored size, no filename, no spoiler state, and a
/// third of them are vector animations with no bitmap on the CDN at all. Folding
/// it into `AttachmentSlot` would mean four fields that are never set and one
/// that means something different.
nonisolated struct StickerSlot: Sendable {
    var rect: CGRect
    var sticker: StickerRef
    var url: URL?
    /// Whether the asset is Lottie, which lives in the filmstrip cache rather
    /// than the still one — `CGImageSource` cannot open it and the CDN serves no
    /// bitmap for it, so its poster is the first frame of a rasterised strip.
    var isVector: Bool
    /// Whether it moves.
    ///
    /// **All three animated formats end up as the same filmstrip** — APNG and
    /// GIF through `CGImageSource`, Lottie through the rasteriser — so this is
    /// one flag rather than three cases, and it is what decides whether the
    /// canvas subscribes to the clock at all.
    var isAnimated: Bool
}

/// One button an app attached to a message.
///
/// **Only a link button is live.** Everything else needs an interaction round
/// trip this client does not make, so it is drawn dimmed — a bot's message is
/// unreadable without its controls, and a control that looks pressable and does
/// nothing is worse than one that says it is not.
nonisolated struct ComponentSlot: Sendable {
    var rect: CGRect
    var label: String
    var emoji: EmojiRef?
    /// Where it goes. Nil for anything this client cannot honour.
    var url: String?
    var isEnabled: Bool
    var style: MessageComponent.Style
    /// A select menu, drawn as its placeholder with a disclosure.
    var isMenu: Bool
}

nonisolated struct ReactionSlot: Sendable {
    var rect: CGRect
    var emoji: EmojiRef
    var count: Int
    var isMine: Bool
    var imageURL: URL?
}

// MARK: - The layout engine

/// Turns timeline items into laid-out rows.
///
/// **Incremental by construction.** A rows change usually adds one message
/// (a live arrival) or prepends a hundred (a page of history); everything else
/// is unchanged, and re-laying it out would mean re-framesetting text that has
/// not moved. The cache is keyed on identity plus everything that can change the
/// answer — width, and the presentation revision that covers text size, theme
/// and mention names — so a hit is exact and a miss is honest.
nonisolated struct TimelineLayoutEngine: Sendable {

    struct Input: Sendable {
        var items: [TimelineItem]
        var width: CGFloat
        var style: MessageTextStyle
        var mentions: MentionContext
        var channelName: String
        /// Everything the layout needs about people, resolved by the caller so
        /// this never touches the store.
        var authors: [UserID: AuthorInfo]
        var calendar: Calendar
        /// What the reader's preferences contribute — density, whether embeds
        /// are measured, and the date formatters. Resolved once per presentation
        /// revision, never read from the store here: this type is `nonisolated`
        /// and runs off the main actor.
        var settings: TimelineSettings
    }

    /// `@unchecked` for the same reason `MessageTextStyle` is: it carries a
    /// resolved `NSFont`, which is immutable in practice but not marked
    /// `Sendable`. **Resolved on the main actor where this is built**, because
    /// the registry is main-actor state and the layout deliberately is not — and
    /// because resolving here means only the faces actually on screen are ever
    /// registered.
    struct AuthorInfo: @unchecked Sendable {
        var name: String
        var colorValue: UInt32?
        var avatarURL: URL?
        var monogram: String
        var decorationURL: URL?
        var isBot: Bool
        /// The styled face, already resolved. Nil is the ordinary case.
        var nameFace: NSFont?
        /// Discord's per-family tracking, in points.
        var nameTracking: CGFloat = 0
    }

    /// Key for one message's laid-out form.
    struct CacheKey: Hashable, Sendable {
        var messageID: MessageID
        /// Width, rounded to a whole point. A drag resizes by fractions and a
        /// key that carries them never hits.
        var width: Int
        var presentationRevision: UInt64
        var isRunHead: Bool
    }

    var presentationRevision: UInt64

    /// Lays out every item, reusing what `cache` already holds.
    ///
    /// The cache is `inout` rather than a class, so the caller owns its lifetime
    /// and the engine cannot retain anything past the call — there is no place
    /// for a leak to hide.
    func layout(
        _ input: Input,
        cache: inout [CacheKey: MessageRow],
        parser: MarkdownParser = MarkdownParser()
    ) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        rows.reserveCapacity(input.items.count)
        var used = Set<CacheKey>()
        used.reserveCapacity(input.items.count)

        for item in input.items {
            switch item {
            case .daySeparator(let date):
                rows.append(TimelineRow(
                    height: TimelineMetrics.daySeparatorHeight,
                    kind: .daySeparator(label: input.settings.dayLabel(date, calendar: input.calendar))
                ))

            case .unreadDivider:
                rows.append(TimelineRow(
                    height: TimelineMetrics.unreadDividerHeight,
                    kind: .unreadDivider
                ))

            case .conversationStart:
                rows.append(TimelineRow(
                    height: TimelineMetrics.conversationStartHeight,
                    kind: .conversationStart(name: input.channelName)
                ))

            case .historySkeleton(let index):
                rows.append(TimelineRow(
                    height: TimelineMetrics.skeletonHeight,
                    kind: .skeleton(index: index)
                ))

            case .loadingFirstPage:
                rows.append(TimelineRow(
                    height: TimelineMetrics.loadingRowHeight,
                    kind: .loadingFirstPage
                ))

            case .historyUnavailable(let reason):
                rows.append(TimelineRow(
                    height: TimelineMetrics.historyUnavailableHeight,
                    kind: .historyUnavailable(reason: reason)
                ))

            case .message(let message):
                let key = CacheKey(
                    messageID: message.id,
                    width: Int(input.width.rounded()),
                    presentationRevision: presentationRevision,
                    isRunHead: message.isRunHead
                )
                used.insert(key)
                if let cached = cache[key] {
                    rows.append(TimelineRow(height: rowHeight(of: cached), kind: .message(cached)))
                    continue
                }
                let row = message.message.isSystemEvent
                    ? buildSystemMessage(message, input: input)
                    : buildMessage(message, input: input, parser: parser)
                cache[key] = row
                rows.append(TimelineRow(height: rowHeight(of: row), kind: .message(row)))
            }
        }

        // Drop anything this pass did not use, bounded so a long session cannot
        // accumulate every layout it has ever built. Without this the cache is a
        // leak with a polite name.
        if cache.count > used.count + Self.cacheSlack {
            cache = cache.filter { used.contains($0.key) }
        }

        return rows
    }

    /// How many stale entries to tolerate before sweeping.
    ///
    /// Some slack is worth keeping: a width drag produces a burst of misses and
    /// then settles back, and sweeping on every pass would throw away the
    /// entries the settle is about to want again.
    static let cacheSlack = 400

    private func rowHeight(of row: MessageRow) -> CGFloat {
        var bottom: CGFloat = 0
        if let avatarRect = row.avatarRect { bottom = max(bottom, avatarRect.maxY) }
        bottom = max(bottom, row.authorRect.maxY)
        if let block = row.textBlock {
            bottom = max(bottom, row.textOrigin.y + block.size.height)
        }
        for slot in row.stickers { bottom = max(bottom, slot.rect.maxY) }
        for slot in row.attachments { bottom = max(bottom, slot.rect.maxY) }
        for slot in row.embeds { bottom = max(bottom, slot.rect.maxY) }
        for slot in row.components { bottom = max(bottom, slot.rect.maxY) }
        if let poll = row.poll { bottom = max(bottom, poll.rect.maxY) }
        for slot in row.reactions { bottom = max(bottom, slot.rect.maxY) }
        return ceil(bottom + TimelineMetrics.runBottomPadding)
    }

    private func buildMessage(
        _ item: TimelineMessage,
        input: Input,
        parser: MarkdownParser
    ) -> MessageRow {
        let message = item.message
        let author = input.authors[message.authorID]
        let contentX = TimelineMetrics.contentInset
        let contentWidth = max(80, input.width - contentX - TimelineMetrics.horizontalMargin)

        var y: CGFloat = item.isRunHead ? input.settings.runSpacing : TimelineMetrics.lineSpacing
        var avatarRect: CGRect?
        var authorRect = CGRect(x: contentX, y: y, width: 0, height: 0)
        var timestampRect = CGRect.zero

        if item.isRunHead {
            avatarRect = CGRect(
                x: TimelineMetrics.horizontalMargin,
                y: y,
                width: Metrics.avatarMessage,
                height: Metrics.avatarMessage
            )
            let name = author?.name ?? "Unknown"
            // **Measured in the face it will be DRAWN in.** The bot badge and
            // the timestamp are placed off this width, so measuring in the
            // default face and drawing in another puts both in the wrong place.
            let nameWidth = Self.measure(
                name,
                font: author?.nameFace ?? input.style.authorFont,
                tracking: author?.nameTracking ?? 0
            )
            authorRect = CGRect(
                x: contentX,
                y: y,
                width: nameWidth,
                height: TimelineMetrics.headerHeight
            )
            let stampWidth = Self.measure(
                input.settings.timestampLabel(message.sentAt, calendar: input.calendar),
                font: input.style.metadataFont
            )
            timestampRect = CGRect(
                x: authorRect.maxX + 8 + (author?.isBot == true ? 34 : 0),
                y: y,
                width: stampWidth,
                height: TimelineMetrics.headerHeight
            )
            y += TimelineMetrics.headerHeight + TimelineMetrics.headerGap
        }

        // Body text.
        //
        // A message that is nothing but emoji is drawn large — the rule every
        // client shares, and the one that decides whether a lone thumbs-up
        // reads as a reply or as punctuation. The decision is made on the
        // PARSED tree, because `<:blobcat:123>` is not emoji by any character
        // test and `:thumbsup:` was expanded server-side long before this.
        var textBlock: TimelineTextBlock?
        let textOrigin = CGPoint(x: contentX, y: y)
        if !message.content.isEmpty {
            let document = parser.parse(message.content)
            let style = document.jumboEmojiCount == nil ? input.style : input.style.jumbo
            let text = MessageTextBuilder.build(
                document: document,
                context: input.mentions,
                style: style
            )
            let block = TimelineTextBlock(text: text, width: contentWidth, style: style)
            textBlock = block
            y += block.size.height
        }

        // Stickers, above attachments: a sticker IS the message, and one drawn
        // under a screenshot reads as a caption on it.
        var stickers: [StickerSlot] = []
        for sticker in message.stickers {
            y += TimelineMetrics.attachmentGap
            let side = min(Metrics.stickerInline, contentWidth)
            stickers.append(StickerSlot(
                rect: CGRect(x: contentX, y: y, width: side, height: side),
                sticker: sticker,
                url: CDN.sticker(id: sticker.id, format: sticker.format),
                isVector: sticker.format == .lottie,
                isAnimated: sticker.format.isAnimated
            ))
            y += side
        }

        // Attachments.
        var attachments: [AttachmentSlot] = []
        for attachment in message.attachments {
            y += TimelineMetrics.attachmentGap
            let slot = Self.attachmentSlot(
                attachment,
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth
            )
            attachments.append(slot)
            y = slot.rect.maxY
        }

        // A poll IS the message: it arrives beside an empty body, so a renderer
        // that does not know about one draws an author line over a blank row.
        var poll: PollSlot?
        if let value = message.poll {
            y += TimelineMetrics.attachmentGap
            let slot = PollLayoutEngine.layout(
                value,
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth,
                style: input.style
            )
            poll = slot
            y = slot.rect.maxY
        }

        // Embeds. A link unfurl, a bot's status card, a release note — all the
        // same object with different subsets populated, which is why the layout
        // branches on what is present rather than on the `kind` string.
        // Skipped WHOLESALE when the reader has turned unfurls off — not laid
        // out and then hidden. An embed is a framesetting pass over a title, a
        // markdown description and a field grid; measuring one nobody will see
        // is the most expensive way to draw nothing.
        var embeds: [EmbedSlot] = []
        for embed in input.settings.showsEmbeds ? message.embeds : [] {
            y += TimelineMetrics.attachmentGap
            let slot = EmbedLayoutEngine.layout(
                embed,
                origin: CGPoint(x: contentX, y: y),
                availableWidth: contentWidth,
                style: input.style,
                mentions: input.mentions,
                parser: parser
            )
            embeds.append(slot)
            y = slot.rect.maxY
        }

        // A Components V2 tree, which is the whole body of the message it
        // arrives on. It produces the same two things an embed does — cards and
        // controls — so nothing downstream needs a case for it.
        var components: [ComponentSlot] = []
        if !message.displayComponents.isEmpty {
            y += TimelineMetrics.attachmentGap
            let tree = ComponentsLayoutEngine.layout(
                message.displayComponents,
                origin: CGPoint(x: contentX, y: y),
                width: min(Metrics.embedMaxWidth, contentWidth),
                context: ComponentsLayoutEngine.Context(
                    style: input.style,
                    mentions: input.mentions,
                    parser: parser
                )
            )
            embeds.append(contentsOf: tree.cards)
            components.append(contentsOf: tree.controls)
            y = tree.bottom
        } else if !message.components.isEmpty {
            // The ordinary flat form: rows of buttons under a body or an embed.
            y += TimelineMetrics.componentGap
            y = Self.layoutComponents(
                message.components,
                contentX: contentX,
                y: y,
                width: contentWidth,
                style: input.style,
                into: &components
            )
        }

        // Reaction chips.
        var reactions: [ReactionSlot] = []
        y = Self.layoutReactions(
            message.reactions,
            contentX: contentX,
            y: y,
            width: contentWidth,
            style: input.style,
            into: &reactions
        )

        return MessageRow(
            id: message.id,
            authorID: message.authorID,
            isRunHead: item.isRunHead,
            mentionsMe: item.flags.contains(.mentionsMe),
            isPending: item.flags.contains(.pending),
            isFailed: item.flags.contains(.failed),
            avatarRect: avatarRect,
            avatarURL: author?.avatarURL,
            avatarMonogram: author?.monogram ?? "?",
            decorationURL: author?.decorationURL,
            authorName: author?.name ?? "Unknown",
            authorFace: author?.nameFace,
            authorTracking: author?.nameTracking ?? 0,
            authorColor: author?.colorValue.map { NSColor(Color(hex: $0)) },
            authorRect: authorRect,
            timestampText: input.settings.timestampLabel(message.sentAt, calendar: input.calendar),
            timestampRect: timestampRect,
            gutterTimestampText: input.settings.time(message.sentAt),
            isBot: author?.isBot ?? false,
            textBlock: textBlock,
            textOrigin: textOrigin,
            attachments: attachments,
            stickers: stickers,
            embeds: embeds,
            components: components,
            poll: poll,
            reactions: reactions,
            accessibilityLabel: Self.accessibilityLabel(
                author: author?.name ?? "Unknown",
                time: input.settings.time(message.sentAt),
                body: textBlock?.text.plainLabel ?? "",
                attachments: message.attachments.count,
                stickers: stickers.map(\.sticker.name),
                extra: Self.spokenBody(of: message)
            )
        )
    }

    /// A message nobody typed: a join, a boost, a pin, a call.
    ///
    /// **The words are the client's, and without them the row is blank.** These
    /// arrive with `content: ""` — a renderer that only knows how to draw
    /// content puts an avatar, a name and a timestamp over an empty space, which
    /// on a `#welcome` channel is the whole channel.
    ///
    /// Drawn compactly: a tinted glyph where the avatar would be, one sentence
    /// with the member's name in their colour, and the time inline after it. A
    /// system event is a fact about the channel rather than something somebody
    /// said, and giving it a full author header makes a hundred joins look like
    /// a hundred conversations.
    private func buildSystemMessage(
        _ item: TimelineMessage,
        input: Input
    ) -> MessageRow {
        let message = item.message
        let author = input.authors[message.authorID]
        let name = author?.name ?? "Someone"
        let sentence = SystemMessageText.sentence(for: message, name: name)
        let contentX = TimelineMetrics.contentInset
        let contentWidth = max(80, input.width - contentX - TimelineMetrics.horizontalMargin)
        let y = input.settings.runSpacing

        let text = Self.systemText(
            sentence,
            authorID: message.authorID,
            colorValue: author?.colorValue,
            time: input.settings.timestampLabel(message.sentAt, calendar: input.calendar),
            style: input.style
        )
        let block = TimelineTextBlock(text: text, width: contentWidth, style: input.style)

        // A join message can be reacted to like any other, and dropping them
        // would be dropping data the payload already carries.
        var reactions: [ReactionSlot] = []
        _ = Self.layoutReactions(
            message.reactions,
            contentX: contentX,
            y: y + block.size.height,
            width: contentWidth,
            style: input.style,
            into: &reactions
        )

        return MessageRow(
            id: message.id,
            authorID: message.authorID,
            isRunHead: false,
            mentionsMe: item.flags.contains(.mentionsMe),
            isPending: false,
            isFailed: false,
            avatarRect: nil,
            avatarURL: nil,
            avatarMonogram: "",
            decorationURL: nil,
            authorName: name,
            authorColor: nil,
            authorRect: CGRect(x: contentX, y: y, width: 0, height: 0),
            timestampText: "",
            timestampRect: .zero,
            gutterTimestampText: "",
            isBot: false,
            textBlock: block,
            textOrigin: CGPoint(x: contentX, y: y),
            attachments: [],
            stickers: [],
            embeds: [],
            components: [],
            poll: nil,
            reactions: reactions,
            systemSymbol: sentence?.symbolName ?? "circle",
            systemTint: Self.tintColor(sentence?.tint),
            accessibilityLabel: text.plainLabel
        )
    }

    /// The sentence, with the name coloured and clickable and the time after it.
    ///
    /// Built as one attributed string rather than three drawn runs so it wraps
    /// as a sentence — a long nickname on a narrow column has to break like
    /// prose, not leave the verb hanging off the edge.
    private static func systemText(
        _ sentence: SystemSentence?,
        authorID: UserID,
        colorValue: UInt32?,
        time: String,
        style: MessageTextStyle
    ) -> MessageText {
        let body: [NSAttributedString.Key: Any] = [
            .font: style.bodyFont,
            .foregroundColor: style.secondaryColor,
        ]
        let output = NSMutableAttributedString()
        var links: [MessageText.LinkRun] = []

        guard let sentence else {
            output.append(NSAttributedString(string: "Message", attributes: body))
            return .plain(output)
        }

        output.append(NSAttributedString(string: sentence.prefix, attributes: body))
        if !sentence.name.isEmpty {
            let start = output.length
            output.append(NSAttributedString(string: sentence.name, attributes: [
                .font: style.boldFont,
                .foregroundColor: colorValue.map { NSColor(Color(hex: $0)) }
                    ?? style.primaryColor,
            ]))
            links.append(.init(
                range: NSRange(location: start, length: output.length - start),
                target: .user(authorID)
            ))
        }
        output.append(NSAttributedString(string: sentence.suffix, attributes: body))
        output.append(NSAttributedString(string: "  " + time, attributes: [
            .font: style.metadataFont,
            .foregroundColor: style.tertiaryColor,
        ]))
        return .plain(output, links: links)
    }

    private static func tintColor(_ tint: SystemSentence.Tint?) -> NSColor {
        switch tint {
        case .affirmative: NSColor(Palette.presenceOnline)
        case .celebratory: NSColor(Palette.accent)
        case .destructive: NSColor(Palette.unreadBadge)
        case .quiet, nil: NSColor.tertiaryLabelColor
        }
    }

    /// The reaction chips under a message, wrapped to the column.
    ///
    /// Shared by the ordinary row and the system one — a join message can be
    /// reacted to like any other, and a second copy of this arithmetic is a
    /// second place for the chip width to drift from what the painter draws.
    ///
    /// Returns the y the next thing starts at, unchanged when there is nothing
    /// to lay out.
    private static func layoutReactions(
        _ reactions: [Reaction],
        contentX: CGFloat,
        y startY: CGFloat,
        width: CGFloat,
        style: MessageTextStyle,
        into slots: inout [ReactionSlot]
    ) -> CGFloat {
        guard !reactions.isEmpty else { return startY }
        var y = startY + TimelineMetrics.reactionGap
        var x = contentX

        for reaction in reactions {
            // Built from the same parts the painter draws, so the chip cannot be
            // narrower than its own contents.
            let chipWidth = TimelineMetrics.reactionChipWidth(
                countWidth: measure("\(reaction.count)", font: style.metadataFont)
            )
            if x + chipWidth > contentX + width, x > contentX {
                x = contentX
                y += TimelineMetrics.reactionChipHeight + 4
            }
            slots.append(ReactionSlot(
                rect: CGRect(
                    x: x, y: y,
                    width: chipWidth, height: TimelineMetrics.reactionChipHeight
                ),
                emoji: reaction.emoji,
                count: reaction.count,
                isMine: reaction.isMine,
                imageURL: reaction.emoji.id.flatMap {
                    CDN.emoji(id: $0, animated: reaction.emoji.isAnimated, side: 16)
                }
            ))
            x += chipWidth + 4
        }
        return y + TimelineMetrics.reactionChipHeight
    }

    /// The button rows under a message, wrapped to the column.
    ///
    /// Returns the y the next thing starts at.
    /// Shared with `ComponentsLayoutEngine`, which lays rows out inside a card.
    static func layoutComponentRows(
        _ rows: [ActionRow],
        contentX: CGFloat,
        y: CGFloat,
        width: CGFloat,
        style: MessageTextStyle,
        into slots: inout [ComponentSlot]
    ) -> CGFloat {
        layoutComponents(rows, contentX: contentX, y: y, width: width, style: style, into: &slots)
    }

    private static func layoutComponents(
        _ rows: [ActionRow],
        contentX: CGFloat,
        y startY: CGFloat,
        width: CGFloat,
        style: MessageTextStyle,
        into slots: inout [ComponentSlot]
    ) -> CGFloat {
        var y = startY
        let font = NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .semibold)

        for row in rows {
            var x = contentX
            var usedRow = false
            for control in row.components {
                let glyphRoom = control.emoji == nil
                    ? 0
                    : TimelineMetrics.componentGlyphSide + TimelineMetrics.componentGlyphGap
                let chevronRoom: CGFloat = control.kind == .menu ? 14 : 0
                let labelWidth = measure(control.label, font: font)
                let buttonWidth = min(
                    width,
                    TimelineMetrics.componentPadding * 2 + glyphRoom + labelWidth + chevronRoom
                )
                if usedRow, x + buttonWidth > contentX + width {
                    x = contentX
                    y += TimelineMetrics.componentHeight + TimelineMetrics.componentGap
                }
                slots.append(ComponentSlot(
                    rect: CGRect(
                        x: x, y: y,
                        width: buttonWidth, height: TimelineMetrics.componentHeight
                    ),
                    label: control.label,
                    emoji: control.emoji,
                    url: control.destination,
                    isEnabled: control.isActionable,
                    style: control.style,
                    isMenu: control.kind == .menu
                ))
                x += buttonWidth + TimelineMetrics.componentGap
                usedRow = true
            }
            if usedRow { y += TimelineMetrics.componentHeight + TimelineMetrics.componentGap }
        }
        // The last row contributed a trailing gap the caller does not want. With
        // nothing laid out at all there is no gap to take back.
        return slots.isEmpty ? startY : y - TimelineMetrics.componentGap
    }

    /// What a message says when its body is not `content`.
    ///
    /// Folded once, at layout time, for the same reason `plainText` is: a row is
    /// one accessibility node with a plain `String`, and letting the platform
    /// derive a label from styled text re-resolves every run into attributes on
    /// every render — per run, per frame, whether or not anybody is using
    /// VoiceOver.
    private static func spokenBody(of message: Message) -> String {
        var parts: [String] = []
        for node in message.displayComponents {
            let text = node.plainText
            if !text.isEmpty { parts.append(text) }
        }
        if let poll = message.poll {
            parts.append("Poll. \(poll.question)")
            for answer in poll.answers {
                parts.append(poll.showsResults
                    ? "\(answer.text), \(answer.count) votes"
                    : answer.text)
            }
        }
        return parts.joined(separator: ". ")
    }

    // MARK: Helpers

    private static func attachmentSlot(
        _ attachment: Attachment,
        origin: CGPoint,
        availableWidth: CGFloat
    ) -> AttachmentSlot {
        // A missing aspect ratio is a real state, not something to substitute a
        // square for: reserving a square for a panorama makes the transcript
        // jump when the picture arrives.
        let ratio = attachment.aspectRatio
        let boxWidth: CGFloat
        let boxHeight: CGFloat
        if let ratio, ratio > 0 {
            let naturalWidth = min(availableWidth, CGFloat(attachment.width ?? 0))
            let width = naturalWidth > 0 ? naturalWidth : availableWidth
            let height = width / ratio
            if height > Metrics.attachmentMaxHeight {
                boxHeight = Metrics.attachmentMaxHeight
                boxWidth = boxHeight * ratio
            } else {
                boxWidth = width
                boxHeight = height
            }
        } else {
            boxWidth = min(availableWidth, 320)
            boxHeight = 180
        }

        return AttachmentSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: boxWidth, height: boxHeight),
            url: CDN.resizedAttachment(proxyURL: attachment.proxyURL, width: boxWidth),
            isSpoiler: attachment.isSpoiler,
            isVideo: attachment.isVideo,
            altText: attachment.description,
            decodeWidth: boxWidth
        )
    }

    /// Text width, measured through CoreText rather than through `NSString`
    /// sizing.
    ///
    /// `NSAttributedString.size()` builds a text container and a layout manager;
    /// `CTLineGetTypographicBounds` measures one line and nothing else, which is
    /// all a name or a timestamp ever is.
    static func measure(_ string: String, font: NSFont, tracking: CGFloat = 0) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if tracking != 0 { attributes[.kern] = tracking }
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func accessibilityLabel(
        author: String,
        time: String,
        body: String,
        attachments: Int,
        stickers: [String],
        extra: String
    ) -> String {
        var label = "\(author), \(time)"
        if !body.isEmpty { label += ". \(body)" }
        // **A components-only message and a poll have no `content` at all**, so
        // a label folded from the body alone leaves VoiceOver reading a name and
        // a timestamp over what is, to a sighted reader, a whole card.
        if !extra.isEmpty { label += ". \(extra)" }
        // Named rather than counted: a sticker's name is what it says, and
        // "1 sticker" is the one description that tells a reader nothing.
        for name in stickers where !name.isEmpty {
            label += ". Sticker, \(name)"
        }
        if attachments > 0 {
            label += attachments == 1 ? ". 1 attachment" : ". \(attachments) attachments"
        }
        return label
    }
}
