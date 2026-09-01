import CryptoKit
import Foundation

// MARK: - The two AEAD modes Discord still accepts
//
// Every `xsalsa20_poly1305` mode was withdrawn in 2024. What is left is two
// modes with identical framing and different ciphers, and a client has to carry
// both: `aead_aes256_gcm_rtpsize` is offered only where the server believes the
// hardware has AES instructions, and `aead_xchacha20_poly1305_rtpsize` is the
// one every client must support.
//
// **The `_rtpsize` suffix is the whole of the framing and it is easy to get
// subtly wrong.** It does not mean "the header is twelve bytes". It means the
// clear prefix is *however long this packet's RTP header actually is* — twelve,
// plus four per CSRC, plus the four-byte extension preamble when the X bit is
// set — and that prefix is the additional authenticated data. A client that
// assumes twelve authenticates the wrong bytes the moment a header extension
// appears, which is every audio and video packet Discord sends.
//
//     [ RTP header + CSRCs + ext preamble ] [ ciphertext ‖ tag(16) ] [ nonce(4) ]
//
// **The extension BODY is inside the ciphertext, not the prefix.** SRTP leaves
// every extension in the clear; Discord begins encrypting straight after the
// four-byte `0xBEDE`-and-length preamble, so the elements themselves are
// encrypted and arrive at the front of the plaintext. Treating them as clear
// authenticates the wrong bytes on every packet that carries one — which is
// every audio packet Discord sends, in both directions at once.
//
// The trailing four bytes are a big-endian counter. It is *not* the nonce the
// cipher takes: it is zero-extended on the right to the cipher's width — twelve
// bytes for GCM, twenty-four for XChaCha20 — which is why the same counter can
// feed both.

public enum VoiceCipher: String, Sendable, CaseIterable {
    case aes256GCM = "aead_aes256_gcm_rtpsize"
    case xchacha20Poly1305 = "aead_xchacha20_poly1305_rtpsize"

    /// Preference order. AES-GCM first wherever it is offered: on Apple silicon
    /// it runs on the cryptographic extensions and costs a fraction of what the
    /// software XChaCha20 does, and at fifty packets a second per stream that is
    /// a difference worth having.
    ///
    /// The server publishes what it will accept in READY, so this is a filter
    /// over that list rather than a choice made blind.
    public static func best(from offered: [String]) -> VoiceCipher? {
        for candidate in [VoiceCipher.aes256GCM, .xchacha20Poly1305]
        where offered.contains(candidate.rawValue) {
            return candidate
        }
        return nil
    }

    /// The tag is appended to the ciphertext by both modes.
    public static let tagLength = 16
    /// The counter written after the tag.
    public static let nonceSuffixLength = 4
}

/// One connection's key, and the counter that must never repeat under it.
///
/// A `final class` rather than a struct: the counter is state shared by the
/// audio path and the video path, which are different threads sending under one
/// key, and a value type would give each of them a private copy and reuse
/// nonces across them. Reusing a nonce under GCM does not merely leak the
/// plaintext of two packets — it leaks the authentication subkey, and from
/// there anything the attacker likes. The increment is atomic for that reason
/// alone.
public final class VoiceSealer: Sendable {
    public let cipher: VoiceCipher
    private let key: SymmetricKey
    /// XChaCha20's per-packet subkey depends only on the first sixteen nonce
    /// bytes, and those are always zero here — the counter lands in the last
    /// eight. So the subkey is derived once for the connection rather than once
    /// per packet, which is what makes the software cipher affordable.
    private let chachaSubkey: SymmetricKey?
    private let counter: Counter

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt32 = 0

