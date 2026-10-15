import CoreGraphics
import Foundation

// MARK: - Grid metrics
//
// The sizing rule is the opposite of how a grid is normally written, and it is
// the reason a sticker is the same size in a narrow window and a wide one.
//
// The usual approach fixes a column count and lets the items resize, or uses an
// adaptive column and lets the framework decide both. This does neither. The
// item size is a **target the design has already settled on**; the layout
// derives how many of those fit, and spends the entire remainder on the gaps:
//
//   1. columns  — how many target-sized items fit at the minimum gap, floored
//                 so a narrow column still reads as a grid rather than a list.
//   2. itemSize — the target, unless that many genuinely do not fit, in which
//                 case they shrink to the largest size that does. Above the
//                 target an item never grows.
//   3. spacing  — whatever width is left, split evenly between the gaps.
//
// Step 3 is why this cannot be an adaptive `LazyVGrid`: adaptive columns spend
// leftover width by growing the items, which is precisely what is being avoided.

nonisolated struct ExpressionGridMetrics: Equatable, Sendable {
    var itemSize: CGFloat
    var spacing: CGFloat
    var columns: Int

    /// A section heading's row height.
    static let headerHeight: CGFloat = 26
    /// Between rows inside a section.
    static let rowSpacing: CGFloat = 6
    /// Inset from the container's leading and trailing edges.
    static let horizontalInset: CGFloat = Spacing.snug

    static func resolve(
        width: CGFloat,
        target: CGFloat,
        minimumSpacing: CGFloat,
        minimumColumns: Int
    ) -> ExpressionGridMetrics {
        let available = max(width - horizontalInset * 2, 1)

        // How many target-sized items fit, counting the gap that follows each
        // and then reclaiming the trailing gap that does not exist.
        let fitting = Int((available + minimumSpacing) / (target + minimumSpacing))
        let columns = max(minimumColumns, fitting)

        let widthIfMinimallySpaced = available - minimumSpacing * CGFloat(columns - 1)
        let proposed = (widthIfMinimallySpaced / CGFloat(columns)).rounded(.down)
        let itemSize = max(min(proposed, target), 1)

        let spacing: CGFloat = columns > 1
            ? max(((available - itemSize * CGFloat(columns)) / CGFloat(columns - 1)).rounded(.down), 0)
            : 0

        return ExpressionGridMetrics(itemSize: itemSize, spacing: spacing, columns: columns)
    }

    /// The metrics a mode wants at a given width.
    static func resolve(for mode: ExpressionMode, width: CGFloat) -> ExpressionGridMetrics {
        switch mode {
        case .emoji:
            // Discord's: a 40-point emoji in a 48-point cell
            // (`--custom-emoji-picker-constants-emoji-size-medium`, 4 of
            // padding a side) — dense, because emoji are scanned in bulk
            // rather than looked at one at a time.
            resolve(width: width, target: 40, minimumSpacing: 8, minimumColumns: 6)
        case .stickers:
            // Large enough to read as a picture, grown with the panel.
            resolve(width: width, target: 88, minimumSpacing: 10, minimumColumns: 3)
        case .gifs:
            // Not drawn by this layout — the GIF tab is a masonry of variable
            // heights, which is a different problem. Answered anyway so the
            // type is total.
            resolve(width: width, target: 150, minimumSpacing: 8, minimumColumns: 2)
        }
    }
}

// MARK: - Layout

