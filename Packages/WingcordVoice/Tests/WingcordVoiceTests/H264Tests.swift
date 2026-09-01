import Foundation
import Testing
@testable import WingcordVoice

@Suite("H.264 over RTP")
struct H264Tests {

    @Test func aSmallUnitIsSentWhole() {
        let unit: [UInt8] = [0x65] + Array(repeating: 0xAB, count: 40)
        let packets = H264.packetize(nalUnits: [unit], parameterSets: [])
        #expect(packets == [unit])
    }

    @Test func parameterSetsAggregateIntoOnePacket() throws {
        let sps: [UInt8] = [0x67, 1, 2, 3]
        let pps: [UInt8] = [0x68, 4, 5]
        let packets = H264.packetize(nalUnits: [], parameterSets: [sps, pps])
        let stapA = try #require(packets.first)
        #expect(packets.count == 1)
        #expect(stapA[0] & 0x1F == 24)
        // Each aggregated unit is preceded by its own 16-bit length.
        #expect(Int(stapA[1]) << 8 | Int(stapA[2]) == sps.count)
        #expect(Array(stapA[3..<(3 + sps.count)]) == sps)
    }

    @Test func aLargeUnitFragmentsAndReassembles() throws {
        let unit: [UInt8] = [0x65] + (0..<5_000).map { UInt8(truncatingIfNeeded: $0) }
        let packets = H264.packetize(nalUnits: [unit], parameterSets: [])
        #expect(packets.count > 1)
        #expect(packets.allSatisfy { $0.count <= H264.maximumPayload })
        #expect(packets.first![1] & 0x80 != 0)   // start
        #expect(packets.last![1] & 0x40 != 0)    // end

        let reassembler = H264Depacketizer()
        // A stream cannot decode before it has parameter sets, so they go first
        // — which is exactly what a keyframe carries.
        _ = reassembler.accept(
            payload: H264.aggregate([[0x67, 1], [0x68, 2]])[0],
            sequence: 0, marker: false, isContiguous: true
        )
        var result: (units: [[UInt8]], ordered: [[UInt8]], isKeyframe: Bool)?
        for (index, packet) in packets.enumerated() {
            result = reassembler.accept(
                payload: packet,
                sequence: UInt16(index + 1),
                marker: index == packets.count - 1,
                isContiguous: true
            )
        }
        let frame = try #require(result)
        #expect(frame.isKeyframe)
        #expect(frame.units == [unit])
    }

    /// A hole inside a fragment makes the whole access unit unusable. Patching
    /// it and handing the result to a hardware decoder is not a corrupt picture
    /// — it is a decoder that stops producing frames until the next keyframe.
    @Test func aGapDiscardsTheFrameRatherThanPatchingIt() {
        let unit: [UInt8] = [0x65] + (0..<4_000).map { UInt8(truncatingIfNeeded: $0) }
        let packets = H264.packetize(nalUnits: [unit], parameterSets: [])
        let reassembler = H264Depacketizer()
        _ = reassembler.accept(
            payload: H264.aggregate([[0x67, 1], [0x68, 2]])[0],
            sequence: 0, marker: false, isContiguous: true
        )
        var result: (units: [[UInt8]], ordered: [[UInt8]], isKeyframe: Bool)?
        for (index, packet) in packets.enumerated() {
            result = reassembler.accept(
                payload: packet,
                sequence: UInt16(index + 1),
                marker: index == packets.count - 1,
                // The second packet is reported as following a gap.
                isContiguous: index != 1
            )
        }
        #expect(result == nil)
    }

    @Test func parameterSetsAreReplacedNotAccumulated() {
        let reassembler = H264Depacketizer()
        _ = reassembler.accept(
            payload: H264.aggregate([[0x67, 1], [0x68, 2]])[0],
            sequence: 0, marker: false, isContiguous: true
        )
        _ = reassembler.accept(
            payload: H264.aggregate([[0x67, 9], [0x68, 8]])[0],
            sequence: 1, marker: false, isContiguous: true
        )
        #expect(reassembler.parameterSets == [[0x67, 9], [0x68, 8]])
    }
}
