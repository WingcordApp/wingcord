import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

/// The member list's Activity section, as the column draws it — Discord's
/// content feed at the head of the list (`946228`): "Activity — 5", then three
/// cards until it is expanded.
nonisolated struct MemberActivityBlock: Equatable, Sendable {
    /// How many cards there are in all.
    var count: Int
    var isExpanded: Bool
    /// Folded away by Hide Activity Cards: the heading stays, the cards go.
    var isHidden: Bool
    /// The cards drawn: three, every one when expanded, none when hidden.
    var cards: [MemberActivityCard]

    var title: String { "Activity\u{A0}\u{A0}·\u{A0}\u{A0}\(count.formatted())" }

    /// Whether the heading's chevron does anything — Discord's: more than
    /// three to unfold, or a hidden section to bring back.
    var canToggle: Bool { isHidden || count > ActivityCardRules.collapsedCount }

    var height: CGFloat {
        MemberActivityGeometry.headerHeight + CGFloat(cards.count) * MemberActivityGeometry.cardHeight
    }

    /// The card at `y`, in the block's own space, or nil for the heading.
    func cardIndex(at y: CGFloat) -> Int? {
        let into = y - MemberActivityGeometry.headerHeight
        guard into >= 0 else { return nil }
        let index = Int(into / MemberActivityGeometry.cardHeight)
        return cards.indices.contains(index) ? index : nil
    }

    func cardFrame(at index: Int, width: CGFloat) -> CGRect {
        CGRect(
            x: 0,
            y: MemberActivityGeometry.headerHeight + CGFloat(index) * MemberActivityGeometry.cardHeight,
            width: width,
            height: MemberActivityGeometry.cardHeight
        )
    }
}

/// One card: who, what, the chips, and the picture.
nonisolated struct MemberActivityCard: Equatable, Sendable, Identifiable {
    var id: String
    var authorID: UserID
    /// Up to three faces — the author's, then whoever was with them.
    var faces: [Face]
    var name: String
    var nameColor: UInt32?
    var title: String
    var badges: [Badge]
    var artURL: URL?
    /// The glyph in the picture's place where there is no picture.
    var artSymbol: String
    /// When it began, for something still going on: the clock runs from here.
    var liveSince: Date?
    /// When it happened, for the "3h ago" — the entry's own id.
    var occurredAt: Date?

    struct Face: Equatable, Sendable {
        var url: URL?
        var monogram: String
    }

    /// One chip under the title — Discord's badges (`506326`), in its order.
    enum Badge: Equatable, Sendable {
        /// The clock: a running time while it is on, "3h ago" after.
        case clock(symbol: String)
        case label(symbol: String, text: String, isPositive: Bool)
    }

    var isLive: Bool { liveSince != nil }
}

/// The section's measurements — Discord's (`438692`'s `nS` and the card's
/// stylesheet): a card is 72 points with its margin, 8 points in from the
/// column, padded by 8, with a 48-point picture.
nonisolated enum MemberActivityGeometry {
    static let headerHeight = MemberSectionGeometry.height
    static let cardHeight: CGFloat = 72
    static let inset: CGFloat = 8
    static let padding: CGFloat = 8
    static let art: CGFloat = 48
    static let face: CGFloat = 16
    static let corner: CGFloat = 8

    /// The card's own rectangle inside its 72-point band.
    static func plate(in band: CGRect) -> CGRect {
        CGRect(
            x: band.minX + inset,
            y: band.minY + inset,
            width: max(0, band.width - inset * 2),
            height: band.height - inset
        )
    }

    /// The gear and the chevron at the heading's trailing end, on the eyebrow
    /// every other section's heading sits on.
    static func gearRect(in header: CGRect, canToggle: Bool) -> CGRect {
        let side: CGFloat = 16
        let eyebrow = MemberSectionGeometry.eyebrow(in: header)
        let trailing = header.maxX - MemberSectionGeometry.inset - (canToggle ? side + 4 : 0)
        return CGRect(x: trailing - side, y: eyebrow.midY - side / 2, width: side, height: side)
    }

    static func chevronRect(in header: CGRect) -> CGRect {
        let side: CGFloat = 16
        let eyebrow = MemberSectionGeometry.eyebrow(in: header)
        return CGRect(
            x: header.maxX - MemberSectionGeometry.inset - side,
            y: eyebrow.midY - side / 2,
            width: side,
            height: side
        )
    }
}

