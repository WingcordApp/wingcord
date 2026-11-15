import Foundation
import Network
import Synchronization
import Testing
@testable import WingcordVoice

// MARK: - What a session is keyed on

@Suite("Media session")
struct MediaSessionTests {

    private static let connection = MediaSession.Connection(
        endpoint: "voice.example:443", token: "t", serverID: "1", userID: 2, sessionID: "s"
    )

    /// **The group key is decided by what the session is, and nothing else.**
    /// A share that keyed its group on the call's channel encrypted a second
    /// session's media under the first one's keys, and every member refused it.
    /// The kind carries the id its group needs, so the wrong one cannot be
    /// passed without naming it.
    @Test("A call keys its group on its channel, a stream and a watch on the media session")
    func groupKeys() async {
        let call = MediaSession(
            connection: Self.connection,
            kind: .call(channelID: 30, audioBitrate: 64_000, preferences: .init())
        )
        let stream = MediaSession(
            connection: Self.connection,
            kind: .stream(
                mediaSessionID: 40,
                capture: ScreenShareCapture(),
                quality: .init(width: 1_280, height: 720, framerate: 30, capturesAudio: true),
                audioBitrate: 64_000
            )
        )
        let watch = MediaSession(
            connection: Self.connection, kind: .watch(mediaSessionID: 50, owner: 9)
        )
        #expect(await call.groupKey == .channel(30))
        #expect(await stream.groupKey == .mediaSession(40))
        #expect(await watch.groupKey == .mediaSession(50))
    }
}

// MARK: - The media socket

/// Every datagram the handler was given, in order.
private final class Received: Sendable {
    private let datagrams = Mutex<[[UInt8]]>([])

    func append(_ bytes: [UInt8]) { datagrams.withLock { $0.append(bytes) } }
    var all: [[UInt8]] { datagrams.withLock { $0 } }
}

@Suite("Media socket", .serialized)
struct VoiceTransportTests {

