import AppKit
import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import Synchronization
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
        /// Whether the row draws its own face. **Not in the transcript's
        /// bubbles**, where each run's face is a layer that rides the scroll
        /// (`StickyFaces`) and the row leaves its place empty; every other
        /// surface that paints a row (pins, search, the inbox) draws it here.
        var drawsFace = true
        /// Whether this message is one the reader has kept.
        ///
        /// **On the paint state, not in the layout.** §4.5: a row's layout is
        /// cached and only re-runs on a presentation or items change, so a flag
        /// taken at measure time would freeze the moment the row was laid out
        /// and a bookmark toggled afterwards would never reach the canvas. The
        /// geometry does not depend on it.
        var isBookmarked = false
        /// Whether a new reaction may be started in this channel — the add
        /// control at the end of the reaction row. A channel's answer, so it is
        /// paint state rather than layout: a permission change is a repaint.
        var canAddReaction = false
        /// Whether the pointer is on this row's reactions, which is what shows
        /// a bookmark control the message does not already wear.
        var isPointerOnReactions = false
        /// Whether the reaction picker this row's add control raised is still
        /// up. The control is the pointer's, and the pointer follows the
        /// picker off the row — a control that left then took the picker's own
        /// origin with it.
        var pinsReactionControls = false
        /// The chips whose count is rolling on a layer over the canvas, by
        /// their place in the row: the canvas leaves their number to it.
        var rollingReactions: Set<Int> = []
        /// The chips that have just arrived or been pressed, and how long ago
        /// in seconds — see `ReactionPop`.
        var reactionPops: [Int: Double] = [:]
        var showsGutterTimestamp = false
        /// The time beside an author's name — off only under Hide Times, and
        /// back on under the pointer.
        var showsHeaderTimestamp = true
        var isHighlighted = false
        var revealedSpoilers: Set<Int> = []
        /// The body's plated run under the pointer — a mention, a role — which
        /// lights the way Discord's `.interactive` does.
        var hoveredPlate: Int?
        /// The body's concealed spoiler under the pointer.
        var hoveredSpoiler: Int?
        /// Which of the row's attachments have had their spoiler lifted.
        ///
        /// **Its own set, keyed by the attachment's position.** A spoiler in the
        /// body text and a spoilered picture are both identified by an index
        /// into their own list, and sharing one set would have revealing the
        /// first hidden word uncover the second photograph.
        var revealedAttachments: Set<Int> = []
        /// The same for a forward's own files — a list of its own, so lifting
        /// the message's first spoiler does not uncover the forward's first.
        var revealedForwardAttachments: Set<Int> = []
        /// The invite cards the reader is already settled into: in the
        /// server, in the group, friends with the person.
        var settledInviteCodes: Set<String> = []
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
        /// Which unfurled embed the pointer is over, if any.
        ///
        /// **A second index rather than a reuse of the attachment's.** A message
        /// can carry both — a pasted `.gif` file *and* a Tenor link — and one
        /// field for both would put the star on whichever the pointer was not
        /// on.
        var hoveredEmbed: Int?
        var isHoveredEmbedFavorite = false
        /// The preview clip playing anywhere in the app, so the one card that
        /// started it draws a stop glyph and every other draws a play.
        var playingPreviewURL: URL?
        /// Where the voice notes stand, on a row that has one: read at paint time, since
        /// it moves every frame while one plays and no layout could hold it.
        var voicePlayback: VoiceNotePlayback?
        /// The shared animation clock's current time.
        ///
        /// Passed in rather than read here: the painter is `nonisolated` so a
        /// render test can drive it, and reaching for a main-actor singleton
        /// from inside a draw loop is exactly what that buys.
        var animationTime: Double = 0
        /// Which of this row's moving pictures play on layers over the canvas
        /// — see `TranscriptFilms` — so the painter leaves their boxes empty.
        ///
        /// **Empty, not the still.** Whatever is drawn under a picture shows
        /// through wherever it is clear: a plate behind a sticker, a ghost of an
        /// emoji's first frame behind the rest of it.
        var layered = Layered()
        /// The link under the pointer, underlined — Discord's `a:hover`.
        var hoveredLink: MessageText.LinkTarget?
        /// The part of the body the reader has selected.
        var selectedRange: NSRange?
        /// The selected parts of the texts the row's embeds and component cards
        /// draw, by their place across the row (`TimelineCanvasView.TextPoint`).
        var selectedEmbedTexts: [Int: NSRange] = [:]
        /// The author's name under the pointer, underlined — Discord's
        /// `.username.clickable:hover`.
        var isAuthorNameHovered = false
        /// Whether a styled name's effect may move.
        ///
        /// **Its own flag rather than a nil `animationTime`**, because zero is a
        /// real moment on that clock and every effect's first keyframe is its
        /// resting picture — so "still" and "one frame in" have to be sayable
        /// apart. False under Reduce Motion, where the design is still drawn and
        /// only the movement stops.
        var playsNameEffect = true
        /// Where the hovered name's role gradient has travelled to, `0..<1`, or
        /// nil for a name standing still.
        ///
        /// **Nil also turns the glow off**, because Discord lights and moves an
        /// enhanced role's name together — see `drawText`'s own note.
        var nameGradientPhase: CGFloat?
        /// An activity invitation's colour, quantised from the app's icon.
        ///
        /// **On the paint state rather than in the slot**, because it resolves
        /// asynchronously and the layout is cached: a colour taken at measure
        /// time arrives after the row is already laid out and never reaches the
        /// card. Here it costs a redraw, which is all a colour change is.
        var activityAccent: CGColor?
        /// The second of the card's two colours, and its app's cover — see
        /// `InviteCardColours` and `ActivityCardCovers`.
        var activityAccentEnd: CGColor?
        var activityCover: CGImage?
        /// "00:08 · Adding videos · 1 playing", when the instance is live.
        ///
        /// **On the paint state, like the accent and for the same reason.** It
        /// comes from presence and changes far more often than the transcript
        /// is measured; laid out, it froze at whatever it said when the reader
        /// last switched channels.
        var activityInviteStatus: String?
        var activityInviteIsJoined = false
        /// A listen-along card's host, painted — see `ListenAlongCard`.
        var listenAlong: ListenAlongCard?
        /// A shared theme card's two states, painted: being previewed, kept.
        var isPreviewingSharedTheme = false
        var isSharedThemeSaved = false
        /// How far an upload's files have got, 0...1 — the session's, and so
        /// painted rather than laid out. See `UploadCardSlot`.
        var uploadProgress: Double = 0
        /// Whether the pointer is on an upload card's cancel.
        var isUploadCancelHovered = false
        /// One frame of this author's moving avatar, or nil for the still —
        /// which is every row but the one under the pointer.
        ///
        /// **Resolved by the canvas, not peeked here.** A painter that reached
        /// the film cache itself would animate every run head in the channel
        /// whose avatar happens to be a GIF, which is the column of moving
        /// faces `HoverAvatarFilm` exists to prevent.
        var avatarFrame: CGImage?
        /// One frame of their moving decoration, same rule.
        var decorationFrame: CGImage?
        /// This row's super reactions whose effect is on screen, and the clock
        /// time each one appeared.
        ///
        /// **The chip hands its emoji to the effect while one plays** — every
        /// effect draws the emoji itself, bursting out of the chip, and two of
        /// them would be a picture and its ghost — and shakes for the effect's
        /// first half second, Discord's `shakeReaction`. On the paint state
        /// because it comes and goes with a layer the canvas owns and changes
        /// nothing about the row's geometry.
        var burstEffects: [ReactionEmojiKey: Double] = [:]
        /// The row's bubble and its words are on a flight over the canvas —
        /// a send on its way from the composer, see `BubbleFlight` — so they
        /// are left out here, exactly as a layered picture's box is.
        var hidesBubble = false
    }

    /// - Parameter styledAuthorName: the hovered run head's name, shaped and
    ///   with its gradients built, or nil — which is every row but one.
    ///
    ///   **Passed in rather than put on `State`, and prepared by the canvas
    ///   rather than here.** `State` is `Sendable` and a prepared name holds
    ///   `CGPath`s and `CGGradient`s; and this painter never starts work, so
    ///   shaping inside a draw would run a framesetting pass, fifteen outline
    ///   builds and a ramp per frame for a name that cannot change while
    ///   somebody is pointing at it.
    static func draw(
        row: TimelineRow,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        state: State,
        images: ImageStore,
        scale: CGFloat,
        styledAuthorName: DisplayNameEffectPainter.Prepared? = nil
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
                isButtonHovered: slot.editButton.map { state.hoveredComponent == $0.rect.origin } ?? false,
                hoveredComponent: state.hoveredComponent,
                images: images,
                scale: scale
            )
        case .skeleton(let index):
            drawSkeleton(index: index, in: rowFrame, context: context)
        case .marker(let kind, let title):
            drawMarker(kind, title: title, in: rowFrame, context: context, style: style)
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
                scale: scale,
                styledAuthorName: styledAuthorName
            )
        case .collapsedGroup(let slot):
            drawCollapsedGroup(slot, in: rowFrame, context: context, style: style, state: state, images: images, scale: scale)
        case .postActions(let slot):
            drawPostActions(slot, in: rowFrame, context: context, style: style, state: state, images: images, scale: scale)
        }
    }

    // MARK: A forum post's bar

    /// Discord's bar under a post's opening message — `PostActionsSlot`: each
    /// button on the quiet plate the drawn secondary buttons wear, lifted a
    /// step under the pointer.
    private static func drawPostActions(
        _ slot: PostActionsSlot,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        state: State,
        images: ImageStore,
        scale: CGFloat
    ) {
        for button in slot.buttons {
            let rect = button.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            let isHovered = state.hoveredComponent == button.rect.origin
            context.addPath(CGPath(
                roundedRect: rect, cornerWidth: Radius.row, cornerHeight: Radius.row, transform: nil
            ))
            context.setFillColor(ThemeInk.current.lift(isHovered ? 0.18 : 0.12))
            context.fillPath()
            drawSymbol(
                button.symbolName,
                tint: button.isLit ? style.linkColor : style.primaryColor,
                in: button.glyphRect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY),
                context: context
            )
            if let label = button.label {
                drawTextFrame(
                    label,
                    at: CGPoint(x: rowFrame.minX + button.labelOrigin.x, y: rowFrame.minY + button.labelOrigin.y),
                    context: context,
                    images: images,
                    scale: scale
                )
            }
        }
    }

    // MARK: Fold

    /// A fold's line — `CollapsedGroupSlot`.
    ///
    /// On the fold's tint while it is open, which Discord's `expanded` lays over
    /// the line and everything it put back, or the pointer's while it is
    /// hovered. Under the pointer the glyph turns critical and the word takes the
    /// link's ink, underlined when the word itself is under it.
    private static func drawCollapsedGroup(
        _ slot: CollapsedGroupSlot,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        state: State,
        images: ImageStore,
        scale: CGFloat
    ) {
        if slot.group.isOpen || state.isHovered {
            context.setFillColor(ThemeInk.current.lift(0.035))
            context.fill(rowFrame)
        }
        drawSymbol(
            slot.symbolName,
            // Discord reddens the block mark and the eye; a suspended fold's
            // glyph keeps its quiet ink, as it offers nothing to press.
            tint: state.isHovered && slot.group.canOpen ? style.criticalColor : style.tertiaryColor,
            in: CGRect(
                x: rowFrame.minX + slot.textOrigin.x
                    - TimelineMetrics.avatarGap - TimelineMetrics.systemGlyphSide,
                y: rowFrame.minY + slot.textOrigin.y,
                width: TimelineMetrics.systemGlyphSide,
                height: TimelineMetrics.systemGlyphSide
            ),
            context: context
        )
        drawTextBlock(
            slot.text,
            at: CGPoint(x: rowFrame.minX + slot.textOrigin.x, y: rowFrame.minY + slot.textOrigin.y),
            context: context,
            style: style,
            images: images,
            scale: scale,
            time: state.animationTime,
            state: TextState()
        )
        guard let action = slot.action else { return }
        let origin = CGPoint(x: rowFrame.minX + action.rect.minX, y: rowFrame.minY + action.rect.minY)
        drawTextBlock(
            state.isHovered ? action.lit : action.quiet,
            at: origin,
            context: context,
            style: style,
            images: images,
            scale: scale,
            time: state.animationTime,
            state: TextState()
        )
        if state.hoveredComponent == action.rect.origin {
            let font = style.bodyFont
            context.setFillColor(style.linkColor.cgColor)
            context.fill(CGRect(
                x: origin.x,
                y: origin.y + action.rect.height + font.descender + 1.5,
                width: action.rect.width,
                height: max(1, font.underlineThickness)
            ))
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
        scale: CGFloat,
        styledAuthorName: DisplayNameEffectPainter.Prepared? = nil
    ) {
        // A mention of the reader tints the whole row and carries a leading
        // rule. Both, not one: the tint alone is easy to miss on a busy channel
        // and the rule alone reads as a quote. **Not in bubbles**, where a row
        // is a band across a conversation that has none — the mention tints
        // its bubble instead, and the pointer lifts the bubble it is on.
        if row.bubbles == nil {
            if row.mentionsMe {
                context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.08).cgColor)
                context.fill(rowFrame)
                context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.7).cgColor)
                context.fill(CGRect(x: rowFrame.minX, y: rowFrame.minY, width: 2, height: rowFrame.height))
            } else if state.isHovered || row.isInOpenFold {
                // An open fold's messages sit on the pointer's tint for as long
                // as it stays open — Discord's `expanded` — so what was folded
                // still reads as apart from the conversation around it.
                context.setFillColor(ThemeInk.current.lift(0.035))
                context.fill(rowFrame)
            }
        }

        if state.isHighlighted {
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor)
            context.fill(rowFrame)
        }

        // Super reaction glows, before anything else in the row. **Discord's
        // glow is `z-index: -1`** — under the message, not over it — and it
        // reaches well past its chip, into the line of text above. Drawn with
        // the chip it would lie across that line as a faint tint.
        for slot in row.reactions where slot.kind == .burst {
            guard let burst = slot.palette?.style(isLight: ThemeInk.current.isLight) else { continue }
            let frame = slot.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            let shake = state.burstEffects[slot.emoji.reactionKey].flatMap {
                SuperReactionShake.offset(at: state.animationTime - $0)
            }
            context.saveGState()
            if let shake { applyShake(shake, around: frame, context: context) }
            SuperReactionGlow.draw(around: frame, accent: burst.accent, context: context, scale: scale)
            context.restoreGState()
        }

        // The quoted line, and the elbow tying it to the face below. Drawn
        // first so the connector passes *under* the avatar rather than across
        // it — one save/restore, and only on a reply.
        if let header = row.interactionHeader {
            drawInteractionHeader(
                header,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                isChipHovered: state.hoveredComponent == header.chipRect.origin,
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
            if state.drawsFace {
                let frame = avatarRect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
                drawAvatar(
                    url: row.avatarURL,
                    monogram: row.avatarMonogram,
                    in: frame,
                    context: context,
                    style: style,
                    images: images,
                    scale: scale,
                    // A bubble's face is smaller than the size the prefetch asked
                    // for, and the cache is keyed on the asking.
                    peekSide: row.bubbles == nil ? nil : Metrics.avatarMessage,
                    decorationURL: row.decorationURL,
                    avatarFrame: state.avatarFrame,
                    decorationFrame: state.decorationFrame
                )
            }
        } else if let symbol = row.systemSymbol {
            // A system event's mark, where a face would be. Tinted rather than
            // achromatic: a join, a boost and a removal are three different
            // things and the glyph is the only place the difference can live —
            // the sentence beside it is one quiet line either way.
            drawSymbol(
                symbol,
                tint: row.systemTint ?? style.tertiaryColor,
                // A gutter's gap before the words, wherever they start — the
                // avatar column's trailing edge in columns, beside a centred
                // line in bubbles.
                in: CGRect(
                    x: rowFrame.minX + row.textOrigin.x
                        - TimelineMetrics.avatarGap - TimelineMetrics.systemGlyphSide,
                    y: rowFrame.minY + row.textOrigin.y,
                    width: TimelineMetrics.systemGlyphSide,
                    height: TimelineMetrics.systemGlyphSide
                ),
                context: context
            )
        } else if state.showsGutterTimestamp, row.bubbles == nil {
            // A continuation row reveals its time in the empty gutter rather
            // than reserving a column for a stamp almost nobody reads.
            //
            // **The whole gutter, not the avatar's width.** Right-aligned to
            // the avatar's edge as before, but free to run back to the row's
            // own margin: "5:07 PM" is wider than a 38-point face, and inside
            // the face's width it came out as "5:07…".
            let gutterInset: CGFloat = 4
            drawText(
                row.gutterTimestampText,
                font: style.metadataFont,
                color: style.tertiaryColor,
                at: CGPoint(
                    x: rowFrame.minX + gutterInset,
                    y: rowFrame.minY + 3
                ),
                maxWidth: TimelineMetrics.horizontalMargin + Metrics.avatarMessage - gutterInset,
                alignment: .right,
                context: context
            )
        }

        if row.hasAuthorLine {
            let namePoint = CGPoint(
                x: rowFrame.minX + row.authorRect.minX,
                y: rowFrame.minY + row.authorRect.minY
            )
            // **The face carries into the transcript always; the effect only
            // under the pointer.** That is Discord's own arrangement and it is
            // what the two captures show: the same pixel face in both, colour
            // in the lit one only. A column of names all running their own
            // effects is a page of moving text where a conversation should be.
            //
            // The role colour keeps the resting state — a colour a server chose
            // beats a colour its owner did — and the effect takes the lit one,
            // because an effect is a paint rather than a colour and there is
            // nothing for the two to share.
            // **A server's role beats the account's own paint, and the two
            // are mutually exclusive.** The roster states the rule — "a
            // server's enhanced role beats the app's ink" — and the transcript
            // has to match it, or one person reads two ways in one window
            // depending on which list you point at. `authorStyle` is already
            // nil in a guild, so this branch is a DM's.
            if let gradient = row.authorGradient, gradient.count >= 2 {
                drawText(
                    row.authorName,
                    font: row.authorFace ?? style.authorFont,
                    color: row.authorColor ?? style.primaryColor,
                    at: namePoint,
                    maxWidth: row.authorRect.width + 8,
                    tracking: row.authorTracking,
                    gradient: gradient,
                    gradientPhase: state.isHovered ? state.nameGradientPhase : nil,
                    context: context
                )
            } else if state.isHovered, let name = styledAuthorName {
                DisplayNameEffectPainter.draw(
                    name,
                    fallback: (row.authorColor ?? style.primaryColor).cgColor,
                    // Nil parks the effect on its own first keyframe, which is
                    // what a still Reduce Motion picture is here.
                    time: state.playsNameEffect ? state.animationTime : nil,
                    at: namePoint,
                    context: context
                )
            } else {
                // Drawn in the same face the layout measured, or the badge
                // beside it lands in the wrong place.
                drawText(
                    row.authorName,
                    font: row.authorFace ?? style.authorFont,
                    color: row.authorColor ?? style.primaryColor,
                    at: namePoint,
                    maxWidth: row.authorRect.width + 8,
                    tracking: row.authorTracking,
                    context: context
                )
            }

            // Discord's `.username.clickable:hover`: the name underlines under
            // the pointer, in its own ink.
            if state.isAuthorNameHovered {
                let font = row.authorFace ?? style.authorFont
                context.setFillColor((row.authorColor ?? style.primaryColor).cgColor)
                context.fill(CGRect(
                    x: namePoint.x, y: namePoint.y + font.ascender + 1.5,
                    width: row.authorRect.width, height: max(1, font.underlineThickness)
                ))
            }

            if let tag = row.authorTag {
                let badgeRect = CGRect(
                    x: rowFrame.minX + row.authorRect.maxX + 6,
                    y: rowFrame.minY + row.authorRect.minY + 3,
                    width: AuthorTagChip.width(tag),
                    height: 14
                )
                drawChip(
                    tag.label,
                    in: badgeRect,
                    fill: NSColor.controlAccentColor,
                    textColor: .white,
                    font: AppBadge.font,
                    context: context
                )
            }

            // The server tag, in the roster's own chip. `MemberRowPainter`
            // owns the shape; this owns nothing but where it lands, which the
            // layout already decided.
            if let tag = row.tag {
                drawTagChip(
                    tag,
                    in: row.tagRect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY),
                    badge: row.tagBadgeURL,
                    style: style,
                    images: images,
                    scale: scale,
                    context: context
                )
            }

            // The role icon, after the tag chip. **An image or an emoji, never
            // both** — Discord's role editor offers one or the other, and the
            // layout reserved the same square for either.
            if row.roleIconRect.width > 0 {
                let box = row.roleIconRect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
                if let url = row.roleIconURL {
                    if let icon = images.cached(
                        ImageStore.Key(
                            url: url,
                            maximumPixelSize: Int((box.width * scale).rounded(.up))
                        ),
                        bucket: .thumbnail
                    ) {
                        // **Fitted, not filled** — Discord's `object-fit:
                        // contain`. A role icon need not be square, and its
                        // logo is wider than tall: stretched to the square it
                        // drew squeezed thin (Alex's screenshots 21, 22).
                        drawFlipped(icon, in: fittedRect(icon, in: box, covering: false), context: context)
                    }
                } else if let emoji = row.roleEmoji {
                    // One copy of the measurement, for the reason §5.55 gives:
                    // a colour emoji is wider than its point size and answering
                    // an overflow by truncating draws it as "…".
                    drawEmojiInBox(
                        EmojiRef(name: emoji),
                        in: box,
                        context: context,
                        color: style.secondaryColor,
                        images: images,
                        scale: scale
                    )
                }
            }

            if state.showsHeaderTimestamp {
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
                clock: state.animationTime,
                revealedAttachments: state.revealedForwardAttachments,
                isFooterHovered: state.hoveredComponent != nil
                    && state.hoveredComponent == forwarded.footerRect.origin
            )
        }

        if let bubbles = row.bubbles {
            drawBubble(bubbles, of: row, in: rowFrame, state: state, style: style, context: context)
        }

        // A DM's system line under the pointer: the sentence with the name in
        // clear ink, and the name's effect drawn into the gap after it.
        let litSystemName = state.isHovered && !row.hasAuthorLine ? row.systemName : nil
        let litSystemPrepared = litSystemName == nil ? nil : styledAuthorName
        if let block = (litSystemPrepared != nil ? litSystemName?.unnamedBlock : nil) ?? row.textBlock,
           !(state.hidesBubble && row.bubbles?.bubble != nil)
        {
            let origin = CGPoint(
                x: rowFrame.minX + row.textOrigin.x,
                y: rowFrame.minY + row.textOrigin.y
            )
            // **The words of a send Discord has not taken, at half strength** —
            // Discord's `.isSending`, which is on the text and on nothing else:
            // the name, the face and the time are already true. Faded as one
            // layer, as CSS `opacity` fades its box, so a mention's plate and
            // the words over it do not each let the other through. **Not in
            // bubbles**: the send's flight is its feedback, and half strength
            // would flash as Discord's answer lands in the middle of it.
            if row.isPending, row.bubbles == nil {
                context.saveGState()
                context.setAlpha(0.5)
                context.beginTransparencyLayer(
                    in: CGRect(origin: origin, size: block.size).insetBy(dx: -4, dy: -4),
                    auxiliaryInfo: nil
                )
            }
            drawTextBlock(
                block,
                at: origin,
                context: context,
                style: style,
                images: images,
                scale: scale,
                time: state.animationTime,
                state: TextState(
                    revealedSpoilers: state.revealedSpoilers,
                    hoveredPlate: state.hoveredPlate,
                    hoveredSpoiler: state.hoveredSpoiler,
                    layeredEmoji: state.layered.emoji,
                    hoveredLink: state.hoveredLink,
                    selectedRange: state.selectedRange,
                    plates: row.bubbles?.bubble?.ground == .accent ? ThemeInk.current.ownBubblePlates : nil
                )
            )
            if row.isPending, row.bubbles == nil {
                context.endTransparencyLayer()
                context.restoreGState()
            }
            if let slot = litSystemName, let prepared = litSystemPrepared {
                DisplayNameEffectPainter.draw(
                    prepared,
                    fallback: style.primaryColor.cgColor,
                    time: state.playsNameEffect ? state.animationTime : nil,
                    at: CGPoint(x: rowFrame.minX + slot.origin.x, y: rowFrame.minY + slot.origin.y),
                    context: context
                )
            }
        }

        if let foot = row.editedFoot, !state.hidesBubble {
            drawFrame(
                foot.block,
                at: CGPoint(x: rowFrame.minX + foot.origin.x, y: rowFrame.minY + foot.origin.y),
                context: context
            )
        }

        for (index, slot) in row.stickers.enumerated() where !state.layered.stickers.contains(index) {
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
            // A note on its way out of the composer: the flight has its pixels.
            if slot.kind == .voice, state.hidesBubble { continue }
            let frame = slot.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawAttachment(
                slot,
                in: frame,
                context: context,
                style: style,
                images: images,
                scale: scale,
                isRevealed: state.revealedAttachments.contains(index),
                isLayered: state.layered.attachments.contains(index),
                clock: state.animationTime,
                // The star is a hover control: it exists on the picture the
                // pointer is on and nowhere else, exactly as the action pill
                // exists on the row the pointer is on.
                favorite: state.hoveredAttachment == index
                    ? (state.isHoveredAttachmentFavorite ? .starred : .unstarred)
                    : nil,
                // A file's Download, on the file the pointer is on — lit while
                // it is on the button itself.
                download: state.hoveredAttachment == index && slot.downloadRect != nil
                    ? state.hoveredComponent == slot.downloadRect?.origin
                    : nil,
                voicePlayback: state.voicePlayback,
                voiceHover: state.hoveredAttachment == index ? state.hoveredComponent : nil
            )
        }

        if let upload = row.upload {
            drawUploadCard(
                upload,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                scale: scale,
                progress: state.uploadProgress,
                isCancelHovered: state.isUploadCancelHovered
            )
        }

        if let hiddenMedia = row.hiddenMedia {
            drawHiddenMedia(
                hiddenMedia,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style
            )
        }

        if let invite = row.activityInvite {
            drawActivityInvite(
                invite,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                accent: state.activityAccent,
                accentEnd: state.activityAccentEnd,
                cover: state.activityCover,
                status: state.activityInviteStatus,
                isJoined: state.activityInviteIsJoined,
                hovered: state.hoveredComponent,
                images: images,
                scale: scale
            )
        }

        if let listenAlong = row.listenAlong {
            drawListenAlong(
                listenAlong,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                card: state.listenAlong,
                now: .now,
                hovered: state.hoveredComponent,
                images: images,
                scale: scale
            )
        }

        if let theme = row.sharedTheme {
            drawSharedThemeCard(
                theme,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                isPreviewing: state.isPreviewingSharedTheme,
                isSaved: state.isSharedThemeSaved,
                hovered: state.hoveredComponent,
                images: images,
                scale: scale
            )
        }

        for card in row.inviteCards {
            drawInviteCard(
                card,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                isSettled: state.settledInviteCodes.contains(card.code),
                hovered: state.hoveredComponent,
                images: images,
                scale: scale,
                style: style
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

        if let card = row.card {
            drawCard(
                card,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                hovered: state.hoveredComponent,
                images: images,
                scale: scale,
                time: state.animationTime
            )
        }

        var embedImageBase = 0
        var embedTextBase = 0
        for (index, slot) in row.embeds.enumerated() {
            // `layered` counts pictures across every embed in the row; this
            // embed's own start at `embedImageBase`.
            let base = embedImageBase
            embedImageBase += slot.images.count
            // The selection counts texts the same way.
            let textBase = embedTextBase
            embedTextBase += slot.texts.count
            var selectedTexts: [Int: NSRange] = [:]
            if !state.selectedEmbedTexts.isEmpty {
                for (place, range) in state.selectedEmbedTexts
                    where place >= textBase && place < textBase + slot.texts.count {
                    selectedTexts[place - textBase] = range
                }
            }
            drawEmbed(
                slot,
                offset: CGPoint(x: rowFrame.minX, y: rowFrame.minY),
                context: context,
                style: style,
                images: images,
                scale: scale,
                clock: state.animationTime,
                layeredImages: Set(state.layered.embedImages.compactMap {
                    $0 >= base && $0 < base + slot.images.count ? $0 - base : nil
                }),
                // A hover control, exactly as the attachment's is: it exists on
                // the picture the pointer is on and nowhere else.
                favorite: state.hoveredEmbed == index
                    ? (state.isHoveredEmbedFavorite ? .starred : .unstarred)
                    : nil,
                isPlayingPreview: slot.previewURL != nil
                    && slot.previewURL == state.playingPreviewURL,
                selectedTexts: selectedTexts
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

        // **In the row's own space, offset like every chip beside it.** These
        // were drawn at their row-space rect as though it were the canvas's,
        // which put them near the top of the transcript — over a channel's
        // welcome header, whenever that strip repainted in the same pass.
        // Both controls are the pointer's — on the message, or on the picker
        // the add control raised. See `visibleReactionControls`.
        let showsControls = state.isHovered || state.isPointerOnReactions || state.pinsReactionControls
        let controls = row.visibleReactionControls(
            canAddReaction: state.canAddReaction && showsControls,
            showsBookmark: state.isBookmarked || showsControls
        )
        for slot in controls {
            drawReactionControl(
                slot,
                in: slot.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY),
                context: context,
                isHovered: state.hoveredComponent == slot.rect.origin,
                isBookmarked: state.isBookmarked
            )
        }
        for (index, slot) in row.reactions.enumerated() {
            let frame = slot.rect.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
            drawReaction(
                slot,
                in: frame,
                context: context,
                style: style,
                isHovered: state.hoveredComponent == slot.rect.origin,
                images: images,
                scale: scale,
                clock: state.animationTime,
                isLayered: state.layered.reactions.contains(index),
                effectStart: slot.kind == .burst ? state.burstEffects[slot.emoji.reactionKey] : nil,
                popElapsed: state.reactionPops[index],
                drawsCount: !state.rollingReactions.contains(index)
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

    /// What the reader and the pointer have done to one block of text.
    /// One message's pictures that play on layers, by their place in the row.
    struct Layered: Sendable, Equatable {
        var stickers: Set<Int> = []
        var attachments: Set<Int> = []
        /// Counted across every embed in the row, in order.
        var embedImages: Set<Int> = []
        /// Indexes into the body's `emojiRects`.
        var emoji: Set<Int> = []
        var reactions: Set<Int> = []
    }

    struct TextState {
        /// Which spoilers have been uncovered. **Nil uncovers every one** — a
        /// block whose spoilers have no click of their own, an embed's, where
        /// a cover nobody can lift would be text nobody can read.
        var revealedSpoilers: Set<Int>?
        /// The plated run under the pointer, when it is a link.
        var hoveredPlate: Int?
        /// The concealed spoiler under the pointer.
        var hoveredSpoiler: Int?
        /// The emoji that play on layers, by index into `emojiRects`.
        var layeredEmoji: Set<Int> = []
        /// The link under the pointer. See `State.hoveredLink`.
        var hoveredLink: MessageText.LinkTarget?
        /// The selected characters, highlighted under the words.
        var selectedRange: NSRange?
        /// What the words' plates are filled with. Nil is the room's own set;
        /// the reader's bubble hands its white one — see `TextPlateInk`.
        var plates: TextPlateInk?
    }

    /// Draws a laid-out block: the plates and rules under the words, the words,
    /// the pictures in the boxes they reserved, and the spoilers over them.
    ///
    /// The context is flipped once around the block rather than per line: CoreText
    /// draws bottom-up and the canvas is top-down, and doing the flip per line
    /// means a CTM save/restore per line of every message on screen.
    ///
    /// **Everything conditional is a walk over an array that is almost always
    /// empty**, so a plain message costs the frame draw and nothing else.
    static func drawTextBlock(
        _ block: TimelineTextBlock,
        at origin: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        /// The shared clock, so an animated custom emoji resolves to the frame
        /// every other moving picture on this canvas is showing.
        time: Double,
        state: TextState
    ) {
        let plates = state.plates ?? ThemeInk.current.plates

        // The selection, under everything else, in the system's own colour.
        if let selected = state.selectedRange, selected.length > 0 {
            context.setFillColor(NSColor.selectedTextBackgroundColor.cgColor)
            for rect in block.selectionRects(for: selected) {
                context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }

        // Under the words: a quote's rule, a fenced block's box, a revealed
        // spoiler's plate, and every chip's.
        for rule in block.quoteRules {
            let frame = rule.offsetBy(dx: origin.x, dy: origin.y)
            context.setFillColor(plates.quoteRule)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.fillPath()
        }
        for box in block.codeBlockRects {
            drawCodePlate(box.offsetBy(dx: origin.x, dy: origin.y), corner: 4, plates: plates, context: context)
        }
        for (rect, spoiler) in block.spoilerRects where state.revealedSpoilers?.contains(spoiler) ?? true {
            context.setFillColor(plates.spoilerRevealed)
            context.addPath(CGPath(
                roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y),
                cornerWidth: 4, cornerHeight: 4, transform: nil
            ))
            context.fillPath()
        }
        var overpaint: [(rect: CGRect, plate: Int)] = []
        for (rect, index) in block.plateRects {
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y)
            let isHovered = state.hoveredPlate == index
            switch block.text.plates[index].kind {
            case .mention:
                context.setFillColor(isHovered ? plates.mentionHoverFill : plates.mentionFill)
                if isHovered { overpaint.append((frame, index)) }
            case .role(let fill, let hoverFill):
                context.setFillColor(isHovered ? hoverFill : fill)
            case .gradientRole(let fill, let hoverFill, _):
                context.setFillColor(isHovered ? hoverFill : fill)
                overpaint.append((frame, index))
            case .timestamp:
                context.setFillColor(plates.timestampFill)
            case .code:
                drawCodePlate(frame, corner: 4, plates: plates, context: context)
                continue
            case .highlight:
                context.setFillColor(TextPlateInk.highlightFill)
                context.fill(frame)
                continue
            }
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
        }

        drawFrame(block, at: origin, context: context)

        // An `ansi` block's overlines (`53`), which CoreText cannot draw: a
        // rule along the top of each line the run crosses, in the run's ink.
        for range in block.text.overlines {
            let ink = block.text.attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
            context.setFillColor((ink as? NSColor)?.cgColor ?? style.primaryColor.cgColor)
            for rect in block.selectionRects(for: range) {
                let frame = rect.offsetBy(dx: origin.x, dy: origin.y)
                context.fill(CGRect(x: frame.minX, y: frame.minY + 1, width: frame.width, height: 1))
            }
        }

        // Glyphs painted through something other than their ink: a gradient
        // role, and a hovered mention's white on its solid plate.
        for (frame, index) in overpaint {
            switch block.text.plates[index].kind {
            case .gradientRole(_, _, let gradient):
                paintGlyphs(of: block, at: origin, in: frame, context: context) {
                    $0.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: frame.minX, y: frame.midY),
                        end: CGPoint(x: frame.maxX, y: frame.midY),
                        options: []
                    )
                }
            default:
                paintGlyphs(of: block, at: origin, in: frame, context: context) {
                    $0.setFillColor(CGColor.white)
                    $0.fill(frame)
                }
            }
        }

        // Inline emoji, drawn into the boxes the run delegates reserved.
        for (index, entry) in block.emojiRects.enumerated() where !state.layeredEmoji.contains(index) {
            let frame = entry.rect.offsetBy(dx: origin.x, dy: origin.y)
            guard let url = entry.emoji.id.flatMap({
                CDN.emoji(id: $0, animated: entry.emoji.isAnimated, side: frame.width)
            }) else { continue }
            let pixels = Int((frame.width * scale).rounded(.up))
            let key = ImageStore.Key(url: url, maximumPixelSize: pixels)
            // **The filmstrip first for an animated one**, exactly as a sticker
            // resolves — see `stickerFrame`. Without this every `<a:name:id>` in
            // the transcript sat on frame zero forever: the URL was already the
            // `.gif`, and `ImageStore` decodes one frame of it. The still below
            // is still the fallback, because it is what is on screen while the
            // strip decodes.
            let animated: CGImage? = entry.emoji.isAnimated
                ? AnimatedImageStore.shared
                    .cached(AnimatedImageStore.Key(url: url, maximumPixelSize: pixels))
                    .map { $0.frames[$0.index(at: time)] }
                : nil
            if let image = animated ?? images.cached(key) {
                // **Flipped, like every other picture this file draws.** Core
                // Graphics origins an image bottom-left and the canvas is
                // top-left, so an unflipped `draw` puts every custom emoji in
                // the transcript upside down — which is invisible on a symmetric
                // one and unmissable on a face.
                drawFlipped(image, in: frame, context: context, fit: .contain)
            } else {
                // A soft plate rather than nothing, so a line does not visibly
                // reflow when the picture lands — the box was already reserved.
                context.setFillColor(plates.emojiPlaceholder)
                context.fillEllipse(in: frame.insetBy(dx: 2, dy: 2))
            }
        }

        // Inline symbols, in the mention's own colour so the glyph and the
        // name it leads read as one chip — white on a hovered one's solid plate.
        let hoveredFrames = overpaint.map(\.rect)
        for entry in block.symbolRects {
            let frame = entry.rect.offsetBy(dx: origin.x, dy: origin.y)
            drawSymbol(
                entry.name,
                tint: hoveredFrames.contains { $0.intersects(frame) } ? .white : style.mentionColor,
                in: frame,
                context: context
            )
        }

        // The hovered link's underline — Discord's `a:hover` — on every line it
        // crosses. Only a URL: a mention or a channel chip answers the pointer
        // with its plate instead.
        if let hovered = state.hoveredLink, case .url = hovered {
            let font = style.bodyFont
            context.setFillColor(style.linkColor.cgColor)
            for entry in block.linkRects where entry.target == hovered {
                let rect = entry.rect.offsetBy(dx: origin.x, dy: origin.y)
                let baseline = rect.maxY + font.descender
                context.fill(CGRect(
                    x: rect.minX, y: baseline + 1.5,
                    width: rect.width, height: max(1, font.underlineThickness)
                ))
            }
        }

        // Over everything: a concealed spoiler is an opaque plate on top of the
        // words it hides, so revealing one is a repaint and never a relayout.
        for (rect, spoiler) in block.spoilerRects {
            guard let revealed = state.revealedSpoilers, !revealed.contains(spoiler) else { continue }
            context.setFillColor(
                state.hoveredSpoiler == spoiler ? plates.spoilerHiddenHover : plates.spoilerHidden
            )
            context.addPath(CGPath(
                roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y),
                cornerWidth: 4, cornerHeight: 4, transform: nil
            ))
            context.fillPath()
        }
    }

    /// The block's glyphs, flipped once into the canvas's top-down space.
    private static func drawFrame(_ block: TimelineTextBlock, at origin: CGPoint, context: CGContext) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + block.size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(block.frame, context)
        context.restoreGState()
    }

    /// Inline code's plate and a fenced block's box: the code tint inside a
    /// hairline, the stroke inset half a point so it lands on whole pixels.
    private static func drawCodePlate(
        _ frame: CGRect,
        corner: CGFloat,
        plates: TextPlateInk,
        context: CGContext
    ) {
        let shape = CGPath(roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil)
        context.setFillColor(plates.codeFill)
        context.addPath(shape)
        context.fillPath()
        let stroke = frame.insetBy(dx: 0.5, dy: 0.5)
        context.setStrokeColor(plates.codeBorder)
        context.setLineWidth(1)
        context.addPath(CGPath(
            roundedRect: stroke,
            cornerWidth: corner - 0.5, cornerHeight: corner - 0.5, transform: nil
        ))
        context.strokePath()
    }

    /// Repaints the glyphs inside `rect` through `fill` — a gradient, a colour.
    ///
    /// **A transparency layer and `.sourceIn`, never a text clip**: Core Text's
    /// clip modes draw nothing (`INVARIANTS.md` and memory both say so). The
    /// frame is drawn into the layer clipped to the chip, and the fill keeps
    /// only what the glyphs covered. Only a gradient role and the one hovered
    /// mention ever come here.
    private static func paintGlyphs(
        of block: TimelineTextBlock,
        at origin: CGPoint,
        in rect: CGRect,
        context: CGContext,
        fill: (CGContext) -> Void
    ) {
        context.saveGState()
        context.clip(to: rect)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawFrame(block, at: origin, context: context)
        context.setBlendMode(.sourceIn)
        fill(context)
        context.endTransparencyLayer()
        context.restoreGState()
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
        /// **The enhanced role style.** Two or more stops painted *through* the
        /// glyphs rather than behind them — which is what `background-clip:
        /// text` does in Discord's stylesheet, and which a fill colour cannot
        /// express at all. Nil for every ordinary name, which is nearly all of
        /// them, and the branch then costs one comparison.
        gradient: [NSColor]? = nil,
        /// Where the ramp has travelled to, `0..<1`, or nil for a name that is
        /// standing still.
        ///
        /// **Nil is also what turns the glow off**, because Discord lights and
        /// moves an enhanced role's name together — both are its hover state,
        /// and a glowing name that did not travel would read as a rendering
        /// artefact rather than as an answer to the pointer.
        gradientPhase: CGFloat? = nil,
        context: CGContext
    ) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        // Shaped once and kept — see `DrawnLineCache`. A truncating line needs
        // a width to truncate against; without one it draws past the rect and
        // over whatever is beside it.
        let shaped = DrawnLineCache.shared.line(string, font: font, tracking: tracking, maxWidth: maxWidth)
        let drawn = shaped.line
        let ascent = shaped.ascent
        let width = shaped.width
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
        // The line carries no ink of its own: it takes the context's, so one
        // shaped line serves a name at rest, lit, muted and unread.
        context.setFillColor(color.cgColor)
        let tiles = Int((width / Self.gradientTile).rounded(.up)) + 1
        if let ramp = Self.ramp(gradient, tiles: tiles) {
            let phase = gradientPhase ?? 0
            // **The glow is a shadow, not a second blurred copy of the text.**
            // Discord draws the name again at `blur(4px)` and 70 % behind
            // itself; a zero-offset shadow in the ramp's own accent is the same
            // halo for one draw instead of two, which matters on a canvas that
            // repaints a row per frame. Set before the layer, so it applies to
            // the layer's whole composite rather than to the glyphs inside it.
            if gradientPhase != nil, let accent = gradient?.dropFirst().first {
                context.setShadow(
                    offset: .zero,
                    blur: 4,
                    color: accent.usingColorSpace(.sRGB)?.withAlphaComponent(0.7).cgColor
                )
            }
            // **A transparency layer and `.sourceIn`, NOT `setTextDrawingMode(.clip)`.**
            // The clip recipe is the one everybody reaches for and it drew
            // nothing here: Core Text sets the fill colour from each run's own
            // attributes as it draws, which puts the text drawing mode back,
            // so the glyphs never reached the clipping path and the ramp
            // painted into an empty region — a name that simply vanished.
            //
            // Drawing the glyphs into a layer and compositing the ramp *into*
            // their coverage asks nothing of Core Text at all, which is why it
            // cannot be undone by an attribute.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            CTLineDraw(drawn, context)
            context.setBlendMode(.sourceIn)
            // **Discord's tile: a hundred points, repeated, travelling right.**
            // Its name is `background-size: 100px` and animates
            // `background-position` from 0 to 100px every second and a half
            // (`gradientUsernameAnimation`, stylesheet `858942`) — so a long
            // name shows several cycles, every name moves at one speed, and the
            // colours flow left to right. This used to lay one cycle across the
            // name's own width and slide it LEFT, which is every gradient on
            // the canvas running backwards next to Discord's. The list wraps
            // back to its first colour, so copies laid end to end are periodic
            // at the tile, and phase 1 is indistinguishable from phase 0.
            let start = (phase - 1) * Self.gradientTile
            context.drawLinearGradient(
                ramp,
                start: CGPoint(x: start, y: 0),
                end: CGPoint(x: start + CGFloat(tiles) * Self.gradientTile, y: 0),
                // The glyphs run the full width, so both ends have to keep
                // painting past the last stop or the first and last letters
                // come out unfilled.
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            context.endTransparencyLayer()
        } else {
            CTLineDraw(drawn, context)
        }
        context.restoreGState()
        return width
    }

    /// The ramp a gradient name is filled through, or nil for an ordinary one.
    ///
    /// **Converted to sRGB first.** A catalog colour has no components until it
    /// is resolved against a colour space, and `CGGradient` answers nil for a
    /// list it cannot read — which would silently draw nothing at all where the
    /// name used to be.
    /// - Parameter repeating: lay the stops down twice, for a ramp that has to
    ///   slide without showing where it started.
    /// One cycle of a role gradient, in points — Discord's `background-size`.
    static let gradientTile: CGFloat = 100

    private static func ramp(_ colors: [NSColor]?, tiles: Int) -> CGGradient? {
        guard let colors, colors.count >= 2 else { return nil }
        // The list ends on the colour it began with, so each copy joins the one
        // before without a seam — and the duplicate join is dropped rather than
        // drawn twice, which would put a flat spot at every tile's edge.
        let laid = colors + (1..<max(1, tiles)).flatMap { _ in colors.dropFirst() }
        let resolved = laid.compactMap { $0.usingColorSpace(.sRGB)?.cgColor }
        guard resolved.count == laid.count else { return nil }
        return CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: resolved as CFArray,
            locations: nil
        )
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
        isChipHovered: Bool,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        if let elbowBottom = header.elbowBottom {
            drawElbow(
                from: offset.y + elbowBottom,
                to: offset.y + header.rect.midY,
                offset: offset,
                context: context
            )
        }

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
            // On the line's middle, as a reply's name is, with the face beside
            // it and the chip after it.
            at: CGPoint(
                x: offset.x + header.leadRect.minX,
                y: capCenteredY(of: header.leadFace ?? font, in: header.leadRect) + offset.y
            ),
            maxWidth: header.leadRect.width,
            tracking: header.leadTracking,
            context: context
        )

        // Discord's chip: a mention's plate, its ink, and white on solid under
        // the pointer. A label is only the name in that ink.
        let chip = header.chipRect.offsetBy(dx: offset.x, dy: offset.y)
        var ink = style.mentionColor
        if header.chip.hasPlate {
            let plates = ThemeInk.current.plates
            context.addPath(CGPath(roundedRect: chip, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.setFillColor(isChipHovered ? plates.mentionHoverFill : plates.mentionFill)
            context.fillPath()
            if isChipHovered { ink = .white }
        }
        if let glyph = header.glyphRect {
            context.addPath(AppsGlyph.path(in: glyph.offsetBy(dx: offset.x, dy: offset.y)))
            context.setFillColor(ink.cgColor)
            context.fillPath()
        }

        _ = drawText(
            header.command,
            font: header.commandFont,
            color: ink,
            at: CGPoint(
                x: offset.x + header.commandRect.minX,
                y: capCenteredY(of: header.commandFont, in: header.commandRect) + offset.y
            ),
            maxWidth: header.commandRect.width + 1,
            context: context
        )
    }

    /// The connector a reply or a command line rises out of the avatar
    /// gutter on, stroked as one path — see `drawInteractionHeader`.
    private static func drawElbow(from bottom: CGFloat, to midY: CGFloat, offset: CGPoint, context: CGContext) {
        let x = offset.x + TimelineMetrics.replyElbowX
        let end = offset.x + TimelineMetrics.replyElbowEndX
        context.saveGState()
        context.setStrokeColor(ThemeInk.current.selectionFill)
        context.setLineWidth(TimelineMetrics.replyElbowWidth)
        context.setLineCap(.round)
        context.beginPath()
        context.move(to: CGPoint(x: x, y: bottom))
        context.addArc(
            tangent1End: CGPoint(x: x, y: midY),
            tangent2End: CGPoint(x: end, y: midY),
            radius: TimelineMetrics.replyElbowRadius
        )
        context.addLine(to: CGPoint(x: end, y: midY))
        context.strokePath()
        context.restoreGState()
    }

    /// A bubble row's own marks: the bubble under the words, lifted while the
    /// pointer is on the row and tinted where it mentions the reader, and the
    /// time beside it on the side the row leaves open.
    private static func drawBubble(
        _ bubbles: BubbleRow,
        of row: MessageRow,
        in rowFrame: CGRect,
        state: State,
        style: MessageTextStyle,
        context: CGContext
    ) {
        if let bubble = bubbles.bubble, !state.hidesBubble {
            let ink = ThemeInk.current
            let tint = BubbleTint.current
            context.saveGState()
            context.translateBy(x: rowFrame.minX, y: rowFrame.minY)
            context.addPath(bubble.path)
            switch bubble.ground {
            case .accent: context.setFillColor(state.isHovered ? ink.ownBubbleHover : ink.ownBubble)
            case .own: context.setFillColor(state.isHovered ? tint.ownHover : tint.own)
            case .neutral: context.setFillColor(state.isHovered ? tint.otherHover : tint.other)
            }
            context.fillPath()
            // The glass's edge: a hairline where a frosted bubble meets the
            // wallpaper, so it reads as an object over the picture rather than
            // a darker patch of it.
            if let rim = tint.rim, bubble.ground != .accent {
                context.addPath(bubble.path)
                context.setStrokeColor(rim)
                context.setLineWidth(1)
                context.strokePath()
            }
            if row.mentionsMe {
                context.addPath(bubble.path)
                context.setFillColor(ink.mentionedBubbleTint)
                context.fillPath()
            }
            context.restoreGState()
        }
        if let failure = bubbles.failure, !state.hidesBubble {
            drawFailure(failure, in: rowFrame, isHovered: state.hoveredComponent == failure.badge.origin,
                        style: style, context: context)
        }
        guard state.showsGutterTimestamp, !bubbles.timeRect.isEmpty, !state.hidesBubble else { return }
        drawText(
            row.gutterTimestampText,
            font: style.metadataFont,
            color: style.tertiaryColor,
            at: CGPoint(x: rowFrame.minX + bubbles.timeRect.minX, y: rowFrame.minY + bubbles.timeRect.minY),
            maxWidth: bubbles.timeRect.width + 8,
            context: context
        )
    }

    /// A refused send's marks: Messages' red disc with a white "!", which
    /// brightens under the pointer, and "Not Delivered" in the same red.
    private static func drawFailure(
        _ failure: BubbleFailure,
        in rowFrame: CGRect,
        isHovered: Bool,
        style: MessageTextStyle,
        context: CGContext
    ) {
        let badge = failure.badge.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
        // The system red rather than the critical ink, which is softened for
        // words and reads pink as a filled disc.
        let red = isHovered ? NSColor.systemRed.highlight(withLevel: 0.15) ?? .systemRed : .systemRed
        context.setFillColor(red.cgColor)
        context.fillEllipse(in: badge)
        drawSymbol(
            "exclamationmark",
            tint: .white,
            in: badge.insetBy(dx: badge.width * 0.25, dy: badge.height * 0.25),
            context: context
        )
        drawText(
            BubbleFailure.caption,
            font: style.metadataFont,
            color: style.criticalColor,
            at: CGPoint(x: rowFrame.minX + failure.caption.minX, y: rowFrame.minY + failure.caption.minY),
            maxWidth: failure.caption.width + 8,
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
        if let elbowBottom = header.elbowBottom {
            drawElbow(
                from: offset.y + elbowBottom,
                to: offset.y + header.rect.midY,
                offset: offset,
                context: context
            )
        }

        if header.badgeRect != .zero {
            drawReplyBadge(in: header.badgeRect.offsetBy(dx: offset.x, dy: offset.y), context: context, style: style)
        }
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
                font: header.excerptFont,
                color: style.tertiaryColor,
                at: CGPoint(
                    x: offset.x + header.excerptRect.minX,
                    y: capCenteredY(of: header.excerptFont, in: header.excerptRect) + offset.y
                ),
                maxWidth: header.excerptRect.width,
                context: context
            )
        }
    }

    /// Discord's reply badge — `replyBadge` with its `replyIcon` — where a
    /// quote's face would be: a 16-point disc of `--background-base-lowest`
    /// carrying the reply arrow at 10.8 × 7.2 in `--text-default`.
    private static func drawReplyBadge(in frame: CGRect, context: CGContext, style: MessageTextStyle) {
        context.saveGState()
        context.setFillColor(ThemeInk.current.surface)
        context.fillEllipse(in: frame)
        let glyph = CGSize(width: 10.8, height: 7.2)
        // The canvas is flipped, as the SVG's own space is, so the arrow goes
        // in unturned: moved to the disc's centre and scaled from its 12 × 8 box.
        context.translateBy(x: frame.midX - glyph.width / 2, y: frame.midY - glyph.height / 2)
        context.scaleBy(x: glyph.width / 12, y: glyph.height / 8)
        context.addPath(replyArrow)
        context.setFillColor(style.primaryColor.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    /// Discord's reply arrow, from the 12 × 8 path its reply header draws
    /// (`b9176d0f…`, `V`), point for point. Built once and never mutated after,
    /// which is what makes the shared reference safe across painters.
    private nonisolated(unsafe) static let replyArrow: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.80974, y: 3.59646))
        path.addLine(to: CGPoint(x: 5.12565, y: 0.46843))
        path.addCurve(to: CGPoint(x: 5.2951, y: 0.40176), control1: CGPoint(x: 5.17446, y: 0.43116), control2: CGPoint(x: 5.23323, y: 0.40804))
        path.addCurve(to: CGPoint(x: 5.4752, y: 0.43295), control1: CGPoint(x: 5.35698, y: 0.39548), control2: CGPoint(x: 5.41943, y: 0.4063))
        path.addCurve(to: CGPoint(x: 5.61013, y: 0.55234), control1: CGPoint(x: 5.53096, y: 0.45961), control2: CGPoint(x: 5.57776, y: 0.50101))
        path.addCurve(to: CGPoint(x: 5.6581, y: 0.72294), control1: CGPoint(x: 5.64251, y: 0.60368), control2: CGPoint(x: 5.65914, y: 0.66283))
        path.addLine(to: CGPoint(x: 5.6581, y: 2.3707))
        path.addCurve(to: CGPoint(x: 11.3991, y: 7.21174), control1: CGPoint(x: 10.3624, y: 2.3707), control2: CGPoint(x: 11.2539, y: 5.52482))
        path.addCurve(to: CGPoint(x: 11.3474, y: 7.40312), control1: CGPoint(x: 11.4028, y: 7.27916), control2: CGPoint(x: 11.3848, y: 7.34603))
        path.addCurve(to: CGPoint(x: 11.1908, y: 7.53049), control1: CGPoint(x: 11.3101, y: 7.46021), control2: CGPoint(x: 11.2554, y: 7.50471))
        path.addCurve(to: CGPoint(x: 10.9868, y: 7.54703), control1: CGPoint(x: 11.1262, y: 7.55626), control2: CGPoint(x: 11.0549, y: 7.56204))
        path.addCurve(to: CGPoint(x: 10.8104, y: 7.44666), control1: CGPoint(x: 10.9187, y: 7.53201), control2: CGPoint(x: 10.857, y: 7.49695))
        path.addCurve(to: CGPoint(x: 5.6581, y: 5.63359), control1: CGPoint(x: 8.72224, y: 5.08977), control2: CGPoint(x: 5.6581, y: 5.63359))
        path.addLine(to: CGPoint(x: 5.6581, y: 7.28135))
        path.addCurve(to: CGPoint(x: 5.60931, y: 7.44894), control1: CGPoint(x: 5.65831, y: 7.34051), control2: CGPoint(x: 5.64141, y: 7.39856))
        path.addCurve(to: CGPoint(x: 5.4764, y: 7.5665), control1: CGPoint(x: 5.5772, y: 7.49932), control2: CGPoint(x: 5.53117, y: 7.54004))
        path.addCurve(to: CGPoint(x: 5.29932, y: 7.59869), control1: CGPoint(x: 5.42163, y: 7.59296), control2: CGPoint(x: 5.3603, y: 7.60411))
        path.addCurve(to: CGPoint(x: 5.13128, y: 7.53585), control1: CGPoint(x: 5.23834, y: 7.59328), control2: CGPoint(x: 5.18014, y: 7.57151))
        path.addLine(to: CGPoint(x: 0.80974, y: 4.40892))
        path.addCurve(to: CGPoint(x: 0.65507, y: 4.22975), control1: CGPoint(x: 0.74449, y: 4.3616), control2: CGPoint(x: 0.69154, y: 4.30026))
        path.addCurve(to: CGPoint(x: 0.59961, y: 4.00269), control1: CGPoint(x: 0.6186, y: 4.15925), control2: CGPoint(x: 0.59961, y: 4.08151))
        path.addCurve(to: CGPoint(x: 0.65507, y: 3.77562), control1: CGPoint(x: 0.59961, y: 3.92386), control2: CGPoint(x: 0.6186, y: 3.84612))
        path.addCurve(to: CGPoint(x: 0.80974, y: 3.59646), control1: CGPoint(x: 0.69154, y: 3.70511), control2: CGPoint(x: 0.74449, y: 3.64377))
        path.closeSubpath()
        return path
    }()

    /// - Parameter peekSide: the point size the picture was *requested* at, when
    ///   that differs from the box it is drawn in. The cache is keyed on pixel
    ///   size, so a reply header drawing a 16-point face has to look in the slot
    ///   the 38-point prefetch filled — peeking with its own box's size looks in
    ///   a slot nothing was ever put in, and the face is a permanent monogram.
    /// A bubble run's face on its own, for the layer that carries it while it
    /// rides the scroll (`StickyFaces`): the same drawing as a row's (picture
    /// or monogram, decoration, the hover film's frames), asking the cache
    /// with the same key the transcript's prefetch does.
    static func drawBubbleFace(
        url: URL?,
        monogram: String,
        decorationURL: URL?,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        avatarFrame: CGImage?,
        decorationFrame: CGImage?
    ) {
        drawAvatar(
            url: url,
            monogram: monogram,
            in: frame,
            context: context,
            style: style,
            images: images,
            scale: scale,
            peekSide: Metrics.avatarMessage,
            decorationURL: decorationURL,
            avatarFrame: avatarFrame,
            decorationFrame: decorationFrame
        )
    }

    private static func drawAvatar(
        url: URL?,
        monogram: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        peekSide: CGFloat? = nil,
        /// The artwork worn around the face. **Nil on a reply header's
        /// sixteen-point avatar**, where Discord draws none either: a
        /// decoration scaled to that is a smear, and the quoted line is a
        /// pointer at a message rather than a portrait.
        decorationURL: URL? = nil,
        avatarFrame: CGImage? = nil,
        decorationFrame: CGImage? = nil
    ) {
        context.saveGState()
        context.addEllipse(in: frame)
        context.clip()

        // The moving face where this is the row playing one, the decoded still
        // everywhere else.
        if let image = avatarFrame ?? url.flatMap({ url in
            images.cached(ImageStore.Key(
                url: url,
                maximumPixelSize: Int(((peekSide ?? frame.width) * scale).rounded(.up))
            ))
        }) {
            drawFlipped(image, in: frame, context: context)
            context.restoreGState()
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
        }

        // **After the clip is gone, and for a monogram too.** A decoration is
        // worn at 1.2x around the circle, so it is the one thing here that must
        // be outside the ellipse — and somebody with no avatar still wears
        // theirs, which an early return for the monogram branch would drop.
        guard decorationURL != nil || decorationFrame != nil else { return }
        drawDecoration(
            decorationFrame ?? decorationURL.flatMap { url in
                images.cached(
                    ImageStore.Key(
                        url: url,
                        // From the size the face was asked for, as the
                        // prefetch asks for the decoration around it.
                        maximumPixelSize: Int(
                            ((peekSide ?? frame.width) * Metrics.decorationScale * scale).rounded(.up)
                        )
                    ),
                    bucket: .thumbnail
                )
            },
            around: frame,
            context: context
        )
    }

    private static func drawAttachment(
        _ slot: AttachmentSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        isRevealed: Bool,
        /// Whether the picture plays on a layer over the canvas, which leaves
        /// its box to that layer.
        isLayered: Bool = false,
        clock: Double,
        favorite: FavoriteBadge?,
        /// Whether a file card shows its Download — nil where it does not —
        /// and whether the pointer is on it.
        download: Bool? = nil,
        /// Where the voice notes stand, and which of a note's controls the pointer's on.
        voicePlayback: VoiceNotePlayback? = nil,
        voiceHover: CGPoint? = nil
    ) {
        // A spoiler stays covered until it is clicked, and the click that
        // uncovers it is not the click that opens it — a picture somebody hid
        // deliberately must not be shown full-screen by the same press that
        // reveals it.
        let isHidden = slot.isSpoiler && !isRevealed
        switch slot.kind {
        case .image, .video:
            // A picture on a layer leaves its box empty for the layer.
            guard !isLayered else { break }
            drawAttachmentArtwork(
                slot,
                in: frame,
                context: context,
                images: images,
                scale: scale,
                isHidden: isHidden,
                clock: clock
            )
            if let clip = slot.clip, !isHidden {
                drawClipHeader(clip, in: frame, context: context, style: style, images: images, scale: scale)
            }
        case .voice:
            drawVoiceNote(
                slot,
                in: frame,
                context: context,
                style: style,
                playback: voicePlayback,
                hover: voiceHover,
                clock: clock
            )
        case .textPreview:
            // The hosted card draws it.
            break
        case .file:
            drawFileCard(slot, in: frame, context: context, style: style, scale: scale)
            if let isLit = download, let button = slot.downloadRect {
                drawFileHoverButton(
                    button.offsetBy(dx: frame.minX - slot.rect.minX, dy: frame.minY - slot.rect.minY),
                    isLit: isLit,
                    context: context,
                    style: style
                )
            }
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
    /// Internal rather than private: `EmbedPainter` is an extension on this type
    /// in another file and draws the same badge on an unfurled GIF. One painter
    /// for one control — two copies is two places for the star to stop agreeing
    /// with itself.
    static func drawFavoriteBadge(
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
                drawFlipped(
                    film.frames[film.index(at: clock)],
                    in: frame,
                    context: context,
                    fit: .init(cropsToFill: slot.cropsToFill)
                )
                drewArtwork = true
            } else if let image = images.cached(
                ImageStore.Key(url: url, maximumPixelSize: pixels), bucket: .attachment
            ) {
                drawFlipped(image, in: frame, context: context, fit: .init(cropsToFill: slot.cropsToFill))
                drewArtwork = true
            }
        }
        if !drewArtwork {
            context.setFillColor(ThemeInk.current.surfaceRaised)
            context.fill(frame)
            // Discord's blurred stand-in over the plate until the picture
            // lands. **And a hidden spoiler's cover** (REDESIGN.md D16):
            // Discord draws the picture itself blurred by 40 points at 55 %
            // brightness (`--__obscured-background-blur-radius`, `-brightness`).
            // The stand-in is that blur already, and it arrives with the
            // message — the picture is never fetched until it is uncovered, so
            // the cover says what colour of thing is under it and nothing more.
            if let placeholder = PlaceholderImages.shared.image(slot.placeholder) {
                context.interpolationQuality = .high
                drawFlipped(placeholder, in: frame, context: context, fit: .init(cropsToFill: slot.cropsToFill))
                if isHidden {
                    context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                    context.fill(frame)
                }
            }
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

    /// A Discord clip's title, game and people over the top of its poster —
    /// see `ClipTileHeader`. White over a shade, as Discord's player draws
    /// them: a poster can be any colour, and a fixed shade is what keeps the
    /// words legible on all of them.
    private static func drawClipHeader(
        _ header: ClipTileHeader,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        context.saveGState()
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.clip()
        let shadeBottom = frame.minY + min(frame.height, ClipTileHeader.shadeHeight)
        if let shade = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                NSColor.black.withAlphaComponent(0.6).cgColor,
                NSColor.black.withAlphaComponent(0).cgColor,
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                shade,
                start: CGPoint(x: frame.midX, y: frame.minY),
                end: CGPoint(x: frame.midX, y: shadeBottom),
                options: []
            )
        }
        context.restoreGState()

        let (faces, overflow) = header.faceRects(in: frame)
        for (face, rect) in zip(header.faces, faces) {
            drawAvatar(
                url: face.url, monogram: face.monogram, in: rect,
                context: context, style: style, images: images, scale: scale
            )
        }
        if let overflow {
            drawChip(
                "+\(header.overflow)",
                in: overflow,
                fill: NSColor.black.withAlphaComponent(0.55),
                textColor: .white,
                font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                context: context
            )
        }

        let left = frame.minX + 12
        let right = (faces.first?.minX ?? overflow?.minX ?? frame.maxX) - 10
        if let title = header.title {
            drawSymbol("film", tint: .white, in: CGRect(x: left, y: frame.minY + 11, width: 14, height: 13), context: context)
            drawText(
                title,
                font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                color: .white,
                at: CGPoint(x: left + 19, y: frame.minY + 9),
                maxWidth: max(0, right - left - 19),
                context: context
            )
        }
        if let subtitle = header.subtitle {
            drawText(
                subtitle,
                font: NSFont.systemFont(ofSize: 11, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.88),
                at: CGPoint(x: left, y: frame.minY + 28),
                maxWidth: max(0, right - left),
                context: context
            )
        }
    }

    /// A file with nothing to show: a glyph, its name, its size.
    ///
    /// **A card, not an empty rectangle.** Anything that is not a picture used
    /// to be laid out as one and then drew a permanent grey box, which is
    /// indistinguishable from a picture that failed to load.
    /// A send's files going up — see `UploadCardSlot`.
    /// A request's media, standing in for itself — Discord's `d1`: a picture's
    /// glyph and "Image attachment" per piece, and why under them.
    private static func drawHiddenMedia(
        _ slot: HiddenMediaSlot,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle
    ) {
        let ink = ThemeInk.current
        let inset = TimelineMetrics.attachmentCardInset
        let glyph: CGFloat = 18
        for tile in slot.tiles {
            let frame = tile.offsetBy(dx: offset.x, dy: offset.y)
            context.addPath(CGPath(
                roundedRect: frame,
                cornerWidth: EmbedLayoutEngine.corner,
                cornerHeight: EmbedLayoutEngine.corner,
                transform: nil
            ))
            context.setFillColor(ink.discordCard)
            context.fillPath()
            drawSymbol(
                "photo",
                tint: style.tertiaryColor,
                in: CGRect(x: frame.minX + inset, y: frame.midY - glyph / 2, width: glyph, height: glyph),
                context: context
            )
            let textX = frame.minX + inset + glyph + Spacing.base
            _ = drawText(
                "Image attachment",
                font: style.bodyFont,
                color: style.tertiaryColor,
                at: CGPoint(x: textX, y: frame.midY - style.bodyFont.pointSize / 2 - 2),
                maxWidth: max(0, frame.maxX - inset - textX),
                context: context
            )
        }
        let note = slot.noteRect.offsetBy(dx: offset.x, dy: offset.y)
        let mark = style.metadataFont.pointSize + 2
        drawSymbol(
            "info.circle",
            tint: style.tertiaryColor,
            in: CGRect(x: note.minX, y: note.midY - mark / 2, width: mark, height: mark),
            context: context
        )
        _ = drawText(
            "Media is hidden until the DM is accepted",
            font: style.metadataFont,
            color: style.tertiaryColor,
            at: CGPoint(x: note.minX + mark + Spacing.tight, y: note.midY - style.metadataFont.pointSize / 2 - 1),
            maxWidth: max(0, note.width - mark - Spacing.tight),
            context: context
        )
    }

    private static func drawUploadCard(
        _ slot: UploadCardSlot,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        scale: CGFloat,
        progress: Double,
        isCancelHovered: Bool
    ) {
        let ink = ThemeInk.current
        let frame = slot.rect.offsetBy(dx: offset.x, dy: offset.y)
        drawFileCardGround(frame, context: context)
        drawFileIcon(slot.fileKind, in: frame, context: context, scale: scale)
        _ = drawText(
            slot.title,
            font: style.bodyFont,
            color: style.primaryColor,
            at: CGPoint(x: slot.titleOrigin.x + offset.x, y: slot.titleOrigin.y + offset.y),
            maxWidth: slot.titleWidth,
            context: context
        )
        _ = drawText(
            slot.sizeLabel,
            font: style.metadataFont,
            color: style.tertiaryColor,
            at: CGPoint(x: slot.sizeOrigin.x + offset.x, y: slot.sizeOrigin.y + offset.y),
            maxWidth: max(0, frame.maxX - slot.sizeOrigin.x - offset.x),
            context: context
        )

        let bar = slot.progressRect.offsetBy(dx: offset.x, dy: offset.y)
        guard progress < 1 else {
            // Every byte is up and Discord is still making the message.
            _ = drawText(
                "Processing...",
                font: style.metadataFont,
                color: style.tertiaryColor,
                at: CGPoint(x: bar.minX, y: bar.midY - style.metadataFont.pointSize / 2 - 1),
                maxWidth: bar.width,
                context: context
            )
            return
        }
        let radius = bar.height / 2
        context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(ink.lift(0.12))
        context.fillPath()
        let filled = CGRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * progress), height: bar.height)
        context.addPath(CGPath(roundedRect: filled, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(ink.accent)
        context.fillPath()

        drawSymbol(
            "xmark",
            tint: isCancelHovered ? style.primaryColor : style.secondaryColor,
            in: slot.cancelRect.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: 2, dy: 2),
            context: context
        )
    }

    /// Discord's file card (`745268`'s `O`): its ground and hairline, the
    /// file type's icon, the name in the link colour, the size muted.
    private static func drawFileCard(
        _ slot: AttachmentSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        scale: CGFloat
    ) {
        drawFileCardGround(frame, context: context)
        drawFileIcon(slot.fileKind, in: frame, context: context, scale: scale)
        // **The words are laid out in the row's space and drawn in the
        // canvas's**, so they move by exactly what moved the card. Drawn at the
        // row-space origins they landed wherever row zero would be — every file
        // card in a transcript was a glyph on an empty plate, its name and size
        // painted somewhere else (Alex's image 37, 2026-10-07).
        let shift = CGPoint(x: frame.minX - slot.rect.minX, y: frame.minY - slot.rect.minY)
        let title = CGPoint(x: slot.titleOrigin.x + shift.x, y: slot.titleOrigin.y + shift.y)
        let subtitle = CGPoint(x: slot.subtitleOrigin.x + shift.x, y: slot.subtitleOrigin.y + shift.y)
        let room = max(0, frame.maxX - TimelineMetrics.fileCardInset - title.x)
        _ = drawText(
            slot.filename,
            font: style.bodyFont,
            color: style.linkColor,
            at: title,
            maxWidth: room,
            context: context
        )
        _ = drawText(
            slot.sizeLabel,
            font: style.metadataFont,
            color: style.tertiaryColor,
            at: subtitle,
            maxWidth: room,
            context: context
        )
    }

    /// A voice note: `(▶) bars 0:12 [1×]`.
    ///
    /// **Real bars, from the waveform the message carried.** Played bars in the accent
    /// and the rest in a strong ink, with nothing pale: the bars are the whole of what
    /// this row says. A note that's playing repaints on the canvas's display link, and
    /// only this row does.
    ///
    /// **A bar the playhead's just passed swells and settles**, worked out from how long
    /// ago that was. Nothing holds per-bar state, so a seek can't set off a burst.
    private static func drawVoiceNote(
        _ slot: AttachmentSlot,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        playback: VoiceNotePlayback?,
        hover: CGPoint?,
        clock: TimeInterval
    ) {
        guard let voice = slot.voice else { return }
        let ink = ThemeInk.current
        let shift = CGPoint(x: frame.minX - slot.rect.minX, y: frame.minY - slot.rect.minY)
        func moved(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: shift.x, dy: shift.y) }
        let radius = frame.height / 2

        if !voice.isBare {
            context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(ink.discordCard)
            context.fillPath()
            context.addPath(CGPath(
                roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: radius - 0.5,
                cornerHeight: radius - 0.5,
                transform: nil
            ))
            context.setStrokeColor(ink.hoverFill)
            context.setLineWidth(1)
            context.strokePath()
        }

        let id = voice.attachmentID
        let isCurrent = playback?.current == id
        let isPlaying = isCurrent && playback?.isPlaying == true
        let isLoading = isCurrent && playback?.isLoading == true
        let hasFailed = playback?.failed.contains(id) == true
        let position = playback?.position(of: id)

        // The disc.
        let disc = moved(voice.disc)
        // On an accent bubble the accent can't be what's lit, so white takes its place,
        // and what's left to play is a white that's been let down.
        let themeAccent = NSColor(cgColor: ink.accent) ?? .controlAccentColor
        let accent = voice.isOnAccent ? NSColor.white : themeAccent
        let unplayed = voice.isOnAccent ? NSColor.white.withAlphaComponent(0.55) : style.primaryColor
        let text = voice.isOnAccent ? NSColor.white : style.primaryColor
        let glyphTint = voice.isOnAccent ? themeAccent : NSColor.white
        let isDiscLit = hover == voice.disc.origin
        context.setFillColor(
            (hasFailed ? NSColor.systemRed : accent).withAlphaComponent(isDiscLit ? 0.85 : 1).cgColor
        )
        context.fillEllipse(in: disc)
        if isLoading {
            drawVoiceSpinner(in: disc, tint: glyphTint, clock: clock, context: context)
        } else {
            let symbol = hasFailed ? "arrow.clockwise" : isPlaying ? "pause.fill" : "play.fill"
            let side: CGFloat = 14
            // A play triangle's weight sits left of its box, so it looks centred a
            // point to the right.
            let nudge: CGFloat = symbol == "play.fill" ? 1 : 0
            drawSymbol(
                symbol,
                tint: hasFailed ? .white : glyphTint,
                in: CGRect(x: disc.midX - side / 2 + nudge, y: disc.midY - side / 2, width: side, height: side),
                context: context
            )
        }

        // The bars.
        let bars = moved(voice.barsRect)
        let count = voice.bars.count
        let played = position.map { seconds -> Int in
            guard voice.duration > 0 else { return 0 }
            return Int((seconds / voice.duration * Double(count)).rounded())
        } ?? 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || LaunchOptions.current.forcesReducedMotion
        let rate = Double(playback?.rate ?? 1)
        func addBar(_ index: Int, height: CGFloat) {
            let barRect = CGRect(
                x: bars.minX + CGFloat(index) * VoiceWaveform.barStep,
                y: bars.midY - height / 2,
                width: VoiceWaveform.barWidth,
                height: height
            )
            context.addPath(CGPath(
                roundedRect: barRect,
                cornerWidth: VoiceWaveform.barCorner,
                cornerHeight: VoiceWaveform.barCorner,
                transform: nil
            ))
        }
        for index in voice.bars.indices where index >= played {
            addBar(index, height: VoiceWaveform.barHeight(voice.bars[index]))
        }
        context.setFillColor(unplayed.cgColor)
        context.fillPath()
        if played > 0 {
            for index in 0..<min(played, count) {
                var value = voice.bars[index]
                if isPlaying, !reduceMotion, let position, count > 0 {
                    let passedAt = Double(index + 1) / Double(count) * voice.duration
                    value = VoiceWaveform.popped(value, age: (position - passedAt) / max(rate, 0.25))
                }
                addBar(index, height: VoiceWaveform.barHeight(value))
            }
            context.setFillColor(accent.cgColor)
            context.fillPath()
        }

        // How long is left, or all of it, for one nobody's touched.
        let remaining = position.map { voice.duration - $0 } ?? voice.duration
        let font = NSFont.monospacedDigitSystemFont(ofSize: style.metadataFont.pointSize, weight: .medium)
        let time = moved(voice.timeRect)
        _ = drawText(
            VoiceWaveform.timeLabel(remaining),
            font: font,
            color: text,
            at: CGPoint(x: time.minX, y: time.midY - font.pointSize / 2 - 2),
            maxWidth: time.width,
            context: context
        )

        // The speed pill.
        let pill = moved(voice.pill)
        let isPillLit = hover == voice.pill.origin
        context.addPath(CGPath(
            roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil
        ))
        context.setFillColor(isPillLit ? ink.selectionFill : ink.hoverFill)
        context.fillPath()
        let label = voiceRateLabel(playback?.rate ?? 1)
        let labelWidth = TimelineLayoutEngine.measure(label, font: font)
        _ = drawText(
            label,
            font: font,
            color: text,
            at: CGPoint(x: pill.midX - labelWidth / 2, y: pill.midY - font.pointSize / 2 - 2),
            maxWidth: pill.width,
            context: context
        )
    }

    /// A note as a picture, for its flight out of the composer: the row's own pixels, so
    /// the landing swaps a layer for exactly what it was showing.
    static func voiceNoteImage(
        _ slot: AttachmentSlot,
        style: MessageTextStyle,
        scale: CGFloat
    ) -> CGImage? {
        let width = Int((slot.rect.width * scale).rounded(.up))
        let height = Int((slot.rect.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawVoiceNote(
            slot,
            in: CGRect(origin: .zero, size: slot.rect.size),
            context: context,
            style: style,
            playback: nil,
            hover: nil,
            clock: 0
        )
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// What the pill says: Discord's numbers, with its leading zero gone.
    static func voiceRateLabel(_ rate: Float) -> String {
        rate == 0.75 ? ".75×" : rate == 1.5 ? "1.5×" : "\(Int(rate))×"
    }

    /// A note coming down: a quarter of a ring going round, in the disc where the play
    /// glyph will be.
    private static func drawVoiceSpinner(
        in disc: CGRect, tint: NSColor, clock: TimeInterval, context: CGContext
    ) {
        let angle = CGFloat(clock.truncatingRemainder(dividingBy: 1)) * 2 * .pi
        context.saveGState()
        context.setStrokeColor(tint.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.addArc(
            center: CGPoint(x: disc.midX, y: disc.midY),
            radius: 7,
            startAngle: angle,
            endAngle: angle + .pi * 1.4,
            clockwise: false
        )
        context.strokePath()
        context.restoreGState()
    }

    /// The glyph for a document, from its extension.
    ///
    /// A short table rather than a UTType lookup: `UTType(filenameExtension:)`
    /// consults the type database, and this is asked once per file card per
    /// repaint.
    /// A file card's ground, as Discord's `.file`: the raised fill, a hairline
    /// (`--border-subtle`), the corner 8.
    private static func drawFileCardGround(_ frame: CGRect, context: CGContext) {
        let ink = ThemeInk.current
        let outline = CGPath(
            roundedRect: frame,
            cornerWidth: EmbedLayoutEngine.corner,
            cornerHeight: EmbedLayoutEngine.corner,
            transform: nil
        )
        context.addPath(outline)
        context.setFillColor(ink.discordCard)
        context.fillPath()
        context.addPath(CGPath(
            roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: EmbedLayoutEngine.corner - 0.5,
            cornerHeight: EmbedLayoutEngine.corner - 0.5,
            transform: nil
        ))
        context.setStrokeColor(ink.hoverFill)
        context.setLineWidth(1)
        context.strokePath()
    }

    /// The file type's icon, 30×40, 16 in from the card's leading edge and
    /// centred on its height.
    private static func drawFileIcon(_ kind: AttachmentFileKind, in frame: CGRect, context: CGContext, scale: CGFloat) {
        guard let icon = FileIconArt.image(for: kind, scale: scale) else { return }
        let size = TimelineMetrics.fileCardIcon
        drawFlipped(
            icon,
            in: CGRect(
                x: frame.minX + TimelineMetrics.fileCardInset,
                y: frame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            context: context
        )
    }

    /// Discord's hover group on a file (`06ab4`): one button, Download, on
    /// the darker ground with a hairline of the darkest, its corner 5 — the
    /// hover fill and the brighter ink while the pointer is on it.
    private static func drawFileHoverButton(_ rect: CGRect, isLit: Bool, context: CGContext, style: MessageTextStyle) {
        let ink = ThemeInk.current
        let outline = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        context.addPath(outline)
        context.setFillColor(ink.surface)
        context.fillPath()
        if isLit {
            context.addPath(outline)
            context.setFillColor(ink.hoverFill)
            context.fillPath()
        }
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil))
        context.setStrokeColor(ink.canvas)
        context.setLineWidth(1)
        context.strokePath()
        drawSymbol(
            "arrow.down.to.line",
            tint: isLit ? style.primaryColor : style.secondaryColor,
            in: rect.insetBy(dx: 6, dy: 6),
            context: context
        )
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
            ThemeInk.current.lift(isHovered ? 0.10 : 0.05)
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

    /// One of the two square controls at the end of the reaction row.
    ///
    /// The same fill and the same corner as a chip it sits beside, because it is
    /// the same kind of object: a small control on the row, not a badge.
    private static func drawReactionControl(
        _ slot: ReactionControlSlot,
        in frame: CGRect,
        context: CGContext,
        isHovered: Bool,
        isBookmarked: Bool
    ) {
        let isOn = slot.kind == .bookmark && isBookmarked
        context.addPath(CGPath(
            roundedRect: frame,
            cornerWidth: TimelineMetrics.reactionChipRadius,
            cornerHeight: TimelineMetrics.reactionChipRadius,
            transform: nil
        ))
        let base: CGFloat = isOn ? 0.22 : 0.07
        context.setFillColor(
            isOn
                ? NSColor.controlAccentColor.withAlphaComponent(base + (isHovered ? 0.12 : 0)).cgColor
                : ThemeInk.current.lift(base + (isHovered ? 0.06 : 0))
        )
        context.fillPath()

        let side = TimelineMetrics.reactionControlGlyphSide
        let symbol: String = switch slot.kind {
        case .addReaction: "face.smiling"
        // Filled once it is on: a bookmark is a state, and a reader scanning a
        // channel has to see which messages they kept without reading a tint
        // difference of one step.
        case .bookmark: isBookmarked ? "bookmark.fill" : "bookmark"
        }
        drawSymbol(
            symbol,
            tint: isOn ? .controlAccentColor : Self.restingActionGlyph,
            in: CGRect(
                x: (frame.midX - side / 2).rounded(),
                y: (frame.midY - side / 2).rounded(),
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
        scale: CGFloat,
        clock: Double,
        /// Whether the emoji plays on a layer over the canvas, which leaves its
        /// glyph box to that layer.
        isLayered: Bool = false,
        effectStart: Double?,
        /// Seconds since this chip arrived or was pressed, while it pops.
        popElapsed: Double? = nil,
        /// False while the count rolls on a layer over the chip.
        drawsCount: Bool = true
    ) {
        // A chip that has just arrived, or just counted the reader in, pops:
        // the whole chip, about its own centre.
        let pop = popElapsed.map(ReactionPop.scale(at:)) ?? 1
        if pop != 1 {
            context.saveGState()
            context.translateBy(x: frame.midX, y: frame.midY)
            context.scaleBy(x: pop, y: pop)
            context.translateBy(x: -frame.midX, y: -frame.midY)
        }
        defer { if pop != 1 { context.restoreGState() } }

        // A super reaction's effect shakes the chip it starts from, for half a
        // second. Everything below — glow, fill, count — shakes with it, as it
        // does in Discord, where the shaken element is the whole chip.
        let shake = effectStart.flatMap { SuperReactionShake.offset(at: clock - $0) }
        if let shake {
            context.saveGState()
            applyShake(shake, around: frame, context: context)
        }
        defer { if shake != nil { context.restoreGState() } }

        // **A rounded square, not a capsule** — see
        // `TimelineMetrics.reactionChipRadius` for the measurement; a lozenge is
        // what this drew and it is what neither reference client draws. A
        // tapback is the exception: Messages' round badge.
        let radius = slot.isTapback ? frame.height / 2 : TimelineMetrics.reactionChipRadius
        let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let tint = BubbleTint.current
        // The reader's own tapback is solid, in the accent, as Messages draws
        // its blue badge; and its count is white on it.
        let isSolid = slot.isTapback && slot.isMine
        let burst = slot.kind == .burst ? slot.palette?.style(isLight: ThemeInk.current.isLight) : nil
        if let burst {
            // **A super reaction wears its emoji's colour**: a tinted fill, a
            // count in the accent, a glow — drawn behind the whole row, see
            // `drawMessage` — and, when the reader is one of the people who
            // sent it, a solid ring in the fill's colour. Discord's numbers,
            // from `SuperReactionPalette`.
            context.addPath(path)
            context.setFillColor(SuperReactionInk.color(burst.background, alpha: burst.opacity))
            context.fillPath()
            if isHovered {
                // The same step a plain chip lifts by, on top of the tint, so a
                // super reaction answers the pointer the way every chip does.
                context.addPath(path)
                context.setFillColor(ThemeInk.current.lift(0.06))
                context.fillPath()
            }
            if slot.isMine {
                context.addPath(path)
                context.setStrokeColor(SuperReactionInk.color(burst.background))
                context.setLineWidth(1)
                context.strokePath()
            }
        } else if isSolid {
            context.addPath(path)
            context.setFillColor(isHovered ? ThemeInk.current.ownBubbleHover : ThemeInk.current.ownBubble)
            context.fillPath()
        } else if slot.isTapback || tint.rim != nil {
            // Glass, like the bubbles: the wallpaper's frost shows through the
            // outline (`TimelineCanvasView.bubbleOutlines`), with the smoke
            // over it — or, on the theme's ground, a lift that holds its own
            // over the bubble a tapback rides. The reader's own chip takes
            // the accent over that.
            context.addPath(path)
            context.setFillColor(isHovered ? tint.badgeHover : tint.badge)
            context.fillPath()
            if slot.isMine {
                context.addPath(path)
                context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(isHovered ? 0.5 : 0.4).cgColor)
                context.fillPath()
            }
            if let rim = tint.rim {
                context.addPath(path)
                context.setStrokeColor(slot.isMine ? NSColor.controlAccentColor.cgColor : rim)
                context.setLineWidth(1)
                context.strokePath()
            }
        } else {
            context.addPath(path)
            // A chip is a control, so it answers the pointer. The reader's own
            // is already accent-tinted; hovering lifts whichever it is by the
            // same step, so the two states stay distinguishable in both
            // directions.
            let base: CGFloat = slot.isMine ? 0.22 : 0.07
            context.setFillColor(
                slot.isMine
                    ? NSColor.controlAccentColor.withAlphaComponent(base + (isHovered ? 0.12 : 0)).cgColor
                    : ThemeInk.current.lift(base + (isHovered ? 0.06 : 0))
            )
            context.fillPath()

            // The reader's own chip carries an outline as well as a tint: on a
            // busy row the fill alone is one step of lightness against four
            // other chips, and "did my reaction land" is the only question the
            // control answers. Everybody else's carries a hairline — at this
            // size a fill seven hundredths off its ground has no edge, and a
            // tile with no edge reads as a smudge.
            let inner = CGPath(
                roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil
            )
            context.addPath(inner)
            context.setStrokeColor(
                slot.isMine
                    ? NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
                    : ThemeInk.current.lift(isHovered ? 0.16 : 0.09)
            )
            context.setLineWidth(1)
            context.strokePath()
        }

        let glyphRect = slot.glyphRect.offsetBy(
            dx: frame.minX - slot.rect.minX, dy: frame.minY - slot.rect.minY
        )
        // While an effect plays, the effect is the emoji.
        if effectStart == nil, !isLayered {
            drawReactionGlyph(slot, in: glyphRect, context: context, style: style,
                              images: images, scale: scale, clock: clock)
        }

        // A tapback carries a count only where there is more than one.
        guard drawsCount, !slot.isTapback || slot.count > 1 else { return }
        let countFont = TimelineMetrics.reactionCountFont(style)
        drawText(
            String(slot.count),
            font: countFont,
            color: reactionCountColor(slot, style: style),
            at: CGPoint(
                x: glyphRect.maxX + TimelineMetrics.reactionGlyphGap,
                y: frame.midY - ((countFont.ascender - countFont.descender) / 2).rounded()
            ),
            maxWidth: max(
                0,
                frame.maxX - glyphRect.maxX
                    - TimelineMetrics.reactionGlyphGap
                    - TimelineMetrics.reactionTrailingInset
            ),
            context: context
        )
    }

    /// The ink a chip's count is drawn in — the painter's, and the roll's that
    /// stands in for it while the number changes (`ReactionCountRolls`).
    ///
    /// A super reaction's is its emoji's accent; the reader's own is the
    /// accent, or white where the chip is solid or glass; everybody else's is
    /// the primary ink. **Not the secondary**: a count is the chip's whole
    /// point, and pale grey numbers were the first thing wrong with these.
    static func reactionCountColor(_ slot: ReactionSlot, style: MessageTextStyle) -> NSColor {
        if slot.kind == .burst, let burst = slot.palette?.style(isLight: ThemeInk.current.isLight) {
            return SuperReactionInk.ink(burst.accent)
        }
        let onGlass = slot.isTapback || BubbleTint.current.rim != nil
        let isSolid = slot.isTapback && slot.isMine
        if isSolid || (slot.isMine && onGlass) { return .white }
        return slot.isMine ? .controlAccentColor : style.primaryColor
    }

    /// Moves the context to where a shaking chip is: offset, and turned about
    /// the chip's own centre — CSS's default `transform-origin`.
    private static func applyShake(
        _ shake: (dx: CGFloat, dy: CGFloat, radians: CGFloat),
        around frame: CGRect,
        context: CGContext
    ) {
        context.translateBy(x: frame.midX + shake.dx, y: frame.midY + shake.dy)
        context.rotate(by: shake.radians)
        context.translateBy(x: -frame.midX, y: -frame.midY)
    }

    /// A chip's emoji: an animated custom one's current frame, a still one's
    /// picture, or a Unicode one's glyph.
    ///
    /// **The filmstrip first for an animated one**, exactly as an inline emoji
    /// resolves — see `drawTextBlock`. The still is the fallback, because it is
    /// what is on screen while the strip decodes.
    private static func drawReactionGlyph(
        _ slot: ReactionSlot,
        in glyphRect: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        clock: Double
    ) {
        guard let url = slot.imageURL else {
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
                at: CGPoint(x: glyphRect.minX, y: glyphRect.minY + 2),
                maxWidth: glyphRect.width,
                context: context
            )
            return
        }
        // A CUSTOM emoji. Its picture is the only correct answer — its `name`
        // is a word like "blobcat", not a glyph — so a miss draws the same soft
        // plate the inline path draws rather than the word.
        let pixels = Int((glyphRect.width * scale).rounded(.up))
        let frame: CGImage? = slot.emoji.isAnimated
            ? AnimatedImageStore.shared
                .cached(AnimatedImageStore.Key(url: url, maximumPixelSize: pixels))
                .map { $0.frames[$0.index(at: clock)] }
            : nil
        if let image = frame ?? images.cached(ImageStore.Key(url: url, maximumPixelSize: pixels)) {
            drawFlipped(image, in: glyphRect, context: context, fit: .contain)
        } else {
            context.setFillColor(ThemeInk.current.placeholderFill)
            context.fillEllipse(in: glyphRect.insetBy(dx: 2, dy: 2))
        }
    }

    /// How a picture meets a box that is not its own shape.
    ///
    /// **`CGContext.draw(_:in:)` stretches**, which is invisible for as long as
    /// every box is derived from its own picture's shape — an avatar, a sized
    /// attachment. It stops being invisible the moment a box is fixed first
    /// and the picture arrives later.
    enum ImageFit {
        /// To the box's edges. Right only where the box came from the picture.
        case stretch
        /// Scaled until the *smaller* overflow is gone, with the rest hanging
        /// outside the box. The caller's clip is what removes it, so this must
        /// never be used to fill a box nothing has clipped.
        case cover
        /// Whole, and centred in the box — CSS `object-fit: contain`, which is
        /// how Discord draws every emoji. A custom emoji can be any shape, and
        /// a wide one drawn to a square box was squeezed into a different
        /// picture.
        case contain

        /// A gallery cell's answer: a cell in the mosaic's shape covers, and a
        /// box sized from its own picture is that picture's edges.
        init(cropsToFill: Bool) { self = cropsToFill ? .cover : .stretch }
    }

    /// Draws a bitmap the right way up.
    ///
    /// Core Graphics origins an image at the bottom-left and this canvas is
    /// flipped, so every `draw(_:in:)` in this file goes through here. It used
    /// to be four lines copied at each call site, and the one copy that was
    /// missing is what drew every inline custom emoji upside down.
    static func drawFlipped(
        _ image: CGImage,
        in frame: CGRect,
        context: CGContext,
        fit: ImageFit = .stretch
    ) {
        let box = switch fit {
        case .stretch: frame
        case .cover: fittedRect(image, in: frame, covering: true)
        case .contain: fittedRect(image, in: frame, covering: false)
        }
        context.saveGState()
        context.translateBy(x: 0, y: frame.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -frame.midY)
        context.draw(image, in: box)
        context.restoreGState()
    }

    // MARK: Avatar decorations

    /// The box a decoration occupies around an avatar drawn in `avatar`.
    ///
    /// **1.2x and concentric, which means it draws OUTSIDE the avatar's own
    /// circle.** A decoration is authored with the face's circle in the middle
    /// of a larger square — ears, a halo, a hat brim all live in the margin —
    /// so a decoration sized to the avatar loses exactly the part that
    /// identifies it. `AvatarView` has always drawn it this way in SwiftUI and
    /// this is the same number, shared so the two surfaces cannot drift.
    ///
    /// It contributes no layout: both canvases place the avatar and then draw
    /// this over whatever is beside it, which is what Discord does too.
    static func decorationRect(around avatar: CGRect) -> CGRect {
        let side = avatar.width * Metrics.decorationScale
        return CGRect(
            x: avatar.midX - side / 2,
            y: avatar.midY - side / 2,
            width: side,
            height: side
        )
    }

    /// One avatar decoration, still or moving.
    ///
    /// **Never clipped to the avatar's circle**, which is the mistake this
    /// function exists to make impossible: the caller draws the face inside a
    /// `clip()` and this must be called after the matching `restoreGState`.
    /// And flipped, like every other bitmap these canvases draw — §4.5's one
    /// rule, and the one whose absence drew every custom emoji upside down.
    static func drawDecoration(_ image: CGImage?, around avatar: CGRect, context: CGContext) {
        guard let image else { return }
        drawFlipped(image, in: decorationRect(around: avatar), context: context)
    }

    /// The rect a picture occupies, centred in `frame`, when it covers the
    /// frame or when it fits inside it.
    static func fittedRect(_ image: CGImage, in frame: CGRect, covering: Bool) -> CGRect {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0, frame.width > 0, frame.height > 0 else { return frame }
        let scale = covering
            ? max(frame.width / width, frame.height / height)
            : min(frame.width / width, frame.height / height)
        let drawn = CGSize(width: width * scale, height: height * scale)
        return CGRect(
            x: frame.midX - drawn.width / 2,
            y: frame.midY - drawn.height / 2,
            width: drawn.width,
            height: drawn.height
        )
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
            context.setFillColor(ThemeInk.current.placeholderFill)
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
    /// A server tag beside a name.
    ///
    /// **The roster's chip, drawn here too.** The metrics come from
    /// `MemberRowGeometry` — the same padding, height, font and badge size the
    /// member list reserves — so the two surfaces cannot drift apart, and a
    /// change to the shape is one edit rather than two.
    static func drawTagChip(
        _ label: String,
        in frame: CGRect,
        badge: URL?,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        context: CGContext
    ) {
        let corner = frame.height / 2
        context.addPath(CGPath(
            roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil
        ))
        context.setFillColor(ThemeInk.current.lift(0.12))
        context.fillPath()

        var textX = frame.minX + MemberRowGeometry.tagChipPadding
        if let badge {
            let side = MemberRowGeometry.tagBadgeSide
            let glyph = CGRect(
                x: textX,
                y: (frame.midY - side / 2).rounded(),
                width: side,
                height: side
            )
            if let image = images.cached(ImageStore.Key(
                url: badge,
                maximumPixelSize: Int((side * scale).rounded(.up))
            )) {
                drawFlipped(image, in: glyph, context: context)
            }
            textX = glyph.maxX + MemberRowGeometry.tagBadgeGap
        }

        let font = MemberRowGeometry.tagChipFont
        drawText(
            label,
            font: font,
            color: style.secondaryColor,
            at: CGPoint(x: textX, y: capCenteredY(of: font, in: frame)),
            maxWidth: frame.maxX - MemberRowGeometry.tagChipPadding - textX,
            context: context
        )
    }

    static func drawChip(
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

    // MARK: Drawn cards

    /// Discord's critical button ground (`--control-critical-primary-background-default`,
    /// `red-new-50`), the same in every theme.
    private static let criticalGround = CGColor(srgbRed: 0xD1 / 255, green: 0x2E / 255, blue: 0x38 / 255, alpha: 1)

    /// A card drawn from parts — see `DrawnCard`. Its grounds are already
    /// first in the list; the control under the pointer draws its lit words.
    static func drawCard(
        _ card: DrawnCard,
        offset: CGPoint,
        context: CGContext,
        style: MessageTextStyle,
        hovered: CGPoint?,
        images: ImageStore,
        scale: CGFloat,
        time: Double
    ) {
        let ink = ThemeInk.current
        for part in card.parts {
            switch part {
            case .ground(let rect, let ground, let corners, let radius):
                let frame = rect.offsetBy(dx: offset.x, dy: offset.y)
                let fill = switch ground {
                case .card: ink.discordCard
                case .bar: ink.surface
                case .plate: ink.hoverFill
                case .critical: criticalGround
                }
                context.setFillColor(fill)
                context.addPath(groundPath(frame, corners: corners, radius: radius))
                context.fillPath()
            case .text(let block, let origin):
                drawTextBlock(
                    block,
                    at: CGPoint(x: origin.x + offset.x, y: origin.y + offset.y),
                    context: context,
                    style: style,
                    images: images,
                    scale: scale,
                    time: time,
                    state: TextState()
                )
            case .symbol(let name, let rect, let tint):
                let color = switch tint {
                case .accent: NSColor.controlAccentColor
                case .primary: style.primaryColor
                case .muted: style.tertiaryColor
                case .critical: style.criticalColor
                case .positive: NSColor(Palette.presenceOnline)
                case .link: style.linkColor
                }
                drawSymbol(
                    name,
                    tint: color,
                    in: rect.offsetBy(dx: offset.x, dy: offset.y),
                    context: context
                )
            case .avatar(let url, let monogram, let rect):
                drawAvatar(
                    url: url,
                    monogram: monogram,
                    in: rect.offsetBy(dx: offset.x, dy: offset.y),
                    context: context,
                    style: style,
                    images: images,
                    scale: scale
                )
            case .tag(let tag, let rect):
                drawChip(
                    tag.label,
                    in: rect.offsetBy(dx: offset.x, dy: offset.y),
                    fill: NSColor.controlAccentColor,
                    textColor: .white,
                    font: AppBadge.font,
                    context: context
                )
            case .dot(let rect):
                context.setFillColor(ink.selectionFill)
                context.fillEllipse(in: rect.offsetBy(dx: offset.x, dy: offset.y))
            }
        }
        for control in card.controls {
            guard let label = control.label else { continue }
            let lit = hovered == control.rect.origin ? control.litLabel ?? label : label
            drawTextBlock(
                lit,
                at: CGPoint(x: control.labelOrigin.x + offset.x, y: control.labelOrigin.y + offset.y),
                context: context,
                style: style,
                images: images,
                scale: scale,
                time: time,
                state: TextState()
            )
        }
    }

    /// A rounded rectangle with only some corners rounded — a card whose bar
    /// is joined under it, and the bar.
    private static func groundPath(_ rect: CGRect, corners: DrawnCard.Corners, radius: CGFloat) -> CGPath {
        let top: CGFloat = corners == .bottom ? 0 : radius
        let bottom: CGFloat = corners == .top ? 0 : radius
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + top), radius: top)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.maxY), radius: bottom)
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottom), radius: bottom)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + top, y: rect.minY), radius: top)
        path.closeSubpath()
        return path
    }

    // MARK: Separators

    /// The open topic's marker: its title in a band across the transcript,
    /// and the glyph that says the band opens the topic's panel.
    ///
    /// **A band rather than a divider.** Discord draws this as the header of
    /// the topic's own card, and it is what the card comes back to when it is
    /// put away — a line of text between two rules would read as one more day
    /// heading.
    private static func drawMarker(
        _ kind: TimelineMark.Kind,
        title: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        switch kind {
        case .topic: drawTopicMarker(title: title, in: frame, context: context, style: style)
        case .summary: drawSummaryMarker(title: title, in: frame, context: context, style: style)
        }
    }

    /// The summary the reader went to: its glyph and title in the link colour,
    /// then a rule to the far edge — Discord's summary divider, as a fact.
    ///
    /// **A rule, not the topic's band**, because it is not a control: the band
    /// is where a topic's panel goes back to and carries the glyph that says
    /// so, and a second band that did nothing would teach the reader that the
    /// first one does nothing either (§5.5).
    private static func drawSummaryMarker(
        title: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        let inset = TimelineMetrics.horizontalMargin
        let glyph = TimelineMetrics.topicMarkerGlyphSide
        let gap: CGFloat = 8
        let midY = frame.midY
        drawSymbol(
            "scroll",
            tint: style.linkColor,
            in: CGRect(x: frame.minX + inset, y: midY - glyph / 2, width: glyph, height: glyph),
            context: context
        )
        let textX = frame.minX + inset + glyph + gap
        let available = frame.maxX - inset - textX
        // Measured from the string that is drawn, cut to what fits — §2.8.
        let width = min(TimelineLayoutEngine.measure(title, font: style.authorFont), available)
        drawText(
            title,
            font: style.authorFont,
            color: style.linkColor,
            at: CGPoint(x: textX, y: midY - style.authorFont.pointSize * 0.62),
            maxWidth: available,
            context: context
        )
        let ruleStart = textX + width + gap
        guard ruleStart < frame.maxX - inset else { return }
        context.setStrokeColor(ThemeInk.current.lift(0.08))
        context.setLineWidth(1)
        context.move(to: CGPoint(x: ruleStart, y: midY))
        context.addLine(to: CGPoint(x: frame.maxX - inset, y: midY))
        context.strokePath()
    }

    private static func drawTopicMarker(
        title: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        let inset = TimelineMetrics.horizontalMargin
        let band = CGRect(
            x: frame.minX + inset,
            y: frame.midY - TimelineMetrics.topicMarkerBandHeight / 2,
            width: frame.width - inset * 2,
            height: TimelineMetrics.topicMarkerBandHeight
        )
        context.addPath(CGPath(
            roundedRect: band, cornerWidth: Radius.row, cornerHeight: Radius.row, transform: nil
        ))
        context.setFillColor(ThemeInk.current.lift(0.06))
        context.fillPath()

        let padding: CGFloat = 10
        let glyph = TimelineMetrics.topicMarkerGlyphSide
        drawSymbol(
            "arrow.up.left.and.arrow.down.right",
            tint: style.secondaryColor,
            in: CGRect(
                x: band.maxX - padding - glyph,
                y: band.midY - glyph / 2,
                width: glyph,
                height: glyph
            ),
            context: context
        )
        drawText(
            title,
            font: style.authorFont,
            color: style.primaryColor,
            at: CGPoint(x: band.minX + padding, y: band.midY - style.authorFont.pointSize * 0.62),
            maxWidth: band.width - padding * 3 - glyph,
            context: context
        )
    }

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

        context.setStrokeColor(ThemeInk.current.lift(0.08))
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
        clock: Double,
        revealedAttachments: Set<Int> = [],
        isFooterHovered: Bool = false
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
        // **The row draws the body when it is the row's own text**
        // (`ForwardedSlot.bodyIsRowText`), with its selection, its revealed
        // spoilers and its lit mentions; drawn here as well it would be twice.
        if let body = slot.body, !slot.bodyIsRowText {
            // The body's own painter, so a forwarded message keeps its quotes,
            // code and mentions. Its spoilers stay covered: beside words of its
            // own, a forward's text is not the row's and takes no click.
            drawTextBlock(
                body,
                at: CGPoint(x: offset.x + slot.bodyOrigin.x, y: offset.y + slot.bodyOrigin.y),
                context: context,
                style: style,
                images: images,
                scale: scale,
                time: clock,
                state: TextState(revealedSpoilers: [])
            )
        }
        for sticker in slot.stickers {
            drawSticker(
                sticker,
                in: sticker.rect.offsetBy(dx: offset.x, dy: offset.y),
                context: context,
                style: style,
                images: images,
                scale: scale,
                time: clock
            )
        }
        for (index, attachment) in slot.attachments.enumerated() {
            drawAttachment(
                attachment,
                in: attachment.rect.offsetBy(dx: offset.x, dy: offset.y),
                context: context,
                style: style,
                images: images,
                scale: scale,
                // Lifted by a click, as on the message's own files.
                isRevealed: revealedAttachments.contains(index),
                clock: clock,
                // No star: favouriting somebody else's forwarded GIF is the
                // message menu's to offer.
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
            // The breadcrumb lights under the pointer, as Discord's does: the
            // whole line is the way to the original.
            if isFooterHovered, slot.jump != nil {
                let plate = slot.footerRect.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -4, dy: -2)
                context.addPath(CGPath(
                    roundedRect: plate, cornerWidth: plate.height / 2, cornerHeight: plate.height / 2, transform: nil
                ))
                context.setFillColor(style.tertiaryColor.withAlphaComponent(0.14).cgColor)
                context.fillPath()
            }
            if let url = slot.footerIconURL {
                let box = slot.footerIconRect.offsetBy(dx: offset.x, dy: offset.y)
                let key = ImageStore.Key(url: url, maximumPixelSize: Int((box.width * scale).rounded(.up)))
                if let icon = images.cached(key, bucket: .thumbnail) {
                    context.saveGState()
                    context.addPath(CGPath(
                        roundedRect: box, cornerWidth: box.width * 0.3, cornerHeight: box.width * 0.3, transform: nil
                    ))
                    context.clip()
                    drawFlipped(icon, in: box, context: context)
                    context.restoreGState()
                } else {
                    context.addPath(CGPath(
                        roundedRect: box, cornerWidth: box.width * 0.3, cornerHeight: box.width * 0.3, transform: nil
                    ))
                    context.setFillColor(ThemeInk.current.placeholderFill)
                    context.fillPath()
                }
            }
            drawTextFrame(
                footer,
                at: CGPoint(x: offset.x + slot.footerOrigin.x, y: offset.y + slot.footerOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
            if slot.jump != nil {
                drawSymbol(
                    "chevron.right",
                    tint: style.tertiaryColor,
                    in: slot.footerChevronRect.offsetBy(dx: offset.x, dy: offset.y),
                    context: context
                )
            }
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
        isButtonHovered: Bool,
        hoveredComponent: CGPoint?,
        images: ImageStore,
        scale: CGFloat
    ) {
        let offset = CGPoint(x: frame.minX, y: frame.minY)

        // The tile. A rounded square rather than a circle: the channel list's
        // own rows are rounded rectangles, and a disc here reads as an avatar —
        // which is what a conversation's head draws instead: its people's face.
        let icon = slot.iconRect.offsetBy(dx: offset.x, dy: offset.y)
        if slot.isRound, slot.avatarURL != nil || slot.avatarMonogram != nil {
            drawAvatar(
                url: slot.avatarURL,
                monogram: slot.avatarMonogram ?? "",
                in: icon,
                context: context,
                style: style,
                images: images,
                scale: scale
            )
        } else {
            if slot.isRound {
                context.addEllipse(in: icon)
            } else {
                context.addPath(CGPath(
                    roundedRect: icon,
                    cornerWidth: Radius.card,
                    cornerHeight: Radius.card,
                    transform: nil
                ))
            }
            context.setFillColor(ThemeInk.current.surfaceRaised)
            context.fillPath()
            drawSymbol(
                slot.symbolName,
                tint: style.secondaryColor,
                in: slot.glyphRect.offsetBy(dx: offset.x, dy: offset.y),
                context: context
            )
        }

        drawTextFrame(
            slot.title,
            at: CGPoint(x: offset.x + slot.titleOrigin.x, y: offset.y + slot.titleOrigin.y),
            context: context,
            images: images,
            scale: scale
        )
        if let subtitle = slot.subtitle {
            drawTextFrame(
                subtitle,
                at: CGPoint(x: offset.x + slot.subtitleOrigin.x, y: offset.y + slot.subtitleOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
        }
        if let note = slot.note {
            drawTextFrame(
                note,
                at: CGPoint(x: offset.x + slot.noteOrigin.x, y: offset.y + slot.noteOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
        }
        // A post's tags, each on the quiet plate the drawn buttons wear.
        for tag in slot.tags {
            let rect = tag.rect.offsetBy(dx: offset.x, dy: offset.y)
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: rect.height / 2,
                cornerHeight: rect.height / 2,
                transform: nil
            ))
            context.setFillColor(ThemeInk.current.lift(0.12))
            context.fillPath()
            drawTextFrame(
                tag.label,
                at: CGPoint(x: offset.x + tag.labelOrigin.x, y: offset.y + tag.labelOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
        }
        if let topic = slot.topic {
            drawTextFrame(
                topic,
                at: CGPoint(x: offset.x + slot.topicOrigin.x, y: offset.y + slot.topicOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
        }
        // A person's servers in common: up to three faces, then the count.
        if let mutuals = slot.mutuals {
            for icon in mutuals.icons {
                drawAvatar(
                    url: icon.mark.iconURL,
                    monogram: icon.mark.monogram,
                    in: icon.rect.offsetBy(dx: offset.x, dy: offset.y),
                    context: context,
                    style: style,
                    images: images,
                    scale: scale
                )
            }
            drawTextFrame(
                mutuals.label,
                at: CGPoint(x: offset.x + mutuals.labelOrigin.x, y: offset.y + mutuals.labelOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
        }
        // A person's controls: Discord's primary on the accent, its secondary
        // on the quiet plate, each lifted a step under the pointer.
        for button in slot.buttons {
            let rect = button.rect.offsetBy(dx: offset.x, dy: offset.y)
            let isHovered = button.action.isEnabled && hoveredComponent == button.rect.origin
            context.addPath(CGPath(
                roundedRect: rect, cornerWidth: Radius.row, cornerHeight: Radius.row, transform: nil
            ))
            if button.action.isCritical {
                context.setFillColor(NSColor.systemRed.withAlphaComponent(isHovered ? 0.85 : 1).cgColor)
            } else if button.action.isProminent {
                let accent = NSColor.controlAccentColor
                context.setFillColor(
                    (button.action.isEnabled ? accent.withAlphaComponent(isHovered ? 0.85 : 1) : accent.withAlphaComponent(0.5))
                        .cgColor
                )
            } else {
                context.setFillColor(ThemeInk.current.lift(isHovered ? 0.18 : 0.12))
            }
            context.fillPath()
            drawTextFrame(
                button.label,
                at: CGPoint(x: offset.x + button.labelOrigin.x, y: offset.y + button.labelOrigin.y),
                context: context,
                images: images,
                scale: scale
            )
        }
        if let button = slot.editButton {
            // The quiet plate every drawn secondary button wears, lifted a step
            // under the pointer.
            let rect = button.rect.offsetBy(dx: offset.x, dy: offset.y)
            context.addPath(CGPath(
                roundedRect: rect, cornerWidth: Radius.row, cornerHeight: Radius.row, transform: nil
            ))
            context.setFillColor(ThemeInk.current.lift(isButtonHovered ? 0.18 : 0.12))
            context.fillPath()
            drawSymbol(
                "pencil",
                tint: style.primaryColor,
                in: button.glyphRect.offsetBy(dx: offset.x, dy: offset.y),
                context: context
            )
            drawTextFrame(
                button.label,
                at: CGPoint(x: offset.x + button.labelOrigin.x, y: offset.y + button.labelOrigin.y),
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
        let tint = ThemeInk.current.lift(0.05)
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

nonisolated extension TimelineRowPainter {
    /// An action glyph at rest: white at 75 % in a dark room, black at 60 % in
    /// a light one. A painter-side static rather than `ThemeInk`, because a
    /// symbol's tint is handed to AppKit, which resolves a dynamic colour
    /// against the canvas it is drawn in.
    static let restingActionGlyph = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
            ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.60)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75)
    }
}

// MARK: - Lines shaped once

/// The one-line labels the drawn surfaces set — a name, a status line, a chip's
/// word, a time — shaped once and drawn many times.
///
/// **`drawText` shaped its string on every call**: an attributed string and a
/// `CTLine`, and a second line for the ellipsis whenever the first was cut, for
/// each label of each row of each repaint. A scroll repaints a row several
/// times as it crosses the edge, a hover repaints it twice, and a presence
/// landing repaints the roster — the same few hundred strings, shaped again
/// each time. Shaping is the expensive half of setting a line; drawing a shaped
/// one is a blit of glyphs.
///
/// - **No colour in the key, and none in the line.** The line is set with
///   `kCTForegroundColorFromContextAttributeName`, so it takes the fill colour
///   of the context it is drawn into. A name lit under the pointer, muted, or
///   in a role's colour is one entry.
/// - **Cut lines are filed by the width they were cut to**, whole points, and
///   an uncut one under no width at all, so a name that fits is one entry
///   whatever room it was offered.
/// - **Bounded by count and emptied whole.** It is a cache of what is on
///   screen now; a list scrolled through once has no claim on what it shaped.
///
/// Locked rather than confined to the main actor because the painters are
/// `nonisolated`. A `CTLine` is immutable once made.
nonisolated final class DrawnLineCache: Sendable {
    static let shared = DrawnLineCache()

    struct Shaped: @unchecked Sendable {
        var line: CTLine
        /// The drawn line's width, rounded up to a whole point.
        var width: CGFloat
        /// The uncut line's ascent, which is where its baseline goes.
        var ascent: CGFloat
    }

    private struct Key: Hashable, @unchecked Sendable {
        var string: String
        var font: NSFont
        var tracking: CGFloat
        /// The width a cut line was cut to; nil for one drawn whole.
        var fit: Int?
    }

    private struct State {
        var lines: [Key: Shaped] = [:]
        var hits = 0
        var misses = 0
    }

    private let state = Mutex(State())
    private static let limit = 4_096

    /// How often a line was found already shaped, and how often it was not:
    /// what a test reads to know the cache is used.
    var counts: (hits: Int, misses: Int) {
        state.withLock { ($0.hits, $0.misses) }
    }

    func removeAll() {
        state.withLock { $0.lines.removeAll(keepingCapacity: true) }
    }

    func line(_ string: String, font: NSFont, tracking: CGFloat, maxWidth: CGFloat) -> Shaped {
        let wholeKey = Key(string: string, font: font, tracking: tracking, fit: nil)
        let whole = cached(wholeKey) ?? {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            if tracking != 0 { attributes[.kern] = tracking }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            var ascent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, nil, nil)
            let shaped = Shaped(line: line, width: ceil(width), ascent: ascent)
            store(shaped, under: wholeKey)
            return shaped
        }()
        // Compared before rounding up, as the cut always was.
        guard CTLineGetTypographicBounds(whole.line, nil, nil, nil) > Double(maxWidth) else { return whole }

        let cutKey = Key(string: string, font: font, tracking: tracking, fit: Int(maxWidth.rounded(.down)))
        if let cut = cached(cutKey) { return cut }
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        // To the whole point the entry is filed under, so every width that
        // shares the entry draws the same line.
        let line = CTLineCreateTruncatedLine(whole.line, Double(cutKey.fit ?? 0), .end, ellipsis) ?? whole.line
        let shaped = Shaped(
            line: line,
            width: ceil(CTLineGetTypographicBounds(line, nil, nil, nil)),
            ascent: whole.ascent
        )
        store(shaped, under: cutKey)
        return shaped
    }

    private func cached(_ key: Key) -> Shaped? {
        state.withLock { state in
            guard let found = state.lines[key] else {
                state.misses += 1
                return nil
            }
            state.hits += 1
            return found
        }
    }

    private func store(_ shaped: Shaped, under key: Key) {
        state.withLock { state in
            if state.lines.count >= Self.limit { state.lines.removeAll(keepingCapacity: true) }
            state.lines[key] = shaped
        }
    }
}
