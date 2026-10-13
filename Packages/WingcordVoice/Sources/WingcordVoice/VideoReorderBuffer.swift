import Foundation

// MARK: - One sender's video, back in order
//
// **A lost video packet used to cost everything until the sender's next
// keyframe.** The depacketiser reads a stream strictly in order, and a hole was
// the end of the frame it fell in — and, because every frame after it refers
// back, the end of the picture until a keyframe arrived. On a two-second
// cadence that is two seconds of a frozen tile per packet a Wi-Fi network
// dropped.
//
// So the packets go through this first. It hands them on in sequence order
// and holds everything behind a hole while it asks for the missing packet
// (RFC 4585's generic NACK), which comes back as a retransmission. If it does
// not come back in time, the hole is given up: what was held goes on, the
// packet after the hole is marked discontinuous, and the depacketiser does what
// it always did — drops the broken frame and asks for a keyframe.

struct VideoReorderBuffer: Sendable {
    struct Packet: Sendable, Equatable {
        var payload: [UInt8]
        var sequence: UInt16
        var marker: Bool
        var timestamp: UInt32
    }

    /// A packet handed on, and whether it follows the one handed on before it.
    struct Delivery: Sendable, Equatable {
        var packet: Packet
        var isContiguous: Bool
    }

    /// How long a hole may hold the stream up for its retransmission. A few
    /// round trips to a voice server; past it, the freeze a keyframe costs is
    /// shorter than the wait.
    static let patience: TimeInterval = 0.2
    /// How soon a missing packet is asked for again, and how many times in all.
    static let askInterval: TimeInterval = 0.05
    static let maximumAsks = 3
    /// The most packets held behind a hole before it is given up regardless —
    /// about two frames of a 720p keyframe.
    static let capacity = 256
    /// How far behind the stream a packet may be and still be a late one
    /// rather than a sender that started again.
    private static let restartDistance = 1_000

    private var next: UInt16?
    private var held: [UInt16: Packet] = [:]
    private var missing: [UInt16: Ask] = [:]

    private struct Ask: Sendable {
        var since: TimeInterval
        var lastAsked: TimeInterval?
        var count = 0
    }

    /// Takes one packet and returns what can now go on, in order.
    mutating func insert(_ packet: Packet, at now: TimeInterval) -> [Delivery] {
        guard let expected = next else {
            next = packet.sequence &+ 1
            return [Delivery(packet: packet, isContiguous: true)]
        }
        let distance = Int(Int16(bitPattern: packet.sequence &- expected))
        if distance < 0 {
            // Behind the stream: a duplicate, or a retransmission that came
            // after its hole was given up. Unless it is so far behind that the
            // sender must have started again, in which case it starts here.
            guard distance <= -Self.restartDistance else { return [] }
            return restart(with: packet)
        }
        if distance >= Self.capacity { return restart(with: packet) }

        var deliveries: [Delivery] = []
        missing[packet.sequence] = nil
        if distance == 0 {
            deliveries.append(Delivery(packet: packet, isContiguous: true))
            next = packet.sequence &+ 1
            drain(into: &deliveries, contiguous: true)
        } else {
            held[packet.sequence] = packet
            var sequence = expected
            while sequence != packet.sequence {
                if held[sequence] == nil, missing[sequence] == nil {
                    missing[sequence] = Ask(since: now)
                }
                sequence &+= 1
            }
        }
        giveUp(at: now, into: &deliveries)
        return deliveries
    }

    /// The missing packets to ask for now, in sequence order.
    mutating func asks(at now: TimeInterval) -> [UInt16] {
        guard let next, !missing.isEmpty else { return [] }
        var due: [UInt16] = []
        for (sequence, ask) in missing where ask.count < Self.maximumAsks {
            guard ask.lastAsked.map({ now - $0 >= Self.askInterval }) ?? true else { continue }
            missing[sequence]?.lastAsked = now
            missing[sequence]?.count += 1
            due.append(sequence)
        }
        return due.sorted { $0 &- next < $1 &- next }
    }

    mutating func reset() {
        next = nil
        held.removeAll()
        missing.removeAll()
    }

    /// Hands on every held packet that now follows.
    private mutating func drain(into deliveries: inout [Delivery], contiguous: Bool) {
        var isContiguous = contiguous
        while let expected = next, let packet = held.removeValue(forKey: expected) {
            deliveries.append(Delivery(packet: packet, isContiguous: isContiguous))
            isContiguous = true
            next = expected &+ 1
        }
    }

    /// Gives up the hole at the front of the stream once it has waited long
    /// enough, or once too much is waiting behind it — and then any hole that
    /// follows, by the same test.
    private mutating func giveUp(at now: TimeInterval, into deliveries: inout [Delivery]) {
        while let expected = next, !held.isEmpty, held[expected] == nil {
            let waited = missing[expected].map { now - $0.since } ?? .infinity
            guard waited >= Self.patience || held.count >= Self.capacity else { return }
            // The earliest packet held, in sequence order from the hole.
            guard let resume = held.keys.min(by: { $0 &- expected < $1 &- expected }) else { return }
            var sequence = expected
            while sequence != resume {
                missing[sequence] = nil
                sequence &+= 1
            }
            next = resume
            drain(into: &deliveries, contiguous: false)
        }
    }

    private mutating func restart(with packet: Packet) -> [Delivery] {
        held.removeAll()
        missing.removeAll()
        next = packet.sequence &+ 1
        return [Delivery(packet: packet, isContiguous: false)]
    }
}
