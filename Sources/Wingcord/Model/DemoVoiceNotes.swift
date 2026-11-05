import AVFoundation
import Foundation
import WingcordCore
import WingcordVoice

// MARK: - Voice messages, for `--demo`
//
// docs/VOICE-MESSAGES.md D13. **Real audio, in real Ogg Opus**, spoken by the system's own
// voice and encoded by the same code a recording goes through, so what plays here and the
// waveform it shows are the real path end to end. Spoken once and kept in Caches: the first
// launch has them a couple of seconds in, and every launch after has them straight away.
//
// | fixture | where |
// | --- | --- |
// | three lengths, from them and from the reader, the newest a note | the third conversation |
// | one from them, one from the reader | The Iris Project › #faq, above its links |

@MainActor
enum DemoVoiceNotes {
    private struct Spec {
        var name: String
        var words: String
        var isMine: Bool
        var minutesAgo: Double
    }

    private static let conversation: [Spec] = [
        Spec(
            name: "short",
            words: "Hey, are you around? Call me when you get a second.",
            isMine: false,
            minutesAgo: 44
        ),
        Spec(
            name: "reply",
            words: "Yeah, give me ten minutes. I'm just finishing the build, and then I'm all yours. "
                + "Actually, while I have you, did you see what they did with the new update?",
            isMine: true,
            minutesAgo: 41
        ),
        Spec(
            name: "long",
            words: "Okay so I finally had a proper look at it, and honestly I think it's the best one they've done. "
                + "The whole first area has been rebuilt, the lighting is completely different, and they fixed that "
                + "bug with the bridge that kept dropping everybody into the water. I played for about two hours "
                + "last night and I only stopped because it got so late. The only thing I'm not sure about is the "
                + "new map. It looks great, but it takes forever to find anything on it, and I got lost twice trying "
                + "to get back to the harbour. Anyway, we should definitely play this weekend. Saturday works for me, "
                + "probably any time after lunch. Let me know what suits you and I'll get everyone else on. "
                + "Oh, and bring the good headset this time, because last week you sounded like you were calling "
                + "from inside a washing machine.",
            isMine: false,
            minutesAgo: 12
        ),
    ]

    private static let channel: [Spec] = [
        Spec(
            name: "faq-question",
            words: "Quick question for whoever's around. Does the invite link still work if the server's full?",
            isMine: false,
            minutesAgo: 90
        ),
        Spec(
            name: "faq-answer",
            words: "It does. It just puts you on the waiting list.",
            isMine: true,
            minutesAgo: 86
        ),
    ]

    private nonisolated struct Rendered: Codable {
        var durationSeconds: Double
        var waveform: String
        var size: Int
    }

    // MARK: Filling them in

    static func populate(_ model: AppModel, guildID: GuildID, me: UserID, people: [UserID]) {
        guard LaunchOptions.current.usesDemoFixtures else { return }
        let others = people.filter { $0 != me }
        let privates = model.channelIndex.privateChannelIDs()
        guard privates.count > 3, let partner = model.channelIndex[privates[3]]?.recipientIDs.first else { return }
        let dm = privates[3]
        let faq = model.channelIndex.channelIDs(inGuild: guildID).first { model.channelIndex[$0]?.name == "faq" }
        let asker = others.first ?? partner

        let insert = {
            place(conversation, in: dm, partner: partner, me: me, model: model)
            if let faq { place(channel, in: faq, partner: asker, me: me, model: model) }
        }
        if (conversation + channel).allSatisfy({ load($0) != nil }) {
            insert()
            return
        }
        Task {
            for spec in conversation + channel where load(spec) == nil {
                await render(spec)
            }
            insert()
        }
    }

    /// Puts the notes in a transcript, and says so to a conversation that's already open.
    private static func place(
        _ specs: [Spec], in channelID: ChannelID, partner: UserID, me: UserID, model: AppModel
    ) {
        var box = model.demoTranscripts[channelID] ?? {
            var fresh = MessageBox()
            fresh.hasMoreHistory = false
            return fresh
        }()
        var notes: [Message] = []
        for (offset, spec) in specs.enumerated() {
            guard let rendered = load(spec) else { continue }
            let id = snowflake(minutesAgo: spec.minutesAgo, serial: 900 + UInt64(offset))
            let url = audioURL(for: spec).absoluteString
            notes.append(Message(
                id: MessageID(rawValue: id),
                channelID: channelID,
                authorID: spec.isMine ? me : partner,
                flags: .isVoiceMessage,
                payload: MessagePayload(attachments: [
                    Attachment(
                        id: AttachmentID(rawValue: id),
                        filename: VoiceMessageLimits.filename,
                        url: url,
                        proxyURL: url,
                        contentType: "audio/ogg",
                        size: rendered.size,
                        waveform: rendered.waveform,
                        durationSeconds: rendered.durationSeconds
                    ),
                ])
            ))
        }
        // In time order among whatever's there.
        box.messages = (box.messages + notes).sorted { $0.id.rawValue < $1.id.rawValue }
        model.demoTranscripts[channelID] = box
        // Keeps the conversation's newest as what its list row shows.
        if let last = box.messages.last, model.channelIndex[channelID]?.kind.isPrivate == true {
            var index = model.channelIndex
            index.patchLastMessage(last.id, in: channelID)
            model.channelIndex = index
            model.receivePreviews([last])
        }
        if model.messages(in: channelID) != nil { model.setMessages(box, in: channelID) }
    }

