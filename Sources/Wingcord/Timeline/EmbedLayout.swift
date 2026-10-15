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
    /// The leading rule's colour. Nil for a card with no accent — which draws
    /// Discord's neutral rule if it is a link's card (`isLinkCard`), and no rule
    /// if it is a Components V2 container, which has none.
    var accent: NSColor?
    /// Whether there is a card at all.
    ///
    /// **An explicit flag rather than "does it have text".** A bare image embed
    /// and a loose Components V2 text display both draw content with no ground
    /// behind it, and inferring that from the parts present is a rule that
    /// silently changes the day something gains a caption.
    var drawsCard: Bool = true
    /// Discord's `embedFull`: a link's card, which draws a neutral rule where
    /// the embed names no colour and a hairline round its edge. A Components
    /// V2 container has neither.
    var isLinkCard = false
    var texts: [EmbedText]
    var images: [EmbedImage]
    /// Rules drawn inside the card — a Components V2 separator.
    var rules: [CGRect] = []
    /// A Spotify card's own controls, when this embed is one.
    ///
    /// **A chip is a rect and a kind, resolved at layout time like everything
    /// else here** — the painter fills a shape and draws a glyph, and the hit
    /// test reads the same rects, so a control drawn in one place and clicked in
    /// another is impossible by construction.
    var chips: [EmbedChip] = []
    /// The thirty-second clip the Preview chip plays. Nil for a card whose
    /// entity has none, which is why the chip is absent rather than disabled.
    var previewURL: URL?
    /// The card the Open chip raises Spotify's own player for. Carried whole
    /// because the panel needs its title, its kind and its id — and the kind is
    /// what decides the panel's height.
    var spotify: SpotifyUnfurl?
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

/// One small control or badge on an embed's card.
nonisolated struct EmbedChip: Sendable {
    enum Kind: Sendable {
        /// Plays the thirty-second clip. The only one that takes a click.
        case preview
        /// The `E` Spotify puts on an explicit track. A mark, not a control.
        case explicit
        /// Raises Spotify's own player beside the card — the full track for
        /// anybody signed in there, and the library controls this client cannot
        /// offer. See `SpotifyPlayerSession` for what it costs and why it is
        /// asked for rather than always present.
        case open
    }

    var rect: CGRect
    var kind: Kind
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
    /// Whether the picture covers its box, cropping, rather than filling it —
    /// a gallery's cells, which are the mosaic's shapes and not the pictures'.
    var cropsToFill = false
    /// The clip this picture is the poster of.
    var video: EmbedVideo?
    /// Play and Open Link over a site's player, in the row's space. Nil for
    /// everything that is not one.
    var controls: EmbedPlayControls?
    /// Discord's blurred stand-in, drawn until the picture lands.
    var placeholder: String?
    /// A gallery item sent as a spoiler: drawn covered, and never fetched.
    var isSpoiler = false
}

/// A clip an embed's picture stands in for.
nonisolated enum EmbedVideo: Sendable, Hashable {
    /// A GIF that is an MP4 — Tenor's and Giphy's are. Their unfurl is a
    /// `gifv` whose thumbnail is a still, and drawing that still for ever is
    /// "GIFs do not animate" for most GIFs people send. Discord plays the clip
    /// muted, looping, on its own, with the thumbnail as its poster (module
    /// `175671`'s `ei`, the video's proxy URL first); so does the transcript,
    /// on a layer.
    case loop(URL)
    /// A site's own player — YouTube, Twitch, TikTok — which the Play control
    /// starts in place of the thumbnail, as Discord's iframe does.
    case player(URL)
    /// A video file the card plays itself — Blip's MP4 — which the Play
    /// control starts in place, as Discord's `<video>` does.
    case file(URL)

    /// What the Play control starts, for the two that have one.
    var isPlayable: Bool {
        switch self {
        case .player, .file: true
        case .loop: false
        }
    }

    var isLoop: Bool {
        if case .loop = self { return true }
        return false
    }
}

