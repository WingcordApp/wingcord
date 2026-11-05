import Foundation
import Synchronization
import WingcordCore

// MARK: - A voice message being recorded
//
// Takes the frames a capture delivers, 20 ms of 48 kHz mono at a time, and turns them
// into an Ogg Opus file and a waveform.
//
// **Encoded on the thread that delivers them.** A packet costs about a millisecond
// against twenty, and the file is written a second at a time, so there's nothing to
// queue, and nothing queued to lose or to wait for at Stop. The lock is only ever
// contended by Stop itself.

/// A finished recording.
public struct VoiceNoteFile: Sendable, Equatable {
    public var url: URL
    public var durationSeconds: Double
    /// One byte per frame, at full length: see `VoiceWaveform`.
    public var samples: [UInt8]
    public var byteCount: Int

    public init(url: URL, durationSeconds: Double, samples: [UInt8], byteCount: Int) {
        self.url = url
        self.durationSeconds = durationSeconds
        self.samples = samples
        self.byteCount = byteCount
    }
}

public final class VoiceNoteRecording: Sendable {
    /// **48 kbps**: a clear voice, and twenty minutes comes to 7.2 MB, under the 10 MB
    /// upload limit every account has.
    public static let bitrate: Int32 = 48_000

    private struct State {
        var encoder: OpusEncoder?
        var writer: OggOpusWriter?
        var packet = [UInt8](repeating: 0, count: OpusFormat.maximumPacketBytes)
        var samples: [UInt8] = []
        var failure: (any Error)?

        /// Whether the frame made it into the file.
        mutating func write(_ frame: UnsafePointer<Int16>, level: Float) -> Bool {
            guard let encoder, let writer else { return false }
            do {
                let written = try encoder.encode(frame, into: &packet)
                try packet.withUnsafeBufferPointer { bytes in
                    try writer.append(UnsafeBufferPointer(rebasing: bytes[0..<written]), samples: Int(OpusFormat.frameSize))
                }
                samples.append(VoiceWaveform.sample(level: level))
                return true
            } catch {
                // The disk filled, or the encoder gave up. Stop says what happened.
                failure = error
                self.encoder = nil
                return false
            }
        }
    }

    private let state: Mutex<State>
    private let url: URL
    private let frames = Atomic<Int>(0)
    private let latestLevel = Atomic<UInt32>(0)

    /// Creates the file and gets the encoder ready.
    public init(url: URL) throws {
        let encoder = try OpusEncoder(bitrate: Self.bitrate, signal: .voiceNote)
        let writer = try OggOpusWriter(url: url, preSkip: UInt16(clamping: encoder.lookahead))
        state = Mutex(State(encoder: encoder, writer: writer))
        self.url = url
    }

    // MARK: What the composer reads, every frame

    /// The latest frame's level, 0…1, for the bars going by.
    public var level: Float { Float(bitPattern: latestLevel.load(ordering: .relaxed)) }

    /// How much has actually been captured. The timer is this rather than a clock: a
    /// microphone that took a second to wake hasn't recorded that second.
    public var elapsedSeconds: Double {
        Double(frames.load(ordering: .relaxed)) * Double(OpusFormat.frameSize) / Double(OpusFormat.sampleRate)
    }

    // MARK: The capture thread

    /// One frame of `OpusFormat.voiceFrameCount` samples, and its level.
    public func ingest(_ frame: UnsafePointer<Int16>, level: Float) {
        let frame = CapturedFrame(base: frame)
        guard state.withLock({ $0.write(frame.base, level: level) }) else { return }
        latestLevel.store(level.bitPattern, ordering: .relaxed)
        frames.add(1, ordering: .relaxed)
    }

    // MARK: Ending

    /// Closes the file. Anything delivered after this is dropped.
    public func finish() throws -> VoiceNoteFile {
        let (writer, samples, failure) = state.withLock { state in
            let writer = state.writer
            state.writer = nil
            state.encoder = nil
            return (writer, state.samples, state.failure)
        }
        if let failure { throw failure }
        try writer?.finish()
        return VoiceNoteFile(
            url: url,
            durationSeconds: Double(samples.count) * Double(OpusFormat.frameSize) / Double(OpusFormat.sampleRate),
            samples: samples,
            byteCount: writer?.bytesWritten ?? 0
        )
    }

    /// Throws it all away.
    public func cancel() {
        state.withLock { state in
            state.writer = nil
            state.encoder = nil
        }
        try? FileManager.default.removeItem(at: url)
    }
}
