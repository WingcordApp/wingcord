import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The transcript's moving pictures on layers, through the real coordinator and
/// canvas in a window.
///
/// **What matters is where each layer sits and what the painter leaves under
/// it.** A layer a few points off its box is a picture beside itself; a painter
/// still drawing under a layer shows through every clear pixel of it.
@MainActor
@Suite("Transcript films")
struct TranscriptFilmsTests {

    private let channel = ChannelID(rawValue: 7)
    private let messageID = MessageID(rawValue: (1_700_000_000_000 << 22) | 1)

    private func attachment(_ id: UInt64, _ name: String, spoiler: Bool = false) -> WingcordCore.Attachment {
        WingcordCore.Attachment(
            id: AttachmentID(rawValue: id),
            filename: spoiler ? "SPOILER_\(name)" : name,
            url: "https://cdn.discordapp.com/attachments/1/\(id)/\(name)",
            proxyURL: "https://media.discordapp.net/attachments/1/\(id)/\(name)",
            contentType: "image/gif",
            size: 1024,
            width: 320,
            height: 240
        )
    }

    /// One message: a GIF, a spoilered GIF, an animated emoji in its text and
    /// an animated sticker.
    private func show(in coordinator: TimelineCoordinator) {
        let message = Message(
            id: messageID,
            channelID: channel,
            authorID: UserID(rawValue: 10),
            content: "look <a:party:123456789010468812>",
            payload: MessagePayload(
                attachments: [attachment(1, "loop.gif"), attachment(2, "secret.gif", spoiler: true)],
                stickers: [StickerRef(id: 42, name: "wave", format: .apng)]
            )
        )
        coordinator.update(
            channelID: channel,
            items: TimelineReducer.rows(messages: [message]),
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

    private func mounted() throws -> (AppModel, TimelineCoordinator, NSWindow, TimelineCanvasView) {
        let model = AppModel()
        let coordinator = TimelineCoordinator(model: model)
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        show(in: coordinator)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let canvas = try #require(
            scrollView.documentView?.subviews.compactMap { $0 as? TimelineCanvasView }.first
        )
        return (model, coordinator, window, canvas)
    }

    @Test("Every moving picture is on a layer, and the painter leaves its box")
    func layered() throws {
        let (model, coordinator, window, canvas) = try mounted()
        let layered = try #require(canvas.films.layered[messageID])
        #expect(layered.attachments == [0], "the spoilered GIF stays under its cover")
        #expect(layered.stickers == [0])
        if AnimationClock.playsAnimatedEmoji {
            #expect(layered.emoji == [0])
        }
        withExtendedLifetime((model, coordinator, window)) {}
    }

    @Test("A layer sits exactly on the box the painter reserved")
    func placement() throws {
        let (model, coordinator, window, canvas) = try mounted()
        let index = try #require(canvas.rows.firstIndex { $0.messageID == messageID })
        guard case .message(let row) = canvas.rows[index].kind else {
            Issue.record("not a message row")
            return
        }
        let origin = canvas.rowFrame(at: index).origin
        let frames = Set((canvas.films.container.sublayers ?? []).map { NSStringFromRect($0.frame) })
        let gif = row.attachments[0].rect.offsetBy(dx: origin.x, dy: origin.y)
        let sticker = row.stickers[0].rect.offsetBy(dx: origin.x, dy: origin.y)
        #expect(frames.contains(NSStringFromRect(gif)))
        #expect(frames.contains(NSStringFromRect(sticker)))
        withExtendedLifetime((model, coordinator, window)) {}
    }

    @Test("A window the transcript leaves takes its layers with it")
    func leavingTheWindow() throws {
        let (model, coordinator, window, canvas) = try mounted()
        #expect(!(canvas.films.container.sublayers ?? []).isEmpty)
        window.contentView = nil
        #expect((canvas.films.container.sublayers ?? []).isEmpty)
        #expect(canvas.films.layered.isEmpty)
        withExtendedLifetime((model, coordinator, window)) {}
    }
}