/// Discord's two controls over a video's thumbnail (module `821209`): Play,
/// and Open Link, side by side in the middle.
nonisolated struct EmbedPlayControls: Sendable, Hashable {
    var play: CGRect
    var open: CGRect
    /// Where Open Link goes: the page, not the player.
    var page: URL

    static let side: CGFloat = 40
    static let gap: CGFloat = 12

    init(centeredIn box: CGRect, page: URL) {
        let side = Self.side
        let y = box.midY - side / 2
        let left = box.midX - side - Self.gap / 2
        play = CGRect(x: left, y: y, width: side, height: side)
        open = CGRect(x: left + side + Self.gap, y: y, width: side, height: side)
        self.page = page
    }
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

    /// Discord's `.gridContainer { max-width: 516px }`: a link's card's
    /// content, the rule outside it.
    static let maxWidth: CGFloat = 516
    /// `.grid`'s padding past the rule's 12: 16 at the trailing edge and the
    /// foot, and 2 at the top — where every part's own `embedMargin` of 8
    /// stands above it, so the first sits 10 down.
    static let trailingPadding: CGFloat = 16
    static let topPadding: CGFloat = 10
    static let bottomPadding: CGFloat = 16
    /// `.embedFull .embedMedia { margin-top: 16px }`.
    static let mediaGap: CGFloat = 16
    /// `.embed { border-radius: 4px }`, and its pictures'.
    static let cardCorner: CGFloat = 4
    /// `.embedAuthorIcon`: 24, round, 8 before the name.
    static let authorIconSide: CGFloat = 24
    /// `.embedThumbnail { margin-inline-start: 16px }`.
    static let thumbnailGap: CGFloat = 16
    /// Discord's `text-sm` against its 16 px body — an embed's author, its
    /// description and its fields.
    static let smallScale: CGFloat = 0.875

    /// The square cover on a music card.
    static let coverSide: CGFloat = 76
    /// A chip on one, and the `E` badge beside it.
    static let chipHeight: CGFloat = 20

    /// Lays one embed out at `origin`, inside `availableWidth`.
    ///
    /// - Parameter spotify: the card Spotify's own embed page answered with, if
    ///   this link is one and it has been resolved. **Nil is the ordinary
    ///   state** — before the fetch lands, and for ever if it fails — and it
    ///   falls through to the link unfurl Discord sent, which is a correct card
    ///   that says less.
    static func layout(
        _ embed: Embed,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle,
        mentions: MentionContext,
        parser: MarkdownParser,
        spotify: SpotifyUnfurl? = nil,
        footerStamp: String? = nil
    ) -> EmbedSlot {
        if let spotify {
            return musicCard(spotify, origin: origin, availableWidth: availableWidth, style: style)
        }
        // **An embed that is nothing but a picture gets no card at all.** That
        // is what a pasted image link unfurls into, and drawing a bordered box
        // with twelve points of padding around a photograph is a frame nobody
        // asked for — `Embed.isBareImage` exists to name exactly this case.
        if let media = embed.bareMedia {
            return bareImage(media, in: embed, origin: origin, availableWidth: availableWidth)
        }

        var cardWidth = min(ruleWidth + maxWidth, availableWidth)
        let small = style.scaled(smallScale)
        // **Discord's normaliser decides which picture is which** (module
        // `659674`'s `L`): an article's thumbnail is its picture, drawn large
        // under the text — Qwertykeys' logo — where any other kind keeps it in
        // the corner, as VIA's chip. An explicit `image` wins over either.
        let isArticle = embed.kind == "article"
        let picture = embed.image ?? (isArticle ? embed.thumbnail : nil)
        // **A video is its media, not a corner thumbnail**: Discord draws the
        // thumbnail only when an embed has no media (module `175671`'s
        // `renderAll`). A site's player — YouTube — is media, and so is a video
        // file the card plays itself — Blip's MP4.
        let player = Self.playerURL(for: embed)
        let file = player == nil ? Self.videoFile(of: embed, isArticle: isArticle) : nil
        let videoPoster = player != nil ? (embed.thumbnail ?? embed.image) : nil
        let hasMedia = videoPoster != nil || file != nil
        // Fitted inside Discord's 80 by 80, never cropped to it — and the
        // whole square for one whose shape the unfurl did not say.
        let thumbnailBox = (!isArticle && !hasMedia ? embed.thumbnail : nil).map { thumbnail in
            thumbnail.pixelSize == nil
                ? CGSize(width: thumbnailSide, height: thumbnailSide)
                : TimelineLayoutEngine.mediaBox(
                    width: thumbnail.width, height: thumbnail.height,
                    availableWidth: thumbnailSide, maximumHeight: thumbnailSide
                )
        }
        let contentX = origin.x + ruleWidth + padding
        let fullContentWidth = max(40, cardWidth - ruleWidth - padding - trailingPadding)
        let contentWidth = thumbnailBox.map { max(40, fullContentWidth - $0.width - thumbnailGap) } ?? fullContentWidth

        var texts: [EmbedText] = []
        var images: [EmbedImage] = []
        var y = origin.y + topPadding

        // The site, over everything — Discord's `embedProvider`: "Blip",
        // "Qwertykeys", "YouTube".
        if let provider = embed.providerName, !provider.isEmpty {
            // `text-xs/normal`.
            let block = plainBlock(
                provider,
                font: style.metadataFont,
                color: style.secondaryColor,
                width: contentWidth,
                link: nil,
                style: style
            )
            texts.append(EmbedText(block: block, origin: CGPoint(x: contentX, y: y)))
            y += block.size.height + gap
        }

        // The author row: a circular mark and a name, on one line.
        if let author = embed.author {
            var textX = contentX
            var markHeight: CGFloat = 0
            if let icon = author.iconURL.flatMap(URL.init(string:)) {
                images.append(EmbedImage(
                    rect: CGRect(x: contentX, y: y, width: authorIconSide, height: authorIconSide),
                    url: icon,
                    isCircle: true,
                    corner: authorIconSide / 2,
                    decodeWidth: authorIconSide,
                    isArtwork: false
                ))
                textX += authorIconSide + 8
                markHeight = authorIconSide
            }
            // `.embedAuthorName`: `.875rem`, semibold.
            let block = plainBlock(
                author.name,
                font: NSFont.systemFont(ofSize: small.bodyFont.pointSize, weight: .semibold),
                color: style.primaryColor,
                width: max(20, contentWidth - (textX - contentX)),
                link: author.url,
                style: style
            )
            // Centred on the mark rather than sharing its top edge, as
            // `.embedAuthor`'s `align-items: center` sets it.
            let rowHeight = max(markHeight, block.size.height)
            texts.append(EmbedText(
                block: block,
                origin: CGPoint(x: textX, y: y + (rowHeight - block.size.height) / 2)
            ))
            y += rowHeight + gap
        }

        if let title = embed.title, !title.isEmpty {
            // `.embedTitle`: `1rem`, semibold.
            let block = plainBlock(
                title,
                font: NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold),
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

        // Discord's `Mg`: an image, a video or a GIF says nothing below its
        // title — the picture is the content.
        if !["image", "video", "gifv"].contains(embed.kind),
           let description = embed.description.map(Self.preLine), !description.isEmpty {
            // `embedDescription text-sm/normal`.
            let block = markdownBlock(
                description,
                width: contentWidth,
                style: small,
                mentions: mentions,
                parser: parser
            )
            texts.append(EmbedText(block: block, origin: CGPoint(x: contentX, y: y)))
            y += block.size.height + gap
        }

        // The thumbnail sits in the top-trailing corner beside everything above,
        // which is why the content above was narrowed rather than the picture
        // placed after it.
        var thumbnailIndex: Int?
        if let box = thumbnailBox, let thumbnail = embed.thumbnail {
            // A bot's GIF moves where Discord's does, in the corner as in the
            // card's body.
            let moves = thumbnail.playsAsAnimated
            thumbnailIndex = images.count
            images.append(EmbedImage(
                rect: CGRect(
                    x: origin.x + cardWidth - trailingPadding - box.width,
                    y: origin.y + topPadding,
                    width: box.width,
                    height: box.height
                ),
                url: CDN.resizedAttachment(
                    proxyURL: thumbnail.proxyURL ?? thumbnail.url,
                    width: box.width,
                    height: box.height,
                    animated: moves
                ),
                isCircle: false,
                corner: cardCorner,
                decodeWidth: box.width,
                isArtwork: true,
                isAnimated: moves,
                placeholder: thumbnail.placeholder
            ))
        }

        y = layoutFields(
            embed.fields,
            contentX: contentX,
            y: y,
            width: fullContentWidth,
            style: small,
            mentions: mentions,
            parser: parser,
            texts: &texts
        )

        // The media's own 16 above it, where every other part has 8.
        if videoPoster != nil || file != nil || picture != nil { y += mediaGap - gap }

        if let poster = videoPoster, let player, let page = embed.url.flatMap(URL.init(string:)) {
            let source = poster.proxyURL ?? poster.url
            let width = fullContentWidth
            // The clip's own shape where the unfurl gives it, the poster's
            // otherwise.
            let aspect = embed.video?.aspectRatio ?? poster.aspectRatio ?? 16.0 / 9.0
            let height = min(imageMaxHeight, width / aspect)
            let rect = CGRect(x: contentX, y: y, width: width, height: height)
            images.append(EmbedImage(
                rect: rect,
                url: CDN.resizedAttachment(proxyURL: source, width: width, height: width / aspect),
                isCircle: false,
                corner: cardCorner,
                decodeWidth: width,
                isArtwork: true,
                video: .player(player),
                controls: EmbedPlayControls(centeredIn: rect, page: page)
            ))
            y += height + gap
        } else if let file {
            // **A video file plays in the card**, Discord's `<video>` — here the
            // site's player's own path, Play starting it in place.
            let box = Self.mediaBox(for: file.poster, in: fullContentWidth)
            let rect = CGRect(x: contentX, y: y, width: box.width, height: box.height)
            images.append(EmbedImage(
                rect: rect,
                url: file.posterURL(box.width, box.height),
                isCircle: false,
                corner: cardCorner,
                decodeWidth: box.width,
                isArtwork: true,
                video: .file(file.url),
                controls: EmbedPlayControls(
                    centeredIn: rect,
                    page: embed.url.flatMap(URL.init(string:)) ?? file.url
                ),
                placeholder: file.poster.placeholder
            ))
            y += box.height + gap
        } else if let image = picture, !embed.galleryImages.isEmpty {
            // **A gallery**: the pictures of the embeds that share this link
            // (`Embed.mergingGalleries`), in the mosaic a message's own
            // pictures use, inside the same 400-point media box.
            let pictures = [image] + embed.galleryImages
            let frames = AttachmentMosaic.frames(
                sizes: pictures.map { $0.pixelSize },
                width: min(400, fullContentWidth)
            )
            for (media, frame) in zip(pictures, frames) {
                let rect = frame.offsetBy(dx: contentX, dy: y)
                let decode = AttachmentMosaic.coverWidth(media.pixelSize, in: rect.size)
                let moves = media.playsAsAnimated
                images.append(EmbedImage(
                    rect: rect,
                    url: CDN.resizedAttachment(
                        proxyURL: media.proxyURL ?? media.url,
                        width: decode,
                        height: media.aspectRatio.map { decode / $0 },
                        animated: moves
                    ),
                    isCircle: false,
                    corner: cardCorner,
                    decodeWidth: decode,
                    isArtwork: true,
                    isAnimated: moves,
                    cropsToFill: true,
                    placeholder: media.placeholder
                ))
            }
            y += (frames.map(\.maxY).max() ?? 0) + gap
        } else if let image = picture {
            let source = image.proxyURL ?? image.url
            // Discord's media box, 400 by 300 (module `659674`'s `G`), which a
            // picture is fitted inside rather than stretched across: a tall one
            // comes back narrower, never squeezed.
            let box = Self.mediaBox(for: image, in: fullContentWidth)
            let moves = image.playsAsAnimated
            images.append(EmbedImage(
                rect: CGRect(x: contentX, y: y, width: box.width, height: box.height),
                url: CDN.resizedAttachment(
                    proxyURL: source, width: box.width, height: box.height, animated: moves
                ),
                isCircle: false,
                corner: cardCorner,
                decodeWidth: box.width,
                isArtwork: true,
                isAnimated: moves,
                placeholder: image.placeholder
            ))
            y += box.height + gap
        }

        if let footer = footerLine(embed, stamp: footerStamp) {
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
                textX += markSide + 8
            }
            // `embedFooterText text-xs/medium` in `--text-default`.
            let block = plainBlock(
                footer,
                font: NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .medium),
                color: style.primaryColor,
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
        var height = max(topPadding + bottomPadding, y - gap - origin.y + bottomPadding)
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
        if let box = thumbnailBox { height = max(height, topPadding + box.height + bottomPadding) }
        // **As wide as what is in it** — Discord's card is `max-width:
        // max-content`, so VIA's is its two lines and its chip rather than the
        // column. A field grid is laid across the whole width, so a card with
        // fields keeps it.
        if embed.fields.isEmpty {
            let fitted = Self.fittedWidth(
                texts: texts, images: images, thumbnailIndex: thumbnailIndex, contentX: contentX, cap: cardWidth
            )
            if fitted < cardWidth {
                if let thumbnailIndex { images[thumbnailIndex].rect.origin.x -= cardWidth - fitted }
                cardWidth = fitted
            }
        }
        return EmbedSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: cardWidth, height: height),
            accent: embed.colorValue.flatMap { $0 == 0 ? nil : NSColor(Color(hex: $0)) },
            isLinkCard: true,
            texts: texts,
            images: images
        )
    }

    /// The width a card's content reaches, rule and padding included — what
    /// `max-content` resolves to — capped at `cap`.
    private static func fittedWidth(
        texts: [EmbedText], images: [EmbedImage], thumbnailIndex: Int?, contentX: CGFloat, cap: CGFloat
    ) -> CGFloat {
        var extent: CGFloat = 0
        for text in texts {
            extent = max(extent, text.origin.x - contentX + usedWidth(of: text.block))
        }
        for (index, image) in images.enumerated() where index != thumbnailIndex {
            extent = max(extent, image.rect.maxX - contentX)
        }
        if let thumbnailIndex { extent += thumbnailGap + images[thumbnailIndex].rect.width }
        return min(cap, ceil(ruleWidth + padding + trailingPadding + extent))
    }

    /// A block's `max-content` width: how far its lines reach where none was
    /// broken for want of room, against `size.width`, which is the width it
    /// was *given* (`INVARIANTS.md` §4.85). A line the width broke means the
    /// content is wider than it was given, and the answer is all of it — as a
    /// wrapped card in Discord is as wide as the column allows. Trailing
    /// whitespace is not ink (§2.8), and a quote or a code block is drawn to
    /// the edge whatever its lines say.
    static func usedWidth(of block: TimelineTextBlock) -> CGFloat {
        guard block.quoteRules.isEmpty, block.codeBlockRects.isEmpty,
              let lines = CTFrameGetLines(block.frame) as? [CTLine], !lines.isEmpty
        else { return block.size.width }
        let hardBreaks = block.text.attributed.string.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        guard lines.count <= hardBreaks + 1 else { return block.size.width }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(block.frame, CFRange(location: 0, length: 0), &origins)
        var widest: CGFloat = 0
        for (line, origin) in zip(lines, origins) {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            widest = max(widest, origin.x + width)
        }
        return min(block.size.width, ceil(widest))
    }

    /// Discord's media box — 400 by 300, module `659674`'s `G` — and never
    /// wider than the card leaves, with the picture fitted inside it.
    private static func mediaBox(for media: Embed.Media, in available: CGFloat) -> CGSize {
        TimelineLayoutEngine.mediaBox(
            width: media.width,
            height: media.height,
            availableWidth: min(400, available),
            maximumHeight: imageMaxHeight
        )
    }

    /// A video the card plays itself, and the poster it waits behind —
    /// Discord's rule for an embed's `video` (module `659674`'s `L`).
    ///
    /// **One with dimensions, carried by Discord's media proxy, and not
    /// Sketchfab's**, whose "video" is a page. Discord also plays an `https`
    /// address with no proxy copy; this client does not, because every such
    /// `video` in the captures is a site's player page — YouTube's embed, and
    /// any look-alike of it — and only the proxy's copy is known to be a file.
    /// Its poster is the embed's corner thumbnail where it keeps one; an
    /// article's thumbnail has become its picture, so its poster is the
    /// proxy's own still of the file, which is what Discord shows for Blip.
    struct VideoFile {
        var url: URL
        var poster: Embed.Media
        /// A still of the file, from the proxy — an image `format` on a video path.
        var usesFrameOfFile: Bool

        func posterURL(_ width: CGFloat, _ height: CGFloat) -> URL? {
            let source = poster.proxyURL ?? poster.url
            return usesFrameOfFile
                ? CDN.videoPoster(proxyURL: source, width: width, height: height)
                : CDN.resizedAttachment(proxyURL: source, width: width, height: height)
        }
    }

    static func videoFile(of embed: Embed, isArticle: Bool) -> VideoFile? {
        guard let video = embed.video, (video.width ?? 0) > 0, (video.height ?? 0) > 0 else { return nil }
        let isSketchfab = embed.providerName?.range(of: "sketchfab", options: .caseInsensitive) != nil
            || video.url.lowercased().hasPrefix("https://sketchfab.com")
        guard !isSketchfab, let proxy = video.proxyURL, let url = URL(string: proxy) else { return nil }
        if !isArticle, let thumbnail = embed.thumbnail {
            return VideoFile(url: url, poster: thumbnail, usesFrameOfFile: false)
        }
        return VideoFile(url: url, poster: video, usesFrameOfFile: true)
    }

    /// An embed description as Discord sets it: `white-space: pre-line`.
    ///
    /// **Runs of spaces and tabs are one space, and a line starts at its first
    /// word** — the line breaks themselves stay. Blip's description carries a
    /// newline and eight tabs mid-sentence, and laid out as written the tab
    /// stops pushed "directly to" to the far edge of the card. A code fence
    /// keeps its own spacing, as `<pre>` does inside Discord's.
    static func preLine(_ text: String) -> String {
        guard text.contains(where: { $0 == "\t" || $0 == " " }) else { return text }
        var inFence = false
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); lines.append(line); continue }
            if inFence { lines.append(line); continue }
            var collapsed = ""
            var pendingSpace = false
            for character in line {
                if character == " " || character == "\t" {
                    pendingSpace = !collapsed.isEmpty
                } else {
                    if pendingSpace { collapsed.append(" ") }
                    pendingSpace = false
                    collapsed.append(character)
                }
            }
            lines.append(Substring(collapsed))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: A music card

    /// The card behind a Spotify link.
    ///
    /// **Wingcord's own card, not a copy of Discord's blue slab.** It is the
    /// same object every other embed here is — a rounded ground with an accent
    /// rule down its leading edge — and what Spotify's page contributes is the
    /// *colour* of that rule, quantised from the artwork rather than the brand's
    /// green. A square cover, a name, whoever made it, and a row of small
    /// controls under them.
    ///
    /// Its height is the cover's or its text's, whichever is taller, so a track
    /// with a long title and one with none are the same card.
    private static func musicCard(
        _ card: SpotifyUnfurl,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> EmbedSlot {
        let cardWidth = min(Metrics.embedMaxWidth, availableWidth)
        let contentX = origin.x + ruleWidth + padding
        let textX = contentX + coverSide + gap
        let textWidth = max(40, origin.x + cardWidth - padding - textX)

        var texts: [EmbedText] = []
        var chips: [EmbedChip] = []
        var y = origin.y + padding

        // What kind of thing it is, above the name. Small and quiet: it is the
        // answer to "why is there a card here", which the reader only needs
        // once.
        let kindBlock = plainBlock(
            card.kind.label.uppercased(),
            font: NSFont.systemFont(ofSize: style.metadataFont.pointSize - 1, weight: .semibold),
            color: style.tertiaryColor,
            width: textWidth,
            link: nil,
            style: style
        )
        texts.append(EmbedText(block: kindBlock, origin: CGPoint(x: textX, y: y)))
        y += kindBlock.size.height + 2

        let titleBlock = plainBlock(
            card.title,
            font: NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .bold),
            color: style.primaryColor,
            width: textWidth,
            link: nil,
            style: style
        )
        texts.append(EmbedText(block: titleBlock, origin: CGPoint(x: textX, y: y)))
        y += titleBlock.size.height + 1

        if let subtitle = card.subtitle, !subtitle.isEmpty {
            let block = plainBlock(
                subtitle,
                font: style.bodyFont,
                color: style.secondaryColor,
                width: textWidth,
                link: nil,
                style: style
            )
            texts.append(EmbedText(block: block, origin: CGPoint(x: textX, y: y)))
            y += block.size.height
        }

        // The controls, on one line under the name. Everything on it is
        // optional and the row collapses to nothing when none of it applies —
        // an artist page has no clip, no rating and no length.
        y += gap
        var chipX = textX
        if card.previewURL != nil {
            let font = NSFont.systemFont(
                ofSize: style.metadataFont.pointSize, weight: .semibold
            )
            // **Measured, not proposed.** A `TimelineTextBlock`'s size is the
            // width it was *given* — which is right for a paragraph that wraps
            // and useless for a label on a chip: asked for at the column's
            // width, "Preview" reports 288 points and the row walks off the
            // card. Every inline element here is measured first and framesetted
            // at that width, so the block and the shape under it agree.
            let labelWidth = Self.measuredWidth(of: "Preview", font: font)
            let width = labelWidth + chipHeight + padding
            let label = plainBlock(
                "Preview",
                font: font,
                color: style.primaryColor,
                width: labelWidth,
                link: nil,
                style: style
            )
            chips.append(EmbedChip(
                rect: CGRect(x: chipX, y: y, width: width, height: chipHeight),
                kind: .preview
            ))
            texts.append(EmbedText(
                block: label,
                origin: CGPoint(
                    x: chipX + chipHeight - Spacing.hair,
                    y: y + (chipHeight - label.size.height) / 2
                )
            ))
            chipX += width + Spacing.tight
        }
        if card.isExplicit {
            chips.append(EmbedChip(
                rect: CGRect(x: chipX, y: y, width: chipHeight, height: chipHeight),
                kind: .explicit
            ))
            chipX += chipHeight + Spacing.tight
        }
        if let duration = card.durationLabel {
            let width = Self.measuredWidth(of: duration, font: style.metadataFont)
            let block = plainBlock(
                duration,
                font: style.metadataFont,
                color: style.tertiaryColor,
                width: width,
                link: nil,
                style: style
            )
            texts.append(EmbedText(
                block: block,
                origin: CGPoint(
                    x: chipX, y: y + (chipHeight - block.size.height) / 2
                )
            ))
            chipX += width
        }
        // The way into Spotify's own player, at the trailing edge of the
        // control row. **Always offered**, because it is the only route to a
        // full track and to the library, and neither depends on anything this
        // client can see in advance.
        let openRect = CGRect(
            x: origin.x + cardWidth - padding - chipHeight,
            y: y,
            width: chipHeight,
            height: chipHeight
        )
        // Unless the row has already run into it, in which case the row wins:
        // a control drawn over a duration is two things in one place.
        if chipX + Spacing.tight < openRect.minX {
            chips.append(EmbedChip(rect: openRect, kind: .open))
        }

        // Only where something was actually put on it.
        let hasControls = !chips.isEmpty || card.durationLabel != nil
        y += hasControls ? chipHeight : -gap

        var images: [EmbedImage] = []
        let coverRect = CGRect(
            x: contentX, y: origin.y + padding, width: coverSide, height: coverSide
        )
        images.append(EmbedImage(
            rect: coverRect,
            url: card.coverURL,
            isCircle: false,
            corner: corner,
            decodeWidth: coverSide,
            isArtwork: true
        ))

        // The taller of the two columns decides the card, so artwork never hangs
        // out of the bottom — the defect a link unfurl with a short title had.
        let height = max(coverSide, y - origin.y - padding) + padding * 2
        return EmbedSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: cardWidth, height: height),
            accent: card.accentValue.map { NSColor(Color(hex: $0)) },
            texts: texts,
            images: images,
            chips: chips,
            previewURL: card.previewURL,
            spotify: card
        )
    }

    /// How wide a short label actually is.
    ///
    /// **`TimelineTextBlock` cannot answer this**: its size is the width it was
    /// proposed, because it exists to lay out paragraphs that wrap. Anything
    /// laid out *in a row* — a chip, a badge, a duration — has to be measured
    /// before it is placed, or the row is arranged against a number that is the
    /// column's width rather than the text's.
    static func measuredWidth(of text: String, font: NSFont) -> CGFloat {
        (text as NSString)
            .size(withAttributes: [.font: font])
            .width
            .rounded(.up)
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
        // Discord's own rule: a `.gif` always, a WebP when Discord marked it.
        let isAnimated = media.playsAsAnimated
        return EmbedSlot(
            rect: rect,
            // No accent: there is no rule to draw it on.
            accent: nil,
            drawsCard: false,
            texts: [],
            images: [EmbedImage(
                rect: rect,
                // Resized whether or not it moves: the proxy keeps every frame
                // of a GIF it resizes, and of a WebP when asked. See
                // `CDN.resizedAttachment`.
                url: CDN.resizedAttachment(
                    proxyURL: media.proxyURL ?? media.url, width: width, height: height, animated: isAnimated
                ),
                isCircle: false,
                corner: corner,
                decodeWidth: width,
                isArtwork: true,
                isAnimated: isAnimated,
                video: embed.kind == "gifv"
                    ? embed.video.flatMap { URL(string: $0.proxyURL ?? $0.url) }.map(EmbedVideo.loop)
                    : nil,
                placeholder: media.placeholder
            )],
            favorite: favorite(for: embed, media: media, animates: isAnimated),
            favoriteRect: TimelineLayoutEngine.favoriteBadgeRect(in: rect)
        )
    }

    /// The player a video embed's Play control starts, or nil when there is
    /// none — Discord's module `259407`, which plays exactly these three
    /// sites in place and adds each one's own parameters.
    ///
    /// **Twitch will not play without `parent`**, the page it is framed in;
    /// Discord names its own hosts and so does this, because the player is
    /// loaded as if framed by discord.com — see `EmbedPlayerView`.
    static func playerURL(for embed: Embed) -> URL? {
        guard embed.kind == "video", let source = embed.video?.url,
              var components = URLComponents(string: source), components.scheme == "https",
              let host = components.host?.lowercased()
        else { return nil }
        // Each site's player from that site's own host and nowhere else: the
        // page it is framed in is discord.com's, and a player is somebody
        // else's message.
        func hosted(_ domains: String...) -> Bool {
            domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        var items = components.queryItems ?? []
        func set(_ name: String, _ value: String) {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }
        switch embed.providerName {
        case "YouTube":
            guard hosted("youtube.com", "youtube-nocookie.com") else { return nil }
            set("autoplay", "1")
            set("auto_play", "1")
        case "Twitch":
            guard hosted("twitch.tv") else { return nil }
            items.removeAll { $0.name == "parent" }
            for parent in ["discord.co", "discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com", "localhost"] {
                items.append(URLQueryItem(name: "parent", value: parent))
            }
            set("autoplay", "true")
        case "TikTok":
            guard hosted("tiktok.com") else { return nil }
            set("utm_source", "discord.gg")
        default:
            return nil
        }
        components.queryItems = items
        return components.url
    }

    /// The GIF an unfurled embed would be starred as.
    ///
    /// **`gifv` is a declaration, not an observation, and gating on whether the
    /// picture animates was wrong.** A captured Klipy unfurl —
    /// `search messages1.har` — is `type: "gifv"` with an unmarked **`.webp`**
    /// thumbnail and an `.mp4` beside it, which `playsAsAnimated` calls still,
    /// so that GIF would have had no star while Tenor's `.gif` did. What makes
    /// something starrable is that Discord called it a GIF.
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
        // `embedFieldName text-sm/semibold` — `style` is the embed's small one.
        let nameFont = NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold)
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
    /// Discord joins them — the time in the transcript's own calendar words
    /// (`58703.mk`), which the caller hands in as `stamp`.
    private static func footerLine(_ embed: Embed, stamp: String?) -> String? {
        let stamp = embed.timestamp == nil ? nil : stamp
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
                target: ChannelLink.parse(link).map { .channelLink($0, url: link) } ?? .url(link)
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
