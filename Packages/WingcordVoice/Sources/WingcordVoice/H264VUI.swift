import Foundation

// MARK: - The SPS a WebRTC receiver keeps
//
// **A WebRTC receiver rewrites any SPS it does not like, and it does so before
// DAVE sees the frame.** `RtpDepacketizerH264` runs `SpsVuiRewriter` on every
// SPS that arrives: one with no VUI, a VUI without a bitstream restriction, or
// a restriction allowing reordering or more decode buffering than there are
// reference frames comes out with the VUI added or fixed. DAVE leaves the
// parameter sets in the clear but authenticates them, so a rewritten SPS is a
// keyframe whose tag no longer matches. Every keyframe is dropped, the far end
// asks for another every few hundred milliseconds, and Discord gives up with
// error 2012 while every counter on this end reads healthy.
//
// WebRTC's own sender never trips it because it runs the same rewriter over
// the encoder's output (`FrameEncodeMetadataWriter`) before the frame
// transformer encrypts. VideoToolbox writes no VUI at all, so this is that
// pass: the SPS leaves in the form a receiver keeps, byte for byte.
//
// A port of `SpsVuiRewriter::ParseAndRewriteSps` with no colour space — the
// argument WebRTC's receiver passes — over `SpsParser::ParseSpsUpToVui`, down to
// where each one gives up. `SPSVUITests` holds it to WebRTC's own C++ on every
// SPS VideoToolbox produces and on a fuzzed corpus.

extension H264 {
    /// What WebRTC's rewriter makes of one SPS.
    enum VUIVerdict: Equatable {
        /// Already what a receiver wants: it passes through untouched.
        case kept
        /// The SPS a receiver substitutes, header byte included.
        case rewritten([UInt8])
        /// Not an SPS the parser can read. WebRTC passes these through as
        /// they are, and so does this.
        case unparseable
    }

    /// The verdict a WebRTC receiver reaches on `unit`, a whole SPS NAL unit.
    static func vuiVerdict(forSPS unit: [UInt8]) -> VUIVerdict {
        guard unit.count > 1 else { return .unparseable }
        let rbsp = unescapedRBSP(unit[1...])
        var source = SPSBitReader(rbsp)
        guard let sps = SPSHead.parse(&source) else { return .unparseable }

        // Everything the parser read is copied as it was, except its last bit:
        // `vui_parameters_present_flag`, which the VUI copy writes again.
        var output = SPSBitWriter()
        output.append(rbsp, bitCount: source.consumedBits - 1)

        let copy = copyVUI(of: sps, from: &source, into: &output)
        guard copy.isValid else { return .unparseable }
        guard copy.isRewritten else { return .kept }

        while source.remaining > 0 { output.write(UInt64(source.bit()), bits: 1) }
        output.padToByte()

        var rewritten = [unit[0]]
        appendEscaped(output.bytes, to: &rewritten)
        return .rewritten(rewritten)
    }

    /// `unit` as it should leave: an SPS a receiver would rewrite comes back
    /// rewritten, and anything else comes back untouched.
    public static func receiverStableSPS(_ unit: [UInt8]) -> [UInt8] {
        guard unit.first.map({ $0 & 0x1F }) == NALType.sps.rawValue,
              case .rewritten(let sps) = vuiVerdict(forSPS: unit)
        else { return unit }
        return sps
    }

    // MARK: The VUI

