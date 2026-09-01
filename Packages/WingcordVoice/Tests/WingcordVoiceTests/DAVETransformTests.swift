import CryptoKit
import Foundation
import Testing

@testable import WingcordVoice

@Suite("DAVE frame transform")
struct DAVETransformTests {
    private func pair() -> (DAVEEncryptor, DAVEDecryptor) {
        let secret = [UInt8](repeating: 0x5A, count: 32)
        let encryptor = DAVEEncryptor()
        encryptor.setRatchet(MLSHashRatchet(baseSecret: secret))
        encryptor.setPassthrough(false)
        let decryptor = DAVEDecryptor(userID: 1)
        decryptor.transition(to: MLSHashRatchet(baseSecret: secret), retaining: 0)
        return (encryptor, decryptor)
    }

    /// An Opus packet, the shape a real one has: a TOC byte and then payload.
    private var opusFrame: [UInt8] {
        [0x78] + (0..<80).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
    }

    @Test("An Opus frame round-trips, and none of it is left in the clear")
    func opusRoundTrip() throws {
        let (encryptor, decryptor) = pair()
        let frame = opusFrame
        let sealed = try #require(encryptor.encrypt(frame, codec: .opus))

        #expect(sealed.suffix(2) == DAVE.magicMarker[...])
        #expect(sealed.count > frame.count)

        // **The whole packet is encrypted, TOC byte included.** If any of the
        // original bytes survive in order at the front, something is being left
        // in the clear that should not be.
        #expect(!sealed.starts(with: frame.prefix(8)))
        let parsed = try #require(InboundFrame(parsing: sealed))
        #expect(parsed.ranges.isEmpty, "Opus has no ranges the packetizer reads")
        #expect(parsed.authenticated.isEmpty)
        #expect(parsed.ciphertext.count == frame.count)

        #expect(decryptor.decrypt(sealed, isAudio: true) == frame)
    }

    @Test("A tampered frame does not decrypt, in the ciphertext or the footer")
    func tampering() throws {
        let (encryptor, decryptor) = pair()
        let frame = opusFrame

        var body = try #require(encryptor.encrypt(frame, codec: .opus))
        body[4] ^= 0x01
        #expect(decryptor.decrypt(body, isAudio: true) == nil)

        var tag = try #require(encryptor.encrypt(frame, codec: .opus))
        tag[tag.count - 6] ^= 0x01
        #expect(decryptor.decrypt(tag, isAudio: true) == nil)

        // Truncating the marker makes it stop being a protocol frame at all,
        // and outside passthrough that is a drop rather than a pass.
        var marker = try #require(encryptor.encrypt(frame, codec: .opus))
        marker[marker.count - 1] ^= 0xFF
        #expect(decryptor.decrypt(marker, isAudio: true) == nil)
    }

    /// A frame accepted twice is a frame an attacker can repeat.
    @Test("A replayed frame is refused, but a reordered one is not")
    func replayAndReordering() throws {
        let (encryptor, decryptor) = pair()
        let first = try #require(encryptor.encrypt(opusFrame, codec: .opus))
        let second = try #require(encryptor.encrypt(opusFrame, codec: .opus))
        let third = try #require(encryptor.encrypt(opusFrame, codec: .opus))

        #expect(decryptor.decrypt(first, isAudio: true) != nil)
        #expect(decryptor.decrypt(first, isAudio: true) == nil, "a replay")

        // Out of order is normal on a lossy path and must still work.
        #expect(decryptor.decrypt(third, isAudio: true) != nil)
        #expect(decryptor.decrypt(second, isAudio: true) != nil, "a reordered frame")
        #expect(decryptor.decrypt(second, isAudio: true) == nil, "a replay of it")
    }

    @Test("Passthrough passes plain frames and refuses them when it is off")
    func passthrough() throws {
        let encryptor = DAVEEncryptor()
        encryptor.setPassthrough(true)
        #expect(encryptor.encrypt(opusFrame, codec: .opus) == opusFrame)

        let decryptor = DAVEDecryptor(userID: 1)
        decryptor.setPassthrough(true, retaining: 0)
        #expect(decryptor.decrypt(opusFrame, isAudio: true) == opusFrame)

        // With passthrough off and no ratchet, a plain frame is not media this
        // client may hand to a decoder.
        let strict = DAVEDecryptor(userID: 1)
        #expect(strict.decrypt(opusFrame, isAudio: true) == nil)
    }

