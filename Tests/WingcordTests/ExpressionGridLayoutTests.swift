import CoreGraphics
import Testing
@testable import Wingcord

/// The picker's grid geometry.
///
/// **`itemsNeverGrowPastTheirTarget` is the one that matters.** It is the whole
/// difference between this layout and an adaptive grid, it is invisible in a
/// screenshot of any single window size, and getting it wrong makes an emoji a
/// different size in a narrow window and a wide one.
@Suite("Expression grid layout")
struct ExpressionGridLayoutTests {

    private func section(_ id: String, count: Int) -> ExpressionSection {
        ExpressionSection(
            id: id,
            title: id,
            badge: .glyph("😀"),
            items: (0..<count).map {
                ExpressionItem(id: "\(id).\($0)", art: .glyph("😀"), name: "e\($0)", pick: .insert("😀"))
            }
        )
    }

    // MARK: Metrics

    @Test("Leftover width goes to the gaps, never to the items")
    func itemsNeverGrowPastTheirTarget() {
        // A width chosen so the items cannot divide it evenly.
        let metrics = ExpressionGridMetrics.resolve(
            width: 500, target: 32, minimumSpacing: 6, minimumColumns: 6
        )
        #expect(metrics.itemSize == 32)
        #expect(metrics.spacing >= 6)

        // Twice the width: more columns, same item size.
        let wide = ExpressionGridMetrics.resolve(
            width: 1000, target: 32, minimumSpacing: 6, minimumColumns: 6
        )
        #expect(wide.itemSize == metrics.itemSize)
        #expect(wide.columns > metrics.columns)
    }

    @Test("Items shrink only when the target genuinely does not fit")
    func itemsShrinkAtTheFloor() {
        // Six columns forced into a width that cannot hold six 32pt items.
        let metrics = ExpressionGridMetrics.resolve(
            width: 140, target: 32, minimumSpacing: 6, minimumColumns: 6
        )
        #expect(metrics.columns == 6)
        #expect(metrics.itemSize < 32)
        #expect(metrics.itemSize >= 1)
    }

    @Test("A row of items always fits the width it was resolved for")
    func rowsFitTheirWidth() {
        for width in stride(from: 180.0, through: 900.0, by: 7.0) {
            let metrics = ExpressionGridMetrics.resolve(
                width: width, target: 32, minimumSpacing: 6, minimumColumns: 6
            )
            let used = metrics.itemSize * CGFloat(metrics.columns)
                + metrics.spacing * CGFloat(metrics.columns - 1)
            let available = width - ExpressionGridMetrics.horizontalInset * 2
            #expect(used <= available + 1, "overflowed at \(width)")
        }
    }

    // MARK: Layout

