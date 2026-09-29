import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The loaded window: where it is cut, when it is cut off from the present,
/// how a page lands in it, and how the store asks for the next one.
@Suite("Transcript window")
@MainActor
struct TranscriptWindowTests {

    private let channel = ChannelID(rawValue: 9)

    private func message(_ id: UInt64) -> Message {
        Message(
            id: MessageID(rawValue: id),
            channelID: channel,
            authorID: UserID(rawValue: 1),
            content: "m\(id)"
        )
    }

    private func messages(_ ids: ClosedRange<UInt64>) -> [Message] {
        ids.map(message)
    }

    private func ids(_ box: MessageBox) -> [UInt64] {
        box.messages.map(\.id.rawValue)
    }

    // MARK: Discord's around arithmetic

    @Test("A page from the middle of a channel has history on both sides")
    func aroundMiddle() {
        let page = (1...100).map { MessageID(rawValue: $0) }
        let edges = TranscriptWindow.edges(
            ofAround: page, target: MessageID(rawValue: 51), limit: 100,
            newestInChannel: MessageID(rawValue: 5000)
        )
        #expect(edges.older)
        #expect(edges.newer)
    }

    @Test("Fewer than half the limit from the target onward is the present")
    func aroundReachesPresent() {
        // 60 before the target, the target, and 29 after it: the channel ends.
        let page = (1...90).map { MessageID(rawValue: $0) }
        let edges = TranscriptWindow.edges(
            ofAround: page, target: MessageID(rawValue: 61), limit: 100,
            newestInChannel: nil
        )
        #expect(edges.older)
        #expect(!edges.newer)
    }

    @Test("Fewer than half the limit before the target is the channel's start")
    func aroundReachesStart() {
        let page = (1...80).map { MessageID(rawValue: $0) }
        let edges = TranscriptWindow.edges(
            ofAround: page, target: MessageID(rawValue: 20), limit: 100,
            newestInChannel: nil
        )
        #expect(!edges.older)
        #expect(edges.newer)
    }

    @Test("A page ending on the channel's newest message reaches the present")
    func aroundEndsOnNewest() {
        let page = (1...100).map { MessageID(rawValue: $0) }
        let edges = TranscriptWindow.edges(
            ofAround: page, target: MessageID(rawValue: 51), limit: 100,
            newestInChannel: MessageID(rawValue: 100)
        )
        #expect(!edges.newer)
    }

    @Test("A deleted target still has a place in its page")
    func aroundDeletedTarget() {
        // Target 5000 is gone; 49 older and 50 newer came back around it.
        let page = (4951...4999).map { MessageID(rawValue: $0) }
            + (5001...5050).map { MessageID(rawValue: $0) }
        let edges = TranscriptWindow.edges(
            ofAround: page, target: MessageID(rawValue: 5000), limit: 100,
            newestInChannel: nil
        )
        #expect(edges.older)
        #expect(edges.newer)
    }

    // MARK: Pages landing

    @Test("An older page that crosses the limit cuts the window off from the present")
    func olderPageTrimsNewest() {
        var box = MessageBox()
        box.receivePresent(messages(1001...1100))
        box.receiveOlder(messages(901...1000), before: MessageID(rawValue: 1001))
        box.receiveOlder(messages(801...900), before: MessageID(rawValue: 901))
        #expect(box.messages.count == 300)
        #expect(!box.hasMoreNewer)

        box.receiveOlder(messages(701...800), before: MessageID(rawValue: 801))
        // The reader is at the top: the newest two hundred went, and with them
        // the present.
        #expect(ids(box) == Array(701...900))
        #expect(box.hasMoreNewer)
        #expect(box.hasMoreHistory)
    }

    @Test("A page the window moved away from is dropped whole")
    func stalePagesAreDropped() {
        var box = MessageBox()
        box.receivePresent(messages(1001...1100))
        // Asked for above 500, but the window starts at 1001 now.
        let older = box.receiveOlder(messages(401...499), before: MessageID(rawValue: 500))
        #expect(!older)
        #expect(ids(box) == Array(1001...1100))
        // A newer page into a window that reaches the present is stale too.
        let newer = box.receiveNewer(messages(1101...1150), after: MessageID(rawValue: 1100))
        #expect(!newer)
    }

    @Test("A channel's first page does not land in a window a jump cut off")
    func firstPageAfterAJump() {
        // A link opened with its channel: the jump's page lands first, and the
        // newest page — asked for when the channel opened — lands after it.
        var box = MessageBox()
        box.receiveAround(messages(101...200), edges: (older: true, newer: true))
        let landed = box.receiveOlder(messages(9001...9100), before: nil)
        #expect(!landed)
        #expect(ids(box) == Array(101...200))
    }

