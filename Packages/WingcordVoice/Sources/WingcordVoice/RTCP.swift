import Foundation
import QuartzCore
import Synchronization

// MARK: - What the far end says about what we sent it
//
// **The only instrument on this machine that can see the other end of the
// path.** Every other counter in this package measures what left here: frames
// encoded, frames sealed, packets written to a socket. All of them read healthy
// on a stream nobody can watch, because none of them is downstream of the
// network — a share that the SFU discards and a share the viewer cannot decode
// produce identical numbers on this side, and two sessions were spent guessing
// between them.
//
// RTCP is the answer coming back. A receiver report says how many of our
// packets arrived and how many did not; a picture loss indication says a viewer
// has our packets and cannot start from them; silence says the server is not
// receiving anything at all. Those are three different faults with three
// different fixes, and until this existed the trace said `in=153` and left the
// reader to guess which.
//
// RFC 3550 §6 for the sender and receiver reports, RFC 4585 §6 for the
// transport and payload-specific feedback, RFC 5104 §4.3.1 for the full intra
// request, and `draft-alvestrand-rmcat-remb` for the bitrate estimate.

public enum RTCP {

    /// The payload types RFC 3550 reserves. A datagram is RTCP rather than RTP
    /// when its payload type falls in here — the two share a port and a version
    /// number, and this range is reserved in RTP for exactly this test.
    public static let payloadTypes: ClosedRange<UInt8> = 200...207

    /// The bytes of an RTCP record that stay in the clear when the packet is
    /// encrypted: the four-byte header and the sender's SSRC.
    ///
    /// **Eight, not twelve.** An RTCP header is four bytes shorter than an RTP
    /// one, and opening one with an RTP-sized prefix authenticates four bytes
    /// of the wrong thing and fails every time — which is what the call's
    /// `transport would not open` count has been made of all along.
    public static let clearPrefixLength = 8

    enum Kind: UInt8 {
        case senderReport = 200
        case receiverReport = 201
        case sourceDescription = 202
        case goodbye = 203
        case application = 204
        /// Transport-layer feedback: NACK, and transport-wide congestion
        /// control.
        case transportFeedback = 205
        /// Payload-specific feedback: picture loss, slice loss, full intra
        /// request, and the receiver's bandwidth estimate.
        case payloadFeedback = 206
        case extendedReport = 207
    }

    /// What arrived since the last drain.
    ///
    /// Accumulated rather than reported per packet: an SFU sends these several
    /// times a second per stream, and one line each would bury the handful that
    /// say why a picture is missing.
    public struct Feedback: Sendable, Equatable {
        public var packets = 0
        public var senderReports = 0
        public var receiverReports = 0
        /// The worst `fraction_lost` in the window, as the eighth of a per-cent
        /// unit RFC 3550 defines: the value is out of 256.
        public var worstFractionLost: UInt8 = 0
        /// The highest cumulative loss any report block claimed. Signed on the
        /// wire — a receiver that got duplicates can report a negative — and
        /// carried as such rather than clamped, because a negative number here
        /// is a real and diagnosable state.
        public var cumulativeLost: Int32 = 0
        /// The worst interarrival jitter reported, in the stream's own clock
        /// units — 90 kHz for video, 48 kHz for Opus.
        public var worstJitter: UInt32 = 0
        /// **A viewer has our packets and cannot decode them.** Picture loss
        /// and full intra requests both mean "send a keyframe"; they are
        /// counted apart because they come from different layers and a client
        /// that answers only one of them looks like it answers neither.
        public var pictureLossIndications = 0
        public var fullIntraRequests = 0
        /// Packets a receiver says it never got, from a generic NACK.
        public var negativeAcknowledgements = 0
        /// Transport-wide congestion control reports. Counted and not yet read:
        /// they are what a delay-based estimator would run on, and whether the
        /// server sends them at all is the first thing that estimator needs to
        /// know.
        public var transportFeedback = 0
        /// The receiver's estimate of what the path will carry, in bits per
        /// second.
        public var bitrateEstimate: Int?
        /// Record types this client does not name, so an unexpected one shows
        /// up as itself rather than as silence.
        public var unnamed: Set<UInt8> = []
        /// **Which of our streams the far end says it is receiving.**
        ///
        /// A report block names the source it describes, and that is the whole
        /// difference between "the SFU has our video" and "the SFU has the
        /// audio SSRC we registered and never sent a byte on". A stream session
        /// announces both and transmits only the second of them, so `lost=0%`
        /// on its own has been saying nothing at all.
        public var reportedSources: Set<UInt32> = []
        /// The worst `fraction_lost` reported about each of our streams, out of
        /// 256 — what the bitrate controller reads for the one it drives.
        public var fractionLost: [UInt32: UInt8] = [:]
        /// The middle 32 bits of the NTP time in each sender report, by the
        /// stream it describes — what our own report blocks echo back as LSR,
        /// which is how the far end measures the round trip.
        public var senderReportTimes: [UInt32: UInt32] = [:]

