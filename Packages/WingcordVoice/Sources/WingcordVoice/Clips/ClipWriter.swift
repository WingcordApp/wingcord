import AVFoundation
import CoreMedia
import Foundation
import OSLog
import WingcordCore

// MARK: - Saving a clip
//
// docs/CLIPS-PRESENCE.md, Phase 3.1. The picture is written as it was encoded
// — no re-encode, from the keyframe at or before "N seconds ago" — and the
// sound is decoded from Opus and written as AAC, track by track:
//
//   1. **Everything kept, mixed** — enabled, so QuickTime, a browser or
//      Discord plays the file right as it is. Players play the first enabled
//      audio track (QuickTime mixes every enabled one), so it is the only
//      enabled one.
//   2. One **disabled stem per source** — the game, the reader's microphone,
//      each person in the call, the soundboard — for the editor to take apart
//      (Discord's editor splits a clip's tracks the same way).
//
// Rendered a tenth of a second at a time, so two minutes of eight tracks is
// never eight two-minute buffers in memory at once.

public enum ClipWriter {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Clips")

    public struct Request: Sendable {
        public var url: URL
        /// Seconds the clip should last.
        public var length: Double
        public var video: ReplayVideoRing
        public var gameSound: TimedAudioTrack
        public var call: ClipAudioTap.Snapshot?
        public var selfUserID: UInt64?
        /// Track titles: who each voice is.
        public var names: [UInt64: String]
        public var gameName: String?

        public init(
            url: URL, length: Double, video: ReplayVideoRing, gameSound: TimedAudioTrack,
            call: ClipAudioTap.Snapshot?, selfUserID: UInt64?, names: [UInt64: String], gameName: String?
        ) {
            self.url = url
            self.length = length
            self.video = video
            self.gameSound = gameSound
            self.call = call
            self.selfUserID = selfUserID
            self.names = names
            self.gameName = gameName
        }
    }

    public struct Result: Sendable {
        public var url: URL
        /// Host-clock seconds of the first picture — what the timeline is
        /// measured from.
        public var start: Double
        public var end: Double
        public var tracks: [ClipAudioTrack]
        /// Everybody whose voice is in a track.
        public var voices: [UInt64]

        public var duration: Double { end - start }
    }

    public enum Failure: Error, LocalizedError, Sendable {
        case nothingKept
        case writer(String)

        public var errorDescription: String? {
            switch self {
            case .nothingKept: "Nothing has been kept yet — the buffer is still warming up."
            case .writer(let reason): reason
            }
        }
    }