    /// `CopyAndRewriteVui`. A missing VUI is written fresh with nothing in it
    /// but the restriction; a present one is copied field by field and only
    /// its restriction is replaced.
    private static func copyVUI(
        of sps: SPSHead, from source: inout SPSBitReader, into output: inout SPSBitWriter
    ) -> (isValid: Bool, isRewritten: Bool) {
        output.write(1, bits: 1)                    // vui_parameters_present_flag
        guard sps.hasVUI else {
            output.write(0, bits: 2)                // aspect ratio, overscan
            output.write(0, bits: 1)                // video signal type
            output.write(0, bits: 5)                // chroma loc, timing, both HRDs, pic_struct
            output.write(1, bits: 1)                // bitstream_restriction_flag
            appendBitstreamRestriction(to: &output, referenceFrames: sps.referenceFrames)
            return (true, true)
        }

        func copy(_ count: Int) -> UInt64 {
            let value = source.bits(count)
            output.write(value, bits: count)
            return value
        }
        func copyGolomb() -> UInt32 {
            let value = source.golomb()
            output.writeGolomb(value)
            return value
        }
        /// `CopyHrdParameters`. The loop stops as soon as the reader runs
        /// dry, because a count read from a corrupt SPS can be four billion.
        func copyHRD() {
            let lastIndex = UInt64(copyGolomb())    // cpb_cnt_minus1
            _ = copy(8)                             // bit_rate_scale, cpb_size_scale
            var index: UInt64 = 0
            while source.isValid, index <= lastIndex {
                _ = copyGolomb()                    // bit_rate_value_minus1
                _ = copyGolomb()                    // cpb_size_value_minus1
                _ = copy(1)                         // cbr_flag
                index += 1
            }
            _ = copy(20)                            // four delay and offset lengths
        }

        if copy(1) == 1, copy(8) == 255 { _ = copy(32) }        // aspect ratio, extended SAR
        if copy(1) == 1 { _ = copy(1) }                          // overscan
        // Video signal type. With no colour space WebRTC writes back exactly
        // what it read: the flag, then format, range and the colour
        // description flag, then the three colour bytes when that flag is set.
        if copy(1) == 1, copy(5) & 1 == 1 { _ = copy(24) }
        if copy(1) == 1 { _ = copyGolomb(); _ = copyGolomb() }    // chroma sample location
        if copy(1) == 1 { _ = copy(32); _ = copy(32); _ = copy(1) } // timing
        let nalHRD = copy(1)
        if nalHRD == 1 { copyHRD() }
        let vclHRD = copy(1)
        if vclHRD == 1 { copyHRD() }
        if nalHRD == 1 || vclHRD == 1 { _ = copy(1) }            // low_delay_hrd_flag
        _ = copy(1)                                              // pic_struct_present_flag

        // The restriction is read, never copied: it is the field being fixed.
        let hasRestriction = source.bit()
        output.write(1, bits: 1)
        guard hasRestriction == 1 else {
            appendBitstreamRestriction(to: &output, referenceFrames: sps.referenceFrames)
            return (source.isValid, true)
        }
        _ = copy(1)                                 // motion_vectors_over_pic_boundaries_flag
        for _ in 0..<4 { _ = copyGolomb() }         // bytes/pic, bits/mb, both mv lengths
        let reorderFrames = source.golomb()
        let decodeBuffering = source.golomb()
        output.writeGolomb(0)
        output.writeGolomb(sps.referenceFrames)
        let isRewritten = reorderFrames != 0 || decodeBuffering > sps.referenceFrames
        return (source.isValid, isRewritten)
    }

    /// `AddBitstreamRestriction`: the defaults the standard implies when the
    /// fields are absent, then no reordering and no more decode buffering than
    /// the stream has reference frames.
    private static func appendBitstreamRestriction(
        to output: inout SPSBitWriter, referenceFrames: UInt32
    ) {
        output.write(1, bits: 1)                    // motion_vectors_over_pic_boundaries_flag
        output.writeGolomb(2)                       // max_bytes_per_pic_denom
        output.writeGolomb(1)                       // max_bits_per_mb_denom
        output.writeGolomb(16)                      // log2_max_mv_length_horizontal
        output.writeGolomb(16)                      // log2_max_mv_length_vertical
        output.writeGolomb(0)                       // max_num_reorder_frames
        output.writeGolomb(referenceFrames)         // max_dec_frame_buffering
    }

    // MARK: Emulation prevention

    /// `H264::ParseRbsp`: every `00 00 03` loses its `03`.
    static func unescapedRBSP(_ payload: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(payload.count)
        var index = payload.startIndex
        while index < payload.endIndex {
            if payload.endIndex - index >= 3, payload[index] == 0,
               payload[index + 1] == 0, payload[index + 2] == 3 {
                out.append(0)
                out.append(0)
                index += 3
            } else {
                out.append(payload[index])
                index += 1
            }
        }
        return out
    }

