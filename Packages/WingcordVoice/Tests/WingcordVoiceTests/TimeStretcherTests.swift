import Foundation
import Testing
@testable import WingcordVoice

/// The time stretcher changes a voiced frame's length by exactly one pitch
/// period and leaves everything else alone.
struct TimeStretcherTests {
    /// A 200 Hz tone (a 240-sample period at 48 kHz), stereo, one frame long.
    private func tone(frequency: Double = 200, amplitude: Float = 0.3, length: Int = 960) -> [Float] {
        var frame: [Float] = []
        for index in 0..<length {
            let value = amplitude * Float(sin(2 * .pi * frequency * Double(index) / 48_000))
            frame.append(value)
            frame.append(value)
        }
        return frame
    }

    @Test func findsTheVoicePeriod() throws {
        let mono = TimeStretcher.mixdown(tone(), channels: 2, length: 960)
        let found = try #require(TimeStretcher.pitchPeriod(mono))
        // 240 or a multiple of it: any whole number of periods splices cleanly.
        #expect(found.period % 240 == 0 || abs(found.period - 240) <= 1)
        #expect(found.correlation > 0.95)
    }

    @Test func accelerateDropsOnePeriod() {
        let frame = tone()
        let out = TimeStretcher.stretch(frame, channels: 2, action: .accelerate)
        #expect(out.count < frame.count)
        #expect((frame.count - out.count) % 2 == 0)
        #expect((frame.count - out.count) / 2 >= TimeStretcher.shortestPeriod)
    }

    @Test func expandAddsOnePeriod() {
        let frame = tone()
        let out = TimeStretcher.stretch(frame, channels: 2, action: .expand)
        #expect(out.count > frame.count)
        #expect((out.count - frame.count) / 2 <= TimeStretcher.longestPeriod)
    }

    @Test func splicesWithoutAJump() {
        // The largest step between neighbouring samples stays a tone's own.
        let frame = tone()
        let ownStep = zip(frame, frame.dropFirst(2)).map { abs($0 - $1) }.max() ?? 0
        for action in [TimeStretcher.Action.accelerate, .expand] {
            let out = TimeStretcher.stretch(frame, channels: 2, action: action)
            let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
            let step = zip(left, left.dropFirst()).map { abs($0 - $1) }.max() ?? 0
            #expect(step <= ownStep * 1.5 + 0.001)
        }
    }

    @Test func leavesNoiseAlone() {
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<1920).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
        #expect(TimeStretcher.stretch(noise, channels: 2, action: .accelerate).count == noise.count)
    }

    @Test func noneIsTheSameFrame() {
        let frame = tone()
        #expect(TimeStretcher.stretch(frame, channels: 2, action: .none) == frame)
    }
}
