import Foundation
import Testing

@testable import WingcordVoice

// MARK: - What the far end reassembles has to be what we authenticated
//
// **This is not a round trip through this client's own mirror.** The
// depacketiser here is the one half of the video path with real interop
// evidence: it reassembles Discord's own camera every day and the picture
// decodes. What has never been checked is the *sending* half — and the property
// the far end depends on is exact:
//
//   reassemble(packetize(sealed))  ==  sealed
//
// DAVE authenticates the whole Annex B frame down to the start codes, so a
// single byte of difference is a frame the far end refuses, silently, for ever.
// Every count on this end stays healthy while it happens, which is exactly the
// shape the camera failed in.
@Suite("Video send path")
struct VideoSendRoundTripTests {

    /// A NAL unit of `size` bytes with the given type, containing no start code
    /// of its own — the packetiser is allowed to assume that, because
    /// `DAVECodec.encryptedFrameIsSafe` refuses a frame where it is untrue.
    private func unit(type: UInt8, size: Int, seed: UInt8) -> [UInt8] {
        var bytes: [UInt8] = [0x60 | type]
        var value = seed
        while bytes.count < size {
            value = value &* 31 &+ 17
            // Never two zeros in a row, so nothing here can look like a start
            // code and the test is measuring packetisation, not luck.
            bytes.append(value == 0 ? 0x55 : value)
        }
        return bytes
    }

    /// Rebuilds the Annex B frame the way a receiver does: every unit behind a
    /// four-byte start code, in arrival order.
    private func reassemble(_ payloads: [[UInt8]]) -> [UInt8]? {
        let depacketizer = H264Depacketizer()
        var frame: (units: [[UInt8]], ordered: [[UInt8]], isKeyframe: Bool)?
        for (index, payload) in payloads.enumerated() {
            frame = depacketizer.accept(
                payload: payload,
                sequence: UInt16(index),
                marker: index == payloads.count - 1,
                isContiguous: true
            )
        }
        return frame.map { H264.annexB(units: $0.ordered) }
    }

    /// A keyframe: parameter sets, then an IDR far too large for one packet.
    @Test("A keyframe survives packetisation byte for byte")
    func keyframeSurvives() throws {
        let sps = unit(type: 7, size: 20, seed: 3)
        let pps = unit(type: 8, size: 4, seed: 9)
        let idr = unit(type: 5, size: 7_751, seed: 41)
        let sealed = H264.annexB(units: [sps, pps, idr])

        let payloads = H264.packetize(nalUnits: H264.splitAnnexB(sealed), parameterSets: [])
        #expect(payloads.count > 1, "an IDR this size has to fragment")

        let rebuilt = try #require(reassemble(payloads))
        #expect(rebuilt == sealed, "the far end would authenticate different bytes")
    }

    /// The DAVE footer rides on the last unit, and it must survive too — it is
    /// where the tag, the nonce and the ranges live, and it is read from the
    /// very end of the frame.
    @Test("The trailing supplemental bytes survive with the last unit")
    func footerSurvives() throws {
        let idr = unit(type: 5, size: 3_000, seed: 7)
        var sealed = H264.annexB(units: [unit(type: 7, size: 18, seed: 1), idr])
        sealed.append(contentsOf: (0..<12).map { UInt8($0 &* 7 &+ 1) })
        sealed.append(contentsOf: DAVE.magicMarker)

        let payloads = H264.packetize(nalUnits: H264.splitAnnexB(sealed), parameterSets: [])
        let rebuilt = try #require(reassemble(payloads))
        #expect(rebuilt == sealed)
        #expect(rebuilt.suffix(2) == DAVE.magicMarker[...], "the marker has to be last")
    }

    /// A frame small enough that nothing fragments still has to come back whole.
    ///
    /// It is a keyframe because the depacketiser refuses everything before its
    /// first one — a decoder handed a delta frame with no reference shows
    /// rubbish, so that refusal is correct and this test has to respect it.
    @Test("A frame that fits in single-NAL packets survives")
    func singlePacketSurvives() throws {
        let sealed = H264.annexB(units: [
            unit(type: 7, size: 18, seed: 1),
            unit(type: 8, size: 4, seed: 2),
            unit(type: 5, size: 60, seed: 5),
        ])
        let payloads = H264.packetize(nalUnits: H264.splitAnnexB(sealed), parameterSets: [])
        #expect(payloads.count == 3, "nothing here is large enough to fragment")
        #expect(try #require(reassemble(payloads)) == sealed)
    }
}
