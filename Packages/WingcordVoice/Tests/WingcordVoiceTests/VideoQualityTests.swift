import Foundation
import Testing
@testable import WingcordVoice

// MARK: - Discord's ladder and quality, held to its own numbers
//
// Every expected value below was computed by running Discord's own module 4511
// and 466376 code over the same inputs (the bundle in
// `docs/research/2026-10-05/discord-bundle/`), not derived from this port — a
// port checked against itself agrees with any mistake it made.

@Suite("Video quality")
struct VideoQualityTests {

    @Test("The ladder is Discord's, rung for rung")
    func ladder() {
        let rungs = VideoLadder.rungs.map { [$0.want, $0.width, $0.height, $0.mutedFramerate] }
        #expect(rungs == [
            [20, 256, 144, 12],
            [30, 320, 180, 20],
            [40, 384, 216, 20],
            [50, 416, 234, 20],
            [60, 512, 288, 20],
            [70, 640, 360, 20],
            [80, 672, 378, 20],
            [90, 896, 504, 20],
            [100, 1_280, 720, 20],
        ])
        #expect(VideoLadder.rungs.allSatisfy { $0.framerate == 30 })
        #expect(VideoLadder.rung(for: 75).want == 70, "the highest rung at or under the want")
        #expect(VideoLadder.rung(for: 0).want == 20, "and the lowest under every rung")
    }

    /// **Zero is never the answer for a stream at quality 100.** Measured on a
    /// call as `{"any":0,"95747":100}`, which asks for 95747 in full.
    @Test("A want is the named one, then any, then a hundred")
    func wants() {
        let measured = MediaSinkWants(any: 0, bySSRC: [95_747: 100])
        #expect(VideoQualityPolicy.want(for: 95_747, in: measured) == 100)
        #expect(VideoQualityPolicy.want(for: 1, in: MediaSinkWants(any: 60)) == 60)
        #expect(VideoQualityPolicy.want(for: 1, in: MediaSinkWants(any: 60, bySSRC: [1: 30])) == 30)
        #expect(VideoQualityPolicy.want(for: 1, in: MediaSinkWants(any: 0, bySSRC: [1: 0])) == 100)
        #expect(VideoQualityPolicy.want(for: 1, in: nil) == 100)
    }

    @Test("A camera's size, rate and band follow its want")
    func camera() {
        let full = VideoQualityPolicy.camera(want: 100, isMuted: false, isFull: false)
        #expect(full == VideoQuality(
            width: 1_280, height: 720, framerate: 30, bitrateMin: 150_000, bitrateMax: 2_500_000
        ))
        // 416×234 is 0.10563 of the budget: 2.5 Mbit/s × that.
        let half = VideoQualityPolicy.camera(want: 50, isMuted: false, isFull: false)
        #expect(half == VideoQuality(
            width: 416, height: 234, framerate: 30, bitrateMin: 150_000, bitrateMax: 264_062
        ))
        #expect(VideoQualityPolicy.camera(want: 50, isMuted: true, isFull: false).framerate == 20)
        #expect(VideoQualityPolicy.camera(want: 20, isMuted: true, isFull: false).framerate == 12)
        // The channel's "720p" fixes the size and keeps the want's band.
        let fixed = VideoQualityPolicy.camera(want: 50, isMuted: false, isFull: true)
        #expect((fixed.width, fixed.height) == (1_280, 720))
        #expect(fixed.bitrateMax == half.bitrateMax)
    }

    @Test("A share's band follows its viewers, never below what its pixels need")
    func share() {
        let box = VideoQuality(
            width: 1_280, height: 720, framerate: 30, bitrateMin: 500_000, bitrateMax: 3_500_000
        )
        #expect(VideoQualityPolicy.share(maximum: box, viewerPixels: 0) == box)
        #expect(VideoQualityPolicy.share(maximum: box, viewerPixels: 2_000_000) == box)
        // Viewers drawing it at a quarter of its pixels: the band scales by a
        // quarter, but the ceiling stays at 0.02 × 921,600 × 30 = 552,960.
        let quarter = VideoQualityPolicy.share(maximum: box, viewerPixels: 230_400)
        #expect(quarter.bitrateMin == 150_000, "125,000 scaled, lifted to the floor")
        #expect(quarter.bitrateMax == 875_000)
        let tiny = VideoQualityPolicy.share(maximum: box, viewerPixels: 9_216)
        #expect(tiny.bitrateMax == 552_960)
        #expect((tiny.width, tiny.height, tiny.framerate) == (1_280, 720, 30), "the picture keeps its size")
    }

    /// Discord's `setDesktopEncodingOptions`: 9 Mbit/s for anything taller
    /// than 720, faster than 30, or Source; 3.5 Mbit/s for the rest. Source is
    /// a 2160-line box here, so it lands on the high side by its box.
    @Test("A share's ceiling is Discord's for its resolution and frame rate")
    func shareBand() {
        #expect(VideoQualityPolicy.shareBand(boxHeight: 720, framerate: 30) == (500_000, 3_500_000))
        #expect(VideoQualityPolicy.shareBand(boxHeight: 480, framerate: 15) == (500_000, 3_500_000))
        #expect(VideoQualityPolicy.shareBand(boxHeight: 720, framerate: 60) == (500_000, 9_000_000))
        #expect(VideoQualityPolicy.shareBand(boxHeight: 480, framerate: 60) == (500_000, 9_000_000))
        #expect(VideoQualityPolicy.shareBand(boxHeight: 1_080, framerate: 15) == (500_000, 9_000_000))
        #expect(VideoQualityPolicy.shareBand(boxHeight: 2_160, framerate: 15) == (500_000, 9_000_000))
    }

    @Test("Opcode 15 reads in both shapes the server was measured sending")
    func sinkWants() throws {
        let call = try JSONDecoder().decode(
            MediaSinkWants.self, from: Data(#"{"any":0,"95747":100}"#.utf8)
        )
        #expect(call == MediaSinkWants(any: 0, bySSRC: [95_747: 100]))
        let share = try JSONDecoder().decode(
            MediaSinkWants.self,
            from: Data(#"{"pixelCounts":{"91568":921600.0},"any":100,"later":"x"}"#.utf8)
        )
        #expect(share == MediaSinkWants(any: 100, pixelCounts: [91_568: 921_600]))
        #expect(share.description == "any=100 px91568=921600")
    }

    @Test("Fifteen quiet seconds slow the camera, and speech or unmuting restores it")
    func framerateReducer() {
        let start = ContinuousClock.now
        var reducer = FramerateReducer(now: start)
        var changed = reducer.tick(at: start + .seconds(14))
        #expect(!changed)
        changed = reducer.tick(at: start + .seconds(15))
        #expect(changed, "silent from the start")
        #expect(reducer.isMuted)
        changed = reducer.speaking(true, at: start + .seconds(16))
        #expect(changed)
        #expect(!reducer.isMuted)
        changed = reducer.speaking(false, at: start + .seconds(17))
        #expect(!changed, "the clock starts again")
        changed = reducer.tick(at: start + .seconds(31))
        #expect(!changed)
        changed = reducer.tick(at: start + .seconds(32))
        #expect(changed)
        changed = reducer.selfMuted(false)
        #expect(changed, "unmuting restores it at once")
        changed = reducer.tick(at: start + .seconds(60))
        #expect(!changed, "and starts no clock of its own")
        changed = reducer.selfMuted(true)
        #expect(changed, "muting slows it at once")
    }
}

// MARK: - The bitrate controller

@Suite("Bitrate controller")
struct BitrateControllerTests {

    private let camera = VideoQualityPolicy.camera(want: 100, isMuted: false, isFull: false)

    @Test("It starts at the top of the band and comes down on loss")
    func lossBacksOff() {
        var controller = BitrateController(quality: camera)
        #expect(controller.bitrate == 2_500_000)
        // 20 % lost: down by half of it, to 90 %.
        var told = controller.update(fractionLost: 51, estimate: nil, interval: .milliseconds(500))
        #expect(told == 2_250_976)
        // Between two and ten per cent it holds.
        told = controller.update(fractionLost: 13, estimate: nil, interval: .seconds(1))
        #expect(told == nil)
        #expect(controller.bitrate == 2_250_976)
        // Below two it climbs, eight per cent a second.
        told = controller.update(fractionLost: 0, estimate: nil, interval: .seconds(1))
        #expect(told == 2_431_054)
    }

    @Test("A window with no report holds, and the receiver's estimate is a ceiling")
    func silenceAndEstimate() {
        var controller = BitrateController(quality: camera)
        var told = controller.update(fractionLost: nil, estimate: nil, interval: .seconds(1))
        #expect(told == nil)
        told = controller.update(fractionLost: 0, estimate: 1_000_000, interval: .seconds(1))
        #expect(told == 1_000_000)
    }

    /// **The path is remembered across a narrower band.** A want that drops
    /// to a lower rung and comes back must not leave the camera climbing back
    /// at eight per cent a second over a path it had already measured.
    @Test("A band that narrows and widens again finds the path where it was")
    func bandDoesNotForgetThePath() {
        var controller = BitrateController(quality: camera)
        let low = VideoQualityPolicy.camera(want: 50, isMuted: false, isFull: false)
        var told = controller.update(quality: low)
        #expect(told == 264_062)
        told = controller.update(quality: camera)
        #expect(told == 2_500_000)
    }
}

// MARK: - One sender's video, back in order

@Suite("Video reorder buffer")
struct VideoReorderBufferTests {

    private func packet(_ sequence: UInt16, marker: Bool = false, payload: [UInt8] = [1]) -> VideoReorderBuffer.Packet {
        .init(payload: payload, sequence: sequence, marker: marker, timestamp: 9_000)
    }

    private func sequences(_ deliveries: [VideoReorderBuffer.Delivery]) -> [UInt16] {
        deliveries.map(\.packet.sequence)
    }

    @Test("Packets in order go straight through")
    func inOrder() {
        var buffer = VideoReorderBuffer()
        let first = buffer.insert(packet(10), at: 0)
        let second = buffer.insert(packet(11), at: 0.01)
        let asks = buffer.asks(at: 0.01)
        #expect(sequences(first) == [10])
        #expect(sequences(second) == [11])
        #expect(asks.isEmpty)
    }

    @Test("A hole holds what follows it, is asked for, and fills from a retransmission")
    func holeFills() {
        var buffer = VideoReorderBuffer()
        _ = buffer.insert(packet(10), at: 0)
        let behindHole = buffer.insert(packet(12), at: 0.01)
        let further = buffer.insert(packet(13), at: 0.02)
        #expect(behindHole.isEmpty, "12 waits for 11")
        #expect(further.isEmpty)
        let firstAsk = buffer.asks(at: 0.02)
        let tooSoon = buffer.asks(at: 0.03)
        let again = buffer.asks(at: 0.08)
        #expect(firstAsk == [11])
        #expect(tooSoon.isEmpty, "not asked again inside the interval")
        #expect(again == [11], "and asked again after it")

        let filled = buffer.insert(packet(11), at: 0.09)
        let afterwards = buffer.asks(at: 0.5)
        let isContiguous = filled.allSatisfy(\.isContiguous)
        #expect(sequences(filled) == [11, 12, 13])
        #expect(isContiguous)
        #expect(afterwards.isEmpty)
    }

    @Test("A hole is given up after its patience, and what follows it is marked")
    func holeGivenUp() {
        var buffer = VideoReorderBuffer()
        _ = buffer.insert(packet(10), at: 0)
        _ = buffer.insert(packet(12), at: 0.01)
        let patient = buffer.insert(packet(13), at: 0.15)
        let released = buffer.insert(packet(14), at: 0.22)
        let late = buffer.insert(packet(11), at: 0.3)
        #expect(patient.isEmpty, "still patient")
        #expect(sequences(released) == [12, 13, 14])
        #expect(released.map(\.isContiguous) == [false, true, true])
        #expect(late.isEmpty, "too late, and dropped")
    }

    @Test("A hole is asked about three times and no more")
    func boundedAsks() {
        var buffer = VideoReorderBuffer()
        _ = buffer.insert(packet(10), at: 0)
        _ = buffer.insert(packet(12), at: 0)
        let asks = [0.0, 0.05, 0.10, 0.15].map { buffer.asks(at: $0) }
        #expect(asks == [[11], [11], [11], []])
    }

    @Test("Sequence numbers wrap")
    func wraps() {
        var buffer = VideoReorderBuffer()
        _ = buffer.insert(packet(65_534), at: 0)
        let held = buffer.insert(packet(0), at: 0)
        let asks = buffer.asks(at: 0)
        let filled = buffer.insert(packet(65_535), at: 0.01)
        #expect(held.isEmpty)
        #expect(asks == [65_535])
        #expect(sequences(filled) == [65_535, 0])
    }

    /// **A packet with nothing in it still has a place.** An SFU's padding
    /// probe trims to nothing and consumes a sequence number; skipping it is a
    /// hole that never fills.
    @Test("An empty packet keeps the stream contiguous")
    func padding() {
        var buffer = VideoReorderBuffer()
        _ = buffer.insert(packet(10), at: 0)
        let probe = buffer.insert(packet(11, payload: []), at: 0.01)
        let next = buffer.insert(packet(12), at: 0.02)
        let isContiguous = next.allSatisfy(\.isContiguous)
        #expect(sequences(probe) == [11])
        #expect(isContiguous)
    }

    @Test("A sender that starts again far away is followed, not waited for")
    func restart() {
        var buffer = VideoReorderBuffer()
        _ = buffer.insert(packet(10), at: 0)
        let jumped = buffer.insert(packet(30_000), at: 0.01)
        let next = buffer.insert(packet(30_001), at: 0.02)
        #expect(sequences(jumped) == [30_000])
        #expect(jumped.first?.isContiguous == false)
        #expect(sequences(next) == [30_001])
    }
}

// MARK: - Discord's voice gate

@Suite("Transmit gate")
struct TransmitGateTests {

    private func admit(_ gate: inout TransmitGate, _ levels: [Float]) -> [Bool] {
        levels.map { gate.admit(level: $0, isMuted: false).send }
    }

    /// Discord's `vadTrailing`: half a second — twenty-five frames — after the
    /// last one over the line.
    @Test("A manual line opens at once and stays open twenty-five frames")
    func trailing() {
        var gate = TransmitGate()
        gate.mode = .voiceActivity(.init(isAutomatic: false, threshold: -40))
        let opened = admit(&gate, [-50, -30])
        #expect(opened == [false, true])
        let held = admit(&gate, Array(repeating: -50, count: 26))
        #expect(held == Array(repeating: true, count: 25) + [false])
    }

    @Test("Muting shuts the gate whatever the level")
    func muting() {
        var gate = TransmitGate()
        gate.mode = .voiceActivity(.init(isAutomatic: false, threshold: -40))
        let decision = gate.admit(level: -10, isMuted: true)
        #expect(!decision.send)
        #expect(gate.threshold == -40)
    }

    /// The automatic line learns the room from what is not a voice, and opens
    /// eighteen decibels above it — speech does not teach it, so talking does
    /// not raise the line under the talker.
    @Test("The automatic line sits above the room and does not learn from speech")
    func automatic() throws {
        var gate = TransmitGate()
        gate.mode = .voiceActivity(.init(isAutomatic: true))
        _ = admit(&gate, Array(repeating: -70, count: 50))
        let quiet = try #require(gate.threshold)
        #expect(quiet < -50 && quiet >= -70, "a quiet room puts the line low")
        let speech = admit(&gate, Array(repeating: -25, count: 100))
        #expect(speech.allSatisfy { $0 }, "a voice well over it opens and keeps it open")
        #expect(try #require(gate.threshold) == quiet, "and speaking does not move it")
    }

    /// Discord's Push to Talk (Priority) opens the microphone in either mode
    /// — and muting still wins.
    @Test("The priority key opens the gate in either mode, and muting still shuts it")
    func priority() {
        var gate = TransmitGate()
        gate.mode = .voiceActivity(.init(isAutomatic: false, threshold: -40))
        gate.isPriorityHeld = true
        #expect(gate.admit(level: -80, isMuted: false).send)
        gate.mode = .pushToTalk
        #expect(gate.admit(level: -80, isMuted: false).send, "with push to talk not held")
        #expect(!gate.admit(level: -10, isMuted: true).send)
        gate.isPriorityHeld = false
        #expect(!gate.admit(level: -10, isMuted: false).send)
    }

    @Test("A level is measured on Discord's dBFS scale")
    func decibels() {
        #expect(TransmitGate.decibels(1) == 0)
        #expect(abs(TransmitGate.decibels(0.03) - -30.46) < 0.01)
        #expect(TransmitGate.decibels(0) == -100)
    }
}

// MARK: - A watched stream's sound

@Suite("Stream attenuation")
struct StreamAttenuationTests {

    private static let source = StreamAudio(inbound: InboundStreams())

    @Test("Nothing to mix without a stream")
    func noSource() {
        var mix = StreamMix()
        let step = mix.step(isSpeech: true)
        #expect(step == nil)
    }

    /// Discord's strength is how far the stream drops: at 50, to half. It
    /// gets there within a few frames of somebody speaking and comes back
    /// slowly, so a stream does not pump between words.
    @Test("Speech lowers the stream fast, by the strength, and silence restores it slowly")
    func ducking() throws {
        var mix = StreamMix(source: Self.source, attenuation: 0.5)
        var ends: [Float] = []
        for _ in 0..<6 {
            let step = mix.step(isSpeech: true)
            ends.append(try #require(step).2)
        }
        #expect(ends.first! < 1)
        #expect(abs(ends.last! - 0.5) < 0.01, "at the strength within six frames")

        let quiet = mix.step(isSpeech: false)
        let first = try #require(quiet)
        #expect(abs(first.1 - ends.last!) < 0.000_1, "each frame starts where the last ended")
        var restored = first.2
        var frames = 1
        while restored < 0.99 {
            let step = mix.step(isSpeech: false)
            restored = try #require(step).2
            frames += 1
        }
        #expect(frames > 20, "more slowly than it fell")
    }

    @Test("Off means no attenuation, and the stream's own volume scales the ramp")
    func offAndVolume() throws {
        var mix = StreamMix(source: Self.source, volume: 1.5, attenuation: nil)
        let stepped = mix.step(isSpeech: true)
        let step = try #require(stepped)
        #expect(step.1 == 1.5 && step.2 == 1.5)
    }
}

// MARK: - What this end does not want

@Suite("Media sink wants")
struct MediaSinkWantsTests {

    /// Discord's desktop shape: `any`, and each named SSRC as a string key.
    @Test("Opcode 15 is written as Discord's desktop writes it")
    func encoding() throws {
        let wants = MediaSinkWants(any: 100, bySSRC: [200: 0])
        let json = try #require(String(data: JSONEncoder().encode(wants), encoding: .utf8))
        #expect(json.contains(#""any":100"#))
        #expect(json.contains(#""200":0"#))
        #expect(try JSONDecoder().decode(MediaSinkWants.self, from: Data(json.utf8)) == wants)
    }

    /// A video turned off and a person muted are each a zero for their SSRC,
    /// and everything else is asked for in full.
    @Test("A disabled video and a muted person are unwanted, and only until turned back on")
    func unwanted() {
        let inbound = InboundStreams()
        inbound.bind(ssrc: 100, to: 1)
        inbound.bindVideo(ssrc: 200, to: 2)
        #expect(inbound.sinkWants() == MediaSinkWants(any: 100))

        inbound.setLocallyMuted(true, for: 1)
        inbound.setVideoDisabled(true, for: 2)
        #expect(inbound.sinkWants() == MediaSinkWants(any: 100, bySSRC: [100: 0, 200: 0]))

        inbound.setLocallyMuted(false, for: 1)
        inbound.setVideoDisabled(false, for: 2)
        #expect(inbound.sinkWants() == MediaSinkWants(any: 100))
    }
}

// MARK: - Priority, in the mix

@Suite("Priority speaker")
struct PrioritySpeakerTests {

    private static let sealer = VoiceSealer(
        cipher: .aes256GCM, secretKey: [UInt8](repeating: 0x55, count: 32)
    )

    /// Ten packets of one person's tone, arrived together.
    private func feed(_ inbound: InboundStreams, ssrc: UInt32) throws {
        let encoder = try OpusEncoder(bitrate: 64_000)
        var packet = [UInt8](repeating: 0, count: OpusFormat.maximumPacketBytes)
        let tone = (0..<Int(OpusFormat.frameSize)).map {
            Int16(sin(2 * .pi * 440 * Double($0) / 48_000) * 12_000)
        }
        for index in 0..<10 {
            let length = try tone.withUnsafeBufferPointer {
                try encoder.encode($0.baseAddress!, into: &packet)
            }
            let header = RTPWriter.header(
                ssrc: ssrc, payloadType: RTP.PayloadType.opus, sequence: UInt16(index),
                timestamp: UInt32(index) * 960, marker: index == 0, extensions: []
            )
            let sealed = try Array(packet.prefix(length)).withUnsafeBytes {
                try Self.sealer.seal(payload: $0, header: header)
            }
            inbound.accept([UInt8](sealed), arrival: 0)
        }
    }

    /// The energy of five mixed frames.
    private func energy(_ inbound: InboundStreams) -> Float {
        (0..<5).reduce(0) { total, frame in
            let mixed = inbound.mixNextFrame(at: 1 + Double(frame) * 0.02)
            return total + mixed.samples.reduce(0) { $0 + $1 * $1 }
        }
    }

    private func listener(_ priority: Set<UInt64>) throws -> InboundStreams {
        let inbound = InboundStreams()
        inbound.setSealer(Self.sealer)
        inbound.bind(ssrc: 10, to: 1)
        inbound.setPrioritySpeakers(priority)
        try feed(inbound, ssrc: 10)
        return inbound
    }

    /// Discord's `prioritySpeakerDucking`: everybody else at a tenth while a
    /// priority speaker talks — a hundredth of the energy — and the priority
    /// speaker untouched.
    @Test("Everybody else plays at a tenth while a priority speaker talks")
    func ducking() throws {
        let plain = energy(try listener([]))
        let ducked = energy(try listener([2]))
        let speaking = energy(try listener([1]))
        #expect(plain > 0)
        #expect(abs(ducked / plain - 0.01) < 0.001)
        #expect(abs(speaking / plain - 1) < 0.001)
    }
}
