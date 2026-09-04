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
        /// Which of the row's attachments have had their spoiler lifted.
        ///
        /// **Its own set, keyed by the attachment's position.** A spoiler in the
        /// body text and a spoilered picture are both identified by an index
        /// into their own list, and sharing one set would have revealing the
        /// first hidden word uncover the second photograph.
        var revealedAttachments: Set<Int> = []
        /// The origin of the button or poll answer under the pointer, in row
        /// space.
        ///
        /// **Identified by its origin rather than by an index**, because the
        /// pointer state is held per message and an index is only meaningful
        /// next to the array it came from — which the canvas does not keep
        /// between passes. One field for both, because at most one thing in a
        /// row is under the pointer.
        var hoveredComponent: CGPoint?
        /// Which attachment the pointer is over, if any.
        ///
        /// **Its own field rather than another meaning for `hoveredComponent`.**
        /// That one is an origin because a button and a poll answer are
        /// identified by where they sit; an attachment already has an index, and
        /// overloading the point would make the star and a button under the same
        /// pointer indistinguishable.
        var hoveredAttachment: Int?
        /// Whether the account has already starred the hovered GIF, so the badge
        /// says which way the click goes.
        var isHoveredAttachmentFavorite = false
        /// The shared animation clock's current time.
        ///
        /// Passed in rather than read here: the painter is `nonisolated` so a
        /// render test can drive it, and reaching for a main-actor singleton
        /// from inside a draw loop is exactly what that buys.
        var animationTime: Double = 0
        /// An activity invitation's colour, quantised from the app's icon.
        ///
        /// **On the paint state rather than in the slot**, because it resolves
        /// asynchronously and the layout is cached: a colour taken at measure
        /// time arrives after the row is already laid out and never reaches the
        /// card. Here it costs a redraw, which is all a colour change is.
        var activityAccent: CGColor?
        /// "00:08 · Adding videos · 1 playing", when the instance is live.
        ///
        /// **On the paint state, like the accent and for the same reason.** It
        /// comes from presence and changes far more often than the transcript
        /// is measured; laid out, it froze at whatever it said when the reader
        /// last switched channels.
        var activityInviteStatus: String?
        var activityInviteIsJoined = false
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
        case .conversationStart(let slot):
            drawConversationStart(
                slot,
                in: rowFrame,
                context: context,
                style: style,
                images: images,
                scale: scale
            )
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

        // The quoted line, and the elbow tying it to the face below. Drawn
        // first so the connector passes *under* the avatar rather than across
        // it — one save/restore, and only on a reply.
        if let header = row.interactionHeader {
            drawInteractionHeader(
                header,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                images: images,
                scale: scale
            )
        }

        if let header = row.replyHeader {
            drawReplyHeader(
                header,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                images: images,
                scale: scale
            )
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
        } else if let symbol = row.systemSymbol {
            // A system event's mark, where a face would be. Tinted rather than
            // achromatic: a join, a boost and a removal are three different
            // things and the glyph is the only place the difference can live —
            // the sentence beside it is one quiet line either way.
            drawSymbol(
                symbol,
                tint: row.systemTint ?? style.tertiaryColor,
                in: CGRect(
                    x: rowFrame.minX + TimelineMetrics.horizontalMargin
                        + (Metrics.avatarMessage - TimelineMetrics.systemGlyphSide),
                    y: rowFrame.minY + row.textOrigin.y,
                    width: TimelineMetrics.systemGlyphSide,
                    height: TimelineMetrics.systemGlyphSide
                ),
                context: context
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
            // The face carries into the transcript; the colour does not — a
            // role colour a server chose beats a colour its owner did. Drawn in
            // the same face the layout measured, or the badge beside it lands
            // in the wrong place.
            drawText(
                row.authorName,
                font: row.authorFace ?? style.authorFont,
                color: row.authorColor ?? style.primaryColor,
                at: CGPoint(
                    x: rowFrame.minX + row.authorRect.minX,
                    y: rowFrame.minY + row.authorRect.minY
                ),
                maxWidth: row.authorRect.width + 8,
                tracking: row.authorTracking,
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
        if let forwarded = row.forwarded {
            drawForward(
                forwarded,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                images: images,
                scale: scale,
                clock: state.animationTime
            )
        }

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

        for slot in row.stickers {
            let frame = slot.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawSticker(
                slot,
                in: frame,
                context: context,
                style: style,
                images: images,
                scale: scale,
                time: state.animationTime
            )
        }

        for (index, slot) in row.attachments.enumerated() {
            let frame = slot.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawAttachment(
                slot,
                in: frame,
                context: context,
                style: style,
                images: images,
                scale: scale,
                isRevealed: state.revealedAttachments.contains(index),
                clock: state.animationTime,
                // The star is a hover control: it exists on the picture the
                // pointer is on and nowhere else, exactly as the action pill
                // exists on the row the pointer is on.
                favorite: state.hoveredAttachment == index
                    ? (state.isHoveredAttachmentFavorite ? .starred : .unstarred)
                    : nil
            )
        }

        if let invite = row.activityInvite {
            drawActivityInvite(
                invite,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                accent: state.activityAccent,
                status: state.activityInviteStatus,
                isJoined: state.activityInviteIsJoined,
                hovered: state.hoveredComponent,
                images: images,
                scale: scale
            )
        }

        if let poll = row.poll {
            drawPoll(
                poll,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                hovered: state.hoveredComponent,
                images: images,
                scale: scale
            )
        }

        for slot in row.embeds {
            drawEmbed(
                slot,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                images: images,
                scale: scale,
                clock: state.animationTime
            )
        }

        for slot in row.components {
            let frame = slot.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawComponent(
                slot,
                in: frame,
                context: context,
                style: style,
                isHovered: state.hoveredComponent == slot.rect.origin,
                images: images,
                scale: scale
            )
        }

        for slot in row.reactions {
            let frame = slot.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawReaction(
                slot,
                in: frame,
                context: context,
                style: style,
                isHovered: state.hoveredComponent == slot.rect.origin,
                images: images,
                scale: scale
            )
        }

        // The thread this message started. Above the ephemeral note for the
        // same reason it is laid out there: the chip is about the message, the
        // note is about the row.
        if let chip = row.threadChip {
            drawThreadChip(
                chip,
                in: chip.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY),
                context: context,
                style: style,
                isHovered: state.hoveredComponent == chip.rect.origin
            )
        }

        // "Only you can see this". Last, under everything — a note about the
        // whole message, in the quietest ink the row has.
        if let note = row.ephemeralNote {
            let frame = note.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawSymbol(
                "eye.slash",
                tint: style.tertiaryColor,
                in: CGRect(
                    x: frame.minX,
                    y: frame.minY + (frame.height - TimelineMetrics.ephemeralNoteGlyphSide) / 2,
                    width: TimelineMetrics.ephemeralNoteGlyphSide,
                    height: TimelineMetrics.ephemeralNoteGlyphSide
                ),
                context: context
            )
            drawText(
                note.text,
                font: style.metadataFont,
                color: style.tertiaryColor,
                at: CGPoint(
                    x: frame.minX + TimelineMetrics.ephemeralNoteGlyphRoom,
                    y: frame.minY + 1
                ),
                maxWidth: frame.width,
                context: context
            )

            // The separator dot, centred in the gap the layout left for it.
            let dismiss = note.dismissRect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawText(
                "·",
                font: style.metadataFont,
                color: style.tertiaryColor,
                at: CGPoint(
                    x: dismiss.minX - TimelineMetrics.ephemeralNoteSeparatorRoom / 2,
                    y: frame.minY + 1
                ),
                maxWidth: TimelineMetrics.ephemeralNoteSeparatorRoom,
                context: context
            )
            // The control. In the link colour, because it is the one thing on
            // this line that does something — and the same colour every other
            // clickable run in the transcript takes.
            drawText(
                note.dismissText,
                font: style.metadataFont,
                color: style.linkColor,
                at: CGPoint(x: dismiss.minX, y: dismiss.minY + 1),
                maxWidth: dismiss.width,
                context: context
            )
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
                // **Flipped, like every other picture this file draws.** Core
                // Graphics origins an image bottom-left and the canvas is
                // top-left, so an unflipped `draw` puts every custom emoji in
                // the transcript upside down — which is invisible on a symmetric
                // one and unmissable on a face.
                drawFlipped(image, in: frame, context: context)
            } else {
                // A soft plate rather than nothing, so a line does not visibly
                // reflow when the picture lands — the box was already reserved.
                context.setFillColor(style.codeBackground.withAlphaComponent(0.5).cgColor)
                context.fillEllipse(in: frame.insetBy(dx: 2, dy: 2))
            }
        }

        // Inline symbols, in the mention's own colour so the glyph and the
        // name it leads read as one chip.
        for entry in block.symbolRects {
            drawSymbol(
                entry.name,
                tint: style.mentionColor,
                in: entry.rect.offsetBy(dx: origin.x, dy: origin.y),
                context: context
            )
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
    /// - Parameter tracking: extra letter spacing, in points. **Zero costs
    ///   nothing** — the attribute is left off entirely rather than set to 0,
    ///   because an attributed string with one more key is one more entry for
    ///   Core Text to walk on every name in a five-hundred-row roster. Only the
    ///   display-name faces that Discord tracks ever pass one.
    static func drawText(
        _ string: String,
        font: NSFont,
        color: NSColor,
        at point: CGPoint,
        maxWidth: CGFloat,
        alignment: NSTextAlignment = .left,
        tracking: CGFloat = 0,
        context: CGContext
    ) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if tracking != 0 { attributes[.kern] = tracking }
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: string,
            attributes: attributes
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

    /// The quoted line above a reply: an elbow out of the avatar gutter, the
    /// quoted author's face and name, and one line of what they said.
    ///
    /// **The elbow is stroked in one path, not two lines and an arc.** A corner
    /// assembled from three primitives joins at the miter and leaves a notch on
    /// the inside of the turn at any stroke wider than a point, which at 1.5 is
    /// visible as a nick in the only curve on the row.
    /// "alex used **launch**".
    ///
    /// Shares the reply header's elbow deliberately: both are a line above a
    /// message saying what it answers, and one connector for one idea is what
    /// keeps them reading as a single vocabulary.
    private static func drawInteractionHeader(
        _ header: InteractionHeaderSlot,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        let midY = offset.y + header.rect.midY
        let x = offset.x + TimelineMetrics.replyElbowX

        context.saveGState()
        context.setStrokeColor(style.quoteRuleColor.cgColor)
        context.setLineWidth(TimelineMetrics.replyElbowWidth)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: CGPoint(x: x, y: offset.y + header.elbowBottom))
        context.addArc(
            tangent1End: CGPoint(x: x, y: midY),
            tangent2End: CGPoint(x: offset.x + TimelineMetrics.replyElbowEndX, y: midY),
            radius: TimelineMetrics.replyElbowRadius
        )
        context.addLine(to: CGPoint(x: offset.x + TimelineMetrics.replyElbowEndX, y: midY))
        context.strokePath()
        context.restoreGState()

        drawAvatar(
            url: header.avatarURL,
            monogram: header.monogram,
            in: header.avatarRect.offsetBy(dx: offset.x, dy: offset.y),
            context: context,
            style: style,
            images: images,
            scale: scale,
            peekSide: Metrics.avatarMessage
        )

        let font = style.metadataFont
        _ = drawText(
            header.lead,
            font: header.leadFace ?? font,
            color: header.leadColor ?? style.secondaryColor,
            at: CGPoint(x: offset.x + header.leadRect.minX, y: offset.y + header.leadRect.minY),
            maxWidth: header.leadRect.width,
            tracking: header.leadTracking,
            context: context
        )

        // The chip. Filled rather than outlined: the command's name is a token
        // the app owns, and a border would make it read as a control.
        let chip = header.chipRect.offsetBy(dx: offset.x, dy: offset.y)
        context.addPath(CGPath(
            roundedRect: chip,
            cornerWidth: chip.height / 2,
            cornerHeight: chip.height / 2,
            transform: nil
        ))
        context.setFillColor(ThemeInk.current.accent.copy(alpha: 0.28) ?? ThemeInk.current.accent)
        context.fillPath()

        _ = drawText(
            header.command,
            font: font,
            color: style.primaryColor,
            at: CGPoint(
                x: offset.x + header.commandRect.minX,
                y: offset.y + header.commandRect.minY
            ),
            maxWidth: header.commandRect.width,
            context: context
        )
    }

    private static func drawReplyHeader(
        _ header: ReplyHeaderSlot,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        let midY = offset.y + header.rect.midY
        let radius = TimelineMetrics.replyElbowRadius
        let x = offset.x + TimelineMetrics.replyElbowX

        context.saveGState()
        context.setStrokeColor(style.quoteRuleColor.cgColor)
        context.setLineWidth(TimelineMetrics.replyElbowWidth)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: CGPoint(x: x, y: offset.y + header.elbowBottom))
        context.addArc(
            tangent1End: CGPoint(x: x, y: midY),
            tangent2End: CGPoint(x: offset.x + TimelineMetrics.replyElbowEndX, y: midY),
            radius: radius
        )
        context.addLine(to: CGPoint(x: offset.x + TimelineMetrics.replyElbowEndX, y: midY))
        context.strokePath()
        context.restoreGState()

        if header.avatarRect != .zero {
            drawAvatar(
                url: header.avatarURL,
                monogram: header.monogram,
                in: header.avatarRect.offsetBy(dx: offset.x, dy: offset.y),
                context: context,
                style: style,
                images: images,
                scale: scale,
                // The transcript already asked for this face at the message
                // avatar's size, and that is the slot the picture is in.
                peekSide: Metrics.avatarMessage
            )
        }

        let font = style.metadataFont
        if !header.name.isEmpty {
            drawText(
                header.name,
                font: header.nameFace ?? font,
                color: header.nameColor ?? style.secondaryColor,
                at: CGPoint(
                    x: offset.x + header.nameRect.minX,
                    y: capCenteredY(of: header.nameFace ?? font, in: header.nameRect)
                        + offset.y
                ),
                maxWidth: header.nameRect.width + 4,
                tracking: header.nameTracking,
                context: context
            )
        }
        if !header.excerpt.isEmpty {
            drawText(
                header.excerpt,
                font: font,
                color: style.tertiaryColor,
                at: CGPoint(
                    x: offset.x + header.excerptRect.minX,
                    y: capCenteredY(of: font, in: header.excerptRect) + offset.y
                ),
                maxWidth: header.excerptRect.width,
                context: context
            )
        }
    }

    /// - Parameter peekSide: the point size the picture was *requested* at, when
    ///   that differs from the box it is drawn in. The cache is keyed on pixel
    ///   size, so a reply header drawing a 16-point face has to look in the slot
    ///   the 38-point prefetch filled — peeking with its own box's size looks in
    ///   a slot nothing was ever put in, and the face is a permanent monogram.
    private static func drawAvatar(
        url: URL?,
        monogram: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        peekSide: CGFloat? = nil
    ) {
        context.saveGState()
        context.addEllipse(in: frame)
        context.clip()

        if let url,
           let image = images.cached(ImageStore.Key(
               url: url,
               maximumPixelSize: Int(((peekSide ?? frame.width) * scale).rounded(.up))
           ))
        {
            drawFlipped(image, in: frame, context: context)
        } else {
            context.setFillColor(ThemeInk.current.surfaceRaised)
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
        scale: CGFloat,
        isRevealed: Bool,
        clock: Double,
        favorite: FavoriteBadge?
    ) {
        // A spoiler stays covered until it is clicked, and the click that
        // uncovers it is not the click that opens it — a picture somebody hid
        // deliberately must not be shown full-screen by the same press that
        // reveals it.
        let isHidden = slot.isSpoiler && !isRevealed
        switch slot.kind {
        case .image, .video:
            drawAttachmentArtwork(
                slot,
                in: frame,
                context: context,
                images: images,
                scale: scale,
                isHidden: isHidden,
                clock: clock
            )
        case .voice:
            drawVoiceNote(slot, in: frame, context: context, style: style)
        case .file:
            drawFileCard(slot, in: frame, context: context, style: style)
        }

        if isHidden {
            drawChip(
                "SPOILER",
                in: CGRect(x: frame.midX - 38, y: frame.midY - 10, width: 76, height: 20),
                fill: NSColor.black.withAlphaComponent(0.7),
                textColor: .white,
                font: NSFont.systemFont(ofSize: 10, weight: .bold),
                context: context
            )
        }

        if let favorite, slot.favorite != nil, !isHidden {
            drawFavoriteBadge(
                favorite,
                in: slot.favoriteRect.offsetBy(
                    dx: frame.minX - slot.rect.minX,
                    dy: frame.minY - slot.rect.minY
                ),
                context: context
            )
        }
    }

    /// Which way the star's click goes.
    enum FavoriteBadge: Sendable {
        case starred
        case unstarred
    }

    /// The control that keeps a GIF.
    ///
    /// **A fixed dark plate, never glass.** It sits on moving artwork, and glass
    /// over a moving picture churns its sampled blur every frame and leaves the
    /// glyph illegible on a bright one — the same rule the play badge follows.
    /// Boxy rather than round, because it is a control rather than a mark.
    private static func drawFavoriteBadge(
        _ state: FavoriteBadge,
        in frame: CGRect,
        context: CGContext
    ) {
        context.addPath(CGPath(
            roundedRect: frame,
            cornerWidth: Radius.row,
            cornerHeight: Radius.row,
            transform: nil
        ))
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.fillPath()

        let side = frame.width * 0.52
        drawSymbol(
            state == .starred ? "star.fill" : "star",
            tint: state == .starred ? NSColor.systemYellow : .white,
            in: CGRect(
                x: frame.midX - side / 2,
                y: frame.midY - side / 2,
                width: side,
                height: side
            ),
            context: context
        )
    }

    /// A picture or a clip's poster, and the clip's badge over it.
    private static func drawAttachmentArtwork(
        _ slot: AttachmentSlot,
        in frame: CGRect,
        context: CGContext,
        images: ImageStore,
        scale: CGFloat,
        isHidden: Bool,
        clock: Double
    ) {
        let path = CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()

        let pixels = Int((slot.decodeWidth * scale).rounded(.up))
        var drewArtwork = false
        if !isHidden, let url = slot.url {
            if slot.isAnimated,
               let film = AnimatedImageStore.shared.cached(
                   AnimatedImageStore.Key(url: url, maximumPixelSize: pixels)
               )
            {
                // The SAME clock every other moving thing reads, so a channel of
                // GIFs stays in step instead of each drifting on its own
                // accumulated error. See `AnimationClock`.
                drawFlipped(film.frames[film.index(at: clock)], in: frame, context: context)
                drewArtwork = true
            } else if let image = images.cached(
                ImageStore.Key(url: url, maximumPixelSize: pixels), bucket: .attachment
            ) {
                drawFlipped(image, in: frame, context: context)
                drewArtwork = true
            }
        }
        if !drewArtwork {
            context.setFillColor(ThemeInk.current.surfaceRaised)
            context.fill(frame)
        }
        context.restoreGState()

        guard slot.kind == .video, !isHidden else { return }
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
        guard !slot.durationLabel.isEmpty else { return }
        let width = TimelineLayoutEngine.measure(
            slot.durationLabel, font: NSFont.systemFont(ofSize: 10, weight: .semibold)
        )
        drawChip(
            slot.durationLabel,
            in: CGRect(
                x: frame.maxX - width - 20, y: frame.maxY - 26, width: width + 12, height: 18
            ),
            fill: NSColor.black.withAlphaComponent(0.6),
            textColor: .white,
            font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            context: context
        )
    }

    /// A file with nothing to show: a glyph, its name, its size.
    ///
    /// **A card, not an empty rectangle.** Anything that is not a picture used
    /// to be laid out as one and then drew a permanent grey box, which is
    /// indistinguishable from a picture that failed to load.
    private static func drawFileCard(
        _ slot: AttachmentSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        context.addPath(CGPath(
            roundedRect: frame,
            cornerWidth: EmbedLayoutEngine.corner,
            cornerHeight: EmbedLayoutEngine.corner,
            transform: nil
        ))
        context.setFillColor(ThemeInk.current.cardFill)
        context.fillPath()

        let side = TimelineMetrics.attachmentCardGlyphSide
        drawSymbol(
            Self.fileSymbol(for: slot.filename),
            tint: style.linkColor,
            in: CGRect(
                x: frame.minX + TimelineMetrics.attachmentCardInset,
                y: frame.midY - side / 2,
                width: side,
                height: side
            ),
            context: context
        )
        let room = max(0, frame.maxX - TimelineMetrics.attachmentCardInset - slot.titleOrigin.x)
        _ = drawText(
            slot.filename,
            font: style.bodyFont,
            color: style.linkColor,
            at: slot.titleOrigin,
            maxWidth: room,
            context: context
        )
        _ = drawText(
            slot.sizeLabel,
            font: style.metadataFont,
            color: style.tertiaryColor,
            at: slot.subtitleOrigin,
            maxWidth: room,
            context: context
        )
    }

    /// A voice note: a play glyph, a waveform and how long it runs.
    ///
    /// The bars are derived from the file name rather than from Discord's
    /// base64 waveform — decoding that per repaint is work inside a draw, and
    /// the shape carries no information the reader acts on. What matters is that
    /// the row reads as a voice message rather than as a failed picture.
    private static func drawVoiceNote(
        _ slot: AttachmentSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        context.addPath(CGPath(
            roundedRect: frame,
            cornerWidth: frame.height / 2,
            cornerHeight: frame.height / 2,
            transform: nil
        ))
        context.setFillColor(ThemeInk.current.cardFill)
        context.fillPath()

        let inset = TimelineMetrics.attachmentCardInset
        let glyph = CGRect(x: frame.minX + inset, y: frame.midY - 9, width: 18, height: 18)
        drawSymbol("play.fill", tint: style.linkColor, in: glyph, context: context)

        let durationWidth = slot.durationLabel.isEmpty
            ? 0
            : TimelineLayoutEngine.measure(slot.durationLabel, font: style.metadataFont) + 8
        let barsX = glyph.maxX + Spacing.base
        let barsWidth = max(0, frame.maxX - inset - durationWidth - barsX)
        drawWaveform(
            in: CGRect(x: barsX, y: frame.midY - 8, width: barsWidth, height: 16),
            seed: slot.filename,
            color: style.linkColor.withAlphaComponent(0.55),
            context: context
        )
        guard !slot.durationLabel.isEmpty else { return }
        _ = drawText(
            slot.durationLabel,
            font: style.metadataFont,
            color: style.tertiaryColor,
            at: CGPoint(
                x: frame.maxX - inset - durationWidth + 8,
                y: frame.midY - style.metadataFont.pointSize / 2 - 1
            ),
            maxWidth: durationWidth,
            context: context
        )
    }

    /// Bars across a box. Deterministic on the seed, so the same note draws the
    /// same shape on every repaint rather than shimmering.
    private static func drawWaveform(
        in frame: CGRect,
        seed: String,
        color: NSColor,
        context: CGContext
    ) {
        guard frame.width > 8 else { return }
        let barWidth: CGFloat = 2
        let gap: CGFloat = 2
        let count = Int(frame.width / (barWidth + gap))
        guard count > 0 else { return }
        context.setFillColor(color.cgColor)
        var hash = UInt64(truncatingIfNeeded: seed.hashValue) | 1
        for index in 0..<count {
            // A cheap xorshift rather than `Double.random`: this runs inside a
            // display pass and must not touch the system generator.
            hash ^= hash << 13
            hash ^= hash >> 7
            hash ^= hash << 17
            let level = 0.25 + Double(hash % 1000) / 1000 * 0.75
            let height = frame.height * level
            context.fill(CGRect(
                x: frame.minX + CGFloat(index) * (barWidth + gap),
                y: frame.midY - height / 2,
                width: barWidth,
                height: height
            ))
        }
    }

    /// The glyph for a document, from its extension.
    ///
    /// A short table rather than a UTType lookup: `UTType(filenameExtension:)`
    /// consults the type database, and this is asked once per file card per
    /// repaint.
    private static func fileSymbol(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "zip", "rar", "7z", "tar", "gz": "doc.zipper"
        case "pdf": "doc.richtext"
        case "txt", "md", "log", "rtf": "doc.text"
        case "mp3", "wav", "flac", "m4a", "ogg", "aac": "waveform"
        case "swift", "js", "ts", "py", "rs", "c", "h", "cpp", "json", "html", "css": "chevron.left.forwardslash.chevron.right"
        case "dmg", "pkg", "app": "shippingbox"
        default: "doc"
        }
    }

    /// The chip under a message that started a thread.
    ///
    /// **A rounded rectangle, not a capsule.** A capsule at this height reads as
    /// an oversized reaction chip; the chip is a *destination*, and the corner
    /// radius is the one every card in this app uses so it reads as a surface
    /// you can go into.
    private static func drawThreadChip(
        _ slot: ThreadChipSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        isHovered: Bool
    ) {
        let path = CGPath(
            roundedRect: frame,
            cornerWidth: Radius.row,
            cornerHeight: Radius.row,
            transform: nil
        )
        context.addPath(path)
        context.setFillColor(
            NSColor.white.withAlphaComponent(isHovered ? 0.10 : 0.05).cgColor
        )
        context.fillPath()

        var x = frame.minX + TimelineMetrics.threadChipLeadingInset
        // Everything but the chevron and the insets. Clamped at zero so a chip
        // squeezed to nothing does not ask `drawText` to truncate to a negative
        // width, which draws the full string past the rect.
        let room = max(
            0,
            frame.maxX - TimelineMetrics.threadChipTrailingInset
                - TimelineMetrics.threadChipChevronRoom - x
        )

        // The name takes the accent, because it is the link. The count beside it
        // is metadata in the quietest ink, exactly as a timestamp is.
        let nameWidth = min(slot.nameWidth, room)
        _ = drawText(
            slot.name,
            font: style.authorFont,
            color: NSColor.controlAccentColor,
            at: CGPoint(x: x, y: frame.midY - style.authorFont.pointSize * 0.7),
            maxWidth: nameWidth,
            context: context
        )
        x += nameWidth + TimelineMetrics.threadChipLabelGap

        let countRoom = max(0, frame.maxX - TimelineMetrics.threadChipTrailingInset
            - TimelineMetrics.threadChipChevronRoom - x)
        if countRoom > 0 {
            _ = drawText(
                slot.countText,
                font: style.metadataFont,
                color: style.tertiaryColor,
                at: CGPoint(x: x, y: frame.midY - style.metadataFont.pointSize * 0.7),
                maxWidth: countRoom,
                context: context
            )
        }

        // The chevron says this goes somewhere, which is the one thing the fill
        // alone does not.
        let side: CGFloat = 10
        drawSymbol(
            "chevron.right",
            tint: style.tertiaryColor,
            in: CGRect(
                x: frame.maxX - TimelineMetrics.threadChipTrailingInset - side,
                y: frame.midY - side / 2,
                width: side,
                height: side
            ),
            context: context
        )
    }

    private static func drawReaction(
        _ slot: ReactionSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        isHovered: Bool,
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
        // A chip is a control, so it answers the pointer. The reader's own is
        // already accent-tinted; hovering lifts whichever it is by the same
        // step, so the two states stay distinguishable in both directions.
        let base: CGFloat = slot.isMine ? 0.22 : 0.07
        context.setFillColor(
            slot.isMine
                ? NSColor.controlAccentColor.withAlphaComponent(base + (isHovered ? 0.12 : 0)).cgColor
                : NSColor.white.withAlphaComponent(base + (isHovered ? 0.06 : 0)).cgColor
        )
        context.fillPath()

        // The reader's own chip carries an outline as well as a tint: on a busy
        // row the fill alone is one step of lightness against four other chips,
        // and "did my reaction land" is the only question the control answers.
        if slot.isMine {
            context.addPath(path)
            context.setStrokeColor(
                NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
            )
            context.setLineWidth(1)
            context.strokePath()
        }

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
                drawFlipped(image, in: glyphRect, context: context)
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

    /// Draws a bitmap the right way up.
    ///
    /// Core Graphics origins an image at the bottom-left and this canvas is
    /// flipped, so every `draw(_:in:)` in this file goes through here. It used
    /// to be four lines copied at each call site, and the one copy that was
    /// missing is what drew every inline custom emoji upside down.
    static func drawFlipped(_ image: CGImage, in frame: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: frame.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -frame.midY)
        context.draw(image, in: frame)
        context.restoreGState()
    }

    /// One sticker.
    ///
    /// **Aspect-fit inside its box and never cropped.** A sticker is authored
    /// artwork with its own margins; filling a square box with a wide one cuts
    /// the ends off the thing that identifies it.
    ///
    /// The picture comes from one of two caches and the format decides which:
    /// a Lottie sticker has **no bitmap on the CDN at all** — measured, both its
    /// `.png` and `.gif` endpoints answer 404 — so its poster is the first frame
    /// of a rasterised filmstrip, while everything else is an ordinary decode.
    /// Both are peeks; the coordinator is the only thing that starts a fetch.
    private static func drawSticker(
        _ slot: StickerSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        time: Double
    ) {
        let pixels = Int((frame.width * scale).rounded(.up))
        let image = stickerFrame(slot, pixels: pixels, images: images, time: time)

        guard let image else {
            // A quiet plate at the sticker's own size, so the row does not
            // reflow when the artwork lands.
            context.addPath(CGPath(
                roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil
            ))
            context.setFillColor(style.codeBackground.withAlphaComponent(0.5).cgColor)
            context.fillPath()
            return
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return }
        let factor = min(frame.width / width, frame.height / height)
        let fitted = CGRect(
            x: (frame.midX - width * factor / 2).rounded(),
            y: (frame.midY - height * factor / 2).rounded(),
            width: (width * factor).rounded(),
            height: (height * factor).rounded()
        )
        drawFlipped(image, in: fitted, context: context)
    }

    /// One SF Symbol, tinted, fitted into a rect.
    ///
    /// The bitmap comes out of `SymbolCache`: resolving and rasterising a symbol
    /// is a font lookup and a render, and a `#welcome` channel draws one per row
    /// on every repaint of every scroll.
    static func drawSymbol(
        _ name: String,
        tint: NSColor,
        in frame: CGRect,
        context: CGContext
    ) {
        guard let image = SymbolCache.shared.image(
            name: name, pointSize: frame.height, tint: tint
        ) else { return }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return }
        let factor = min(frame.width / width, frame.height / height)
        drawFlipped(
            image,
            in: CGRect(
                x: frame.midX - width * factor / 2,
                y: frame.midY - height * factor / 2,
                width: width * factor,
                height: height * factor
            ),
            context: context
        )
    }

    /// The bitmap a sticker shows right now.
    ///
    /// **A moving sticker is a filmstrip and a still one is a bitmap**, and the
    /// difference is the format rather than the caller: APNG, GIF and Lottie all
    /// decode into the same strip, so one lookup covers all three. A still is
    /// drawn while the strip is still decoding — every animated sticker except
    /// Lottie also has a first frame in the ordinary cache, and showing it beats
    /// showing a plate.
    static func stickerFrame(
        _ slot: StickerSlot,
        pixels: Int,
        images: ImageStore,
        time: Double
    ) -> CGImage? {
        guard let url = slot.url else { return nil }
        if slot.isAnimated {
            let key = AnimatedImageStore.Key(url: url, maximumPixelSize: pixels)
            if let film = AnimatedImageStore.shared.cached(key) {
                return film.frames[film.index(at: time)]
            }
        }
        // Lottie has no bitmap on the CDN at all — measured, both its `.png` and
        // `.gif` endpoints answer 404 — so there is nothing to fall back to.
        guard !slot.isVector else { return nil }
        return images.cached(
            ImageStore.Key(url: url, maximumPixelSize: pixels),
            bucket: .artwork
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

    /// A forwarded message, quoted inside the one that carries it.
    ///
    /// Every rectangle came from the layout, so this has no cases: a rule, a
    /// glyph, and whatever slots the snapshot turned into — drawn by the same
    /// functions the message's own content is drawn by, which is what makes a
    /// forwarded photograph a photograph rather than a line of text about one.
    private static func drawForward(
        _ slot: ForwardedSlot,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        clock: Double
    ) {
        let rule = slot.ruleRect.offsetBy(dx: offset.x, dy: offset.y)
        context.addPath(CGPath(
            roundedRect: rule,
            cornerWidth: rule.width / 2,
            cornerHeight: rule.width / 2,
            transform: nil
        ))
        context.setFillColor(style.tertiaryColor.withAlphaComponent(0.45).cgColor)
        context.fillPath()

        drawSymbol(
            "arrowshape.turn.up.right.fill",
            tint: style.tertiaryColor,
            in: slot.glyphRect.offsetBy(dx: offset.x, dy: offset.y),
            context: context
        )
        drawTextFrame(
            slot.label,
            at: CGPoint(x: offset.x + slot.labelOrigin.x, y: offset.y + slot.labelOrigin.y),
            context: context,
            images: images,
            scale: scale
        )
        if let body = slot.body {
            drawTextFrame(
                body,
                at: CGPoint(x: offset.x + slot.bodyOrigin.x, y: offset.y + slot.bodyOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
        }
        for attachment in slot.attachments {
            drawAttachment(
                attachment,
                in: attachment.rect.offsetBy(dx: offset.x, dy: offset.y),
                context: context,
                style: style,
                images: images,
                scale: scale,
                // A spoiler inside a forward stays covered: the block is a
                // quote of somebody else's message, and there is nothing here to
                // click that would reveal it.
                isRevealed: false,
                clock: clock,
                // And nothing in a quote is a control. A star on somebody else's
                // forwarded GIF would be a control that cannot be pointed at,
                // because the hit test does not descend into the block.
                favorite: nil
            )
        }
        for embed in slot.embeds {
            drawEmbed(
                embed,
                offset: offset,
                context: context,
                style: style,
                images: images,
                scale: scale,
                clock: clock
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

    /// The head of a channel: an icon tile, a welcome, and what the channel is
    /// for.
    ///
    /// Every rectangle here was measured at layout time, so this has no cases
    /// and no arithmetic — the same rule the embed painter follows.
    private static func drawConversationStart(
        _ slot: ConversationStartSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        let offset = CGPoint(x: frame.minX, y: frame.minY)

        // The tile. A rounded square rather than a circle: the channel list's
        // own rows are rounded rectangles, and a disc here reads as an avatar.
        let icon = slot.iconRect.offsetBy(dx: offset.x, dy: offset.y)
        context.addPath(CGPath(
            roundedRect: icon,
            cornerWidth: Radius.card,
            cornerHeight: Radius.card,
            transform: nil
        ))
        context.setFillColor(ThemeInk.current.surfaceRaised)
        context.fillPath()
        drawSymbol(
            slot.symbolName,
            tint: style.secondaryColor,
            in: slot.glyphRect.offsetBy(dx: offset.x, dy: offset.y),
            context: context
        )

        drawTextFrame(
            slot.title,
            at: CGPoint(x: offset.x + slot.titleOrigin.x, y: offset.y + slot.titleOrigin.y),
            context: context,
            images: images,
            scale: scale
        )
        drawTextFrame(
            slot.subtitle,
            at: CGPoint(x: offset.x + slot.subtitleOrigin.x, y: offset.y + slot.subtitleOrigin.y),
            context: context,
            images: images,
            scale: scale
        )
        if let topic = slot.topic {
            drawTextFrame(
                topic,
                at: CGPoint(x: offset.x + slot.topicOrigin.x, y: offset.y + slot.topicOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
        }
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
