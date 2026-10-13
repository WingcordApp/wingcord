import Foundation
import Testing

@testable import WingcordVoice

// MARK: - The far end's own account, read byte by byte
//
// **Built from the field layouts rather than from a capture**, because there is
// no capture: this is the first version of this client that reads any of it.
// Every packet below is assembled here from RFC 3550 §6.4 (the reports), RFC
// 4585 §6.2 and §6.3 (the feedback), RFC 5104 §4.3.1 (the full intra request)
// and `draft-alvestrand-rmcat-remb-03` §2.2 (the bandwidth estimate), so what
// they check is that this reader agrees with those documents.
//
// The one thing they cannot check is whether Discord sends what the documents
// describe. `RTCPListener` answers that on the wire instead, by refusing to
// read anything whose records do not tile the datagram — see `isPlaintext`.
@Suite("RTCP")
struct RTCPTests {

    /// One record: the two header bytes, the length in words-past-the-first,
    /// and a body. The length is computed rather than passed, because a wrong
    /// one is exactly the mistake the reader has to survive and not the one
    /// these tests are about.
    private func record(count: UInt8, kind: UInt8, body: [UInt8]) -> [UInt8] {
        precondition(body.count % 4 == 0, "RTCP records are whole words")
        let words = body.count / 4
        return [2 << 6 | count, kind, UInt8(words >> 8), UInt8(words & 0xFF)] + body
    }

    private func word(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }

    /// A report block: the source, the loss byte and its running total, the
    /// highest sequence seen, the jitter, and the two round-trip timestamps.
    private func reportBlock(
        source: UInt32, fractionLost: UInt8, cumulativeLost: Int32, jitter: UInt32
    ) -> [UInt8] {
        let lost = UInt32(bitPattern: cumulativeLost) & 0x00FF_FFFF
        return word(source)
            + [fractionLost,
               UInt8(truncatingIfNeeded: lost >> 16),
               UInt8(truncatingIfNeeded: lost >> 8),
               UInt8(truncatingIfNeeded: lost)]
            + word(9_001) + word(jitter) + word(0) + word(0)
    }

    private func read(_ packet: [UInt8]) -> RTCP.Feedback {
        var feedback = RTCP.Feedback()
        RTCP.read(packet, into: &feedback)
        return feedback
    }

    // MARK: What a healthy stream looks like

