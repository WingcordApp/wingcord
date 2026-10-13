import Foundation

// MARK: - What one received stream looked like, as RFC 3550 counts it
//
// **The far end can only adapt to a path it is told about.** A receiver report
// block is how a sender learns what reached us — how much was lost overall and
// since the last report, how far the sequence got, and how unevenly packets
// arrived — and an SFU that never hears one is sending blind. This is the
// arithmetic of RFC 3550 appendices A.1, A.3 and A.8, one per stream.

struct ReceptionStatistics: Sendable {
    /// The stream's RTP clock: 48 kHz for Opus, 90 kHz for video.
    let clockRate: Double

    private var baseSequence: UInt16?
    private var maximumSequence: UInt16 = 0
    /// Sequence-number wraps, already shifted into the high sixteen bits.
    private var cycles: UInt32 = 0
    private var received: UInt32 = 0
    private var expectedAtLastReport: UInt32 = 0
    private var receivedAtLastReport: UInt32 = 0
    private var lastTransit: Double?
    /// The smoothed inter-arrival jitter, in the stream's own clock units.
    private(set) var jitter: Double = 0

    init(clockRate: Double) {
        self.clockRate = clockRate
    }

    /// One packet, as it arrived.
    mutating func record(sequence: UInt16, timestamp: UInt32, arrival: TimeInterval) {
        if baseSequence == nil {
            baseSequence = sequence
            maximumSequence = sequence
        } else if sequence &- maximumSequence < 0x8000, sequence != maximumSequence {
            // Ahead of the highest so far — counting a wrap when it passes zero.
            if sequence < maximumSequence { cycles &+= 1 << 16 }
            maximumSequence = sequence
        }
        received &+= 1

        // RFC 3550 §6.4.1: the difference between two packets' transit times,
        // smoothed by a sixteenth.
        let transit = arrival * clockRate - Double(timestamp)
        if let lastTransit {
            jitter += (abs(transit - lastTransit) - jitter) / 16
        }
        lastTransit = transit
    }

    /// The report block for this stream, and the window since the last one
    /// closes with it.
    ///
    /// - Parameters:
    ///   - lastSenderReport: the middle 32 bits of the NTP time in the last
    ///     sender report received about this stream, or 0 without one.
    ///   - delaySinceLastSenderReport: the time since it arrived, in units of
    ///     1/65536 s.
    mutating func block(
        for ssrc: UInt32, lastSenderReport: UInt32, delaySinceLastSenderReport: UInt32
    ) -> RTCP.ReportBlock? {
        guard let baseSequence else { return nil }
        let extendedMaximum = cycles | UInt32(maximumSequence)
        let expected = extendedMaximum &- UInt32(baseSequence) &+ 1
        let lost = Int64(expected) - Int64(received)

        let expectedInterval = expected &- expectedAtLastReport
        let receivedInterval = received &- receivedAtLastReport
        expectedAtLastReport = expected
        receivedAtLastReport = received
        let lostInterval = Int64(expectedInterval) - Int64(receivedInterval)
        let fraction: UInt8 = expectedInterval == 0 || lostInterval <= 0
            ? 0 : UInt8(min(255, (lostInterval << 8) / Int64(expectedInterval)))

        return RTCP.ReportBlock(
            ssrc: ssrc,
            fractionLost: fraction,
            // Twenty-four bits, signed: duplicates can make it negative.
            cumulativeLost: Int32(max(-0x80_0000, min(0x7F_FFFF, lost))),
            highestSequence: extendedMaximum,
            jitter: UInt32(jitter.rounded()),
            lastSenderReport: lastSenderReport,
            delaySinceLastSenderReport: delaySinceLastSenderReport
        )
    }
}
