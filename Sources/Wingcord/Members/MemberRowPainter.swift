import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

/// Draws member-list rows.
///
/// **The paint order is the nameplate contract.** Every row draws its plate
/// rectangle first — artwork when there is one, a hover fill when there is not,
/// nothing when neither — and everything else draws on top of it. That order is
/// why a nameplate is a paint-time addition: the geometry already reserves the
/// layer, the text already sits above it, and the scrim that keeps the name
/// legible over arbitrary artwork is part of the same step.
nonisolated enum MemberRowPainter {

    /// A section's heading — Discord's `tX` and `tW` (`763349`): a hairline over
    /// every heading but the first, then a glyph, the name, its count and a chevron.
    ///
    /// **The role's own capitalisation, not an upper-cased copy of it.** A server
    /// names a role "Admin" or "EU Champion" and shouting it back is this client
    /// deciding it knows better — and it loses information the moment a role is
    /// deliberately lower case. Discord draws the name it was given.
    static func drawHeader(
        _ section: RosterSection,
        in rowFrame: CGRect,
        isSeparated: Bool,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        /// Which of Active Now's lobes is dim right now, or nil for none.
        dimmedLobe: Int? = nil
    ) {
        switch section.kind {
        case .standard: break
        case .continuation: return
        case .voiceGroup(let group):
            drawVoiceGroupHeader(section, group, in: rowFrame, context: context, style: style)
            return
        }
        let inset = MemberSectionGeometry.inset
        if isSeparated {
            let y = rowFrame.minY + MemberSectionGeometry.hairlineOffset
            context.setFillColor(ThemeInk.current.lift(0.1))
            context.fill(CGRect(
                x: rowFrame.minX + inset, y: y, width: max(0, rowFrame.width - inset * 2), height: 1
            ))
        }
        let eyebrow = MemberSectionGeometry.eyebrow(in: rowFrame)
        var x = rowFrame.minX + inset

        // A group the server has not named yet: a bar where the words go, as
        // Discord's list draws its unknown group.
        if section.isPlaceholder {
            let bar = CGRect(x: x, y: eyebrow.midY - 4, width: 72, height: 8)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.setFillColor(ThemeInk.current.lift(0.05))
            context.fillPath()
            return
        }

        let font = style.memberHeadingFont
        let ink = style.secondaryColor
        if section.glyph != .none {
            drawSectionGlyph(
                section.glyph,
                in: MemberSectionGeometry.glyphRect(in: rowFrame),
                dimmedLobe: dimmedLobe,
                context: context,
                style: style,
                images: images,
                scale: scale
            )
            x += MemberSectionGeometry.glyphBox + MemberSectionGeometry.gap
        }

        let chevronSide = MemberSectionGeometry.chevronSide
        let limit = rowFrame.maxX - inset
            - (section.canCollapse ? chevronSide + MemberSectionGeometry.gap : 0)
        // **The count is measured first and the name truncates against it**, so
        // "Very Long Role Na… · 12" still says how many.
        let count = section.countText.map { "\u{A0}\u{A0}·\u{A0}\u{A0}\($0)" }
        let countWidth = count.map { ceil(TimelineLayoutEngine.measure($0, font: font)) } ?? 0
        let y = TimelineRowPainter.capCenteredY(of: font, in: eyebrow)
        if let title = section.title {
            x += TimelineRowPainter.drawText(
                title,
                font: font,
                // A hoisted role's name takes the role's colour, which is how the
                // list says *why* these people are grouped.
                color: section.colorValue.map { NSColor(Color(hex: $0)) } ?? ink,
                at: CGPoint(x: x, y: y),
                maxWidth: max(0, limit - x - countWidth),
                context: context
            )
        }
        if let count {
            x += TimelineRowPainter.drawText(
                count, font: font, color: ink, at: CGPoint(x: x, y: y),
                maxWidth: countWidth + 1, context: context
            )
        }
        if section.canCollapse {
            if section.title != nil { x += MemberSectionGeometry.gap }
            // Down while open, inward while closed: the HIG's disclosure, and
            // Discord's `tY`.
            let box = CGRect(
                x: x, y: eyebrow.midY - chevronSide / 2, width: chevronSide, height: chevronSide
            )
            TimelineRowPainter.drawSymbol(
                section.isCollapsed ? "chevron.right" : "chevron.down",
                tint: ink,
                in: box.insetBy(dx: 3, dy: 3),
                context: context
            )
        }
    }

    // MARK: A room

    /// A room's name, with its green speaker in front — Discord's `tW` with a
    /// `leading` of the channel's icon and its text in `text-default`.
    private static func drawVoiceGroupHeader(
        _ section: RosterSection,
        _ group: RosterVoiceGroup,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        let eyebrow = MemberVoiceGroupGeometry.eyebrow(in: frame)
        let inset = MemberSectionGeometry.inset
        let side = MemberRowGeometry.activityGlyphSide
        TimelineRowPainter.drawSymbol(
            (group.isStage ? ActivityStatusLine.Glyph.stage : .voice).symbolName,
            tint: NSColor(Palette.presenceOnline),
            in: CGRect(x: frame.minX + inset + 2, y: eyebrow.midY - side / 2, width: side, height: side),
            context: context
        )
        let x = voiceGroupNameX(in: frame)
        let font = style.memberHeadingFont
        TimelineRowPainter.drawText(
            section.title ?? "",
            font: font,
            color: style.primaryColor,
            at: CGPoint(x: x, y: TimelineRowPainter.capCenteredY(of: font, in: eyebrow)),
            // The Join button sits at the far end when it's shown.
            maxWidth: max(0, frame.maxX - inset - x - 56),
            context: context
        )
    }

    /// Where a room's name starts, for the click that opens the room.
    static func voiceGroupNameX(in frame: CGRect) -> CGFloat {
        frame.minX + MemberSectionGeometry.inset + MemberSectionGeometry.glyphBox + MemberSectionGeometry.gap
    }

    /// Under a room's rows: a faint green wash that fades across, and a green edge
    /// on the column's side — Discord's `.groupBackgroundEffect` (`798350`). Then
    /// "2 others in voice", behind a little spine out of the rows above it.
    static func drawVoiceGroupGround(
        _ group: RosterVoiceGroup,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        let inset = MemberVoiceGroupGeometry.backgroundInset
        let band = frame.insetBy(dx: 0, dy: inset)
        let green = NSColor(Palette.presenceOnline)
        if let wash = voiceWash {
            context.saveGState()
            context.clip(to: band)
            context.drawLinearGradient(
                wash,
                start: CGPoint(x: band.minX, y: band.midY),
                end: CGPoint(x: band.maxX, y: band.midY),
                options: []
            )
            context.restoreGState()
        }
        context.setFillColor(green.withAlphaComponent(0.4).cgColor)
        context.fill(CGRect(x: band.minX, y: band.minY, width: 1, height: band.height))

        guard group.extraCount > 0 else { return }
        let extraHeight = MemberVoiceGroupGeometry.extraHeight
        let line = CGRect(
            x: frame.minX,
            y: frame.maxY - MemberVoiceGroupGeometry.padding - extraHeight,
            width: frame.width,
            height: extraHeight
        )
        // An L out of the avatars' column, `calc(var(--space-24) - 1px)` in from the
        // list's content, with `--radius-sm` on its bend.
        let spineX = frame.minX + MemberRowGeometry.horizontalMargin + 23
        let spine = CGMutablePath()
        spine.move(to: CGPoint(x: spineX, y: line.minY + 4))
        spine.addLine(to: CGPoint(x: spineX, y: line.minY + 12 - 6))
        spine.addQuadCurve(
            to: CGPoint(x: spineX + 6, y: line.minY + 12),
            control: CGPoint(x: spineX, y: line.minY + 12)
        )
        spine.addLine(to: CGPoint(x: spineX + 15, y: line.minY + 12))
        context.addPath(spine)
        context.setStrokeColor(ThemeInk.current.lift(0.25))
        context.setLineWidth(2)
        context.strokePath()

        let font = style.memberLineFont
        let words = group.extraCount == 1 ? "1 other in voice" : "\(group.extraCount.formatted()) others in voice"
        TimelineRowPainter.drawText(
            words,
            font: font,
            color: style.secondaryColor,
            at: CGPoint(
                x: spineX + 15 + MemberRowGeometry.activityGap,
                y: TimelineRowPainter.capCenteredY(of: font, in: line)
            ),
            maxWidth: frame.maxX - spineX - 15 - MemberSectionGeometry.inset,
            context: context
        )
    }

    /// `var(--custom-group-color)` at 8%, masked from opaque to clear left to right.
    private nonisolated(unsafe) static let voiceWash: CGGradient? = {
        let green = NSColor(Palette.presenceOnline).usingColorSpace(.sRGB) ?? .systemGreen
        return CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                green.withAlphaComponent(0.08).cgColor,
                green.withAlphaComponent(0).cgColor,
            ] as CFArray,
            locations: [0, 1]
        )
    }()

    /// What goes in a heading's glyph box. **A painter only ever peeks at the image
    /// caches**, so a picture nobody prefetched leaves the box empty —
    /// `MemberListCoordinator.schedulePrefetch` asks for these at the same key.
    private static func drawSectionGlyph(
        _ glyph: RosterGlyph,
        in box: CGRect,
        dimmedLobe: Int?,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        switch glyph {
        case .none:
            break
        case .activeNow:
            MemberSectionGlyphs.drawActiveNow(in: box, dimmedLobe: dimmedLobe, context: context)
        case .online:
            MemberSectionGlyphs.drawOnline(in: box, ink: style.secondaryColor, context: context)
        case .offline:
            MemberSectionGlyphs.drawOffline(in: box, context: context)
        case .image(let url):
            if let icon = images.cached(
                ImageStore.Key(url: url, maximumPixelSize: Int((box.width * scale).rounded(.up))),
                bucket: .thumbnail
            ) {
                // Fitted in its square, as the transcript's is — Discord's
                // `contain`; a wide icon stretched to the square drew thin.
                TimelineRowPainter.drawFlipped(
                    icon, in: TimelineRowPainter.fittedRect(icon, in: box, covering: false), context: context
                )
            }
        case .emoji(let emoji):
            TimelineRowPainter.drawEmojiInBox(
                EmojiRef(name: emoji),
                in: box.insetBy(dx: 1, dy: 1),
                context: context,
                color: style.secondaryColor,
                images: images,
                scale: scale
            )
        case .game(let url):
            drawArtwork(url.map { .image($0) } ?? .placeholder(.game), in: box, context: context, style: style, images: images, scale: scale)
        case .letter(let letter):
            let font = NSFontManager.shared.convert(style.memberHeadingFont, toHaveTrait: .boldFontMask)
            TimelineRowPainter.drawText(
                letter,
                font: font,
                color: style.primaryColor,
                at: CGPoint(x: box.minX, y: TimelineRowPainter.capCenteredY(of: font, in: box)),
                maxWidth: box.width,
                alignment: .center,
                context: context
            )
        }
    }

    /// A member the server has not sent yet: a face and a name, in the
    /// transcript's placeholder ink.
    ///
    /// No text, no images, no model reads — a fast scroll through a list of
    /// thousands draws a column of these until the pages land, and a costly
    /// placeholder would trade one stall for another.
    static func drawPlaceholder(index: Int, in rowFrame: CGRect, context: CGContext) {
        let tint = ThemeInk.current.lift(0.05)
        context.setFillColor(tint)
        context.fillEllipse(in: MemberRowGeometry.avatarRect(in: rowFrame))
        // Widths from the row rather than a random number: a column that
        // reshuffles on every repaint reads as flickering.
        let widths: [CGFloat] = [0.52, 0.71, 0.44, 0.63]
        let textX = MemberRowGeometry.textOriginX(in: rowFrame)
        let room = MemberRowGeometry.plateRect(in: rowFrame).maxX - MemberRowGeometry.contentInset - textX
        let bar = CGRect(
            x: textX,
            y: rowFrame.midY - 5,
            width: max(40, room * widths[index % widths.count]),
            height: 10
        )
        context.addPath(CGPath(roundedRect: bar, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.fillPath()
    }

    /// - Parameter nameFace: the styled face this person's name is set in,
    ///   already resolved. **Resolved by the caller, not looked up here** — the
    ///   registry is main-actor state and this painter is deliberately
    ///   `nonisolated` so a draw cannot reach into the model, which is the rule
    ///   `INVARIANTS.md` §4.5 is written around. Nil is the ordinary case and
    ///   means the app's own face.
    /// - Parameter plateFrame: one frame of the plate's moving form, when this
    ///   row is the one playing it. **Resolved by the caller** for the same
    ///   reason `nameFace` is: the filmstrip lives behind a main-actor clock and
    ///   this painter is deliberately `nonisolated`. Nil is every row but one,
    ///   and means the still.
    static func drawMember(
        _ entry: MemberEntry,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        isHovered: Bool,
        /// Whether the glass buttons sit on this row right now, in the picture's
        /// place — see `MemberRowActionsOverlay`. A role's popout has none.
        showsActions: Bool = false,
        images: ImageStore,
        scale: CGFloat,
        /// Read once per draw by the caller, for the times on the lines.
        now: Date = .now,
        nameFace: NSFont? = nil,
        plateFrame: CGImage? = nil,
        /// One frame of this person's moving avatar, or nil for the still —
        /// which is every row but the one under the pointer. Resolved by the
        /// caller for the same reason `plateFrame` is.
        avatarFrame: CGImage? = nil,
        /// One frame of their moving decoration, same rule.
        decorationFrame: CGImage? = nil,
        /// Where in the typing animation's cycle this row is, or nil when they
        /// are not typing — which is every row, nearly always.
        typingPhase: CGFloat? = nil,
        /// Where an enhanced role's ramp has travelled to, or nil for a name
        /// that is not animating — which is every row but the hovered one.
        gradientPhase: CGFloat? = nil
    ) {
        let plate = MemberRowGeometry.plateRect(in: rowFrame)
        let plateShape = CGPath(
            roundedRect: plate,
            cornerWidth: Radius.row,
            cornerHeight: Radius.row,
            transform: nil
        )
        let isOffline = entry.status == .offline
        let paintPlate = {
            drawPlate(
                entry,
                shape: plateShape,
                rect: plate,
                context: context,
                isHovered: isHovered,
                images: images,
                scale: scale,
                plateFrame: plateFrame
            )
        }

        // 1. The plate layer, first, unless the row is dimmed — see the end.
        if !isOffline { paintPlate() }

        // 2. Avatar and presence.
        let avatar = MemberRowGeometry.avatarRect(in: rowFrame)
        drawAvatar(
            entry,
            in: avatar,
            context: context,
            style: style,
            images: images,
            scale: scale,
            avatarFrame: avatarFrame,
            decorationFrame: decorationFrame,
            typingPhase: entry.isTyping ? typingPhase : nil
        )

        // 3. Name, tag chip, activity.
        //
        // **What's at the row's end sets how far the words may run**: the picture
        // and its gap, or under the pointer the buttons, which replace it —
        // Discord's `.container:hover .trailingAsset { display: none }`.
        let textX = MemberRowGeometry.textOriginX(in: rowFrame)
        let reserved: CGFloat = if showsActions {
            MemberRowGeometry.actionsWidth(count: entry.actionCount)
        } else if entry.art != nil {
            MemberRowGeometry.artSide + MemberRowGeometry.artGap
        } else {
            0
        }
        let available = plate.maxX - textX - MemberRowGeometry.contentInset - reserved
        let baseNameFont = nameFace ?? style.memberNameFont
        let nameHeight = ceil(baseNameFont.ascender - baseNameFont.descender)
        let lineFont = style.memberLineFont
        let lineHeight = ceil(lineFont.ascender - lineFont.descender)
        // Two lines as one block, centred on the plate; one line alone on its middle.
        let nameY = entry.line != nil
            ? (plate.midY - (nameHeight + lineHeight) / 2).rounded()
            : (plate.midY - nameHeight / 2).rounded()

        // Room for whatever chip follows the name, reserved before the name is
        // drawn so the name truncates to leave space rather than colliding.
        var chipLabel: String?
        var chipFill: NSColor?
        var chipBadge: URL?
        if let tag = entry.tag {
            chipLabel = tag
            chipBadge = entry.tagBadgeURL
        } else if entry.isBot {
            chipLabel = AppBadge.label(isVerified: entry.isVerifiedBot)
            chipFill = NSColor.controlAccentColor
        }

        var chipWidth: CGFloat = 0
        if let chipLabel {
            chipWidth = MemberRowGeometry.tagChipWidth(
                textWidth: TimelineLayoutEngine.measure(
                    chipLabel, font: MemberRowGeometry.tagChipFont
                ),
                hasBadge: chipBadge != nil
            )
        }
        let chipRoom = chipWidth > 0 ? chipWidth + MemberRowGeometry.tagChipGap : 0
        let nameWidth = max(20, available - chipRoom)

        // **The chip follows the DRAWN text, not the slot.** `drawText` returns
        // the width it actually painted; measuring the full name and clamping it
        // to the available width instead places the chip at the end of the slot,
        // which is a visible gap on every truncated name and on nothing else.
        // **The face carries into the roster; the colour does not.** Discord's
        // own dialog says colours and effects do not appear in servers, and a
        // role colour a server chose has to beat a colour its owner did — so a
        // styled name here is the same ink as any other, set in their face.
        // The effect itself plays on hover, over this row rather than in it.
        let drawnName = TimelineRowPainter.drawText(
            entry.name,
            font: baseNameFont,
            color: entry.colorValue.map { NSColor(Color(hex: $0)) }
                ?? (entry.status == .offline ? style.tertiaryColor : style.primaryColor),
            at: CGPoint(x: textX, y: nameY),
            maxWidth: nameWidth,
            tracking: (entry.displayNameFont?.letterSpacing ?? 0) * style.bodyFont.pointSize,
            // **A server's enhanced role beats the app's ink, and only here.**
            // The note above is about a person's own display-name STYLE, which
            // a server deliberately suppresses; this is the server's own choice
            // about one of its roles, so it is drawn.
            gradient: entry.gradient.map { $0.map { NSColor(Color(hex: $0)) } },
            gradientPhase: gradientPhase,
            context: context
        )

        if let chipLabel {
            // **Centred on the name's capitals, not on its line box.** A line
            // box is ascent plus descent, and a chip centred on that sits
            // visibly low beside a name that has no descenders in it — which,
            // for the majority of names, is what the eye compares it against.
            let capCenter = nameY + style.bodyFont.ascender - style.bodyFont.capHeight / 2
            drawTagChip(
                chipLabel,
                in: CGRect(
                    x: textX + drawnName + MemberRowGeometry.tagChipGap,
                    y: (capCenter - MemberRowGeometry.tagChipHeight / 2).rounded(),
                    width: chipWidth,
                    height: MemberRowGeometry.tagChipHeight
                ),
                context: context,
                style: style,
                fill: chipFill,
                badge: chipBadge,
                images: images,
                scale: scale
            )
        }

        // The owner's crown, after the name and after whatever chip follows it.
        //
        // A glyph rather than a chip: the tag and the APP mark are things a
        // person *chose*, and a crown is a fact about the conversation. Drawing
        // it as a third capsule would put it in the same category as the other
        // two.
        if entry.isOwner {
            let trailing = textX + drawnName
                + (chipWidth > 0 ? chipWidth + MemberRowGeometry.tagChipGap : 0)
            let capCenter = nameY + style.bodyFont.ascender - style.bodyFont.capHeight / 2
            let side = MemberRowGeometry.crownSide
            let crown = CGRect(
                x: trailing + MemberRowGeometry.tagChipGap,
                y: (capCenter - side / 2).rounded(),
                width: side,
                height: side
            )
            if crown.maxX <= plate.maxX - MemberRowGeometry.contentInset - reserved {
                TimelineRowPainter.drawSymbol(
                    "crown.fill",
                    tint: NSColor(Palette.presenceIdle),
                    in: crown,
                    context: context
                )
            }
        }

        if let line = entry.line {
            drawLine(
                line,
                at: CGPoint(x: textX, y: nameY + nameHeight),
                maxWidth: max(20, available),
                now: now,
                context: context,
                style: style,
                images: images,
                scale: scale
            )
        }

        // 4. The picture, unless the buttons have taken its place.
        if let art = entry.art, !showsActions {
            drawArtwork(
                art, in: MemberRowGeometry.artRect(in: rowFrame),
                context: context, style: style, images: images, scale: scale
            )
        }

        // **Offline dims what the row says, and not the plate behind it** —
        // Discord's `.content.offline { opacity: .3 }`, with the nameplate outside
        // `.content` (aad1i, Alex's screenshot 41). 45%, not its 30%: his call,
        // because that's the pale grey he's asked to be rid of.
        //
        // **Erased and then painted under**, rather than a transparency layer round
        // the row: a column of offline rows is redrawn on every scroll tick, and a
        // layer is a row-sized bitmap each. What's already there is the row's own
        // ink, so taking 55% of it away is one fill, and `destinationOver` puts the
        // plate beneath what's left. The canvas is cleared before any of this.
        if isOffline {
            context.saveGState()
            context.addPath(plateShape)
            context.clip()
            context.setFillColor(CGColor(gray: 0, alpha: 1 - MemberRowGeometry.offlineInk))
            context.setBlendMode(.destinationOut)
            context.fill(plate)
            context.restoreGState()
            context.saveGState()
            context.setBlendMode(.destinationOver)
            paintPlate()
            context.restoreGState()
        }
    }

    // MARK: The line under the name

    /// Discord's `t_` over its `tT` (`763349`): a green glyph, the words, and how
    /// long. **One run takes what's left**: the words truncate against the time,
    /// so `Escape from Ta… · 2h` under the pointer still says how long.
    private static func drawLine(
        _ line: MemberRowLine,
        at origin: CGPoint,
        maxWidth: CGFloat,
        now: Date,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        let font = style.memberLineFont
        let gap = MemberRowGeometry.activityGap
        let glyphSide = MemberRowGeometry.activityGlyphSide
        let green = NSColor(Palette.presenceOnline)
        let ink = line.isLive ? green : style.secondaryColor
        let capCenter = origin.y + font.ascender - font.capHeight / 2
        let limit = origin.x + maxWidth

        var x = origin.x
        if let glyph = line.glyph {
            TimelineRowPainter.drawSymbol(
                glyph.symbolName,
                tint: green,
                in: CGRect(x: x, y: capCenter - glyphSide / 2, width: glyphSide, height: glyphSide),
                context: context
            )
            x += glyphSide + gap
        } else if let emoji = line.emoji {
            let side = MemberRowGeometry.statusEmojiSide
            TimelineRowPainter.drawEmojiInBox(
                emoji,
                in: CGRect(x: x, y: capCenter - side / 2, width: side, height: side),
                context: context,
                color: ink,
                images: images,
                scale: scale
            )
            x += side + gap
        }

        let time = line.since.map { MemberRowLine.duration(since: $0, now: now) }
        let tail = time.map { line.joiner + $0 }
        let tailWidth = tail.map { ceil(TimelineLayoutEngine.measure($0, font: font)) } ?? 0
        if let text = line.text {
            x += TimelineRowPainter.drawText(
                text, font: font, color: ink, at: CGPoint(x: x, y: origin.y),
                maxWidth: max(0, limit - x - tailWidth), context: context
            )
        }
        if let tail {
            TimelineRowPainter.drawText(
                tail, font: font, color: ink, at: CGPoint(x: x, y: origin.y),
                maxWidth: tailWidth + 1, context: context
            )
        }
    }

    // MARK: The picture at the row's end

    /// A squircle: Discord's `tx.V`, `contain` in a 4-point corner. **Only a peek**,
    /// at the key `MemberListCoordinator.schedulePrefetch` asks for.
    private static func drawArtwork(
        _ art: MemberRowArt,
        in rect: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        let corner = MemberRowGeometry.artCorner * (rect.width / MemberRowGeometry.artSide).squareRoot()
        let shape = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        var picture: CGImage?
        var placeholder: ActivityStatusLine.Glyph = .game
        switch art {
        case .image(let url):
            picture = images.cached(
                ImageStore.Key(url: url, maximumPixelSize: Int((rect.width * scale).rounded(.up))),
                bucket: .thumbnail
            )
        case .placeholder(let glyph):
            placeholder = glyph
        }
        if let picture {
            context.saveGState()
            context.addPath(shape)
            context.clip()
            TimelineRowPainter.drawFlipped(
                picture, in: TimelineRowPainter.fittedRect(picture, in: rect, covering: false), context: context
            )
            context.restoreGState()
            return
        }
        // Not here yet, or never coming: the row keeps its shape either way.
        context.addPath(shape)
        context.setFillColor(ThemeInk.current.lift(0.08))
        context.fillPath()
        let inset = rect.width * 0.27
        TimelineRowPainter.drawSymbol(
            placeholder.symbolName,
            tint: style.tertiaryColor,
            in: rect.insetBy(dx: inset, dy: inset),
            context: context
        )
    }

    // MARK: Plate

    // **Built once, never per row.** A `CGGradient` is an allocation plus a
    // colour-space resolve, and a plate draws two of them; the scrim used to be
    // constructed inside the draw, so a roster of forty plated rows repainting
    // on every pointer move was building forty of it a frame for a value that
    // cannot change.
    //
    // The palette washes below are the reader's *content* — twelve fixed hues
    // Discord sells — so they are `nonisolated(unsafe)` statics for the same
    // reason `MemberRowGeometry.tagChipFont` is: immutable once created, never
    // written after first use, and `static let` initialisation is thread-safe.
    //
    // The **scrim** is not one of them. It is the theme's own surface colour and
    // has to be rebuilt when the theme changes, so it lives on `ThemeInk` beside
    // every other themed value a painter draws with — a static here was black,
    // which is a hole in whatever colour the reader chose.

    /// One wash per palette, keyed so a draw is a dictionary lookup.
    ///
    /// Twelve at most, and only those with a colour — `.none` is a real answer
    /// and gets no entry, so a plate that asked for no wash cannot be given one
    /// by a fallback.
    /// What erases the artwork's leading half.
    ///
    /// Opaque at the leading edge and gone by the time the strip's own pixels
    /// begin, so a name always sits on the row's background rather than on a
    /// picture. It is drawn with `destinationOut`, so only the *alpha* matters —
    /// the colour is black because a fully-opaque something is what erases, and
    /// which something is irrelevant.
    private nonisolated(unsafe) static let plateFade: CGGradient? = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 0.75),
            CGColor(gray: 0, alpha: 0),
        ] as CFArray,
        locations: [0, 0.22, 0.62]
    )

    private nonisolated(unsafe) static let plateWashes: [NameplatePalette: CGGradient] = {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var table: [NameplatePalette: CGGradient] = [:]
        table.reserveCapacity(NameplatePalette.allCases.count)
        for palette in NameplatePalette.allCases {
            guard let value = palette.colorValue else { continue }
            // Built as `CGColor` components rather than through
            // `NSColor(Color(hex:))`: that bridge can hand back a catalog
            // colour, and `withAlphaComponent` on one of those is not the
            // straightforward operation it looks like.
            let red = CGFloat((value >> 16) & 0xFF) / 255
            let green = CGFloat((value >> 8) & 0xFF) / 255
            let blue = CGFloat(value & 0xFF) / 255
            func tint(_ alpha: CGFloat) -> CGColor {
                CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
            }
            guard let gradient = CGGradient(
                colorsSpace: space,
                // Clear at the leading edge, where the name is, and strongest
                // under the artwork. Kept in the same register as
                // `Palette.hoverFill` and `Palette.selectionFill` — a hue at
                // low alpha over near-black reads far weaker than white does,
                // which is why the far end is above the selection pill's 0.15
                // and still reads as a wash rather than as paint.
                colors: [tint(0), tint(0.08), tint(0.24)] as CFArray,
                locations: [0, 0.5, 1]
            ) else { continue }
            table[palette] = gradient
        }
        return table
    }()

    private static func drawPlate(
        _ entry: MemberEntry,
        shape: CGPath,
        rect: CGRect,
        context: CGContext,
        isHovered: Bool,
        images: ImageStore,
        scale: CGFloat,
        plateFrame: CGImage?
    ) {
        // **The moving frame stands in for the still, in the same rectangle.**
        // Everything below — the wash, the erasing fade, the clip — is one
        // treatment applied to whichever picture the row has, so a plate cannot
        // look like two different objects depending on whether it is moving.
        //
        // `??` rather than a resolved pair, so the row that IS moving never
        // pays for the cache lookup it is not going to use.
        let image = plateFrame ?? entry.nameplateURL.flatMap { url in
            images.cached(
                ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int(
                        (MemberRowGeometry.nameplateArtWidth * scale).rounded(.up)
                    )
                ),
                bucket: .artwork
            )
        }
        if let image {
            // One clip for all three layers. The plate used to save, clip, draw
            // and restore twice over, which is four state operations a row for
            // the same region.
            context.saveGState()
            context.addPath(shape)
            context.clip()

            // 1. The palette's wash, underneath everything.
            //
            // **A nameplate's artwork only covers its trailing third.**
            // Measured on the real asset: Dark Roses is a 672x126 strip whose
            // left two thirds are fully transparent. Drawn alone, that reads as
            // a picture floating beside somebody's name rather than as a plate
            // behind it, and the wash is what closes the gap between the
            // scrim's fade-out and the artwork's first pixels.
            if let wash = plateWashes[entry.nameplatePalette] {
                context.drawLinearGradient(
                    wash,
                    start: CGPoint(x: rect.minX, y: rect.midY),
                    end: CGPoint(x: rect.maxX, y: rect.midY),
                    options: []
                )
            }

            // 2. The artwork, FADED OUT toward the leading edge.
            //
            // **The fade erases the picture; it does not paint over it.** This
            // used to be a scrim — a wash laid on top, opaque under the name and
            // clear over the roses — and a scrim is a *colour*, so it can only
            // ever be the right one by accident. Black left a hole in whatever
            // theme the reader chose; the theme's own surface left a lighter
            // rectangle, because the roster's ground is the canvas under a
            // recess and not the surface. Either way the plate read as a box
            // sitting on the list rather than as artwork emerging out of it.
            //
            // Erasing has no colour to be wrong about. The strip is drawn into a
            // transparency layer and a `destinationOut` ramp takes its leading
            // half away, so what shows through is exactly the row's own
            // background — whatever that happens to be — and the picture fades
            // into it instead of stopping against a plate.
            //
            // Fit to the plate's HEIGHT and hung off its trailing edge — see
            // `MemberRowGeometry.nameplateArtRect`, which carries the
            // measurement that settled the rule. **Not aspect-fill**: fill takes
            // whichever of the two fits is larger, which lands on the width for
            // a wide plate and stretches the strip vertically.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            TimelineRowPainter.drawFlipped(
                image,
                in: MemberRowGeometry.nameplateArtRect(
                    in: rect,
                    imagePixelSize: CGSize(width: image.width, height: image.height)
                ),
                context: context
            )
            if let fade = plateFade {
                context.setBlendMode(.destinationOut)
                context.drawLinearGradient(
                    fade,
                    start: CGPoint(x: rect.minX, y: rect.midY),
                    end: CGPoint(x: rect.maxX, y: rect.midY),
                    options: []
                )
                context.setBlendMode(.normal)
            }
            context.endTransparencyLayer()

            if isHovered {
                context.setFillColor(ThemeInk.current.lift(0.06))
                context.fill(rect)
            }
            context.restoreGState()
            return
        }

        guard isHovered else { return }
        context.addPath(shape)
        context.setFillColor(ThemeInk.current.hoverFill)
        context.fillPath()
    }

    // MARK: Avatar

    /// The face, its decoration and its presence dot.
    ///
    /// **Three layers in one order, and the order is the whole of it**: the
    /// face is clipped to its circle, the decoration draws *outside* that clip
    /// — see `TimelineRowPainter.decorationRect` — and the dot goes over both.
    /// Drawing the decoration inside the clip loses the ears, the halo and the
    /// hat brim, which is to say everything that makes one recognisable.
    private static func drawAvatar(
        _ entry: MemberEntry,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        avatarFrame: CGImage? = nil,
        decorationFrame: CGImage? = nil,
        typingPhase: CGFloat? = nil
    ) {
        // **A real hole for whatever sits in the corner**, as Discord's mask cuts
        // one. This used to be a ring of the window's colour laid over the face,
        // which is a dark ring on any theme or picture that isn't that colour, and
        // a dark ring across a hovered row's plate.
        let hole = cornerHole(of: entry, typingPhase: typingPhase, on: frame)
        func clipToHole() {
            guard let hole else { return }
            context.addRect(frame.insetBy(dx: -frame.width, dy: -frame.height))
            context.addPath(hole)
            context.clip(using: .evenOdd)
        }

        context.saveGState()
        clipToHole()
        context.addEllipse(in: frame)
        context.clip()
        // The moving face where this is the row playing one, the decoded still
        // everywhere else. Both are drawn through the same flip.
        if let image = avatarFrame ?? entry.avatarURL.flatMap({ url in
            images.cached(ImageStore.Key(
                url: url,
                maximumPixelSize: Int((frame.width * scale).rounded(.up))
            ))
        }) {
            TimelineRowPainter.drawFlipped(image, in: frame, context: context)
            context.restoreGState()
        } else {
            context.setFillColor(ThemeInk.current.surfaceRaised)
            context.fill(frame)
            context.restoreGState()
            context.saveGState()
            clipToHole()
            let font = NSFont.systemFont(ofSize: frame.width * 0.42, weight: .semibold)
            TimelineRowPainter.drawText(
                entry.monogram,
                font: font,
                color: style.secondaryColor,
                at: CGPoint(
                    x: frame.minX,
                    y: TimelineRowPainter.capCenteredY(of: font, in: frame)
                ),
                maxWidth: frame.width,
                alignment: .center,
                context: context
            )
            context.restoreGState()
        }

        // **After the clip is gone.** A decoration is drawn around the face at
        // 1.2x, so it is the one thing on this row that must not be inside the
        // ellipse above — and it is drawn before the dot, which Discord puts
        // over everything.
        context.saveGState()
        clipToHole()
        TimelineRowPainter.drawDecoration(
            decorationFrame ?? decorationStill(entry, around: frame, images: images, scale: scale),
            around: frame,
            context: context
        )
        context.restoreGState()

        // **The typing pill REPLACES the presence dot.** Discord swaps the two
        // rather than stacking them, and it has to: they share the same corner,
        // and a pill drawn over a dot is a dot poking out of its end.
        if let typingPhase {
            drawTypingPill(
                on: frame,
                tint: NSColor(entry.status.tint).cgColor,
                phase: typingPhase,
                context: context
            )
        } else if hole != nil {
            if let client = deviceMark(of: entry),
               let mark = PresenceMarkArt.path(for: client, in: markRect(for: client, on: frame)) {
                context.addPath(mark)
                context.setFillColor(NSColor(entry.status.tint).cgColor)
                context.fillPath(using: .evenOdd)
            } else {
                drawPresenceDot(entry.status, on: frame, context: context)
            }
        }
    }

    /// What's in the avatar's corner, and the hole it needs — nil for nothing.
    ///
    /// **No dot for offline or unknown, as Discord's member list has none** (`eo`
    /// passes no status for OFFLINE, and the avatar draws none for UNKNOWN): an
    /// offline row says so by being dimmed, and an app that never connects says
    /// nothing at all.
    private static func cornerHole(
        of entry: MemberEntry,
        typingPhase: CGFloat?,
        on frame: CGRect
    ) -> CGPath? {
        if typingPhase != nil {
            let ring = typingPillRect(on: frame).insetBy(dx: -statusCut, dy: -statusCut)
            return CGPath(roundedRect: ring, cornerWidth: ring.height / 2, cornerHeight: ring.height / 2, transform: nil)
        }
        guard entry.status != .offline, entry.status != .unknown else { return nil }
        // A phone or a headset cuts its own shape, as Discord's mask does.
        if let client = deviceMark(of: entry) {
            return PresenceMarkArt.silhouette(
                for: client, in: markRect(for: client, on: frame), gap: statusCut
            )
        }
        return CGPath(ellipseIn: dotRect(on: frame).insetBy(dx: -statusCut, dy: -statusCut), transform: nil)
    }

    /// The phone or the headset, for somebody online on one — Discord's two
    /// online masks. Every other status is the same mark wherever it is set.
    private static func deviceMark(of entry: MemberEntry) -> PresenceClient? {
        entry.status == .online && entry.client != .desktop ? entry.client : nil
    }

    /// Where a device mark sits: the dot's own corner, grown up for a phone and
    /// to the leading side for a headset, so the foot and the trailing edge
    /// stay where the dot's were.
    private static func markRect(for client: PresenceClient, on avatarFrame: CGRect) -> CGRect {
        let dot = dotRect(on: avatarFrame)
        let size = PresenceMarkArt.size(for: client, side: dotSide)
        return CGRect(
            x: dot.maxX - size.width, y: dot.maxY - size.height,
            width: size.width, height: size.height
        )
    }

    /// How much air there is between a status and the face it's on.
    private static let statusCut: CGFloat = 2.5
    /// A status dot on a 32-point face, as it measures on Alex's screenshot 43.
    private static let dotSide: CGFloat = 11

    private static func dotRect(on avatarFrame: CGRect) -> CGRect {
        CGRect(
            x: avatarFrame.maxX - dotSide + 2,
            y: avatarFrame.maxY - dotSide + 2,
            width: dotSide,
            height: dotSide
        )
    }

    private static func typingPillRect(on avatarFrame: CGRect) -> CGRect {
        let height: CGFloat = 11
        let width: CGFloat = 20
        return CGRect(
            x: avatarFrame.maxX - width + 2,
            y: avatarFrame.maxY - height + 2,
            width: width,
            height: height
        )
    }

    /// Three dots in a pill, where the presence dot would be.
    ///
    /// **The dots rise and fall in sequence** — a third of a cycle apart, which
    /// is the stagger every typing indicator uses and the one that reads as
    /// "someone is mid-sentence" rather than as a loading spinner. The phase is
    /// resolved by the caller from the shared clock, for the same reason
    /// `plateFrame` and `gradientPhase` are: this painter is `nonisolated` and
    /// may not reach a main-actor singleton from inside a draw.
    ///
    /// **In the presence colour it replaces**, as Discord paints it — green for
    /// somebody online — so the corner still says who is there.
    private static func drawTypingPill(
        on avatarFrame: CGRect,
        tint: CGColor,
        phase: CGFloat,
        context: CGContext
    ) {
        let pill = typingPillRect(on: avatarFrame)

        context.setFillColor(tint)
        context.addPath(CGPath(
            roundedRect: pill,
            cornerWidth: pill.height / 2,
            cornerHeight: pill.height / 2,
            transform: nil
        ))
        context.fillPath()

        let dotSide: CGFloat = 3
        let gap: CGFloat = 1.5
        let run = dotSide * 3 + gap * 2
        var x = pill.midX - run / 2
        for index in 0..<3 {
            // A third of a cycle apart, and the rise is a raised cosine so the
            // dot eases at both ends instead of ticking between two positions.
            let local = (phase + CGFloat(index) / 3).truncatingRemainder(dividingBy: 1)
            let lift = (1 - cos(local * 2 * .pi)) / 2
            let box = CGRect(
                x: x,
                y: pill.midY - dotSide / 2 - lift * 1.5,
                width: dotSide,
                height: dotSide
            )
            context.setFillColor(NSColor.white.withAlphaComponent(0.55 + lift * 0.45).cgColor)
            context.fillEllipse(in: box)
            x += dotSide + gap
        }
    }

    /// The decoration's first frame, once anything has decoded it.
    ///
    /// **Only a peek.** A painter may not start a fetch — it runs inside a draw
    /// and a roster is repainted on every scroll tick — so an asset nobody
    /// prefetches is an asset that never arrives, which is the trap
    /// `INVARIANTS.md` §2 names and exactly what kept every decoration in this
    /// list invisible: `MemberEntry.decorationURL` has been decoded all along
    /// and no surface asked for the bytes. The key must equal the prefetcher's,
    /// or the picture lands in a slot this never looks in.
    private static func decorationStill(
        _ entry: MemberEntry,
        around frame: CGRect,
        images: ImageStore,
        scale: CGFloat
    ) -> CGImage? {
        guard let url = entry.decorationURL else { return nil }
        let side = TimelineRowPainter.decorationRect(around: frame).width
        return images.cached(
            ImageStore.Key(url: url, maximumPixelSize: Int((side * scale).rounded(.up))),
            bucket: .thumbnail
        )
    }

    /// The presence dot.
    ///
    /// Each state has a *shape* as well as a colour — a filled disc, a crescent,
    /// a bar, a ring. Hue alone is the first thing a colour-blind reader loses,
    /// and online-versus-idle differ by nothing else.
    private static func drawPresenceDot(
        _ status: PresenceStatus,
        on avatarFrame: CGRect,
        context: CGContext
    ) {
        guard status != .unknown else { return }
        let dot = dotRect(on: avatarFrame)
        let tint = NSColor(status.tint).cgColor
        switch status {
        case .online:
            context.setFillColor(tint)
            context.fillEllipse(in: dot)
        case .idle:
            // A crescent and a bar are holes too, not patches of the window's
            // colour: a plate or a hover shows through them.
            context.saveGState()
            context.addEllipse(in: dot)
            context.clip()
            context.addRect(dot)
            context.addEllipse(in: dot.offsetBy(dx: -2.5, dy: -2.5).insetBy(dx: 1.6, dy: 1.6))
            context.setFillColor(tint)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        case .doNotDisturb:
            context.addEllipse(in: dot)
            context.addPath(CGPath(
                roundedRect: CGRect(x: dot.minX + 2, y: dot.midY - 1.1, width: dot.width - 4, height: 2.2),
                cornerWidth: 1.1, cornerHeight: 1.1, transform: nil
            ))
            context.setFillColor(tint)
            context.fillPath(using: .evenOdd)
        case .offline, .invisible:
            context.setStrokeColor(tint)
            context.setLineWidth(2.6)
            context.strokeEllipse(in: dot.insetBy(dx: 1.3, dy: 1.3))
        case .unknown:
            break
        }
    }

    /// A clan tag or an APP badge.
    ///
    /// A clan tag carries the guild's **badge image** beside its letters — that
    /// is what a tag IS on Discord, and drawing only the letters loses the half
    /// people recognise. The badge comes out of the same cache as every other
    /// picture, at the same key `MemberListView` prefetches it under; a key that
    /// disagrees by one pixel is a badge that is fetched and then never found.
    ///
    /// The frame arrives already sized by `MemberRowGeometry.tagChipWidth`, so
    /// the padding here and the width reserved for the chip cannot disagree —
    /// and the contents are laid out from the leading padding rightwards, which
    /// leaves the trailing padding equal to it by construction.
    private static func drawTagChip(
        _ label: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        fill: NSColor? = nil,
        badge: URL? = nil,
        images: ImageStore? = nil,
        scale: CGFloat = 2
    ) {
        let corner = MemberRowGeometry.tagChipHeight / 2
        context.addPath(CGPath(
            roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil
        ))
        context.setFillColor(fill?.cgColor ?? ThemeInk.current.lift(0.12))
        context.fillPath()

        var textX = frame.minX + MemberRowGeometry.tagChipPadding
        if let badge, let images {
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
                context.saveGState()
                context.translateBy(x: 0, y: glyph.midY)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -glyph.midY)
                context.draw(image, in: glyph)
                context.restoreGState()
            }
            textX = glyph.maxX + MemberRowGeometry.tagBadgeGap
        }

        let font = MemberRowGeometry.tagChipFont
        TimelineRowPainter.drawText(
            label,
            font: font,
            color: fill == nil ? style.secondaryColor : .white,
            at: CGPoint(x: textX, y: TimelineRowPainter.capCenteredY(of: font, in: frame)),
            maxWidth: frame.maxX - MemberRowGeometry.tagChipPadding - textX,
            context: context
        )
    }
}
