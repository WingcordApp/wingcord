import Foundation
import Testing
@testable import WingcordVoice

/// Auto Clips' ears (docs/CLIPS-PRESENCE.md, Phase 7.2): kept Opus frames
/// decoded back onto the window they were heard in, and the classifier asked
/// about them.
@Suite("Clip emotion listener")
struct ClipEmotionListenerTests {

    /// `seconds` of a tone, as the soundshare encoder would keep it: 20 ms
    /// Opus frames stamped from `start`.
    private func tone(from start: Double, seconds: Double, hertz: Double = 440) throws -> TimedAudioTrack {
        let encoder = try OpusEncoder(bitrate: 96_000, signal: .soundshare)
        var output = [UInt8](repeating: 0, count: OpusFormat.maximumPacketBytes)
        var frames: [TimedAudioFrame] = []
        let width = Int(OpusFormat.frameSize)
        let count = Int(seconds * Double(OpusFormat.sampleRate)) / width
        for index in 0 ..< count {
            var pcm = [Int16](repeating: 0, count: OpusFormat.interleavedCount)
            for sample in 0 ..< width {
                let t = Double(index * width + sample) / Double(OpusFormat.sampleRate)
                let value = Int16(sin(2 * .pi * hertz * t) * 12_000)
                pcm[sample * 2] = value
                pcm[sample * 2 + 1] = value
            }
            let written = try pcm.withUnsafeBufferPointer { try encoder.encode($0.baseAddress!, into: &output) }
            frames.append(TimedAudioFrame(
                time: start + Double(index) * OpusFrame.duration,
                payload: .opus(Array(output.prefix(written)))
            ))
        }
        return TimedAudioTrack(frames: frames)
    }

    @Test("Kept frames are decoded onto the window where they were heard")
    func mixPlacesFrames() throws {
        // A second of tone starting one second into a three-second window.
        let track = try tone(from: 101, seconds: 1)
        let mono = ClipEmotionListener.mix([track], from: 100, to: 103)
        #expect(mono.count == 144_000)
        func energy(_ range: Range<Int>) -> Float {
            mono[range].reduce(0) { $0 + abs($1) } / Float(range.count)
        }
        #expect(energy(0 ..< 40_000) < 0.01, "silent before the tone")
        #expect(energy(52_000 ..< 90_000) > 0.1, "the tone where it was heard")
        #expect(energy(110_000 ..< 144_000) < 0.01, "silent after it")
    }

    @Test("Silence is heard as nothing, without asking the classifier")
    func silence() {
        let snapshot = ClipAudioTap.Snapshot(voices: [:], microphone: TimedAudioTrack(), soundboard: [], speaking: [])
        #expect(ClipEmotionListener().listen(to: snapshot, from: 0, to: 3) == .nothing)
    }

    @Test("A steady tone is neither laughter nor shouting")
    func toneIsNotEmotion() throws {
        let heard = ClipEmotionListener.classify(
            ClipEmotionListener.mix([try tone(from: 0, seconds: 3)], from: 0, to: 3)
        )
        #expect(heard.laughter < 0.6)
        #expect(heard.shouting < 0.7)
    }
}
