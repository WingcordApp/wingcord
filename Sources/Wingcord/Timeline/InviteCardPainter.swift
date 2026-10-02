import AppKit
import CoreGraphics
import WingcordCore

nonisolated extension TimelineRowPainter {

    /// Discord's affirmative green (`GREEN_430`) and its pressed shade.
    private static let joinFill = CGColor(srgbRed: 0x24 / 255, green: 0x80 / 255, blue: 0x45 / 255, alpha: 1)
    private static let joinFillHovered = CGColor(
        srgbRed: 0x1A / 255, green: 0x63 / 255, blue: 0x34 / 255, alpha: 1
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
        scale: CGFloat
    ) {
        let ink = ThemeInk.current
        let frame = slot.rect.offsetBy(dx: offset.x, dy: offset.y)
        let corner: CGFloat = if case .profile = slot.body {
            InviteCardLayoutEngine.profileCorner
        } else {
            EmbedLayoutEngine.corner
        }
        let outline = CGPath(roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil)
        context.addPath(outline)
        context.setFillColor(ink.cardFill)
        context.fillPath()

        switch slot.body {
        case .classic(let classic):
            drawClassic(classic, offset: offset, context: context, images: images, scale: scale)
        case .profile(let profile):
            // Everything the card holds is cut to its outline — the banner's
            // corners, and the content a folded card hides under its fade.
            context.saveGState()
            context.addPath(outline)
            context.clip()
            drawProfile(profile, offset: offset, context: context, ink: ink, images: images, scale: scale)
            if let mark = slot.mark {
                GuildMarkArt.draw(
                    mark, in: slot.markRect.offsetBy(dx: offset.x, dy: offset.y),
                    context: context, isLight: ink.isLight
                )
            }
            if case .collapsed(let fade) = slot.fold {
                drawFade(fade.offsetBy(dx: offset.x, dy: offset.y), to: ink.cardFill, context: context)
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
            context.setFillColor(ink.lift(hovered == hide.origin ? 0.18 : 0.12))
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
                : ink.lift(isHovered ? 0.18 : 0.12)
        )
        context.fillPath()
        // A disabled face is drawn at half, which is what Discord's disabled
        // button is.
        if !button.isEnabled { context.setAlpha(0.5) }
        drawTextFrame(face.label, at: shifted(face.labelOrigin, offset), context: context, images: images, scale: scale)
        if !button.isEnabled { context.setAlpha(1) }
    }

    // MARK: The profile card

    private static func drawProfile(
        _ profile: InviteCardSlot.Profile,
        offset: CGPoint,
        context: CGContext,
        ink: ThemeInk,
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
        context.setFillColor(ink.cardFill)
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
            context.setFillColor(ink.surfaceRaised)
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
            context.setStrokeColor(ink.hoverFill)
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
    /// `linear-gradient(180deg, transparent, var(--background-surface-high))`.
    private static func drawFade(_ rect: CGRect, to ground: CGColor, context: CGContext) {
        guard let clear = ground.copy(alpha: 0),
              let gradient = CGGradient(
                  colorsSpace: ground.colorSpace, colors: [clear, ground] as CFArray, locations: [0, 1]
              )
        else { return }
        context.saveGState()
        context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                                height: rect.height + InviteCardLayoutEngine.buttonHeight + 24))
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
        context.setFillColor(ink.surfaceRaised)
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
