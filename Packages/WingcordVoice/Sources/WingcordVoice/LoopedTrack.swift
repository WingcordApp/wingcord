import AVFoundation
import Foundation
import Synchronization
import WingcordCore

/// A long sound looped into a call's mix, read a frame at a time — Discord's
/// stage waiting music (`stage_waiting`, module 30108).
///
/// **Read from the file as it plays, never decoded whole.** The waiting music
/// runs a minute and a half; decoded to the mix's format it would be about
/// thirty-five megabytes, held for as long as somebody sits in an empty stage.
/// Twenty milliseconds of AAC out of a one-megabyte file is microseconds, and
/// the mix pump reads it before it takes the call's lock, so no packet is ever
/// routed behind a file read.
///
/// **Mixed by the call, never played by a second engine**: out of the call's
/// device, at the call's output volume, inside the echo canceller's reference —
/// INVARIANTS §1.5, "Echo cancellation only works through one engine".
public final class LoopedTrack: Sendable {
    private struct Reader {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        /// The next frame, interleaved, at the track's gain.
        var frame: [Float]
        var playback = StageMusic.Playback.stopped
    }

    private let reader: Mutex<Reader>
    private let gain: Float

    /// Nil when the file cannot be opened or is not the mix's own format —
    /// 48 kHz stereo, so that nothing resamples on the pump.
    ///
    /// - Parameter gain: the track's level beneath the call's output volume.
    public init?(url: URL, gain: Float) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard format.sampleRate == Double(OpusFormat.sampleRate),
              format.channelCount == AVAudioChannelCount(OpusFormat.channels),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(OpusFormat.frameSize)
              )
        else { return nil }
        reader = Mutex(Reader(
            file: file,
            buffer: buffer,
            frame: [Float](repeating: 0, count: OpusFormat.interleavedCount)
        ))
        self.gain = gain
    }

    /// Stopped goes back to the top; paused keeps its place.
    public func setPlayback(_ playback: StageMusic.Playback) {
        reader.withLock { reader in
            guard reader.playback != playback else { return }
            reader.playback = playback
            if playback == .stopped { reader.file.framePosition = 0 }
        }
    }

    /// Reads the next 20 ms, wrapping at the end — the half of a frame that
    /// touches the file, done before the pump takes the call's lock. False
    /// while silent, and for good on a file that will not read.
    func read() -> Bool {
        reader.withLock { reader in
            guard reader.playback == .playing else { return false }
            let frames = Int(OpusFormat.frameSize)
            var filled = 0
            while filled < frames {
                // **From the top before the end, never after it**: a read at
                // the end of the file throws rather than coming back empty.
                if reader.file.framePosition >= reader.file.length {
                    reader.file.framePosition = 0
                }
                let remaining = reader.file.length - reader.file.framePosition
                do {
                    try reader.file.read(
                        into: reader.buffer,
                        frameCount: AVAudioFrameCount(min(Int64(frames - filled), remaining))
                    )
                } catch {
                    reader.playback = .stopped
                    return false
                }
                let got = Int(reader.buffer.frameLength)
                guard got > 0, let channels = reader.buffer.floatChannelData else {
                    // A file with nothing in it.
                    reader.playback = .stopped
                    return false
                }
                let left = channels[0]
                let right = channels[1]
                for index in 0..<got {
                    reader.frame[(filled + index) * 2] = left[index] * gain
                    reader.frame[(filled + index) * 2 + 1] = right[index] * gain
                }
                filled += got
            }
            return true
        }
    }

    /// Adds the frame `read()` prepared.
    func add(into mix: inout [Float]) {
        reader.withLock { reader in
            for index in 0..<OpusFormat.interleavedCount {
                mix[index] += reader.frame[index]
            }
        }
    }
}