    /// The SFU synthesises this for a muted source and it is never encrypted.
    @Test("The silence packet passes even when passthrough is off")
    func silencePacket() {
        let decryptor = DAVEDecryptor(userID: 1)
        #expect(decryptor.decrypt(DAVE.opusSilence, isAudio: true) == DAVE.opusSilence)
        // Only for audio: three bytes of video are not a silence packet.
        #expect(decryptor.decrypt(DAVE.opusSilence, isAudio: false) == nil)
    }

    /// After an epoch change the old ratchet has to keep working for a moment,
    /// because media encrypted under it is still arriving.
    @Test("A retained previous epoch still decrypts frames in flight")
    func epochRetention() throws {
        let (encryptor, decryptor) = pair()
        let inFlight = try #require(encryptor.encrypt(opusFrame, codec: .opus))

        decryptor.transition(
            to: MLSHashRatchet(baseSecret: [UInt8](repeating: 0x77, count: 32)),
            retaining: DAVE.keyRetention
        )
        #expect(
            decryptor.decrypt(inFlight, isAudio: true) != nil,
            "a frame from the previous epoch, still in flight"
        )

        // And a frame under the new ratchet decrypts too.
        let next = DAVEEncryptor()
        next.setRatchet(MLSHashRatchet(baseSecret: [UInt8](repeating: 0x77, count: 32)))
        next.setPassthrough(false)
        let fresh = try #require(next.encrypt(opusFrame, codec: .opus))
        #expect(decryptor.decrypt(fresh, isAudio: true) != nil)
    }

    // MARK: H.264

    /// A frame shaped like one VideoToolbox produces: a parameter set, then a
    /// slice, in Annex B with start codes.
    private var h264Frame: [UInt8] {
        var frame: [UInt8] = []
        frame.append(contentsOf: [0, 0, 0, 1])
        frame.append(contentsOf: [0x67, 0x42, 0x00, 0x1E, 0x8D, 0x8D, 0x40])  // SPS
        frame.append(contentsOf: [0, 0, 0, 1])
        frame.append(contentsOf: [0x68, 0xCE, 0x3C, 0x80])                     // PPS
        frame.append(contentsOf: [0, 0, 0, 1])
        frame.append(contentsOf: [0x65, 0x88, 0x84])                           // IDR header
        frame.append(contentsOf: (0..<200).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })        // picture
        return frame
    }

    @Test("H.264 keeps its NAL headers readable and encrypts the picture")
    func h264Ranges() throws {
        let (encryptor, decryptor) = pair()
        let frame = h264Frame
        let sealed = try #require(encryptor.encrypt(frame, codec: .h264))

        let parsed = try #require(InboundFrame(parsing: sealed))
        #expect(!parsed.ranges.isEmpty, "the depacketizer needs the NAL headers")
        #expect(!parsed.ciphertext.isEmpty, "the picture must be encrypted")

        // Start codes survive so the packetizer can still find NAL boundaries.
        #expect(sealed.starts(with: [0, 0, 0, 1]))
        // The parameter sets are metadata and stay whole; the picture does not.
        #expect(parsed.authenticated.contains(0x67))
        #expect(parsed.authenticated.contains(0x68))
        #expect(!parsed.authenticated.contains(where: { $0 == 0x9B }))

        #expect(decryptor.decrypt(sealed, isAudio: false) == frame)
    }

    /// The ciphertext may not contain a start code, or the packetizer would cut
    /// the frame in the wrong place and it would never reassemble.
    @Test("An encrypted H.264 frame never carries a start code in its ciphertext")
    func h264StartCodes() throws {
        let (encryptor, decryptor) = pair()
        // Many frames, because a start code appearing by chance is rare — the
        // point is that the retry loop catches it whenever it does.
        for index in 0..<200 {
            var frame = h264Frame
            frame.append(UInt8(truncatingIfNeeded: index))
            let sealed = try #require(encryptor.encrypt(frame, codec: .h264))
            let parsed = try #require(InboundFrame(parsing: sealed))
            #expect(
                DAVECodec.encryptedFrameIsSafe(sealed, ranges: parsed.ranges, codec: .h264),
                "frame \(index) shipped with a start code in its ciphertext"
            )
            #expect(decryptor.decrypt(sealed, isAudio: false) == frame)
        }
    }

    @Test("An unknown codec is encrypted whole rather than guessed at")
    func unknownCodec() throws {
        let (encryptor, decryptor) = pair()
        let frame = h264Frame
        let sealed = try #require(encryptor.encrypt(frame, codec: .unknown))
        let parsed = try #require(InboundFrame(parsing: sealed))
        #expect(parsed.ranges.isEmpty)
        #expect(decryptor.decrypt(sealed, isAudio: false) == frame)
    }
}