    @Test("A receiver report yields the loss and the jitter it carries")
    func receiverReport() {
        let packet = record(
            count: 1, kind: 201,
            body: word(0x1234_5678) + reportBlock(
                source: 4242, fractionLost: 64, cumulativeLost: 900, jitter: 1_500
            )
        )
        #expect(RTCP.isRTCP(packet))
        #expect(RTCP.isPlaintext(packet))

        let feedback = read(packet)
        #expect(feedback.packets == 1)
        #expect(feedback.receiverReports == 1)
        #expect(
            feedback.reportedSources == [4_242],
            "which of our streams it is reporting on is the point of reading it"
        )
        #expect(feedback.worstFractionLost == 64)
        #expect(feedback.cumulativeLost == 900)
        #expect(feedback.worstJitter == 1_500)
        #expect(!feedback.wantsKeyframe)
    }

    /// A sender report is a receiver report with twenty bytes of sender
    /// information wedged in front of the blocks, and reading it as though it
    /// were not is how a parser silently reports somebody else's numbers.
    @Test("A sender report's blocks are found past its sender information")
    func senderReport() {
        let senderInfo = word(0) + word(0) + word(0) + word(500) + word(80_000)
        let packet = record(
            count: 2, kind: 200,
            body: word(1) + senderInfo
                + reportBlock(source: 1, fractionLost: 10, cumulativeLost: 3, jitter: 20)
                + reportBlock(source: 2, fractionLost: 200, cumulativeLost: 7, jitter: 90)
        )
        let feedback = read(packet)
        #expect(feedback.senderReports == 1)
        #expect(feedback.reportedSources == [1, 2], "both blocks, not only the first")
        #expect(feedback.worstFractionLost == 200, "the worse of the two blocks")
        #expect(feedback.worstJitter == 90)
    }

    /// Twenty-four bits, two's complement: a receiver that got duplicates
    /// reports fewer losses than zero, and clamping that to zero would hide a
    /// path that is duplicating packets.
    @Test("A negative cumulative loss stays negative")
    func negativeLoss() {
        let packet = record(
            count: 1, kind: 201,
            body: word(1) + reportBlock(
                source: 1, fractionLost: 0, cumulativeLost: -5, jitter: 0
            )
        )
        #expect(read(packet).cumulativeLost == -5)
    }

    // MARK: What a stream nobody can decode looks like

    @Test("A picture loss indication asks for a keyframe")
    func pictureLoss() {
        let packet = record(count: 1, kind: 206, body: word(1) + word(4242))
        let feedback = read(packet)
        #expect(feedback.pictureLossIndications == 1)
        #expect(feedback.wantsKeyframe)
    }

    @Test("A full intra request asks for one too")
    func fullIntraRequest() {
        let packet = record(
            count: 4, kind: 206,
            body: word(1) + word(0) + word(4242) + [3, 0, 0, 0]
        )
        let feedback = read(packet)
        #expect(feedback.fullIntraRequests == 1)
        #expect(feedback.wantsKeyframe)
    }

    /// The one this client sends. It has to be readable by the same rules it
    /// reads everything else by, or it is not the shape it thinks it is.
    @Test("The indication this client sends reads back as one")
    func ourOwnIndicationRoundTrips() {
        let packet = RTCP.pictureLossIndication(from: 1_000, about: 2_000)
        #expect(packet.count == 12)
        #expect(RTCP.isRTCP(packet))
        #expect(RTCP.isPlaintext(packet), "the length field has to describe it exactly")

        let feedback = read(packet)
        #expect(feedback.pictureLossIndications == 1)
        #expect(feedback.packets == 1)
    }

    /// Each FCI word names one lost packet and a bitmask of the sixteen behind
    /// it, so the count is not the number of words.
    @Test("A generic NACK counts every packet it names")
    func negativeAcknowledgement() {
        let packet = record(
            count: 1, kind: 205,
            body: word(1) + word(4242)
                + [0x10, 0x00, 0b0000_0001, 0b0000_0011]   // one, plus three more
        )
        #expect(read(packet).negativeAcknowledgements == 4)
    }

    private func requests(in packet: [UInt8]) -> (RTCP.Feedback, [RTCP.Request]) {
        var feedback = RTCP.Feedback()
        var asked: [RTCP.Request] = []
        RTCP.read(packet, into: &feedback) { asked.append($0) }
        return (feedback, asked)
    }

    /// The bitmask names the sixteen packets after the first, least
    /// significant bit first — RFC 4585 §6.2.1 — and the request names the
    /// stream, because a sequence number means nothing outside one.
    @Test("A NACK becomes a request to resend exactly the packets it names")
    func negativeAcknowledgementRequest() {
        let packet = record(
            count: 1, kind: 205,
            body: word(1) + word(4242)
                + [0x10, 0x00, 0b0000_0001, 0b0000_0011]
        )
        let (_, asked) = requests(in: packet)
        #expect(asked == [.retransmit(ssrc: 4242, sequences: [0x1000, 0x1001, 0x1002, 0x1009])])
    }

    /// The one this client sends, read back by the rules it reads everything
    /// by — across a sequence wrap, and with a run longer than one mask.
    @Test("The NACK this client sends reads back as the packets it asked for")
    func ourOwnNegativeAcknowledgementRoundTrips() {
        let lost: [UInt16] = [65_534, 65_535, 0, 3, 17, 18, 40]
        let packet = RTCP.negativeAcknowledgement(from: 1_000, about: 2_000, sequences: lost)
        #expect(RTCP.isPlaintext(packet), "the length field has to describe it exactly")
        #expect(packet.count == 12 + 4 * 3, "65534 carries 3 and 17; 18 and 40 their own")
        let (feedback, asked) = requests(in: packet)
        #expect(asked == [.retransmit(ssrc: 2_000, sequences: [65_534, 65_535, 0, 3, 17, 18, 40])])
        #expect(feedback.negativeAcknowledgements == 7)
    }

    @Test("A picture loss names its stream, and a full intra request each of its entries")
    func keyframeRequests() {
        let (_, pli) = requests(in: record(count: 1, kind: 206, body: word(1) + word(4242)))
        #expect(pli == [.keyframe(ssrc: 4242)])
        let fir = record(
            count: 4, kind: 206,
            body: word(1) + word(0) + word(4242) + [3, 0, 0, 0] + word(4343) + [9, 0, 0, 0]
        )
        let (_, asked) = requests(in: fir)
        #expect(asked == [.keyframe(ssrc: 4242), .keyframe(ssrc: 4343)])
    }

    /// What the bitrate controller reads for the stream it drives — the audio
    /// beside it may be losing nothing.
    @Test("Loss is kept for each stream reported on")
    func lossPerStream() {
        let packet = record(
            count: 2, kind: 201,
            body: word(1)
                + reportBlock(source: 10, fractionLost: 3, cumulativeLost: 1, jitter: 0)
                + reportBlock(source: 11, fractionLost: 40, cumulativeLost: 9, jitter: 0)
        )
        let feedback = read(packet)
        #expect(feedback.fractionLost == [10: 3, 11: 40])
        #expect(feedback.worstFractionLost == 40)
    }

    @Test("Transport-wide feedback is counted, and read as nothing else")
    func transportWideFeedback() {
        let packet = record(count: 15, kind: 205, body: word(1) + word(4242) + word(0) + word(0))
        let (feedback, asked) = requests(in: packet)
        #expect(feedback.transportFeedback == 1)
        #expect(feedback.negativeAcknowledgements == 0)
        #expect(asked.isEmpty)
    }

    /// Our own reports, read back by the rules this client reads everybody's
    /// by: the sender information, the blocks, and the NTP time a receiver
    /// echoes back to time the round trip.
    @Test("The reports this client sends read back as what they say")
    func ourOwnReportsRoundTrip() {
        let block = RTCP.ReportBlock(
            ssrc: 4242, fractionLost: 26, cumulativeLost: -3, highestSequence: 0x0001_0005,
            jitter: 480, lastSenderReport: 0xA1B2_C3D4, delaySinceLastSenderReport: 65_536
        )
        let sender = RTCP.SenderInfo(
            ntpTime: 0x1122_3344_5566_7788, rtpTimestamp: 960_000, packets: 50, octets: 4_000
        )
        let report = RTCP.report(from: 1_000, sender: sender, blocks: [block])
        #expect(report.count == 4 + 4 + 20 + 24)
        #expect(RTCP.isPlaintext(report))
        let feedback = read(report)
        #expect(feedback.senderReports == 1)
        #expect(feedback.reportedSources == [4242])
        #expect(feedback.fractionLost == [4242: 26])
        #expect(feedback.cumulativeLost == -3)
        #expect(feedback.worstJitter == 480)
        #expect(feedback.senderReportTimes == [1_000: 0x3344_5566], "LSR is the NTP time's middle")

        let receiverOnly = RTCP.report(from: 1_000, sender: nil, blocks: [])
        #expect(receiverOnly.count == 8)
        #expect(read(receiverOnly).receiverReports == 1)
    }

    @Test("NTP time counts from 1900")
    func ntpEpoch() {
        #expect(RTCP.ntpTime(Date(timeIntervalSince1970: 0)) == UInt64(2_208_988_800) << 32)
        let half = RTCP.ntpTime(Date(timeIntervalSince1970: 0.5))
        #expect(half & 0xFFFF_FFFF == 0x8000_0000)
    }

    /// A mantissa scaled by a power of two, which is how one word covers
    /// kilobits to gigabits.
    @Test("A bandwidth estimate is a mantissa and an exponent")
    func bandwidthEstimate() {
        // 2,000,000 bits per second: 125,000 << 4.
        let exponent: UInt8 = 4
        let mantissa: UInt32 = 125_000
        let body = word(1) + word(0)
            + [0x52, 0x45, 0x4D, 0x42]                          // "REMB"
            + [1,
               exponent << 2 | UInt8(truncatingIfNeeded: mantissa >> 16),
               UInt8(truncatingIfNeeded: mantissa >> 8),
               UInt8(truncatingIfNeeded: mantissa)]
            + word(4242)
        let packet = record(count: 15, kind: 206, body: body)
        #expect(read(packet).bitrateEstimate == 2_000_000)
    }

    @Test("Payload feedback that is not REMB leaves the estimate alone")
    func unnamedApplicationFeedback() {
        let body = word(1) + word(0) + [0x4E, 0x4F, 0x50, 0x45] + word(0)
        #expect(read(record(count: 15, kind: 206, body: body)).bitrateEstimate == nil)
    }

    // MARK: Walking a compound packet

    /// **The whole point of the length field.** A record this client does not
    /// read has to be stepped over by its own length, or everything behind it
    /// is read at the wrong offset — and the interesting record is usually the
    /// last one.
    @Test("An unread record is stepped over rather than stopping the walk")
    func compoundPacket() {
        let sender = record(
            count: 1, kind: 200,
            body: word(1) + word(0) + word(0) + word(0) + word(500) + word(80_000)
                + reportBlock(source: 1, fractionLost: 5, cumulativeLost: 1, jitter: 7)
        )
        // Source description, which nothing here reads.
        let description = record(count: 1, kind: 202, body: word(1) + [1, 2, 0x61, 0x62] + word(0))
        let pli = record(count: 1, kind: 206, body: word(1) + word(4242))
        let packet = sender + description + pli

        #expect(RTCP.isPlaintext(packet))
        let feedback = read(packet)
        #expect(feedback.packets == 1, "a compound packet is one datagram")
        #expect(feedback.senderReports == 1)
        #expect(feedback.worstFractionLost == 5)
        #expect(feedback.pictureLossIndications == 1)
    }

    @Test("A record type nothing names is reported as itself")
    func unnamedRecord() {
        #expect(read(record(count: 0, kind: 207, body: word(1))).unnamed.isEmpty)
        // 207 is named and ignored; anything outside the range is not RTCP at
        // all and never reaches the reader.
        #expect(!RTCP.isRTCP(record(count: 0, kind: 199, body: word(1))))
    }

    // MARK: Telling a report from a sealed report

    /// Both carry the same eight readable bytes, and only the length says
    /// which. A sealed packet is a tag and a counter longer than it claims.
    @Test("A sealed report is not mistaken for a plain one")
    func sealedIsNotPlaintext() {
        let plain = record(count: 1, kind: 201, body: word(1) + reportBlock(
            source: 1, fractionLost: 0, cumulativeLost: 0, jitter: 0
        ))
        #expect(RTCP.isPlaintext(plain))

        let sealed = plain + [UInt8](repeating: 0xAB, count: 20)
        #expect(RTCP.isRTCP(sealed), "the header stays readable so it can be routed")
        #expect(!RTCP.isPlaintext(sealed), "and the length says it is not what it looks like")
    }

    /// A length that runs past the end stops the walk, keeping what was read
    /// before it. Truncation is a network event, not a reason to lose the
    /// records that did arrive.
    @Test("A record longer than the datagram stops the walk without losing what came before")
    func truncated() {
        let pli = record(count: 1, kind: 206, body: word(1) + word(4242))
        var lying = record(count: 1, kind: 201, body: word(1))
        lying[3] = 40   // claims forty more words than it has
        let feedback = read(pli + lying)
        #expect(feedback.pictureLossIndications == 1)
        #expect(feedback.receiverReports == 0)
    }

    @Test("Neither RTP nor rubbish is read as a report")
    func notRTCP() {
        // An H.264 packet with the marker set, which is the collision this
        // range exists to prevent.
        var rtp = [UInt8](repeating: 0, count: 16)
        rtp[0] = 2 << 6
        rtp[1] = RTP.PayloadType.h264 | 0x80
        #expect(!RTCP.isRTCP(rtp))
        #expect(!RTCP.isRTCP([]))
        #expect(!RTCP.isRTCP([0xFF, 0xC8, 0, 1]), "version one is not RTCP")
    }
}

