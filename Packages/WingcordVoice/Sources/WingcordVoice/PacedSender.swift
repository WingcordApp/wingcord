import Foundation
import QuartzCore
import Synchronization

// MARK: - A frame spread across time, and what was lost sent again
//
// **An encoder hands over a frame at once and a network does not take it at
// once.** A keyframe is fifty packets; written to the socket in one burst they
// arrive at the first congested hop together, and a drop-tail queue keeps the
// first few and discards the rest — which for a keyframe is the whole frame.
// WebRTC paces every video packet at two and a half times the target bitrate,
// and so does this.
//
// Two things follow from sending a packet later than it was made, and both are
// why the pacer owns sealing rather than taking sealed packets:
//
// - **The send time and the transport-wide sequence are facts about leaving.**
//   Both are extension elements, which Discord encrypts, so they have to be
//   written before the seal; written at packetisation they would describe the
//   burst to the far end's estimator exactly as though it had happened.
// - **A retransmission is a new packet carrying an old one.** RFC 4588: its own
//   SSRC and sequence, the original's timestamp and marker, and the original
//   sequence number ahead of the original payload. The history it is rebuilt
//   from is what this type kept as each packet left.
//
// Audio is never paced. Twenty milliseconds of Opus is one small packet, and
// holding it behind a keyframe is latency nobody can hear the reason for.

final class PacedSender: Sendable {

    struct Configuration: Sendable {
        var sealer: VoiceSealer
        var transport: VoiceTransport
        var ssrc: UInt32
        /// RFC 4588's stream: retransmissions travel on their own SSRC, the one
        /// after the video's, under the RTX payload type offered at select.
        var retransmissionSSRC: UInt32
        var sendTimeExtensionID: UInt8?
        var transportSequenceExtensionID: UInt8?
        /// Shared with the audio path: the number is transport-wide.
        var transportSequence: TransportSequence?
    }

    /// A video packet whose place in its stream is decided and which has not
    /// left yet — or which has, and is kept in case it has to again.
    struct Packet: Sendable {
        var sequence: UInt16
        var timestamp: UInt32
        var marker: Bool
        var payload: [UInt8]
    }

    /// What has gone out since the last drain.
    struct Report: Sendable {
        /// The running total, as the media line prints it.
        var packets = 0
        var bytes = 0
        var retransmitted = 0
        /// Every byte of media payload sent, for the sender report's octet
        /// count. Running, like `packets`.
        var octets = 0
    }

    /// WebRTC's pacing factor: the queue drains at two and a half times the
    /// rate the encoder is aiming for, so a frame is spread out without a
    /// steady stream ever waiting.
    static let pacingFactor = 2.5
    /// How much may leave in one go after a quiet spell. Five milliseconds of
    /// the pacing rate, and never less than one packet.
    private static let burst: Double = 0.005
    /// The longest anything may wait. A backlog that would take longer than
    /// this at the pacing rate is sent faster: a frame a quarter of a second
    /// late is worth more than the same frame half a second late.
    private static let maximumQueueTime: Double = 0.25
    /// Packets kept for retransmission — about four seconds of a 720p camera,
    /// and far longer than a request for one can usefully arrive.
    private static let historySize = 1_024
    /// How soon one packet may be resent again. A receiver that asks twice
    /// within a round trip is asking about the same loss.
    private static let resendInterval: Double = 0.05

    private let queue = DispatchQueue(label: "dev.wingcord.voice.pacer", qos: .userInteractive)
    private let state: Mutex<State>

    private struct State {
        var configuration: Configuration?
        var media: [Packet] = []
        var mediaHead = 0
        var retransmissions: [Packet] = []
        var queuedBytes = 0
        /// Bytes per second.
        var rate: Double
        var budget: Double = 0
        var lastDrain: CFTimeInterval = 0
        var isScheduled = false
        var history: [Packet?]
        var resentAt: [CFTimeInterval]
        var retransmissionSequence = UInt16.random(in: 0...UInt16.max)
        var report = Report()

