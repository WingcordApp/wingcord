import Foundation
import Testing
@testable import WingcordVoice

@Suite("Jitter buffer")
struct JitterBufferTests {

    private func fill(_ buffer: JitterBuffer, sequences: [UInt16], from base: UInt16 = 1_000) {
        for (index, sequence) in sequences.enumerated() {
            buffer.accept(
                sequence: sequence,
                timestamp: UInt32(index) * 960,
                payload: [UInt8(truncatingIfNeeded: sequence)],
                arrival: Double(index) * 0.02
            )
        }
        _ = base
    }

    @Test func inOrderPacketsComeBackInOrder() {
        let buffer = JitterBuffer()
        fill(buffer, sequences: [10, 11, 12, 13, 14])
        var seen: [UInt8] = []
        for _ in 0..<5 {
            if case .packet(let payload) = buffer.pull(at: 1) { seen.append(payload[0]) }
        }
        #expect(seen == [10, 11, 12, 13, 14])
    }

    /// The point of the buffer: a packet that overtook its neighbour is put
    /// back, not dropped.
    @Test func reorderingIsRepaired() {
        let buffer = JitterBuffer()
        fill(buffer, sequences: [20, 22, 21, 23, 24])
        var seen: [UInt8] = []
        for _ in 0..<5 {
            if case .packet(let payload) = buffer.pull(at: 1) { seen.append(payload[0]) }
        }
        #expect(seen == [20, 21, 22, 23, 24])
    }

    /// The FEC path, and the reason the buffer holds a packet of delay at all:
    /// with the successor in hand, a lost packet is recovered rather than
    /// concealed.
    @Test func aHoleIsRecoveredFromTheNextPacket() {
        let buffer = JitterBuffer()
        fill(buffer, sequences: [30, 32, 33, 34])
        #expect({ if case .packet = buffer.pull(at: 1) { return true } else { return false } }())
        guard case .forwardCorrection(let successor) = buffer.pull(at: 1) else {
            Issue.record("expected the hole to be recovered from its successor")
            return
        }
        #expect(successor == [32])
        #expect(buffer.snapshot.recovered == 1)
        #expect(buffer.snapshot.lost == 1)
    }

    @Test func aRunOfLossesIsConcealed() {
        let buffer = JitterBuffer()
        fill(buffer, sequences: [40, 41, 42, 46, 47, 48])
        var concealed = 0
        for _ in 0..<8 {
            if case .conceal = buffer.pull(at: 1) { concealed += 1 }
        }
        #expect(concealed > 0)
        #expect(buffer.snapshot.lost > 0)
    }

    /// Sequence numbers wrap at 65535. A buffer that compares them numerically
    /// calls everything after the wrap ancient and throws the stream away.
    @Test func theSequenceSpaceWraps() {
        let buffer = JitterBuffer()
        fill(buffer, sequences: [65_534, 65_535, 0, 1, 2])
        var seen = 0
        for _ in 0..<5 {
            if case .packet = buffer.pull(at: 1) { seen += 1 }
        }
        #expect(seen == 5)
        #expect(buffer.snapshot.arrivedTooLate == 0)
    }

    @Test func aDuplicateIsCountedAndDiscarded() {
        let buffer = JitterBuffer()
        fill(buffer, sequences: [50, 51, 51, 52])
        #expect(buffer.snapshot.duplicates == 1)
        #expect(buffer.snapshot.received == 3)
    }

    @Test func anEmptyStreamIsIdleRatherThanLost() {
        let buffer = JitterBuffer()
        guard case .idle = buffer.pull(at: 1) else {
            Issue.record("an unstarted stream must be idle")
            return
        }
        fill(buffer, sequences: [60, 61])
        _ = buffer.pull(at: 1)
        _ = buffer.pull(at: 1)
        guard case .idle = buffer.pull(at: 1) else {
            Issue.record("a drained stream is silence, not loss")
            return
        }
        #expect(buffer.snapshot.lost == 0)
    }

    @Test func lossFeedsBackAsAPercentage() {
        let buffer = JitterBuffer()
        fill(buffer, sequences: [70, 71, 72, 74, 75, 76, 77, 78, 79, 80])
        for _ in 0..<11 { _ = buffer.pull(at: 1) }
        #expect(buffer.snapshot.lossPercent > 0)
        #expect(buffer.snapshot.lossPercent < 50)
    }

    /// **The delay is taken at the start of a talkspurt.** One packet in hand
    /// is not the depth; the stream waits for a second rather than playing the
    /// first and running dry at the first late arrival.
    @Test func aTalkspurtGathersItsDepthBeforeItPlays() {
        let buffer = JitterBuffer()
        buffer.accept(sequence: 90, timestamp: 0, payload: [90], arrival: 0)
        guard case .idle = buffer.pull(at: 0) else {
            Issue.record("one packet is not yet the depth")
            return
        }
        buffer.accept(sequence: 91, timestamp: 960, payload: [91], arrival: 0.02)
        guard case .packet(let first) = buffer.pull(at: 0.02) else {
            Issue.record("two packets are, and the first plays")
            return
        }
        #expect(first == [90])
    }

    /// A burst shorter than the depth — one word — plays once it has had the
    /// time the depth would have taken, rather than waiting for packets that
    /// are not coming.
    @Test func aShortBurstPlaysWhenItsTimeIsUp() {
        let buffer = JitterBuffer()
        buffer.accept(sequence: 95, timestamp: 0, payload: [95], arrival: 0)
        guard case .idle = buffer.pull(at: 0.03) else {
            Issue.record("still inside the depth's time")
            return
        }
        guard case .packet = buffer.pull(at: 0.04) else {
            Issue.record("and played once it has passed")
            return
        }
    }

    /// The depth follows the path: twice the jitter in frames, plus the one
    /// packet FEC needs.
    @Test func theDepthFollowsTheJitter() {
        #expect(JitterBuffer.depth(forJitter: 0) == 1)
        #expect(JitterBuffer.depth(forJitter: 960) == 3, "20 ms of jitter: two frames, and one")
        #expect(JitterBuffer.depth(forJitter: 1_200) == 4)
    }
}