// MARK: - Pacing a recovery

/// **Both ways of getting a recovery brake wrong have shipped in this project,
/// and each one killed every call it touched.** See `RecoveryPacer`.
@Suite("Recovery pacing")
struct RecoveryPacerTests {

    private let start = ContinuousClock.now

    @Test("The first request runs at once")
    func firstRuns() {
        var pacer = RecoveryPacer()
        #expect(pacer.request(at: start) == .now)
    }

    /// The fault that made a call transmit nothing for its whole life: the
    /// second refusal was a hundred and fifty milliseconds after the first, and
    /// it was discarded rather than held.
    @Test("A request inside the window is deferred, never dropped")
    func deferredNotDropped() {
        var pacer = RecoveryPacer()
        #expect(pacer.request(at: start) == .now)

        let soon = start.advanced(by: .milliseconds(150))
        guard case .after(let wait) = pacer.request(at: soon) else {
            Issue.record("a request inside the window has to be held, not dropped")
            return
        }
        #expect(wait == RecoveryPacer.interval - .milliseconds(150))
    }

    /// One timer, however many requests arrive behind it.
    @Test("Further requests fold into the attempt already waiting")
    func foldsIntoTheWait() {
        var pacer = RecoveryPacer()
        _ = pacer.request(at: start)
        _ = pacer.request(at: start.advanced(by: .milliseconds(100)))
        #expect(pacer.request(at: start.advanced(by: .milliseconds(200))) == .alreadyWaiting)
        #expect(pacer.request(at: start.advanced(by: .milliseconds(300))) == .alreadyWaiting)
    }

