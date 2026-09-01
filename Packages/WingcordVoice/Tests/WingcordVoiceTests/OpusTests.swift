import Foundation
import Testing
@testable import WingcordVoice

@Suite("Opus")
struct OpusTests {

    private func tone(frequency: Double, frames: Int) -> [Int16] {
        var samples = [Int16](repeating: 0, count: frames * Int(OpusFormat.channels))
        for frame in 0..<frames {
            let value = sin(2 * .pi * frequency * Double(frame) / 48_000) * 12_000
            samples[frame * 2] = Int16(value)
            samples[frame * 2 + 1] = Int16(value)
        }
        return samples
    }

    @Test func aFrameEncodesAndDecodes() throws {
        let encoder = try OpusEncoder(bitrate: 64_000)
        let decoder = try OpusDecoder()
        var packet = [UInt8](repeating: 0, count: OpusFormat.maximumPacketBytes)
        var pcm = [Int16](repeating: 0, count: OpusFormat.interleavedCount)

        let input = tone(frequency: 440, frames: Int(OpusFormat.frameSize))
        let length = try input.withUnsafeBufferPointer {
            try encoder.encode($0.baseAddress!, into: &packet)
        }
        #expect(length > 0)
        #expect(length <= OpusFormat.maximumPacketBytes)

        let decoded = try decoder.decode(Array(packet.prefix(length)), into: &pcm)
        #expect(decoded == Int(OpusFormat.frameSize))
    }

    /// The concealer. A decoder handed nothing must still produce a frame —
    /// that is what turns a lost packet into a smoothed one rather than a gap.
    @Test func aMissingPacketIsConcealed() throws {
        let encoder = try OpusEncoder(bitrate: 64_000)
        let decoder = try OpusDecoder()
        var packet = [UInt8](repeating: 0, count: OpusFormat.maximumPacketBytes)
        var pcm = [Int16](repeating: 0, count: OpusFormat.interleavedCount)

        let input = tone(frequency: 300, frames: Int(OpusFormat.frameSize))
        for _ in 0..<5 {
            let length = try input.withUnsafeBufferPointer {
                try encoder.encode($0.baseAddress!, into: &packet)
            }
            _ = try decoder.decode(Array(packet.prefix(length)), into: &pcm)
        }
        let concealed = try decoder.decode(nil, into: &pcm)
        #expect(concealed == Int(OpusFormat.frameSize))
        // The concealer extrapolates: it does not hand back silence.
        #expect(pcm.contains { $0 != 0 })
    }

    @Test func theExpectedLossFeedbackIsClamped() throws {
        let encoder = try OpusEncoder(bitrate: 64_000)
        // Nothing to assert beyond "it does not trap": the clamp exists so a
        // reported 100% does not make Opus spend the whole bitrate on
        // redundancy and collapse the primary signal.
        encoder.updateExpectedLoss(percent: 100)
        encoder.updateExpectedLoss(percent: -5)
        encoder.setBitrate(96_000)
    }
}
