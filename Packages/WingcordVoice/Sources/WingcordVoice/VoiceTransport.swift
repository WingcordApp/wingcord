import Foundation
import Network
import Synchronization

// MARK: - The media socket
//
// One UDP flow carries everything: our microphone, our camera, our screen, and
// everybody else's. It is opened once per voice connection and lives as long as
// the session does.
//
// `NWConnection` rather than a BSD socket, and the reason is not tidiness:
// `NWParameters.serviceClass = .interactiveVoice` is what marks the flow EF at
// the IP layer and asks Wi-Fi for the voice access category. On a congested
// network that marking is the difference between a call that degrades and one
// that stutters, and there is no way to ask for it through `socket(2)` on this
// platform without reaching for `setsockopt` and a raw DSCP value.
//
// **The receive loop never awaits anything that can wait on a future packet.**
// The same rule the main gateway is built on, and for the same reason: the loop
// is the only thing that can read the socket, so a handler that suspends on the
// next packet suspends the thing that would deliver it. Packets are decrypted
// and handed to a sink synchronously.

public final class VoiceTransport: @unchecked Sendable {

    public enum Failure: Error, Sendable {
        case notReady
        case discoveryTimedOut
        case discoveryMalformed
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.wingcord.voice.udp", qos: .userInteractive)
    private let readyGate = Gate()

    /// Called for every datagram that arrives, on the socket's own queue.
    ///
    /// Set once, before `start`. A property rather than a stream: an
    /// `AsyncStream` puts a scheduling hop between the packet and the jitter
    /// buffer, which on a burst is exactly where reordering gets manufactured
    /// by the client that is supposed to be fixing it.
    public var onDatagram: (@Sendable ([UInt8]) -> Void)?

    public init(host: String, port: UInt16) {
        let parameters = NWParameters.udp
        // EF marking, and the Wi-Fi voice access category with it.
        parameters.serviceClass = .interactiveVoice
        // A voice flow that survives a Wi-Fi-to-Ethernet change without
        // renegotiating is not a thing Discord's protocol allows — the server
        // routes to the address we told it about — so this stays off and the
        // session reconnects instead. Naming it is cheaper than rediscovering
        // why turning it on made calls fail on a dock.
        parameters.prohibitExpensivePaths = false
        parameters.allowLocalEndpointReuse = true

        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: parameters
        )
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readyGate.open()
                self?.receiveLoop()
            case .failed(let error):
                VoiceTrace.fault("udp failed: \(error.localizedDescription)")
                self?.readyGate.open()
            case .cancelled:
                self?.readyGate.open()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func stop() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receiveLoop() {
        // `receiveMessage`, not `receive(minimum:maximum:)`. The latter is a
        // byte-stream read and will happily hand back two datagrams glued
        // together; on a message protocol that is a packet nobody can parse and
        // a stream that never recovers.
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { onDatagram?([UInt8](data)) }
            guard error == nil else { return }
            receiveLoop()
        }
    }

    /// Datagrams the stack refused, and the first reason it gave.
    ///
    /// **`out=` counts calls to this, not packets that left**, and the two are
    /// not the same number. A session can hand this three thousand datagrams
    /// and have every one of them dropped by the stack — too large, no route,
    /// a socket in a state that no longer accepts writes — and report a
    /// perfectly healthy send count while nothing crosses the wire. That is one
    /// of the four ways a black screen share looks identical from this end, and
    /// it was the only one with no counter at all.
    private let failures = SendFailures()

    /// Built once and reused. `.contentProcessed` costs a completion per
    /// datagram where `.idempotent` costs none, which on a path carrying a
    /// hundred and fifty packets a second is worth caring about — but not
    /// nearly as much as knowing whether they left.
    private lazy var completion: NWConnection.SendCompletion = .contentProcessed {
        [failures] error in
        guard let error else { return }
        failures.note(error)
    }

    /// How many datagrams the stack refused since the last call, and why the
    /// first of them was refused.
    public func drainSendFailures() -> (count: Int, reason: String?) {
        failures.drain()
    }

    public func send(_ datagram: Data) {
        connection.send(content: datagram, completion: completion)
    }

    public func send(_ datagram: [UInt8]) {
        connection.send(content: Data(datagram), completion: completion)
    }

    /// Waits for the flow to come up, or gives up.
    public func waitUntilReady(timeout: Duration = .seconds(5)) async -> Bool {
        await readyGate.wait(timeout: timeout)
        if case .ready = connection.state { return true }
        return false
    }

    // MARK: IP discovery