    /// And once the wait elapses the brake is free again — otherwise a session
    /// that needed two recoveries would only ever get one.
    @Test("The brake is free again once a wait has elapsed")
    func freeAfterTheWait() {
        var pacer = RecoveryPacer()
        _ = pacer.request(at: start)
        _ = pacer.request(at: start.advanced(by: .milliseconds(100)))
        pacer.waitElapsed()

        let later = start.advanced(by: RecoveryPacer.interval + .milliseconds(1))
        #expect(pacer.request(at: later) == .now)
        guard case .after = pacer.request(at: later.advanced(by: .milliseconds(10))) else {
            Issue.record("a second storm has to be braked like the first")
            return
        }
    }

    @Test("A request past the window runs at once")
    func pastTheWindow() {
        var pacer = RecoveryPacer()
        _ = pacer.request(at: start)
        let later = start.advanced(by: RecoveryPacer.interval + .milliseconds(1))
        #expect(pacer.request(at: later) == .now)
    }
}

// MARK: - What one received stream looked like

@Suite("Reception statistics")
struct ReceptionStatisticsTests {

    private func block(_ statistics: inout ReceptionStatistics) -> RTCP.ReportBlock? {
        statistics.block(for: 7, lastSenderReport: 0, delaySinceLastSenderReport: 0)
    }