        public var isEmpty: Bool { packets == 0 }

        /// Whether the far end has asked for a keyframe since the last drain.
        public var wantsKeyframe: Bool {
            pictureLossIndications > 0 || fullIntraRequests > 0
        }

        /// Folds a window into a longer one, so the line a reader sees covers
        /// the same interval as everything printed beside it.
        ///
        /// Counts add; the "worst seen" fields take the worse of the two; the
        /// bandwidth estimate takes the newer, since it is a current opinion
        /// rather than a total.
        public mutating func merge(_ other: Feedback) {
            packets += other.packets
            senderReports += other.senderReports
            receiverReports += other.receiverReports
            worstFractionLost = max(worstFractionLost, other.worstFractionLost)
            if abs(other.cumulativeLost) > abs(cumulativeLost) {
                cumulativeLost = other.cumulativeLost
            }
            worstJitter = max(worstJitter, other.worstJitter)
            pictureLossIndications += other.pictureLossIndications
            fullIntraRequests += other.fullIntraRequests
            negativeAcknowledgements += other.negativeAcknowledgements
            transportFeedback += other.transportFeedback
            if let estimate = other.bitrateEstimate { bitrateEstimate = estimate }
            unnamed.formUnion(other.unnamed)
            reportedSources.formUnion(other.reportedSources)
            fractionLost.merge(other.fractionLost) { max($0, $1) }
            senderReportTimes.merge(other.senderReportTimes) { $1 }
        }

        /// One line, or an empty string when nothing came back.
        ///
        /// **Silence is itself a reading and is printed as one.** A session
        /// sending media to a server that is receiving it always gets reports;
        /// no reports at all means the packets are not arriving, which is a
        /// different fault from every fault above this line.
        public var description: String {
            guard packets > 0 else { return "" }
            var line = " rtcp=\(packets)"
            if senderReports > 0 { line += " sr=\(senderReports)" }
            if receiverReports > 0 {
                line += " rr=\(receiverReports)"
                if !reportedSources.isEmpty {
                    line += " about=[" + reportedSources.sorted()
                        .map(String.init).joined(separator: " ") + "]"
                }
                // Out of 256, printed as the per-cent a reader thinks in.
                line += " lost=\(Int(worstFractionLost) * 100 / 256)%"
                if cumulativeLost != 0 { line += "/\(cumulativeLost)" }
                if worstJitter > 0 { line += " jitter=\(worstJitter)" }
            }
            if pictureLossIndications > 0 { line += " PLI=\(pictureLossIndications)" }
            if fullIntraRequests > 0 { line += " FIR=\(fullIntraRequests)" }
            if negativeAcknowledgements > 0 { line += " nack=\(negativeAcknowledgements)" }
            if transportFeedback > 0 { line += " twcc=\(transportFeedback)" }
            if let bitrateEstimate { line += " remb=\(bitrateEstimate / 1_000)kbit" }
            if !unnamed.isEmpty {
                line += " other=[" + unnamed.sorted().map(String.init).joined(separator: " ") + "]"
            }
            return line
        }
    }

    /// Whether this datagram is RTCP.
    ///
    /// Version two, and a payload type in the reserved range. Length is checked
    /// by `isPlaintext` rather than here: an encrypted report keeps its header
    /// in the clear, so the shape is all this can tell.
    public static func isRTCP(_ packet: [UInt8]) -> Bool {
        packet.count >= 4 && packet[0] >> 6 == 2 && payloadTypes.contains(packet[1])
    }

