import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// A page of history landing while the reader is somewhere in the transcript,
/// through the real coordinator and canvas.
///
/// **Alex's report**: scroll up for a while and the placeholders take the
/// screen, while the older messages keep loading underneath them. The runway
/// stays at the top of the document as a page lands beneath it, so a prepend
/// anchored on the placeholder at the viewport's top — or, as it was, on
/// nothing — leaves the reader looking at placeholders with the page out of
/// sight below.
@MainActor
@Suite("History runway")
struct HistoryRunwayTests {

    private let channel = ChannelID(rawValue: 7)

    /// Messages a minute apart, by two people, so the page is made of runs and
    /// day headings the way a real channel's is.
    private func messages(_ ids: ClosedRange<UInt64>) -> [Message] {
        ids.map { id in
            let milliseconds = (1_700_000_000 + id * 60) * 1000
            return Message(
                id: MessageID(rawValue: (milliseconds << 22) | id),
                channelID: channel,
                authorID: UserID(rawValue: 10 + id % 2),
                content: "message \(id)"
            )
        }
    }

    private func show(_ messages: [Message], in coordinator: TimelineCoordinator) {
        coordinator.update(
            channelID: channel,
            items: TimelineReducer.rows(messages: messages, hasMoreHistory: true),
            presentationRevision: 0,
            activityAccents: [:],
            activityInviteStatuses: [:], uploadProgress: [:],
            topInset: 0,
            bottomInset: 0,
            jump: nil,
            reachesPresent: true,
            present: nil,
            flight: nil,
            scroll: TranscriptScrollState(),
            topics: [],
            summaries: [],
            selectedSummary: nil,
            cardRevision: 0,
            playingPreview: nil,
            isCovered: false,
            bookmarks: [],
            canSuperReact: false,
            canAddReactions: true,
            hidesMedia: false,
            listenAlongCards: [:]
        )
    }

    private func canvas(in scrollView: NSScrollView) throws -> TimelineCanvasView {
        try #require(
            scrollView.documentView?.subviews.compactMap { $0 as? TimelineCanvasView }.first
        )
    }

    /// Lets the scroll view's notifications reach the coordinator, the way a
    /// running window's would between two events.
    private func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func isPlaceholder(_ row: TimelineRow) -> Bool {
        if case .skeleton = row.kind { return true }
        return false
    }

    private func isHeading(_ row: TimelineRow) -> Bool {
        if case .daySeparator = row.kind { return true }
        return false
    }

    /// Where a message sits on screen: its top, less the viewport's.
    private func screenOffset(of id: MessageID, _ canvas: TimelineCanvasView, _ scrollView: NSScrollView) -> CGFloat? {
        canvas.rows.firstIndex { $0.messageID == id }
            .map { canvas.rowFrame(at: $0).minY - scrollView.contentView.bounds.minY }
    }

    @Test("A page that lands while the reader is in the runway lands where they are looking")
    func pageReplacesThePlaceholders() throws {
        // Held here: the coordinator keeps its store unowned, as the app's
        // window does.
        let model = AppModel()
        let coordinator = TimelineCoordinator(model: model)
        let scrollView = coordinator.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        scrollView.tile()
        let newest = messages(200...259)
        show(newest, in: coordinator)
        settle()
        let canvas = try canvas(in: scrollView)

        // Into the runway: the top of the document is twenty placeholder groups.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle()
        #expect(isPlaceholder(try #require(canvas.rowIndex(at: 300).map { canvas.rows[$0] })))
        let firstLoaded = try #require(newest.first?.id)
        let before = try #require(screenOffset(of: firstLoaded, canvas, scrollView))
        #expect(before > 0, "the first loaded message is below the viewport's top")

        show(messages(100...259), in: coordinator)
        settle()

        // The message that was under the placeholders has not moved on screen…
        let after = try #require(screenOffset(of: firstLoaded, canvas, scrollView))
        #expect(abs(after - before) < 0.5)
        // …and what the reader is looking at is the page, not the runway.
        let top = try #require(canvas.rowIndex(at: scrollView.contentView.bounds.minY))
        #expect(!isPlaceholder(canvas.rows[top]))

        withExtendedLifetime((model, coordinator)) {}
    }

    @Test("A page that lands above a day heading at the top does not move the reader")
    func headingAtTheTopHoldsItsPlace() throws {
        // Held here: the coordinator keeps its store unowned, as the app's
        // window does.
        let model = AppModel()
        let coordinator = TimelineCoordinator(model: model)
        let scrollView = coordinator.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        scrollView.tile()
        // A day apart, so the second page's first message opens a new day.
        let newest = messages(1_700...1_759)
        show(newest, in: coordinator)
        settle()
        let canvas = try canvas(in: scrollView)

        let heading = try #require(canvas.rows.firstIndex(where: isHeading))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: canvas.rowFrame(at: heading).minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle()
        let firstLoaded = try #require(newest.first?.id)
        let before = try #require(screenOffset(of: firstLoaded, canvas, scrollView))

        show(messages(100...159) + newest, in: coordinator)
        settle()

        let after = try #require(screenOffset(of: firstLoaded, canvas, scrollView))
        #expect(abs(after - before) < 0.5)

        withExtendedLifetime((model, coordinator)) {}
    }
}