    @Test("A clean stream reports nothing lost")
    func clean() throws {
        var statistics = ReceptionStatistics(clockRate: 48_000)
        for index in 0..<10 {
            statistics.record(sequence: 100 + UInt16(index), timestamp: UInt32(index) * 960, arrival: Double(index) * 0.02)
        }
        let report = try #require(block(&statistics))
        #expect(report.fractionLost == 0)
        #expect(report.cumulativeLost == 0)
        #expect(report.highestSequence == 109)
        #expect(report.jitter == 0, "a constant transit is no jitter")
    }

    /// RFC 3550 A.3: lost is expected less received, and the fraction is the
    /// window's own — so a window with no new loss reports none.
    @Test("Loss is counted overall and per report")
    func loss() throws {
        var statistics = ReceptionStatistics(clockRate: 48_000)
        for sequence: UInt16 in [0, 1, 2, 3, 4, 7, 8, 9] {
            statistics.record(sequence: sequence, timestamp: UInt32(sequence) * 960, arrival: Double(sequence) * 0.02)
        }
        let first = try #require(block(&statistics))
        #expect(first.cumulativeLost == 2)
        #expect(first.fractionLost == 51, "two of ten, out of 256")
        for sequence: UInt16 in 10...14 {
            statistics.record(sequence: sequence, timestamp: UInt32(sequence) * 960, arrival: Double(sequence) * 0.02)
        }
        let second = try #require(block(&statistics))
        #expect(second.cumulativeLost == 2)
        #expect(second.fractionLost == 0)
    }

    @Test("A wrap of the sequence counts as a cycle")
    func wrap() throws {
        var statistics = ReceptionStatistics(clockRate: 90_000)
        for (index, sequence) in [UInt16(65_534), 65_535, 0, 1].enumerated() {
            statistics.record(sequence: sequence, timestamp: 0, arrival: Double(index) * 0.01)
        }
        let report = try #require(block(&statistics))
        #expect(report.highestSequence == 1 << 16 | 1)
        #expect(report.cumulativeLost == 0)
    }

    @Test("A stream nothing has arrived on has no block")
    func empty() {
        var statistics = ReceptionStatistics(clockRate: 48_000)
        #expect(block(&statistics) == nil)
    }
}