/// Draws the section. `nonisolated` and free of the model, as the row
/// painter is: everything it needs arrives on the card.
nonisolated enum MemberActivityPainter {

    static func drawHeader(
        _ block: MemberActivityBlock,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle
    ) {
        // The same words as every other section's heading: `MemberRowPainter.drawHeader`.
        let font = style.memberHeadingFont
        let x = frame.minX + MemberSectionGeometry.inset
        let gear = MemberActivityGeometry.gearRect(in: frame, canToggle: block.canToggle)
        TimelineRowPainter.drawText(
            block.title,
            font: font,
            color: style.secondaryColor,
            at: CGPoint(x: x, y: TimelineRowPainter.capCenteredY(of: font, in: MemberSectionGeometry.eyebrow(in: frame))),
            maxWidth: gear.minX - 4 - x,
            context: context
        )
        drawSymbol("gearshape.fill", in: gear, pointSize: 10, color: style.secondaryColor, context: context)
        if block.canToggle {
            let chevron = block.isHidden ? "eye.slash" : block.isExpanded ? "chevron.up" : "chevron.down"
            drawSymbol(
                chevron,
                in: MemberActivityGeometry.chevronRect(in: frame),
                pointSize: 10,
                color: style.secondaryColor,
                context: context
            )
        }
    }

    static func drawCard(
        _ card: MemberActivityCard,
        in band: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        isHovered: Bool,
        images: ImageStore,
        scale: CGFloat,
        now: Date
    ) {
        let ink = ThemeInk.current
        let plate = MemberActivityGeometry.plate(in: band)
        let path = CGPath(
            roundedRect: plate,
            cornerWidth: MemberActivityGeometry.corner,
            cornerHeight: MemberActivityGeometry.corner,
            transform: nil
        )
        // Discord's card: a raised ground, a muted hairline, lighter under the
        // pointer.
        context.addPath(path)
        context.setFillColor(ink.lift(isHovered ? 0.09 : 0.05))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(ink.lift(0.08))
        context.setLineWidth(1)
        context.strokePath()

        let padding = MemberActivityGeometry.padding
        let artSide = MemberActivityGeometry.art
        let art = CGRect(
            x: plate.maxX - padding - artSide,
            y: plate.midY - artSide / 2,
            width: artSide,
            height: artSide
        )
        drawArt(card, in: art, context: context, style: style, images: images, scale: scale)

        let left = plate.minX + padding
        let maxWidth = art.minX - padding - left
        var y = plate.minY + padding

        // Who: their faces, then their name in their role's colour.
        let face = MemberActivityGeometry.face
        var x = left
        for (index, entry) in card.faces.prefix(3).enumerated() {
            let rect = CGRect(x: x, y: y, width: face, height: face)
            drawFace(entry, in: rect, context: context, style: style, images: images, scale: scale)
            x += face - (index < card.faces.count - 1 ? 3 : 0)
        }
        x += 6
        let nameFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        TimelineRowPainter.drawText(
            card.name,
            font: nameFont,
            color: card.nameColor.map { NSColor(Color(hex: $0)) } ?? style.secondaryColor,
            at: CGPoint(x: x, y: TimelineRowPainter.capCenteredY(of: nameFont, in: CGRect(x: x, y: y, width: 0, height: face))),
            maxWidth: max(0, left + maxWidth - x),
            context: context
        )
        y += face + 2

        // What: the title on one line.
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        TimelineRowPainter.drawText(
            card.title,
            font: titleFont,
            color: style.primaryColor,
            at: CGPoint(x: left, y: y),
            maxWidth: maxWidth,
            context: context
        )
        y += ceil(titleFont.ascender - titleFont.descender) + 1

        // The chips, as many as fit.
        let chipFont = NSFont.systemFont(ofSize: 10.5)
        var chipX = left
        for badge in card.badges {
            let (symbol, text, isPositive) = resolve(badge, card: card, now: now)
            let color = isPositive ? NSColor(Palette.presenceOnline) : style.tertiaryColor
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: chipFont]).width)
            let needed = 11 + 3 + textWidth
            guard chipX + needed <= left + maxWidth else { break }
            drawSymbol(symbol, in: CGRect(x: chipX, y: y + 1, width: 11, height: 11), pointSize: 9, color: color, context: context)
            TimelineRowPainter.drawText(
                text,
                font: chipFont,
                color: isPositive ? color : style.tertiaryColor,
                at: CGPoint(x: chipX + 14, y: y),
                maxWidth: textWidth,
                context: context
            )
            chipX += needed + 8
        }
    }

    /// A clock chip's words at the moment of drawing.
    static func resolve(
        _ badge: MemberActivityCard.Badge,
        card: MemberActivityCard,
        now: Date
    ) -> (symbol: String, text: String, isPositive: Bool) {
        switch badge {
        case .clock(let symbol):
            if let since = card.liveSince {
                return (symbol, ActivityCardRules.elapsed(since: since, now: now), true)
            }
            return (symbol, card.occurredAt.map { ActivityCardRules.timeAgo(since: $0, now: now) } ?? "", false)
        case .label(let symbol, let text, let isPositive):
            return (symbol, text, isPositive)
        }
    }

    private static func drawArt(
        _ card: MemberActivityCard,
        in rect: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.clip()
        if let url = card.artURL,
           let image = images.cached(
               ImageStore.Key(url: url, maximumPixelSize: Int((rect.width * scale).rounded(.up))),
               bucket: .thumbnail
           )
        {
            TimelineRowPainter.drawFlipped(image, in: rect, context: context)
            context.restoreGState()
            return
        }
        context.setFillColor(ThemeInk.current.lift(0.06))
        context.fill(rect)
        context.restoreGState()
        drawSymbol(card.artSymbol, in: rect.insetBy(dx: 14, dy: 14), pointSize: 16, color: style.tertiaryColor, context: context)
    }

    private static func drawFace(
        _ face: MemberActivityCard.Face,
        in rect: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        if let url = face.url,
           let image = images.cached(ImageStore.Key(url: url, maximumPixelSize: Int((rect.width * scale).rounded(.up))))
        {
            TimelineRowPainter.drawFlipped(image, in: rect, context: context)
        } else {
            context.setFillColor(ThemeInk.current.surfaceRaised)
            context.fill(rect)
        }
        context.restoreGState()
    }

    /// An SF Symbol, rasterised into a square in the given colour.
    private static func drawSymbol(
        _ name: String,
        in rect: CGRect,
        pointSize: CGFloat,
        color: NSColor,
        context: CGContext
    ) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = image.size
        let target = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
    }
}