    /// `--open-channel=NAME`: the demo opens there, a channel by name, or the Nth
    /// conversation as `@N`, so a surface can be looked at with nobody at the mouse.
    static func openRequestedChannel(_ model: AppModel) {
        guard let wanted = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--open-channel=") })?
            .dropFirst("--open-channel=".count)
        else { return }
        let index = model.channelIndex
        if wanted.hasPrefix("@"), let number = Int(wanted.dropFirst()),
           let channelID = index.privateChannelIDs().dropFirst(number).first
        {
            model.openDirectMessage(channelID)
        } else if let channelID = model.orderedGuildIDs.lazy.compactMap({ guildID in
            index.channelIDs(inGuild: guildID).first { index[$0]?.name == String(wanted) }
        }).first {
            model.selectChannel(channelID)
        }
    }

    private static func snowflake(minutesAgo: Double, serial: UInt64) -> UInt64 {
        let milliseconds = UInt64(Date.now.addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970 * 1_000)
        return ((milliseconds - Snowflake<MessageTag>.epochMilliseconds) << 22) | (serial & 0xFFF)
    }

    // MARK: Speaking and encoding

    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.wingcord.Wingcord.demo", isDirectory: true)
            .appendingPathComponent("DemoVoiceNotes", isDirectory: true)
    }

    private static func audioURL(for spec: Spec) -> URL {
        folder.appendingPathComponent("\(spec.name).ogg")
    }

    private static func detailsURL(for spec: Spec) -> URL {
        folder.appendingPathComponent("\(spec.name).json")
    }

    private static func load(_ spec: Spec) -> Rendered? {
        guard FileManager.default.fileExists(atPath: audioURL(for: spec).path),
              let data = try? Data(contentsOf: detailsURL(for: spec))
        else { return nil }
        return try? JSONDecoder().decode(Rendered.self, from: data)
    }

    private static func render(_ spec: Spec) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let speech = folder.appendingPathComponent("\(spec.name).caf")
        defer { try? FileManager.default.removeItem(at: speech) }
        guard await DemoMedia.speak(spec.words, to: speech) else { return }
        let destination = audioURL(for: spec)
        let details = detailsURL(for: spec)
        await Task.detached(priority: .userInitiated) {
            guard let file = try? encode(speech: speech, to: destination) else { return }
            let rendered = Rendered(
                durationSeconds: file.durationSeconds,
                waveform: VoiceWaveform.encode(file.samples),
                size: file.byteCount
            )
            try? JSONEncoder().encode(rendered).write(to: details)
        }.value
    }

    /// A file of speech, through the same encoder and writer a recording goes through.
    private nonisolated static func encode(speech: URL, to destination: URL) throws -> VoiceNoteFile {
        let source = try AVAudioFile(forReading: speech)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true
        ),
            let converter = AVAudioConverter(from: source.processingFormat, to: target),
            let input = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length)
            )
        else { throw CocoaError(.fileReadCorruptFile) }
        try source.read(into: input)
        let ratio = 48_000 / source.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(
            pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 4_096
        ) else { throw CocoaError(.fileReadCorruptFile) }
        nonisolated(unsafe) let unsafeInput = input
        nonisolated(unsafe) var isDone = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            if isDone {
                status.pointee = .endOfStream
                return nil
            }
            isDone = true
            status.pointee = .haveData
            return unsafeInput
        }
        if let failure { throw failure }
        guard let samples = output.int16ChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }

        let recording = try VoiceNoteRecording(url: destination)
        let width = Int(OpusFormat.voiceFrameCount)
        var start = 0
        while start + width <= Int(output.frameLength) {
            let frame = samples + start
            var sum = 0.0
            for index in 0..<width {
                let value = Double(frame[index]) / 32_768
                sum += value * value
            }
            recording.ingest(frame, level: Float((sum / Double(width)).squareRoot()))
            start += width
        }
        return try recording.finish()
    }
}