// MARK: - The footer's own encodings

@Suite("DAVE wire encodings")
struct DAVEEncodingTests {
    @Test("ULEB128 round-trips across its width boundaries")
    func leb128() {
        for value: UInt64 in [0, 1, 0x7F, 0x80, 0x3FFF, 0x4000, 0xFFFF, 0x1F_FFFF, 0xFFFF_FFFF] {
            var buffer: [UInt8] = []
            LEB128.write(value, into: &buffer)
            #expect(buffer.count == LEB128.size(value), "size disagrees for \(value)")
            var index = 0
            #expect(LEB128.read(buffer, &index, end: buffer.count) == value)
            #expect(index == buffer.count)
        }
        // A truncated encoding is a parse failure, not a partial value.
        var index = 0
        #expect(LEB128.read([0x80], &index, end: 1) == nil)
    }

    /// **The nonce layout is the one thing here that only interoperability can
    /// catch.** Both ends of a Wingcord-to-Wingcord call would agree on a
    /// backwards nonce, so this is pinned against the byte order Discord's own
    /// implementation writes.
    @Test("The truncated nonce widens into the last four bytes, little-endian")
    func nonceLayout() {
        #expect(DAVE.fullNonce(from: 0x0102_0304) == [
            0, 0, 0, 0, 0, 0, 0, 0, 0x04, 0x03, 0x02, 0x01,
        ])
        #expect(DAVE.fullNonce(from: 1) == [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0])
        #expect(DAVE.fullNonce(from: 0).allSatisfy { $0 == 0 })
    }

    /// The generation is the top byte of the counter, so it advances once every
    /// 2^24 frames without a byte on the wire.
    @Test("The generation is the nonce's most significant byte")
    func generations() {
        #expect(DAVE.generation(of: 0) == 0)
        #expect(DAVE.generation(of: 0x00FF_FFFF) == 0)
        #expect(DAVE.generation(of: 0x0100_0000) == 1)
        #expect(DAVE.generation(of: 0xFF00_0000) == 255)
        #expect(DAVE.wrappedNonce(generation: 1, truncated: 0x0100_0005) == 0x0100_0005)
        // Past the wrap, the generation keeps counting where the byte cannot.
        #expect(DAVE.wrappedGeneration(oldest: 300, generation: 45) == 301)
        #expect(DAVE.wrappedGeneration(oldest: 300, generation: 250) == 250 + 256)
    }

    @Test("A frame that is not a protocol frame is recognised as one")
    func frameCheck() {
        #expect(InboundFrame(parsing: []) == nil)
        #expect(InboundFrame(parsing: [1, 2, 3]) == nil)
        // The marker in place but a nonsense supplemental size.
        #expect(InboundFrame(parsing: [0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFA, 0xFA]) == nil)
        // A supplemental size below the floor.
        #expect(InboundFrame(parsing: [0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0xFA, 0xFA]) == nil)
    }
}

// MARK: - Video, through the packetizer it has to survive

