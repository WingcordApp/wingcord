import AppKit
import CoreGraphics
import CoreText
import Foundation
import WingcordCore

/// Draws the two things a bot puts under its message: the embed, and the
/// controls beneath it.
///
/// **The painter has no cases.** `EmbedLayoutEngine` resolved the whole
/// structure — which parts exist, where each one goes, how wide the text wrapped
/// — into a list of text frames and a list of rectangles, so this fills a
/// ground, strokes a rule, blits some already-positioned glyphs and draws some
/// pictures. That is the whole point of doing the structure at layout time: a
/// repaint of a channel full of release notes costs no framesetting at all.
///
/// Its own file because it is a self-contained surface with its own vocabulary,
/// and `TimelineRowPainter` is already the longest file in the transcript.
/// `nonisolated` on the extension, not per member: the app target defaults to
/// main-actor isolation, and a painter that inherits it cannot be called from a
/// draw pass at all — the escape has to be explicit and greppable, which is the
/// same rule `ImageStore` is written to (`INVARIANTS.md` §5).
nonisolated extension TimelineRowPainter {

    // MARK: Embeds

    static func drawEmbed(
        _ slot: EmbedSlot,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        clock: Double,
        /// The pictures that play on layers over the canvas, by index into the
        /// slot's `images`; their boxes are left to the layers.
        layeredImages: Set<Int> = [],
        /// The star, when the pointer is on this embed. Nil is every embed the
        /// pointer is not on, which is all of them nearly all of the time.
        favorite: FavoriteBadge? = nil,
        /// Whether this card's own clip is the one currently playing, so the
        /// chip says which way the click goes.
        isPlayingPreview: Bool = false
    ) {
        let frame = slot.rect.offsetBy(dx: offset.x, dy: offset.y)
        // A link's card is Discord's `.embed`, rounded 4; a Components V2
        // container keeps its own 8.
        let corner = slot.isLinkCard ? EmbedLayoutEngine.cardCorner : EmbedLayoutEngine.corner

        // A bare image, and a loose Components V2 text display, have no card:
        // one IS the picture and the other is prose. Filling a ground behind
        // either draws a plate nobody asked for.
        if slot.drawsCard {
            // The card and the rule down its leading edge in one clip: the rule
            // is the card's own left column rather than a bar laid over it, so
            // the two share a corner radius and cannot come apart at the top.
            context.saveGState()
            context.addPath(CGPath(
                roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil
            ))
            context.clip()
            context.setFillColor(ThemeInk.current.cardFill)
            context.fill(frame)
            // A link's card always has its rule: the embed's colour, or
            // Discord's neutral `--border-normal` where it names none
            // (`embedFull`, stylesheet `198496`). A container draws only a
            // colour it was given.
            if let rule = slot.accent?.cgColor ?? (slot.isLinkCard ? ThemeInk.current.plates.quoteRule : nil) {
                context.setFillColor(rule)
                context.fill(CGRect(
                    x: frame.minX,
                    y: frame.minY,
                    width: EmbedLayoutEngine.ruleWidth,
                    height: frame.height
                ))
            }
            context.restoreGState()
            // And its edge: one point of `--border-subtle` all the way round.
            if slot.isLinkCard {
                context.saveGState()
                context.addPath(CGPath(
                    roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                    cornerWidth: corner - 0.5,
                    cornerHeight: corner - 0.5,
                    transform: nil
                ))
                context.setStrokeColor(ThemeInk.current.plates.codeBorder)
                context.setLineWidth(1)
                context.strokePath()
                context.restoreGState()
            }
        }

        for rule in slot.rules {
            context.setFillColor(ThemeInk.current.lift(0.10))
            context.fill(rule.offsetBy(dx: offset.x, dy: offset.y))
        }

        // Under the labels, because a chip's own text sits on it.
        for chip in slot.chips {
            drawEmbedChip(
                chip,
                in: chip.rect.offsetBy(dx: offset.x, dy: offset.y),
                context: context,
                style: style,
                isPlaying: isPlayingPreview
            )
        }

        // **The body's own painter**, so a description's quotes, code and
        // mentions wear the same plates as a message's. Its spoilers have no
        // click of their own, so they draw uncovered rather than unreadable.
        for text in slot.texts {
            drawTextBlock(
                text.block,
                at: CGPoint(x: offset.x + text.origin.x, y: offset.y + text.origin.y),
                context: context,
                style: style,
                images: images,
                scale: scale,
                time: clock,
                state: TextState()
            )
        }

        for (index, image) in slot.images.enumerated() where !layeredImages.contains(index) {
            drawEmbedImage(
                image,
                in: image.rect.offsetBy(dx: offset.x, dy: offset.y),
                context: context,
                style: style,
                images: images,
                scale: scale,
                clock: clock
            )
        }

        // A video's Play and Open Link, over its thumbnail — Discord's two
        // controls (module `821209`), as fixed dark discs rather than glass for
        // the reason the attachment's play badge gives.
        for image in slot.images {
            guard let controls = image.controls else { continue }
            drawPlayControl("play.fill", in: controls.play.offsetBy(dx: offset.x, dy: offset.y), context: context)
            drawPlayControl("arrow.up.right", in: controls.open.offsetBy(dx: offset.x, dy: offset.y), context: context)
        }

        // Over the picture, last, and only while the pointer is on it. The same
        // control the attachment painter draws, from the same function.
        if let favorite, slot.favorite != nil {
            drawFavoriteBadge(
                favorite,
                in: slot.favoriteRect.offsetBy(dx: offset.x, dy: offset.y),
                context: context
            )
        }
    }

    /// One small control or badge on a card.
    ///
    /// **No text of its own.** The label was framesetted at layout time and is
    /// drawn with every other text frame; this fills the shape under it and puts
    /// the glyph in. A painter that laid out a string here would be doing
    /// CoreText work inside a repaint, which is the whole thing this surface is
    /// built to avoid.
    private static func drawEmbedChip(
        _ chip: EmbedChip,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        isPlaying: Bool
    ) {
        switch chip.kind {
        case .preview:
            context.addPath(CGPath(
                roundedRect: frame,
                cornerWidth: frame.height / 2,
                cornerHeight: frame.height / 2,
                transform: nil
            ))
            context.setFillColor(ThemeInk.current.lift(0.12))
            context.fillPath()
            let side = frame.height * 0.5
            drawSymbol(
                isPlaying ? "stop.fill" : "play.fill",
                tint: style.primaryColor,
                in: CGRect(
                    x: frame.minX + (frame.height - side) / 2,
                    y: frame.midY - side / 2,
                    width: side,
                    height: side
                ),
                context: context
            )

        case .open:
            context.addPath(CGPath(
                roundedRect: frame,
                cornerWidth: frame.height / 2,
                cornerHeight: frame.height / 2,
                transform: nil
            ))
            context.setFillColor(ThemeInk.current.lift(0.12))
            context.fillPath()
            let side = frame.height * 0.5
            drawSymbol(
                "arrow.up.forward",
                tint: style.secondaryColor,
                in: CGRect(
                    x: frame.midX - side / 2,
                    y: frame.midY - side / 2,
                    width: side,
                    height: side
                ),
                context: context
            )

        case .explicit:
            // Discord's own mark, and Spotify's: a filled square with an E in
            // it, quiet rather than a warning. It says a fact about the track,
            // not something the reader has to act on.
            context.addPath(CGPath(
                roundedRect: frame.insetBy(dx: 2, dy: 2),
                cornerWidth: 4,
                cornerHeight: 4,
                transform: nil
            ))
            context.setFillColor(ThemeInk.current.lift(0.35))
            context.fillPath()
            let font = NSFont.systemFont(ofSize: frame.height * 0.5, weight: .bold)
            drawText(
                "E",
                font: font,
                color: NSColor.black.withAlphaComponent(0.75),
                at: CGPoint(x: frame.minX, y: capCenteredY(of: font, in: frame)),
                maxWidth: frame.width,
                alignment: .center,
                context: context
            )
        }
    }

    /// A laid-out block, plus the pictures its run delegates reserved room for.
    ///
    /// **The inline-emoji pass is the point.** A `CTFrame` draws glyphs; a
    /// custom emoji is an object-replacement character with a run delegate
    /// behind it, so the frame draws a reserved *hole* and something has to put
    /// a picture in it. The message body has always done that — this surface did
    /// not, which is the whole of "an app's custom emoji show up as blank gaps
    /// in its embeds". Every app that writes `<:sakura:123>` into a description
    /// hits it.
    ///
    /// No spoiler pass: an embed's own runs cannot carry one, so the loop the
    /// message body needs would be a walk over an empty array per block per
    /// repaint, and one of these surfaces can hold a dozen blocks.
    static func drawTextFrame(
        _ block: TimelineTextBlock,
        at origin: CGPoint,
        context: CGContext,
        images: ImageStore,
        scale: CGFloat
    ) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + block.size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(block.frame, context)
        context.restoreGState()

        for entry in block.symbolRects {
            drawSymbol(
                entry.name,
                tint: NSColor(Palette.accent),
                in: entry.rect.offsetBy(dx: origin.x, dy: origin.y),
                context: context
            )
        }

        // Nothing at all for the overwhelming majority, which carry none.
        guard !block.emojiRects.isEmpty else { return }
        for entry in block.emojiRects {
            let frame = entry.rect.offsetBy(dx: origin.x, dy: origin.y)
            guard let url = entry.emoji.id.flatMap({
                CDN.emoji(id: $0, animated: entry.emoji.isAnimated, side: frame.width)
            }) else { continue }
            let key = ImageStore.Key(
                url: url,
                maximumPixelSize: Int((frame.width * scale).rounded(.up))
            )
            if let image = images.cached(key) {
                drawFlipped(image, in: frame, context: context, fit: .contain)
            }
            // No plate on a miss here. The box is already reserved, and a soft
            // disc inside a card reads as a bullet rather than as a picture on
            // its way.
        }
    }

    private static func drawEmbedImage(
        _ slot: EmbedImage,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        clock: Double
    ) {
        let shape = slot.isCircle
            ? CGPath(ellipseIn: frame, transform: nil)
            : CGPath(
                roundedRect: frame,
                cornerWidth: slot.corner,
                cornerHeight: slot.corner,
                transform: nil
            )
        context.saveGState()
        context.addPath(shape)
        context.clip()

        let pixels = Int((slot.decodeWidth * scale).rounded(.up))
        var drew = false
        // A spoiler is never drawn, only its cover: the plate, the blurred
        // stand-in and the word, as a spoiler attachment's is.
        if let url = slot.url, !slot.isSpoiler {
            if slot.isAnimated,
               let film = AnimatedImageStore.shared.cached(
                   AnimatedImageStore.Key(url: url, maximumPixelSize: pixels)
               )
            {
                drawFlipped(
                    film.frames[film.index(at: clock)], in: frame, context: context, fit: .init(cropsToFill: slot.cropsToFill)
                )
                drew = true
            } else if let image = images.cached(
                ImageStore.Key(url: url, maximumPixelSize: pixels),
                bucket: slot.isArtwork ? .artwork : .thumbnail
            ) {
                drawFlipped(image, in: frame, context: context, fit: .init(cropsToFill: slot.cropsToFill))
                drew = true
            }
        }
        if !drew {
            // A quiet plate at the picture's own size, so nothing reflows when
            // it lands — the box was already reserved — and Discord's blurred
            // stand-in over it where the embed carried one.
            context.setFillColor(ThemeInk.current.placeholderFill)
            context.fill(frame)
            if let placeholder = PlaceholderImages.shared.image(slot.placeholder) {
                context.interpolationQuality = .high
                drawFlipped(placeholder, in: frame, context: context, fit: .init(cropsToFill: slot.cropsToFill))
            }
        }
        context.restoreGState()
        if slot.isSpoiler {
            drawChip(
                "SPOILER",
                in: CGRect(x: frame.midX - 38, y: frame.midY - 10, width: 76, height: 20),
                fill: NSColor.black.withAlphaComponent(0.7),
                textColor: .white,
                font: NSFont.systemFont(ofSize: 10, weight: .bold),
                context: context
            )
        }
    }

    /// One of a video's two controls: a dark disc and its glyph.
    private static func drawPlayControl(_ symbol: String, in frame: CGRect, context: CGContext) {
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.fillEllipse(in: frame)
        let side = frame.width * 0.42
        drawSymbol(
            symbol,
            tint: .white,
            in: CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side),
            context: context
        )
    }

    // MARK: Components

    /// One button.
    ///
    /// **A live control and a dead one are drawn differently on purpose.** Only
    /// a link button does anything in this client; the rest need an interaction
    /// round trip it does not make. A dimmed button says so before it is
    /// pressed, which is the difference between a client that cannot do
    /// something and a client that appears to be broken.
    static func drawComponent(
        _ slot: ComponentSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        isHovered: Bool,
        images: ImageStore,
        scale: CGFloat
    ) {
        let corner: CGFloat = 8
        context.addPath(CGPath(
            roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil
        ))
        context.setFillColor(fill(for: slot, isHovered: isHovered).cgColor)
        context.fillPath()

        // White on a coloured button; the room's own ink on a secondary one,
        // whose fill is only a shade of the ground — white on a light theme's
        // shade is no label at all.
        let ink = !slot.isEnabled ? style.tertiaryColor
            : slot.style == .secondary ? style.primaryColor : NSColor.white
        var x = frame.minX + TimelineMetrics.componentPadding

        if let emoji = slot.emoji {
            let glyph = CGRect(
                x: x,
                y: frame.midY - TimelineMetrics.componentGlyphSide / 2,
                width: TimelineMetrics.componentGlyphSide,
                height: TimelineMetrics.componentGlyphSide
            )
            drawComponentGlyph(
                emoji, in: glyph, context: context, style: style, images: images, scale: scale
            )
            x = glyph.maxX + TimelineMetrics.componentGlyphGap
        }

        let font = NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .semibold)
        let hasTrailingGlyph = slot.isMenu || slot.url != nil
        let trailing = TimelineMetrics.componentPadding
            + (hasTrailingGlyph ? TimelineMetrics.componentTrailingGlyphRoom : 0)
        drawText(
            slot.label,
            font: font,
            color: ink,
            at: CGPoint(x: x, y: capCenteredY(of: font, in: frame)),
            maxWidth: max(0, frame.maxX - trailing - x),
            context: context
        )

        // Centred in the band the layout reserved, so the mark and the label
        // can never meet however long the words are.
        if hasTrailingGlyph {
            let side: CGFloat = slot.isMenu ? 10 : 12
            let band = frame.maxX - TimelineMetrics.componentPadding
                - TimelineMetrics.componentTrailingGlyphRoom
            drawSymbol(
                slot.isMenu ? "chevron.down" : "arrow.up.forward.square",
                tint: slot.isMenu ? style.tertiaryColor : ink.withAlphaComponent(0.75),
                in: CGRect(
                    x: band + (TimelineMetrics.componentTrailingGlyphRoom - side) / 2,
                    y: frame.midY - side / 2,
                    width: side,
                    height: side
                ),
                context: context
            )
        }
    }

    /// One emoji in a box — a button's, a poll answer's, anything chrome-sized.
    ///
    /// **One copy, because getting it wrong is silent and the two surfaces that
    /// need it look nothing alike.** A colour emoji's advance is far wider than
    /// its point size, so a glyph sized to the box's *height* overflows the box —
    /// and `drawText` answers an overflow by truncating, which draws a thumbs-up
    /// as "…". That was fixed on a button and not on a poll, and the second copy
    /// is what put "…" in front of every poll answer. `INVARIANTS.md` §5.55; the
    /// sizing itself is `EmojiGlyphMetrics`, which SwiftUI's `ExpressionGlyph`
    /// shares, and a custom emoji is drawn whole inside the box, never stretched.
    static func drawEmojiInBox(
        _ emoji: EmojiRef,
        in frame: CGRect,
        context: CGContext,
        color: NSColor,
        images: ImageStore,
        scale: CGFloat
    ) {
        guard let id = emoji.id else {
            // A Unicode emoji, whose name IS the glyph: its ink fills the box
            // and is centred in it, and its advance — wider than the ink, and
            // empty past it — runs over the box's edges untruncated.
            let metrics = EmojiGlyphMetrics.fitting(emoji.name, side: min(frame.width, frame.height))
            drawText(
                emoji.name,
                font: NSFont.systemFont(ofSize: metrics.pointSize),
                color: color,
                at: CGPoint(
                    x: frame.midX - metrics.ink.midX,
                    y: frame.midY + metrics.ink.midY - metrics.ascent
                ),
                maxWidth: metrics.advance.rounded(.up) + 1,
                context: context
            )
            return
        }
        guard let url = CDN.emoji(id: id, animated: emoji.isAnimated, side: frame.width),
              let image = images.cached(ImageStore.Key(
                  url: url,
                  maximumPixelSize: Int((frame.width * scale).rounded(.up))
              ))
        else { return }
        drawFlipped(image, in: frame, context: context, fit: .contain)
    }

    private static func drawComponentGlyph(
        _ emoji: EmojiRef,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        drawEmojiInBox(
            emoji,
            in: frame,
            context: context,
            color: style.primaryColor,
            images: images,
            scale: scale
        )
    }

    /// The button's ground.
    ///
    /// Discord's five styles collapse to three answers here, because two of them
    /// mean the same thing to a reader: primary and link are both "the thing to
    /// press", success and danger carry their own meaning, and secondary is
    /// everything else. A disabled control is the same ground at a third of the
    /// weight rather than a fourth colour — it is the *same button*, not another
    /// kind of one.
    private static func fill(for slot: ComponentSlot, isHovered: Bool) -> NSColor {
        let base: NSColor = switch slot.style {
        case .primary, .link: NSColor(Palette.accent)
        case .success: NSColor(Palette.affirmative)
        case .danger: NSColor(Palette.destructive)
        case .secondary: NSColor(cgColor: ThemeInk.current.lift(0.12)) ?? .clear
        }
        guard slot.isEnabled else { return base.withAlphaComponent(0.22) }
        return isHovered ? base.blended(withFraction: 0.18, of: .white) ?? base : base
    }
}

