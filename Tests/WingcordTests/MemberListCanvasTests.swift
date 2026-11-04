import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The drawn list, through real mouse events in a real window: anything hover- or
/// click-shaped is only known from running it. See `CanvasAnchorTests`.
@MainActor
@Suite("Member list canvas")
struct MemberListCanvasTests {

    private func person(_ id: UInt64, _ name: String, art: Bool = false) -> MemberEntry {
        var entry = MemberEntry(
            userID: UserID(rawValue: id), name: name, monogram: "?",
            status: .online, isOnMobile: false, isBot: false
        )
        if art { entry.art = .placeholder(.game) }
        return entry
    }

    /// Admin (rows 1, 2), Online (rows 4, 5).
    private func roster(foldingOnline: Bool = false) -> Roster {
        var roster = Roster(identity: "list", sections: [], members: [:], rowCount: 0)
        roster.sections = [
            RosterSection(key: .role(RoleID(rawValue: 7)), title: "Admin", countText: "2", index: 0, count: 2),
            RosterSection(
                key: .online, title: "Online", countText: "2", index: 3,
                count: foldingOnline ? 0 : 2, isCollapsed: foldingOnline
            ),
        ]
        roster.members = [1: person(1, "ada"), 2: person(2, "bo", art: true)]
        if !foldingOnline {
            roster.members[4] = person(3, "cy")
            roster.members[5] = person(4, "di")
        }
        roster.rowCount = foldingOnline ? 4 : 6
        return roster
    }

    private final class Harness {
        let coordinator = MemberListCoordinator()
        let scrollView: NSScrollView
        let window: NSWindow
        var canvas: MemberListCanvas {
            scrollView.documentView!.subviews.compactMap { $0 as? MemberListCanvas }.first!
        }

        init() {
            scrollView = coordinator.makeScrollView()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 288, height: 700),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = scrollView
        }

