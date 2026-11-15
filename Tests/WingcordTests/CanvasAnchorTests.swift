import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Where a press on a drawn control anchors what it opens, through the real
/// coordinator and canvas in a window, with the events a hand would send.
///
/// **A popover anchored off the window does not appear, and says nothing.** A
/// row-space rect offset by the view's own `frame` instead of the row's compiled,
/// and pressing a command's chip, Add Reaction or an invite's "+ N more" did
/// nothing — while every test that handed the model an anchor passed.
@MainActor
@Suite("Canvas anchors")
struct CanvasAnchorTests {
    private let channel = ChannelID(rawValue: 7)
    private let bot = UserID(rawValue: 2)

    private func id(_ value: UInt64) -> MessageID {
        MessageID(rawValue: (1_700_000_000_000 << 22) | value)
    }

    /// Enough above the row that a rect taken for row space alone is nowhere
    /// near it.
    private func filler() -> [Message] {
        (1...6).map { value in
            Message(id: id(value), channelID: channel, authorID: UserID(rawValue: 10 + value), content: "line \(value)")
        }
    }

    /// Columns, whatever the store holds. Bubbles are on by default, and a
    /// bubble wears a message's first few reactions on its corner with no Add
    /// Reaction control, so on a Mac whose store is new (every CI run) these
    /// tests ran in bubbles unless a settings test had already turned them off.
    private func inColumns(_ body: () throws -> Void) async rethrows {
        try await withAppSettings(\.usesMessageBubbles) { settings in
            settings.usesMessageBubbles = false
            try body()
        }
    }

    private func mounted(_ messages: [Message]) throws -> (AppModel, TimelineCoordinator, NSWindow, TimelineCanvasView) {
        let model = AppModel()
        var box = MessageBox()
        box.messages = messages
        model.setMessages(box, in: channel)
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
            presentationRevision: 0, activityAccents: [:], activityInviteStatuses: [:], uploadProgress: [:],
            topInset: 0, bottomInset: 0, jump: nil, reachesPresent: true, present: nil, flight: nil,
            scroll: TranscriptScrollState(), topics: [], summaries: [], selectedSummary: nil,
            cardRevision: 0, playingPreview: nil, isCovered: false, bookmarks: [],
            canSuperReact: false,
            canAddReactions: true,
            hidesMedia: false,
            listenAlongCards: [:],
            stageInvitations: []
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let canvas = try #require(
            scrollView.documentView?.subviews.compactMap { $0 as? TimelineCanvasView }.first
        )
        return (model, coordinator, window, canvas)
    }

    private func press(_ point: CGPoint, in canvas: TimelineCanvasView) throws {
        canvas.mouseDown(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: canvas.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )))
    }

    private func row(of messageID: MessageID, in canvas: TimelineCanvasView) throws -> (MessageRow, CGRect) {
        let index = try #require(canvas.rows.firstIndex { $0.messageID == messageID })
        guard case .message(let row) = canvas.rows[index].kind else { throw CancellationError() }
        return (row, canvas.rowFrame(at: index))
    }

    @Test("A command's chip opens its flyout over the chip")
    func commandChip() async throws {
        try await inColumns {
            let answer = Message(
                id: id(7),
                channelID: channel,
                authorID: bot,
                content: "answered",
                kind: .chatInputCommand,
                payload: MessagePayload(
                    interaction: MessageInteraction(userID: UserID(rawValue: 1), name: "count", commandType: 1)
                )
            )
            let (model, coordinator, window, canvas) = try mounted(filler() + [answer])
            let (row, frame) = try row(of: answer.id, in: canvas)
            #expect(frame.minY > 100, "the row has to be away from the canvas's origin for this to mean anything")
            let chip = try #require(row.interactionHeader).chipRect.offsetBy(dx: frame.minX, dy: frame.minY)
            try press(CGPoint(x: chip.midX, y: chip.midY), in: canvas)
            let request = try #require(model.invokedCommandRequest)
            #expect(request.messageID == answer.id)
            #expect(request.anchor == canvas.anchorInHostingRoot(chip))
            withExtendedLifetime((coordinator, window)) {}
        }
    }

    @Test("Add Reaction opens its picker over the control")
    func addReaction() async throws {
        try await inColumns {
            let reacted = Message(
                id: id(7),
                channelID: channel,
                authorID: bot,
                content: "reacted",
                payload: MessagePayload(reactions: [
                    Reaction(emoji: EmojiRef(name: "😀"), count: 2, isMine: false),
                ])
            )
            let (model, coordinator, window, canvas) = try mounted(filler() + [reacted])
            let (row, frame) = try row(of: reacted.id, in: canvas)
            #expect(frame.minY > 100)
            let control = try #require(row.visibleReactionControls(canAddReaction: true, showsBookmark: false).first {
                $0.kind == .addReaction
            })
            let rect = control.rect.offsetBy(dx: frame.minX, dy: frame.minY)
            var anchor: CGRect?
            canvas.onAddReaction = { _, opened in anchor = opened }
            try press(CGPoint(x: rect.midX, y: rect.midY), in: canvas)
            #expect(anchor == canvas.anchorInHostingRoot(rect))
            withExtendedLifetime((model, coordinator, window)) {}
        }
    }
}
