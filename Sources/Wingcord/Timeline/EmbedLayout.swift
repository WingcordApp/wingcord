import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

/// One embed, laid out.
///
/// **Resolved to rectangles and text frames at layout time, exactly like a
/// message body.** An embed is the most structurally complex thing a transcript
/// draws — an author row, a title, a markdown description, a grid of fields, two
/// pictures and a footer — and resolving that structure inside `draw` would put
/// a dozen framesetting calls per embed inside every repaint of every row that
/// carries one. A bot channel is nothing but rows that carry one.
///
/// The painter that consumes this has no cases at all: it fills the ground,
/// draws the rule, draws each text frame at its origin and each picture in its
/// rect. Everything that decides *where* those go lives here, in a pure function
/// a layout test can call.
nonisolated struct EmbedSlot: Sendable {
    var rect: CGRect
    /// The leading rule's colour. Nil for a card with no accent, which draws the
    /// ground and no rule — a grey bar on a grey card is a border nobody asked
    /// for.
    var accent: NSColor?
    /// Whether there is a card at all.
    ///
    /// **An explicit flag rather than "does it have text".** A bare image embed
    /// and a loose Components V2 text display both draw content with no ground
    /// behind it, and inferring that from the parts present is a rule that
    /// silently changes the day something gains a caption.
    var drawsCard: Bool = true
    var texts: [EmbedText]
    var images: [EmbedImage]
    /// Rules drawn inside the card — a Components V2 separator.
    var rules: [CGRect] = []
    /// The GIF this embed would star, when it is one the account can keep.
    ///
    /// **A Tenor link and an uploaded `.gif` are the same feature and were not
    /// the same code.** The star was built on `AttachmentSlot` only, so a GIF
    /// somebody pasted — which is most of them — had no star at all: not
    /// disabled, not empty, absent. The value is built the way the picker's own
    /// results are, so a favourite made here and one made there are the same
    /// entry: the page URL is the key, because that is what gets re-sent and
    /// what every other client unfurls, and the preview is the drawable
    /// rendition rather than a video nothing in the image path can open.
    var favorite: GIF?
    /// Where the star sits inside the picture. Only meaningful with `favorite`.
    var favoriteRect: CGRect = .zero
}

nonisolated struct EmbedText: Sendable {
    var block: TimelineTextBlock
    /// Relative to the row, like everything else a `MessageRow` holds.
    var origin: CGPoint
}

nonisolated struct EmbedImage: Sendable {
    var rect: CGRect
    var url: URL?
    /// An author's or a footer's icon is a face; a thumbnail and the main image
    /// are artwork.
    var isCircle: Bool
    var corner: CGFloat
    var decodeWidth: CGFloat
    var isArtwork: Bool
    /// Whether the picture moves. A pasted GIF link unfurls into one of these,
    /// and drawing its first frame for ever is the whole of "GIFs do not
    /// animate in the chat" on the embed half of the transcript.
    var isAnimated: Bool = false
}