        /// A point in the canvas's own space, as an event in the window's.
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: canvas.convert(point, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }
    }

    private func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }

    /// Lets a report scheduled on the main queue run. **Not `settle()`**: a test on
    /// the main actor is itself a block on that queue, and a nested run loop doesn't
    /// drain the queue it's standing in. Suspending does.
    private func reported() async { try? await Task.sleep(for: .milliseconds(40)) }

    private func mounted(_ roster: Roster) -> Harness {
        let harness = Harness()
        harness.coordinator.update(roster: roster, presentationRevision: 0, topInset: 0)
        settle()
        return harness
    }

    @Test("A heading's click folds it, and a row's opens the person")
    func clicks() {
        let harness = mounted(roster())
        var toggled: [MemberSectionKey] = []
        var opened: [UserID] = []
        harness.coordinator.toggleSection = { toggled.append($0) }
        harness.coordinator.openProfile = { userID, _ in opened.append(userID) }

        let heading = harness.canvas.rowFrame(at: 3)
        harness.canvas.mouseDown(with: harness.event(.leftMouseDown, at: CGPoint(x: 60, y: heading.midY)))
        #expect(toggled == [.online])
        #expect(opened.isEmpty)

        let row = harness.canvas.rowFrame(at: 1)
        harness.canvas.mouseDown(with: harness.event(.leftMouseDown, at: CGPoint(x: 60, y: row.midY)))
        #expect(opened == [UserID(rawValue: 1)])
        withExtendedLifetime(harness) {}
    }

    /// `rowIndex` clamps, so the air under the last row answered with that row.
    @Test("A click in the air under the list opens nobody")
    func airUnderTheList() {
        let harness = mounted(roster())
        var opened: [UserID] = []
        harness.coordinator.openProfile = { userID, _ in opened.append(userID) }
        let last = harness.canvas.rowFrame(at: 5)
        harness.canvas.mouseDown(with: harness.event(.leftMouseDown, at: CGPoint(x: 60, y: last.maxY + 30)))
        #expect(opened.isEmpty)
        withExtendedLifetime(harness) {}
    }

    @Test("A heading that can't fold doesn't")
    func cantFold() {
        var roster = roster()
        roster.sections[0].canCollapse = false
        let harness = mounted(roster)
        var toggled: [MemberSectionKey] = []
        harness.coordinator.toggleSection = { toggled.append($0) }
        let heading = harness.canvas.rowFrame(at: 0)
        harness.canvas.mouseDown(with: harness.event(.leftMouseDown, at: CGPoint(x: 60, y: heading.midY)))
        #expect(toggled.isEmpty)
        withExtendedLifetime(harness) {}
    }

    @Test("The pointer on a row reports it, and leaving reports nothing")
    func hoverReport() async {
        let harness = mounted(roster())
        var reports: [MemberRowHover?] = []
        harness.coordinator.noteHover = { reports.append($0) }
        harness.coordinator.setShowsRowActions(true)

        let row = harness.canvas.rowFrame(at: 2)
        harness.canvas.mouseMoved(with: harness.event(.mouseMoved, at: CGPoint(x: 60, y: row.midY)))
        await reported()
        #expect(reports.last??.userID == UserID(rawValue: 2))
        #expect(reports.last??.rowFrame.midY == row.midY - harness.scrollView.contentView.bounds.minY)

        // `mouseExited(with:)` doesn't read its event, and `NSEvent.mouseEvent`
        // refuses to make that type.
        harness.canvas.mouseExited(with: harness.event(.mouseMoved, at: .zero))
        await reported()
        #expect(reports.last! == nil)
        withExtendedLifetime(harness) {}
    }

    @Test("A list without buttons reports nothing: a role's popout")
    func noButtons() async {
        let harness = mounted(roster())
        var reports: [MemberRowHover?] = []
        harness.coordinator.noteHover = { reports.append($0) }
        harness.coordinator.setShowsRowActions(false)
        let row = harness.canvas.rowFrame(at: 1)
        harness.canvas.mouseMoved(with: harness.event(.mouseMoved, at: CGPoint(x: 60, y: row.midY)))
        await reported()
        #expect(reports.allSatisfy { $0 == nil })
        withExtendedLifetime(harness) {}
    }

    /// Discord's `.active`: the card or the menu is where the pointer is now.
    @Test("A pinned row stays reported when the pointer's gone")
    func pinned() async {
        let harness = mounted(roster())
        var last: MemberRowHover?
        harness.coordinator.noteHover = { last = $0 }
        harness.coordinator.setShowsRowActions(true)
        harness.coordinator.setPinnedUser(UserID(rawValue: 3))
        await reported()
        #expect(last?.userID == UserID(rawValue: 3))
        harness.coordinator.setPinnedUser(nil)
        await reported()
        #expect(last == nil)
        withExtendedLifetime(harness) {}
    }

    /// **The heading stays where it was clicked.** `holdPlace` would have held the
    /// rows below it still and thrown the heading off the screen.
    @Test("Folding a section leaves the scroll where it was")
    func foldKeepsPlace() {
        let harness = mounted(roster())
        harness.coordinator.setAnimatesPlate(false)
        let before = harness.scrollView.contentView.bounds.minY
        let heading = harness.canvas.rowFrame(at: 3).minY
        harness.coordinator.update(roster: roster(foldingOnline: true), presentationRevision: 0, topInset: 0)
        settle()
        #expect(harness.scrollView.contentView.bounds.minY == before)
        #expect(harness.canvas.rowFrame(at: 3).minY == heading)
        #expect(harness.canvas.drawingLimit == nil)
        #expect(harness.canvas.contentHeight < 400)
        withExtendedLifetime(harness) {}
    }

    /// With motion on: the canvas gives up what's under the heading, and has it back.
    @Test("A fold hands the area back when it lands")
    func foldLands() {
        let harness = mounted(roster())
        harness.coordinator.setAnimatesPlate(true)
        harness.coordinator.update(roster: roster(foldingOnline: true), presentationRevision: 0, topInset: 0)
        harness.coordinator.update(roster: roster(), presentationRevision: 0, topInset: 0)
        // A new list ends whatever's in flight.
        var other = roster()
        other.identity = "other"
        harness.coordinator.update(roster: other, presentationRevision: 0, topInset: 0)
        #expect(harness.canvas.drawingLimit == nil)
        withExtendedLifetime(harness) {}
    }

    /// **Not the numbers between them**: one range across a folded section would ask
    /// the server for every page in it.
    @Test("What's on screen goes back as the server's rows, in runs")
    func rowsReported() async {
        var roster = Roster(identity: "list", sections: [], members: [:], rowCount: 0)
        roster.sections = [
            RosterSection(
                key: .role(RoleID(rawValue: 7)), title: "Admin", countText: "2", index: 0, count: 0,
                isCollapsed: true, span: RosterServerSpan(heading: 0)
            ),
            RosterSection(
                key: .online, title: "Online", countText: "4000", index: 1, count: 4,
                span: RosterServerSpan(heading: 5000, hidden: [5002])
            ),
        ]
        roster.rowCount = 6
        let harness = mounted(roster)
        var reported: [ClosedRange<Int>] = []
        harness.coordinator.showRows = { runs, _ in reported = runs }
        harness.coordinator.update(roster: {
            var next = roster
            next.members[2] = person(1, "ada")
            return next
        }(), presentationRevision: 0, topInset: 0)
        // A 50 ms debounce, on a machine busy running every other test.
        for _ in 0..<100 where reported.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(reported == [0...0, 5000...5001, 5003...5005])
        withExtendedLifetime(harness) {}
    }

    @Test("A picture in a normal window is left alone by a flyout's appearance")
    func probeOnlyTouchesPopovers() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.appearance = nil
        let probe = PopoverWindowAppearance.Probe()
        probe.isDark = false
        window.contentView?.addSubview(probe)
        probe.apply()
        #expect(window.appearance == nil)
    }
}
