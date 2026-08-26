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

    static func drawMember(
        _ entry: MemberEntry,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        isHovered: Bool,
        images: ImageStore,
        scale: CGFloat
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

        var nameWidth = available
        var tagWidth: CGFloat = 0
        if let tag = entry.tag {
            tagWidth = TimelineLayoutEngine.measure(
                tag,
                font: NSFont.systemFont(ofSize: 9, weight: .bold)
            ) + 12
            nameWidth -= tagWidth + 6
        } else if entry.isBot {
            tagWidth = 32
            nameWidth -= tagWidth + 6
        }

        let measuredName = min(
            nameWidth,
            TimelineLayoutEngine.measure(entry.name, font: style.bodyFont)
        )

        TimelineRowPainter.drawText(
            entry.name,
            font: style.bodyFont,
            color: entry.colorValue.map { NSColor(Color(hex: $0)) }
                ?? (entry.status == .offline ? style.tertiaryColor : style.primaryColor),
            at: CGPoint(x: textX, y: nameY),
            maxWidth: max(20, nameWidth),
            context: context
        )

        if let tag = entry.tag {
            drawTagChip(
                tag,
                at: CGPoint(x: textX + measuredName + 6, y: nameY + 1),
                width: tagWidth,
                context: context,
                style: style
            )
        } else if entry.isBot {
            drawTagChip(
                "APP",
                at: CGPoint(x: textX + measuredName + 6, y: nameY + 1),
                width: tagWidth,
                context: context,
                style: style,
                fill: NSColor.controlAccentColor
            )
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
            context.saveGState()
            context.addPath(shape)
            context.clip()

            // Aspect-fill, anchored to the TRAILING edge. A nameplate is
            // authored with its subject on the right and empty space on the
            // left, precisely so the name can sit over the empty half — filling
            // from the leading edge crops the subject out and leaves the busy
            // part under the text.
            let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let drawWidth = max(rect.width, rect.height * imageAspect)
            let drawRect = CGRect(
                x: rect.maxX - drawWidth,
                y: rect.minY,
                width: drawWidth,
                height: rect.height
            )
            context.translateBy(x: 0, y: rect.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -rect.midY)
            context.draw(image, in: drawRect)
            context.restoreGState()

            // The scrim. Opaque under the text, clear over the artwork — this is
            // what makes a light plate survive a light name, and it is why the
            // plate is a painter concern rather than a background image.
            context.saveGState()
            context.addPath(shape)
            context.clip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    NSColor.black.withAlphaComponent(0.72).cgColor,
                    NSColor.black.withAlphaComponent(0.30).cgColor,
                    NSColor.clear.cgColor,
                ] as CFArray,
                locations: [0, 0.45, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.minX, y: rect.midY),
                    end: CGPoint(x: rect.maxX, y: rect.midY),
                    options: []
                )
            }
            context.restoreGState()

            if isHovered {
                context.addPath(shape)
                context.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
                context.fillPath()
            }
            return
        }

        guard isHovered else { return }
        context.addPath(shape)
        context.setFillColor(NSColor(Palette.hoverFill).cgColor)
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
            context.setFillColor(NSColor(Palette.surfaceRaised).cgColor)
            context.fill(frame)
            context.restoreGState()
            TimelineRowPainter.drawText(
                entry.monogram,
                font: NSFont.systemFont(ofSize: frame.width * 0.42, weight: .semibold),
                color: style.secondaryColor,
                at: CGPoint(x: frame.minX, y: frame.midY - frame.width * 0.3),
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

    private static func drawTagChip(
        _ label: String,
        at origin: CGPoint,
        width: CGFloat,
        context: CGContext,
        style: MessageTextStyle,
        fill: NSColor? = nil
    ) {
        let frame = CGRect(x: origin.x, y: origin.y + 1, width: width, height: 14)
        context.addPath(CGPath(
            roundedRect: frame, cornerWidth: 4, cornerHeight: 4, transform: nil
        ))
        context.setFillColor((fill ?? NSColor.white.withAlphaComponent(0.12)).cgColor)
        context.fillPath()
        TimelineRowPainter.drawText(
            label,
            font: NSFont.systemFont(ofSize: 9, weight: .bold),
            color: fill == nil ? style.secondaryColor : .white,
            at: CGPoint(x: frame.minX, y: frame.midY - 6),
            maxWidth: frame.width,
            alignment: .center,
            context: context
        )
    }
}
