import AppKit
import CoreGraphics
import WingcordCore

nonisolated extension TimelineRowPainter {

    /// Discord's green and its hover (`--control-connected-background-*`,
    /// 2026-11-16) — the invite card's Join, and the event card's
    /// (`EmbedButtonStyle`) — the same in every theme, `DiscordCardInk`'s rule.
    static let joinFill = CGColor(srgbRed: 0x00 / 255, green: 0x85 / 255, blue: 0x45 / 255, alpha: 1)
    static let joinFillHovered = CGColor(
        srgbRed: 0x00 / 255, green: 0x6B / 255, blue: 0x38 / 255, alpha: 1
    )
    /// `--text-status-online` and `--text-status-offline`.
    private static let onlineDot = CGColor(srgbRed: 0x23 / 255, green: 0xA5 / 255, blue: 0x59 / 255, alpha: 1)

    /// An invite card.
    ///
    /// - Parameters:
    ///   - isSettled: the reader is already where the invite leads — in the
    ///     server, in the group, friends with the person. Decided at paint time,
    ///     so joining is a repaint.
    ///   - hovered: the origin of the control under the pointer, in row space.
    static func drawInviteCard(
        _ slot: InviteCardSlot,
        offset: CGPoint,
        context: CGContext,
        isSettled: Bool,
        hovered: CGPoint?,
        images: ImageStore,
        scale: CGFloat,
        style: MessageTextStyle
    ) {
        let ink = ThemeInk.current
        // A voice card's plate stops above the line that sits under it.
        let frame: CGRect = switch slot.body {
        case .voice(let voice): voice.plateRect.offsetBy(dx: offset.x, dy: offset.y)
        case .voiceRow(let row): row.plateRect.offsetBy(dx: offset.x, dy: offset.y)
        default: slot.rect.offsetBy(dx: offset.x, dy: offset.y)
        }
        let corner: CGFloat = if case .profile = slot.body {
            InviteCardLayoutEngine.profileCorner
        } else {
            EmbedLayoutEngine.corner
        }
        let outline = CGPath(roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil)
        context.addPath(outline)
        context.setFillColor(ink.discordCard)
        context.fillPath()

        switch slot.body {
        case .classic(let classic):
            drawClassic(classic, offset: offset, context: context, images: images, scale: scale)
        case .voice(let voice):
            drawVoice(voice, offset: offset, context: context, ink: ink, hovered: hovered,
                      images: images, scale: scale, style: style)
        case .voiceRow(let row):
            drawVoiceRow(row, offset: offset, context: context, ink: ink, hovered: hovered,
                         images: images, scale: scale, style: style)
        case .profile(let profile):
            // Everything the card holds is cut to its outline — the banner's
            // corners, and the content a folded card hides under its fade.
            context.saveGState()
            context.addPath(outline)
            context.clip()
            let fold: CGRect? = if case .collapsed(let fade) = slot.fold {
                fade.offsetBy(dx: offset.x, dy: offset.y)
            } else {
                nil
            }
            // **A folded card's content is faded OUT, not painted over.** The
            // fade used to run to the card's own fill — which is translucent,
            // so a trait chip and "Invited by" ghosted through under the button
            // (Alex's images 42–43). In a layer of its own, the content is
            // erased along the fade and gone below it, and what shows instead
            // is whatever the card is drawn on: §4.5's rule for hiding part of
            // a picture.
            if fold != nil { context.beginTransparencyLayer(auxiliaryInfo: nil) }
            drawProfile(profile, offset: offset, context: context, ink: ink, hovered: hovered, images: images, scale: scale)
            if let mark = slot.mark {
                GuildMarkArt.draw(
                    mark, in: slot.markRect.offsetBy(dx: offset.x, dy: offset.y),
                    context: context, isLight: ink.isLight
                )
            }
            if let fold {
                eraseBelow(fold, to: frame.maxY, context: context)
                context.endTransparencyLayer()
            }
            context.restoreGState()
            // Discord's hairline around the profile card (`--border-subtle`).
            context.addPath(CGPath(
                roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: corner, cornerHeight: corner, transform: nil
            ))
            context.setStrokeColor(ink.hoverFill)
            context.setLineWidth(1)
            context.strokePath()
        }

        if case .expanded(let hide, let label, let labelOrigin) = slot.fold {
            let rect = hide.offsetBy(dx: offset.x, dy: offset.y)
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: InviteCardLayoutEngine.buttonCorner,
                cornerHeight: InviteCardLayoutEngine.buttonCorner,
                transform: nil
            ))
            context.setFillColor(hovered == hide.origin ? ink.discord.secondaryHover : ink.discord.secondaryFill)
            context.fillPath()
            drawTextFrame(label, at: shifted(labelOrigin, offset), context: context, images: images, scale: scale)
        }

        guard let button = slot.button else { return }
        let face = isSettled ? button.settled : button.pending
        let rect = button.rect.offsetBy(dx: offset.x, dy: offset.y)
        let isHovered = button.isEnabled && hovered == button.rect.origin
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: InviteCardLayoutEngine.buttonCorner,
            cornerHeight: InviteCardLayoutEngine.buttonCorner,
            transform: nil
        ))
        context.setFillColor(
            face.isProminent
                ? (isHovered ? joinFillHovered : joinFill)
                : (isHovered ? ink.discord.secondaryHover : ink.discord.secondaryFill)
        )
        context.fillPath()
        // A disabled face is drawn at half, which is what Discord's disabled
        // button is.
        if !button.isEnabled { context.setAlpha(0.5) }
        drawTextFrame(face.label, at: shifted(face.labelOrigin, offset), context: context, images: images, scale: scale)
        if !button.isEnabled { context.setAlpha(1) }
        // The channel-row card's Join Voice carries the speaker, as Discord's does.
        if case .voiceRow(let row) = slot.body, !isSettled {
            drawSymbol("speaker.wave.2.fill", tint: .white,
                       in: row.buttonSpeakerRect.offsetBy(dx: offset.x, dy: offset.y), context: context)
        }
    }

    // MARK: The voice card

    private static func drawVoice(
        _ voice: InviteCardSlot.Voice,
        offset: CGPoint,
        context: CGContext,
        ink: ThemeInk,
        hovered: CGPoint?,
        images: ImageStore,
        scale: CGFloat,
        style: MessageTextStyle
    ) {
        // The way to the channel: brighter under the pointer, as a link is.
        let crumbTint = hovered == voice.breadcrumbRect.origin ? style.primaryColor : style.secondaryColor
        drawSymbol("speaker.wave.2.fill", tint: crumbTint,
                   in: voice.speakerRect.offsetBy(dx: offset.x, dy: offset.y), context: context)
        drawTextFrame(voice.breadcrumb, at: shifted(voice.breadcrumbOrigin, offset), context: context,
                      images: images, scale: scale)
        drawSymbol("chevron.right", tint: crumbTint,
                   in: voice.chevronRect.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: 2, dy: 2), context: context)
        drawTextFrame(voice.label, at: shifted(voice.labelOrigin, offset), context: context, images: images, scale: scale)
        if let sublabel = voice.sublabel {
            drawTextFrame(sublabel, at: shifted(voice.sublabelOrigin, offset), context: context, images: images, scale: scale)
        }

        // Last first, so each face lies over the smaller one after it, ringed
        // in the card's own fill where they overlap.
        for face in voice.faces.reversed() {
            let rect = face.rect.offsetBy(dx: offset.x, dy: offset.y)
            context.addEllipse(in: rect.insetBy(dx: -2, dy: -2))
            context.setFillColor(ink.discordCard)
            context.fillPath()
            if let url = face.avatarURL,
               let image = images.cached(InviteCardSlot.imageKey(url, in: face.rect, scale: scale)) {
                context.saveGState()
                context.addEllipse(in: rect)
                context.clip()
                drawFlipped(image, in: rect, context: context)
                context.restoreGState()
            } else {
                context.addEllipse(in: rect)
                context.setFillColor(ink.discord.secondaryFill)
                context.fillPath()
                drawTextFrame(face.monogram, at: shifted(face.monogramOrigin, offset), context: context,
                              images: images, scale: scale)
            }
        }
        if let overflow = voice.overflow {
            let rect = overflow.rect.offsetBy(dx: offset.x, dy: offset.y)
            context.addEllipse(in: rect.insetBy(dx: -2, dy: -2))
            context.setFillColor(ink.discordCard)
            context.fillPath()
            context.addEllipse(in: rect)
            context.setFillColor(ink.discord.secondaryHover)
            context.fillPath()
            drawTextFrame(overflow.label, at: shifted(overflow.labelOrigin, offset), context: context,
                          images: images, scale: scale)
        }

        drawSymbol("eye.slash", tint: style.secondaryColor,
                   in: voice.footerSymbolRect.offsetBy(dx: offset.x, dy: offset.y), context: context)
        drawTextFrame(voice.footer, at: shifted(voice.footerOrigin, offset), context: context, images: images, scale: scale)
    }

    private static func drawVoiceRow(
        _ row: InviteCardSlot.VoiceRow,
        offset: CGPoint,
        context: CGContext,
        ink: ThemeInk,
        hovered: CGPoint?,
        images: ImageStore,
        scale: CGFloat,
        style: MessageTextStyle
    ) {
        // Discord's `TEXT_FEEDBACK_POSITIVE` while somebody is inside.
        let green = NSColor(srgbRed: 0x23 / 255, green: 0xA5 / 255, blue: 0x59 / 255, alpha: 1)
        drawSymbol("speaker.wave.2.fill", tint: row.isOccupied ? green : style.secondaryColor,
                   in: row.speakerRect.offsetBy(dx: offset.x, dy: offset.y), context: context)
        drawTextFrame(row.header, at: shifted(row.headerOrigin, offset), context: context, images: images, scale: scale)
        if hovered == row.headerRect.origin {
            // Under the pointer, the channel's name is underlined, as a link is.
            let line = CGRect(
                x: row.headerOrigin.x + offset.x, y: row.headerOrigin.y + offset.y + row.header.size.height - 1,
                width: row.header.size.width, height: 1
            )
            context.setFillColor(style.primaryColor.cgColor)
            context.fill(line)
        }
        for person in row.people {
            let rect = person.avatarRect.offsetBy(dx: offset.x, dy: offset.y)
            if let url = person.avatarURL,
               let image = images.cached(InviteCardSlot.imageKey(url, in: person.avatarRect, scale: scale)) {
                context.saveGState()
                context.addEllipse(in: rect)
                context.clip()
                drawFlipped(image, in: rect, context: context)
                context.restoreGState()
            } else {
                context.addEllipse(in: rect)
                context.setFillColor(ink.discord.secondaryFill)
                context.fillPath()
                drawTextFrame(person.monogram, at: shifted(person.monogramOrigin, offset), context: context,
                              images: images, scale: scale)
            }
            drawTextFrame(person.name, at: shifted(person.nameOrigin, offset), context: context, images: images, scale: scale)
            if let liveRect = person.liveRect, let live = person.live {
                let badge = liveRect.offsetBy(dx: offset.x, dy: offset.y)
                context.addPath(CGPath(roundedRect: badge, cornerWidth: 4, cornerHeight: 4, transform: nil))
                context.setFillColor(CGColor(srgbRed: 0xDA / 255, green: 0x37 / 255, blue: 0x3C / 255, alpha: 1))
                context.fillPath()
                drawTextFrame(live, at: shifted(person.liveOrigin, offset), context: context, images: images, scale: scale)
            }
        }
        if let note = row.note {
            drawTextFrame(note, at: shifted(row.noteOrigin, offset), context: context, images: images, scale: scale)
        }
        drawSymbol("eye.slash", tint: style.secondaryColor,
                   in: row.footerSymbolRect.offsetBy(dx: offset.x, dy: offset.y), context: context)
        drawTextFrame(row.footer, at: shifted(row.footerOrigin, offset), context: context, images: images, scale: scale)
    }

    // MARK: The profile card

    private static func drawProfile(
        _ profile: InviteCardSlot.Profile,
        offset: CGPoint,
        context: CGContext,
        ink: ThemeInk,
        hovered: CGPoint?,
        images: ImageStore,
        scale: CGFloat
    ) {
        let banner = profile.bannerRect.offsetBy(dx: offset.x, dy: offset.y)
        if let url = profile.bannerURL,
           let image = images.cached(InviteCardSlot.imageKey(url, in: profile.bannerRect, scale: scale),
                                     bucket: .thumbnail)
        {
            drawCovering(image, in: banner, context: context)
        } else {
            GuildBannerArt.drawGlow(
                profile.bannerColor ?? GuildBannerArt.defaultColour(isLight: ink.isLight),
                in: banner, context: context
            )
        }

        // The icon's plate is the card's own ground, so the icon reads as cut
        // out of the banner rather than stuck on it.
        let frame = profile.iconFrame.offsetBy(dx: offset.x, dy: offset.y)
        context.addPath(iconShape(frame))
        context.setFillColor(ink.discordCard)
        context.fillPath()

        let iconRect = profile.iconRect.offsetBy(dx: offset.x, dy: offset.y)
        context.saveGState()
        context.addPath(iconShape(iconRect))
        context.clip()
        if let url = profile.iconURL,
           let image = images.cached(InviteCardSlot.imageKey(url, in: profile.iconRect, scale: scale),
                                     bucket: .thumbnail)
        {
            drawFlipped(image, in: iconRect, context: context)
        } else {
            context.setFillColor(ink.discord.secondaryFill)
            context.fill(iconRect)
            drawTextFrame(profile.monogram, at: shifted(profile.monogramOrigin, offset), context: context,
                          images: images, scale: scale)
        }
        context.restoreGState()

        drawTextFrame(profile.title, at: shifted(profile.titleOrigin, offset), context: context,
                      images: images, scale: scale)
        for count in profile.counts {
            context.setFillColor(count.isOnline ? onlineDot : ink.lift(0.4))
            context.fillEllipse(in: count.dot.offsetBy(dx: offset.x, dy: offset.y))
            drawTextFrame(count.label, at: shifted(count.labelOrigin, offset), context: context,
                          images: images, scale: scale)
        }
        drawTextFrame(profile.established, at: shifted(profile.establishedOrigin, offset), context: context,
                      images: images, scale: scale)
        if let description = profile.description {
            drawTextFrame(description, at: shifted(profile.descriptionOrigin, offset), context: context,
                          images: images, scale: scale)
        }

        for trait in profile.traits {
            let chip = trait.rect.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: 0.5, dy: 0.5)
            context.addPath(CGPath(
                roundedRect: chip, cornerWidth: chip.height / 2, cornerHeight: chip.height / 2, transform: nil
            ))
            // `--border-subtle`, and the "+ N more" chip's `:hover` border —
            // `--border-strong`, for which the selection's ink is the nearest
            // this palette has — while the pointer is on it.
            let isLit = hovered == trait.rect.origin && profile.moreTraits?.rect.origin == trait.rect.origin
            context.setStrokeColor(isLit ? ink.selectionFill : ink.hoverFill)
            context.setLineWidth(1)
            context.strokePath()
            if let glyph = trait.glyph {
                drawTextFrame(glyph, at: shifted(trait.glyphOrigin, offset), context: context,
                              images: images, scale: scale)
            } else if let url = trait.emojiURL,
                      let image = images.cached(InviteCardSlot.imageKey(url, in: trait.emojiRect, scale: scale),
                                                bucket: .thumbnail)
            {
                drawFlipped(
                    image,
                    in: trait.emojiRect.offsetBy(dx: offset.x, dy: offset.y),
                    context: context,
                    fit: .contain
                )
            }
            drawTextFrame(trait.label, at: shifted(trait.labelOrigin, offset), context: context,
                          images: images, scale: scale)
        }

        if let inviter = profile.inviter {
            drawInviter(inviter, offset: offset, context: context, images: images, scale: scale)
        }
    }

    /// The fade a folded card's button floats over — Discord's
    /// `linear-gradient(180deg, transparent, var(--background-surface-high))`
    /// as an erasure: the content goes from whole at the top of `rect` to gone
    /// at its foot, and stays gone down to `bottom`.
    private static func eraseBelow(_ rect: CGRect, to bottom: CGFloat, context: CGContext) {
        let space = CGColorSpaceCreateDeviceGray()
        guard let gradient = CGGradient(
            colorsSpace: space,
            colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray,
            locations: [0, 1]
        ) else { return }
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                                height: max(rect.height, bottom - rect.minY)))
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private static func iconShape(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: rect.width * 0.3, cornerHeight: rect.height * 0.3, transform: nil)
    }

    // MARK: The classic card

    private static func drawClassic(
        _ classic: InviteCardSlot.Classic,
        offset: CGPoint,
        context: CGContext,
        images: ImageStore,
        scale: CGFloat
    ) {
        let ink = ThemeInk.current
        drawTextFrame(classic.header, at: shifted(classic.headerOrigin, offset), context: context,
                      images: images, scale: scale)

        if let url = classic.splashURL,
           let image = images.cached(InviteCardSlot.imageKey(url, in: classic.splashRect, scale: scale),
                                     bucket: .thumbnail)
        {
            let rect = classic.splashRect.offsetBy(dx: offset.x, dy: offset.y)
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.clip()
            drawCovering(image, in: rect, context: context)
            context.restoreGState()
        }

        let iconRect = classic.iconRect.offsetBy(dx: offset.x, dy: offset.y)
        if classic.isExpired {
            drawExpiredIcon(in: iconRect, context: context)
        } else {
            drawClassicIcon(classic, in: iconRect, offset: offset, context: context, ink: ink,
                            images: images, scale: scale)
        }

        drawTextFrame(classic.title, at: shifted(classic.titleOrigin, offset), context: context,
                      images: images, scale: scale)
        if let detail = classic.detail {
            drawTextFrame(detail, at: shifted(classic.detailOrigin, offset), context: context,
                          images: images, scale: scale)
        }
        if let dot = classic.onlineDot {
            context.setFillColor(onlineDot)
            context.fillEllipse(in: dot.offsetBy(dx: offset.x, dy: offset.y))
        }
        if let dot = classic.membersDot {
            context.setFillColor(ink.lift(0.4))
            context.fillEllipse(in: dot.offsetBy(dx: offset.x, dy: offset.y))
        }
        if let inviter = classic.inviter {
            drawInviter(inviter, offset: offset, context: context, images: images, scale: scale)
        }
    }

    /// An invite that is gone: Discord's `guildIconExpired` — a tile of its
    /// critical red at twelve per cent with a hairline of the same, radius 12,
    /// and its envelope in the red at 26 points.
    private static func drawExpiredIcon(in rect: CGRect, context: CGContext) {
        let red = NSColor.systemRed
        let tile = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.addPath(tile)
        context.setFillColor(red.withAlphaComponent(0.12).cgColor)
        context.fillPath()
        context.addPath(CGPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 11.5, cornerHeight: 11.5, transform: nil
        ))
        context.setStrokeColor(red.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        let side: CGFloat = 26
        drawSymbol(
            "envelope.fill",
            tint: red,
            in: CGRect(x: (rect.midX - side / 2).rounded(), y: (rect.midY - side / 2).rounded(),
                       width: side, height: side),
            context: context
        )
    }

    /// A live invite's icon: the server's, the group's or the person's
    /// picture, or its monogram on a raised tile while there is none.
    private static func drawClassicIcon(
        _ classic: InviteCardSlot.Classic,
        in iconRect: CGRect,
        offset: CGPoint,
        context: CGContext,
        ink: ThemeInk,
        images: ImageStore,
        scale: CGFloat
    ) {
        let iconShape = classic.iconIsCircle
            ? CGPath(ellipseIn: iconRect, transform: nil)
            : CGPath(
                roundedRect: iconRect,
                cornerWidth: InviteCardLayoutEngine.classicIconCorner,
                cornerHeight: InviteCardLayoutEngine.classicIconCorner,
                transform: nil
            )
        context.saveGState()
        context.addPath(iconShape)
        context.clip()
        context.setFillColor(ink.discord.secondaryFill)
        context.fill(iconRect)
        if let url = classic.iconURL,
           let image = images.cached(InviteCardSlot.imageKey(url, in: classic.iconRect, scale: scale),
                                     bucket: .thumbnail)
        {
            drawFlipped(image, in: iconRect, context: context)
        } else {
            drawTextFrame(classic.monogram, at: shifted(classic.monogramOrigin, offset), context: context,
                          images: images, scale: scale)
        }
        context.restoreGState()
    }

    // MARK: Shared parts

    private static func drawInviter(
        _ inviter: InviteCardSlot.Inviter,
        offset: CGPoint,
        context: CGContext,
        images: ImageStore,
        scale: CGFloat
    ) {
        if let url = inviter.avatarURL,
           let image = images.cached(InviteCardSlot.imageKey(url, in: inviter.avatarRect, scale: scale),
                                     bucket: .thumbnail)
        {
            let rect = inviter.avatarRect.offsetBy(dx: offset.x, dy: offset.y)
            context.saveGState()
            context.addPath(CGPath(ellipseIn: rect, transform: nil))
            context.clip()
            drawFlipped(image, in: rect, context: context)
            context.restoreGState()
        }
        drawTextFrame(inviter.text, at: shifted(inviter.textOrigin, offset), context: context,
                      images: images, scale: scale)
    }

    private static func shifted(_ point: CGPoint, _ offset: CGPoint) -> CGPoint {
        CGPoint(x: point.x + offset.x, y: point.y + offset.y)
    }

    /// Filled, not stretched: a banner or a splash is 16:9 and its strip is
    /// not, so the picture covers the box and the caller's clip takes the
    /// overflow.
    private static func drawCovering(_ image: CGImage, in frame: CGRect, context: CGContext) {
        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        var covering = frame
        if frame.width / frame.height > aspect {
            covering.size.height = frame.width / aspect
            covering.origin.y = frame.midY - covering.height / 2
        } else {
            covering.size.width = frame.height * aspect
            covering.origin.x = frame.midX - covering.width / 2
        }
        context.saveGState()
        context.clip(to: frame)
        drawFlipped(image, in: covering, context: context)
        context.restoreGState()
    }
}