        /// Whether the caller is the one to start a drain. Exactly one is ever
        /// scheduled; the drain itself reschedules while anything is left.
        mutating func claimSchedule() -> Bool {
            guard !isScheduled else { return false }
            isScheduled = true
            return true
        }
    }

    init(bitrate: Int) {
        state = Mutex(State(
            rate: Double(bitrate) * Self.pacingFactor / 8,
            history: Array(repeating: nil, count: Self.historySize),
            resentAt: Array(repeating: 0, count: Self.historySize)
        ))
    }

    func configure(_ configuration: Configuration) {
        state.withLock { $0.configuration = configuration }
    }

    /// Forgets the socket, the queue and the history. Nothing queued leaves.
    func teardown() {
        state.withLock { state in
            state.configuration = nil
            state.media.removeAll()
            state.mediaHead = 0
            state.retransmissions.removeAll()
            state.queuedBytes = 0
            for index in state.history.indices { state.history[index] = nil }
        }
    }

    /// The rate the encoder is aiming for, which the queue drains at a
    /// multiple of.
    func setBitrate(_ bitrate: Int) {
        state.withLock { $0.rate = Double(bitrate) * Self.pacingFactor / 8 }
    }

    /// The running totals, without closing the window.
    func peekReport() -> Report {
        state.withLock { $0.report }
    }

    func drainReport() -> Report {
        state.withLock { state in
            let report = state.report
            state.report.bytes = 0
            state.report.retransmitted = 0
            return report
        }
    }

    /// One frame's packets, in order. From VideoToolbox's callback thread.
    func enqueue(_ packets: [Packet]) {
        guard !packets.isEmpty else { return }
        let start = state.withLock { state -> Bool in
            state.media.append(contentsOf: packets)
            state.queuedBytes += packets.reduce(0) { $0 + $1.payload.count }
            return state.claimSchedule()
        }
        if start { queue.async { [weak self] in self?.drain() } }
    }

    /// Sends again what a receiver says never arrived, ahead of anything new.
    ///
    /// From the socket's queue, the moment the request is read: a
    /// retransmission is only worth sending while the frame it belongs to can
    /// still be assembled, which is a few round trips at most.
    func retransmit(_ sequences: [UInt16]) {
        let now = CACurrentMediaTime()
        let start = state.withLock { state -> Bool in
            for sequence in sequences {
                let slot = Int(sequence) % Self.historySize
                guard let packet = state.history[slot], packet.sequence == sequence,
                      now - state.resentAt[slot] >= Self.resendInterval
                else { continue }
                state.resentAt[slot] = now
                state.retransmissions.append(packet)
                state.queuedBytes += packet.payload.count + 2
            }
            return !state.retransmissions.isEmpty && state.claimSchedule()
        }
        if start { queue.async { [weak self] in self?.drain() } }
    }

