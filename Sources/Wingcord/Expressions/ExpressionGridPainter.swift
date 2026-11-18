import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Draws the picker's grid: section headings, and cells that are either a glyph
/// or a picture.
///
/// **A heading is drawn twice, by two different views, and that is the whole
/// trick behind the sticky behaviour.** The grid's canvas draws every heading at
/// its natural position; a floating view above the scroller draws whichever one
/// is currently pinned. The two never conflict, because a heading is only pinned
/// once its natural position has gone above the pin line — where the canvas's
/// copy is scrolled out of the visible area anyway — and at the instant of
/// hand-off the two coincide exactly.
///
/// That is what lets the canvas keep repainting only when it runs out of
/// overscan. A heading drawn *only* into it would scroll away with the layer.
///
/// **A Unicode cell costs a `CTLine` and nothing else.** That is the whole
/// reason the grid is drawn rather than composed: nineteen hundred emoji is
/// nineteen hundred view nodes with a button each, against one canvas that
/// paints the forty a viewport shows and touches nothing else.
nonisolated enum ExpressionGridPainter {

    /// Where a cell's highlight sits relative to the cell — the pad that makes
    /// a 32pt glyph look like it has a target around it rather than a box
    /// drawn on it.
    static let highlightInset: CGFloat = -3

    // MARK: Headings

    /// The pill: the server's icon, then its name.
    ///
    /// A pill rather than a bare label because it has to stay legible while the
    /// cells of the *next* section pass underneath it — the panel is
    /// transparent, so a label with no ground has emoji running through the
    /// letters. The icon is what makes it a server rather than a caption.
    static func drawHeader(
        _ section: ExpressionSection,
        in rowFrame: CGRect,
        images: ImageStore,
        scale: CGFloat,
        context: CGContext
    ) {
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let title = section.title.uppercased()
        let textWidth = measure(title, font: font)
        // **Reserved, not appended.** The lock used to be glued onto the title
        // and drawn as one string — while the pill was measured from the title
        // ALONE. So the pill hugged the name, the draw was handed a longer
        // string, and the first thing truncated away was the padlock itself:
        // every locked server read as a name that stopped mid-word for no
        // reason, with nothing to say why. Measured here, and drawn separately
        // below at the pill's trailing edge, so the NAME is what gives when the
        // panel is narrow and the lock survives at every width.
        let lockWidth = section.isLocked ? measure(Self.lockMark, font: font) + badgeGap : 0

        let pill = CGRect(
            x: rowFrame.minX + ExpressionGridMetrics.horizontalInset,
            y: rowFrame.midY - headerPillHeight / 2,
            width: min(
                leadingPad + badgeSide + badgeGap + textWidth + lockWidth + trailingPad,
                rowFrame.width - ExpressionGridMetrics.horizontalInset * 2
            ),
            height: headerPillHeight
        )

        context.setFillColor(ThemeInk.current.lift(0.14))
        context.addPath(CGPath(
            roundedRect: pill,
            cornerWidth: pill.height / 2,
            cornerHeight: pill.height / 2,
            transform: nil
        ))
        context.fillPath()

        let badge = CGRect(
            x: pill.minX + leadingPad,
            y: pill.midY - badgeSide / 2,
            width: badgeSide,
            height: badgeSide
        )
        drawBadge(section.badge, in: badge, images: images, scale: scale, context: context)

        let textX = badge.maxX + badgeGap
        let baseline = TimelineRowPainter.capCenteredY(of: font, in: pill)
        let drawnWidth = TimelineRowPainter.drawText(
            title,
            font: font,
            color: NSColor.labelColor,
            at: CGPoint(x: textX, y: baseline),
            maxWidth: max(pill.maxX - trailingPad - lockWidth - textX, 1),
            context: context
        )
        if section.isLocked {
            // Against the name rather than against the pill's far edge: a name
            // that fits leaves the lock beside it, which is what reads as "this
            // one is locked" rather than as two unrelated marks.
            _ = TimelineRowPainter.drawText(
                Self.lockMark,
                font: font,
                color: NSColor.labelColor,
                at: CGPoint(x: textX + drawnWidth + badgeGap, y: baseline),
                maxWidth: lockWidth,
                context: context
            )
        }
    }

    /// Measures a string in the header's own face.
    ///
    /// **One place, because the pill's width and the text's ceiling are the same
    /// number twice** — and the bug this replaces was exactly those two numbers
    /// being computed from two different strings.
    private static func measure(_ string: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.font: font])
        )
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// The mark on a section whose expressions this account cannot use.
    static let lockMark = "🔒"


    /// The pill's own height, inside the taller row that gives it breathing
    /// space above and below.
    static let headerPillHeight: CGFloat = 20
    /// The icon inside the pill. **Not private**: the prefetch has to ask for
    /// this exact size, or the picture lands under a key the draw never looks
    /// in and the pill shows a monogram forever.
    static let badgeSide: CGFloat = 15
    private static let leadingPad: CGFloat = 3
    private static let badgeGap: CGFloat = 5
    private static let trailingPad: CGFloat = 9

    /// An SF Symbol in the label's own ink, as a mask filled — the section
    /// pill's words are that colour, and the mark belongs with them.
    private static func drawSymbol(_ name: String, in frame: CGRect, context: CGContext) {
        let configuration = NSImage.SymbolConfiguration(pointSize: frame.height * 0.78, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        var rect = CGRect(origin: .zero, size: symbol.size)
        guard let mask = symbol.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let size = symbol.size
        let target = CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        context.saveGState()
        // The canvas is flipped; a mask is drawn the right way up.
        context.translateBy(x: 0, y: target.maxY + target.minY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: target, mask: mask)
        context.setFillColor(NSColor.labelColor.withAlphaComponent(0.78).cgColor)
        context.fill(target)
        context.restoreGState()
    }

    private static func drawBadge(
        _ badge: ExpressionSection.Badge,
        in frame: CGRect,
        images: ImageStore,
        scale: CGFloat,
        context: CGContext
    ) {
        switch badge {
        case .glyph(let glyph):
            drawGlyph(glyph, in: frame, context: context)
        case .symbol(let name):
            drawSymbol(name, in: frame, context: context)
        case .image(let url, let monogram):
            context.saveGState()
            // The rail draws a server as a squircle; a different shape here
            // would read as a different object.
            context.addPath(CGPath(
                roundedRect: frame, cornerWidth: 4, cornerHeight: 4, transform: nil
            ))
            context.clip()
            let pixels = Int((frame.width * scale).rounded(.up))
            // A Lottie pack cover has no still on the CDN, so its poster is
            // the one `LottiePosters` drew.
            let poster: CGImage? = url.flatMap { url in
                LottieFilmstrip.handles(url)
                    ? LottiePosters.shared.cached(LottiePosters.Key(url: url, pixels: pixels))
                    : images.cached(ImageStore.Key(url: url, maximumPixelSize: pixels))
            }
            if let poster {
                let image = poster
                context.translateBy(x: 0, y: frame.maxY)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(
                    x: frame.minX, y: 0, width: frame.width, height: frame.height
                ))
            } else {
                context.setFillColor(ThemeInk.current.lift(0.16))
                context.fill(frame)
                context.restoreGState()
                let font = NSFont.systemFont(ofSize: 8, weight: .bold)
                _ = TimelineRowPainter.drawText(
                    monogram,
                    font: font,
                    color: NSColor.secondaryLabelColor,
                    at: CGPoint(x: frame.minX, y: TimelineRowPainter.capCenteredY(of: font, in: frame)),
                    maxWidth: frame.width,
                    alignment: .center,
                    context: context
                )
                return
            }
            context.restoreGState()
        }
    }

    /// One cell.
    ///
    /// - Parameter isHovered: Draws the target behind it. The pointer is the
    ///   only affordance a drawn grid has — there is no button to highlight
    ///   itself — so it is not decoration.
    static func drawItem(
        _ item: ExpressionItem,
        in frame: CGRect,
        isHovered: Bool,
        isDimmed: Bool,
        images: ImageStore,
        scale: CGFloat,
        time: Double?,
        context: CGContext,
        drawsArt: Bool = true
    ) {
        if isHovered {
            let target = frame.insetBy(dx: highlightInset, dy: highlightInset)
            context.setFillColor(ThemeInk.current.lift(0.12))
            context.addPath(CGPath(
                roundedRect: target,
                cornerWidth: Radius.row,
                cornerHeight: Radius.row,
                transform: nil
            ))
            context.fillPath()
        }

        context.saveGState()
        // A locked section is dimmed rather than hidden: its contents are still
        // worth looking at, and a rail that silently omits servers reads as
        // those servers having nothing.
        if isDimmed { context.setAlpha(dimmedAlpha) }

        switch item.art {
        case .glyph(let glyph):
            drawGlyph(glyph, in: frame, context: context)
        case .image(_, _) where !drawsArt:
            // Its film layer is showing it (`ExpressionGridCanvas.syncFilms`).
            break
        case .image(let url, let animated):
            drawImage(
                url: url,
                animated: animated,
                in: frame,
                images: images,
                scale: scale,
                time: time,
                context: context
            )
        }

        context.restoreGState()
    }

    /// A glyph, centred on its own typographic box.
    ///
    /// **Not cap-height centred**, unlike every label in this app. Cap height is
    /// the right rule for text, where the eye aligns on the capitals; an emoji
    /// has no capitals and fills its em box, so centring on the box is what puts
    /// it in the middle of the cell.
    private static func drawGlyph(_ glyph: String, in frame: CGRect, context: CGContext) {
        // Sized to the cell rather than to a text style: this is a picture that
        // happens to be made of text, and it should fill its target the way the
        // custom emoji beside it does.
        let font = NSFont.systemFont(ofSize: (frame.height * 0.78).rounded())
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: glyph,
            attributes: [.font: font]
        ))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(
            x: (frame.midX - width / 2).rounded(),
            y: (frame.midY + (ascent - descent) / 2).rounded()
        )
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// A custom emoji or a sticker.
    ///
    /// The cache is **peeked synchronously** — never awaited. An image already
    /// decoded draws on this pass; one that is not leaves the cell empty and the
    /// canvas repaints it when the fetch lands. Awaiting here would mean a
    /// placeholder frame per cell, times a screenful, per scroll.
    /// A filmstrip's budget, per asset.
    ///
    /// **A byte budget is a frame count in disguise and belongs to the caller.**
    /// A cell here is 32 points, so a frame is about 16 KB at 2x — a megabyte
    /// buys sixty-four of them, which is longer than any emoji, and a screenful
    /// of forty then costs at most forty megabytes against the store's own
    /// sixty-four before it starts evicting.
    static let filmBudget = 1024 * 1024

    /// How strongly a locked cell draws — its film included
    /// (`ExpressionGridCanvas.syncFilms`).
    static let dimmedAlpha: CGFloat = 0.4

    private static func drawImage(
        url: URL?,
        animated: Bool,
        in frame: CGRect,
        images: ImageStore,
        scale: CGFloat,
        time: Double?,
        context: CGContext
    ) {
        guard let url else { return }
        let pixels = Int((frame.width * scale).rounded(.up))

        // The filmstrip if it has arrived and animation is on; otherwise the
        // still, which is the same URL's first frame and lands far sooner. A
        // Lottie sticker has no still on the CDN: its poster is drawn once by
        // `LottiePosters`, and its film plays over it (`FilmPlayer`).
        let image: CGImage?
        if LottieFilmstrip.handles(url) {
            image = LottiePosters.shared.cached(LottiePosters.Key(url: url, pixels: pixels))
        } else if animated, let time, let strip = AnimatedImageStore.shared.cached(
            AnimatedImageStore.Key(
                url: url, maximumPixelSize: pixels, byteBudget: filmBudget
            )
        ) {
            image = strip.frame(at: time)
        } else {
            image = images.cached(
                ImageStore.Key(url: url, maximumPixelSize: pixels),
                bucket: .thumbnail
            )
        }
        guard let image else { return }

        // Aspect-FIT, not fill. A sticker is a picture with its own shape and
        // cropping it to a square is cropping the thing being chosen; the
        // leftover space in the cell is the gap between cells and reads as one.
        let ratio = CGFloat(image.width) / CGFloat(max(image.height, 1))
        var drawn = frame
        if ratio > 1 {
            drawn.size.height = (frame.width / ratio).rounded()
            drawn.origin.y += ((frame.height - drawn.height) / 2).rounded()
        } else if ratio < 1 {
            drawn.size.width = (frame.height * ratio).rounded()
            drawn.origin.x += ((frame.width - drawn.width) / 2).rounded()
        }

        context.saveGState()
        // The canvas is flipped; an image drawn into it without this arrives
        // upside down.
        context.translateBy(x: 0, y: drawn.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: drawn.minX, y: 0, width: drawn.width, height: drawn.height
        ))
        context.restoreGState()
    }
}
