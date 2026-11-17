import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

/// The member list's Activity section, as the column draws it — Discord's
/// content feed at the head of the list (`946228`): "Activity · 5", then three
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

/// One card: who, what, the markers, and the picture (docs/ACTIVITY-CARDS.md
/// decision 6; Discord's `868065`, `322789`).
nonisolated struct MemberActivityCard: Equatable, Sendable, Identifiable {
    var id: String
    var authorID: UserID
    /// Up to three faces — the author's, then whoever was with them.
    var faces: [Face]
    /// Everyone past those three — Discord's "+2" chip.
    var extraPeople: Int
    var name: String
    var nameColor: UInt32?
    /// The author's display-name face, as Discord sets the card's name
    /// (`displayNameStylesFont`): the face, in the role's colour.
    var nameFont: DisplayNameFont?
    var title: String
    /// Discord's markers for the card (`ActivityMarkers`), first two drawn.
    var markers: [ActivityMarker]
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

    var isLive: Bool { liveSince != nil }
}

/// The section's measurements — Discord's card stylesheet (`g7esM5`): a card
/// 70 points tall with 8 between cards, 8 in from the column, padded by 8,
/// with a 48-point picture; names and titles 14, markers 12.
nonisolated enum MemberActivityGeometry {
    static let headerHeight = MemberSectionGeometry.height
    static let cardHeight: CGFloat = 78
    static let inset: CGFloat = 8
    static let padding: CGFloat = 8
    static let art: CGFloat = 48
    static let face: CGFloat = 16
    static let corner: CGFloat = 8
    static let nameSize: CGFloat = 14
    static let lineHeight: CGFloat = 18
    static let markerSize: CGFloat = 12
    /// How many markers a card shows — Discord's `nth-child(n+3)` rule.
    static let cardMarkerLimit = 2

    /// The card's own rectangle inside its band.
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

    /// Where each drawn marker sits on a card, for its tooltip.
    static func markerRects(
        _ card: MemberActivityCard, in band: CGRect, now: Date
    ) -> [(rect: CGRect, marker: ActivityMarker)] {
        let plate = plate(in: band)
        let left = plate.minX + padding
        let right = plate.maxX - padding - art - padding
        let y = plate.minY + padding + lineHeight + 2 + lineHeight
        var x = left
        var placed: [(CGRect, ActivityMarker)] = []
        for marker in card.markers.prefix(cardMarkerLimit) {
            let text = MemberActivityPainter.words(marker, card: card, now: now)
            let width = min(right - x, 12 + 4 + ceil((text as NSString).size(withAttributes: [.font: MemberActivityPainter.markerFont]).width))
            guard width > 16 else { break }
            placed.append((CGRect(x: x, y: y, width: width, height: 16), marker))
            x += width + 8
        }
        return placed
    }
}