    /// Whether the records inside tile the datagram exactly.
    ///
    /// **This is what separates a report from an encrypted report.** Both carry
    /// the same eight clear bytes at the front — the header has to stay
    /// readable for the packet to be routed at all — so the header alone cannot
    /// say which it is. What differs is the length: a plaintext compound packet
    /// ends where its last record ends, and a sealed one is twenty bytes longer
    /// than it claims, being a tag and a counter past it. Reading the second as
    /// the first yields whatever the ciphertext happens to look like.
    public static func isPlaintext(_ packet: [UInt8]) -> Bool {
        var offset = 0
        while offset + 4 <= packet.count {
            guard packet[offset] >> 6 == 2, payloadTypes.contains(packet[offset + 1])
            else { return false }
            let words = Int(packet[offset + 2]) << 8 | Int(packet[offset + 3])
            offset += (words + 1) * 4
        }
        return offset == packet.count
    }

    /// What a receiver asked one of our streams for. Handed over the moment it
    /// is read, because both are answered on the next frame or not in time.
    public enum Request: Sendable, Equatable {
        /// These packets never arrived; resend them.
        case retransmit(ssrc: UInt32, sequences: [UInt16])
        /// A receiver that has our packets and cannot start from them.
        case keyframe(ssrc: UInt32)
    }

    /// Reads one compound packet, accumulating what it says and dropping what
    /// it asks for.
    public static func read(_ packet: [UInt8], into feedback: inout Feedback) {
        read(packet, into: &feedback) { _ in }
    }

    /// Reads one compound packet — several records back to back, each with its
    /// own length — accumulating what it says and handing each request to
    /// `requests` as it is read.
    ///
    /// Forgiving by design. A record this client does not understand is skipped
    /// by its own length field, which is what makes the format extensible; a
    /// length that runs past the end stops the walk rather than failing the
    /// packet, because the records before it were still true.
    public static func read(
        _ packet: [UInt8], into feedback: inout Feedback, requests: (Request) -> Void
    ) {
        guard isRTCP(packet) else { return }
        feedback.packets += 1

        var offset = 0
        while offset + 4 <= packet.count {
            guard packet[offset] >> 6 == 2 else { return }
            let count = Int(packet[offset] & 0x1F)
            let kind = packet[offset + 1]
            // The length field counts 32-bit words **after** the first one, so
            // the record is four bytes longer than it says.
            let words = Int(packet[offset + 2]) << 8 | Int(packet[offset + 3])
            let end = offset + (words + 1) * 4
            guard end <= packet.count else { return }
            defer { offset = end }

            switch Kind(rawValue: kind) {
            case .senderReport:
                feedback.senderReports += 1
                if offset + 16 <= end {
                    // The NTP time is the eight bytes after the sender's SSRC;
                    // LSR is its middle thirty-two bits.
                    feedback.senderReportTimes[word(packet, at: offset + 4)] =
                        UInt32(packet[offset + 10]) << 24 | UInt32(packet[offset + 11]) << 16
                        | UInt32(packet[offset + 12]) << 8 | UInt32(packet[offset + 13])
                }
                // Header, sender SSRC, then twenty bytes of sender info before
                // the report blocks begin.
                readReportBlocks(packet, from: offset + 28, count: count, end: end, into: &feedback)

            case .receiverReport:
                feedback.receiverReports += 1
                readReportBlocks(packet, from: offset + 8, count: count, end: end, into: &feedback)

            case .transportFeedback:
                // `count` is the feedback message type: 1 is a generic NACK,
                // whose every FCI word names a lost packet and a bitmask of the
                // sixteen behind it — bit `i` is packet `PID + i + 1` — and 15
                // is transport-wide congestion control.
                if count == 15 { feedback.transportFeedback += 1 }
                guard count == 1, offset + 12 <= end else { break }
                var lost: [UInt16] = []
                var fci = offset + 12
                while fci + 4 <= end {
                    let first = UInt16(packet[fci]) << 8 | UInt16(packet[fci + 1])
                    let mask = UInt16(packet[fci + 2]) << 8 | UInt16(packet[fci + 3])
                    lost.append(first)
                    for bit in 0..<16 where mask & (1 << bit) != 0 {
                        lost.append(first &+ UInt16(bit) &+ 1)
                    }
                    fci += 4
                }
                feedback.negativeAcknowledgements += lost.count
                if !lost.isEmpty {
                    requests(.retransmit(ssrc: word(packet, at: offset + 8), sequences: lost))
                }

            case .payloadFeedback:
                switch count {
                case 1:
                    // The stream is the record's media source.
                    feedback.pictureLossIndications += 1
                    if offset + 12 <= end { requests(.keyframe(ssrc: word(packet, at: offset + 8))) }
                case 4:
                    // A full intra request names its streams in its entries
                    // instead: eight bytes each, the SSRC and a sequence number.
                    feedback.fullIntraRequests += 1
                    var entry = offset + 12
                    while entry + 8 <= end {
                        requests(.keyframe(ssrc: word(packet, at: entry)))
                        entry += 8
                    }
                case 15: readBitrateEstimate(packet, from: offset + 12, end: end, into: &feedback)
                default: break
                }

            case .sourceDescription, .goodbye, .application, .extendedReport:
                break

            case nil:
                feedback.unnamed.insert(kind)
            }
        }
    }