    public static func write(_ request: Request) async throws -> Result {
        let frames = request.video.frames(lasting: request.length)
        guard let first = frames.first, let last = frames.last else { throw Failure.nothingKept }
        let start = first.presentation.seconds
        let end = last.presentation.seconds + max(last.duration.seconds.isFinite ? last.duration.seconds : 0, 0)
        let sampleCount = Int(((end - start) * Double(OpusFormat.sampleRate)).rounded())

        // The sources, each kept only if it has something in the window.
        var stems: [(track: ClipAudioTrack, source: AudioSource)] = []
        let window = (start - 1)...(end)
        func inWindow(_ track: TimedAudioTrack) -> [TimedAudioFrame] {
            track.frames(from: window.lowerBound, to: window.upperBound)
        }
        let game = inWindow(request.gameSound)
        if AudioSource.isAudible(game, between: start, and: end) {
            stems.append((ClipAudioTrack(role: .game, title: request.gameName ?? "Game", isEnabled: false), .opus(game)))
        }
        var voices: [UInt64] = []
        if let call = request.call {
            let microphone = inWindow(call.microphone)
            if AudioSource.isAudible(microphone, between: start, and: end) {
                let name = request.selfUserID.flatMap { request.names[$0] } ?? "You"
                stems.append((ClipAudioTrack(role: .microphone, title: name, isEnabled: false), .opus(microphone)))
                if let me = request.selfUserID { voices.append(me) }
            }
            for userID in call.voices.keys.sorted() {
                let kept = inWindow(call.voices[userID] ?? TimedAudioTrack())
                guard AudioSource.isAudible(kept, between: start, and: end) else { continue }
                stems.append((
                    ClipAudioTrack(role: .voice(userID: userID), title: request.names[userID] ?? "Voice", isEnabled: false),
                    .opus(kept)
                ))
                voices.append(userID)
            }
            let plays = call.soundboard.filter { $0.time <= end && $0.time + Double($0.samples.count / 2) / 48_000 >= start }
            if !plays.isEmpty {
                stems.append((ClipAudioTrack(role: .soundboard, title: "Soundboard", isEnabled: false), .soundboard(plays)))
            }
        }

        try? FileManager.default.removeItem(at: request.url)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: request.url, fileType: .mp4)
        } catch {
            throw Failure.writer(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: first.format.formatDescription
        )
        guard writer.canAdd(videoInput) else { throw Failure.writer("The picture could not be written.") }
        var feeds: [Feed] = [VideoFeed(receiver: writer.inputReceiver(for: videoInput), ring: request.video, frames: frames)]
        var tracks: [ClipAudioTrack] = []
        if !stems.isEmpty {
            let mix = ClipAudioTrack(role: .mix, title: "Everything", isEnabled: true)
            let mixSource = AudioSource.mix(stems.map(\.source))
            for (track, source) in [(mix, mixSource)] + stems {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Double(OpusFormat.sampleRate),
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: track.role == .mix || track.role == .game ? 160_000 : 96_000,
                ])
                input.marksOutputTrackAsEnabled = track.isEnabled
                input.languageCode = "und"
                guard writer.canAdd(input) else { continue }
                feeds.append(AudioFeed(
                    receiver: writer.inputReceiver(for: input), renderer: source.renderer(start: start),
                    start: start, count: sampleCount
                ))
                tracks.append(track)
            }
        }

        do {
            try writer.start()
        } catch {
            throw Failure.writer(writer.error?.localizedDescription ?? error.localizedDescription)
        }
        writer.startSession(atSourceTime: first.presentation)

        // One task per track: the writer suspends whichever has run ahead of
        // the others, which is what interleaves them in the file.
        await withTaskGroup(of: Void.self) { group in
            for feed in feeds {
                group.addTask { await feed.run() }
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.writer(writer.error?.localizedDescription ?? "The clip could not be finished.")
        }
        log.info("clips: wrote \(String(format: "%.1f", end - start), privacy: .public) s, \(tracks.count, privacy: .public) audio tracks")
        return Result(url: request.url, start: start, end: end, tracks: tracks, voices: voices)
    }
}

// MARK: - Feeding the writer

/// One track's samples, appended in order until there are no more.
///
/// `@unchecked` for the receiver, which the writer hands over `sending` and
/// which only this feed's own task ever touches.
private class Feed: @unchecked Sendable {
    let receiver: AVAssetWriterInput.SampleBufferReceiver

    init(receiver: sending AVAssetWriterInput.SampleBufferReceiver) {
        self.receiver = receiver
    }

    /// The next sample, or nil when there are no more.
    func next() -> CMSampleBuffer? { nil }

    func run() async {
        // A sample the writer refuses ends this track rather than the clip:
        // the others still finish.
        while let sample = next() {
            do {
                try await receiver.append(CMReadySampleBuffer(unsafeBuffer: sample))
            } catch {
                break
            }
        }
        receiver.finish()
    }
}

private final class VideoFeed: Feed, @unchecked Sendable {
    private let ring: ReplayVideoRing
    private let frames: [ReplayVideoRing.Frame]
    private var index = 0

