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
        waveform: String? = nil
    ) -> WingcordCore.Attachment {
        WingcordCore.Attachment(
            id: AttachmentID(rawValue: 1),
            filename: name,
            url: "https://cdn.discordapp.com/attachments/1/2/\(name)",
            proxyURL: "https://media.discordapp.net/attachments/1/2/\(name)",
            contentType: type,
            size: size,
            width: width,
            height: height,
            waveform: waveform,
            durationSeconds: duration
        )
    }

    @Test("A clip is a poster, not the video's own bytes")
    func videoPoster() {
        let slot = slot(attachment(name: "clip.mp4", type: "video/mp4", width: 1920, height: 1080))
        #expect(slot?.kind == AttachmentSlot.Kind.video)
        // Without `format=jpg` the proxy answers with the video, `CGImageSource`
        // decodes nothing, and the store records a permanent failure — which is
        // a grey box for the life of the process.
        #expect(slot?.url?.query()?.contains("format=jpg") == true)
    }

    @Test("A document is a card, never a picture-shaped hole")
    func documentIsACard() {
        let slot = slot(attachment(name: "notes.zip", type: "application/zip", size: 4_096_000))
        #expect(slot?.kind == AttachmentSlot.Kind.file)
        #expect(slot?.url == nil)
        #expect(slot?.rect.height == TimelineMetrics.attachmentCardHeight)
        #expect(slot?.sizeLabel.isEmpty == false)
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