// MARK: - Polls

/// The poll card.
///
/// **The fill runs across the answer row itself rather than under it.** The row
/// *is* the quantity, so a separate track beneath a label would be two objects
/// describing one number — and at 38 points tall there is no room for both.
///
/// Its own extension rather than a case in the row painter, because a poll is a
/// self-contained surface with its own vocabulary: a question, rows that are
/// also bars, and a footer that changes what it says three times over a poll's
/// life.
nonisolated extension TimelineRowPainter {

    /// The ground every card that belongs to an app or a track is painted on:
    /// two colours on Discord's 45° line, the cover bled in from the trailing
    /// edge, and a hairline that catches the light.
    ///
    /// **A flood, since the 2026-11-12 redesign.** This used to be the neutral
    /// card fill with a coloured rule down its leading edge — one vocabulary
    /// with an embed, and legible on any theme. The colours make it legible
    /// now: both are taken down until white reads on them
    /// (`InviteCardColours.darkened`), so the card can be the app's own colour
    /// in a light room as in a dark one.
    private static func drawInviteGround(
        in frame: CGRect,
        primary: CGColor,
        secondary: CGColor,
        cover: CGImage?,
        context: CGContext
    ) {
        let corner = ActivityInviteLayoutEngine.corner
        let path = CGPath(roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        // CSS's `45deg` runs from the bottom-leading corner to the top-trailing
        // one, and this canvas is flipped: bottom is `maxY`.
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(
               colorsSpace: space, colors: [primary, secondary] as CFArray, locations: [0, 1]
           ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: frame.minX, y: frame.maxY),
                end: CGPoint(x: frame.maxX, y: frame.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            context.setFillColor(primary)
            context.fill(frame)
        }
        if let cover, let fade = Self.coverFade {
            // The trailing three fifths, filled by the cover and faded in from
            // nothing at its leading edge: the words are on the colour, and the
            // picture arrives where they have stopped.
            let box = CGRect(
                x: frame.minX + frame.width * 0.4, y: frame.minY,
                width: frame.width * 0.6, height: frame.height
            )
            context.saveGState()
            context.clip(to: box, mask: fade)
            context.setAlpha(0.55)
            let scale = max(box.width / CGFloat(cover.width), box.height / CGFloat(cover.height))
            let size = CGSize(width: CGFloat(cover.width) * scale, height: CGFloat(cover.height) * scale)
            TimelineRowPainter.drawFlipped(
                cover,
                in: CGRect(
                    x: box.maxX - size.width, y: box.midY - size.height / 2,
                    width: size.width, height: size.height
                ),
                context: context
            )
            context.restoreGState()
        }
        context.restoreGState()

        let inner = CGPath(
            roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: corner - 0.5, cornerHeight: corner - 0.5, transform: nil
        )
        context.addPath(inner)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
        context.setLineWidth(1)
        context.strokePath()
    }

    /// The cover's fade, as a mask: nothing at the leading edge, everything by
    /// the middle. Luminance is coverage, so this is a grey ramp one pixel tall.
    private static let coverFade: CGImage? = {
        let width = 256
        guard let context = CGContext(
            data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray,
            locations: [0, 0.62]
        ) else { return nil }
        context.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: width, y: 0), options: [.drawsAfterEndLocation]
        )
        return context.makeImage()
    }()

    /// The card's one control: a white capsule with a dark word, as Discord's
    /// overlay button is — or, where there is nothing to press, a quiet one
    /// with a light word.
    private static func drawInviteButton(
        in rect: CGRect,
        isProminent: Bool,
        isHovered: Bool,
        context: CGContext
    ) {
        let radius = ActivityInviteLayoutEngine.buttonCorner
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(
            gray: 1,
            alpha: isProminent ? (isHovered ? 1 : 0.92) : (isHovered ? 0.26 : 0.18)
        ))
        context.fillPath()
        if !isProminent {
            context.addPath(CGPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil
            ))
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.2))
            context.setLineWidth(1)
            context.strokePath()
        }
    }

    /// An activity invitation — Discord's card (`572211.h`): the app's own two
    /// colours, its icon, its name, what is happening in it and one button.
    static func drawActivityInvite(
        _ slot: ActivityInviteSlot,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        accent: CGColor?,
        accentEnd: CGColor? = nil,
        cover: CGImage? = nil,
        status: String?,
        isJoined: Bool,
        hovered: CGPoint?,
        images: ImageStore,
        scale: CGFloat
    ) {
        let frame = slot.rect.offsetBy(dx: offset.x, dy: offset.y)
        let neutral = InviteCardColours.cgColor(InviteCardColours.neutral)
        drawInviteGround(
            in: frame,
            primary: accent ?? neutral,
            secondary: accentEnd ?? accent ?? InviteCardColours.cgColor(0x1E_1F_22),
            cover: cover,
            context: context
        )

        drawLine(
            "Invite to Play",
            font: ActivityInviteLayoutEngine.eyebrowFont(style),
            color: ActivityInviteLayoutEngine.quietInk,
            at: CGPoint(x: offset.x + slot.eyebrowOrigin.x, y: offset.y + slot.eyebrowOrigin.y),
            maxWidth: frame.maxX - offset.x - slot.eyebrowOrigin.x - ActivityInviteLayoutEngine.padding,
            style: style,
            context: context,
            images: images,
            scale: scale
        )

        // The icon, with the monogram behind it until it lands.
        let iconRect = slot.iconRect.offsetBy(dx: offset.x, dy: offset.y)
        let iconPath = CGPath(
            roundedRect: iconRect,
            cornerWidth: ActivityInviteLayoutEngine.iconCorner,
            cornerHeight: ActivityInviteLayoutEngine.iconCorner,
            transform: nil
        )
        context.saveGState()
        context.addPath(iconPath)
        context.clip()
        context.setFillColor(CGColor(gray: 1, alpha: 0.14))
        context.fill(iconRect)
        if let url = slot.iconURL,
           let image = images.cached(
               ImageStore.Key(
                   url: url,
                   maximumPixelSize: Int(ActivityInviteLayoutEngine.iconSide * scale)
               ),
               bucket: .thumbnail
           ) {
            // **Through the one flip.** Core Graphics origins an image at the
            // bottom-left and this canvas is flipped, so a bare `draw(_:in:)`
            // comes out upside down — invisible on a symmetric mark and
            // unmissable on a strawberry. `INVARIANTS.md` §4.5.
            TimelineRowPainter.drawFlipped(image, in: iconRect, context: context)
        } else {
            drawTextFrame(
                slot.monogram,
                at: CGPoint(
                    x: offset.x + slot.monogramOrigin.x,
                    y: offset.y + slot.monogramOrigin.y
                ),
                context: context,
                images: images,
                scale: scale
            )
        }
        context.restoreGState()
        context.addPath(iconPath)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        context.setLineWidth(1)
        context.strokePath()

        drawTextFrame(
            slot.title,
            at: CGPoint(x: offset.x + slot.titleOrigin.x, y: offset.y + slot.titleOrigin.y),
            context: context,
            images: images,
            scale: scale
        )
        // The live line, painted rather than laid out — see `statusOrigin`.
        if let status, !status.isEmpty {
            drawLine(
                status,
                font: style.metadataFont,
                color: ActivityInviteLayoutEngine.quietInk,
                at: CGPoint(x: offset.x + slot.statusOrigin.x, y: offset.y + slot.statusOrigin.y),
                maxWidth: slot.statusWidth,
                style: style,
                context: context,
                images: images,
                scale: scale
            )
        }

        let buttonRect = slot.buttonRect.offsetBy(dx: offset.x, dy: offset.y)
        drawInviteButton(
            in: buttonRect,
            isProminent: !isJoined,
            isHovered: hovered == slot.buttonRect.origin,
            context: context
        )
        if isJoined {
            // "Joined" rather than "Play": a button offering what somebody
            // already has is a control that cannot do anything. Painted for the
            // same reason the status line is — it turns on presence.
            drawLine(
                "Joined",
                font: NSFont.systemFont(
                    ofSize: style.bodyFont.pointSize, weight: .semibold
                ),
                color: ActivityInviteLayoutEngine.ink,
                at: CGPoint(
                    x: offset.x + slot.buttonRect.minX,
                    y: offset.y + slot.buttonLabelOrigin.y
                ),
                maxWidth: slot.buttonRect.width,
                centred: true,
                style: style,
                context: context,
                images: images,
                scale: scale
            )
        } else {
            drawTextFrame(
                slot.buttonLabel,
                at: CGPoint(
                    x: offset.x + slot.buttonLabelOrigin.x,
                    y: offset.y + slot.buttonLabelOrigin.y
                ),
                context: context,
                images: images,
                scale: scale
            )
        }
    }

    /// A listen-along invitation, painted from the track it is about: the
    /// album's own two colours, its cover large, the track's progress, who is
    /// listening, and Join.
    ///
    /// **Everything that moves is painted from `card`**, the host's presence:
    /// the cover and the colours taken from it, "{track} by {artist}", the
    /// clock and the progress line — read off `now`, which is why the canvas
    /// repaints a live card every second — the faces and "N Listening", and
    /// Join or Joined. An ended party draws Spotify's mark and Discord's "The
    /// listening party is over!", on the neutral ground, and no button.
    static func drawListenAlong(
        _ slot: ListenAlongSlot,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        card: ListenAlongCard?,
        now: Date,
        hovered: CGPoint?,
        images: ImageStore,
        scale: CGFloat
    ) {
        let frame = slot.rect.offsetBy(dx: offset.x, dy: offset.y)
        let ink = ActivityInviteLayoutEngine.ink
        let quiet = ActivityInviteLayoutEngine.quietInk
        let green: UInt32 = 0x1E_D7_60

        let artwork: CGImage? = slot.isLive
            ? card?.artworkURL.flatMap { url in
                images.cached(
                    ImageStore.Key(url: url, maximumPixelSize: Int(ListenAlongLayoutEngine.artSide * scale)),
                    bucket: .thumbnail
                )
            }
            : nil
        // The album's colours once its cover is in hand; Spotify's green over
        // near-black until then; the neutral pair once the party is over.
        let tint: ActivityCardTint
        if let artwork, let url = card?.artworkURL {
            tint = ArtworkCardColours.tint(for: url, image: artwork)
        } else if slot.isLive {
            tint = ActivityCardTint(primary: InviteCardColours.darkened(green), secondary: 0x12_12_12)
        } else {
            tint = ActivityCardTint(primary: InviteCardColours.neutral, secondary: 0x1E_1F_22)
        }
        drawInviteGround(
            in: frame,
            primary: InviteCardColours.cgColor(tint.primary),
            secondary: InviteCardColours.cgColor(tint.secondary),
            cover: nil,
            context: context
        )

        // Spotify's mark, then the eyebrow.
        let markSide = ListenAlongLayoutEngine.markSide
        let headerX = offset.x + slot.headerOrigin.x
        let headerY = offset.y + slot.headerOrigin.y
        var eyebrowX = headerX
        if let mark = BrandMark.path(for: "spotify") {
            var transform = CGAffineTransform(translationX: headerX, y: headerY)
                .scaledBy(x: markSide / BrandMark.side, y: markSide / BrandMark.side)
            if let placed = mark.copy(using: &transform) {
                context.addPath(placed)
                context.setFillColor(InviteCardColours.cgColor(green))
                context.fillPath(using: .evenOdd)
            }
            eyebrowX += markSide + Spacing.tight
        }
        let eyebrow = ActivityInviteLayoutEngine.eyebrowFont(style)
        drawLine(
            "Listen Along on \(slot.source.name)",
            font: eyebrow,
            color: quiet,
            at: CGPoint(
                x: eyebrowX,
                y: headerY + (markSide - ListenAlongLayoutEngine.lineHeight(eyebrow)) / 2
            ),
            maxWidth: frame.maxX - eyebrowX - ListenAlongLayoutEngine.padding,
            style: style,
            context: context,
            images: images,
            scale: scale
        )

        // The cover, or Spotify's own mark once the party is over.
        let art = slot.artRect.offsetBy(dx: offset.x, dy: offset.y)
        let artPath = CGPath(
            roundedRect: art,
            cornerWidth: ListenAlongLayoutEngine.artCorner,
            cornerHeight: ListenAlongLayoutEngine.artCorner,
            transform: nil
        )
        // The cover's own shadow: it is the one object on the card, and a
        // picture flat on a gradient of its own colours has no edge.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(artPath)
        context.setFillColor(CGColor(gray: 0, alpha: 0.35))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(artPath)
        context.clip()
        if slot.isLive {
            context.setFillColor(CGColor(gray: 1, alpha: 0.12))
            context.fill(art)
            if let artwork { TimelineRowPainter.drawFlipped(artwork, in: art, context: context) }
        } else {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(art)
            if let mark = BrandMark.path(for: "spotify") {
                let side = art.width * 0.56
                var transform = CGAffineTransform(translationX: art.midX - side / 2, y: art.midY - side / 2)
                    .scaledBy(x: side / BrandMark.side, y: side / BrandMark.side)
                if let placed = mark.copy(using: &transform) {
                    context.addPath(placed)
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.fillPath(using: .evenOdd)
                }
            }
        }
        context.restoreGState()
        context.addPath(artPath)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        context.setLineWidth(1)
        context.strokePath()

        let titleFont = NSFont.systemFont(ofSize: style.bodyFont.pointSize + 1, weight: .semibold)
        let textWidth = slot.textWidth
        let x = offset.x + slot.textX
        func top(_ line: Int) -> CGFloat { offset.y + slot.lineTops[line] }
        guard slot.isLive else {
            drawLine(slot.source.name, font: titleFont, color: ink,
                     at: CGPoint(x: x, y: top(0)), maxWidth: textWidth,
                     style: style, context: context, images: images, scale: scale)
            drawLine("The listening party is over!", font: style.metadataFont, color: quiet,
                     at: CGPoint(x: x, y: top(1)), maxWidth: textWidth,
                     style: style, context: context, images: images, scale: scale)
            return
        }

        drawLine(card?.title ?? slot.source.name, font: titleFont, color: ink,
                 at: CGPoint(x: x, y: top(0)), maxWidth: textWidth,
                 style: style, context: context, images: images, scale: scale)

        // The clock: elapsed, and the track's length where the host's
        // presence says when it ends.
        var fraction: Double?
        if let start = card?.startedAt {
            var clock = ListenAlongLayoutEngine.clock(since: start, now: now)
            if let end = card?.endsAt, end > start {
                let length = end.timeIntervalSince(start)
                let elapsed = min(max(0, now.timeIntervalSince(start)), length)
                fraction = elapsed / length
                clock = ListenAlongLayoutEngine.clock(seconds: Int(elapsed))
                    + "  /  " + ListenAlongLayoutEngine.clock(seconds: Int(length))
            }
            drawLine(
                clock,
                font: NSFont.monospacedDigitSystemFont(ofSize: style.metadataFont.pointSize, weight: .medium),
                color: quiet,
                at: CGPoint(x: x, y: top(1)),
                maxWidth: textWidth,
                style: style, context: context, images: images, scale: scale
            )
        }

        if let card {
            let face = ListenAlongLayoutEngine.faceSide
            var faceX = x
            for url in card.faces {
                let circle = CGRect(x: faceX, y: top(2), width: face, height: face)
                context.saveGState()
                context.addEllipse(in: circle)
                context.clip()
                context.setFillColor(CGColor(gray: 1, alpha: 0.2))
                context.fill(circle)
                if let url, let image = images.cached(
                    ImageStore.Key(url: url, maximumPixelSize: Int(face * scale)), bucket: .thumbnail
                ) {
                    TimelineRowPainter.drawFlipped(image, in: circle, context: context)
                }
                context.restoreGState()
                // Overlapped a little, each ringed in the card's own colour so
                // the stack reads as faces rather than as one shape.
                context.addEllipse(in: circle.insetBy(dx: -0.75, dy: -0.75))
                context.setStrokeColor(InviteCardColours.cgColor(tint.primary))
                context.setLineWidth(1.5)
                context.strokePath()
                faceX += face - 4
            }
            if !card.faces.isEmpty { faceX += 4 }
            drawLine(
                "\(card.listenerCount) Listening",
                font: style.metadataFont,
                color: quiet,
                at: CGPoint(
                    x: faceX + Spacing.tight,
                    y: top(2) + (face - ListenAlongLayoutEngine.lineHeight(style.metadataFont)) / 2
                ),
                maxWidth: max(0, x + textWidth - faceX - Spacing.tight),
                style: style, context: context, images: images, scale: scale
            )
        }

        if let progress = slot.progressRect?.offsetBy(dx: offset.x, dy: offset.y) {
            let radius = progress.height / 2
            context.addPath(CGPath(roundedRect: progress, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(CGColor(gray: 1, alpha: 0.2))
            context.fillPath()
            if let fraction {
                let filled = CGRect(
                    x: progress.minX, y: progress.minY,
                    width: max(progress.height, progress.width * fraction), height: progress.height
                )
                context.addPath(CGPath(roundedRect: filled, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(CGColor(gray: 1, alpha: 0.92))
                context.fillPath()
            }
        }

        guard let button = slot.buttonRect else { return }
        let buttonRect = button.offsetBy(dx: offset.x, dy: offset.y)
        let isEnabled = card?.isButtonEnabled ?? false
        drawInviteButton(
            in: buttonRect,
            isProminent: isEnabled,
            isHovered: isEnabled && hovered == button.origin,
            context: context
        )
        let label = NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold)
        drawLine(
            card?.buttonTitle ?? "Join",
            font: label,
            color: isEnabled ? ActivityInviteLayoutEngine.buttonInk : ink,
            at: CGPoint(x: buttonRect.minX, y: buttonRect.midY - ListenAlongLayoutEngine.lineHeight(label) / 2),
            maxWidth: buttonRect.width,
            centred: true,
            style: style, context: context, images: images, scale: scale
        )
    }

    /// One line of plain text, laid out at paint time.
    ///
    /// **For text whose CONTENT changes without the geometry changing.** A
    /// block built during layout is frozen there, which is right for a message
    /// body and wrong for a line that turns on presence — the invitation card's
    /// status and its Joined/Play word both do.
    ///
    /// **It builds a real `TimelineTextBlock` rather than driving CoreText by
    /// hand.** The first attempt did the latter and drew nothing at all: a
    /// `CTFrame` whose path is exactly one line tall drops the line, because
    /// the leading does not fit. Reusing the path every other run of text in
    /// this file goes through is both correct and one line of code.
    ///
    /// The cost is one measurement per draw, and only on rows that carry an
    /// invitation — which are rare, and none of them is in a scroll loop.
    private static func drawLine(
        _ text: String,
        font: NSFont,
        color: NSColor,
        at origin: CGPoint,
        maxWidth: CGFloat,
        centred: Bool = false,
        style: MessageTextStyle,
        context: CGContext,
        images: ImageStore,
        scale: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centred ? .center : .natural
        paragraph.lineBreakMode = .byTruncatingTail
        let block = TimelineTextBlock(
            text: .plain(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ])),
            width: maxWidth,
            style: style
        )
        drawTextFrame(block, at: origin, context: context, images: images, scale: scale)
    }

    static func drawPoll(
        _ slot: PollSlot,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        hovered: CGPoint?,
        images: ImageStore,
        scale: CGFloat
    ) {
        let frame = slot.rect.offsetBy(dx: offset.x, dy: offset.y)
        context.addPath(CGPath(
            roundedRect: frame,
            cornerWidth: EmbedLayoutEngine.corner,
            cornerHeight: EmbedLayoutEngine.corner,
            transform: nil
        ))
        context.setFillColor(ThemeInk.current.cardFill)
        context.fillPath()

        drawTextFrame(
            slot.question,
            at: CGPoint(
                x: offset.x + slot.questionOrigin.x,
                y: offset.y + slot.questionOrigin.y
            ),
            context: context,
            images: images,
            scale: scale
        )

        for answer in slot.answers {
            drawPollAnswer(
                answer,
                offset: offset,
                context: context,
                style: style,
                isHovered: slot.isVotable && hovered == answer.rect.origin,
                isVotable: slot.isVotable,
                images: images,
                scale: scale
            )
        }

        if let footer = slot.footer {
            drawTextFrame(
                footer,
                at: CGPoint(x: offset.x + slot.footerOrigin.x, y: offset.y + slot.footerOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
        }
    }

    private static func drawPollAnswer(
        _ slot: PollAnswerSlot,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        isHovered: Bool,
        isVotable: Bool,
        images: ImageStore,
        scale: CGFloat
    ) {
        let frame = slot.rect.offsetBy(dx: offset.x, dy: offset.y)
        let shape = CGPath(
            roundedRect: frame,
            cornerWidth: PollLayoutEngine.answerCorner,
            cornerHeight: PollLayoutEngine.answerCorner,
            transform: nil
        )

        // The unfilled ground, and the reader's own pick lit inside it.
        context.addPath(shape)
        context.setFillColor(
            ThemeInk.current.lift(isHovered ? 0.12 : 0.06)
        )
        context.fillPath()

        // The share, clipped to the row's own shape so the fill keeps the
        // corner radius at both ends instead of poking out of it.
        if slot.share > 0 {
            context.saveGState()
            context.addPath(shape)
            context.clip()
            // **The winner is the only tinted bar.** A poll where every row is
            // coloured has no result in it; one where exactly one is says the
            // answer before a number is read. The reader's own pick is marked by
            // its weight and its check instead, so the two never compete.
            let tint = slot.isWinner
                ? NSColor(Palette.affirmative).withAlphaComponent(0.30)
                : NSColor(cgColor: ThemeInk.current.lift(0.10)) ?? .clear
            context.setFillColor(tint.cgColor)
            context.fill(CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width * CGFloat(min(1, max(0, slot.share))),
                height: frame.height
            ))
            context.restoreGState()
        }

        if slot.isMine || slot.isWinner {
            context.addPath(shape)
            context.setStrokeColor(
                (slot.isWinner
                    ? NSColor(Palette.affirmative)
                    : NSColor(Palette.accent)).withAlphaComponent(0.7).cgColor
            )
            context.setLineWidth(1)
            context.strokePath()
        }

        if let emoji = slot.emoji {
            drawPollGlyph(
                emoji,
                in: slot.emojiRect.offsetBy(dx: offset.x, dy: offset.y),
                context: context,
                style: style,
                images: images,
                scale: scale
            )
        }

        drawTextFrame(
            slot.label,
            at: CGPoint(x: offset.x + slot.labelOrigin.x, y: offset.y + slot.labelOrigin.y),
            context: context,
            images: images,
            scale: scale
        )

        if let tally = slot.tally {
            drawTextFrame(
                tally,
                at: CGPoint(x: offset.x + slot.tallyOrigin.x, y: offset.y + slot.tallyOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
        }
    }

    private static func drawPollGlyph(
        _ emoji: EmojiRef,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        drawEmojiInBox(
            emoji,
            in: frame,
            context: context,
            color: style.primaryColor,
            images: images,
            scale: scale
        )
    }
}
