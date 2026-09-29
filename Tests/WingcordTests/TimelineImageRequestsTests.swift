import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Wingcord
@testable import WingcordCore

/// The prefetch behind the surfaces that play moving pictures on the clock —
/// the pinned pane, search, the inbox.
///
/// **The report**: a "GIF" of one frame — a caption meme saved as a GIF so it
/// can be favourited — drew as a plate for good. The film store answered nil
/// for it and remembered it as a still, every painter falls back to the still,
/// and nothing ever asked for the still.
@MainActor
@Suite("Image requests")
struct TimelineImageRequestsTests {

    /// A one-frame GIF on disk, under a fresh name so no test shares a cache
    /// entry with another.
    private func oneFrameGIF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "still-\(UUID().uuidString).gif")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, 1, nil
        ))
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The row a message holding `url` as a GIF attachment lays out to. A file
    /// URL passes through `CDN.resizedAttachment` untouched, so the slot's own
    /// URL is the file.
    private func row(attaching url: URL) -> MessageRow? {
        let attachment = WingcordCore.Attachment(
            id: AttachmentID(rawValue: 1),
            filename: url.lastPathComponent,
            url: url.absoluteString,
            proxyURL: url.absoluteString,
            contentType: "image/gif",
            width: 64,
            height: 48
        )
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 1),
            content: "",
            payload: MessagePayload(attachments: [attachment])
        )
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let rows = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: 520,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: PresentationRevision.shared.timeline
            ),
            cache: &cache
        )
        guard case .message(let row)? = rows.first?.kind else { return nil }
        return row
    }

    private func request(for row: MessageRow) throws -> TimelineImageRequests.Request {
        let url = try #require(row.attachments.first?.url)
        let requests = TimelineImageRequests.requests(for: [row], scale: 2, loadsArtwork: true)
        return try #require(requests.first { $0.key.url == url })
    }

    @Test("A film that turns out to be one frame is fetched as the painter's still")
    func filmFallsBackToTheStill() async throws {
        let row = try #require(row(attaching: try oneFrameGIF()))
        #expect(row.attachments.first?.isAnimated == true)
        let request = try request(for: row)
        #expect(request.source == .film(still: .attachment))
        // True only once the still is decoded into `.attachment`, the slot
        // `drawAttachmentArtwork` peeks when there is no film. The cache is not
        // peeked afterwards: the app's memory relief purges every store, and
        // suites running beside this one exercise it.
        #expect(await request.load())
    }

    @Test("A picture known to be one frame is asked for as a still")
    func knownStillIsAskedForAsAStill() async throws {
        let row = try #require(row(attaching: try oneFrameGIF()))
        let url = try #require(row.attachments.first?.url)
        let film = AnimatedImageStore.Key(url: url, maximumPixelSize: try request(for: row).key.maximumPixelSize)
        // What any surface's earlier pass would have learned — learned again
        // if the memory relief a neighbouring suite exercises wiped it first.
        var request = try request(for: row)
        for _ in 0..<3 where request.source != .still(.attachment) {
            #expect(await AnimatedImageStore.shared.image(for: film) == nil)
            request = try self.request(for: row)
        }
        #expect(request.source == .still(.attachment))
        #expect(await request.load())
    }
}
