import SwiftUI

/// Tiles in rows as wide as the space allows, every row centred — the way
/// Messages lays out its pinned conversations, so two faces sit in the middle
/// of the list rather than at its left edge.
///
/// **As many columns as `minimumWidth` allows, each no wider than
/// `maximumWidth`**, `GridItem.adaptive`'s rule; a row that isn't full is
/// centred instead of left behind at the leading edge.
struct CenteredTileGrid: Layout {
    var minimumWidth: CGFloat
    var maximumWidth: CGFloat
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? CGFloat(subviews.count) * (minimumWidth + spacing) - spacing
        let metrics = metrics(width: width, count: subviews.count)
        let rowHeight = tallest(subviews, width: metrics.tile)
        let height = CGFloat(metrics.rows) * rowHeight + CGFloat(max(metrics.rows - 1, 0)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let metrics = metrics(width: bounds.width, count: subviews.count)
        let rowHeight = tallest(subviews, width: metrics.tile)
        for (index, subview) in subviews.enumerated() {
            let row = index / metrics.columns
            let column = index % metrics.columns
            // The last row holds what's left; it is centred like the others.
            let inRow = min(metrics.columns, subviews.count - row * metrics.columns)
            let rowWidth = CGFloat(inRow) * metrics.tile + CGFloat(inRow - 1) * spacing
            let x = bounds.minX + (bounds.width - rowWidth) / 2 + CGFloat(column) * (metrics.tile + spacing)
            let y = bounds.minY + CGFloat(row) * (rowHeight + lineSpacing)
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: metrics.tile, height: rowHeight)
            )
        }
    }

    private func metrics(width: CGFloat, count: Int) -> (columns: Int, tile: CGFloat, rows: Int) {
        let fit = Int(((width + spacing) / (minimumWidth + spacing)).rounded(.down))
        let columns = max(1, min(fit, count))
        let available = (width - CGFloat(max(fit, 1) - 1) * spacing) / CGFloat(max(fit, 1))
        let tile = min(maximumWidth, max(minimumWidth, available))
        let rows = (count + columns - 1) / columns
        return (columns, tile, rows)
    }

    private func tallest(_ subviews: Subviews, width: CGFloat) -> CGFloat {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
    }
}
