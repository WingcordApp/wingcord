import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The member list holding its place while the rows above it move, through the
/// real coordinator in a window.
///
/// **Alex's report**: scrolled far down a large server's list, the names slid
/// up and down a row at a time as the list changed above them.
@MainActor
@Suite("Member list anchoring")
struct MemberListAnchorTests {

    private func entry(_ id: UInt64) -> MemberEntry {
        MemberEntry(
            userID: UserID(rawValue: id), name: "member \(id)", monogram: "M",
            status: .online, isOnMobile: false, isBot: false
        )
    }

    /// One group of `count` rows whose members start at `firstID`, a heading
    /// of `leading` extra rows above it standing in for the groups that move.
    private func roster(leading: Int, count: Int = 400, loaded: ClosedRange<Int>, firstID: UInt64 = 1000) -> Roster {
        var roster = Roster(identity: "1:everyone", sections: [], members: [:], rowCount: 0)
        roster.sections = [
            RosterSection(key: .role(RoleID(rawValue: 7)), title: "Staff", countText: "\(leading)", index: 0, count: leading),
            RosterSection(key: .online, title: "Online", countText: "\(count)", index: leading + 1, count: count),
        ]
        roster.rowCount = leading + 1 + count + 1
        for row in loaded {
            roster.members[leading + 2 + row] = entry(firstID + UInt64(row))
        }
        return roster
    }

    private func mounted() -> (MemberListCoordinator, NSScrollView, NSWindow) {
        let coordinator = MemberListCoordinator()
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        return (coordinator, scrollView, window)
    }

    private func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }

    /// Where a member sits in the viewport.
    private func screenY(of id: UInt64, _ scrollView: NSScrollView) -> CGFloat? {
        guard let canvas = scrollView.documentView?.subviews.compactMap({ $0 as? MemberListCanvas }).first,
              let index = canvas.roster.members.first(where: { $0.value.userID.rawValue == id })?.key
        else { return nil }
        return canvas.rowFrame(at: index).minY - scrollView.contentView.bounds.minY
    }

    @Test("Rows added above keep the names on screen still")
    func rowsAddedAbove() throws {
        let (coordinator, scrollView, window) = mounted()
        coordinator.update(roster: roster(leading: 10, loaded: 150...250), presentationRevision: 0, topInset: 0)
        settle()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200 * MemberRowGeometry.rowHeight))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle()
        let before = try #require(screenY(of: 1200, scrollView))

        // Three people came online above.
        coordinator.update(roster: roster(leading: 13, loaded: 150...250), presentationRevision: 0, topInset: 0)
        settle()

        let after = try #require(screenY(of: 1200, scrollView))
        #expect(abs(after - before) < 0.5)
        withExtendedLifetime((coordinator, window)) {}
    }

    @Test("One member leaving the screen does not drag the view with them")
    func oneMemberMovesFar() throws {
        let (coordinator, scrollView, window) = mounted()
        coordinator.update(roster: roster(leading: 10, loaded: 150...250), presentationRevision: 0, topInset: 0)
        settle()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200 * MemberRowGeometry.rowHeight))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle()
        let before = try #require(screenY(of: 1200, scrollView))

        // One person above came online, and member 1195 — on screen — went to
        // the far end of the list.
        var next = roster(leading: 11, loaded: 150...250)
        let moved = try #require(next.members.first { $0.value.userID.rawValue == 1195 }?.key)
        next.members[moved] = nil
        next.members[next.rowCount - 1] = entry(1195)
        coordinator.update(roster: next, presentationRevision: 0, topInset: 0)
        settle()

        let after = try #require(screenY(of: 1200, scrollView))
        #expect(abs(after - before) < 0.5)
        withExtendedLifetime((coordinator, window)) {}
    }

    @Test("At the top, rows arriving above are shown, not skipped")
    func topIsNotHeld() throws {
        let (coordinator, scrollView, window) = mounted()
        coordinator.update(roster: roster(leading: 2, loaded: 0...40), presentationRevision: 0, topInset: 0)
        settle()
        let start = scrollView.contentView.bounds.minY
        coordinator.update(roster: roster(leading: 5, loaded: 0...40), presentationRevision: 0, topInset: 0)
        settle()
        #expect(abs(scrollView.contentView.bounds.minY - start) < 0.5)
        withExtendedLifetime((coordinator, window)) {}
    }
}
