import AppKit
import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import WingcordCore

/// Draws one row into a context.
///
/// **The painter never starts work.** It peeks the image cache synchronously and
/// draws a placeholder on a miss; requesting the missing image is the canvas's
/// job, done once when the viewport moves rather than once per row per frame. A
/// painter that kicks off a `Task` allocates one per row per display pass, which
/// is a hundred allocations a frame during a scroll to fetch pictures that are
/// already being fetched.
///
/// It is `nonisolated` and takes everything it needs as parameters, so it can be
/// exercised by a render test that draws into a bitmap and asserts on pixels —
/// which is the only real check on a drawn view. A `Canvas` that draws nothing
/// still compiles, lays out and renders at the right size.
nonisolated enum TimelineRowPainter {

    struct State: Sendable {
        var isHovered = false
        var showsGutterTimestamp = false
        var isHighlighted = false
        var revealedSpoilers: Set<Int> = []
    }

    static func draw(
        row: TimelineRow,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        state: State,
        images: ImageStore,
        scale: CGFloat
    ) {
        switch row.kind {
        case .daySeparator(let label):
            drawDaySeparator(label: label, in: rowFrame, context: context, style: style)
        case .unreadDivider:
            drawUnreadDivider(in: rowFrame, context: context, style: style)
        case .conversationStart(let name):
            drawConversationStart(name: name, in: rowFrame, context: context, style: style)
        case .skeleton(let index):
            drawSkeleton(index: index, in: rowFrame, context: context)
        case .loadingFirstPage:
            drawLoadingFirstPage(in: rowFrame, context: context, style: style)
        case .historyUnavailable(let reason):
            drawHistoryUnavailable(
                reason: reason, in: rowFrame, context: context, style: style
            )
        case .message(let message):
            drawMessage(
                message,
                in: rowFrame,
                context: context,
                style: style,
                state: state,
                images: images,
                scale: scale
            )
        }
    }

    // MARK: Message

    private static func drawMessage(
        _ row: MessageRow,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        state: State,
        images: ImageStore,
        scale: CGFloat
    ) {
        // A mention of the reader tints the whole row and carries a leading
        // rule. Both, not one: the tint alone is easy to miss on a busy channel
        // and the rule alone reads as a quote.
        if row.mentionsMe {
            context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.08).cgColor)
            context.fill(rowFrame)
            context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.7).cgColor)
            context.fill(CGRect(x: rowFrame.minX, y: rowFrame.minY, width: 2, height: rowFrame.height))
        } else if state.isHovered {
            context.setFillColor(NSColor.white.withAlphaComponent(0.035).cgColor)
            context.fill(rowFrame)
        }

        if state.isHighlighted {
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor)
            context.fill(rowFrame)
        }

        // Avatar, or the monogram plate behind it.
        if let avatarRect = row.avatarRect {
            let frame = avatarRect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawAvatar(
                url: row.avatarURL,
                monogram: row.avatarMonogram,
                in: frame,
                context: context,
                style: style,
                images: images,
                scale: scale
            )
        } else if state.showsGutterTimestamp {
            // A continuation row reveals its time in the empty gutter rather
            // than reserving a column for a stamp almost nobody reads.
            drawText(
                row.gutterTimestampText,
                font: style.metadataFont,
                color: style.tertiaryColor,
                at: CGPoint(
                    x: rowFrame.minX + TimelineMetrics.horizontalMargin,
                    y: rowFrame.minY + 3
                ),
                maxWidth: Metrics.avatarMessage,
                alignment: .right,
                context: context
            )
        }

        if row.isRunHead {
            drawText(
                row.authorName,
                font: style.authorFont,
                color: row.authorColor ?? style.primaryColor,
                at: CGPoint(
                    x: rowFrame.minX + row.authorRect.minX,
                    y: rowFrame.minY + row.authorRect.minY
                ),
                maxWidth: row.authorRect.width + 8,
                context: context
            )

            if row.isBot {
                let badgeRect = CGRect(
                    x: rowFrame.minX + row.authorRect.maxX + 6,
                    y: rowFrame.minY + row.authorRect.minY + 3,
                    width: 30,
                    height: 14
                )
                drawChip(
                    "APP",
                    in: badgeRect,
                    fill: NSColor.controlAccentColor,
                    textColor: .white,
                    font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    context: context
                )
            }

            drawText(
                row.timestampText,
                font: style.metadataFont,
                color: style.tertiaryColor,
                at: CGPoint(
                    x: rowFrame.minX + row.timestampRect.minX,
                    y: rowFrame.minY + row.timestampRect.minY + 3
                ),
                maxWidth: row.timestampRect.width + 8,
                context: context
            )
        }

        // Body text.
        if let block = row.textBlock {
            let origin = CGPoint(
                x: rowFrame.minX + row.textOrigin.x,
                y: rowFrame.minY + row.textOrigin.y
            )
            drawTextBlock(
                block,
                at: origin,
                context: context,
                style: style,
                images: images,
                scale: scale,
                revealedSpoilers: state.revealedSpoilers
            )
        }

        for slot in row.attachments {
            let frame = slot.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawAttachment(slot, in: frame, context: context, style: style, images: images, scale: scale)
        }

        for slot in row.reactions {
            let frame = slot.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawReaction(slot, in: frame, context: context, style: style, images: images, scale: scale)
        }
    }

    // MARK: Text

    /// Draws a laid-out block.
    ///
    /// The context is flipped once around the block rather than per line: CoreText
    /// draws bottom-up and the canvas is top-down, and doing the flip per line
    /// means a CTM save/restore per line of every message on screen.
    private static func drawTextBlock(
        _ block: TimelineTextBlock,
        at origin: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        revealedSpoilers: Set<Int>
    ) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + block.size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(block.frame, context)
        context.restoreGState()

        // Inline emoji, drawn into the boxes the run delegates reserved.
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
                context.draw(image, in: frame)
            } else {
                // A soft plate rather than nothing, so a line does not visibly
                // reflow when the picture lands — the box was already reserved.
                context.setFillColor(style.codeBackground.withAlphaComponent(0.5).cgColor)
                context.fillEllipse(in: frame.insetBy(dx: 2, dy: 2))
            }
        }

        // Spoilers, concealed until revealed. The text underneath was laid out
        // normally and drawn in clear, so revealing one costs a repaint and
        // never a relayout.
        for (index, rect) in block.spoilerRects.enumerated() {
            guard !revealedSpoilers.contains(index) else { continue }
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y)
            context.setFillColor(style.spoilerCover.cgColor)
            let path = CGPath(
                roundedRect: frame, cornerWidth: 3, cornerHeight: 3, transform: nil
            )
            context.addPath(path)
            context.fillPath()
        }
    }

    /// One line of plain text.
    ///
    /// Returns the width it **actually drew**, which is not the width it was
    /// offered and not the width the string would have taken untruncated.
    /// Anything positioned after a label — a tag chip, an APP badge — has to use
    /// this number: measuring the full string and clamping it to the available
    /// width places the chip at the end of the SLOT rather than at the end of
    /// the text, which is a visible gap on every truncated name and on nothing
    /// else.
    ///
    /// **Alignment is applied here, by moving the pen.** It used to be set on a
    /// paragraph style — which `CTLine` ignores, because alignment is resolved
    /// by a *framesetter* laying lines into a column and there is no column
    /// here. Every centred label in the app was therefore drawn hard against the
    /// left edge of the box it was centred in: the text inside a chip, an
    /// avatar's monogram, the play glyph on a video, the "Loading messages…"
    /// line, and the gutter timestamp that asked to be right-aligned. The
    /// paragraph style went with it — allocating one per call, on every label of
    /// every row of every repaint, bought exactly nothing.
    @discardableResult
    static func drawText(
        _ string: String,
        font: NSFont,
        color: NSColor,
        at point: CGPoint,
        maxWidth: CGFloat,
        alignment: NSTextAlignment = .left,
        context: CGContext
    ) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: color]
        ))
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)

        // A truncating line needs a width to truncate against; without one it
        // draws past the rect and over whatever is beside it.
        let drawn = truncate(line, to: maxWidth, font: font, color: color) ?? line
        let width = ceil(CTLineGetTypographicBounds(drawn, nil, nil, nil))
        let slack = max(0, maxWidth - width)
        let x: CGFloat = switch alignment {
        case .center: point.x + (slack / 2).rounded()
        case .right: point.x + slack.rounded()
        default: point.x
        }

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: x, y: point.y + ascent)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(drawn, context)
        context.restoreGState()
        return width
    }

    /// Where a single line's `y` has to be so its capitals sit centred in
    /// `rect`.
    ///
    /// Cap height rather than the full line box: a line box is ascent plus
    /// descent, and centring *that* leaves an all-caps label — which every chip
    /// in this app carries — visibly high, because it has no descenders to fill
    /// the space reserved under it.
    static func capCenteredY(of font: NSFont, in rect: CGRect) -> CGFloat {
        rect.midY + font.capHeight / 2 - font.ascender
    }

    private static func truncate(
        _ line: CTLine,
        to width: CGFloat,
        font: NSFont,
        color: NSColor
    ) -> CTLine? {
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > width else { return nil }
        let ellipsis = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\u{2026}", attributes: [.font: font, .foregroundColor: color])
        )
        return CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis)
    }

    // MARK: Pieces

    private static func drawAvatar(
        url: URL?,
        monogram: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        context.saveGState()
        context.addEllipse(in: frame)
        context.clip()

        if let url,
           let image = images.cached(ImageStore.Key(
               url: url,
               maximumPixelSize: Int((frame.width * scale).rounded(.up))
           ))
        {
            // Core Graphics draws images bottom-up; flipping around the frame is
            // cheaper than asking the image source for a flipped rendition.
            context.translateBy(x: 0, y: frame.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -frame.midY)
            context.draw(image, in: frame)
        } else {
            context.setFillColor(NSColor(Palette.surfaceRaised).cgColor)
            context.fill(frame)
            context.restoreGState()
            let font = NSFont.systemFont(ofSize: frame.width * 0.4, weight: .semibold)
            drawText(
                monogram,
                font: font,
                color: style.secondaryColor,
                at: CGPoint(x: frame.minX, y: capCenteredY(of: font, in: frame)),
                maxWidth: frame.width,
                alignment: .center,
                context: context
            )
            return
        }
        context.restoreGState()
    }

    private static func drawAttachment(
        _ slot: AttachmentSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        let path = CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()

        if !slot.isSpoiler,
           let url = slot.url,
           let image = images.cached(
               ImageStore.Key(
                   url: url,
                   maximumPixelSize: Int((slot.decodeWidth * scale).rounded(.up))
               ),
               bucket: .attachment
           )
        {
            context.translateBy(x: 0, y: frame.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -frame.midY)
            context.draw(image, in: frame)
        } else {
            context.setFillColor(NSColor(Palette.surfaceRaised).cgColor)
            context.fill(frame)
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

        if slot.isVideo {
            let badge = CGRect(x: frame.midX - 20, y: frame.midY - 20, width: 40, height: 40)
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            context.fillEllipse(in: badge)
            // A fixed dark disc, never glass: glass over moving artwork churns
            // its sampled blur every frame and leaves the glyph illegible on a
            // bright frame.
            drawText(
                "\u{25B6}",
                font: NSFont.systemFont(ofSize: 15),
                color: .white,
                at: CGPoint(x: badge.minX, y: badge.midY - 9),
                maxWidth: badge.width,
                alignment: .center,
                context: context
            )
        }
    }

    private static func drawReaction(
        _ slot: ReactionSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        let path = CGPath(
            roundedRect: frame,
            cornerWidth: frame.height / 2,
            cornerHeight: frame.height / 2,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(
            slot.isMine
                ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
                : NSColor.white.withAlphaComponent(0.07).cgColor
        )
        context.fillPath()

        let side = TimelineMetrics.reactionGlyphSide
        let glyphRect = CGRect(
            x: frame.minX + TimelineMetrics.reactionLeadingInset,
            y: frame.midY - side / 2,
            width: side,
            height: side
        )
        if let url = slot.imageURL {
            // A CUSTOM emoji. Its picture is the only correct answer — its
            // `name` is a word like "blobcat", not a glyph — so a miss draws the
            // same soft plate the inline path draws rather than the word.
            if let image = images.cached(ImageStore.Key(
                url: url,
                maximumPixelSize: Int((side * scale).rounded(.up))
            )) {
                context.saveGState()
                context.translateBy(x: 0, y: glyphRect.midY)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -glyphRect.midY)
                context.draw(image, in: glyphRect)
                context.restoreGState()
            } else {
                context.setFillColor(style.codeBackground.withAlphaComponent(0.5).cgColor)
                context.fillEllipse(in: glyphRect.insetBy(dx: 2, dy: 2))
            }
        } else {
            // A Unicode emoji, whose `name` IS the glyph.
            //
            // The box has to be at least as wide as the glyph advances or tail
            // truncation eats it: an emoji at size 13 advances 19pt, and the
            // 16pt box this used to get turned every reaction into a lone
            // ellipsis. `reactionGlyphSide` is that measurement.
            drawText(
                slot.emoji.name,
                font: NSFont.systemFont(ofSize: TimelineMetrics.reactionEmojiFontSize),
                color: style.primaryColor,
                at: CGPoint(x: glyphRect.minX, y: glyphRect.midY - side / 2 + 2),
                maxWidth: glyphRect.width,
                context: context
            )
        }

        drawText(
            String(slot.count),
            font: style.metadataFont,
            color: slot.isMine ? NSColor.controlAccentColor : style.secondaryColor,
            at: CGPoint(x: glyphRect.maxX + TimelineMetrics.reactionGlyphGap, y: frame.midY - 7),
            maxWidth: max(
                0,
                frame.maxX - glyphRect.maxX
                    - TimelineMetrics.reactionGlyphGap
                    - TimelineMetrics.reactionTrailingInset
            ),
            context: context
        )
    }

    /// A small filled label — the APP mark, SPOILER, the unread band's NEW.
    ///
    /// `radius` defaults to a capsule, which is the shape every floating chip in
    /// this app is: a hand-picked small radius on a 15pt-tall label is a
    /// *different* shape from the capsules beside it rather than a smaller
    /// version of one.
    private static func drawChip(
        _ label: String,
        in frame: CGRect,
        fill: NSColor,
        textColor: NSColor,
        font: NSFont,
        radius: CGFloat? = nil,
        context: CGContext
    ) {
        let corner = radius ?? frame.height / 2
        context.addPath(CGPath(
            roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil
        ))
        context.setFillColor(fill.cgColor)
        context.fillPath()
        drawText(
            label,
            font: font,
            color: textColor,
            at: CGPoint(x: frame.minX, y: capCenteredY(of: font, in: frame)),
            maxWidth: frame.width,
            alignment: .center,
            context: context
        )
    }

    // MARK: Separators

    private static func drawDaySeparator(
        label: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        let width = TimelineLayoutEngine.measure(label, font: style.metadataFont)
        let midY = frame.midY
        let inset = TimelineMetrics.horizontalMargin
        let gap: CGFloat = 10

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: frame.minX + inset, y: midY))
        context.addLine(to: CGPoint(x: frame.midX - width / 2 - gap, y: midY))
        context.move(to: CGPoint(x: frame.midX + width / 2 + gap, y: midY))
        context.addLine(to: CGPoint(x: frame.maxX - inset, y: midY))
        context.strokePath()

        drawText(
            label,
            font: style.metadataFont,
            color: style.tertiaryColor,
            at: CGPoint(x: frame.midX - width / 2, y: midY - 7),
            maxWidth: width + 4,
            alignment: .center,
            context: context
        )
    }

    /// The line between what has been read and what has not.
    ///
    /// Built as the day separator's sibling — one rule, broken around one label
    /// — so the two read as the same object in two colours rather than as two
    /// unrelated decorations. What is different is deliberate: the label sits at
    /// the **trailing** end rather than centred, because this is a boundary
    /// rather than a heading and a centred red pill competes with the first
    /// unread message directly under it; and it is filled rather than quiet,
    /// because it is the one mark in the transcript whose whole job is to be
    /// found by a reader scrolling for it.
    ///
    /// The label is a **capsule**, like every other chip in the app, and its
    /// text is centred in it by cap height. Both were wrong before: the shape
    /// was a 3pt-radius rectangle, and the text sat hard against its leading
    /// edge with the whole of the padding pooled on the right.
    private static func drawUnreadDivider(
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        let midY = frame.midY.rounded() + 0.5   // a hairline, on the pixel grid
        let inset = TimelineMetrics.horizontalMargin
        let font = TimelineMetrics.unreadLabelFont
        let label = "NEW"
        let width = TimelineLayoutEngine.measure(label, font: font)
            + TimelineMetrics.unreadLabelPadding * 2
        let chip = CGRect(
            x: frame.maxX - inset - width,
            y: (midY - TimelineMetrics.unreadLabelHeight / 2).rounded(),
            width: width,
            height: TimelineMetrics.unreadLabelHeight
        )

        let tint = NSColor(Palette.unreadBadge)
        context.setStrokeColor(tint.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: frame.minX + inset, y: midY))
        context.addLine(to: CGPoint(x: chip.minX - TimelineMetrics.unreadLabelGap, y: midY))
        context.strokePath()

        drawChip(
            label,
            in: chip,
            fill: tint,
            textColor: .white,
            font: font,
            context: context
        )
    }

    private static func drawConversationStart(
        name: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        let inset = TimelineMetrics.horizontalMargin
        drawText(
            "Welcome to #\(name)",
            font: NSFont.systemFont(ofSize: style.bodyFont.pointSize * 1.4, weight: .bold),
            color: style.primaryColor,
            at: CGPoint(x: frame.minX + inset, y: frame.minY + 30),
            maxWidth: frame.width - inset * 2,
            context: context
        )
        drawText(
            "This is the beginning of the channel.",
            font: style.bodyFont,
            color: style.secondaryColor,
            at: CGPoint(x: frame.minX + inset, y: frame.minY + 62),
            maxWidth: frame.width - inset * 2,
            context: context
        )
    }

    /// The first page is still in flight.
    ///
    /// One quiet line rather than a runway. The runway is a gesture affordance —
    /// somewhere for a flick that is already travelling to go — and on a channel
    /// with nothing in it yet there is no such gesture, so twenty placeholder
    /// groups are just a wall of grey bars that reads as content that failed.
    private static func drawLoadingFirstPage(
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        drawText(
            "Loading messages…",
            font: style.metadataFont,
            color: style.tertiaryColor,
            at: CGPoint(x: frame.minX, y: frame.minY + 10),
            maxWidth: frame.width,
            alignment: .center,
            context: context
        )
    }

    /// The first page was asked for and did not arrive.
    ///
    /// It says so, and it says WHY. The alternative — leaving "Loading
    /// messages..." on screen — is the same picture whether the page is one
    /// second away or will never come, and the reader has no way to tell a slow
    /// client from a broken one.
    private static func drawHistoryUnavailable(
        reason: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        let inset = TimelineMetrics.horizontalMargin
        let width = frame.width - inset * 2
        drawText(
            "Messages did not load",
            font: NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold),
            color: style.secondaryColor,
            at: CGPoint(x: frame.minX + inset, y: frame.minY + 34),
            maxWidth: width,
            alignment: .center,
            context: context
        )
        drawText(
            reason,
            font: style.metadataFont,
            color: style.tertiaryColor,
            at: CGPoint(x: frame.minX + inset, y: frame.minY + 58),
            maxWidth: width,
            alignment: .center,
            context: context
        )
    }

    /// A placeholder group in the history runway.
    ///
    /// A circle and three bars: no text layout, no images, no model reads. That
    /// cheapness is the point — the runway is twenty of these deep so a flick has
    /// somewhere to travel while the page is in flight, and a deep runway made of
    /// expensive rows would trade one stall for another.
    private static func drawSkeleton(index: Int, in frame: CGRect, context: CGContext) {
        let inset = TimelineMetrics.horizontalMargin
        let tint = NSColor.white.withAlphaComponent(0.05).cgColor
        context.setFillColor(tint)
        context.fillEllipse(in: CGRect(
            x: frame.minX + inset,
            y: frame.minY + 10,
            width: Metrics.avatarMessage,
            height: Metrics.avatarMessage
        ))

        let contentX = frame.minX + TimelineMetrics.contentInset
        // Deterministic widths from the row index rather than a random number:
        // a runway that reshuffles on every repaint reads as flickering.
        let widths: [CGFloat] = [0.42, 0.78, 0.61, 0.35]
        for line in 0..<3 {
            let fraction = widths[(index &+ line) % widths.count]
            let width = (frame.width - TimelineMetrics.contentInset - inset) * fraction
            let bar = CGRect(
                x: contentX,
                y: frame.minY + 10 + CGFloat(line) * 14,
                width: max(40, width),
                height: 9
            )
            context.addPath(CGPath(
                roundedRect: bar, cornerWidth: 4, cornerHeight: 4, transform: nil
            ))
            context.setFillColor(tint)
            context.fillPath()
        }
    }
}
