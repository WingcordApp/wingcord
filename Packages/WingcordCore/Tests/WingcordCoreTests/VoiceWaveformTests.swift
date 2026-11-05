import CoreGraphics
import Foundation
import Testing
@testable import WingcordCore

@Suite("Voice waveforms")
struct VoiceWaveformTests {

    // MARK: Sampling

    @Test func aLevelMapsAsDiscordsDoes() {
        #expect(VoiceWaveform.sample(level: 0) == 0)
        #expect(VoiceWaveform.sample(level: 1) == 255)
        // −20 dB is 80% of the way up a scale from −100 to 0.
        #expect(VoiceWaveform.sample(level: 0.1) == 204)
        // −40 dB, 60%.
        #expect(VoiceWaveform.sample(level: 0.01) == 153)
        // Louder than full scale can't happen, and doesn't crash if it does.
        #expect(VoiceWaveform.sample(level: 3) == 255)
    }

    // MARK: Downsampling, Discord's `934581`

    @Test func nothingToDoLeavesItAlone() {
        #expect(VoiceWaveform.downsample([1, 2, 3], to: 3) == [1, 2, 3])
        #expect(VoiceWaveform.downsample([1, 2], to: 5) == [1, 2])
    }

    @Test func itAveragesRoundedBuckets() {
        // 5 into 2: width 2.5, so the first bucket ends at round(2.5) = 3 and the
        // second at round(5) = 5.
        #expect(VoiceWaveform.downsample([1, 2, 3, 4, 5], to: 2) == [2, 4.5])
        #expect(VoiceWaveform.downsample([10, 20, 30, 40], to: 2) == [15, 35])
    }

    @Test func aLongRecordingStillComesToExactly256() {
        let values = (0..<60_000).map { Double($0 % 256) }
        #expect(VoiceWaveform.downsample(values, to: 256).count == 256)
        let barely = (0..<257).map(Double.init)
        #expect(VoiceWaveform.downsample(barely, to: 256).count == 256)
    }

    // MARK: On the wire

    @Test func itEncodesAtMost256Bytes() throws {
        let long = [UInt8](repeating: 200, count: 10_000)
        let encoded = VoiceWaveform.encode(long)
        let data = try #require(Data(base64Encoded: encoded))
        #expect(data.count == 256)
        #expect(data.allSatisfy { $0 == 200 })
    }

    @Test func aShortOneGoesAsItIs() throws {
        let encoded = VoiceWaveform.encode([0, 128, 255])
        #expect(try #require(Data(base64Encoded: encoded)) == Data([0, 128, 255]))
    }

    @Test func nothingEncodesToNothing() {
        #expect(VoiceWaveform.encode([]) == "")
    }

    @Test func itRoundTrips() {
        let decoded = VoiceWaveform.decode(VoiceWaveform.encode([0, 255]))
        #expect(decoded == [0, 1])
    }

    @Test func aWaveformThatIsNotBase64DrawsFlatAndDoesNotFail() {
        #expect(VoiceWaveform.decode("not base64!") == [])
        #expect(VoiceWaveform.decode(nil) == [])
    }

    // MARK: Bars

    @Test func barsAreAsTallAsDiscordsBars() {
        #expect(VoiceWaveform.barHeight(0) == 2)
        #expect(VoiceWaveform.barHeight(1) == 24)
        #expect(VoiceWaveform.barHeight(0.5) == 13)
        #expect(VoiceWaveform.barHeight(3) == 24)
    }

    @Test func aWidthHoldsWholeBars() {
        #expect(VoiceWaveform.barCount(forWidth: 2) == 1)
        #expect(VoiceWaveform.barCount(forWidth: 8) == 2)
        #expect(VoiceWaveform.barCount(forWidth: 7.9) == 1)
        #expect(VoiceWaveform.barCount(forWidth: 0) == 0)
    }