    /// Asks the media server what address our packets appear to come from.
    ///
    /// **A client cannot know this for itself.** Behind any NAT the socket's own
    /// local address is a private one, and the address the server has to send
    /// media back to is whatever the NAT rewrote it into. The protocol's answer
    /// is a 74-byte probe on the media socket itself, so the mapping it learns
    /// is the mapping the media will use — a probe on a second socket would
    /// discover a second, different mapping and the media would go nowhere.
    ///
    /// The request and the reply are the same 74 bytes with a different type
    /// word. The address in the reply is a null-terminated string in a 64-byte
    /// field, not a length-prefixed one.
    public func discoverAddress(ssrc: UInt32, timeout: Duration = .seconds(4)) async throws
        -> (address: String, port: UInt16)
    {
        var probe = [UInt8](repeating: 0, count: 74)
        probe[0] = 0x00
        probe[1] = 0x01                    // request
        probe[2] = 0x00
        probe[3] = 0x46                    // 70, the length after this field
        probe[4] = UInt8(truncatingIfNeeded: ssrc >> 24)
        probe[5] = UInt8(truncatingIfNeeded: ssrc >> 16)
        probe[6] = UInt8(truncatingIfNeeded: ssrc >> 8)
        probe[7] = UInt8(truncatingIfNeeded: ssrc)

        let inbox = Inbox()
        let previous = onDatagram
        onDatagram = { bytes in
            // Only the reply. Media can already be arriving on this socket by
            // the time the probe is answered, and a discovery that accepts the
            // first datagram of any kind parses an RTP header as an address.
            if bytes.count >= 74, bytes[0] == 0x00, bytes[1] == 0x02 {
                inbox.deliver(bytes)
            } else {
                previous?(bytes)
            }
        }
        defer { onDatagram = previous }

        // Sent more than once. The probe is a single UDP datagram on a path
        // that has never carried one, and a lost probe is a call that fails to
        // connect for no reason the reader can see.
        for attempt in 0..<3 {
            send(probe)
            if let reply = await inbox.take(timeout: attempt == 2 ? timeout : .milliseconds(700)) {
                return try Self.parseDiscovery(reply)
            }
        }
        throw Failure.discoveryTimedOut
    }

    static func parseDiscovery(_ reply: [UInt8]) throws -> (address: String, port: UInt16) {
        guard reply.count >= 74 else { throw Failure.discoveryMalformed }
        let field = reply[8..<72]
        let terminated = field.prefix { $0 != 0 }
        guard let address = String(bytes: terminated, encoding: .utf8), !address.isEmpty else {
            throw Failure.discoveryMalformed
        }
        let port = UInt16(reply[72]) << 8 | UInt16(reply[73])
        return (address, port)
    }
}

// MARK: - Two small synchronisation pieces
//
// Both exist because the socket's callbacks land on a `DispatchQueue` and the
// caller is in structured concurrency. Neither is general — each has exactly one
// user — and both resume their continuation exactly once, which is the property
// that matters: a `CheckedContinuation` resumed twice traps.
//
// `Mutex` rather than `NSLock`: `NSLock.lock()` is unavailable from an async
// context under Swift 6, because holding one across a suspension blocks a
// cooperative thread. `withLock` cannot be suspended inside, which is the
// compiler enforcing exactly the discipline these two need — every resume
// happens *after* the lock is given back.

/// Opens once, wakes everybody, and stays open.
private final class Gate: Sendable {
    private let state = Mutex(State())

    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    func open() {
        let pending: [CheckedContinuation<Void, Never>] = state.withLock { state in
            guard !state.isOpen else { return [] }
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in pending { waiter.resume() }
    }

    func wait(timeout: Duration) async {
        guard !state.withLock({ $0.isOpen }) else { return }

        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.open()
        }
        defer { timer.cancel() }

        await withCheckedContinuation { continuation in
            let alreadyOpen = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}

/// One slot, one waiter. Holds a datagram that arrived before anybody asked.
private final class Inbox: Sendable {
    private let state = Mutex(State())

    private struct State {
        var pending: [UInt8]?
        var waiter: CheckedContinuation<[UInt8]?, Never>?
    }

    func deliver(_ bytes: [UInt8]) {
        let waiter = state.withLock { state -> CheckedContinuation<[UInt8]?, Never>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.pending = bytes
            return nil
        }
        waiter?.resume(returning: bytes)
    }

    func take(timeout: Duration) async -> [UInt8]? {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self else { return }
            let waiter = state.withLock { state -> CheckedContinuation<[UInt8]?, Never>? in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: nil)
        }
        defer { timer.cancel() }

        return await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> [UInt8]?? in
                if let pending = state.pending {
                    state.pending = nil
                    return .some(pending)
                }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

// MARK: - What the stack refused

/// A reference type holding the counter, for the reason `RTCPListener` is one:
/// `Atomic` and `Mutex` are non-copyable, so a `@Sendable` completion handler
/// cannot capture one out of an enclosing type without consuming it.
private final class SendFailures: Sendable {
    private let count = Atomic<Int>(0)
    private let reason = Mutex<String?>(nil)

    /// Called on the socket's own queue, once per refused datagram.
    func note(_ error: NWError) {
        count.add(1, ordering: .relaxed)
        reason.withLock { slot in
            guard slot == nil else { return }
            slot = error.localizedDescription
            // The first one, to the unified log as well: by the time anybody
            // reads a trace the run is over, and this is the shape of failure
            // that leaves every other number healthy.
            VoiceTrace.fault("udp send refused: \(error.localizedDescription)")
        }
    }

    func drain() -> (count: Int, reason: String?) {
        (count.exchange(0, ordering: .relaxed), reason.withLock { $0 })
    }
}
