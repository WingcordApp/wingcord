import CoreMedia
import Foundation

// MARK: - H.264 over RTP
//
// RFC 6184, packetization mode 1 — the only mode Discord's server forwards and
// the only one every receiving client decodes. Three packet shapes, and a
// sender has to produce all three:
//
//   * a **single NAL** packet, when the unit fits, which is the whole payload
//     with the NAL's own header byte doing double duty as the RTP payload type;
//   * **STAP-A** (type 24), which carries several small units in one packet —
//     the parameter sets go this way, because SPS and PPS in separate packets
//     can be reordered and a decoder that sees PPS first discards it;
//   * **FU-A** (type 28), which splits a unit across packets with a start bit
//     on the first and an end bit on the last. Every keyframe needs it: an IDR
//     at 720p is tens of kilobytes and the path's MTU is about twelve hundred
//     bytes.
//
// **The MTU is the payload budget, not the datagram's.** Everything else in the
// packet — twelve bytes of RTP, four of extension header, however many of
// extension elements, sixteen of authentication tag and four of nonce — comes
// out of the same 1500, and a packetiser that budgets 1400 for payload produces
// datagrams that fragment at the IP layer. An IP fragment lost is the whole
// frame lost, which turns one per cent of packet loss into ten per cent of
// frame loss.

public enum H264 {
    /// The payload budget for one packet.
    ///
    /// 1100 rather than something closer to the theoretical maximum: the
    /// theoretical maximum assumes no tunnel, and a reader on a VPN, a PPPoE
    /// line or a corporate network has fifty to a hundred bytes less than they
    /// think. Losing one per cent of the possible payload is not measurable;
    /// fragmenting every packet is.
    public static let maximumPayload = 1_100

    public enum NALType: UInt8 {
        case slice = 1
        case idr = 5
        case sei = 6
        case sps = 7
        case pps = 8
        case stapA = 24
        case fuA = 28
    }

    // MARK: Annex B
    //
    // The byte-stream form, where each NAL unit is preceded by a start code.
    // Nothing in the RTP path uses it — packets carry bare NAL units — but
    // **DAVE's frame transform is defined over it**, because that is the shape
    // WebRTC hands an encoded frame to an encoded transform, and both ends have
    // to agree on the bytes down to the start codes.

    /// The four-byte start code, which is the only one this client emits.
    ///
    /// WebRTC's depacketizer rewrites every three-byte start code to four when
    /// it reassembles a frame. Emitting the short form would mean the receiver
    /// authenticates different bytes from the ones that were signed, so the
    /// long form is not a preference — it is what makes the frame survive the
    /// round trip.
    public static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Joins NAL units into one Annex B frame.
    public static func annexB(units: [[UInt8]]) -> [UInt8] {
        var frame: [UInt8] = []
        frame.reserveCapacity(units.reduce(0) { $0 + $1.count + 4 })
        for unit in units where !unit.isEmpty {
            frame.append(contentsOf: startCode)
            frame.append(contentsOf: unit)
        }
        return frame
    }

