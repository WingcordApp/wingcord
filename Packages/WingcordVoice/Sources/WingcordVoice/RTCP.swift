import Foundation
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
            if let estimate = other.bitrateEstimate { bitrateEstimate = estimate }
            unnamed.formUnion(other.unnamed)
            reportedSources.formUnion(other.reportedSources)
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

    /// Reads one compound packet — several records back to back, each with its
    /// own length — accumulating what it says.
    ///
    /// Forgiving by design. A record this client does not understand is skipped
    /// by its own length field, which is what makes the format extensible; a
    /// length that runs past the end stops the walk rather than failing the
    /// packet, because the records before it were still true.
    public static func read(_ packet: [UInt8], into feedback: inout Feedback) {
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
                // Header, sender SSRC, then twenty bytes of sender info before
                // the report blocks begin.
                readReportBlocks(packet, from: offset + 28, count: count, end: end, into: &feedback)

            case .receiverReport:
                feedback.receiverReports += 1
                readReportBlocks(packet, from: offset + 8, count: count, end: end, into: &feedback)

            case .transportFeedback:
                // `count` is the feedback message type: 1 is a generic NACK,
                // whose every FCI word names a lost packet and a bitmask of
                // sixteen more behind it.
                guard count == 1 else { break }
                var fci = offset + 12
                while fci + 4 <= end {
                    let mask = UInt16(packet[fci + 2]) << 8 | UInt16(packet[fci + 3])
                    feedback.negativeAcknowledgements += 1 + mask.nonzeroBitCount
                    fci += 4
                }

            case .payloadFeedback:
                switch count {
                case 1: feedback.pictureLossIndications += 1
                case 4: feedback.fullIntraRequests += 1
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
            0, 2,                                           // three words after the first
        ]
        for value in [sender, media] {
            packet.append(UInt8(truncatingIfNeeded: value >> 24))
            packet.append(UInt8(truncatingIfNeeded: value >> 16))
            packet.append(UInt8(truncatingIfNeeded: value >> 8))
            packet.append(UInt8(truncatingIfNeeded: value))
        }
        return packet
    }

    /// The twenty-four byte blocks a sender or receiver report carries, one per
    /// stream the reporter is receiving from us.
    private static func readReportBlocks(
        _ packet: [UInt8], from start: Int, count: Int, end: Int, into feedback: inout Feedback
    ) {
        var offset = start
        for _ in 0..<count {
            guard offset + 24 <= end else { return }
            feedback.reportedSources.insert(
                UInt32(packet[offset]) << 24 | UInt32(packet[offset + 1]) << 16
                    | UInt32(packet[offset + 2]) << 8 | UInt32(packet[offset + 3])
            )
            feedback.worstFractionLost = max(feedback.worstFractionLost, packet[offset + 4])
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
/// A reference type holding the mutex, for the reason `StreamPreview` is one:
/// `Mutex` is non-copyable, so a `@Sendable` closure cannot capture one out of
/// an enclosing type without consuming it.
final class RTCPListener: Sendable {
    private let state = Mutex(State())

    private struct State {
        var feedback = RTCP.Feedback()
        var datagrams = 0
        /// Datagrams that were neither RTCP in the clear nor RTCP once opened.
        var unreadable = 0
        /// How many unreadable datagrams are still to be printed as themselves.
        ///
        /// **Printed, because the alternative is a theory.** Whether the server
        /// encrypts its reports, and under which header length, is a fact about
        /// the wire that nothing in the documentation settles — and a client
        /// that guesses wrong counts every reply as noise and concludes the
        /// server is silent.
        var probesRemaining = VoiceTrace.isOn ? 3 : 0
        /// Which shape the reports arrive in, once one has. Once a session:
        /// it is a fact about the server, not an event.
        var shape: Shape?
        /// When a keyframe was last asked for. Rate limited: a receiver that
        /// asks on every tick while the answer is in flight makes a congested
        /// path carry keyframes nobody needed.
        var lastAsk: ContinuousClock.Instant?
    }

    /// Set once the session is keyed, when the server's reports stop being
    /// readable in the clear.
    private let sealer = Mutex<VoiceSealer?>(nil)

    func setSealer(_ value: VoiceSealer?) { sealer.withLock { $0 = value } }

    /// Called on the socket's own queue, once per datagram.
    func accept(_ packet: [UInt8]) {
        guard RTCP.isRTCP(packet) else {
            state.withLock { state in
                state.datagrams += 1
                state.unreadable += 1
                probe(&state, packet, "not rtcp")
            }
            return
        }
        if RTCP.isPlaintext(packet) {
            state.withLock { state in
                state.datagrams += 1
                announce(&state, .clear)
                RTCP.read(packet, into: &state.feedback)
            }
            return
        }
        // Sealed, then: the header is in the clear because the packet has to be
        // routed, and the reports behind it are not — so the same eight bytes
        // that identify it are the associated data that opens it.
        let opened = sealer.withLock { $0 }?
            .open(packet, headerLength: RTCP.clearPrefixLength)
        state.withLock { state in
            state.datagrams += 1
            guard let opened, case let rebuilt = Self.rejoin(packet, body: opened),
                  RTCP.isPlaintext(rebuilt)
            else {
                state.unreadable += 1
                probe(
                    &state, packet,
                    opened == nil ? "would not open" : "opened=\(opened?.count ?? 0)B, not rtcp"
                )
                return
            }
            announce(&state, .sealed)
            RTCP.read(rebuilt, into: &state.feedback)
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

    var shape: Shape? { state.withLock { $0.shape } }

    /// Says once, per session, which of the two shapes the server actually
    /// sends — so the next reader does not have to re-derive it.
    private func announce(_ state: inout State, _ shape: Shape) {
        guard state.shape == nil else { return }
        state.shape = shape
        VoiceTrace.write("rtcp readable, \(shape == .clear ? "clear" : "sealed")")
    }

    private func probe(_ state: inout State, _ packet: [UInt8], _ reason: String) {
        guard state.probesRemaining > 0 else { return }
        state.probesRemaining -= 1
        VoiceTrace.write(
            "rtcp unreadable \(packet.count)B (\(reason)) head="
            + Self.hex(packet.prefix(16))
        )
    }

    /// Puts the clear header back in front of the decrypted body, so the reader
    /// sees the record exactly as it was written.
    ///
    /// `open` only returns a body for a packet long enough to have had one, so
    /// the prefix is always there by the time this runs.
    private static func rejoin(_ packet: [UInt8], body: [UInt8]) -> [UInt8] {
        Array(packet.prefix(RTCP.clearPrefixLength)) + body
    }

    private static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Sends one picture loss indication per stream that cannot start, at most
    /// once a second however often this is called.
    ///
    /// **Shaped like what the server sends us.** See `Shape`: nothing goes out
    /// before something has come in, so this client never invents a control
    /// format for a server that uses another one.
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

        let sealer = self.sealer.withLock { $0 }
        for ssrc in streams {
            let request = RTCP.pictureLossIndication(from: sender, about: ssrc)
            switch shape {
            case .clear:
                transport.send(Data(request))
            case .sealed:
                // The same split the server uses on the way in: eight bytes of
                // header in the clear and authenticated, the rest sealed.
                guard let sealer, let packet = try? request
                    .suffix(from: RTCP.clearPrefixLength)
                    .withUnsafeBytes({ body in
                        try sealer.seal(
                            payload: body,
                            header: RTPHeaderBytes(
                                clear: Array(request.prefix(RTCP.clearPrefixLength))
                            )
                        )
                    })
                else { continue }
                transport.send(packet)
            }
        }
        VoiceTrace.write("rtcp asked for a keyframe on \(streams.count) stream(s)")
    }

    /// What came back since the last call, and the last call resets it.
    func drain() -> (feedback: RTCP.Feedback, datagrams: Int, unreadable: Int) {
        state.withLock { state in
            let value = (state.feedback, state.datagrams, state.unreadable)
            state.feedback = RTCP.Feedback()
            state.unreadable = 0
            return value
        }
    }

    /// Every datagram the socket has handed over, for the line that only wants
    /// to know whether the server is saying anything at all.
    var datagrams: Int { state.withLock { $0.datagrams } }
}
