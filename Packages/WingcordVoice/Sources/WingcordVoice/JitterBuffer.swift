import Foundation

// MARK: - The jitter buffer
//
// What actually makes a voice stream survive a network. UDP delivers packets
// late, out of order, twice, or not at all, and a client that hands them
// straight to a decoder in the order they arrive produces exactly those four
// faults as audio.
//
// The design is one idea: **hold one packet of delay, and spend it.** With the
// next packet already in hand, a hole in the stream has three possible answers
// rather than one —
//
//   1. the packet arrived late and is now here, so decode it normally;
//   2. it is genuinely gone, but the packet *after* it carries Opus's in-band
//      redundant copy, so decode that copy — the loss becomes inaudible;
//   3. neither, so run the concealer, which extrapolates pitch and spectrum
//      from what was last decoded.
//
// Answer 2 is the one that needs the delay, and it is why the buffer exists at
// all rather than a plain reorder queue. A client that does not hold the delay
// has FEC switched on in its encoder and can never use anybody else's.
//
// **The delay is taken at the start of every talkspurt, and only there.** A
// talker's packets stop when they stop talking — Discord's gate and Opus's DTX
// both see to that — so each burst of speech begins with an empty buffer. It
// gathers its target depth before it plays a frame, and then plays straight
// through: the delay is in place for the jitter that follows, and it is
// changed between sentences, never inside one, where a change is audible. An
// earlier version handed out each packet the moment it existed, which held no
// delay at all and turned ordinary jitter into concealment.
//
// **The depth follows the path.** Twice the measured inter-arrival jitter,
// rounded up to whole frames, plus the one packet FEC needs — and a packet
// that arrives after its turn has gone grows it, because that is a path the
// estimate has not caught up with yet.

/// One speaker's packets, waiting.
///
/// Not an actor. It is written from the network's receive queue and read from
/// the mix pump, both off the main actor, and the critical sections are a
/// dictionary insert and a lookup — an actor here would put a suspension point
/// between a packet arriving and being stored, which on a burst reorders the
/// burst.
public final class JitterBuffer: @unchecked Sendable {

    /// What one pull is asking the decoder to do.
    public enum Frame: Sendable {
        /// The packet, in order.
        case packet([UInt8])
        /// The *following* packet, whose redundant copy stands in for the one
        /// that was lost. Decoded with Opus's FEC flag set.
        case forwardCorrection([UInt8])
        /// Nothing to decode. Run the concealer.
        case conceal
        /// The stream has nothing pending and is not late — silence, not a gap.
        case idle
    }

    public struct Statistics: Sendable, Equatable {
        public var received: Int = 0
        public var lost: Int = 0
        public var recovered: Int = 0
        public var concealed: Int = 0
        public var duplicates: Int = 0
        public var arrivedTooLate: Int = 0
        /// Depth in packets, which at 20 ms each is also the added latency.
        public var depth: Int = 0
        /// RFC 3550's smoothed inter-arrival jitter, in RTP timestamp units.
        public var jitter: Double = 0

        /// Loss as a percentage of what should have arrived, for the encoder's
        /// FEC feedback. Recovered packets still count as lost: they were lost
        /// on the wire, and the far end has to keep spending redundancy to keep
        /// recovering them.
        public var lossPercent: Int {
            let expected = received + lost
            guard expected > 0 else { return 0 }
            return Int((Double(lost) / Double(expected) * 100).rounded())
        }
    }

    /// The smallest depth worth holding. One packet, because that is what FEC
    /// recovery needs and it is the reason the buffer is not zero-delay.
    static let minimumDepth = 2
    /// The largest. Past ten packets — 200 ms — a conversation stops being one:
    /// people talk over each other because the gap they are leaving is being
    /// spent in a queue. A path that needs more than this is a path where
    /// dropping is the better answer.
    static let maximumDepth = 10

    private let lock = NSLock()
    private var packets: [UInt16: [UInt8]] = [:]
    /// The sequence the next pull will ask for. `nil` until the first packet
    /// decides where the stream starts.
    private var nextSequence: UInt16?
    private var targetDepth = JitterBuffer.minimumDepth
    /// The depth the late packets have asked for, on top of the jitter's.
    private var lateAllowance = 0
    private var statistics = Statistics()
    /// Whether the stream is gathering its depth before it plays — at its
    /// start, after each silence, and after it ran dry mid-word.
    private var isGathering = true
    /// When the talkspurt's first packet arrived, so a burst shorter than the
    /// target depth — one word — plays once it has had the time it would have
    /// taken, rather than waiting for packets that are not coming.
    private var gatheringSince: TimeInterval?

    /// Inter-arrival jitter state — RFC 3550 §6.4.1.
    private var lastTransit: Double?
    private var smoothedJitter: Double = 0

    public init() {}

    // MARK: Writing