    /// **The receive handler is fixed for the life of the socket.** Address
    /// discovery used to swap it for a filter and back while datagrams were
    /// being delivered on the socket's queue — a closure written on one thread
    /// and read on another. The reply is now told apart where it arrives, so
    /// this drives a real loopback socket with media arriving in the middle of
    /// a discovery: the media must reach the handler, and the reply must reach
    /// the discovery and nothing else.
    @Test("Media arriving during discovery reaches the handler, and the reply reaches discovery")
    func discoveryAndMediaShareTheSocket() async throws {
        let media: [UInt8] = [0x80, 0x78, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 7]
        var reply = [UInt8](repeating: 0, count: 74)
        reply[1] = 0x02
        reply[3] = 0x46
        let address = Array("203.0.113.7".utf8)
        reply.replaceSubrange(8..<(8 + address.count), with: address)
        reply[72] = 0x10
        reply[73] = 0x92

        // The server's half: answer a discovery request with a media packet
        // first and the reply after it, on the same flow.
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { [reply] peer in
            peer.start(queue: .global())
            peer.receiveMessage { data, _, _, _ in
                guard let data, data.count == 74, data[data.startIndex + 1] == 0x01 else { return }
                peer.send(content: Data(media), completion: .idempotent)
                peer.send(content: Data(reply), completion: .idempotent)
            }
        }
        let port = try await Self.start(listener)
        defer { listener.cancel() }

        let transport = VoiceTransport(host: "127.0.0.1", port: port)
        let received = Received()
        transport.start { received.append($0) }
        defer { transport.stop() }
        #expect(await transport.waitUntilReady())

        let mapped = try await transport.discoverAddress(ssrc: 7, timeout: .seconds(2))
        #expect(mapped.address == "203.0.113.7")
        #expect(mapped.port == 4_242)

        // The media was sent first; give the socket's queue a moment to have
        // handed it over before asserting what the handler saw.
        for _ in 0..<50 where received.all.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received.all == [media], "the media, and not the reply")
    }

    /// **What leaves is kept, and resent as RFC 4588 asks.** A frame goes out
    /// through the pacer as packets in order under one timestamp; a NACK for
    /// one of them brings it back on the retransmission stream, its original
    /// sequence number ahead of its original payload — and a NACK about some
    /// other stream's numbers brings nothing, because the history is ours.
    @Test("A NACK about our video is answered on the retransmission stream, and no other")
    func retransmission() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        let received = Received()
        listener.newConnectionHandler = { peer in
            peer.start(queue: .global())
            @Sendable func next() {
                peer.receiveMessage { data, _, _, error in
                    if let data { received.append([UInt8](data)) }
                    if error == nil { next() }
                }
            }
            next()
        }
        let port = try await Self.start(listener)
        defer { listener.cancel() }

        let transport = VoiceTransport(host: "127.0.0.1", port: port)
        transport.start { _ in }
        defer { transport.stop() }
        #expect(await transport.waitUntilReady())

        let sealer = VoiceSealer(cipher: .aes256GCM, secretKey: [UInt8](repeating: 0x22, count: 32))
        let path = VideoSendPath()
        path.configure(
            sealer: sealer, transport: transport, ssrc: 5_000, retransmissionSSRC: 5_001,
            sendTimeExtensionID: nil, transportSequenceExtensionID: nil, transportSequence: nil
        )
        path.isActive = true
        let picture: [UInt8] = [0x65] + (0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        path.send(
            units: [picture], parameterSets: [[0x67, 0x42, 0xC0, 0x1F], [0x68, 0xCE, 0x3C, 0x80]],
            isKeyframe: true, captureTime: 1
        )

        func opened(_ datagram: [UInt8]) throws -> (header: RTPHeader, payload: [UInt8]) {
            let header = try #require(RTPHeader(parsing: datagram))
            let payload = try #require(sealer.open(datagram, headerLength: header.clearPrefixLength))
            return (header, payload)
        }
        func waitFor(_ count: Int) async throws {
            for _ in 0..<200 where received.all.count < count {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        // The whole picture, up to the packet with its marker, not its first
        // three packets: on a slow runner the rest were still on their way when
        // the count reached three, so the marker and the count after the resend
        // were checked against half a frame.
        for _ in 0..<400 {
            if received.all.count >= 3, let last = received.all.last, (try? opened(last))?.header.marker == true { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let frame = try received.all.map(opened)
        #expect(frame.count >= 3, "a picture of three kilobytes is several packets")
        #expect(frame.allSatisfy { $0.header.payloadType == RTP.PayloadType.h264 && $0.header.ssrc == 5_000 })
        #expect(Set(frame.map(\.header.timestamp)) == [90_000], "one timestamp, from the capture")
        #expect(frame.map(\.header.marker) == Array(repeating: false, count: frame.count - 1) + [true])
        let lost = frame[1]

        path.retransmit([lost.header.sequence], of: 5_000)
        try await waitFor(frame.count + 1)
        let resent = try opened(try #require(received.all.last))
        #expect(resent.header.payloadType == RTP.PayloadType.h264RTX)
        #expect(resent.header.ssrc == 5_001)
        #expect(resent.header.timestamp == lost.header.timestamp)
        #expect(resent.payload == [UInt8(lost.header.sequence >> 8), UInt8(lost.header.sequence & 0xFF)] + lost.payload)

        path.retransmit([lost.header.sequence], of: 4_999)
        try await Task.sleep(for: .milliseconds(100))
        #expect(received.all.count == frame.count + 1, "nothing for a stream that is not ours")
    }

    /// **Five frames lead.** Discord's `vadLeading`: the frames before the one
    /// that crossed the line go out ahead of it — on their own timestamps,
    /// because the clock moved while the gate was shut — and the first of them
    /// carries the marker that tells a receiver a talkspurt began.
    @Test("The gate's lead-in leaves first, on its own timestamps, with the marker")
    func leadIn() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        let received = Received()
        listener.newConnectionHandler = { peer in
            peer.start(queue: .global())
            @Sendable func next() {
                peer.receiveMessage { data, _, _, error in
                    if let data { received.append([UInt8](data)) }
                    if error == nil { next() }
                }
            }
            next()
        }
        let port = try await Self.start(listener)
        defer { listener.cancel() }
        let transport = VoiceTransport(host: "127.0.0.1", port: port)
        transport.start { _ in }
        defer { transport.stop() }
        #expect(await transport.waitUntilReady())

        let sealer = VoiceSealer(cipher: .aes256GCM, secretKey: [UInt8](repeating: 0x33, count: 32))
        let path = AudioSendPath()
        path.configure(
            sealer: sealer, transport: transport, ssrc: 6_000, bitrate: 64_000,
            audioLevelExtensionID: nil, sendTimeExtensionID: nil,
            transportSequenceExtensionID: nil, transportSequence: nil
        )
        path.inputMode = .voiceActivity(.init(isAutomatic: false, threshold: -40))
        let start = path.senderCounts.clock
        let frame = [Int16](repeating: 0, count: OpusFormat.voiceFrameCount)
        frame.withUnsafeBufferPointer { samples in
            // Ten quiet frames at −60 dB, then one at −20.
            for _ in 0..<10 { path.send(samples.baseAddress!, level: 0.001) }
            path.send(samples.baseAddress!, level: 0.1)
        }
        for _ in 0..<200 where received.all.count < 6 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let headers = try received.all.map { try #require(RTPHeader(parsing: $0)) }
        #expect(headers.count == 6, "five frames of lead-in and the one that opened it")
        #expect(headers.map(\.timestamp) == (5...10).map { start &+ UInt32($0) * 960 })
        #expect(headers.map(\.marker) == [true, false, false, false, false, false])
        let sequences = headers.map(\.sequence)
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $1 == $0 &+ 1 })
    }

    /// **A stream's sound has no gate and two channels.** Every frame leaves,
    /// the quiet ones too — a film's soundtrack is not a voice that stops
    /// between words — and what arrives decodes to the stereo that was
    /// captured: a game folded to one channel is footsteps with no side.
    @Test("A stream's sound sends every frame, in stereo")
    func soundshare() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        let received = Received()
        listener.newConnectionHandler = { peer in
            peer.start(queue: .global())
            @Sendable func next() {
                peer.receiveMessage { data, _, _, error in
                    if let data { received.append([UInt8](data)) }
                    if error == nil { next() }
                }
            }
            next()
        }
        let port = try await Self.start(listener)
        defer { listener.cancel() }
        let transport = VoiceTransport(host: "127.0.0.1", port: port)
        transport.start { _ in }
        defer { transport.stop() }
        #expect(await transport.waitUntilReady())

        let sealer = VoiceSealer(cipher: .aes256GCM, secretKey: [UInt8](repeating: 0x44, count: 32))
        let path = AudioSendPath(signal: .soundshare)
        path.configure(
            sealer: sealer, transport: transport, ssrc: 7_000, bitrate: 128_000,
            audioLevelExtensionID: nil, sendTimeExtensionID: nil,
            transportSequenceExtensionID: nil, transportSequence: nil
        )
        path.inputMode = .open
        let start = path.senderCounts.clock
        // A tone on the left, nothing on the right, at a level no voice gate
        // would open for.
        var frame = [Int16](repeating: 0, count: OpusFormat.interleavedCount)
        for index in 0..<Int(OpusFormat.frameSize) {
            frame[index * 2] = Int16(sin(2 * .pi * 440 * Double(index) / 48_000) * 12_000)
        }
        frame.withUnsafeBufferPointer { samples in
            for _ in 0..<10 { path.send(samples.baseAddress!, level: 0.000_1) }
        }
        for _ in 0..<200 where received.all.count < 10 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let headers = try received.all.map { try #require(RTPHeader(parsing: $0)) }
        #expect(headers.count == 10, "every frame, the quiet ones included")
        #expect(headers.map(\.timestamp) == (0..<10).map { start &+ UInt32($0) * 960 })
        #expect(headers.map(\.marker) == [true] + Array(repeating: false, count: 9))

        let decoder = try OpusDecoder()
        var pcm = [Int16](repeating: 0, count: OpusFormat.interleavedCount)
        for datagram in received.all {
            let header = try #require(RTPHeader(parsing: datagram))
            let payload = try #require(sealer.open(datagram, headerLength: header.clearPrefixLength))
            _ = try decoder.decode(payload, into: &pcm)
        }
        let left = stride(from: 0, to: pcm.count, by: 2).reduce(0.0) { $0 + abs(Double(pcm[$1])) }
        let right = stride(from: 1, to: pcm.count, by: 2).reduce(0.0) { $0 + abs(Double(pcm[$1])) }
        #expect(left > right * 20, "the left channel's tone, and the right's silence")
    }

    /// Starts a listener and answers with the port it was given.
    private static func start(_ listener: NWListener) async throws -> UInt16 {
        let started = Mutex(false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                let resume: Result<UInt16, any Error>? = switch state {
                case .ready: listener.port.map { .success($0.rawValue) }
                case .failed(let error): .failure(error)
                default: nil
                }
                guard let resume, !started.withLock({ defer { $0 = true }; return $0 }) else { return }
                continuation.resume(with: resume)
            }
            listener.start(queue: .global())
        }
    }
}

// MARK: - The playback ring

@Suite("Audio ring")
struct AudioRingTests {

    private func write(_ samples: [Float], to ring: AudioRing) {
        samples.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: $0.count) }
    }

    private func read(_ count: Int, from ring: AudioRing) -> (samples: [Float], ready: Int) {
        var out = [Float](repeating: -1, count: count)
        let ready = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
        return (out, ready)
    }

    /// **The reader's index is the reader's alone.** A flush used to store it
    /// from whichever thread asked — the call's actor, on deafen — while the
    /// render callback stored it too. Now asking moves nothing, and the reader
    /// lets go of what was queued on its next read.
    @Test("A flush is carried out by the reader, and what follows it plays")
    func flushIsTheReadersToCarryOut() {
        let ring = AudioRing(capacity: 16)
        write([1, 2, 3, 4], to: ring)
        ring.flush()
        #expect(ring.count == 4, "asking moves nothing")

        let flushed = read(4, from: ring)
        #expect(flushed.ready == 0)
        #expect(flushed.samples == [0, 0, 0, 0], "and what was queued is never played")
        #expect(ring.count == 0)

        write([5, 6], to: ring)
        let next = read(2, from: ring)
        #expect(next.ready == 2)
        #expect(next.samples == [5, 6])
    }

    /// A flush asked for while nothing reads — the engine stopped — waits for
    /// the next reader rather than being lost.
    @Test("A flush with nobody reading waits for the next read")
    func flushWaitsForTheReader() {
        let ring = AudioRing(capacity: 16)
        write([1, 2], to: ring)
        ring.flush()
        write([3, 4], to: ring)
        // Everything written before the reader came back is let go together.
        #expect(read(4, from: ring).ready == 0)
        write([7], to: ring)
        #expect(read(1, from: ring).samples == [7])
    }
}