    /// Splits an Annex B frame back into NAL units, start codes removed.
    ///
    /// Anything trailing the last unit stays attached to it — which is exactly
    /// where DAVE's footer lives, so a transformed frame survives being split
    /// and rejoined.
    public static func splitAnnexB(_ frame: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var starts: [(index: Int, codeLength: Int)] = []
        var search = 0
        while let next = DAVECodec.nextNALU(frame, from: search) {
            starts.append(next)
            search = next.index
        }
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count
                ? starts[position + 1].index - starts[position + 1].codeLength
                : frame.count
            guard start.index < end else { continue }
            units.append(Array(frame[start.index..<end]))
        }
        return units
    }

    /// Splits one access unit into RTP payloads.
    ///
    /// `parameterSets` are prepended as a STAP-A whenever they are present,
    /// which the encoder arranges for every keyframe: a receiver that joins
    /// mid-stream has no format description until it sees them, so a stream that
    /// sends them once at the start is a stream nobody who arrives late can
    /// decode.
    public static func packetize(
        nalUnits: [[UInt8]],
        parameterSets: [[UInt8]]
    ) -> [[UInt8]] {
        var payloads: [[UInt8]] = []

        if !parameterSets.isEmpty {
            payloads.append(contentsOf: aggregate(parameterSets))
        }
        for unit in nalUnits where !unit.isEmpty {
            if unit.count <= maximumPayload {
                payloads.append(unit)
            } else {
                payloads.append(contentsOf: fragment(unit))
            }
        }
        return payloads
    }

    /// STAP-A. Each aggregated unit is preceded by its own 16-bit length.
    ///
    /// The aggregate's own NAL header takes the **highest** NRI of what it
    /// carries and type 24. Taking the first unit's NRI instead marks a packet
    /// containing an SPS as discardable, and a middlebox that honours NRI drops
    /// it.
    static func aggregate(_ units: [[UInt8]]) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        var nri: UInt8 = 0

        func flush() {
            guard !current.isEmpty else { return }
            packets.append([nri | NALType.stapA.rawValue] + current)
            current = []
            nri = 0
        }

        for unit in units where !unit.isEmpty {
            guard unit.count <= 0xFFFF else { continue }
            if 1 + current.count + 2 + unit.count > maximumPayload { flush() }
            nri = max(nri, unit[0] & 0x60)
            current.append(UInt8(truncatingIfNeeded: unit.count >> 8))
            current.append(UInt8(truncatingIfNeeded: unit.count))
            current.append(contentsOf: unit)
        }
        flush()
        return packets
    }

    /// FU-A. The original NAL header is *not* sent: its NRI moves to the
    /// indicator and its type moves to the fragment header, which is where a
    /// reassembler puts it back.
    static func fragment(_ unit: [UInt8]) -> [[UInt8]] {
        guard unit.count > 1 else { return [] }
        let indicator = (unit[0] & 0xE0) | NALType.fuA.rawValue
        let type = unit[0] & 0x1F

        var packets: [[UInt8]] = []
        var offset = 1
        let budget = maximumPayload - 2

        while offset < unit.count {
            let take = min(budget, unit.count - offset)
            let isFirst = offset == 1
            let isLast = offset + take == unit.count
            var packet = [UInt8]()
            packet.reserveCapacity(take + 2)
            packet.append(indicator)
            packet.append((isFirst ? 0x80 : 0) | (isLast ? 0x40 : 0) | type)
            packet.append(contentsOf: unit[offset..<(offset + take)])
            packets.append(packet)
            offset += take
        }
        return packets
    }

    /// Turns a VideoToolbox sample buffer's length-prefixed data into NAL units.
    ///
    /// VideoToolbox emits AVCC — a four-byte big-endian length before each unit
    /// — and RTP wants the bare units. The prefix size is read from the format
    /// description rather than assumed: it is four in practice and the field
    /// exists because it need not be.
    public static func nalUnits(from sampleBuffer: CMSampleBuffer) -> [[UInt8]] {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
            dataPointerOut: &pointer
        ) == noErr, let pointer else { return [] }

        var prefix: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &prefix
            )
        }
        let headerLength = Int(prefix)

        var units: [[UInt8]] = []
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + headerLength <= length {
            var size = 0
            for index in 0..<headerLength { size = size << 8 | Int(bytes[offset + index]) }
            offset += headerLength
            guard size > 0, offset + size <= length else { break }
            units.append(Array(UnsafeBufferPointer(start: bytes + offset, count: size)))
            offset += size
        }
        return units
    }

    /// The SPS and PPS a stream's format description carries.
    public static func parameterSets(from format: CMFormatDescription) -> [[UInt8]] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr else { return [] }

        var sets: [[UInt8]] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { continue }
            sets.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
        }
        return sets
    }
}

// MARK: - Reassembly

/// Rebuilds access units from one sender's packets.
///
/// One per video SSRC. It is deliberately forgiving: a fragment sequence with a
/// hole in it is discarded whole rather than patched, because a partial NAL
/// handed to a hardware decoder is not a corrupted picture — it is a decoder
/// that stops producing frames until the next keyframe, which on a stream with
/// two-second keyframe intervals is two seconds of frozen video per lost packet.
public final class H264Depacketizer {
    private var fragment: [UInt8] = []
    private var fragmentSequence: UInt16?
    private var isCollecting = false
    private(set) public var parameterSets: [[UInt8]] = []
    /// Set when a hole made this frame unusable, so the caller knows to ask for
    /// a keyframe rather than waiting for one.
    private(set) public var needsKeyframe = true