    /// A picture loss indication — RFC 4585 §6.3.1.
    ///
    /// **This is how a receiver that cannot decode says so, and it is the only
    /// way.** A viewer who subscribes halfway through a stream has no parameter
    /// sets and no reference frame; nothing the sender emits until its next
    /// keyframe means anything, and that is seconds away on an encoder's own
    /// cadence and never at all on one that only produces them on request.
    ///
    /// Twelve bytes: the common feedback header, our SSRC, and the SSRC of the
    /// stream we cannot decode. There is no feedback control information — the
    /// message is the whole request.
    public static func pictureLossIndication(from sender: UInt32, about media: UInt32) -> [UInt8] {
        var packet: [UInt8] = [
            2 << 6 | 1,                                     // version 2, feedback type 1
            Kind.payloadFeedback.rawValue,
            0, 2,                                           // two words after the first
        ]
        for value in [sender, media] { appendWord(value, to: &packet) }
        return packet
    }

    /// A generic NACK — RFC 4585 §6.2.1 — for packets of `media` that never
    /// arrived, from `sender`.
    ///
    /// Each entry names one lost packet and a bitmask of the sixteen after it,
    /// so a run of losses costs one word rather than one each. `sequences` are
    /// taken in the order given, which for a receive buffer is ascending in
    /// sequence space.
    public static func negativeAcknowledgement(
        from sender: UInt32, about media: UInt32, sequences: [UInt16]
    ) -> [UInt8] {
        var entries: [(first: UInt16, mask: UInt16)] = []
        var index = sequences.startIndex
        while index < sequences.endIndex {
            let first = sequences[index]
            var mask: UInt16 = 0
            index += 1
            while index < sequences.endIndex {
                let distance = sequences[index] &- first
                guard (1...16).contains(distance) else { break }
                mask |= 1 << (distance - 1)
                index += 1
            }
            entries.append((first, mask))
        }
        let words = 2 + entries.count
        var packet: [UInt8] = [
            2 << 6 | 1,                                     // version 2, generic NACK
            Kind.transportFeedback.rawValue,
            UInt8(truncatingIfNeeded: words >> 8), UInt8(truncatingIfNeeded: words),
        ]
        for value in [sender, media] { appendWord(value, to: &packet) }
        for entry in entries {
            appendWord(UInt32(entry.first) << 16 | UInt32(entry.mask), to: &packet)
        }
        return packet
    }

    /// One received stream, as a report block describes it — RFC 3550 §6.4.1.
    public struct ReportBlock: Sendable, Equatable {
        public var ssrc: UInt32
        /// Lost since the last report, out of 256.
        public var fractionLost: UInt8
        /// Lost in all, which duplicates can make negative. Twenty-four bits.
        public var cumulativeLost: Int32
        /// The highest sequence number received, with its wraps in the high
        /// sixteen bits.
        public var highestSequence: UInt32
        /// In the stream's own clock units.
        public var jitter: UInt32
        /// LSR: the middle 32 bits of the last sender report's NTP time.
        public var lastSenderReport: UInt32
        /// DLSR: how long ago it arrived, in units of 1/65536 s.
        public var delaySinceLastSenderReport: UInt32
    }

    /// What a sender report says about the stream that sends it.
    public struct SenderInfo: Sendable, Equatable {
        /// Seconds since 1900 in the high thirty-two bits, the fraction below.
        public var ntpTime: UInt64
        /// The same instant on the stream's own RTP clock.
        public var rtpTimestamp: UInt32
        public var packets: UInt32
        public var octets: UInt32
    }

