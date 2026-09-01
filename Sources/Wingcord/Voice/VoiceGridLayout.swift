import CoreGraphics
import Foundation

// MARK: - Where the tiles go
//
// A pure value, because it is arithmetic and because a grid that reshuffles is
// the single most obvious defect a call surface can have. Solved once and
// checked against a table, rather than trusted to a `LazyVGrid` whose column
// count is a guess.
//
// **The right answer is the arrangement that makes the tiles biggest**, not the
// one nearest a square. Four people in a wide window belong in one row of four,
// not in a 2×2 that wastes half the width; four in a tall one belong in a
// column. So every row count from one to the participant count is tried and the
// largest resulting tile wins — which is a loop of at most a few dozen
// comparisons, run when somebody joins or the window resizes and at no other
// time.
struct VoiceGridLayout: Equatable, Sendable {
    /// How many tiles fit across.
    var columns: Int
    var rows: Int
    var tileSize: CGSize

    /// The aspect a tile is drawn at. 16:9, so a camera fills its tile and a
    /// face-only tile is the same shape as the one beside it that has a camera
    /// — a grid whose tiles change shape when somebody turns a camera on is a
    /// grid that reflows for a reason nobody asked for.
    static let aspect: CGFloat = 16.0 / 9.0
    static let spacing: CGFloat = Spacing.snug
    /// Below this a tile shows a face and a name and nothing else fits.
    static let minimumTileWidth: CGFloat = 120

    static func solve(count: Int, in size: CGSize) -> VoiceGridLayout {
        guard count > 0, size.width > 0, size.height > 0 else {
            return VoiceGridLayout(columns: 1, rows: 1, tileSize: .zero)
        }

        var best = VoiceGridLayout(columns: count, rows: 1, tileSize: .zero)
        var bestArea: CGFloat = -1

        for rows in 1...count {
            let columns = Int(ceil(Double(count) / Double(rows)))
            let availableWidth = size.width - spacing * CGFloat(columns - 1)
            let availableHeight = size.height - spacing * CGFloat(rows - 1)
            guard availableWidth > 0, availableHeight > 0 else { continue }

            let widthPerTile = availableWidth / CGFloat(columns)
            let heightPerTile = availableHeight / CGFloat(rows)
            // Fit the tile's aspect inside the cell, whichever way binds.
            let width = min(widthPerTile, heightPerTile * aspect)
            let height = width / aspect
            let area = width * height
            guard area > bestArea else { continue }
            bestArea = area
            best = VoiceGridLayout(
                columns: columns,
                rows: rows,
                tileSize: CGSize(width: width, height: height)
            )
        }
        return best
    }

    /// The rows, as index ranges, so a view can lay them out without arithmetic
    /// of its own.
    func rowRanges(count: Int) -> [Range<Int>] {
        guard columns > 0, count > 0 else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            let end = min(start + columns, count)
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }
}

/// The stage, when one person fills it and the rest are a strip.
///
/// The strip is along the **bottom** rather than the side: a shared screen is
/// wider than it is tall, so the space left over by fitting one is a band under
/// it, and putting the strip beside it instead throws that band away and takes
/// width off the thing everybody is looking at.
struct VoiceSpotlightLayout: Equatable, Sendable {
    var stage: CGRect
    var strip: CGRect
    var chipSize: CGSize

    static let chipWidth: CGFloat = 132
    static let stripGap: CGFloat = Spacing.snug

    static func solve(others: Int, in size: CGSize) -> VoiceSpotlightLayout {
        guard others > 0 else {
            return VoiceSpotlightLayout(
                stage: CGRect(origin: .zero, size: size),
                strip: .zero,
                chipSize: .zero
            )
        }
        let chipHeight = chipWidth / VoiceGridLayout.aspect
        // A strip that takes more than a quarter of the height stops being a
        // strip. On a short window the chips shrink instead of the stage.
        let stripHeight = min(chipHeight, size.height * 0.25)
        let stageHeight = max(0, size.height - stripHeight - stripGap)
        return VoiceSpotlightLayout(
            stage: CGRect(x: 0, y: 0, width: size.width, height: stageHeight),
            strip: CGRect(
                x: 0, y: stageHeight + stripGap,
                width: size.width, height: stripHeight
            ),
            chipSize: CGSize(width: stripHeight * VoiceGridLayout.aspect, height: stripHeight)
        )
    }
}
