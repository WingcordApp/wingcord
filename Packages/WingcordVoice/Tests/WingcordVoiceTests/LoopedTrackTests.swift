import AVFoundation
import Foundation
import Testing
import WingcordCore
@testable import WingcordVoice

/// A stage's waiting music, read a frame at a time and looped.
@Suite("Looped track")
struct LoopedTrackTests {

    /// A 48 kHz stereo file of `frames` frames whose left channel counts up
    /// from 1 and whose right is its negative, so every sample says where in
    /// the file it came from.
    private static func file(frames: Int, sampleRate: Double = 48_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "looped-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<frames {
            channels[0][index] = Float(index + 1) / 4096
            channels[1][index] = -Float(index + 1) / 4096
        }
        try file.write(from: buffer)
        return url
    }

    /// The frame `read()` prepared, added to silence.
    private static func frame(_ track: LoopedTrack) -> [Float] {
        var mix = [Float](repeating: 0, count: OpusFormat.interleavedCount)
        track.add(into: &mix)
        return mix
    }

    @Test("It plays only once told to, at its gain")
    func playsAtItsGain() throws {
        let track = try #require(LoopedTrack(url: try Self.file(frames: 2_000), gain: 0.25))
        #expect(!track.read())
        track.setPlayback(.playing)
        #expect(track.read())
        let mix = Self.frame(track)
        #expect(mix[0] == 0.25 * 1 / 4096)
        #expect(mix[1] == -0.25 * 1 / 4096)
    }

    /// 1,500 frames: the second 20 ms frame takes the last 540 and wraps to
    /// the top for the other 420.
    @Test("It wraps to the top without a gap")
    func wraps() throws {
        let track = try #require(LoopedTrack(url: try Self.file(frames: 1_500), gain: 1))
        track.setPlayback(.playing)
        #expect(track.read())
        #expect(track.read())
        let mix = Self.frame(track)
        let left = stride(from: 0, to: mix.count, by: 2).map { Int((mix[$0] * 4096).rounded()) }
        #expect(left[0] == 961)
        #expect(left[539] == 1_500)
        #expect(left[540] == 1)
        #expect(left[959] == 420)
    }

    @Test("Paused keeps its place; stopped starts again from the top")
    func pauseAndStop() throws {
        let track = try #require(LoopedTrack(url: try Self.file(frames: 4_000), gain: 1))
        track.setPlayback(.playing)
        #expect(track.read())
        track.setPlayback(.paused)
        #expect(!track.read())
        track.setPlayback(.playing)
        #expect(track.read())
        #expect(Int((Self.frame(track)[0] * 4096).rounded()) == 961)
        track.setPlayback(.stopped)
        track.setPlayback(.playing)
        #expect(track.read())
        #expect(Int((Self.frame(track)[0] * 4096).rounded()) == 1)
    }

    /// The pump never resamples: a file at another rate is refused up front.
    @Test("A file that is not 48 kHz stereo is refused")
    func refusesOtherRates() throws {
        #expect(LoopedTrack(url: try Self.file(frames: 1_000, sampleRate: 32_000), gain: 1) == nil)
    }
}