    /// `H264::WriteRbsp`: a `03` goes in wherever two zeros are followed by a
    /// byte a start code could begin with.
    static func appendEscaped(_ rbsp: [UInt8], to out: inout [UInt8]) {
        var zeros = 0
        for byte in rbsp {
            if byte <= 3, zeros >= 2 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
    }
}

// MARK: - Reading as far as the VUI

/// `SpsParser::ParseSpsUpToVui`: the two fields the rewrite needs, and every
/// reason WebRTC gives for refusing an SPS outright.
private struct SPSHead {
    var referenceFrames: UInt32
    var hasVUI: Bool

    /// Profiles whose SPS carries chroma format and bit depth fields.
    private static let chromaProfiles: Set<UInt64> = [
        100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134,
    ]

    static func parse(_ reader: inout SPSBitReader) -> SPSHead? {
        let profile = reader.bits(8)
        _ = reader.bits(16)                         // constraint flags, level_idc
        let id = reader.golomb()
        guard reader.isValid, id <= 31 else { return nil }

        var chromaFormat: UInt32 = 1
        var separateColourPlanes: UInt32 = 0
        if chromaProfiles.contains(profile) {
            chromaFormat = reader.golomb()
            guard reader.isValid, chromaFormat <= 3 else { return nil }
            if chromaFormat == 3 { separateColourPlanes = reader.bit() }
            _ = reader.golomb()                     // bit_depth_luma_minus8
            _ = reader.golomb()                     // bit_depth_chroma_minus8
            _ = reader.bits(1)                      // qpprime_y_zero_transform_bypass_flag
            if reader.bit() != 0 {                  // seq_scaling_matrix_present_flag
                for list in 0..<(chromaFormat == 3 ? 12 : 8) where reader.bit() != 0 {
                    var last = 8
                    var next = 8
                    for _ in 0..<(list < 6 ? 16 : 64) {
                        if next != 0 {
                            let delta = reader.signedGolomb()
                            guard reader.isValid, (-128...127).contains(delta) else { return nil }
                            next = (last + Int(delta) + 256) % 256
                        }
                        if next != 0 { last = next }
                    }
                }
            }
        }

        let log2MaxFrameNumberMinus4 = reader.golomb()
        guard reader.isValid, log2MaxFrameNumberMinus4 <= 12 else { return nil }
        let pictureOrderType = reader.golomb()
        guard reader.isValid, pictureOrderType <= 2 else { return nil }
        if pictureOrderType == 0 {
            let log2MaxOrderLSBMinus4 = reader.golomb()
            guard reader.isValid, log2MaxOrderLSBMinus4 <= 12 else { return nil }
        } else if pictureOrderType == 1 {
            _ = reader.bit()                        // delta_pic_order_always_zero_flag
            _ = reader.golomb()                     // offset_for_non_ref_pic
            _ = reader.golomb()                     // offset_for_top_to_bottom_field
            let cycle = reader.golomb()
            var index: UInt32 = 0
            while index < cycle {
                _ = reader.golomb()                 // offset_for_ref_frame
                guard reader.isValid else { return nil }
                index += 1
            }
        }

        let referenceFrames = reader.golomb()
        _ = reader.bits(1)                          // gaps_in_frame_num_value_allowed_flag
        let widthInMacroblocksMinus1 = reader.golomb()
        let heightInMapUnitsMinus1 = reader.golomb()
        let frameMacroblocksOnly = reader.bit()
        if frameMacroblocksOnly == 0 { _ = reader.bits(1) }  // mb_adaptive_frame_field_flag
        _ = reader.bits(1)                          // direct_8x8_inference_flag
        var cropLeft: UInt32 = 0
        var cropRight: UInt32 = 0
        var cropTop: UInt32 = 0
        var cropBottom: UInt32 = 0
        if reader.bit() != 0 {
            cropLeft = reader.golomb()
            cropRight = reader.golomb()
            cropTop = reader.golomb()
            cropBottom = reader.golomb()
        }
        let hasVUI = reader.bit() == 1
        guard reader.isValid else { return nil }

        let uncroppedWidth = 16 * (Int64(widthInMacroblocksMinus1) + 1)
        let uncroppedHeight = 16 * (2 - Int64(frameMacroblocksOnly))
            * (Int64(heightInMapUnitsMinus1) + 1)
        guard isValidResolution(width: uncroppedWidth, height: uncroppedHeight) else { return nil }

        var subWidth: Int64 = 1
        var subHeight: Int64 = 1
        if separateColourPlanes == 0, chromaFormat > 0 {
            if chromaFormat == 1 {
                subWidth = 2
                subHeight = 2
            } else if chromaFormat == 2 {
                subWidth = 2
            }
        }
        let cropX = subWidth * (Int64(cropLeft) + Int64(cropRight))
        let cropY = subHeight * (2 - Int64(frameMacroblocksOnly))
            * (Int64(cropTop) + Int64(cropBottom))
        guard cropX < uncroppedWidth, cropY < uncroppedHeight else { return nil }

        return SPSHead(referenceFrames: referenceFrames, hasVUI: hasVUI)
    }

