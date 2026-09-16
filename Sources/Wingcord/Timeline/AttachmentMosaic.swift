import CoreGraphics
import Foundation

/// Where several pictures in one message go.
///
/// **Ported from Discord's own layout rather than approximated from a
/// screenshot.** Three sources, and they agree:
///
/// - webpack module `394839` holds the five shapes and the arithmetic that
///   divides the row;
/// - module `838541` holds the numbers — `MAX_WIDTH = 550`,
///   `MAX_HEIGHT = 350`;
/// - the stylesheet for module `293612` holds the heights, which are **not** all
///   350: a two-picture row is capped at 280, the three-picture shape at 350,
///   the 2 × 2 at 350 in two equal rows, and a row of three is square by
///   `aspect-ratio: 1/1`.
///
/// The screenshot that prompted this agrees with all of it: a four-picture
/// message measures 550 across, two 273-wide columns either side of a 4-point
/// gap, in rows 173 tall.
///
/// Two of those numbers are the whole of "the images are way too big". A
/// message attachment was drawn at the *column's* width, which on a wide window
/// is a thousand points, and stacked one under another — so four screenshots
/// filled several screens of scrollback. **Every picture in a transcript is
/// capped at 550 wide**, and past one they share that width rather than each
/// taking it.
///
/// `nonisolated` and pure: this runs inside the layout engine, which is off the
/// main actor, and every number it returns is derived from its arguments.
nonisolated enum AttachmentMosaic {

    /// The widest a message's pictures may be, together or alone.
    ///
    /// `.visualMediaItemContainer { max-width: 550px }`. Discord's Components
    /// V2 surface raises it to 600 and a clip embed to 660; this client has
    /// neither.
    static let maxWidth: CGFloat = 550

    /// The tallest a lone picture may be.
    ///
    /// `.oneByOneGrid { max-height: 350px }`. `Metrics.attachmentMaxHeight`
    /// already held it before any of this, which is how the single-picture case
    /// was right in one dimension and wrong in the other.
    static var maxHeight: CGFloat { Metrics.attachmentMaxHeight }

    /// The tallest a **row of two** may be, and the leading picture of a long
    /// mosaic with it.
    ///
    /// `.oneByTwoGrid` and `.oneByOneGridMosaic` are both `max-height: 280px`.
    /// It is not `maxHeight`, and using 350 there is a row a fifth too tall.
    static let rowMaxHeight: CGFloat = 280

    /// Between cells, both ways, and between a leading row and the rows of
    /// three under it — `grid-gap: 4px`, and `margin-top: 4px` on the pair of
    /// adjacent-sibling rules.
    static let gap: CGFloat = 4

    /// Between the pictures and a file card, and between two file cards.
    ///
    /// `.nonVisualMediaItemContainer` and `.nonVisualMediaItem + …` are both
    /// `margin-top: 8px` — twice the gap inside the grid, which is what keeps a
    /// card from reading as another cell.
    static let stackGap: CGFloat = 8

    /// How tall each row of a 2 × 2 may be.
    ///
    /// **Derived, not written down.** `grid-template-rows: repeat(2,
    /// minmax(0, 1fr))` inside `max-height: 350px` with a 4-point gap, so a
    /// change to the cap moves the grid with it rather than leaving two numbers
    /// to disagree.
    static var rowHeight: CGFloat { ((maxHeight - gap) / 2).rounded() }

    /// The boxes `sizes.count` pictures occupy, relative to (0, 0).
    ///
    /// - Parameter sizes: each picture's own pixel dimensions, or nil where the
    ///   attachment carried none. The pixels matter in exactly one place — a
    ///   lone picture is never drawn larger than itself — and everywhere else
    ///   only the shape is read, because a grid cell is a fixed box and
    ///   `object-fit: cover` upscales into it.
    /// - Parameter width: what the message column offers. Clamped to `maxWidth`.
    ///
    /// The five shapes, in Discord's own order:
    ///
    /// - **One** keeps its own aspect inside 550 × 350 and is never upscaled.
    ///   It is the only one of the five that is not cropped.
    /// - **Two** share the row in cells of `(w - 4) / 2`, as tall as the taller
    ///   picture wants and never past 280.
    /// - **Three** are a cell of `2(w - 4) / 3` beside two stacked cells that
    ///   take the rest, inside 350. The column adds up: 364 + 4 + 182 = 550.
    /// - **Four** are a 2 × 2 of `(w - 4) / 2` in two equal rows inside 350.
    /// - **Five or more** lead with the remainder — one full-width picture when
    ///   `count % 3 == 1`, a pair when it is 2, nothing when it is 0 — and then
    ///   run in **square** rows of three.
    static func frames(sizes: [CGSize?], width: CGFloat) -> [CGRect] {
        let w = min(width, maxWidth)
        guard w > 0, !sizes.isEmpty else { return [] }

        switch sizes.count {
        case 1:
            return [CGRect(origin: .zero, size: singleBox(sizes[0], width: w))]
        case 2:
            return pair(sizes, width: w, y: 0)
        case 3:
            return trio(sizes, width: w)
        case 4:
            return quad(sizes, width: w)
        default:
            return many(sizes, width: w)
        }
    }

    /// One picture, at its own shape.
    ///
    /// The rule `TimelineLayoutEngine.mediaBox` already held — never upscaled
    /// past its own pixels, never taller than the cap, and both dimensions move
    /// together — with the width cap that was missing.
    static func singleBox(_ size: CGSize?, width: CGFloat) -> CGSize {
        TimelineLayoutEngine.mediaBox(
            width: size.map { Int($0.width) },
            height: size.map { Int($0.height) },
            availableWidth: min(width, maxWidth),
            maximumHeight: maxHeight
        )
    }

    /// The width a picture has to be decoded at to fill a cell it is cropped
    /// into.
    ///
    /// **Not the cell's width.** A landscape picture in a tall cell is scaled
    /// until its *height* covers, which makes it wider than the cell — asking
    /// for the cell's width would fetch a rendition that then has to be
    /// upscaled, and it would be blurry in exactly the cells that are most
    /// cropped. The painter and the prefetcher both read this one number, so
    /// they cannot look in different slots.
    static func coverWidth(_ size: CGSize?, in cell: CGSize) -> CGFloat {
        guard let ratio = ratio(size), cell.height > 0 else { return cell.width }
        return max(cell.width, cell.height * ratio).rounded()
    }

    // MARK: The shapes

    /// A picture's width ÷ height.
    ///
    /// **A missing one is 16:9 rather than nothing**, because every shape below
    /// but the first needs *some* height to size a row with, and a landscape
    /// guess is what the placeholder box has always been. A missing ratio is
    /// still a real state where it can be one — see `singleBox`, which reserves
    /// a 320 × 180 placeholder rather than guessing a shape.
    private static func ratio(_ size: CGSize?) -> CGFloat? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }

    private static func height(_ size: CGSize?, across width: CGFloat) -> CGFloat {
        width / (ratio(size) ?? 16.0 / 9)
    }

    private static func pair(_ sizes: [CGSize?], width w: CGFloat, y: CGFloat) -> [CGRect] {
        let side = ((w - gap) / 2).rounded()
        // `flex: 1` cells under `align-items: stretch`: the row is as tall as
        // the taller picture wants to be at that width, and no taller than the
        // cap. Both cells then take that height and crop to it.
        let wanted = sizes.prefix(2).map { height($0, across: side) }.max() ?? rowMaxHeight
        let h = min(rowMaxHeight, wanted).rounded()
        // The second cell takes whatever the rounding left, so the row is
        // exactly as wide as it was given rather than a point short of it.
        return [
            CGRect(x: 0, y: y, width: side, height: h),
            CGRect(x: side + gap, y: y, width: w - side - gap, height: h),
        ]
    }

    private static func trio(_ sizes: [CGSize?], width w: CGFloat) -> [CGRect] {
        let big = (2 * (w - gap) / 3).rounded()
        let small = w - big - gap
        // Two flex items side by side: the solo cell and the column of two. The
        // row is as tall as whichever wants more, capped at 350.
        let soloWants = height(sizes.first ?? nil, across: big)
        let duoWants = sizes.dropFirst().prefix(2)
            .reduce(gap) { $0 + height($1, across: small) }
        let h = min(maxHeight, max(soloWants, duoWants)).rounded()
        let short = ((h - gap) / 2).rounded()
        return [
            CGRect(x: 0, y: 0, width: big, height: h),
            CGRect(x: big + gap, y: 0, width: small, height: short),
            CGRect(x: big + gap, y: short + gap, width: small, height: h - short - gap),
        ]
    }

    private static func quad(_ sizes: [CGSize?], width w: CGFloat) -> [CGRect] {
        let side = ((w - gap) / 2).rounded()
        let trailing = w - side - gap
        // `repeat(2, minmax(0, 1fr))` equalises the two rows, and the whole
        // grid is capped at 350 — so each row is at most `rowHeight`.
        let wanted = sizes.prefix(4).map { height($0, across: side) }.max() ?? rowHeight
        let h = min(rowHeight, wanted).rounded()
        return [
            CGRect(x: 0, y: 0, width: side, height: h),
            CGRect(x: side + gap, y: 0, width: trailing, height: h),
            CGRect(x: 0, y: h + gap, width: side, height: h),
            CGRect(x: side + gap, y: h + gap, width: trailing, height: h),
        ]
    }

    /// Five and up: the remainder leads, then square rows of three.
    private static func many(_ sizes: [CGSize?], width w: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        frames.reserveCapacity(sizes.count)
        var y: CGFloat = 0
        var index = 0

        switch sizes.count % 3 {
        case 1:
            // **`.oneByOneGridMosaic` is `width: 100%`, not `fit-content`** —
            // so unlike a lone picture this one fills the column and is
            // cropped, and its cap is 280 rather than 350.
            let h = min(rowMaxHeight, height(sizes[0], across: w)).rounded()
            frames.append(CGRect(x: 0, y: 0, width: w, height: h))
            y = h + gap
            index = 1
        case 2:
            let row = pair(sizes, width: w, y: 0)
            frames.append(contentsOf: row)
            y = (row.first?.height ?? 0) + gap
            index = 2
        default:
            break
        }

        // `aspect-ratio: 1/1` on every cell of a three-row: square, always, and
        // nothing about the pictures changes it.
        let side = ((w - gap * 2) / 3).rounded()
        let trailing = w - side * 2 - gap * 2
        while index < sizes.count {
            frames.append(CGRect(x: 0, y: y, width: side, height: side))
            frames.append(CGRect(x: side + gap, y: y, width: side, height: side))
            frames.append(CGRect(x: side * 2 + gap * 2, y: y, width: trailing, height: side))
            y += side + gap
            index += 3
        }
        return frames
    }
}
