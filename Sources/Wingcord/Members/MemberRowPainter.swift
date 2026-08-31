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

    static func drawHeader(
        title: String,
        count: Int,
        colorValue: UInt32?,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        let label = "\(title.uppercased()) — \(count)"
        TimelineRowPainter.drawText(
            label,
            font: NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .semibold),
            // A hoisted role's heading takes the role's colour, which is how the
            // list says *why* these people are grouped. The synthetic Online and
            // Offline groups have no colour and take the quiet default.
            color: colorValue.map { NSColor(Color(hex: $0)) } ?? style.tertiaryColor,
            at: CGPoint(
                x: rowFrame.minX + MemberRowGeometry.horizontalMargin + MemberRowGeometry.contentInset,
                y: rowFrame.minY + MemberRowGeometry.sectionSpacing + 8
            ),
            maxWidth: rowFrame.width - MemberRowGeometry.horizontalMargin * 2,
            context: context
        )
    }

    /// - Parameter nameFace: the styled face this person's name is set in,
    ///   already resolved. **Resolved by the caller, not looked up here** — the
    ///   registry is main-actor state and this painter is deliberately
    ///   `nonisolated` so a draw cannot reach into the model, which is the rule
    ///   `INVARIANTS.md` §4.5 is written around. Nil is the ordinary case and
    ///   means the app's own face.
    static func drawMember(
        _ entry: MemberEntry,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        isHovered: Bool,
        images: ImageStore,
        scale: CGFloat,
        nameFace: NSFont? = nil
    ) {
        let plate = MemberRowGeometry.plateRect(in: rowFrame)
        let plateShape = CGPath(
            roundedRect: plate,
            cornerWidth: Radius.row,
            cornerHeight: Radius.row,
            transform: nil
        )

        // 1. The plate layer.
        drawPlate(
            entry,
            shape: plateShape,
            rect: plate,
            context: context,
            isHovered: isHovered,
            images: images,
            scale: scale
        )

        // 2. Avatar and presence.
        let avatar = MemberRowGeometry.avatarRect(in: rowFrame)
        drawAvatar(
            entry,
            in: avatar,
            context: context,
            style: style,
            images: images,
            scale: scale
        )

        // 3. Name, tag chip, activity.
        let textX = MemberRowGeometry.textOriginX(in: rowFrame)
        let available = plate.maxX - textX - MemberRowGeometry.contentInset
        let hasSubtitle = entry.subtitle != nil
        let nameY = hasSubtitle ? plate.midY - 15 : plate.midY - 8

        // Room for whatever chip follows the name, reserved before the name is
        // drawn so the name truncates to leave space rather than colliding.
        var chipLabel: String?
        var chipFill: NSColor?
        var chipBadge: URL?
        if let tag = entry.tag {
            chipLabel = tag
            chipBadge = entry.tagBadgeURL
        } else if entry.isBot {
            chipLabel = "APP"
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
        let reserved = chipWidth > 0 ? chipWidth + MemberRowGeometry.tagChipGap : 0
        let nameWidth = max(20, available - reserved)

        // **The chip follows the DRAWN text, not the slot.** `drawText` returns
        // the width it actually painted; measuring the full name and clamping it
        // to the available width instead places the chip at the end of the slot,
        // which is a visible gap on every truncated name and on nothing else.
        // **The face carries into the roster; the colour does not.** Discord's
        // own dialog says colours and effects do not appear in servers, and a
        // role colour a server chose has to beat a colour its owner did — so a
        // styled name here is the same ink as any other, set in their face.
        // The effect itself plays on hover, over this row rather than in it.
        let nameFont = nameFace ?? style.bodyFont
        let drawnName = TimelineRowPainter.drawText(
            entry.name,
            font: nameFont,
            color: entry.colorValue.map { NSColor(Color(hex: $0)) }
                ?? (entry.status == .offline ? style.tertiaryColor : style.primaryColor),
            at: CGPoint(x: textX, y: nameY),
            maxWidth: nameWidth,
            tracking: (entry.displayNameFont?.letterSpacing ?? 0) * style.bodyFont.pointSize,
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
            if crown.maxX <= plate.maxX - MemberRowGeometry.contentInset {
                TimelineRowPainter.drawSymbol(
                    "crown.fill",
                    tint: NSColor(Palette.presenceIdle),
                    in: crown,
                    context: context
                )
            }
        }

        if let subtitle = entry.subtitle {
            TimelineRowPainter.drawText(
                subtitle,
                font: style.metadataFont,
                color: style.tertiaryColor,
                at: CGPoint(x: textX, y: plate.midY + 2),
                maxWidth: max(20, available),
                context: context
            )
        }

        // Offline members are dimmed as a whole rather than by picking a paler
        // colour for each element, which is one operation instead of five and
        // keeps role colours recognisable while still reading as offline.
        if entry.status == .offline {
            context.saveGState()
            context.addPath(plateShape)
            context.clip()
            context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            context.setBlendMode(.destinationOut)
            context.fill(plate)
            context.restoreGState()
        }
    }

    // MARK: Plate

    // **Built once, never per row.** A `CGGradient` is an allocation plus a
    // colour-space resolve, and a plate draws two of them; the scrim used to be
    // constructed inside the draw, so a roster of forty plated rows repainting
    // on every pointer move was building forty of it a frame for a value that
    // cannot change.
    //
    // `nonisolated(unsafe)` for the same reason `MemberRowGeometry.tagChipFont`
    // is: a `CGGradient` is immutable once created and neither of these is ever
    // written after first use, while `static let` initialisation is itself
    // thread-safe.

    private nonisolated(unsafe) static let plateScrim: CGGradient? = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.black.withAlphaComponent(0.72).cgColor,
            NSColor.black.withAlphaComponent(0.30).cgColor,
            NSColor.clear.cgColor,
        ] as CFArray,
        locations: [0, 0.45, 1]
    )

    /// One wash per palette, keyed so a draw is a dictionary lookup.
    ///
    /// Twelve at most, and only those with a colour — `.none` is a real answer
    /// and gets no entry, so a plate that asked for no wash cannot be given one
    /// by a fallback.
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
        scale: CGFloat
    ) {
        if let url = entry.nameplateURL,
           let image = images.cached(
               ImageStore.Key(
                   url: url,
                   maximumPixelSize: Int((MemberRowGeometry.nameplateWidth * scale).rounded(.up))
               ),
               bucket: .artwork
           )
        {
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

            // 2. The artwork: fit to the plate's height, hung off its trailing
            // edge — see `MemberRowGeometry.nameplateArtRect`, which carries
            // the measurement that settled the rule.
            //
            // **Not aspect-fill, which is what this was.** Fill takes whichever
            // of the two fits is larger, so it lands on the height for a
            // two-line plate and on the width for a one-line one — and the
            // second stretches the strip vertically, because the drawn height
            // is the plate's either way. Half the roster's roses came out as
            // ellipses.
            TimelineRowPainter.drawFlipped(
                image,
                in: MemberRowGeometry.nameplateArtRect(
                    in: rect,
                    imagePixelSize: CGSize(width: image.width, height: image.height)
                ),
                context: context
            )

            // 3. The scrim. Opaque under the text, clear over the artwork —
            // this is what makes a light plate survive a light name, and it is
            // why the plate is a painter concern rather than a background
            // image.
            if let scrim = plateScrim {
                context.drawLinearGradient(
                    scrim,
                    start: CGPoint(x: rect.minX, y: rect.midY),
                    end: CGPoint(x: rect.maxX, y: rect.midY),
                    options: []
                )
            }

            if isHovered {
                context.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
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

    private static func drawAvatar(
        _ entry: MemberEntry,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        context.saveGState()
        context.addEllipse(in: frame)
        context.clip()
        if let url = entry.avatarURL,
           let image = images.cached(ImageStore.Key(
               url: url,
               maximumPixelSize: Int((frame.width * scale).rounded(.up))
           ))
        {
            context.translateBy(x: 0, y: frame.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -frame.midY)
            context.draw(image, in: frame)
            context.restoreGState()
        } else {
            context.setFillColor(ThemeInk.current.surfaceRaised)
            context.fill(frame)
            context.restoreGState()
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
        }

        drawPresenceDot(entry.status, on: frame, context: context)
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
        let side: CGFloat = 11
        let dot = CGRect(
            x: avatarFrame.maxX - side + 2,
            y: avatarFrame.maxY - side + 2,
            width: side,
            height: side
        )
        let ring = dot.insetBy(dx: -2, dy: -2)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fillEllipse(in: ring)

        let tint = NSColor(status.tint)
        switch status {
        case .online:
            context.setFillColor(tint.cgColor)
            context.fillEllipse(in: dot)
        case .idle:
            context.setFillColor(tint.cgColor)
            context.fillEllipse(in: dot)
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fillEllipse(in: dot.offsetBy(dx: -2.5, dy: -2.5).insetBy(dx: 1.6, dy: 1.6))
        case .doNotDisturb:
            context.setFillColor(tint.cgColor)
            context.fillEllipse(in: dot)
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(
                x: dot.minX + 2, y: dot.midY - 1.1,
                width: dot.width - 4, height: 2.2
            ))
        case .offline, .invisible:
            context.setStrokeColor(tint.cgColor)
            context.setLineWidth(2.6)
            context.strokeEllipse(in: dot.insetBy(dx: 1.3, dy: 1.3))
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
        context.setFillColor((fill ?? NSColor.white.withAlphaComponent(0.12)).cgColor)
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