@Suite("DAVE over RTP")
struct DAVEVideoPathTests {
    /// A keyframe the way the send path assembles one: parameter sets first,
    /// then the picture, each behind a four-byte start code.
    private func frame(picture bytes: Int, seed: Int) -> (sets: [[UInt8]], units: [[UInt8]]) {
        let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1E, 0x8D, 0x8D, 0x40]
        let pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
        var idr: [UInt8] = [0x65, 0x88, 0x84]
        idr.append(contentsOf: (0..<bytes).map {
            UInt8(truncatingIfNeeded: $0 &* 13 &+ seed)
        })
        return ([sps, pps], [idr])
    }

    /// **The test the video path actually needed.** DAVE authenticates the whole
    /// Annex B frame, and between the two ends sit a packetizer that splits it
    /// into RTP payloads and a depacketizer that puts it back. If those two do
    /// not reproduce the sender's bytes exactly — start codes included — nothing
    /// decrypts, and the symptom is a camera that shows nothing at all.
    @Test("A frame survives encryption, packetization and reassembly")
    func roundTripThroughRTP() throws {
        let secret = [UInt8](repeating: 0x3C, count: 32)
        let encryptor = DAVEEncryptor()
        encryptor.setRatchet(MLSHashRatchet(baseSecret: secret))
        encryptor.setPassthrough(false)
        let decryptor = DAVEDecryptor(userID: 1)
        decryptor.transition(to: MLSHashRatchet(baseSecret: secret), retaining: 0)

        // Small enough for one packet, and large enough to be fragmented across
        // several — both shapes have to survive.
        for size in [200, 4_000] {
            let (sets, units) = frame(picture: size, seed: size)
            let original = H264.annexB(units: sets + units)
            let sealed = try #require(encryptor.encrypt(original, codec: .h264))

            let payloads = H264.packetize(
                nalUnits: H264.splitAnnexB(sealed), parameterSets: []
            )
            #expect(!payloads.isEmpty)

            let depacketizer = H264Depacketizer()
            var received: [[UInt8]]?
            for (index, payload) in payloads.enumerated() {
                let isLast = index == payloads.count - 1
                if let output = depacketizer.accept(
                    payload: payload,
                    sequence: UInt16(index),
                    marker: isLast,
                    isContiguous: true
                ) {
                    received = output.ordered
                }
            }

            let ordered = try #require(received, "the frame never completed at \(size) bytes")
            let rebuilt = H264.annexB(units: ordered)
            #expect(rebuilt == sealed, "reassembly did not reproduce the sent bytes")
            #expect(
                decryptor.decrypt(rebuilt, isAudio: false) == original,
                "the frame did not decrypt at \(size) bytes"
            )
        }
    }

    /// The depacketizer keeps the parameter sets aside for the decoder, so they
    /// have to still be in the ordered list the transform is rebuilt from.
    @Test("Reassembly keeps parameter sets in the frame, not only beside it")
    func orderedIncludesParameterSets() throws {
        let (sets, units) = frame(picture: 100, seed: 1)
        let payloads = H264.packetize(nalUnits: sets + units, parameterSets: [])
        let depacketizer = H264Depacketizer()
        var received: (units: [[UInt8]], ordered: [[UInt8]], isKeyframe: Bool)?
        for (index, payload) in payloads.enumerated() {
            if let output = depacketizer.accept(
                payload: payload,
                sequence: UInt16(index),
                marker: index == payloads.count - 1,
                isContiguous: true
            ) { received = output }
        }
        let output = try #require(received)
        #expect(output.ordered.count == 3, "SPS, PPS and the picture")
        #expect(output.units.count == 1, "only the picture reaches the decoder")
        #expect(depacketizer.parameterSets.count == 2)
        #expect(output.isKeyframe)
    }

    @Test("An Annex B frame splits back into exactly the units it was built from")
    func annexBRoundTrip() {
        let units: [[UInt8]] = [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5, 6, 7]]
        #expect(H264.splitAnnexB(H264.annexB(units: units)) == units)
        // A trailing footer with no start code of its own rides on the last unit,
        // which is exactly where DAVE puts its own.
        var withFooter = H264.annexB(units: units)
        withFooter.append(contentsOf: [0x11, 0x22, 0xFA, 0xFA])
        let split = H264.splitAnnexB(withFooter)
        #expect(split.count == units.count)
        #expect(split.last == units[2] + [0x11, 0x22, 0xFA, 0xFA])
    }
}