    @Test("Paging down past the limit trims the oldest, and a short page is the present")
    func newerPages() {
        var box = MessageBox()
        box.receiveAround(messages(101...200), edges: (older: true, newer: true))

        box.receiveNewer(messages(201...300), after: MessageID(rawValue: 200))
        box.receiveNewer(messages(301...400), after: MessageID(rawValue: 300))
        // At the limit, not past it: nothing goes yet.
        #expect(ids(box) == Array(101...400))

        box.receiveNewer(messages(401...500), after: MessageID(rawValue: 400))
        // The reader is at the foot: the oldest two hundred went.
        #expect(ids(box) == Array(301...500))
        #expect(box.hasMoreNewer)
        #expect(box.hasMoreHistory)

        box.receiveNewer(messages(501...530), after: MessageID(rawValue: 500))
        #expect(!box.hasMoreNewer)
        #expect(box.messages.last?.id.rawValue == 530)
    }

    /// **The cut-off below a jump.** A page Discord sent in full, one message
    /// of which this client could not read, is short by what was read and not
    /// by what was sent. Read as short, it reconnected the window to a
    /// present it had not reached and the transcript stopped there for good.
    @Test("A page is short by what Discord sent, not by what could be read")
    func unreadableMessageIsNotTheEnd() {
        var box = MessageBox()
        box.receiveAround(messages(101...200), edges: (older: true, newer: true))

        // Ninety-nine read, one hundred sent.
        box.receiveNewer(messages(201...299), wireCount: 100, after: MessageID(rawValue: 200))
        #expect(box.hasMoreNewer)

        box.receiveOlder(messages(2...100), wireCount: 100, before: MessageID(rawValue: 101))
        #expect(box.hasMoreHistory)
    }

    @Test("Discord's around arithmetic counts the page it was sent")
    func aroundCountsTheWire() {
        // Fifty after the target were sent and one of them could not be read.
        let read = (1...99).map { MessageID(rawValue: $0) }
        let edges = TranscriptWindow.edges(
            ofAround: read, wireCount: 100, target: MessageID(rawValue: 51), limit: 100,
            newestInChannel: MessageID(rawValue: 5000)
        )
        #expect(edges.newer)
    }

    @Test("Live messages wait beside a window cut off from the present")
    func liveMessagesAreHeld() {
        var box = MessageBox()
        box.receiveAround(messages(101...200), edges: (older: true, newer: true))

        box.receiveLive(message(900), trimming: true)
        #expect(box.messages.last?.id.rawValue == 200)
        #expect(box.heldLive.map(\.id.rawValue) == [900])

        // Reconnecting puts them in behind the page — without replacing the
        // page's own copy of one it already carries.
        var edited = message(430)
        edited.content = "edited since"
        box.receiveLive(message(430), trimming: true)
        // A short page, so it is the one that reaches the present.
        box.receiveNewer(messages(201...229) + [edited], after: MessageID(rawValue: 200))
        #expect(box.heldLive.isEmpty)
        #expect(!box.hasMoreNewer)
        #expect(box.messages.last?.id.rawValue == 900)
        #expect(box.messages.first { $0.id.rawValue == 430 }?.content == "edited since")
    }

    @Test("What is held is bounded, and a delete reaches it")
    func heldIsBounded() {
        var box = MessageBox()
        box.receiveAround(messages(1...100), edges: (older: false, newer: true))
        for id in UInt64(1001)...UInt64(1000 + TranscriptWindow.heldLimit + 5) {
            box.receiveLive(message(id), trimming: true)
        }
        #expect(box.heldLive.count == TranscriptWindow.heldLimit)
        #expect(box.heldLive.first?.id.rawValue == 1006)

        box.remove(MessageID(rawValue: 1006))
        #expect(box.heldLive.first?.id.rawValue == 1007)
    }

    @Test("A live message trims the oldest only when nobody is away from the foot")
    func liveTrimming() {
        var box = MessageBox()
        box.receivePresent(messages(1...100))
        // Somebody is scrolled up: the window grows past its limit rather than
        // losing what they are reading.
        for id in UInt64(101)...UInt64(400) { box.receiveLive(message(id), trimming: false) }
        #expect(box.messages.count == 400)

        box.receiveLive(message(401), trimming: true)
        #expect(ids(box) == Array(202...401))
        #expect(box.hasMoreHistory)
    }

    @Test("The newest page replaces the window and takes in what was held")
    func presentReplaces() {
        var box = MessageBox()
        box.receiveAround(messages(101...200), edges: (older: true, newer: true))
        box.receiveLive(message(5001), trimming: true)
        box.receivePresent(messages(4901...5000))
        #expect(!box.hasMoreNewer)
        #expect(box.messages.first?.id.rawValue == 4901)
        #expect(box.messages.last?.id.rawValue == 5001)
    }

    // MARK: The store

    private func model(cutOff: Bool) -> AppModel {
        let model = AppModel()
        model.mutateBox(channel) { box in
            box.receiveAround(messages(101...200), edges: (older: true, newer: cutOff))
        }
        return model
    }