    /// A sender report — or, with no sender information, a receiver report —
    /// from `ssrc`, carrying a block for each stream received (at most
    /// thirty-one, the five bits the count has).
    public static func report(
        from ssrc: UInt32, sender: SenderInfo?, blocks: [ReportBlock]
    ) -> [UInt8] {
        let blocks = blocks.prefix(31)
        let words = 1 + (sender == nil ? 0 : 5) + 6 * blocks.count
        var packet: [UInt8] = [
            2 << 6 | UInt8(blocks.count),
            (sender == nil ? Kind.receiverReport : Kind.senderReport).rawValue,
            UInt8(truncatingIfNeeded: words >> 8), UInt8(truncatingIfNeeded: words),
        ]
        appendWord(ssrc, to: &packet)
        if let sender {
            appendWord(UInt32(truncatingIfNeeded: sender.ntpTime >> 32), to: &packet)
            appendWord(UInt32(truncatingIfNeeded: sender.ntpTime), to: &packet)
            appendWord(sender.rtpTimestamp, to: &packet)
            appendWord(sender.packets, to: &packet)
            appendWord(sender.octets, to: &packet)
        }
        for block in blocks {
            appendWord(block.ssrc, to: &packet)
            appendWord(
                UInt32(block.fractionLost) << 24
                    | UInt32(bitPattern: block.cumulativeLost) & 0x00FF_FFFF,
                to: &packet
            )
            appendWord(block.highestSequence, to: &packet)
            appendWord(block.jitter, to: &packet)
            appendWord(block.lastSenderReport, to: &packet)
            appendWord(block.delaySinceLastSenderReport, to: &packet)
        }
        return packet
    }

    /// Now, as NTP counts it: seconds since 1900, and a binary fraction.
    public static func ntpTime(_ date: Date = Date()) -> UInt64 {
        let seconds = date.timeIntervalSince1970 + 2_208_988_800
        let whole = UInt64(seconds)
        let fraction = UInt64((seconds - Double(whole)) * 4_294_967_296)
        return whole << 32 | fraction
    }

    private static func word(_ packet: [UInt8], at offset: Int) -> UInt32 {
        UInt32(packet[offset]) << 24 | UInt32(packet[offset + 1]) << 16
            | UInt32(packet[offset + 2]) << 8 | UInt32(packet[offset + 3])
    }

    private static func appendWord(_ value: UInt32, to packet: inout [UInt8]) {
        packet.append(UInt8(truncatingIfNeeded: value >> 24))
        packet.append(UInt8(truncatingIfNeeded: value >> 16))
        packet.append(UInt8(truncatingIfNeeded: value >> 8))
        packet.append(UInt8(truncatingIfNeeded: value))
    }

    /// The twenty-four byte blocks a sender or receiver report carries, one per
    /// stream the reporter is receiving from us.
    private static func readReportBlocks(
        _ packet: [UInt8], from start: Int, count: Int, end: Int, into feedback: inout Feedback
    ) {
        var offset = start
        for _ in 0..<count {
            guard offset + 24 <= end else { return }
            let source = word(packet, at: offset)
            feedback.reportedSources.insert(source)
            feedback.worstFractionLost = max(feedback.worstFractionLost, packet[offset + 4])
            feedback.fractionLost[source] = max(feedback.fractionLost[source] ?? 0, packet[offset + 4])
            // Twenty-four bits, two's complement: a receiver that got more
            // packets than were sent — duplicates — reports a negative.
            let raw = Int32(packet[offset + 5]) << 16
                | Int32(packet[offset + 6]) << 8
                | Int32(packet[offset + 7])
            let lost = raw & 0x0080_0000 != 0 ? raw - 0x0100_0000 : raw
            if abs(lost) > abs(feedback.cumulativeLost) { feedback.cumulativeLost = lost }
            let jitter = UInt32(packet[offset + 12]) << 24 | UInt32(packet[offset + 13]) << 16
                | UInt32(packet[offset + 14]) << 8 | UInt32(packet[offset + 15])
            feedback.worstJitter = max(feedback.worstJitter, jitter)
            offset += 24
        }
    }

