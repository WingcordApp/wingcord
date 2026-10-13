import Foundation
import Testing
@testable import WingcordVoice

@Suite("RTP")
struct RTPTests {

    @Test func headerRoundTrips() throws {
        var writer = RTPWriter(ssrc: 0x0102_0304, payloadType: RTP.PayloadType.h264)
        let first = writer.next(advancingClockBy: 3_000, marker: true)
        #expect(first.encrypted.isEmpty, "no extension means nothing to encrypt ahead of the media")
        let header = try #require(RTPHeader(parsing: first.clear + [0, 0, 0, 0]))
        #expect(header.ssrc == 0x0102_0304)
        #expect(header.payloadType == RTP.PayloadType.h264)
        #expect(header.marker)
        #expect(header.clearPrefixLength == 12)

        let second = writer.next(advancingClockBy: 3_000)
        let next = try #require(RTPHeader(parsing: second.clear + [0, 0, 0, 0]))
        #expect(next.sequence == header.sequence &+ 1)
        #expect(next.timestamp == header.timestamp &+ 3_000)
    }

    /// The extension block's length is in 32-bit words and excludes its own
    /// four-byte preamble. Reading it as bytes puts the clear prefix in the
    /// middle of the ciphertext.
    ///
    /// **And the clear prefix stops at the preamble.** Discord encrypts the
    /// extension elements, unlike SRTP, so a twenty-byte prefix here — twelve
    /// plus the whole four-byte block — authenticates four bytes of ciphertext
    /// and fails every packet that carries an extension, in both directions.
    @Test func theClearPrefixStopsAtTheExtensionPreamble() throws {
        var writer = RTPWriter(ssrc: 1, payloadType: 120)
        // Two bytes of element, padded to four.
        let packet = writer.next(
            advancingClockBy: 960,
            extensions: RTPExtension.audioLevel(id: 5, dBov: 12, isVoice: true)
        )
        #expect(packet.clear[12] == 0xBE && packet.clear[13] == 0xDE)
        #expect(Int(packet.clear[14]) << 8 | Int(packet.clear[15]) == 1)
        #expect(packet.clear.count == 16, "the preamble is clear and the elements are not")
        #expect(packet.encrypted.count == 4, "one padded word, sealed with the media")

        let header = try #require(
            RTPHeader(parsing: packet.clear + packet.encrypted + [0, 0, 0, 0])
        )
        #expect(header.clearPrefixLength == 16)
        #expect(header.extensionBodyLength == 4)
    }

    /// §5.1's padding bit, and the reason it is not optional.
    ///
    /// Discord pads audio, and the padding sits *inside* the encrypted region:
    /// it decrypts cleanly and then sits between the media and the end of the
    /// buffer. A receiver that does not strip it looks for the DAVE footer and
    /// finds filler — measured live as a 174-byte frame ending in twelve
    /// `0x75`s, which is 117 bytes of padding naming itself in its last octet.
    @Test func thePaddingBitIsReadAndItsCountIsTheFinalOctet() throws {
        var writer = RTPWriter(ssrc: 7, payloadType: RTP.PayloadType.opus)
        var packet = writer.next(advancingClockBy: 960).clear
        #expect(try #require(RTPHeader(parsing: packet + [1, 2])).hasPadding == false)

        // Set P, and append four padding octets whose last names the run.
        packet[0] |= 0x20
        let media: [UInt8] = [0xAA, 0xBB]
        let payload = media + [0x75, 0x75, 0x75, 4]
        let header = try #require(RTPHeader(parsing: packet + payload))
        #expect(header.hasPadding)

        // What the receive path does with it: the count includes itself.
        var trimmed = payload
        let count = Int(try #require(trimmed.last))
        #expect(count == 4)
        trimmed.removeLast(count)
        #expect(trimmed == media)
    }

    @Test func audioLevelIsInvertedDecibels() {
        let element = RTPExtension.audioLevel(id: 1, dBov: 0, isVoice: true)
        #expect(element[0] == 0x10)          // id 1, length 2
        #expect(element[1] == 0x80)          // voice bit, 0 dBov = full scale
        let quiet = RTPExtension.audioLevel(id: 1, dBov: 127, isVoice: false)
        #expect(quiet[1] == 127)
    }

    /// The elements go in the part of the packet that is encrypted, in order,
    /// padded to a word with RFC 8285's no-op — and the header says how long
    /// that part is, which is what a receiver strips from the decrypted payload.
    @Test func elementsAreWrittenIntoTheEncryptedBlock() throws {
        var writer = RTPWriter(ssrc: 1, payloadType: 120)
        let packet = writer.next(
            advancingClockBy: 960,
            extensions: RTPExtension.audioLevel(id: 3, dBov: 42, isVoice: true)
                + RTPExtension.absoluteSendTime(id: 4, seconds: 1)
        )
        #expect(packet.encrypted == [0x30, 0xAA, 0x42, 0x04, 0x00, 0x00, 0x00, 0x00])
        let header = try #require(RTPHeader(parsing: packet.clear + packet.encrypted))
        #expect(header.extensionBodyLength == packet.encrypted.count)
    }

    @Test func aNonRTPDatagramIsRejected() {
        #expect(RTPHeader(parsing: [0x00, 0x02]) == nil)
        // An IP-discovery reply is 74 bytes beginning 0x00 0x02, which is
        // version 0 — the check that stops discovery being parsed as media.
        #expect(RTPHeader(parsing: [UInt8](repeating: 0, count: 74)) == nil)
    }

    @Test func discoveryReplyParses() throws {
        var reply = [UInt8](repeating: 0, count: 74)
        reply[1] = 0x02
        let address = Array("203.0.113.7".utf8)
        reply.replaceSubrange(8..<(8 + address.count), with: address)
        reply[72] = 0xC3
        reply[73] = 0x50
        let parsed = try VoiceTransport.parseDiscovery(reply)
        #expect(parsed.address == "203.0.113.7")
        #expect(parsed.port == 50_000)
    }
}

