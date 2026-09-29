import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Selecting message text with the pointer, through the real coordinator and
/// canvas in a window, with the events a hand would send.
@MainActor
@Suite("Text selection")
struct TextSelectionTests {

    private let channel = ChannelID(rawValue: 7)

    private func message(_ id: UInt64, _ content: String) -> Message {
        Message(
            id: MessageID(rawValue: (1_700_000_000_000 << 22) | id),
            channelID: channel,
            authorID: UserID(rawValue: 10 + id),
            content: content
        )
    }

    private func mounted(_ messages: [Message]) throws -> (AppModel, TimelineCoordinator, NSWindow, TimelineCanvasView) {
        let model = AppModel()
        let coordinator = TimelineCoordinator(model: model)
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        coordinator.update(
            channelID: channel,
            items: TimelineReducer.rows(messages: messages),
            presentationRevision: 0, activityAccents: [:], activityInviteStatuses: [:],
            topInset: 0, bottomInset: 0, jump: nil, reachesPresent: true, present: nil,
            scroll: TranscriptScrollState(), topics: [], summaries: [], selectedSummary: nil,
            cardRevision: 0, playingPreview: nil, isCovered: false, bookmarks: [],
            canSuperReact: false
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let canvas = try #require(
            scrollView.documentView?.subviews.compactMap { $0 as? TimelineCanvasView }.first
        )
        return (model, coordinator, window, canvas)
    }

    /// Where a character of a message's body sits in the canvas.
    private func point(in canvas: TimelineCanvasView, message id: UInt64, character: Int) throws -> CGPoint {
        let index = try #require(canvas.rows.firstIndex { $0.messageID?.rawValue == ((1_700_000_000_000 << 22) | id) })
        guard case .message(let row) = canvas.rows[index].kind, let block = row.textBlock else {
            throw CancellationError()
        }
        let rect = try #require(block.selectionRects(for: NSRange(location: character, length: 1)).first)
        let frame = canvas.rowFrame(at: index)
        return CGPoint(x: frame.minX + row.textOrigin.x + rect.minX + 1, y: frame.minY + row.textOrigin.y + rect.midY)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in canvas: TimelineCanvasView, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: 1
        ))
    }

    @Test("A drag across two messages selects from one to the other")
    func dragAcrossMessages() throws {
        let (model, coordinator, window, canvas) = try mounted([
            message(1, "first message here"),
            message(2, "second message there"),
        ])
        let start = try point(in: canvas, message: 1, character: 6)
        let end = try point(in: canvas, message: 2, character: 6)
        canvas.mouseDown(with: try event(.leftMouseDown, at: start, in: canvas))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: end, in: canvas))
        canvas.mouseUp(with: try event(.leftMouseUp, at: end, in: canvas))
        #expect(canvas.selectedText() == "message here\nsecond")
        withExtendedLifetime((model, coordinator, window)) {}
    }

    @Test("Two clicks take the word, and a click elsewhere lets go")
    func doubleClickSelectsAWord() throws {
        let (model, coordinator, window, canvas) = try mounted([message(1, "pick this word please")])
        let inside = try point(in: canvas, message: 1, character: 11)
        canvas.mouseDown(with: try event(.leftMouseDown, at: inside, in: canvas, clicks: 2))
        #expect(canvas.selectedText() == "word")
        canvas.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 2, y: 2), in: canvas))
        #expect(canvas.selectedText() == nil)
        withExtendedLifetime((model, coordinator, window)) {}
    }

    @Test("A custom emoji copies as its name")
    func emojiCopiesAsItsName() {
        let text = MessageTextBuilder.build(
            document: MarkdownParser().parse("hi <:wave:123> there"),
            context: MentionContext(),
            style: MessageTextStyle.current()
        )
        let all = NSRange(location: 0, length: text.attributed.length)
        #expect(TimelineCanvasView.plainText(of: text, in: all) == "hi :wave: there")
    }
}