        func next() -> UInt32 {
            lock.lock()
            defer { lock.unlock() }
            value &+= 1
            return value
        }
    }

    public init(cipher: VoiceCipher, secretKey: [UInt8]) {
        self.cipher = cipher
        key = SymmetricKey(data: Data(secretKey))
        switch cipher {
        case .xchacha20Poly1305:
            chachaSubkey = SymmetricKey(data: Data(
                XChaCha20.subkey(key: secretKey, nonce16: [UInt8](repeating: 0, count: 16))
            ))
        case .aes256GCM:
            chachaSubkey = nil
        }
        counter = Counter()
    }

    /// Seals `payload` into a packet fronted by `header`, and returns the
    /// finished datagram.
    ///
    /// `header.clear` is both the packet's prefix and the AAD, so it is passed
    /// once and used twice — a signature that takes them separately is one
    /// where a caller can authenticate bytes it did not send.
    /// `header.encrypted` is the extension body, sealed ahead of the media
    /// because that is where Discord expects to find it.
    public func seal(payload: UnsafeRawBufferPointer, header: RTPHeaderBytes) throws -> Data {
        let count = counter.next()
        let clear = header.clear
        var packet = Data(capacity: clear.count + header.encrypted.count + payload.count + 20)
        packet.append(contentsOf: clear)

        // The extension body has to be contiguous with the media to be sealed
        // with it. Without an extension there is nothing to join and the
        // payload is sealed where it already lies.
        var joined: [UInt8]?
        if !header.encrypted.isEmpty {
            var buffer = header.encrypted
            buffer.append(contentsOf: payload)
            joined = buffer
        }

        switch cipher {
        case .aes256GCM:
            var nonce = [UInt8](repeating: 0, count: 12)
            writeCounter(count, into: &nonce)
            let box = try joined.map {
                try AES.GCM.seal(
                    $0, using: key,
                    nonce: try AES.GCM.Nonce(data: nonce), authenticating: clear
                )
            } ?? AES.GCM.seal(
                payload, using: key,
                nonce: try AES.GCM.Nonce(data: nonce), authenticating: clear
            )
            packet.append(box.ciphertext)
            packet.append(box.tag)

        case .xchacha20Poly1305:
            var tail = [UInt8](repeating: 0, count: 12)
            writeCounter(count, into: &tail[4...])
            let box = try joined.map {
                try ChaChaPoly.seal(
                    $0, using: chachaSubkey!,
                    nonce: try ChaChaPoly.Nonce(data: tail), authenticating: clear
                )
            } ?? ChaChaPoly.seal(
                payload, using: chachaSubkey!,
                nonce: try ChaChaPoly.Nonce(data: tail), authenticating: clear
            )
            packet.append(box.ciphertext)
            packet.append(box.tag)
        }

        withUnsafeBytes(of: count.bigEndian) { packet.append(contentsOf: $0) }
        return packet
    }

    /// Opens a received datagram. `headerLength` is what
    /// `RTPHeader.clearPrefixLength` computed off the packet's own bits.
    ///
    /// Returns nil rather than throwing on a packet that does not authenticate.
    /// A voice stream carries forged and replayed packets as a matter of course
    /// on a busy channel, and a throw per bad packet is a diagnostic that costs
    /// more than the packet did.
    public func open(_ packet: [UInt8], headerLength: Int) -> [UInt8]? {
        let suffix = VoiceCipher.nonceSuffixLength
        let minimum = headerLength + VoiceCipher.tagLength + suffix
        guard packet.count >= minimum else { return nil }

        let bodyEnd = packet.count - suffix
        let header = Array(packet[0..<headerLength])
        let count = UInt32(packet[bodyEnd]) << 24
            | UInt32(packet[bodyEnd + 1]) << 16
            | UInt32(packet[bodyEnd + 2]) << 8
            | UInt32(packet[bodyEnd + 3])
        let sealed = Array(packet[headerLength..<bodyEnd])

        do {
            switch cipher {
            case .aes256GCM:
                var nonce = [UInt8](repeating: 0, count: 12)
                writeCounter(count, into: &nonce)
                let box = try AES.GCM.SealedBox(
                    nonce: try AES.GCM.Nonce(data: nonce),
                    ciphertext: sealed.dropLast(VoiceCipher.tagLength),
                    tag: sealed.suffix(VoiceCipher.tagLength)
                )
                return try [UInt8](AES.GCM.open(box, using: key, authenticating: header))

            case .xchacha20Poly1305:
                var tail = [UInt8](repeating: 0, count: 12)
                writeCounter(count, into: &tail[4...])
                let box = try ChaChaPoly.SealedBox(
                    nonce: try ChaChaPoly.Nonce(data: tail),
                    ciphertext: sealed.dropLast(VoiceCipher.tagLength),
                    tag: sealed.suffix(VoiceCipher.tagLength)
                )
                return try [UInt8](
                    ChaChaPoly.open(box, using: chachaSubkey!, authenticating: header)
                )
            }
        } catch {
            return nil
        }
    }

    private func writeCounter(_ value: UInt32, into buffer: inout [UInt8]) {
        buffer[0] = UInt8(truncatingIfNeeded: value >> 24)
        buffer[1] = UInt8(truncatingIfNeeded: value >> 16)
        buffer[2] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[3] = UInt8(truncatingIfNeeded: value)
    }

    private func writeCounter(
        _ value: UInt32,
        into slice: inout ArraySlice<UInt8>
    ) {
        let base = slice.startIndex
        slice[base] = UInt8(truncatingIfNeeded: value >> 24)
        slice[base + 1] = UInt8(truncatingIfNeeded: value >> 16)
        slice[base + 2] = UInt8(truncatingIfNeeded: value >> 8)
        slice[base + 3] = UInt8(truncatingIfNeeded: value)
    }
}