/// The voice gateway's endpoint.
///
/// A test because getting it wrong is silent: the socket opens on the default
/// port, HELLO arrives, and the handshake then never advances — with no close
/// code and nothing in any log to say why.
@Suite("Voice endpoint")
struct VoiceEndpointTests {

    @Test("A published port is kept")
    func portsAreKept() {
        #expect(VoiceGateway.authority(from: "c-otp02-4806a489.discord.media:2083")
            == "c-otp02-4806a489.discord.media:2083")
        #expect(VoiceGateway.authority(from: "c-otp01-57c74002.discord.media:8443")
            == "c-otp01-57c74002.discord.media:8443")
        #expect(VoiceGateway.authority(from: "us-east1234.discord.media:443")
            == "us-east1234.discord.media:443")
    }

    /// The one port that must go — published for years on endpoints that only
    /// ever spoke TLS.
    @Test("The legacy :80 is dropped")
    func legacyPortIsDropped() {
        #expect(VoiceGateway.authority(from: "us-west50.discord.media:80")
            == "us-west50.discord.media")
    }

    @Test("An endpoint with no port is left alone")
    func bareHostSurvives() {
        #expect(VoiceGateway.authority(from: "voice.discord.media") == "voice.discord.media")
    }

    /// Every packet of one video frame carries the same timestamp, and only the
    /// last carries the marker.
    ///
    /// **Asserted on the emitted headers, because the sender is self-consistent
    /// either way.** `next` writes the clock it holds and advances afterwards,
    /// so advancing on the first packet of a frame put that packet — the
    /// leading NAL, a parameter set on a keyframe — on the *previous* frame's
    /// timestamp. Nothing at this end notices: the packet count, the bitrate
    /// and the encoder are all healthy. A receiver groups by timestamp, so
    /// every frame arrived a NAL short, no keyframe ever assembled, and the far
    /// end sat on a spinner until it reported a camera that would not start.
    @Test("Every packet of one video frame carries the same timestamp")
    func oneFrameIsOneTimestamp() {
        var writer = RTPWriter(ssrc: 9, payloadType: RTP.PayloadType.h264)
        let start = writer.timestamp

        func stamp(_ header: RTPHeaderBytes) -> UInt32 {
            let bytes = header.clear
            return UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16
                | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        }

        // One access unit of four packets, 3000 ticks after the last.
        writer.advanceClock(by: 3_000)
        let frame = (0..<4).map { index in
            writer.next(advancingClockBy: 0, marker: index == 3)
        }
        let stamps = frame.map(stamp)
        #expect(stamps.allSatisfy { $0 == start &+ 3_000 })
        #expect(Set(stamps).count == 1)

        // And the next frame starts from where this one left the clock, so the
        // advance a caller computes against `timestamp` is still the real gap.
        #expect(writer.timestamp == start &+ 3_000)
        writer.advanceClock(by: 3_000)
        #expect(stamp(writer.next(advancingClockBy: 0, marker: true)) == start &+ 6_000)
    }

    /// What the URL actually comes out as, because that is the thing that was
    /// wrong.
    @Test("The socket URL carries the port and the version")
    func urlKeepsThePort() throws {
        var components = try #require(
            URLComponents(string: "wss://\(VoiceGateway.authority(from: "host.discord.media:2083"))")
        )
        components.queryItems = [URLQueryItem(name: "v", value: "8")]
        #expect(components.port == 2083)
        #expect(components.url?.absoluteString == "wss://host.discord.media:2083?v=8")
    }
}

// MARK: - The extensions a working stream carries

@Suite("RTP header extensions")
struct RTPExtensionTests {

    /// The two elements every packet of a stream Discord renders carries, and
    /// which this client once sent none of — **asserted against literal bytes**,
    /// never against a reader of our own, which would agree with any mistake it
    /// shared. Captured off a working stream as `ext=[3:bcbbac 5:0047]`; 47 s in
    /// 6.18 fixed point is `0xbc0000`, so the capture is the same clock a few
    /// milliseconds later.
    @Test("The two elements a working stream carries are written as they were read")
    func writesWhatWasRead() {
        #expect(RTPExtension.absoluteSendTime(
            id: RTPExtension.DefaultID.absoluteSendTime, seconds: 47.0
        ) == [0x32, 0xBC, 0x00, 0x00])
        #expect(RTPExtension.transportSequence(
            id: RTPExtension.DefaultID.transportSequence, sequence: 0x0047
        ) == [0x51, 0x00, 0x47])
    }

    /// One number for the whole connection, wrapping where the field does.
    @Test("The transport sequence advances once per packet and wraps at sixteen bits")
    func transportSequenceCounts() {
        let counter = TransportSequence()
        #expect(counter.next() == 0)
        #expect(counter.next() == 1)
        for _ in 0..<(0xFFFF - 1) { _ = counter.next() }
        #expect(counter.next() == 0, "and wraps rather than saturating")
    }
}
