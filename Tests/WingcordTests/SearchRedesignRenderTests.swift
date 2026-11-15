import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// The search panel's page pill and filters sheet, drawn — with
/// `WINGCORD_RENDER_DIR` set — and held to the widths that broke before.
@MainActor
@Suite("Search redesign render")
struct SearchRedesignRenderTests {

    @Test("The page pill fits a narrow column at any page count")
    func pagePill() throws {
        for (page, count) in [(1, 69), (37, 400), (2, 2)] {
            let pill = SearchPagePill(currentPage: page, pageCount: count, isLoading: false, go: { _ in })
                .environment(\.colorScheme, .dark)
            let result = try SurfaceRender.render(pill, named: "search-page-pill-\(count)")
            // One line, never wrapped: the capsule and the renderer's margin.
            #expect(result.size.height <= 36 + 24 + 1, "\(page) of \(count)")
            #expect(result.size.width < 260, "\(page) of \(count)")
        }
    }

    @Test("The filters sheet, drawn")
    func sheet() throws {
        var query = MessageSearchQuery(scope: .guild(GuildID(rawValue: 1)))
        query.authorIDs = [UserID(rawValue: 7)]
        query.has = [.image, .link]
        query.dates = [.after(Date(timeIntervalSince1970: 1_790_000_000))]
        query.isPinned = true
        let people = [
            SearchFilterOption(id: 7, title: "alex", detail: "alex", monogram: "A"),
            SearchFilterOption(id: 8, title: "Blåhaj", detail: "blahaj", monogram: "B"),
        ]
        let sheet = SearchFiltersSheet(query: query, people: people, channels: [], apply: { _ in }, dismiss: {})
            .background(Color(white: 0.16))
            .environment(\.colorScheme, .dark)
        // **In a window**: a scroll view draws nothing for a hosting view that
        // has none, which is what the plain renderer gives it.
        let host = NSHostingView(rootView: sheet)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 480, height: 700)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("search-filters-sheet.png"))
        }
        withExtendedLifetime(window) {}
    }

    @Test("Go to Page fits its popover, inset from the corners")
    func pageJump() throws {
        let jump = SearchPageJump(pageCount: 69, go: { _ in })
            .background(Color(white: 0.16))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: jump)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        #expect(host.fittingSize.width == SearchPageJump.width)
        // The title, its line, and the 36-point row, with 16 around: no more.
        #expect(host.fittingSize.height < 130)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("search-page-jump.png"))
        }
        withExtendedLifetime(window) {}
    }

    @Test("Add's flyout: a field over the people, the chosen ones ticked")
    func pickFlyout() throws {
        let people = [
            SearchFilterOption(id: 7, title: "alex", detail: "alex", monogram: "A"),
            SearchFilterOption(id: 8, title: "Blåhaj", detail: "blahaj", monogram: "B"),
            SearchFilterOption(id: 9, title: "Voltcast", detail: "voltcast", monogram: "V"),
        ]
        let flyout = SearchPickFlyout(prompt: "Search members", options: people, chosen: [8], emptyText: "Nobody to add", toggle: { _ in })
            .background(Color(white: 0.16))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: flyout)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        // Three rows of 38 under the 36 pt field: nothing wrapped or cut.
        #expect(host.fittingSize.width == 300)
        #expect(host.fittingSize.height < 36 + 3 * 40 + 60)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("search-pick-flyout.png"))
        }
        withExtendedLifetime(window) {}
    }
}
