import Foundation

// MARK: - Which bytes a codec cannot afford to have encrypted
//
// **The encryptor is codec-aware; the decryptor is not.** That asymmetry is the
// whole design: the footer says which bytes were left clear, so a receiver never
// has to know what codec it is looking at, and Discord can change how a codec is
// handled without a protocol version bump.
//
// What has to stay readable is exactly what the SFU's packetizer and
// depacketizer read to split a frame into RTP packets and put it back together.
// Everything else — every byte that is actually picture or sound — is encrypted.
// Getting this wrong in the safe direction costs interoperability; getting it
// wrong in the other direction leaks media, which is why the rule is "encrypt
// everything unless the packetizer provably reads it".

enum DAVECodecKind {
    case opus
    case h264
    /// Anything this client does not have a rule for. Encrypted whole, which is
    /// the only safe default.
    case unknown
}

enum DAVECodec {
    /// Splits a frame into the ranges that stay clear and the ranges that do not.
    static func process(_ frame: [UInt8], codec: DAVECodecKind, into out: inout OutboundFrame) {
        out.reset(capacity: frame.count)
        switch codec {
        case .opus:
            // **Opus is encrypted whole.** It carries no header the packetizer
            // reads: one Opus packet is one RTP payload, and the TOC byte is
            // for the decoder, not the router. An earlier note in this project
            // said the TOC byte stays in the clear — it does not, and leaving
            // it out would leak the bandwidth, frame size and channel count of
            // every packet for nothing.
            out.addMedia(frame[...])
        case .h264:
            guard processH264(frame, into: &out) else {
                out.reset(capacity: frame.count)
                out.addMedia(frame[...])
                return
            }
        case .unknown:
            out.addMedia(frame[...])
        }
    }

    // MARK: H.264

    static let longStartCode: [UInt8] = [0, 0, 0, 1]

    /// The index just past the next start code, and how long that start code
    /// was, searching from `start`.
    static func nextNALU(_ bytes: [UInt8], from start: Int) -> (index: Int, codeLength: Int)? {
        guard bytes.count >= 3 else { return nil }
        var index = start
        while index < bytes.count - 3 {
            if bytes[index + 2] > 1 {
                index += 3
            } else if bytes[index + 2] == 1 {
                if bytes[index + 1] == 0, bytes[index] == 0 {
                    let naluStart = index + 3
                    if index >= 1, bytes[index - 1] == 0 {
                        return (naluStart, 4)
                    }
                    return (naluStart, 3)
                }
                index += 3
            } else {
                index += 1
            }
        }
        return nil
    }

    /// How many bytes of a slice payload cover the three exponential-Golomb
    /// values the depacketizer reads: `first_mb_in_slice`, `sps_id`, `pps_id`.
    ///
    /// The depacketizer needs the picture parameter set id to reassemble the
    /// frame, and it sits behind two other variable-length fields — so the only
    /// way to know how much to leave clear is to parse them. RBSP emulation
    /// prevention bytes are skipped, because they are not part of the value.
    static func bytesCoveringPPS(_ payload: ArraySlice<UInt8>) -> Int {
        let emulationPrevention: UInt8 = 0x03
        var bitIndex = 0
        var zeroBits = 0
        var parsed = 0
        let base = payload.startIndex
        let bitCount = payload.count * 8

        while bitIndex < bitCount, parsed < 3 {
            let bit = bitIndex % 8
            let byteIndex = bitIndex / 8
            let byte = payload[base + byteIndex]

            if bit == 0, byteIndex >= 2, byte == emulationPrevention,
               payload[base + byteIndex - 1] == 0, payload[base + byteIndex - 2] == 0 {
                bitIndex += 8
                continue
            }

            if byte & (1 << (7 - bit)) == 0 {
                zeroBits += 1
                bitIndex += 1
                // An exp-Golomb value with 32 leading zeros is not a value, it
                // is a malformed frame — and the answer to one of those is to
                // encrypt the whole thing.
                if zeroBits >= 32 { return 0 }
            } else {
                parsed += 1
                bitIndex += 1 + zeroBits
                zeroBits = 0
            }
        }
        return bitIndex / 8 + 1
    }

    private static func processH264(_ frame: [UInt8], into out: inout OutboundFrame) -> Bool {
        let naluHeaderSize = 1
        let typeMask: UInt8 = 0x1F
        let slice: UInt8 = 1
        let idr: UInt8 = 5

        guard frame.count >= 3 + naluHeaderSize else { return false }
        guard var current = nextNALU(frame, from: 0) else { return false }

        while current.index < frame.count - 1 {
            let start = current.index
            let type = frame[start] & typeMask

            // **Always a four-byte start code.** The receiving depacketizer
            // rewrites three-byte codes to four, which would shift every offset
            // in the footer and change the authenticated bytes. Emitting the
            // long form here means what the receiver reconstructs is byte for
            // byte what was authenticated.
            out.addClear(longStartCode[...])

            let next = nextNALU(frame, from: start)
            let end = next.map { $0.index - $0.codeLength } ?? frame.count

            if type == slice || type == idr {
                // A picture: only enough of the header to reach the PPS id.
                let payloadStart = start + naluHeaderSize
                guard payloadStart <= end else { return false }
                let ppsBytes = bytesCoveringPPS(frame[payloadStart..<frame.count])
                let clearEnd = payloadStart + ppsBytes
                guard clearEnd <= end else { return false }
                out.addClear(frame[start..<clearEnd])
                out.addMedia(frame[clearEnd..<end])
            } else {
                // Parameter sets and the like: metadata the depacketizer reads
                // in full, and no picture data at all.
                out.addClear(frame[start..<end])
            }

            guard let next else { break }
            current = next
        }
        return true
    }

    /// Whether an encrypted H.264 frame is safe to send.
    ///
    /// A start code that appears *inside* the ciphertext would be read by the
    /// packetizer as a NAL boundary, and the frame the receiver reassembles
    /// would be shifted — so it would fail to decrypt, every time, for as long
    /// as that ciphertext kept turning up. The protocol's answer is to bump the
    /// nonce and encrypt again, which changes every ciphertext byte.
    static func encryptedFrameIsSafe(
        _ frame: [UInt8], ranges: [ClearRange], codec: DAVECodecKind
    ) -> Bool {
        guard codec == .h264 else { return true }
        // Two bytes either side, because a start code can straddle the seam
        // between a clear range and the ciphertext next to it.
        let padding = 2
        var encryptedStart = 0
        for range in ranges {
            if encryptedStart == range.offset {
                encryptedStart += range.size
                continue
            }
            let start = encryptedStart - min(encryptedStart, padding)
            let end = min(range.offset + padding, frame.count)
            if start < end, nextNALU(Array(frame[start..<end]), from: 0) != nil { return false }
            encryptedStart = range.offset + range.size
        }
        guard encryptedStart != frame.count else { return true }
        let start = encryptedStart - min(encryptedStart, padding)
        if start < frame.count, nextNALU(Array(frame[start...]), from: 0) != nil { return false }
        return true
    }
}
