import CryptoKit
import Foundation
import Synchronization

// MARK: - The per-frame transform
//
// Below MLS and above RTP. An encoded frame — one Opus packet, one H.264 access
// unit — goes in, and a frame with the same shape comes out: the parts the
// server has to read are still readable, everything that is media is
// ciphertext, and a footer says which is which.
//
//   ┌───────────────────────────────────────────────────────────────────┐
//   │ interleaved frame │ tag(8) │ nonce │ ranges │ size(1) │ 0xFAFA(2) │
//   └───────────────────────────────────────────────────────────────────┘
//
// The footer is read backwards from the end, because the frame in front of it
// is whatever length the codec produced:
//
// - **`0xFAFA`**, the last two bytes, is how a receiver tells a protocol frame
//   from a plain one at all.
// - **The supplemental size** is one byte covering everything except the frame
//   itself — tag, nonce, ranges, itself, and the marker.
// - **The unencrypted ranges** are offset/length pairs in ULEB128, ascending.
//   They are *not* authenticated, which is a known property of the protocol
//   rather than an oversight here: Trail of Bits reported it as TOB-DISCE2EC-7
//   and Discord accepted it to keep AES-GCM. It is why every bound below is
//   checked before it is used.
// - **The nonce** is a 32-bit counter, ULEB128 encoded. Its top byte is the
//   *generation*, which selects the key from the sender's ratchet — so the key
//   rolls forward every 2^24 frames without a single extra byte on the wire.
//
// The AEAD tag is truncated to 64 bits, which is what makes this affordable at
// fifty frames a second and is done within NIST SP 800-38D Appendix C's limits.

enum DAVE {
    /// The two bytes that end every protocol frame.
    static let magicMarker: [UInt8] = [0xFA, 0xFA]
    static let tagLength = 8
    static let nonceLength = 12
    /// The nonce actually on the wire, before it is widened.
    static let truncatedNonceLength = 4
    /// Tag, plus the size byte, plus the marker. The floor for any protocol
    /// frame's footer.
    static let minimumSupplementalBytes = tagLength + 1 + 2

    /// The top byte of the truncated nonce is the ratchet generation.
    static let generationShift: UInt32 = 8 * UInt32(truncatedNonceLength - 1)

    /// The SFU synthesises this exact three-byte packet for a muted source, and
    /// it is not a protocol frame. Letting it through is an explicit exception
    /// in the protocol — the alternative is a decoder fed a frame it cannot
    /// parse every time somebody mutes.
    static let opusSilence: [UInt8] = [0xF8, 0xFF, 0xFE]

    /// How long a key from a previous epoch or generation stays usable.
    ///
    /// Media in flight when the group changes epoch was encrypted under the old
    /// ratchet, and it arrives after the transition. Ten seconds is the window
    /// the protocol specifies for holding onto it.
    static let keyRetention: TimeInterval = 10

    /// How far ahead of the newest generation a frame may claim to be.
    static let maximumGenerationGap: UInt32 = 250
    /// How many out-of-order nonces are remembered so a reordered frame can
    /// still be accepted without opening a replay window.
    static let maximumMissingNonces = 1_000
}

// MARK: - ULEB128

/// Unsigned little-endian base 128, as WebRTC and DAVE both use it.
///
/// Chosen over a fixed width for two reasons the protocol states: it keeps the
/// footer small, and it avoids byte sequences that a codec's packetizer would
/// otherwise mistake for structure.
enum LEB128 {
    static func size(_ value: UInt64) -> Int {
        var size = 0
        var value = value
        while value >= 0x80 {
            size += 1
            value >>= 7
        }
        return size + 1
    }

    static func write(_ value: UInt64, into buffer: inout [UInt8]) {
        var value = value
        while value >= 0x80 {
            buffer.append(UInt8(0x80 | (value & 0x7F)))
            value >>= 7
        }
        buffer.append(UInt8(value))
    }

