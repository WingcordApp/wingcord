import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// What an attachment turns into.
///
/// **Four shapes, and getting the kind wrong is silent.** A clip asked the CDN
/// for its own bytes as a picture and drew a grey box for the life of the
/// process; a zip file was laid out as a photograph and drew the same box.
/// Neither failed — they rendered, at the right size, with nothing in them.
@MainActor
@Suite("Attachment slots")
struct AttachmentSlotTests {

    private func slot(
        _ attachment: WingcordCore.Attachment,
        width: CGFloat = 520
    ) -> AttachmentSlot? {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 1),
            content: "",
            payload: MessagePayload(attachments: [attachment])
        )
        let rows = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: width,
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
        return row.attachments.first
    }

    private func attachment(
        name: String,
        type: String?,
        width: Int? = nil,
        height: Int? = nil,
        size: Int = 1024,
        duration: Double? = nil,
        waveform: String? = nil,
        marked: Bool = false
    ) -> WingcordCore.Attachment {
        WingcordCore.Attachment(
            id: AttachmentID(rawValue: 1),
            filename: name,
            url: "https://cdn.discordapp.com/attachments/1/2/\(name)?ex=6abcc102&is=6abb6f82&hm=2ba6",
            proxyURL: "https://media.discordapp.net/attachments/1/2/\(name)?ex=6abcc102&is=6abb6f82&hm=2ba6",
            contentType: type,
            size: size,
            width: width,
            height: height,
            waveform: waveform,
            durationSeconds: duration,
            isMarkedAnimated: marked
        )
    }

    /// Discord's rule, from its `LazyImage.isAnimated`: a `.gif` always, a
    /// WebP only when Discord marked it `IS_ANIMATED`, and nothing else. And a
    /// picture that moves asks the proxy for every frame, which a WebP needs —
    /// measured, it is flattened to one frame otherwise.
    @Test("A picture moves by Discord's rule, and asks the proxy for every frame", arguments: [
        ("loop.gif", "image/gif", false, true),
        ("HappyDays.gif", "image/gif", false, true),
        ("party.webp", "image/webp", true, true),
        ("photo.webp", "image/webp", false, false),
        ("frames.png", "image/png", true, false),
        ("photo.jpg", "image/jpeg", false, false),
    ])
    func movesByDiscordsRule(name: String, type: String, marked: Bool, moves: Bool) throws {
        let slot = try #require(slot(attachment(name: name, type: type, width: 400, height: 300, marked: marked)))
        #expect(slot.isAnimated == moves)
        let items = try #require(
            slot.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
        )
        #expect(items.contains { $0.name == "animated" && $0.value == "true" } == moves)
        // The signature survives the rewrite, or the proxy refuses the request.
        #expect(items.contains { $0.name == "hm" })
    }

    @Test("A clip is a poster, not the video's own bytes")
    func videoPoster() {
        let slot = slot(attachment(name: "clip.mp4", type: "video/mp4", width: 1920, height: 1080))
        #expect(slot?.kind == AttachmentSlot.Kind.video)
        // Without `format=webp` the proxy answers with the video, `CGImageSource`
        // decodes nothing, and the store records a permanent failure — which is
        // a grey box for the life of the process.
        #expect(slot?.url?.query()?.contains("format=webp") == true)
    }

    /// Alex's image 22: the demo clip, a file on this Mac, drew a plate with a
    /// play badge and nothing in it — the proxy has no still of a file it
    /// never saw, so the poster URL was nil and nothing was ever asked for.
    @Test("A clip on this Mac is its own poster: its first frame")
    func localClipPoster() async throws {
        let file = URL.temporaryDirectory.appending(path: "wingcord-poster-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        try await Self.writeRedClip(to: file)

        let clip = WingcordCore.Attachment(
            id: AttachmentID(rawValue: 1), filename: "clip.mp4",
            url: file.absoluteString, proxyURL: file.absoluteString,
            contentType: "video/mp4", size: 1024, width: 64, height: 36, durationSeconds: 1
        )
        let slot = try #require(slot(clip))
        #expect(slot.kind == AttachmentSlot.Kind.video)
        #expect(slot.url == file)

        let frame = try #require(
            await ImageStore.shared.image(for: ImageStore.Key(url: file, maximumPixelSize: 64), bucket: .attachment)
        )
        #expect(frame.width == 64)
        // The frame, not a plate: red.
        let pixels = RenderProbe.pixels(width: 8, height: 8) { context, _ in
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        #expect(pixels[0] > 180 && pixels[1] < 80 && pixels[2] < 80)
    }

    /// Two frames of 64 × 36 red H.264 — `DemoMedia`'s encoder, smaller.
    private static func writeRedClip(to file: URL) async throws {
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 36,
        ])
        let receiver = writer.inputPixelBufferReceiver(
            for: input,
            pixelBufferAttributes: CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32ARGB),
                size: CVImageSize(width: 64, height: 36)
            )
        )
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(receiver.pixelBufferPool)
        for index in 0..<2 {
            var buffer = try pool.makeMutablePixelBuffer()
            buffer.accessUnsafeMutableRawPlaneBytes { planes in
                guard let plane = planes.first, let base = plane.bytes.baseAddress,
                      let context = CGContext(
                          data: base, width: 64, height: 36, bitsPerComponent: 8,
                          bytesPerRow: plane.properties.bytesPerRow,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      )
                else { return }
                context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
            }
            try await receiver.append(CVReadOnlyPixelBuffer(consume buffer), with: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        receiver.finish()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    /// **The measurement this pins**, taken on the live proxy: given only a
    /// width it sends the original back, and a 32-frame GIF resized with both
    /// sides comes back with all 32. See `CDN.resizedAttachment`.
    @Test("A picture and a GIF both ask the proxy for both sides")
    func resizeAsksForBothSides() throws {
        for (name, type) in [("photo.png", "image/png"), ("loop.gif", "image/gif")] {
            let slot = try #require(slot(attachment(name: name, type: type, width: 1200, height: 800)))
            let items = try #require(
                slot.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
            )
            let width = try #require(items.first { $0.name == "width" }?.value.flatMap(Int.init))
            let height = try #require(items.first { $0.name == "height" }?.value.flatMap(Int.init))
            // The picture's own shape, so the proxy's fit changes nothing.
            #expect(abs(Double(width) / Double(height) - 1.5) < 0.01, "\(name)")
            #expect(!items.contains { $0.name == "format" }, "a format flattens a GIF: \(name)")
            #expect(slot.url?.host() == "media.discordapp.net")
        }
    }

    @Test("A document is a card, never a picture-shaped hole")
    func documentIsACard() {
        let slot = slot(attachment(name: "notes.zip", type: "application/zip", size: 4_096_000))
        #expect(slot?.kind == AttachmentSlot.Kind.file)
        #expect(slot?.url == nil)
        #expect(slot?.rect.height == TimelineMetrics.fileTileHeight)
        #expect(slot?.fileKind == .archive)
        #expect(slot?.sizeLabel.isEmpty == false)
        #expect(slot?.fileExtension == "zip")
        #expect(slot?.attachmentID != nil)
    }

    /// The file card (docs/BETA3.md §7, R8): 400 wide at most, 64 tall, its
    /// one round button inside the card at the trailing edge.
    @Test("A file card is the tile: 400 wide, 64 tall, its button inside")
    func fileCardGeometry() throws {
        let wide = try #require(slot(attachment(name: "app-icons.txt", type: "text/plain", size: 14_000), width: 900))
        #expect(wide.rect.width == 400)
        #expect(wide.rect.height == 64)
        #expect(wide.fileKind == .document)
        let button = try #require(wide.downloadRect)
        #expect(button.size == CGSize(width: 32, height: 32))
        #expect(wide.rect.contains(button))
        #expect(button.maxX == wide.rect.maxX - TimelineMetrics.fileTileInset)
        #expect(abs(button.midY - wide.rect.midY) < 0.5)
        let narrow = try #require(slot(attachment(name: "a.zip", type: "application/zip", size: 1), width: 300))
        #expect(narrow.rect.width < 400)
    }

    /// A long name gives up its middle, never its end: the extension and the
    /// last few characters say what the file is.
    @Test("A long name is shortened in the middle, keeping its extension")
    func longNameKeepsItsEnd() {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let name = "Screen_Shot_2021-01-12_at_10.24.50_AM_with_a_much_longer_tail.png"
        let fitted = FileTileText.fitting(name, font: font, width: 160)
        #expect(fitted.contains("…"))
        #expect(fitted.hasSuffix("tail.png"))
        #expect(FileTileText.measure(fitted, font: font) <= 160)
        #expect(FileTileText.fitting("short.png", font: font, width: 160) == "short.png")
    }

    /// His image 245 (2026-11-19): a 2021 screenshot with no `content_type`,
    /// drawn as a file card where Discord draws the picture.
    @Test("A picture older than content_type is still a picture")
    func untypedPictureIsAPicture() {
        let slot = slot(attachment(name: "Screen_Shot_2021-01-12_at_10.24.50_AM.png", type: nil, width: 1200, height: 800))
        #expect(slot?.kind == AttachmentSlot.Kind.image)
        #expect(slot?.url != nil)
    }

    @Test("Every one of Discord's fourteen file icons is in the app")
    func fileIcons() {
        for kind in AttachmentFileKind.allCases {
            #expect(FileIconArt.image(for: kind, scale: 2) != nil, "\(kind.iconName)")
        }
    }

    @Test("A voice note is a bar with its length on it")
    func voiceNote() {
        let slot = slot(attachment(
            name: "voice-message.ogg",
            type: "audio/ogg",
            duration: 64,
            waveform: "AAAA"
        ))
        #expect(slot?.kind == AttachmentSlot.Kind.voice)
        #expect(slot?.durationLabel == "1:04")
    }

    @Test("A picture is never drawn larger than its own pixels")
    func neverUpscaled() {
        let small = slot(attachment(name: "tiny.png", type: "image/png", width: 180, height: 120))
        #expect(small?.rect.width == 180)
        #expect(small?.rect.height == 120)
    }

    @Test("A tall picture keeps its shape when the height is capped")
    func heightCapPreservesRatio() {
        // The defect: the height was capped and the width was not, so a portrait
        // GIF was drawn at the column's full width and squashed.
        let tall = slot(attachment(name: "tall.gif", type: "image/gif", width: 900, height: 1600))
        guard let rect = tall?.rect else {
            Issue.record("no slot")
            return
        }
        #expect(rect.height <= Metrics.attachmentMaxHeight)
        #expect(abs(rect.width / rect.height - 900.0 / 1600.0) < 0.02)
    }

    @Test("Only a GIF offers the star, and it sits inside the picture")
    func favouriteIsOfferedOnlyOnGIFs() {
        // §5.5 — a control that cannot work must not look like one that can. A
        // favourite is stored as a URL and re-sent as a message; a photograph
        // has nothing to send.
        #expect(slot(attachment(name: "photo.png", type: "image/png", width: 400, height: 300))?.favorite == nil)
        #expect(slot(attachment(name: "clip.mp4", type: "video/mp4", width: 400, height: 300))?.favorite == nil)

        let gif = slot(attachment(name: "happy.gif", type: "image/gif", width: 400, height: 300))
        #expect(gif?.favorite != nil)
        #expect(gif?.isAnimated == true)
        guard let slot = gif else { return }
        #expect(slot.rect.contains(slot.favoriteRect))
    }

    @Test("A spoiler is never animated, whatever its type says")
    func spoilersDoNotPlay() {
        // A picture somebody hid must not play under the cover.
        let hidden = slot(attachment(
            name: "SPOILER_happy.gif", type: "image/gif", width: 400, height: 300
        ))
        #expect(hidden?.isSpoiler == true)
        #expect(hidden?.isAnimated == false)
    }
}
