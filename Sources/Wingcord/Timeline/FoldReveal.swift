import CoreGraphics
import Foundation

/// How a fold's messages come out of its line and go back into it.
///
/// **A zip, drawn by the canvas.** Pressing Show puts the folded messages back
/// as rows; each then arrives a beat after the one above it, fading up while it
/// settles the last few points down from the line it came out of. Hide runs
/// the other way, from the foot up, and the rows are taken away when the last
/// has gone — so the line closes over them rather than the page jumping shut.
///
/// Only an alpha and an offset per row: nothing is laid out again, nothing is
/// hosted, and a fold of two hundred messages costs what a fold of eight does
/// because the stagger stops counting at eight.
nonisolated enum FoldReveal {
    /// Between one row starting and the next.
    static let stagger = 0.03
    /// Rows past this many arrive with the last of them.
    static let staggeredRows = 8
    /// One row's own arrival, and its departure — leaving is quicker than
    /// arriving, as it is for everything that is being dismissed.
    static let arrival = 0.26
    static let departure = 0.13
    /// How far above its place a row starts.
    static let rise: CGFloat = 10

    struct Pose: Equatable {
        var alpha: CGFloat
        var offset: CGFloat

        static let rest = Pose(alpha: 1, offset: 0)
    }

    /// How long the whole fold takes.
    static func duration(rows: Int, closing: Bool) -> Double {
        let steps = Double(min(max(rows - 1, 0), staggeredRows))
        return closing ? departure + steps * stagger / 2 : arrival + steps * stagger
    }

    /// Where the row `order` places down a fold of `rows` is, `elapsed`
    /// seconds in.
    static func pose(order: Int, of rows: Int, elapsed: Double, closing: Bool) -> Pose {
        if closing {
            // From the foot up, at half the stagger.
            let fromFoot = min(max(rows - 1 - order, 0), staggeredRows)
            let progress = unit((elapsed - Double(fromFoot) * stagger / 2) / departure)
            return Pose(alpha: 1 - progress, offset: -rise * 0.6 * progress)
        }
        let progress = unit((elapsed - Double(min(order, staggeredRows)) * stagger) / arrival)
        // Ease-out cubic: fast out of the line, no overshoot — a row of text
        // that bounces is a row that is hard to start reading.
        let eased = 1 - pow(1 - progress, 3)
        return Pose(alpha: eased, offset: -rise * (1 - eased))
    }

    private static func unit(_ value: Double) -> CGFloat {
        CGFloat(min(1, max(0, value)))
    }
}
