import AppKit
import SwiftUI
import Testing
@testable import Wingcord

/// The toolbar row.
///
/// **The bug this pins:** the layout needed exactly three subviews and returned
/// without placing anything otherwise, and a title with nothing to say contributes
/// none. So on Discover, the inbox and search sat mid-page (Alex's images 57, 58).
@MainActor
@Suite("The toolbar row")
struct HeaderBarLayoutTests {

    /// Where each slot's view landed in a row this wide.
    private func frames(
        width: CGFloat,
        center: CGFloat?,
        wrapsCenter: Bool = false,
        reservedTrailing: CGFloat = 0
    ) async throws -> (leading: CGRect, center: CGRect?, trailing: CGRect, height: CGFloat) {
        var leading = CGRect.zero
        var middle: CGRect?
        var trailing = CGRect.zero
        func box(_ side: CGFloat, _ report: @escaping (CGRect) -> Void) -> some View {
            Color.clear.frame(width: side, height: 30)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report($0) }
        }
        let row = HeaderBarLayout(rowHeight: 50, wrapsCenter: wrapsCenter, reservedTrailing: reservedTrailing) {
            box(100) { leading = $0 }.layoutValue(key: HeaderSlotKey.self, value: .leading)
            if let center {
                box(center) { middle = $0 }.layoutValue(key: HeaderSlotKey.self, value: .center)
            }
            box(60) { trailing = $0 }.layoutValue(key: HeaderSlotKey.self, value: .trailing)
        }
        .frame(width: width)
        let host = NSHostingView(rootView: row)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        // Geometry reports after the pass that measured it.
        try await Task.sleep(for: .milliseconds(50))
        return (leading, middle, trailing, host.fittingSize.height)
    }

    @Test("With nothing in the middle, the ends still go to the ends")
    func noTitle() async throws {
        let row = try await frames(width: 600, center: nil)
        #expect(row.leading.minX == 0)
        #expect(row.trailing.maxX == 600)
    }

    @Test("The middle sits on the row's midline while it fits there")
    func midline() async throws {
        let row = try await frames(width: 600, center: 200)
        #expect(row.center?.midX == 300)
        #expect(row.height == 50)
    }

    @Test("It slides between its neighbours rather than sit on one")
    func slides() async throws {
        let row = try await frames(width: 500, center: 300)
        let center = try #require(row.center)
        #expect(center.minX >= row.leading.maxX)
        #expect(center.maxX <= row.trailing.minX)
        #expect(row.height == 50)
    }

    @Test("Where one row can't hold it, the middle takes a row of its own")
    func wraps() async throws {
        let row = try await frames(width: 400, center: 300, wrapsCenter: true)
        let center = try #require(row.center)
        #expect(center.midX == 200)
        #expect(center.minY >= row.trailing.maxY)
        #expect(row.height > 50)
    }

    @Test("The reserve decides that, so a field opening doesn't move the page")
    func reservedTrailing() async throws {
        let fits = try await frames(width: 700, center: 300, wrapsCenter: true)
        #expect(fits.height == 50)
        let reserved = try await frames(width: 700, center: 300, wrapsCenter: true, reservedTrailing: 320)
        #expect(reserved.height > 50)
    }
}