    /// Reads one value, advancing `index`. Returns `nil` on a truncated or
    /// over-long encoding rather than a partial value.
    static func read(_ bytes: [UInt8], _ index: inout Int, end: Int) -> UInt64? {
        var value: UInt64 = 0
        var shift = 0
        while index < end, shift < 64 - 7 {
            let byte = bytes[index]
            value |= UInt64(byte & 0x7F) << shift
            index += 1
            shift += 7
            if byte & 0x80 == 0 { return value }
        }
        // A tenth byte may only carry one more bit, or the value cannot fit.
        if index < end, bytes[index] <= 1 {
            value |= UInt64(bytes[index]) << shift
            index += 1
            return value
        }
        return nil
    }
}

// MARK: - Ranges

/// A stretch of the frame that stays in the clear.
struct ClearRange: Equatable {
    var offset: Int
    var size: Int
}

// MARK: - The AEAD, with a truncated tag
//
// CryptoKit will not open a box with a 64-bit tag — its API takes the whole
// 128-bit one — so decryption is done in two passes with primitives it does
// give us, rather than by hand-rolling GCM:
//
//   1. Sealing a run of zeros under the same key and nonce yields the raw
//      keystream, because GCM's ciphertext is the plaintext XORed with it. The
//      keystream depends on the key and nonce alone.
//   2. XOR the ciphertext with it to recover the plaintext, then seal *that*
//      with the real associated data. GCM computes its tag over the associated
//      data and the ciphertext, so the tag that comes back is the one the
//      sender computed — and the first eight bytes are compared against the
//      eight that arrived.
//
// This is not nonce reuse in the dangerous sense. Both operations reproduce the
// *same* keystream that already encrypted this one frame; nothing new is
// encrypted under it and nothing is transmitted.

enum DAVECipher {
    /// Seals `plaintext`, returning the ciphertext and an 8-byte tag.
    static func seal(
        plaintext: [UInt8], key: SymmetricKey, nonce: [UInt8], authenticating aad: [UInt8]
    ) throws -> (ciphertext: [UInt8], tag: [UInt8]) {
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: try AES.GCM.Nonce(data: nonce),
            authenticating: aad
        )
        return (Array(box.ciphertext), Array(box.tag.prefix(DAVE.tagLength)))
    }

    /// Opens a box whose tag was truncated to 64 bits, or returns `nil`.
    static func open(
        ciphertext: [UInt8],
        tag: ArraySlice<UInt8>,
        key: SymmetricKey,
        nonce: [UInt8],
        authenticating aad: [UInt8]
    ) -> [UInt8]? {
        guard tag.count == DAVE.tagLength,
              let gcmNonce = try? AES.GCM.Nonce(data: nonce)
        else { return nil }

        guard let keystream = try? AES.GCM.seal(
            [UInt8](repeating: 0, count: ciphertext.count), using: key, nonce: gcmNonce
        ).ciphertext else { return nil }

        var plaintext = ciphertext
        for index in plaintext.indices {
            plaintext[index] ^= keystream[keystream.index(keystream.startIndex, offsetBy: index)]
        }

        guard let box = try? AES.GCM.seal(
            plaintext, using: key, nonce: gcmNonce, authenticating: aad
        ) else { return nil }

        guard constantTimeEqual(Array(box.tag.prefix(DAVE.tagLength)), Array(tag)) else {
            return nil
        }
        return plaintext
    }
}

// MARK: - Widening the nonce