    init(receiver: sending AVAssetWriterInput.SampleBufferReceiver, ring: ReplayVideoRing, frames: [ReplayVideoRing.Frame]) {
        self.ring = ring
        self.frames = frames
        super.init(receiver: receiver)
    }

    override func next() -> CMSampleBuffer? {
        while index < frames.count {
            defer { index += 1 }
            if let sample = ring.sampleBuffer(for: frames[index]) { return sample }
        }
        return nil
    }
}

private final class AudioFeed: Feed, @unchecked Sendable {
    /// A tenth of a second per sample buffer.
    private static let chunk = 4_800

    private let renderer: AudioRenderer
    private let start: Double
    private let count: Int
    private var position = 0
    private var format: CMAudioFormatDescription?

    init(receiver: sending AVAssetWriterInput.SampleBufferReceiver, renderer: AudioRenderer, start: Double, count: Int) {
        self.renderer = renderer
        self.start = start
        self.count = count
        super.init(receiver: receiver)
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(OpusFormat.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0
        )
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
    }

    override func next() -> CMSampleBuffer? {
        guard position < count, let format else { return nil }
        let frames = min(Self.chunk, count - position)
        var samples = [Float](repeating: 0, count: frames * 2)
        samples.withUnsafeMutableBufferPointer { renderer.render(into: $0, from: position, count: frames) }
        defer { position += frames }

        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = samples.withUnsafeBytes { buffer in
            CMBlockBufferReplaceDataBytes(
                with: buffer.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        let first = Int64((start * Double(OpusFormat.sampleRate)).rounded()) + Int64(position)
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: CMTime(value: first, timescale: OpusFormat.sampleRate),
            packetDescriptions: nil, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}

// MARK: - The sound, rendered

/// Where one track's sound comes from.
enum AudioSource: @unchecked Sendable {
    case opus([TimedAudioFrame])
    case soundboard([ClipAudioTap.SoundboardPlay])
    case mix([AudioSource])

    /// Whether any frame with sound in it falls in the window. Discord's
    /// clients close a talkspurt with Opus silence frames — three bytes —
    /// which are not sound.
    static func isAudible(_ frames: [TimedAudioFrame], between start: Double, and end: Double) -> Bool {
        frames.contains { frame in
            guard frame.time >= start - OpusFrame.duration, frame.time <= end else { return false }
            if case .opus(let bytes) = frame.payload { return bytes.count > 3 }
            return false
        }
    }

    func renderer(start: Double) -> AudioRenderer {
        switch self {
        case .opus(let frames): OpusRenderer(frames: frames, start: start)
        case .soundboard(let plays): SoundboardRenderer(plays: plays, start: start)
        case .mix(let sources): MixRenderer(parts: sources.map { $0.renderer(start: start) })
        }
    }
}

/// Renders a track forward, a stretch at a time: adds its sound into an
/// interleaved stereo buffer the caller zeroed.
class AudioRenderer {
    func render(into buffer: UnsafeMutableBufferPointer<Float>, from position: Int, count: Int) {}
}

/// Opus frames placed on the clip's timeline and decoded as they are reached.
///
/// **Placed in runs, not frame by frame.** A frame's stamp is when the mixer
/// or the capture made it, which wobbles by milliseconds; laying each at its
/// own stamp would overlap or gap neighbours by a few samples, which is a
/// click fifty times a second. Within a run — frames arriving every 20 ms —
/// each lands right after the last; a new run begins at a gap or when the
/// stamps have drifted more than 30 ms from the run's own count.
final class OpusRenderer: AudioRenderer {
    private struct Placed {
        var position: Int
        var payload: TimedAudioFrame.Payload
    }

    private let placed: [Placed]
    private var next = 0
    private var decoded: [(position: Int, samples: [Float])] = []
    private let decoder = try? OpusDecoder()
    private var pcm = [Int16](repeating: 0, count: OpusFormat.interleavedCount)

    init(frames: [TimedAudioFrame], start: Double) {
        let rate = Double(OpusFormat.sampleRate)
        let width = Int(OpusFormat.frameSize)
        var placed: [Placed] = []
        var anchor: (time: Double, position: Int)?
        var count = 0
        for frame in frames.sorted(by: { $0.time < $1.time }) {
            let natural = Int(((frame.time - start) * rate).rounded())
            if let current = anchor {
                let expected = current.time + Double(count) * OpusFrame.duration
                if abs(frame.time - expected) > 0.03 {
                    anchor = (frame.time, natural)
                    count = 0
                }
            } else {
                anchor = (frame.time, natural)
                count = 0
            }
            placed.append(Placed(position: (anchor?.position ?? natural) + count * width, payload: frame.payload))
            count += 1
        }
        self.placed = placed
    }

    override func render(into buffer: UnsafeMutableBufferPointer<Float>, from position: Int, count: Int) {
        let end = position + count
        let width = Int(OpusFormat.frameSize)
        // Every frame is decoded in order, the ones before the clip too: the
        // decoder's state is the stream's history, and a decoder that starts
        // cold mid-word says the first frame wrong.
        while next < placed.count, placed[next].position < end {
            let frame = placed[next]
            next += 1
            guard let samples = decode(frame.payload), frame.position + width > position else { continue }
            decoded.append((frame.position, samples))
        }
        for (framePosition, samples) in decoded {
            let low = max(position, framePosition)
            let high = min(end, framePosition + width)
            guard low < high else { continue }
            for index in low..<high {
                let source = (index - framePosition) * 2
                let target = (index - position) * 2
                buffer[target] += samples[source]
                buffer[target + 1] += samples[source + 1]
            }
        }
        decoded.removeAll { $0.position + width <= end }
    }

    private func decode(_ payload: TimedAudioFrame.Payload) -> [Float]? {
        guard let decoder else { return nil }
        let written: Int? = pcm.withUnsafeMutableBufferPointer { buffer in
            switch payload {
            case .opus(let bytes): try? decoder.decode(bytes, into: buffer.baseAddress!)
            case .recovered(let successor): try? decoder.decode(successor, recoverFromFEC: true, into: buffer.baseAddress!)
            case .concealed: try? decoder.decode(nil, into: buffer.baseAddress!)
            }
        }
        guard written != nil else { return nil }
        return pcm.map { Float($0) / 32_768 }
    }
}

/// Soundboard sounds, each at the moment it was played into the call.
final class SoundboardRenderer: AudioRenderer {
    private let plays: [(position: Int, play: ClipAudioTap.SoundboardPlay)]

    init(plays: [ClipAudioTap.SoundboardPlay], start: Double) {
        self.plays = plays.map { (Int((($0.time - start) * Double(OpusFormat.sampleRate)).rounded()), $0) }
    }

    override func render(into buffer: UnsafeMutableBufferPointer<Float>, from position: Int, count: Int) {
        let end = position + count
        for (playPosition, play) in plays {
            let length = play.samples.count / 2
            let low = max(position, playPosition)
            let high = min(end, playPosition + length)
            guard low < high else { continue }
            for index in low..<high {
                let source = (index - playPosition) * 2
                let target = (index - position) * 2
                buffer[target] += play.samples[source] * play.volume
                buffer[target + 1] += play.samples[source + 1] * play.volume
            }
        }
    }
}

/// Every source summed, with the call mixer's soft knee instead of a clamp.
final class MixRenderer: AudioRenderer {
    private let parts: [AudioRenderer]

    init(parts: [AudioRenderer]) {
        self.parts = parts
    }

    override func render(into buffer: UnsafeMutableBufferPointer<Float>, from position: Int, count: Int) {
        for part in parts { part.render(into: buffer, from: position, count: count) }
        for index in buffer.indices {
            let value = buffer[index]
            if value > 1 || value < -1 { buffer[index] = tanhf(value) }
        }
    }
}