// MARK: - HChaCha20

/// The one primitive CryptoKit does not ship.
///
/// `ChaChaPoly` is the IETF construction: a 96-bit nonce and nothing else.
/// XChaCha20-Poly1305 is that same construction under a *derived* key — HChaCha20
/// of the real key and the nonce's first sixteen bytes — with the remaining
/// eight nonce bytes moved into the IETF nonce's low half. So the whole of the
/// extension is twenty lines of the ChaCha20 core with the feed-forward
/// addition left out, and the rest is CryptoKit's.
///
/// Checked against the vector in draft-irtf-cfrg-xchacha §2.2.1.
enum XChaCha20 {
    static func subkey(key: [UInt8], nonce16: [UInt8]) -> [UInt8] {
        precondition(key.count == 32 && nonce16.count == 16)

        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x6170_7865
        state[1] = 0x3320_646E
        state[2] = 0x7962_2D32
        state[3] = 0x6B20_6574
        for index in 0..<8 { state[4 + index] = load32(key, at: index * 4) }
        for index in 0..<4 { state[12 + index] = load32(nonce16, at: index * 4) }

        for _ in 0..<10 {
            quarter(&state, 0, 4, 8, 12)
            quarter(&state, 1, 5, 9, 13)
            quarter(&state, 2, 6, 10, 14)
            quarter(&state, 3, 7, 11, 15)
            quarter(&state, 0, 5, 10, 15)
            quarter(&state, 1, 6, 11, 12)
            quarter(&state, 2, 7, 8, 13)
            quarter(&state, 3, 4, 9, 14)
        }

        // The first and last rows of the final state, and no feed-forward. That
        // omission is the entire difference from ChaCha20's block function, and
        // it is what makes the result a key rather than a keystream.
        var out = [UInt8]()
        out.reserveCapacity(32)
        for index in [0, 1, 2, 3, 12, 13, 14, 15] { store32(state[index], into: &out) }
        return out
    }

    private static func quarter(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] &+= s[b]; s[d] = rotate(s[d] ^ s[a], 16)
        s[c] &+= s[d]; s[b] = rotate(s[b] ^ s[c], 12)
        s[a] &+= s[b]; s[d] = rotate(s[d] ^ s[a], 8)
        s[c] &+= s[d]; s[b] = rotate(s[b] ^ s[c], 7)
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    private static func load32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func store32(_ value: UInt32, into bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
