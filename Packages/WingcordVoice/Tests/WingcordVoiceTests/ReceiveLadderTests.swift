import CoreMedia
import Foundation
import Testing
@testable import WingcordVoice

/// What this end asks the server to send — Discord's desktop
/// `LocalMediaSinkWantsManager` with its ladder (module 4511), its offscreen
/// rule and its hidden-window rule (module 276208).
@Suite("Receive ladder and video pausing")
struct ReceiveLadderTests {

    @Test("The want falls with the number of pictures, as Discord's ladder")
    func ladder() {
        let table: [(Int, Int)] = [
            (0, 100), (1, 100), (2, 90), (3, 80), (4, 70), (5, 60), (6, 60), (7, 50), (9, 50),
            (10, 40), (11, 40), (12, 30), (16, 30), (17, 20), (25, 20), (40, 20),
        ]
        for (streams, want) in table {
            #expect(VideoLadder.maxSinkValue(streams: streams) == want, "\(streams) pictures")
        }
    }

    /// The first rung bigger than the picture as drawn.
    @Test("A drawn picture asks for the first rung bigger than itself")
    func drawn() {
        #expect(VideoLadder.maxSinkValue(streams: 1, drawnPixels: 800 * 450) == 90)
        #expect(VideoLadder.maxSinkValue(streams: 1, drawnPixels: 100 * 100) == 20)
        #expect(VideoLadder.maxSinkValue(streams: 1, drawnPixels: 4_000_000) == 100)
    }

    // MARK: In a call

    private let sealer = VoiceSealer(cipher: .aes256GCM, secretKey: [UInt8](repeating: 0x11, count: 32))

    /// A receiver with `users` bound to video SSRCs `user × 10`.
    private func receiver(_ users: [UInt64]) -> InboundStreams {
        let inbound = InboundStreams()
        inbound.setSealer(sealer)
        for user in users { inbound.bindVideo(ssrc: UInt32(user * 10), to: user) }
        return inbound
    }

    /// One sealed H.264 packet on the user's SSRC: their picture has arrived.
    private func arrive(_ user: UInt64, at inbound: InboundStreams) throws {
        var writer = RTPWriter(ssrc: UInt32(user * 10), payloadType: RTP.PayloadType.h264)
        let header = writer.next(advancingClockBy: 3_000, marker: true)
        let payload: [UInt8] = [0x65, 0x88, 0x84, 0x00]
        let packet = try [UInt8](payload.withUnsafeBytes { try sealer.seal(payload: $0, header: header) })
        inbound.accept(packet, arrival: 0)
    }

    private func drawn(_ user: UInt64, at inbound: InboundStreams) {
        inbound.setVideoSink({ _ in }, for: user)
    }

    @Test("Three pictures ask for 80, the spotlight for 100, and a disabled one for nothing")
    func callWants() {
        let inbound = receiver([1, 2, 3])
        #expect(inbound.sinkWants() == MediaSinkWants(any: 80))
        inbound.setFocusedVideoUser(2)
        #expect(inbound.sinkWants() == MediaSinkWants(any: 80, bySSRC: [20: 100]))
        inbound.setVideoDisabled(true, for: 3)
        #expect(inbound.sinkWants() == MediaSinkWants(any: 90, bySSRC: [20: 100, 30: 0]))
    }

    /// A one-to-one call asks for each picture as big as its tile draws it;
    /// a stage never does.
    @Test("One other person, and the picture is sized to its tile")
    func oneToOne() {
        let inbound = receiver([1])
        inbound.setDrawnPixels(800 * 450, for: 1)
        #expect(inbound.sinkWants(isOneToOne: true) == MediaSinkWants(any: 100, bySSRC: [10: 90]))
        #expect(inbound.sinkWants(isOneToOne: false) == MediaSinkWants(any: 100))
        inbound.setIsStage(true)
        #expect(inbound.sinkWants(isOneToOne: true) == MediaSinkWants(any: 100))
    }

    @Test("A picture no tile has drawn for thirty seconds is paused, and drawn again comes back")
    func offscreen() throws {
        let inbound = receiver([1])
        try arrive(1, at: inbound)
        drawn(1, at: inbound)
        inbound.setVideoSink(nil, for: 1)
        let start = ContinuousClock.now
        #expect(inbound.sinkWants(now: start) == MediaSinkWants(any: 100))
        #expect(inbound.sinkWants(now: start + .seconds(29)) == MediaSinkWants(any: 100))
        #expect(inbound.sinkWants(now: start + .seconds(31)) == MediaSinkWants(any: 100, bySSRC: [10: 0]))
        drawn(1, at: inbound)
        #expect(inbound.sinkWants(now: start + .seconds(32)) == MediaSinkWants(any: 100))
    }

    @Test("A stage keeps an offscreen picture two minutes")
    func stageOffscreen() throws {
        let inbound = receiver([1])
        inbound.setIsStage(true)
        try arrive(1, at: inbound)
        drawn(1, at: inbound)
        inbound.setVideoSink(nil, for: 1)
        let start = ContinuousClock.now
        _ = inbound.sinkWants(now: start)
        #expect(inbound.sinkWants(now: start + .seconds(31)) == MediaSinkWants(any: 100))
        #expect(inbound.sinkWants(now: start + .seconds(121)) == MediaSinkWants(any: 100, bySSRC: [10: 0]))
    }

    /// Discord's `addLru`: past three offscreen, the one offscreen longest goes
    /// at once — the first of equals.
    @Test("At most three offscreen pictures are kept")
    func keepsThree() throws {
        let users: [UInt64] = [1, 2, 3, 4, 5]
        let inbound = receiver(users)
        for user in users { try arrive(user, at: inbound) }
        drawn(1, at: inbound)
        inbound.setVideoSink(nil, for: 1)
        let wants = inbound.sinkWants(now: .now)
        #expect(wants.bySSRC[10] == 0)
        #expect(wants.bySSRC[20] == 0)
        #expect(wants.bySSRC[30] == nil && wants.bySSRC[40] == nil && wants.bySSRC[50] == nil)
    }

    /// A tile here attaches once a picture has arrived, so a picture paused
    /// before then would never be drawn or asked for again.
    @Test("A picture that has not arrived is never paused")
    func notArrivedIsKept() throws {
        let inbound = receiver([1, 2])
        try arrive(1, at: inbound)
        drawn(1, at: inbound)
        let start = ContinuousClock.now
        _ = inbound.sinkWants(now: start)
        #expect(inbound.sinkWants(now: start + .seconds(60)).bySSRC[20] == nil)
    }

    @Test("Hidden windows ask for no picture at all, and showing them asks again")
    func hiddenWindows() {
        let inbound = receiver([1, 2])
        inbound.setIncomingVideoEnabled(false)
        #expect(inbound.sinkWants() == MediaSinkWants(any: 90, bySSRC: [10: 0, 20: 0]))
        inbound.setIncomingVideoEnabled(true)
        #expect(inbound.sinkWants() == MediaSinkWants(any: 90))
    }
}