    @Test("A window cut off from the present asks for the page below its foot")
    func laterPaging() {
        let model = model(cutOff: true)
        var requests: [HistoryRequest] = []
        model.historyLoader = { _, request in requests.append(request) }

        model.loadLaterHistory(in: channel)
        model.loadLaterHistory(in: channel)  // already loading: nothing
        #expect(requests == [.newer(after: MessageID(rawValue: 200))])
    }

    @Test("A failed page below stops scrolling from asking again")
    func failedLaterPage() {
        let model = model(cutOff: true)
        model.mutateBox(channel) { $0.newerPageFailed = true }
        var requests: [HistoryRequest] = []
        model.historyLoader = { _, request in requests.append(request) }
        model.loadLaterHistory(in: channel)
        #expect(requests.isEmpty)

        // The jump control is the way out, and it clears the failure.
        model.jumpToPresent(in: channel)
        #expect(requests == [.present])
        #expect(model.messages(in: channel)?.newerPageFailed == false)
    }

    @Test("Jumping to the present scrolls a window that has it, and fetches one that does not")
    func jumpToPresent() {
        let attached = model(cutOff: false)
        var fetched = false
        attached.historyLoader = { _, _ in fetched = true }
        attached.jumpToPresent(in: channel)
        #expect(attached.presentRequest?.channelID == channel)
        #expect(!fetched)
        #expect(!attached.escapeTranscript(in: channel))

        let cutOff = model(cutOff: true)
        var requests: [HistoryRequest] = []
        cutOff.historyLoader = { _, request in requests.append(request) }
        #expect(cutOff.escapeTranscript(in: channel))
        #expect(requests == [.present])
        #expect(cutOff.messages(in: channel)?.isLoadingNewer == true)
    }

    @Test("Two requests for the same channel are two requests")
    func presentTokens() {
        let model = model(cutOff: false)
        model.jumpToPresent(in: channel)
        let first = model.presentRequest
        model.jumpToPresent(in: channel)
        #expect(model.presentRequest != first)
    }

    @Test("A transcript away from the foot keeps live messages from trimming")
    func footRecord() {
        let model = AppModel()
        // Held for the whole test: a freed object's address is reused, and two
        // viewers with one identity would be one viewer.
        let mainWindow = NSObject()
        let overlayWindow = NSObject()
        let main = ObjectIdentifier(mainWindow)
        let overlay = ObjectIdentifier(overlayWindow)
        defer { withExtendedLifetime((mainWindow, overlayWindow)) {} }
        #expect(model.mayTrimOldest(in: channel))

        model.setTranscript(channel, isAwayFromFoot: true, viewer: main)
        model.setTranscript(channel, isAwayFromFoot: false, viewer: overlay)
        #expect(!model.mayTrimOldest(in: channel))

        model.setTranscript(channel, isAwayFromFoot: false, viewer: main)
        #expect(model.mayTrimOldest(in: channel))
    }

    // MARK: The viewport

    @Test("The way back shows while cut off, and past a screen up otherwise")
    func jumpVisibility() {
        let viewport = { (y: CGFloat) in CGRect(x: 0, y: y, width: 900, height: 800) }
        // Document 10 000 tall, 100 of it under the composer: the foot rests
        // at y = 10 100 - 800.
        let foot: CGFloat = 9_300
        func shows(at y: CGFloat, reaches: Bool = true, was: Bool = false) -> Bool {
            TimelineViewportPolicy.showsJumpToPresent(
                viewport: viewport(y), documentHeight: 10_000, bottomInset: 100,
                reachesPresent: reaches, wasShowing: was
            )
        }
        #expect(!shows(at: foot))
        #expect(shows(at: foot, reaches: false))
        #expect(!shows(at: foot - 700))
        #expect(shows(at: foot - 900))
        // Hysteresis: between half a screen and a screen, it keeps what it had.
        #expect(shows(at: foot - 600, was: true))
        #expect(!shows(at: foot - 600, was: false))
        #expect(!shows(at: foot - 300, was: true))
    }

    @Test("The page below is asked for near the window's foot, and only then")
    func laterPrefetch() {
        let near = CGRect(x: 0, y: 6_000, width: 900, height: 800)
        let far = CGRect(x: 0, y: 0, width: 900, height: 800)
        #expect(TimelineViewportPolicy.shouldLoadLater(
            viewport: near, documentHeight: 10_000, hasMore: true, isLoading: false
        ))
        #expect(!TimelineViewportPolicy.shouldLoadLater(
            viewport: far, documentHeight: 20_000, hasMore: true, isLoading: false
        ))
        #expect(!TimelineViewportPolicy.shouldLoadLater(
            viewport: near, documentHeight: 10_000, hasMore: true, isLoading: true
        ))
    }
}