    /// `H264::IsValidResolution`: level 5.2's limits.
    private static func isValidResolution(width: Int64, height: Int64) -> Bool {
        let maximumDimension: Int64 = 543 * 16
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension
        else { return false }
        return ((width + 15) / 16) * ((height + 15) / 16) <= 36_864
    }
}

// MARK: - Bits

/// WebRTC's `BitstreamReader`, including how it fails: a read past the end
/// returns zero and leaves the reader invalid, and nothing that follows can
/// make it valid again.
private struct SPSBitReader {
    private let bytes: [UInt8]
    private var position = 0
    /// Bits left to read. Negative once a read has run past the end.
    private(set) var remaining: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        remaining = bytes.count * 8
    }

    var isValid: Bool { remaining >= 0 }
    var consumedBits: Int { bytes.count * 8 - remaining }

    mutating func bit() -> UInt32 {
        remaining -= 1
        guard remaining >= 0 else { return 0 }
        let value = bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1
        position += 1
        return UInt32(value)
    }

    mutating func bits(_ count: Int) -> UInt64 {
        guard count <= remaining else {
            remaining = -1
            return 0
        }
        var value: UInt64 = 0
        for _ in 0..<count { value = value << 1 | UInt64(bit()) }
        return value
    }

    /// `ue(v)`. Thirty-two leading zeros is not a value that fits, so it is
    /// a failure rather than an overflow.
    mutating func golomb() -> UInt32 {
        var zeros = 0
        while bit() == 0 {
            zeros += 1
            if zeros >= 32 {
                remaining = -1
                return 0
            }
        }
        return UInt32(truncatingIfNeeded: (UInt64(1) << zeros) + bits(zeros) - 1)
    }

    /// `se(v)`.
    mutating func signedGolomb() -> Int64 {
        let value = Int64(golomb())
        return value & 1 == 0 ? -(value / 2) : (value + 1) / 2
    }
}

/// WebRTC's `BitBufferWriter`, growing rather than bounded: nothing a
/// readable SPS produces comes near the bound WebRTC gives it.
private struct SPSBitWriter {
    private(set) var bytes: [UInt8] = []
    private var count = 0

    /// The first `bitCount` bits of `source`, verbatim.
    mutating func append(_ source: [UInt8], bitCount: Int) {
        bytes = Array(source.prefix((bitCount + 7) / 8))
        count = bitCount
        if count & 7 != 0 { bytes[bytes.count - 1] &= ~(0xFF >> UInt8(count & 7)) }
    }

    /// The low `bits` bits of `value`, most significant first.
    mutating func write(_ value: UInt64, bits: Int) {
        for shift in stride(from: bits - 1, through: 0, by: -1) {
            if count & 7 == 0 { bytes.append(0) }
            if value >> UInt64(shift) & 1 == 1 {
                bytes[bytes.count - 1] |= 0x80 >> UInt8(count & 7)
            }
            count += 1
        }
    }

    /// `ue(v)`: as many zeros as the value plus one has bits, less one, then
    /// the value plus one.
    mutating func writeGolomb(_ value: UInt32) {
        let encoded = UInt64(value) + 1
        write(encoded, bits: (64 - encoded.leadingZeroBitCount) * 2 - 1)
    }

    mutating func padToByte() {
        while count & 7 != 0 { write(0, bits: 1) }
    }
}
