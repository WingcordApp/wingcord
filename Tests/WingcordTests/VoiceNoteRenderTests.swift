import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A voice note's row, drawn: with `WINGCORD_RENDER_DIR` set each state is written there
/// as a PNG to look at.
@MainActor
@Suite("A voice note, drawn")
struct VoiceNoteRenderTests {
    private var style: MessageTextStyle { MessageTextStyle.current() }
    private let id = AttachmentID(rawValue: 3)

    private func row(settings: TimelineSettings = .comfortable, seconds: Double = 14) -> TimelineRow {
        // A real sentence's shape, as `VoiceWaveform.displayed`'s test measured it.
        let values: [UInt8] = (0..<64).map { index in
            let wave = sin(Double(index) / 2.3) * sin(Double(index) / 7.1)
            return UInt8(max(0, min(255, 190 + wave * 70)))
        }
        let message = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: ChannelID(rawValue: 1),
            authorID: UserID(rawValue: 7),
            flags: .isVoiceMessage,
            payload: MessagePayload(attachments: [
                WingcordCore.Attachment(
                    id: id,
                    filename: "voice-message.ogg",
                    url: "https://cdn.discordapp.com/attachments/1/3/voice-message.ogg",
                    proxyURL: "https://media.discordapp.net/attachments/1/3/voice-message.ogg",
                    contentType: "audio/ogg",
                    size: 4_096,
                    waveform: VoiceWaveform.encode(values),
                    durationSeconds: seconds
                ),
            ])
        )
        let engine = TimelineLayoutEngine(presentationRevision: 0)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return engine.layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: 560,
                style: style,
                mentions: MentionContext(),
                channelName: "general",
                authors: [
                    UserID(rawValue: 7): TimelineLayoutEngine.AuthorInfo(
                        name: "Staff", colorValue: nil, avatarURL: nil,
                        monogram: "S", decorationURL: nil, isBot: false
                    ),
                ],
                calendar: .current,
                settings: settings
            ),
            cache: &cache
        )[0]
    }

    private func pixels(_ row: TimelineRow, playback: VoiceNotePlayback?, name: String) throws -> [UInt8] {
        var state = TimelineRowPainter.State()
        state.voicePlayback = playback
        let height = Int(row.height) + 10
        let pixels = RenderProbe.pixels(width: 560, height: height) { context, _ in
            TimelineRowPainter.draw(
                row: row,
                in: CGRect(x: 0, y: 0, width: 560, height: row.height),
                context: context,
                style: self.style,
                state: state,
                images: ImageStore.shared,
                scale: 1
            )
        }
        try write(row, state: state, name: name)
        return pixels
    }

    /// At 2×, on the room's own ground, to be looked at.
    private func write(_ row: TimelineRow, state: TimelineRowPainter.State, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"] else { return }
        let scale: CGFloat = 2
        let size = CGSize(width: 560, height: row.height + 10)
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(ThemeInk.current.canvas)
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        TimelineRowPainter.draw(
            row: row,
            in: CGRect(x: 0, y: 0, width: 560, height: row.height),
            context: context,
            style: style,
            state: state,
            images: ImageStore.shared,
            scale: scale
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("voice-\(name).png"))
    }

    private func differs(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
    }

    @Test func itIsAVoiceRowWithRealBars() throws {
        guard case .message(let message) = row().kind else {
            Issue.record("expected a message row")
            return
        }
        let slot = try #require(message.attachments.first)
        #expect(slot.kind == .voice)
        let voice = try #require(slot.voice)
        #expect(voice.duration == 14)
        // Not one level: the drawing pulled the sentence apart.
        #expect(Set(voice.bars).count > 8)
        #expect(voice.bars.min()! < 0.2)
        #expect(voice.bars.max()! > 0.8)
    }

    @Test func eachStateDrawsDifferently() throws {
        let row = row()
        let untouched = try pixels(row, playback: nil, name: "untouched")
        #expect(untouched.contains { $0 != UInt8(RenderProbe.ground * 255) })

        var playing = VoiceNotePlayback()
        playing.current = id
        playing.isPlaying = true
        playing.position = 6
        let halfway = try pixels(row, playback: playing, name: "playing")
        #expect(differs(untouched, halfway) > 100)

        var paused = playing
        paused.isPlaying = false
        let stopped = try pixels(row, playback: paused, name: "paused")
        // The same bars lit, and the disc says the other thing.
        #expect(differs(halfway, stopped) > 10)

        var loading = VoiceNotePlayback()
        loading.current = id
        loading.isLoading = true
        #expect(differs(untouched, try pixels(row, playback: loading, name: "loading")) > 10)

        var failed = VoiceNotePlayback()
        failed.failed = [id]
        #expect(differs(untouched, try pixels(row, playback: failed, name: "failed")) > 10)

        var fast = VoiceNotePlayback()
        fast.rate = 1.5
        #expect(differs(untouched, try pixels(row, playback: fast, name: "fast")) > 4)
    }

    /// A row that's been passed swells: the bar just behind the playhead is taller than
    /// it'll be once it settles.
    @Test func aBarThePlayheadJustPassedSwells() {
        #expect(VoiceWaveform.popped(0.5, age: 0.15) > 0.5)
        #expect(VoiceWaveform.popped(0.5, age: 0.6) == 0.5)
        // Never lower than a tenth under, even as it starts: Discord's floor.
        #expect(VoiceWaveform.popped(0.5, age: 0) >= 0.4)
    }

    @Test func itHasAPictureForItsFlight() throws {
        guard case .message(let message) = row().kind, let slot = message.attachments.first else {
            Issue.record("expected a message row")
            return
        }
        let image = try #require(TimelineRowPainter.voiceNoteImage(slot, style: style, scale: 2))
        #expect(image.width == Int(slot.rect.width * 2))
    }
}