    @Test func aMessageIsAsWideAsItIsLong() {
        // 40 at half a second, snapped: 6·floor(44/6) − 4 = 38.
        #expect(VoiceWaveform.width(forDuration: 0.1) == 38)
        #expect(VoiceWaveform.width(forDuration: 0.5) == 38)
        // 294 from 45 seconds on, snapped: 6·floor(298/6) − 4 = 290.
        #expect(VoiceWaveform.width(forDuration: 45) == 290)
        #expect(VoiceWaveform.width(forDuration: 1_199) == 290)
        // Between, it grows, and always lands on a whole number of bars.
        var last: CGFloat = 0
        for seconds in stride(from: 0.5, through: 45, by: 0.5) {
            let width = VoiceWaveform.width(forDuration: seconds)
            #expect(width >= last)
            #expect((width + 4).truncatingRemainder(dividingBy: 6) == 0)
            last = width
        }
    }

    @Test func tooManySamplesAreAveragedToTheBars() {
        #expect(VoiceWaveform.bars([0, 1, 0, 1], count: 2) == [0.5, 0.5])
    }

    @Test func tooFewAreSpreadAcrossThem() {
        #expect(VoiceWaveform.bars([0, 1], count: 3) == [0, 0.5, 1])
    }

    @Test func oneSampleFillsThemAndNoneLeavesThemFlat() {
        #expect(VoiceWaveform.bars([0.25], count: 3) == [0.25, 0.25, 0.25])
        #expect(VoiceWaveform.bars([], count: 2) == [0, 0])
        #expect(VoiceWaveform.bars([1, 2], count: 0) == [])
    }

    // MARK: Time

    @Test func theTimeRoundsUpAsDiscordsDoes() {
        #expect(VoiceWaveform.timeLabel(0) == "0:00")
        #expect(VoiceWaveform.timeLabel(0.2) == "0:01")
        #expect(VoiceWaveform.timeLabel(12) == "0:12")
        #expect(VoiceWaveform.timeLabel(59.5) == "1:00")
        #expect(VoiceWaveform.timeLabel(1_199.5) == "20:00")
    }
}

@Suite("Voice waveform drawing")
struct VoiceWaveformDrawingTests {

    /// A sentence's bars as measured: almost all of it high and close together, with
    /// a few pauses. The drawing has to pull these apart.
    @Test func speechStopsLookingFlat() {
        let speech: [Float] = [0.79, 0.55, 0.51, 0.82, 0.68, 0.36, 0.83, 0.76, 0.72, 0.82, 0.84, 0.77, 0.82, 0.34, 0.86]
        let drawn = VoiceWaveform.displayed(speech)
        let spreadBefore = speech.max()! - speech.min()!
        let spreadAfter = drawn.max()! - drawn.min()!
        #expect(spreadAfter > spreadBefore * 1.5)
        #expect(drawn.allSatisfy { (0...1).contains($0) })
        // The order of things stays: a pause is still the lowest.
        #expect(drawn[5] < drawn[0])
    }

    /// Measured: a real microphone with nobody talking, at −49 dB, with noise from about
    /// −55 to −42. It must look like the nothing it is, not like a voice.
    @Test func aQuietRoomDoesNotLookLikeSomebodyTalking() {
        let room: [Float] = (0..<40).map { 0.45 + 0.13 * Float($0 % 7) / 6 }
        let drawn = VoiceWaveform.displayed(room)
        #expect(drawn.max()! < 0.35)
    }

    @Test func aNoteAtOneLevelStaysFlat() {
        let hum = [Float](repeating: 0.8, count: 40)
        #expect(VoiceWaveform.displayed(hum) == hum)
    }

    @Test func silenceStaysSilent() {
        let silence = [Float](repeating: 0, count: 40)
        #expect(VoiceWaveform.displayed(silence) == silence)
    }

    @Test func oneValueIsLeftAlone() {
        #expect(VoiceWaveform.displayed([0.5]) == [0.5])
        #expect(VoiceWaveform.displayed([]) == [])
    }

    @Test func theLiveScaleIsOneSpeechFills() {
        #expect(VoiceWaveform.liveValue(level: 0) == 0)
        // A quiet room.
        #expect(VoiceWaveform.liveValue(level: 0.001) < 0.2)
        // Ordinary speech, around −25 dB.
        let speech = VoiceWaveform.liveValue(level: 0.056)
        #expect(speech > 0.5 && speech < 0.85)
        #expect(VoiceWaveform.liveValue(level: 1) == 1)
    }
}