/// Draws the section. `nonisolated` and free of the model, as the row
/// painter is: everything it needs arrives on the card.
nonisolated enum MemberActivityPainter {

    static var markerFont: NSFont { NSFont.systemFont(ofSize: MemberActivityGeometry.markerSize) }

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

    // swiftlint:disable:next function_parameter_count
    static func drawCard(
        _ card: MemberActivityCard,
        in band: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        isHovered: Bool,
        isSelected: Bool,
        images: ImageStore,
        scale: CGFloat,
        now: Date,
        nameFace: NSFont?
    ) {
        let ink = ThemeInk.current
        let plate = MemberActivityGeometry.plate(in: band)
        let path = CGPath(
            roundedRect: plate,
            cornerWidth: MemberActivityGeometry.corner,
            cornerHeight: MemberActivityGeometry.corner,
            transform: nil
        )
        // Discord's card: a raised ground with a muted hairline, lighter under
        // the pointer, lighter still while its popout is open.
        context.addPath(path)
        context.setFillColor(ink.lift(isSelected ? 0.12 : isHovered ? 0.09 : 0.05))
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(ink.lift(isSelected ? 0.14 : 0.08))
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
        let line = MemberActivityGeometry.lineHeight
        var y = plate.minY + padding

        // Who: their faces, their name in their face and their role's colour,
        // and "+2" for the rest.
        let face = MemberActivityGeometry.face
        var x = left
        for (index, entry) in card.faces.prefix(3).enumerated() {
            let rect = CGRect(x: x, y: y + (line - face) / 2, width: face, height: face)
            drawFace(entry, in: rect, context: context, style: style, images: images, scale: scale)
            x += face - (index < min(card.faces.count, 3) - 1 ? 3 : 0)
        }
        x += 6
        let nameFont = nameFace ?? NSFont.systemFont(ofSize: MemberActivityGeometry.nameSize, weight: .medium)
        let chipWidth: CGFloat = card.extraPeople > 0 ? extraChipWidth(card.extraPeople) + 4 : 0
        let drawn = TimelineRowPainter.drawText(
            card.name,
            font: nameFont,
            color: card.nameColor.map { NSColor(Color(hex: $0)) } ?? style.secondaryColor,
            at: CGPoint(x: x, y: TimelineRowPainter.capCenteredY(of: nameFont, in: CGRect(x: x, y: y, width: 0, height: line))),
            maxWidth: max(0, min((left + maxWidth - x) * 0.85, left + maxWidth - x - chipWidth)),
            tracking: (card.nameFont?.letterSpacing ?? 0) * nameFont.pointSize,
            context: context
        )
        if card.extraPeople > 0 {
            drawExtraChip(card.extraPeople, at: CGPoint(x: x + drawn + 4, y: y + (line - 14) / 2), context: context, style: style)
        }
        y += line + 2

        // What: the title on one line — brighter under the pointer, as
        // Discord's `interactive-text-hover`.
        let titleFont = NSFont.systemFont(ofSize: MemberActivityGeometry.nameSize, weight: .medium)
        TimelineRowPainter.drawText(
            card.title,
            font: titleFont,
            color: isHovered || isSelected ? style.primaryColor : style.primaryColor.withAlphaComponent(0.92),
            at: CGPoint(x: left, y: TimelineRowPainter.capCenteredY(of: titleFont, in: CGRect(x: left, y: y, width: 0, height: line))),
            maxWidth: maxWidth,
            context: context
        )
        y += line

        // The markers, two at most, the second shortened to fit.
        for (rect, marker) in MemberActivityGeometry.markerRects(card, in: band, now: now) {
            let text = words(marker, card: card, now: now)
            let positive = NSColor(Palette.presenceOnline)
            let symbolColor = marker.tintsSymbol ? positive : style.tertiaryColor
            let textColor = marker.tintsText ? positive : style.tertiaryColor
            drawSymbol(
                marker.symbol,
                in: CGRect(x: rect.minX, y: rect.minY + 2, width: 12, height: 12),
                pointSize: 9,
                color: symbolColor,
                context: context
            )
            TimelineRowPainter.drawText(
                text,
                font: markerFont,
                color: textColor,
                at: CGPoint(x: rect.minX + 16, y: TimelineRowPainter.capCenteredY(of: markerFont, in: rect)),
                maxWidth: max(0, rect.width - 16),
                context: context
            )
        }
    }

    /// A marker's words at the moment of drawing — the clock runs.
    static func words(_ marker: ActivityMarker, card: MemberActivityCard, now: Date) -> String {
        switch marker.text {
        case .words(let text):
            return text
        case .clock:
            if let since = card.liveSince { return ActivityCardRules.elapsed(since: since, now: now) }
            return card.occurredAt.map { ActivityCardRules.timeAgo(since: $0, now: now) } ?? ""
        }
    }

    private static var chipFont: NSFont { NSFont.systemFont(ofSize: 10, weight: .medium) }

    private static func extraChipWidth(_ count: Int) -> CGFloat {
        ceil(("+\(count)" as NSString).size(withAttributes: [.font: chipFont]).width) + 9
    }

    private static func drawExtraChip(_ count: Int, at origin: CGPoint, context: CGContext, style: MessageTextStyle) {
        let rect = CGRect(x: origin.x, y: origin.y, width: extraChipWidth(count), height: 14)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil))
        context.setFillColor(ThemeInk.current.lift(0.1))
        context.fillPath()
        TimelineRowPainter.drawText(
            "+\(count)",
            font: chipFont,
            color: style.secondaryColor,
            at: CGPoint(x: rect.minX + 4.5, y: TimelineRowPainter.capCenteredY(of: chipFont, in: rect)),
            maxWidth: rect.width,
            context: context
        )
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
    static func drawSymbol(
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
