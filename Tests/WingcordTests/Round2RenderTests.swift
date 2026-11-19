import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The file card in every state, and the code blocks that drew empty, drawn
/// through the real coordinator and canvas (docs/BETA3.md §7, R1 and R8) —
/// with `WINGCORD_RENDER_DIR` set, written there as PNGs to look at.
@MainActor
@Suite("Round 2 surfaces, drawn offscreen", .serialized)
struct Round2RenderTests {
    private let channel = ChannelID(rawValue: 7)
    private let author = UserID(rawValue: 3)

    private func id(_ value: UInt64) -> MessageID {
        MessageID(rawValue: (1_700_000_000_000 << 22) | value)
    }

    private func file(_ number: UInt64, _ name: String, size: Int) -> WingcordCore.Attachment {
        WingcordCore.Attachment(
            id: AttachmentID(rawValue: number),
            filename: name,
            url: "https://cdn.discordapp.com/attachments/1/\(number)/\(name)",
            proxyURL: "https://media.discordapp.net/attachments/1/\(number)/\(name)",
            size: size
        )
    }

    private func message(_ number: UInt64, _ content: String = "", files: [WingcordCore.Attachment] = []) -> Message {
        Message(
            id: id(number),
            channelID: channel,
            authorID: author,
            content: content,
            payload: files.isEmpty ? nil : MessagePayload(attachments: files)
        )
    }

    /// The model, the coordinator, the window and the canvas — all four kept
    /// for the test's length: the coordinator holds the model unowned.
    private func mount(_ messages: [Message], height: CGFloat) -> (AppModel, TimelineCoordinator, NSWindow, TimelineCanvasView)? {
        let model = AppModel()
        var box = MessageBox()
        box.messages = messages
        model.setMessages(box, in: channel)
        let coordinator = TimelineCoordinator(model: model)
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        guard let canvas = scrollView.documentView?.subviews.compactMap({ $0 as? TimelineCanvasView }).first
        else { return nil }
        return (model, coordinator, window, canvas)
    }

    /// Lets the canvas take what it was just handed.
    private func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func write(_ view: NSView, named name: String) throws -> Double {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) else { return 0 }
        view.cacheDisplay(in: view.visibleRect, to: rep)
        // How much the canvas drew: a canvas that drew nothing scores zero.
        var drawn = 0
        var sampled = 0
        if let data = rep.bitmapData {
            for offset in stride(from: 3, to: rep.bytesPerRow * rep.pixelsHigh, by: 4 * 11) {
                sampled += 1
                if data[offset] > 0 { drawn += 1 }
            }
        }
        // On a dark violet, near the Vice City theme's, so the light text and
        // the frosted tile are seen as they are in the app.
        if let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"],
           let ground = NSBitmapImageRep(
               bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
           )
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: ground)
            let bounds = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
            NSColor(srgbRed: 0.27, green: 0.10, blue: 0.36, alpha: 1).setFill()
            bounds.fill()
            rep.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            try ground.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return sampled == 0 ? 0 : Double(drawn) / Double(sampled)
    }

    @Test("Every state of the file card draws")
    func fileCardStates() async throws {
        try await withAppSettings(\.usesMessageBubbles) { settings in
            settings.usesMessageBubbles = false
            let ready = file(11, "Wingcord-1.0-beta.3-release-notes-and-screens.zip", size: 4_200_000)
            let coming = file(12, "Ubiquiti UniFi Network Server Guide.pdf", size: 48_000_000)
            let fresh = file(13, "screenshot.heic.txt", size: 22_180)
            let saved = file(14, "Keynote talk.key", size: 9_800_000)
            let failed = file(15, "notes.md", size: 1_024)
            let messages = [
                message(1, "Ready to download", files: [ready]),
                message(2, "Downloading", files: [coming]),
                message(3, "Just saved", files: [fresh]),
                message(4, "Saved a while ago", files: [saved]),
                message(5, "Failed", files: [failed]),
            ]
            let (model, coordinator, window, canvas) = try #require(mount(messages, height: 900))
            canvas.apply(fileTransfers: [
                coming.id: FileTransferState(phase: .downloading, fraction: 0.4, total: coming.size),
                fresh.id: FileTransferState(
                    phase: .saved, fraction: 1, total: fresh.size,
                    savedURL: URL(fileURLWithPath: "/tmp/x"), isFresh: true, savedAt: .distantPast
                ),
                saved.id: FileTransferState(phase: .saved, fraction: 1, total: saved.size, savedURL: URL(fileURLWithPath: "/tmp/y")),
                failed.id: FileTransferState(phase: .failed, total: failed.size),
            ])
            settle()
            let ink = try write(canvas, named: "round2-file-cards")
            #expect(ink > 0.02)
            withExtendedLifetime((model, coordinator, window)) {}
        }
    }

    /// His image 238: six one-line code blocks, drawn as empty boxes.
    @Test("Thread cards draw their newest message, or Discord's line for none")
    func threadCards() async throws {
        let friend = UserID(rawValue: 42)
        func started(_ number: UInt64, _ name: String, count: Int, latest: String?, archived: Bool = false) -> Message {
            let threadID = ChannelID(rawValue: id(number).rawValue)
            var thread = MessageThread(id: threadID, name: name, messageCount: count, isArchived: archived)
            if let latest {
                thread.latest = ThreadLatestMessage(
                    id: MessageID(rawValue: id(number).rawValue + 9), authorID: friend, excerpt: latest, hasAttachment: false
                )
            }
            return Message(
                id: id(number), channelID: channel, authorID: author,
                content: "\(name) — who is in?",
                payload: MessagePayload(thread: thread)
            )
        }
        let messages = [
            started(40, "Twelve Days", count: 29, latest: "( edited ) or no eta"),
            started(41, "Patch notes", count: 3, latest: nil),
            started(42, "Old plans", count: 60, latest: "see you", archived: true),
        ]
        let (model, coordinator, window, canvas) = try #require(mount(messages, height: 520))
        model.users[friend] = User(id: friend, username: "ithatme", displayName: "ithatme |_+")
        model.identityRevision &+= 1
        settle()
        let ink = try write(canvas, named: "round2-thread-cards")
        #expect(ink > 0.02)
        withExtendedLifetime((model, coordinator, window)) {}
    }

    @Test("One-line code blocks draw their code")
    func oneLineCodeBlocks() async throws {
        try await withAppSettings(\.usesMessageBubbles) { settings in
            settings.usesMessageBubbles = false
            let rules = [
                "```1) All previously agreed upon General Server Rules in #rules must be followed.```",
                "```2) Keep all Early Access related discussions in their respective channels and not outside of this Section/Category.```",
                "```3) Discussions regarding how the Store Tracker works are explicitly off-topic.```",
                "see ```code in a line``` and after",
                ">>> a quote that runs\nto the end of the message",
            ]
            let messages = rules.enumerated().map { message(UInt64(20 + $0.offset), $0.element) }
            let (model, coordinator, window, canvas) = try #require(mount(messages, height: 760))
            let ink = try write(canvas, named: "round2-code-blocks")
            #expect(ink > 0.02)
            withExtendedLifetime((model, coordinator, window)) {}
        }
    }
}