    /// Sends what the budget allows and comes back when it allows more.
    private func drain() {
        let now = CACurrentMediaTime()
        let (due, configuration, delay) = state.withLock {
            state -> ([(packet: Packet, isRetransmission: Bool)], Configuration?, Double?) in
            // A backlog that would take longer than the ceiling at the pacing
            // rate is drained at the rate that meets the ceiling instead.
            let rate = max(state.rate, Double(state.queuedBytes) / Self.maximumQueueTime)
            let elapsed = state.lastDrain == 0 ? Self.burst : now - state.lastDrain
            state.budget = min(state.budget + rate * elapsed, max(rate * Self.burst, 1_200))
            state.lastDrain = now

            var due: [(packet: Packet, isRetransmission: Bool)] = []
            while state.budget > 0 {
                let next: (packet: Packet, isRetransmission: Bool)
                if !state.retransmissions.isEmpty {
                    next = (state.retransmissions.removeFirst(), true)
                } else if state.mediaHead < state.media.count {
                    next = (state.media[state.mediaHead], false)
                    state.mediaHead += 1
                } else {
                    break
                }
                let size = next.packet.payload.count + (next.isRetransmission ? 2 : 0)
                state.budget -= Double(size)
                state.queuedBytes -= size
                due.append(next)
            }
            // The array is compacted rather than popped from the front, which
            // would move every packet behind the head on every send.
            if state.mediaHead == state.media.count {
                state.media.removeAll(keepingCapacity: true)
                state.mediaHead = 0
            } else if state.mediaHead > 256 {
                state.media.removeFirst(state.mediaHead)
                state.mediaHead = 0
            }

            let isEmpty = state.retransmissions.isEmpty && state.mediaHead == state.media.count
            if isEmpty {
                state.isScheduled = false
                return (due, state.configuration, nil)
            }
            // Back when the debt is paid, and never sooner than a millisecond:
            // finer than that is a timer firing for one packet at a time.
            return (due, state.configuration, max(0.001, -state.budget / rate))
        }

        if let configuration, !due.isEmpty { send(due, with: configuration) }
        if let delay {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.drain() }
        }
    }

    /// Seals and sends, and keeps what went out.
    private func send(
        _ due: [(packet: Packet, isRetransmission: Bool)], with configuration: Configuration
    ) {
        var sent: [Packet] = []
        var bytes = 0
        var octets = 0
        var retransmitted = 0
        for (packet, isRetransmission) in due {
            // **Both, on every packet, because that is what a stream the far
            // end draws carries.** These are the two measurements an SFU makes
            // of a publisher's path.
            var extensions: [UInt8] = []
            if let id = configuration.sendTimeExtensionID {
                extensions += RTPExtension.absoluteSendTime(id: id, seconds: AudioSendPath.sendClock())
            }
            if let id = configuration.transportSequenceExtensionID,
               let sequence = configuration.transportSequence?.next() {
                extensions += RTPExtension.transportSequence(id: id, sequence: sequence)
            }

            let datagram: Data?
            if isRetransmission {
                let sequence = state.withLock { state -> UInt16 in
                    defer { state.retransmissionSequence &+= 1 }
                    return state.retransmissionSequence
                }
                let header = RTPWriter.header(
                    ssrc: configuration.retransmissionSSRC,
                    payloadType: RTP.PayloadType.h264RTX,
                    sequence: sequence,
                    timestamp: packet.timestamp,
                    marker: packet.marker,
                    extensions: extensions
                )
                // RFC 4588 §4: the original sequence number, then the original
                // payload — here already end-to-end encrypted, exactly as it
                // first left.
                let payload = [
                    UInt8(truncatingIfNeeded: packet.sequence >> 8),
                    UInt8(truncatingIfNeeded: packet.sequence),
                ] + packet.payload
                datagram = try? payload.withUnsafeBytes {
                    try configuration.sealer.seal(payload: $0, header: header)
                }
                if datagram != nil { retransmitted += 1 }
            } else {
                let header = RTPWriter.header(
                    ssrc: configuration.ssrc,
                    payloadType: RTP.PayloadType.h264,
                    sequence: packet.sequence,
                    timestamp: packet.timestamp,
                    marker: packet.marker,
                    extensions: extensions
                )
                datagram = try? packet.payload.withUnsafeBytes {
                    try configuration.sealer.seal(payload: $0, header: header)
                }
                if datagram != nil {
                    sent.append(packet)
                    octets += packet.payload.count
                }
            }
            guard let datagram else { continue }
            configuration.transport.send(datagram)
            bytes += datagram.count
        }

        state.withLock { state in
            for packet in sent {
                state.history[Int(packet.sequence) % Self.historySize] = packet
            }
            state.report.packets += sent.count + retransmitted
            state.report.bytes += bytes
            state.report.octets += octets
            state.report.retransmitted += retransmitted
        }
    }
}