    /// REMB, which rides on the application-defined payload feedback type and
    /// identifies itself by four ASCII bytes.
    ///
    /// The rate is an eighteen-bit mantissa scaled by a six-bit power of two,
    /// which is how a single word covers everything from a few kilobits to
    /// several gigabits.
    private static func readBitrateEstimate(
        _ packet: [UInt8], from start: Int, end: Int, into feedback: inout Feedback
    ) {
        guard start + 8 <= end else { return }
        guard packet[start] == 0x52, packet[start + 1] == 0x45,
              packet[start + 2] == 0x4D, packet[start + 3] == 0x42
        else { return }
        let exponent = UInt32(packet[start + 5] >> 2)
        let mantissa = UInt32(packet[start + 5] & 0x03) << 16
            | UInt32(packet[start + 6]) << 8
            | UInt32(packet[start + 7])
        guard exponent < 40 else { return }
        feedback.bitrateEstimate = Int(mantissa) << Int(exponent)
    }
}

// MARK: - The socket's end of it

/// Accumulates what the far end says, from whichever queue the socket runs on.
///
/// A reference type holding the mutex: `Mutex` is non-copyable, so a
/// `@Sendable` closure cannot capture one out of an enclosing type without
/// consuming it.
final class RTCPListener: Sendable {
    private let state = Mutex(State())

    private struct State {
        var feedback = RTCP.Feedback()
        /// Datagrams that were neither RTCP in the clear nor RTCP once opened.
        var unreadable = 0
        /// Which shape the reports arrive in, once one has. Once a session:
        /// it is a fact about the server, not an event.
        var shape: Shape?
        /// When a keyframe was last asked for. Rate limited: a receiver that
        /// asks on every tick while the answer is in flight makes a congested
        /// path carry keyframes nobody needed.
        var lastAsk: ContinuousClock.Instant?
        /// The last sender report about each stream, and when it arrived — what
        /// our receiver reports echo back so the far end can time the round
        /// trip.
        var senderReports: [UInt32: (ntp: UInt32, arrival: TimeInterval)] = [:]

        /// One packet's worth of what the far end said, folded in.
        mutating func absorb(_ feedback: RTCP.Feedback, at arrival: TimeInterval) {
            self.feedback.merge(feedback)
            for (ssrc, ntp) in feedback.senderReportTimes {
                senderReports[ssrc] = (ntp, arrival)
            }
        }
    }

    /// Set once the session is keyed, when the server's reports stop being
    /// readable in the clear.
    private let sealer = Mutex<VoiceSealer?>(nil)

    /// Where a request about one of our own streams goes, on the socket's
    /// queue. Fixed for the listener's life — §1.5, a handler a real-time
    /// thread reads is never swapped under it.
    private let requests: @Sendable (RTCP.Request) -> Void

    init(requests: @escaping @Sendable (RTCP.Request) -> Void) {
        self.requests = requests
    }

    func setSealer(_ value: VoiceSealer?) { sealer.withLock { $0 = value } }

    /// Called on the socket's own queue, once per datagram.
    func accept(_ packet: [UInt8]) {
        // Collected under the lock and answered after it: an answer is a
        // retransmission or a keyframe, and neither may wait on this lock.
        var asked: [RTCP.Request] = []
        defer { asked.forEach(requests) }
        guard RTCP.isRTCP(packet) else {
            state.withLock { $0.unreadable += 1 }
            return
        }
        let arrival = CACurrentMediaTime()
        if RTCP.isPlaintext(packet) {
            asked = state.withLock { state in
                announce(&state, .clear)
                var feedback = RTCP.Feedback()
                var asked: [RTCP.Request] = []
                RTCP.read(packet, into: &feedback) { asked.append($0) }
                state.absorb(feedback, at: arrival)
                return asked
            }
            return
        }
        // Sealed, then: the header is in the clear because the packet has to be
        // routed, and the reports behind it are not — so the same eight bytes
        // that identify it are the associated data that opens it.
        let opened = sealer.withLock { $0 }?
            .open(packet, headerLength: RTCP.clearPrefixLength)
        asked = state.withLock { state in
            guard let opened, case let rebuilt = Self.rejoin(packet, body: opened),
                  RTCP.isPlaintext(rebuilt)
            else {
                state.unreadable += 1
                return []
            }
            announce(&state, .sealed)
            var feedback = RTCP.Feedback()
            var asked: [RTCP.Request] = []
            RTCP.read(rebuilt, into: &feedback) { asked.append($0) }
            state.absorb(feedback, at: arrival)
            return asked
        }
    }

    /// Which shape the server's own reports arrive in, once one has.
    ///
    /// **Read off the wire rather than chosen.** Whether this server encrypts
    /// its control traffic is a fact about the server, and a client that guesses
    /// sends reports nobody can read — so anything this client sends back is
    /// shaped like what it has already been sent, and nothing is sent until
    /// something has been.
    enum Shape: Sendable { case clear, sealed }

