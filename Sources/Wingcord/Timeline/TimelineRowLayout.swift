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
nonisolated struct MessageRow: Sendable {
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
    var reactions: [ReactionSlot]

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
    }

    struct AuthorInfo: Sendable {
        var name: String
        var colorValue: UInt32?
        var avatarURL: URL?
        var monogram: String
        var decorationURL: URL?
        var isBot: Bool
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
                    kind: .daySeparator(label: Self.dayLabel(date, calendar: input.calendar))
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
                let row = buildMessage(message, input: input, parser: parser)
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
        for slot in row.attachments { bottom = max(bottom, slot.rect.maxY) }
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

        var y: CGFloat = item.isRunHead ? TimelineMetrics.runSpacing : TimelineMetrics.lineSpacing
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
            let nameWidth = Self.measure(name, font: input.style.authorFont)
            authorRect = CGRect(
                x: contentX,
                y: y,
                width: nameWidth,
                height: TimelineMetrics.headerHeight
            )
            let stampWidth = Self.measure(
                Self.timestampLabel(message.sentAt, calendar: input.calendar),
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
        var textBlock: TimelineTextBlock?
        let textOrigin = CGPoint(x: contentX, y: y)
        if !message.content.isEmpty {
            let document = parser.parse(message.content)
            let text = MessageTextBuilder.build(
                document: document,
                context: input.mentions,
                style: input.style
            )
            let block = TimelineTextBlock(text: text, width: contentWidth, style: input.style)
            textBlock = block
            y += block.size.height
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

        // Reaction chips.
        var reactions: [ReactionSlot] = []
        if !message.reactions.isEmpty {
            y += TimelineMetrics.reactionGap
            var x = contentX
            for reaction in message.reactions {
                let label = "\(reaction.count)"
                let width = 26 + Self.measure(label, font: input.style.metadataFont)
                if x + width > contentX + contentWidth, x > contentX {
                    x = contentX
                    y += TimelineMetrics.reactionChipHeight + 4
                }
                reactions.append(ReactionSlot(
                    rect: CGRect(
                        x: x, y: y,
                        width: width, height: TimelineMetrics.reactionChipHeight
                    ),
                    emoji: reaction.emoji,
                    count: reaction.count,
                    isMine: reaction.isMine,
                    imageURL: reaction.emoji.id.flatMap {
                        CDN.emoji(id: $0, animated: reaction.emoji.isAnimated, side: 16)
                    }
                ))
                x += width + 4
            }
            y += TimelineMetrics.reactionChipHeight
        }

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
            authorColor: author?.colorValue.map { NSColor(Color(hex: $0)) },
            authorRect: authorRect,
            timestampText: Self.timestampLabel(message.sentAt, calendar: input.calendar),
            timestampRect: timestampRect,
            gutterTimestampText: Self.compactTime(message.sentAt),
            isBot: author?.isBot ?? false,
            textBlock: textBlock,
            textOrigin: textOrigin,
            attachments: attachments,
            reactions: reactions,
            accessibilityLabel: Self.accessibilityLabel(
                author: author?.name ?? "Unknown",
                time: Self.compactTime(message.sentAt),
                body: textBlock?.text.plainLabel ?? "",
                attachments: message.attachments.count
            )
        )
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
    static func measure(_ string: String, font: NSFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    static func timestampLabel(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "Today at " + compactTime(date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday at " + compactTime(date)
        }
        return date.formatted(.dateTime.day().month().year().hour().minute(.twoDigits))
    }

    /// `HH:mm`. Minute uses `.twoDigits` deliberately — the default-digits form
    /// renders minute zero as a bare `0`, so every time on the hour comes out as
    /// `22:0`.
    static func compactTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute(.twoDigits))
    }

    private static func accessibilityLabel(
        author: String,
        time: String,
        body: String,
        attachments: Int
    ) -> String {
        var label = "\(author), \(time)"
        if !body.isEmpty { label += ". \(body)" }
        if attachments > 0 {
            label += attachments == 1 ? ". 1 attachment" : ". \(attachments) attachments"
        }
        return label
    }
}