/// Turns an embed into rectangles.
nonisolated enum EmbedLayoutEngine {

    /// The leading accent rule.
    static let ruleWidth: CGFloat = 4
    /// Inside the card, on every edge.
    static let padding: CGFloat = 12
    /// Between stacked parts.
    static let gap: CGFloat = 8
    /// The author's and the footer's icon.
    static let markSide: CGFloat = 20
    /// The picture in the top-trailing corner.
    static let thumbnailSide: CGFloat = 80
    /// The tallest the main picture is drawn. A cap on height only — the width
    /// is the card's, which is what keeps a wide screenshot readable.
    static let imageMaxHeight: CGFloat = 300
    /// The card's corner, and every picture's inside it.
    static let corner: CGFloat = 8
    /// How many inline fields share a row, which is Discord's own.
    static let fieldsPerRow = 3

    /// Lays one embed out at `origin`, inside `availableWidth`.
    static func layout(
        _ embed: Embed,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle,
        mentions: MentionContext,
        parser: MarkdownParser
    ) -> EmbedSlot {
        // **An embed that is nothing but a picture gets no card at all.** That
        // is what a pasted image link unfurls into, and drawing a bordered box
        // with twelve points of padding around a photograph is a frame nobody
        // asked for — `Embed.isBareImage` exists to name exactly this case.
        if let media = embed.bareMedia {
            return bareImage(media, in: embed, origin: origin, availableWidth: availableWidth)
        }

        let cardWidth = min(Metrics.embedMaxWidth, availableWidth)
        let hasThumbnail = embed.thumbnail != nil
        let contentX = origin.x + ruleWidth + padding
        let fullContentWidth = max(40, cardWidth - ruleWidth - padding * 2)
        let contentWidth = hasThumbnail
            ? max(40, fullContentWidth - thumbnailSide - gap)
            : fullContentWidth

        var texts: [EmbedText] = []
        var images: [EmbedImage] = []
        var y = origin.y + padding

        // The author row: a circular mark and a name, on one line.
        if let author = embed.author {
            var textX = contentX
            if let icon = author.iconURL.flatMap(URL.init(string:)) {
                images.append(EmbedImage(
                    rect: CGRect(x: contentX, y: y, width: markSide, height: markSide),
                    url: icon,
                    isCircle: true,
                    corner: markSide / 2,
                    decodeWidth: markSide,
                    isArtwork: false
                ))
                textX += markSide + 6
            }
            let block = plainBlock(
                author.name,
                font: NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .semibold),
                color: style.primaryColor,
                width: max(20, contentWidth - (textX - contentX)),
                link: author.url,
                style: style
            )
            // Centred on the mark rather than sharing its top edge: the mark is
            // twenty points and the name is one line of about fourteen.
            texts.append(EmbedText(
                block: block,
                origin: CGPoint(x: textX, y: y + (markSide - block.size.height) / 2)
            ))
            y += max(markSide, block.size.height) + gap
        }

        if let title = embed.title, !title.isEmpty {
            let block = plainBlock(
                title,
                font: NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .bold),
                // A titled embed with a URL is a link, and its title is the
                // thing you click. Without one it is a heading.
                color: embed.url == nil ? style.primaryColor : style.linkColor,
                width: contentWidth,
                link: embed.url,
                style: style
            )
            texts.append(EmbedText(block: block, origin: CGPoint(x: contentX, y: y)))
            y += block.size.height + gap
        }

        if let description = embed.description, !description.isEmpty {
            let block = markdownBlock(
                description,
                width: contentWidth,
                style: style,
                mentions: mentions,
                parser: parser
            )
            texts.append(EmbedText(block: block, origin: CGPoint(x: contentX, y: y)))
            y += block.size.height + gap
        }

        // The thumbnail sits in the top-trailing corner beside everything above,
        // which is why the content above was narrowed rather than the picture
        // placed after it.
        if hasThumbnail, let source = embed.thumbnail?.proxyURL ?? embed.thumbnail?.url {
            images.append(EmbedImage(
                rect: CGRect(
                    x: origin.x + cardWidth - padding - thumbnailSide,
                    y: origin.y + padding,
                    width: thumbnailSide,
                    height: thumbnailSide
                ),
                url: CDN.resizedAttachment(proxyURL: source, width: thumbnailSide),
                isCircle: false,
                corner: corner,
                decodeWidth: thumbnailSide,
                isArtwork: true
            ))
        }

        y = layoutFields(
            embed.fields,
            contentX: contentX,
            y: y,
            width: fullContentWidth,
            style: style,
            mentions: mentions,
            parser: parser,
            texts: &texts
        )

        if let image = embed.image {
            let source = image.proxyURL ?? image.url
            let width = fullContentWidth
            // A missing ratio is a real state, not a square to substitute:
            // reserving one for a panorama makes the transcript jump when the
            // picture lands.
            let height = image.aspectRatio.map { min(imageMaxHeight, width / $0) }
                ?? min(imageMaxHeight, width * 0.5625)
            images.append(EmbedImage(
                rect: CGRect(x: contentX, y: y, width: width, height: height),
                url: CDN.resizedAttachment(proxyURL: source, width: width),
                isCircle: false,
                corner: corner,
                decodeWidth: width,
                isArtwork: true
            ))
            y += height + gap
        }

        if let footer = footerLine(embed) {
            var textX = contentX
            if let icon = embed.footer?.iconURL.flatMap(URL.init(string:)) {
                images.append(EmbedImage(
                    rect: CGRect(x: contentX, y: y, width: markSide, height: markSide),
                    url: icon,
                    isCircle: true,
                    corner: markSide / 2,
                    decodeWidth: markSide,
                    isArtwork: false
                ))
                textX += markSide + 6
            }
            let block = plainBlock(
                footer,
                font: style.metadataFont,
                color: style.tertiaryColor,
                width: max(20, fullContentWidth - (textX - contentX)),
                link: nil,
                style: style
            )
            texts.append(EmbedText(
                block: block,
                origin: CGPoint(x: textX, y: y + (markSide - block.size.height) / 2)
            ))
            y += max(markSide, block.size.height) + gap
        }

        // The last part contributed a trailing gap; the card's bottom padding
        // replaces it.
        var height = max(padding * 2, y - gap - origin.y + padding)
        // **And the card has to be tall enough for the PICTURE, which no part of
        // `y` knows about.** The thumbnail is placed against the card's own top
        // edge rather than after the text — that is the whole point of it — so a
        // card whose text is shorter than eighty points was drawn shorter than
        // the picture inside it, and the picture hung out of the bottom.
        //
        // Any `type: "link"` unfurl with a title and no description does this,
        // which is every Spotify track, every bare article link, and most of
        // what a transcript actually contains. The older enclosure test missed
        // it because its fixture had twenty lines of description — a fixture
        // unlike the caller's input guards the bug rather than catching it.
        if hasThumbnail { height = max(height, padding * 2 + thumbnailSide) }
        return EmbedSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: cardWidth, height: height),
            accent: embed.colorValue.flatMap { $0 == 0 ? nil : NSColor(Color(hex: $0)) },
            texts: texts,
            images: images
        )
    }

    /// A picture with nothing around it.
    ///
    /// **Sized by the picture, not by the column.** This used to take the full
    /// available width whatever the source was and then cap the *height* alone
    /// — so a 180x320 GIF was drawn 432 points wide and 300 tall, which is both
    /// four times its own resolution and the wrong shape. Both dimensions move
    /// together or neither does, and neither goes past the source's own pixels.
    /// `TimelineLayoutEngine.mediaBox` is the one copy of that rule; a second
    /// one here is a second place for it to drift.
    private static func bareImage(
        _ media: Embed.Media,
        in embed: Embed,
        origin: CGPoint,
        availableWidth: CGFloat
    ) -> EmbedSlot {
        let box = TimelineLayoutEngine.mediaBox(
            width: media.width,
            height: media.height,
            availableWidth: min(Metrics.embedMaxWidth, availableWidth),
            maximumHeight: imageMaxHeight
        )
        let width = box.width
        let height = box.height
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        // GIF only: an animated WebP is labelled exactly as a still one, so
        // there is no fact here to act on. Same rule as `CDN.canAnimate`.
        let isAnimated = URL(string: media.proxyURL ?? media.url)
            .map(CDN.canAnimate) ?? false
        return EmbedSlot(
            rect: rect,
            // No accent: there is no rule to draw it on.
            accent: nil,
            drawsCard: false,
            texts: [],
            images: [EmbedImage(
                rect: rect,
                // **Whole, not resized, when it moves.** `width=` on a GIF path
                // answers with a single frame, so a resized rendition is an
                // animation with nothing to play; `AnimatedImageStore`
                // downsamples at decode instead.
                url: isAnimated
                    ? URL(string: media.proxyURL ?? media.url)
                    : CDN.resizedAttachment(
                        proxyURL: media.proxyURL ?? media.url, width: width
                    ),
                isCircle: false,
                corner: corner,
                decodeWidth: width,
                isArtwork: true,
                isAnimated: isAnimated
            )],
            favorite: favorite(for: embed, media: media, animates: isAnimated),
            favoriteRect: TimelineLayoutEngine.favoriteBadgeRect(in: rect)
        )
    }

    /// The GIF an unfurled embed would be starred as.
    ///
    /// **`gifv` is a declaration, not an observation, and gating on whether the
    /// picture animates was wrong.** A captured Klipy unfurl —
    /// `search messages1.har` — is `type: "gifv"` with a **`.webp`** thumbnail
    /// and an `.mp4` beside it, and `CDN.canAnimate` answers on the extension
    /// alone, so that GIF would have had no star while Tenor's `.gif` did. What
    /// makes something starrable is that Discord called it a GIF.
    ///
    /// **The embed's own URL is the key**, not the picture's: that is the link
    /// in the message, it is what `setFavorite` files the entry under, and it is
    /// what re-sending a favourite puts back in a channel. Storing the CDN
    /// rendition instead would favourite a picture nobody could unfurl.
    ///
    /// The preview is the drawable rendition — the `.mp4` a `gifv` carries is a
    /// tile that never resolves in the picker this favourite lands in.
    private static func favorite(
        for embed: Embed, media: Embed.Media, animates: Bool
    ) -> GIF? {
        guard embed.kind == "gifv" || animates else { return nil }
        guard let link = embed.url.flatMap(URL.init(string:)), link.scheme == "https"
        else { return nil }
        return GIF(
            url: link,
            previewURL: GIF.drawable([
                URL(string: media.proxyURL ?? media.url), URL(string: media.url),
            ]),
            width: media.width,
            height: media.height
        )
    }

    /// The field grid.
    ///
    /// Consecutive inline fields share a row, up to three; anything else takes
    /// the full width. Its own function because it is the one part of an embed
    /// whose loop carries state between iterations, and inlining it into the
    /// walk above is what makes that walk hard to follow.
    private static func layoutFields(
        _ fields: [Embed.Field],
        contentX: CGFloat,
        y startY: CGFloat,
        width: CGFloat,
        style: MessageTextStyle,
        mentions: MentionContext,
        parser: MarkdownParser,
        texts: inout [EmbedText]
    ) -> CGFloat {
        guard !fields.isEmpty else { return startY }
        var y = startY
        let nameFont = NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .bold)
        var index = 0

        while index < fields.count {
            // How many of the next fields belong on this row.
            var span = 1
            if fields[index].isInline {
                while span < fieldsPerRow,
                      index + span < fields.count,
                      fields[index + span].isInline
                {
                    span += 1
                }
            }
            let columnWidth = (width - CGFloat(span - 1) * gap) / CGFloat(span)
            var rowHeight: CGFloat = 0

            for column in 0..<span {
                let field = fields[index + column]
                let x = contentX + CGFloat(column) * (columnWidth + gap)
                let name = plainBlock(
                    field.name,
                    font: nameFont,
                    color: style.primaryColor,
                    width: columnWidth,
                    link: nil,
                    style: style
                )
                texts.append(EmbedText(block: name, origin: CGPoint(x: x, y: y)))
                let value = markdownBlock(
                    field.value,
                    width: columnWidth,
                    style: style,
                    mentions: mentions,
                    parser: parser
                )
                texts.append(EmbedText(
                    block: value,
                    origin: CGPoint(x: x, y: y + name.size.height + 2)
                ))
                rowHeight = max(rowHeight, name.size.height + 2 + value.size.height)
            }

            y += rowHeight + gap
            index += span
        }
        return y
    }

    /// The footer's one line: its text, its timestamp, or both joined the way
    /// Discord joins them.
    private static func footerLine(_ embed: Embed) -> String? {
        let stamp = embed.timestamp.map {
            $0.formatted(.dateTime.day().month().year().hour().minute(.twoDigits))
        }
        // A `switch` expression cannot infer `String?` from a bare `nil` here,
        // and the explicit returns read better than annotating one anyway.
        if let text = embed.footer?.text, !text.isEmpty {
            return stamp.map { "\(text) • \($0)" } ?? text
        }
        return stamp
    }

    /// A plain styled run, laid out.
    ///
    /// The `style` it is handed is the message's own and is used for nothing but
    /// the inline-emoji box metrics `TimelineTextBlock` reads — which a run with
    /// no inline emoji never consults. Building a whole `MessageTextStyle` per
    /// part would be seven font lookups and ten colour resolutions for three
    /// numbers nothing reads.
    private static func plainBlock(
        _ string: String,
        font: NSFont,
        color: NSColor,
        width: CGFloat,
        link: String?,
        style: MessageTextStyle
    ) -> TimelineTextBlock {
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: color]
        )
        var links: [MessageText.LinkRun] = []
        // The scheme is checked here rather than at the click: an embed's URLs
        // come from whatever an app chose to send, and a link node built for a
        // scheme this client will not open is a target that swallows the click.
        if let link, InlineScannerSchemeCheck.isSafe(link) {
            links.append(.init(
                range: NSRange(location: 0, length: attributed.length),
                target: MessageLink.parse(link).map { .message($0) } ?? .url(link)
            ))
        }
        return TimelineTextBlock(
            text: .plain(attributed, links: links),
            width: width,
            style: style
        )
    }

    /// A markdown run — descriptions, field values and every Components V2 text
    /// display carry the bold, the lists, the inline code and the **custom
    /// emoji** a release note is written in.
    ///
    /// Shared with `ComponentsLayoutEngine`, because an app's prose is the same
    /// prose whichever shape it arrives in — and running one of them through a
    /// plain attributed string is how `<:sakura:123>` ends up on screen as
    /// literal angle brackets.
    static func markdown(
        _ source: String,
        width: CGFloat,
        context: ComponentsLayoutEngine.Context
    ) -> TimelineTextBlock {
        markdownBlock(
            source,
            width: width,
            style: context.style,
            mentions: context.mentions,
            parser: context.parser
        )
    }

    private static func markdownBlock(
        _ source: String,
        width: CGFloat,
        style: MessageTextStyle,
        mentions: MentionContext,
        parser: MarkdownParser
    ) -> TimelineTextBlock {
        let text = MessageTextBuilder.build(
            document: parser.parse(source),
            context: mentions,
            style: style
        )
        return TimelineTextBlock(text: text, width: width, style: style)
    }
}