    @Test("Every section gets a heading and enough rows to hold it")
    func sectionsAreLaidOut() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(
            sections: [section("a", count: 20), section("b", count: 3)],
            metrics: metrics
        )
        // 1 heading + 3 rows, then 1 heading + 1 row.
        #expect(layout.rows.count == 6)
        #expect(layout.rows[0].isHeader)
        #expect(layout.rows[4].isHeader)
        #expect(layout.contentHeight > 0)
        #expect(layout.offsets.count == layout.rows.count + 1)
    }

    @Test("An empty section takes no space at all")
    func emptySectionsAreDropped() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(
            sections: [section("a", count: 0), section("b", count: 1)],
            metrics: metrics
        )
        #expect(layout.rows.allSatisfy { $0.section == 1 })
    }

    @Test("Hit-testing finds the cell under a point")
    func hitTestingFindsCells() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(sections: [section("a", count: 20)], metrics: metrics)

        // The centre of the first cell of the first item row.
        let frame = layout.itemFrame(row: 1, column: 0)
        let hit = layout.item(at: CGPoint(x: frame.midX, y: frame.midY))
        #expect(hit?.section == 0)
        #expect(hit?.item == 0)

        let third = layout.itemFrame(row: 1, column: 2)
        #expect(layout.item(at: CGPoint(x: third.midX, y: third.midY))?.item == 2)
    }

    /// A click between two emoji must pick neither. The alternative — snapping
    /// to the nearest — sends the wrong emoji on a near miss, which is worse
    /// than doing nothing.
    @Test("The gap between cells belongs to no cell")
    func gapsAreNotClickable() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(sections: [section("a", count: 20)], metrics: metrics)
        let first = layout.itemFrame(row: 1, column: 0)

        let inGap = CGPoint(x: first.maxX + 3, y: first.midY)
        #expect(layout.item(at: inGap) == nil)

        // And the row spacing below a row belongs to no cell either.
        let belowRow = CGPoint(x: first.midX, y: first.maxY + 3)
        #expect(layout.item(at: belowRow) == nil)
    }

    @Test("A heading is never mistaken for a cell")
    func headingsAreNotClickable() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(sections: [section("a", count: 20)], metrics: metrics)
        #expect(layout.item(at: CGPoint(x: 20, y: 4)) == nil)
    }

    @Test("A point past the last row picks nothing")
    func outOfBoundsPicksNothing() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(sections: [section("a", count: 4)], metrics: metrics)
        #expect(layout.item(at: CGPoint(x: 20, y: layout.contentHeight + 40)) == nil)
        #expect(layout.item(at: CGPoint(x: 5_000, y: 40)) == nil)
    }

    @Test("The rail can find a section, and the grid can say which is on top")
    func sectionJumpsResolve() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(
            sections: [section("a", count: 20), section("b", count: 20)],
            metrics: metrics
        )
        let offset = layout.offset(ofSection: 1)
        #expect(offset != nil)

        let viewport = CGRect(x: 0, y: offset ?? 0, width: 300, height: 200)
        #expect(layout.section(atTopOf: viewport) == 1)
        #expect(layout.offset(ofSection: 9) == nil)
    }

    // MARK: Sticky headings

    /// The pinned copy and the canvas's own have to coincide at the hand-off,
    /// or the heading visibly jumps as one takes over from the other.
    @Test("A heading never rises above its natural position")
    func headingHoldsAtItsOwnPosition() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(
            sections: [section("a", count: 40), section("b", count: 40)],
            metrics: metrics
        )
        // Pinned above the first heading: it stays where it is rather than
        // being dragged up to the line.
        let above = layout.pinnedHeader(at: -50)
        #expect(above?.section == 0)
        #expect(above?.y == 0)

        // Scrolled into the section: it holds at the line.
        let held = layout.pinnedHeader(at: 120)
        #expect(held?.section == 0)
        #expect(held?.y == 120)
    }

    @Test("The next heading pushes the last one out")
    func headingsPushEachOther() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(
            sections: [section("a", count: 40), section("b", count: 40)],
            metrics: metrics
        )
        let secondHeading = layout.offset(ofSection: 1) ?? 0
        let headerHeight = ExpressionGridLayout.headerHeight

        // A pin line one point before the next heading arrives: the first is
        // already being shoved, so it sits ABOVE the line.
        let pinLine = secondHeading - headerHeight + 1
        let pushed = layout.pinnedHeader(at: pinLine)
        #expect(pushed?.section == 0)
        #expect((pushed?.y ?? 0) < pinLine)
        #expect(pushed?.y == secondHeading - headerHeight)

        // And the moment the next one reaches the line, it takes over —
        // exactly where the pushed one left off, with no gap between them.
        let after = layout.pinnedHeader(at: secondHeading)
        #expect(after?.section == 1)
        #expect(after?.y == secondHeading)
    }

    /// Walked in half-point steps, because a heading that jumps by a point at
    /// the hand-off is the one artefact this arithmetic exists to prevent and
    /// the one a screenshot of either end cannot show.
    @Test("The pinned heading never moves backwards as the scroll advances")
    func pinnedHeadingIsMonotonic() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(
            sections: [section("a", count: 30), section("b", count: 30), section("c", count: 30)],
            metrics: metrics
        )
        var previous = -CGFloat.infinity
        var pinLine: CGFloat = 0
        var regressions = 0
        while pinLine < layout.contentHeight {
            if let pinned = layout.pinnedHeader(at: pinLine) {
                if pinned.y < previous - 0.001 { regressions += 1 }
                previous = pinned.y
            }
            pinLine += 0.5
        }
        #expect(regressions == 0)
    }

    @Test("The last section has nothing to push it")
    func lastHeadingIsNeverPushed() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(sections: [section("a", count: 30)], metrics: metrics)
        let deep = layout.contentHeight - 1
        let pinned = layout.pinnedHeader(at: deep)
        #expect(pinned?.section == 0)
        #expect(pinned?.y == deep)
    }

    @Test("Only the rows a repaint touches are walked")
    func rowRangeIsBounded() {
        let metrics = ExpressionGridMetrics(itemSize: 32, spacing: 6, columns: 8)
        let layout = ExpressionGridLayout(sections: [section("a", count: 800)], metrics: metrics)
        let range = layout.rowRange(in: CGRect(x: 0, y: 400, width: 300, height: 200))
        #expect(!range.isEmpty)
        #expect(range.count < 12)
        #expect(range.upperBound <= layout.rows.count)
    }
}