/// Where every heading and every cell sits, as arithmetic over fixed heights.
///
/// **Flattened into rows, exactly like the member list.** A row is a heading or
/// a run of up to `columns` cells, every row's height is known without measuring
/// anything, and the offsets are therefore a running sum. That is what makes
/// hit-testing a binary search and repainting a dirty rect rather than a pass
/// over twenty thousand items.
nonisolated struct ExpressionGridLayout: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        /// The section this row belongs to.
        var section: Int
        /// Nil for a heading; otherwise the index of the first item in the run.
        var firstItem: Int?
        var count: Int
        var height: CGFloat

        var isHeader: Bool { firstItem == nil }
    }

    private(set) var rows: [Row] = []
    /// One more entry than `rows`: the last is the content height.
    private(set) var offsets: [CGFloat] = [0]
    private(set) var metrics: ExpressionGridMetrics
    /// The row index each section's heading landed at, for the rail's jump.
    private(set) var headerRows: [Int] = []

    var contentHeight: CGFloat { offsets[offsets.count - 1] }

    init(sections: [ExpressionSection], metrics: ExpressionGridMetrics, showsHeaders: Bool = true) {
        self.metrics = metrics

        var running: CGFloat = 0
        rows.reserveCapacity(sections.count * 4)
        offsets.reserveCapacity(sections.count * 4 + 1)
        headerRows.reserveCapacity(sections.count)

        for (index, section) in sections.enumerated() where !section.items.isEmpty {
            headerRows.append(rows.count)
            if showsHeaders {
                rows.append(Row(section: index, firstItem: nil, count: 0, height: Self.headerHeight))
                running += Self.headerHeight
                offsets.append(running)
            }

            let rowHeight = metrics.itemSize + ExpressionGridMetrics.rowSpacing
            var item = 0
            while item < section.items.count {
                let count = min(metrics.columns, section.items.count - item)
                rows.append(Row(section: index, firstItem: item, count: count, height: rowHeight))
                running += rowHeight
                offsets.append(running)
                item += count
            }
        }
        // A trailing breath, so the last row does not sit against the bottom
        // edge under the floating mode bar.
        running += Spacing.base
        offsets[offsets.count - 1] = running
    }

    static var headerHeight: CGFloat { ExpressionGridMetrics.headerHeight }

    /// The row containing a vertical offset, clamped to the ends.
    func rowIndex(at y: CGFloat) -> Int? {
        guard !rows.isEmpty else { return nil }
        guard y >= 0 else { return 0 }
        guard y < contentHeight else { return rows.count - 1 }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func rowFrame(at index: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: offsets[index], width: width, height: rows[index].height)
    }

    /// The rows intersecting a rect, which is what a repaint walks.
    func rowRange(in rect: CGRect) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let first = rowIndex(at: rect.minY) ?? 0
        var last = first
        while last < rows.count, offsets[last] < rect.maxY { last += 1 }
        return first..<max(first, last)
    }

    /// Where one cell in a row is drawn.
    func itemFrame(row: Int, column: Int) -> CGRect {
        let x = ExpressionGridMetrics.horizontalInset
            + CGFloat(column) * (metrics.itemSize + metrics.spacing)
        return CGRect(
            x: x,
            y: offsets[row],
            width: metrics.itemSize,
            height: metrics.itemSize
        )
    }

    /// The item under a point, as a section and an index into it.
    ///
    /// The gap between cells is deliberately **not** part of any cell: a click
    /// that lands between two emoji picks neither, which is the honest answer
    /// and the one that stops a mis-click sending the wrong thing.
    func item(at point: CGPoint) -> (section: Int, item: Int)? {
        guard let row = rowIndex(at: point.y),
              let firstItem = rows[row].firstItem,
              point.y - offsets[row] <= metrics.itemSize
        else { return nil }

        let stride = metrics.itemSize + metrics.spacing
        let x = point.x - ExpressionGridMetrics.horizontalInset
        guard x >= 0, stride > 0 else { return nil }

        let column = Int(x / stride)
        guard column < rows[row].count,
              x - CGFloat(column) * stride <= metrics.itemSize
        else { return nil }

        return (rows[row].section, firstItem + column)
    }

    /// The vertical offset a section's heading sits at, for the rail's jump.
    func offset(ofSection section: Int) -> CGFloat? {
        guard section < headerRows.count else { return nil }
        return offsets[headerRows[section]]
    }

    /// Which section is at the top of a viewport, so the rail can follow the
    /// grid rather than only leading it.
    func section(atTopOf rect: CGRect) -> Int? {
        guard let row = rowIndex(at: rect.minY) else { return nil }
        return rows[row].section
    }

    /// The heading to hold at `pinLine`, and the height to hold it at.
    ///
    /// Sticky headers, and both halves matter:
    ///
    ///  - a heading never rises **above** its natural position, so a section
    ///    scrolled to its own top shows its heading where it actually is — and
    ///    so the pinned copy coincides exactly with the canvas's own at the
    ///    moment one takes over from the other;
    ///  - the next section's heading **pushes** this one out, so the two are
    ///    never at the same height and the change reads as one shoving the
    ///    other rather than as a cross-fade.
    func pinnedHeader(at pinLine: CGFloat) -> (section: Int, y: CGFloat)? {
        guard let row = rowIndex(at: pinLine) else { return nil }
        let section = rows[row].section
        guard section < headerRows.count else { return nil }

        var y = max(offsets[headerRows[section]], pinLine)
        if section + 1 < headerRows.count {
            y = min(y, offsets[headerRows[section + 1]] - Self.headerHeight)
        }
        return (section, y)
    }
}