    /// Files a packet. Called from the receive queue, once per datagram.
    ///
    /// - Parameter arrival: the local clock at receipt, in seconds.
    public func accept(
        sequence: UInt16,
        timestamp: UInt32,
        payload: [UInt8],
        arrival: TimeInterval
    ) {
        lock.lock()
        defer { lock.unlock() }

        // Jitter first, because it is measured on arrivals rather than on
        // anything the buffer decides to do with them.
        let transit = arrival * Double(OpusFormat.sampleRate) - Double(timestamp)
        if let lastTransit {
            let deviation = abs(transit - lastTransit)
            smoothedJitter += (deviation - smoothedJitter) / 16
        }
        lastTransit = transit
        statistics.jitter = smoothedJitter

        if isGathering, gatheringSince == nil { gatheringSince = arrival }
        guard let expected = nextSequence else {
            nextSequence = sequence
            packets[sequence] = payload
            statistics.received += 1
            return
        }

        // **Signed distance, not a comparison.** Sequence numbers wrap at
        // 65535, and `sequence < expected` calls the packet after the wrap
        // ancient and throws away the whole stream once every twenty minutes.
        let distance = Int16(bitPattern: sequence &- expected)

        if distance < 0 {
            // Behind the read head. Either a duplicate or a straggler that has
            // already been concealed — the audio for it has been produced, so
            // there is nothing to do with it but count it.
            if packets[sequence] != nil {
                statistics.duplicates += 1
            } else {
                statistics.arrivedTooLate += 1
                // A path the jitter estimate has not caught up with yet. The
                // allowance grows a packet at a time and is spent at the next
                // talkspurt, when the depth is set.
                lateAllowance = min(JitterBuffer.maximumDepth, lateAllowance + 1)
            }
            return
        }

        if packets.updateValue(payload, forKey: sequence) != nil {
            statistics.duplicates += 1
            return
        }
        statistics.received += 1

        // A stream that has run far ahead of the read head has had a long gap
        // — a lid closed, a network switch. Re-seating is better than
        // concealing three hundred frames one at a time.
        if distance > JitterBuffer.maximumDepth * 4 {
            reseat(to: sequence)
        }
    }

    // MARK: Reading

    /// What to feed the decoder for this tick. Called once per 20 ms per
    /// speaker, from the mix pump, on the output device's clock.
    ///
    /// - Parameter now: the local clock, in seconds — the same clock arrivals
    ///   were stamped with.
    public func pull(at now: TimeInterval) -> Frame {
        lock.lock()
        defer { lock.unlock() }

        guard let expected = nextSequence else { return .idle }

        if isGathering {
            // **The delay, taken here and nowhere else.** The depth is set for
            // this talkspurt from the jitter so far and the late packets since
            // the last one; then the stream waits for it — or for a burst
            // shorter than it to have had the time it would have taken.
            targetDepth = min(
                JitterBuffer.maximumDepth,
                max(JitterBuffer.minimumDepth, Self.depth(forJitter: smoothedJitter) + lateAllowance)
            )
            let waited = gatheringSince.map { now - $0 } ?? 0
            guard packets.count >= targetDepth || waited >= Double(targetDepth) * 0.02 else {
                statistics.depth = packets.count
                return .idle
            }
            isGathering = false
            lateAllowance = 0
        }

        if let payload = packets.removeValue(forKey: expected) {
            nextSequence = expected &+ 1
            statistics.depth = packets.count
            return .packet(payload)
        }

        // The packet is not here. If the next one is, its redundant copy stands
        // in for it — this is the case the whole buffer exists to reach.
        if let successor = packets[expected &+ 1] {
            nextSequence = expected &+ 1
            statistics.lost += 1
            statistics.recovered += 1
            statistics.depth = packets.count
            return .forwardCorrection(successor)
        }

        // Nothing at all. If the buffer is empty the speaker has stopped — or
        // the stream ran dry mid-word, which from here is the same thing — and
        // the next packet starts a talkspurt that gathers its depth again.
        // Silence rather than a hole, and no loss to report.
        if packets.isEmpty {
            statistics.depth = 0
            isGathering = true
            gatheringSince = nil
            return .idle
        }

        nextSequence = expected &+ 1
        statistics.lost += 1
        statistics.concealed += 1
        statistics.depth = packets.count
        return .conceal
    }

    /// Drops everything and restarts at `sequence`. Called on a long gap and on
    /// a speaker rejoining.
    private func reseat(to sequence: UInt16) {
        packets = packets.filter { key, _ in
            Int16(bitPattern: key &- sequence) >= 0
        }
        nextSequence = packets.keys.min { lhs, rhs in
            Int16(bitPattern: lhs &- sequence) < Int16(bitPattern: rhs &- sequence)
        } ?? sequence
        lastTransit = nil
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        packets.removeAll(keepingCapacity: true)
        nextSequence = nil
        lastTransit = nil
        smoothedJitter = 0
        targetDepth = JitterBuffer.minimumDepth
        lateAllowance = 0
        isGathering = true
        gatheringSince = nil
    }

    /// Twice the jitter, in whole 20 ms frames, plus the one FEC needs.
    ///
    /// - Parameter jitter: RFC 3550's smoothed inter-arrival jitter, in 48 kHz
    ///   timestamp units.
    static func depth(forJitter jitter: Double) -> Int {
        let frames = 2 * jitter / Double(OpusFormat.frameSize)
        return Int(frames.rounded(.up)) + 1
    }

    public var snapshot: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return statistics
    }
}