extension DAVE {
    /// The 96-bit nonce AES-GCM needs, from the 32 bits on the wire.
    ///
    /// The counter goes in the four **least significant** bytes — that is, the
    /// last four — and it is written little-endian, which is what Discord's own
    /// implementation does with a `memcpy` of a `uint32_t`. Writing it the other
    /// way round produces a nonce that is wrong in a way no test of your own
    /// client would ever catch, because both ends of your own call would agree.
    static func fullNonce(from truncated: UInt32) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: nonceLength)
        nonce[8] = UInt8(truncatingIfNeeded: truncated)
        nonce[9] = UInt8(truncatingIfNeeded: truncated >> 8)
        nonce[10] = UInt8(truncatingIfNeeded: truncated >> 16)
        nonce[11] = UInt8(truncatingIfNeeded: truncated >> 24)
        return nonce
    }

    static func generation(of nonce: UInt32) -> UInt32 { nonce >> generationShift }

    /// Rebuilds a monotonically increasing nonce across generation wraps, so a
    /// replay check can compare frames that straddle one.
    static func wrappedNonce(generation: UInt32, truncated: UInt32) -> UInt64 {
        let masked = UInt64(truncated & ((1 << generationShift) - 1))
        return UInt64(generation) << UInt64(generationShift) | masked
    }

    /// The generation a wrapped counter names, given the oldest one still held.
    ///
    /// The wire carries only the low byte, so after 2^32 frames in one epoch the
    /// counter wraps and the generation appears to go backwards. This maps the
    /// byte back onto the real sequence.
    static func wrappedGeneration(oldest: UInt32, generation: UInt32) -> UInt32 {
        let wrap: UInt32 = 1 << 8
        let remainder = oldest % wrap
        let factor = oldest / wrap + (generation < remainder ? 1 : 0)
        return factor * wrap + generation
    }
}

// MARK: - Building a frame

/// Splits an outgoing frame into the parts that stay clear and the parts that
/// get encrypted, and puts it back together afterwards.
///
/// Reused between frames rather than allocated per frame: this runs fifty times
/// a second for audio and up to sixty for video, and three array allocations a
/// frame is three thousand a minute for no reason.
struct OutboundFrame {
    private(set) var clearBytes: [UInt8] = []
    private(set) var mediaBytes: [UInt8] = []
    private(set) var ranges: [ClearRange] = []
    private var index = 0

    mutating func reset(capacity: Int) {
        clearBytes.removeAll(keepingCapacity: true)
        mediaBytes.removeAll(keepingCapacity: true)
        ranges.removeAll(keepingCapacity: true)
        clearBytes.reserveCapacity(capacity)
        mediaBytes.reserveCapacity(capacity)
        index = 0
    }

    mutating func addClear(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        // Adjacent clear stretches merge: two ranges where one would do costs
        // footer bytes on every frame for the rest of the call.
        if var last = ranges.last, last.offset + last.size == index {
            last.size += bytes.count
            ranges[ranges.count - 1] = last
        } else {
            ranges.append(ClearRange(offset: index, size: bytes.count))
        }
        clearBytes.append(contentsOf: bytes)
        index += bytes.count
    }

    mutating func addMedia(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        mediaBytes.append(contentsOf: bytes)
        index += bytes.count
    }

    var rangesSize: Int {
        ranges.reduce(0) { $0 + LEB128.size(UInt64($1.offset)) + LEB128.size(UInt64($1.size)) }
    }

    /// Interleaves the clear bytes and the ciphertext back into frame order.
    func reconstruct(ciphertext: [UInt8], into output: inout [UInt8]) {
        interleave(clear: clearBytes, media: ciphertext, ranges: ranges, into: &output)
    }
}

/// Rebuilds a frame from its two halves and the map of which is where.
///
/// One function for both directions: outbound it interleaves clear bytes with
/// ciphertext, inbound with plaintext, and getting the two subtly different
/// would mean a frame that encrypts correctly and decrypts to rubbish.
private func interleave(
    clear: [UInt8], media: [UInt8], ranges: [ClearRange], into output: inout [UInt8]
) {
    output.removeAll(keepingCapacity: true)
    output.reserveCapacity(clear.count + media.count)
    var clearIndex = 0
    var mediaIndex = 0
    for range in ranges {
        if range.offset > output.count {
            let run = min(range.offset - output.count, media.count - mediaIndex)
            guard run > 0 else { break }
            output.append(contentsOf: media[mediaIndex..<(mediaIndex + run)])
            mediaIndex += run
        }
        guard clearIndex + range.size <= clear.count else { break }
        output.append(contentsOf: clear[clearIndex..<(clearIndex + range.size)])
        clearIndex += range.size
    }
    if mediaIndex < media.count {
        output.append(contentsOf: media[mediaIndex...])
    }
}