    private var pendingUnits: [[UInt8]] = []
    /// Every unit of the frame, in arrival order, parameter sets and SEI
    /// included.
    ///
    /// **Kept only for DAVE**, which authenticates the whole Annex B frame:
    /// rebuilding it means rebuilding it exactly, and the classified lists
    /// above have already dropped SEI and moved the parameter sets aside.
    private var orderedUnits: [[UInt8]] = []

    public init() {}

    /// Feeds one RTP payload. Returns the complete access unit when `marker`
    /// says the frame ended, and nil while it is still arriving.
    public func accept(
        payload: [UInt8],
        sequence: UInt16,
        marker: Bool,
        isContiguous: Bool
    ) -> (units: [[UInt8]], ordered: [[UInt8]], isKeyframe: Bool)? {
        guard let first = payload.first else { return nil }
        if !isContiguous {
            // A gap. Everything half-built is unusable and so is the rest of
            // this frame — the decoder needs whole units or nothing.
            fragment.removeAll(keepingCapacity: true)
            isCollecting = false
            pendingUnits.removeAll(keepingCapacity: true)
            orderedUnits.removeAll(keepingCapacity: true)
            needsKeyframe = true
        }

        switch first & 0x1F {
        case H264.NALType.stapA.rawValue:
            var offset = 1
            while offset + 2 <= payload.count {
                let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard size > 0, offset + size <= payload.count else { break }
                store(Array(payload[offset..<(offset + size)]))
                offset += size
            }

        case H264.NALType.fuA.rawValue:
            guard payload.count > 2 else { return nil }
            let header = payload[1]
            let isStart = header & 0x80 != 0
            let isEnd = header & 0x40 != 0
            if isStart {
                fragment = [(first & 0xE0) | (header & 0x1F)]
                isCollecting = true
            }
            guard isCollecting else { return nil }
            fragment.append(contentsOf: payload[2...])
            fragmentSequence = sequence
            if isEnd {
                store(fragment)
                fragment.removeAll(keepingCapacity: true)
                isCollecting = false
            }

        default:
            store(payload)
        }

        guard marker, !pendingUnits.isEmpty else { return nil }
        let units = pendingUnits
        let ordered = orderedUnits
        pendingUnits.removeAll(keepingCapacity: true)
        orderedUnits.removeAll(keepingCapacity: true)
        let isKeyframe = units.contains { ($0.first ?? 0) & 0x1F == H264.NALType.idr.rawValue }
        if isKeyframe { needsKeyframe = false }
        // A frame arriving before any keyframe has nothing to predict from.
        guard !needsKeyframe else { return nil }
        return (units, ordered, isKeyframe)
    }

    private func store(_ unit: [UInt8]) {
        guard let first = unit.first else { return }
        orderedUnits.append(unit)
        switch first & 0x1F {
        case H264.NALType.sps.rawValue, H264.NALType.pps.rawValue:
            // Replaced rather than appended: a stream that changes resolution
            // sends a new SPS, and a decoder handed both descriptions builds a
            // format for the old one.
            let type = first & 0x1F
            parameterSets.removeAll { ($0.first ?? 0) & 0x1F == type }
            parameterSets.append(unit)
            parameterSets.sort { ($0.first ?? 0) & 0x1F < ($1.first ?? 0) & 0x1F }
        case H264.NALType.sei.rawValue:
            break   // Nothing here reads SEI, and passing it on costs a copy.
        default:
            pendingUnits.append(unit)
        }
    }

    public func reset() {
        fragment.removeAll(keepingCapacity: false)
        pendingUnits.removeAll(keepingCapacity: false)
        orderedUnits.removeAll(keepingCapacity: false)
        parameterSets.removeAll(keepingCapacity: false)
        isCollecting = false
        needsKeyframe = true
    }
}