    /// Says once, per session, which of the two shapes the server actually
    /// sends — so the next reader does not have to re-derive it.
    private func announce(_ state: inout State, _ shape: Shape) {
        guard state.shape == nil else { return }
        state.shape = shape
        VoiceTrace.write("rtcp readable, \(shape == .clear ? "clear" : "sealed")")
    }

    /// Puts the clear header back in front of the decrypted body, so the reader
    /// sees the record exactly as it was written.
    ///
    /// `open` only returns a body for a packet long enough to have had one, so
    /// the prefix is always there by the time this runs.
    private static func rejoin(_ packet: [UInt8], body: [UInt8]) -> [UInt8] {
        Array(packet.prefix(RTCP.clearPrefixLength)) + body
    }

    /// Sends one picture loss indication per stream that cannot start, at most
    /// once a second however often this is called.
    func askForKeyframes(on transport: VoiceTransport, from sender: UInt32, about streams: [UInt32]) {
        guard !streams.isEmpty else { return }
        let shape = state.withLock { state -> Shape? in
            guard let shape = state.shape else { return nil }
            let now = ContinuousClock.now
            if let last = state.lastAsk, now - last < .seconds(1) { return nil }
            state.lastAsk = now
            return shape
        }
        guard let shape else { return }
        for ssrc in streams {
            send(RTCP.pictureLossIndication(from: sender, about: ssrc), shape: shape, on: transport)
        }
        VoiceTrace.write("rtcp asked for a keyframe on \(streams.count) stream(s)")
    }

    /// Asks for packets of one stream that never arrived — a generic NACK.
    ///
    /// Not rate limited here: the receive buffer decides when a hole is asked
    /// about again, and how many times.
    func askForRetransmission(
        on transport: VoiceTransport, from sender: UInt32, about media: UInt32, sequences: [UInt16]
    ) {
        guard !sequences.isEmpty, let shape = state.withLock({ $0.shape }) else { return }
        send(
            RTCP.negativeAcknowledgement(from: sender, about: media, sequences: sequences),
            shape: shape, on: transport
        )
    }

    /// LSR and DLSR for a stream: the last sender report about it, and how
    /// long ago that arrived in 1/65536 s — or zeros with none.
    func lastSenderReport(about ssrc: UInt32, at now: TimeInterval)
        -> (lastSenderReport: UInt32, delay: UInt32)
    {
        guard let report = state.withLock({ $0.senderReports[ssrc] }) else { return (0, 0) }
        return (report.ntp, UInt32(min(Double(UInt32.max), max(0, now - report.arrival) * 65_536)))
    }

    /// Sends one of our periodic reports.
    ///
    /// **The one thing sent before anything has come in**, because it is also
    /// what keeps the NAT mapping open on a call where nobody is talking and
    /// nothing else leaves. Until the server's own reports have shown their
    /// shape it is sealed, which is the shape they were measured in.
    func sendReport(_ report: [UInt8], on transport: VoiceTransport) {
        send(report, shape: state.withLock({ $0.shape }) ?? .sealed, on: transport)
    }

    /// **Shaped like what the server sends us.** See `Shape`: a request goes out
    /// only in the shape the server's own reports arrived in, so this client
    /// never invents a control format for a server that uses another one.
    private func send(_ request: [UInt8], shape: Shape, on transport: VoiceTransport) {
        switch shape {
        case .clear:
            transport.send(Data(request))
        case .sealed:
            // The same split the server uses on the way in: eight bytes of
            // header in the clear and authenticated, the rest sealed.
            guard let sealer = sealer.withLock({ $0 }), let packet = try? request
                .suffix(from: RTCP.clearPrefixLength)
                .withUnsafeBytes({ body in
                    try sealer.seal(
                        payload: body,
                        header: RTPHeaderBytes(clear: Array(request.prefix(RTCP.clearPrefixLength)))
                    )
                })
            else { return }
            transport.send(packet)
        }
    }

    /// What came back since the last call, and the last call resets it.
    func drain() -> (feedback: RTCP.Feedback, unreadable: Int) {
        state.withLock { state in
            let value = (state.feedback, state.unreadable)
            state.feedback = RTCP.Feedback()
            state.unreadable = 0
            return value
        }
    }
}