// MARK: - Parsing a frame

/// The footer of an incoming frame, and the split into authenticated and
/// encrypted bytes that decryption needs.
struct InboundFrame {
    private(set) var truncatedNonce: UInt32 = 0
    private(set) var tag: ArraySlice<UInt8> = []
    private(set) var authenticated: [UInt8] = []
    private(set) var ciphertext: [UInt8] = []
    private(set) var ranges: [ClearRange] = []

    /// Reads the footer and splits the frame, or returns `nil` if this is not a
    /// protocol frame at all.
    ///
    /// **Every field is bounds-checked before it is used.** The ranges are not
    /// covered by the AEAD, so an attacker on the path can rewrite them; the
    /// protocol's own documentation names a crash here as the risk, and the
    /// answer is that nothing derived from them indexes anything unchecked.
    init?(parsing frame: [UInt8]) {
        guard frame.count >= DAVE.minimumSupplementalBytes else { return nil }
        guard frame[frame.count - 2] == DAVE.magicMarker[0],
              frame[frame.count - 1] == DAVE.magicMarker[1]
        else { return nil }

        let supplementalSize = Int(frame[frame.count - 3])
        guard supplementalSize >= DAVE.minimumSupplementalBytes,
              supplementalSize <= frame.count
        else { return nil }

        let footerStart = frame.count - supplementalSize
        tag = frame[footerStart..<(footerStart + DAVE.tagLength)]

        var cursor = footerStart + DAVE.tagLength
        let footerEnd = frame.count - 3
        guard let nonce = LEB128.read(frame, &cursor, end: footerEnd),
              nonce <= UInt64(UInt32.max)
        else { return nil }
        truncatedNonce = UInt32(nonce)

        // The rest of the footer, up to the size byte, is offset/length pairs.
        var parsed: [ClearRange] = []
        while cursor < footerEnd {
            guard let offset = LEB128.read(frame, &cursor, end: footerEnd),
                  let size = LEB128.read(frame, &cursor, end: footerEnd),
                  offset <= UInt64(Int.max), size <= UInt64(Int.max)
            else { return nil }
            parsed.append(ClearRange(offset: Int(offset), size: Int(size)))
        }
        guard cursor == footerEnd else { return nil }

        // Ascending, non-overlapping, and inside the frame — checked here so
        // that nothing below has to.
        let mediaSize = footerStart
        var reach = 0
        for range in parsed {
            guard range.offset >= reach, range.size >= 0 else { return nil }
            let (end, overflow) = range.offset.addingReportingOverflow(range.size)
            guard !overflow, end <= mediaSize else { return nil }
            reach = end
        }
        ranges = parsed

        authenticated.reserveCapacity(mediaSize)
        ciphertext.reserveCapacity(mediaSize)
        var position = 0
        for range in ranges {
            if range.offset > position {
                ciphertext.append(contentsOf: frame[position..<range.offset])
            }
            authenticated.append(contentsOf: frame[range.offset..<(range.offset + range.size)])
            position = range.offset + range.size
        }
        if position < mediaSize {
            ciphertext.append(contentsOf: frame[position..<mediaSize])
        }
    }

    /// Interleaves the decrypted media back among the bytes that were clear.
    func reconstruct(plaintext: [UInt8], into output: inout [UInt8]) {
        interleave(clear: authenticated, media: plaintext, ranges: ranges, into: &output)
    }
}
