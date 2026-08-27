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
        scale: CGFloat
    ) {
        let frame = slot.rect.offsetBy(dx: offset.x, dy: offset.y)
        let corner = EmbedLayoutEngine.corner

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
            context.setFillColor(NSColor(Palette.surfaceRaised).withAlphaComponent(0.85).cgColor)
            context.fill(frame)
            if let accent = slot.accent {
                context.setFillColor(accent.cgColor)
                context.fill(CGRect(
                    x: frame.minX,
                    y: frame.minY,
                    width: EmbedLayoutEngine.ruleWidth,
                    height: frame.height
                ))
            }
            context.restoreGState()
        }

        for rule in slot.rules {
            context.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
            context.fill(rule.offsetBy(dx: offset.x, dy: offset.y))
        }

        for text in slot.texts {
            drawTextFrame(
                text.block,
                at: CGPoint(x: offset.x + text.origin.x, y: offset.y + text.origin.y),
                context: context,
                images: images,
                scale: scale
            )
        }

        for image in slot.images {
            drawEmbedImage(
                image,
                in: image.rect.offsetBy(dx: offset.x, dy: offset.y),
                context: context,
                style: style,
                images: images,
                scale: scale
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
                drawFlipped(image, in: frame, context: context)
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
        scale: CGFloat
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

        if let url = slot.url,
           let image = images.cached(
               ImageStore.Key(
                   url: url,
                   maximumPixelSize: Int((slot.decodeWidth * scale).rounded(.up))
               ),
               bucket: slot.isArtwork ? .artwork : .thumbnail
           )
        {
            drawFlipped(image, in: frame, context: context)
        } else {
            // A quiet plate at the picture's own size, so nothing reflows when
            // it lands — the box was already reserved.
            context.setFillColor(style.codeBackground.withAlphaComponent(0.6).cgColor)
            context.fill(frame)
        }
        context.restoreGState()
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

        let ink = slot.isEnabled ? NSColor.white : style.tertiaryColor
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
        let trailing = slot.isMenu ? 14 + TimelineMetrics.componentPadding
            : TimelineMetrics.componentPadding
        drawText(
            slot.label,
            font: font,
            color: ink,
            at: CGPoint(x: x, y: capCenteredY(of: font, in: frame)),
            maxWidth: max(0, frame.maxX - trailing - x),
            context: context
        )

        if slot.isMenu {
            drawSymbol(
                "chevron.down",
                tint: style.tertiaryColor,
                in: CGRect(x: frame.maxX - 22, y: frame.midY - 5, width: 10, height: 10),
                context: context
            )
        } else if slot.url != nil {
            // A link button says where it goes. The mark is the only difference
            // between "this opens a page" and "this does something here", and
            // Discord draws it for the same reason.
            drawSymbol(
                "arrow.up.forward.square",
                tint: ink.withAlphaComponent(0.75),
                in: CGRect(x: frame.maxX - 24, y: frame.midY - 6, width: 12, height: 12),
                context: context
            )
        }
    }

    private static func drawComponentGlyph(
        _ emoji: EmojiRef,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        guard let id = emoji.id else {
            // A Unicode emoji, whose name IS the glyph.
            drawText(
                emoji.name,
                font: NSFont.systemFont(ofSize: frame.height * 0.86),
                color: style.primaryColor,
                at: CGPoint(x: frame.minX, y: frame.minY),
                maxWidth: frame.width,
                alignment: .center,
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
        drawFlipped(image, in: frame, context: context)
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
        case .secondary: NSColor.white.withAlphaComponent(0.12)
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
        context.setFillColor(NSColor(Palette.surfaceRaised).withAlphaComponent(0.85).cgColor)
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
            NSColor.white.withAlphaComponent(isHovered ? 0.12 : 0.06).cgColor
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
                : NSColor.white.withAlphaComponent(0.10)
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
        guard let id = emoji.id else {
            // A Unicode emoji, whose name IS the glyph.
            drawText(
                emoji.name,
                font: NSFont.systemFont(ofSize: frame.height * 0.9),
                color: style.primaryColor,
                at: CGPoint(x: frame.minX, y: frame.minY),
                maxWidth: frame.width,
                alignment: .center,
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
        drawFlipped(image, in: frame, context: context)
    }
}
