import Foundation
import Testing
@testable import WingcordVoice

@Suite("Voice crypto")
struct VoiceCryptoTests {

    /// draft-irtf-cfrg-xchacha §2.2.1. The one published vector for HChaCha20,
    /// and the only way to know the derivation is right rather than merely
    /// self-consistent — a wrong subkey round-trips perfectly against itself.
    @Test func hChaCha20MatchesTheDraftVector() {
        let key: [UInt8] = (0...31).map { UInt8(0x00 + $0) }
        let nonce: [UInt8] = [
            0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x4a,
            0x00, 0x00, 0x00, 0x00, 0x31, 0x41, 0x59, 0x27,
        ]
        let expected: [UInt8] = [
            0x82, 0x41, 0x3b, 0x42, 0x27, 0xb2, 0x7b, 0xfe,
            0xd3, 0x0e, 0x42, 0x50, 0x8a, 0x87, 0x7d, 0x73,
            0xa0, 0xf9, 0xe4, 0xd5, 0x8a, 0x74, 0xa8, 0x53,
            0xc1, 0x2e, 0xc4, 0x13, 0x26, 0xd3, 0xec, 0xdc,
        ]
        #expect(XChaCha20.subkey(key: key, nonce16: nonce) == expected)
    }

    @Test(arguments: VoiceCipher.allCases)
    func sealAndOpenRoundTrip(cipher: VoiceCipher) throws {
        let sealer = VoiceSealer(cipher: cipher, secretKey: Array(repeating: 7, count: 32))
        var writer = RTPWriter(ssrc: 0xDEAD_BEEF, payloadType: RTP.PayloadType.opus)
        let header = writer.next(advancingClockBy: 960)
        let payload: [UInt8] = Array("the quick brown fox".utf8)

        let packet = try payload.withUnsafeBytes { try sealer.seal(payload: $0, header: header) }
        let bytes = [UInt8](packet)
        let parsed = try #require(RTPHeader(parsing: bytes))
        #expect(parsed.clearPrefixLength == RTP.headerLength)
        #expect(sealer.open(bytes, headerLength: parsed.clearPrefixLength) == payload)
    }

    /// The `_rtpsize` rule, and the half of it that is not SRTP's: the clear
    /// prefix is however long the header really is **up to and including the
    /// four-byte extension preamble, and no further**. Discord encrypts the
    /// extension elements themselves, so they come back at the front of the
    /// plaintext and the media begins after them.
    ///
    /// This test asserted the opposite until a live call proved it wrong —
    /// every inbound packet failed to open and every outbound one was
    /// unreadable to Discord, in a call whose handshake was otherwise perfect.
    @Test func theExtensionPreambleIsClearAndItsElementsAreNot() throws {
        let sealer = VoiceSealer(cipher: .aes256GCM, secretKey: Array(repeating: 3, count: 32))
        var writer = RTPWriter(ssrc: 42, payloadType: RTP.PayloadType.opus)
        let header = writer.next(
            advancingClockBy: 960,
            extensions: RTPExtension.audioLevel(id: 1, dBov: 30, isVoice: true)
        )
        let payload: [UInt8] = [1, 2, 3, 4, 5]
        let packet = [UInt8](
            try payload.withUnsafeBytes { try sealer.seal(payload: $0, header: header) }
        )

        let parsed = try #require(RTPHeader(parsing: packet))
        #expect(parsed.clearPrefixLength == RTP.headerLength + 4)
        #expect(parsed.extensionBodyLength == 4)

        // What comes back is the extension body followed by the media, which is
        // exactly what the receive path has to skip past.
        let opened = try #require(
            sealer.open(packet, headerLength: parsed.clearPrefixLength)
        )
        #expect(opened == header.encrypted + payload)
        #expect(Array(opened.dropFirst(parsed.extensionBodyLength)) == payload)

        // The elements are genuinely ciphertext on the wire: the plaintext
        // element bytes must not appear after the preamble.
        #expect(Array(packet[16..<20]) != header.encrypted)

        // The same packet opened against the old, too-long prefix must fail.
        #expect(sealer.open(packet, headerLength: RTP.headerLength + 8) == nil)
    }

    @Test func aTamperedPacketDoesNotOpen() throws {
        let sealer = VoiceSealer(cipher: .xchacha20Poly1305, secretKey: Array(repeating: 9, count: 32))
        var writer = RTPWriter(ssrc: 1, payloadType: RTP.PayloadType.opus)
        let header = writer.next(advancingClockBy: 960)
        var packet = [UInt8](
            try [UInt8]([9, 9, 9, 9]).withUnsafeBytes {
                try sealer.seal(payload: $0, header: header)
            }
        )
        packet[RTP.headerLength] ^= 0xFF
        #expect(sealer.open(packet, headerLength: RTP.headerLength) == nil)
    }

    @Test func cipherPreferenceTakesAESWhenOffered() {
        #expect(VoiceCipher.best(from: [
            "aead_aes256_gcm_rtpsize", "aead_xchacha20_poly1305_rtpsize",
        ]) == .aes256GCM)
        #expect(VoiceCipher.best(from: ["aead_xchacha20_poly1305_rtpsize"])
            == .xchacha20Poly1305)
        #expect(VoiceCipher.best(from: ["xsalsa20_poly1305"]) == nil)
    }
}
