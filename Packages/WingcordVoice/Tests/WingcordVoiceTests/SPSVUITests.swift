import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
import VideoToolbox

@testable import WingcordVoice

private func bytes(_ hex: some StringProtocol) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

// MARK: - The rewrite is WebRTC's, not a likeness of it
//
// **A port checked against itself proves nothing.** The vectors are WebRTC's
// own `SpsVuiRewriter`, compiled from its sources, run over WebRTC's unit-test
// SPS, over every SPS VideoToolbox produces across sizes, rates and profiles,
// and over fifteen hundred mutations of those: the verdict and the bytes both
// have to agree, down to the SPS WebRTC refuses to parse.
@Suite("SPS VUI rewrite")
struct SPSVUITests {

    @Test("Agrees with WebRTC's rewriter on every vector")
    func agreesWithWebRTC() throws {
        let url = try #require(Bundle.module.url(
            forResource: "webrtc-sps-vui", withExtension: "txt", subdirectory: "Vectors"
        ))
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
        #expect(lines.count > 1_500)

        var disagreements: [String] = []
        for line in lines {
            let fields = line.split(separator: " ")
            let input = bytes(fields[0])
            let expected: H264.VUIVerdict = switch fields[1] {
            case "kept": .kept
            case "rewritten": .rewritten(bytes(fields[2]))
            default: .unparseable
            }
            if H264.vuiVerdict(forSPS: input) != expected { disagreements.append(String(line)) }
        }
        #expect(disagreements.isEmpty, "\(disagreements.count) disagree, first: \(disagreements.first ?? "")")
    }

    /// The camera SPS from the 2026-10-05 call nobody could see, 854×480, and
    /// the one the low-latency encoder wrote when the camera still worked.
    @Test("The traced camera SPS is rewritten; the one that worked is kept")
    func theTracedSPS() {
        #expect(
            H264.vuiVerdict(forSPS: bytes("2742c01fab406c1ef368"))
                == .rewritten(bytes("2742c01fab406c1ef3700da08846a0"))
        )
        #expect(H264.vuiVerdict(forSPS: bytes("2742c01f898a300a00b74d40808081e10084d0")) == .kept)
    }

    @Test("Only an SPS is ever touched")
    func onlySPS() {
        let pps = bytes("28ce3c80")
        #expect(H264.receiverStableSPS(pps) == pps)
        let idr: [UInt8] = [0x25, 0x88, 0x84, 0x00, 0x33]
        #expect(H264.receiverStableSPS(idr) == idr)
    }

    /// The encoder at the three sizes the camera setting offers. Every SPS it
    /// hands the send path must be one a receiver keeps, and must still
    /// declare one reference frame.
    @Test("Every SPS the encoder emits is one a receiver keeps", arguments: [
        (854, 480, 1_000_000), (1_280, 720, 2_500_000), (1_920, 1_080, 4_000_000),
    ])
    func encoderOutputIsKept(width: Int, height: Int, bitrate: Int) throws {
        let frame = try FarEndReceiverTests.encodeKeyframe(width: width, height: height, bitrate: bitrate)
        let sps = try #require(frame.parameterSets.first { $0.first.map { $0 & 0x1F } == 7 })
        #expect(H264.vuiVerdict(forSPS: sps) == .kept, "\(width)×\(height): \(hex(sps))")
    }
}

// MARK: - Received the way Discord receives
//
// **Every earlier test of the video path received with this client's own
// depacketiser**, which passes the SPS through untouched, so a stream every
// Discord client refused round-tripped here perfectly. This receiver does what
// WebRTC does before the frame transformer runs DAVE: each SPS through the
// receive-side rewrite (`RtpDepacketizerH264`), each unit behind the four-byte
// start code `H264SpsPpsTracker` inserts. Then DAVE, then VideoToolbox's
// decoder.
@Suite("A WebRTC receiver", .serialized)
struct FarEndReceiverTests {

    struct EncodedFrame: Sendable {
        var units: [[UInt8]]
        var parameterSets: [[UInt8]]
    }

    /// One keyframe from the real encoder, at a camera size.
    static func encodeKeyframe(width: Int, height: Int, bitrate: Int) throws -> EncodedFrame {
        let encoder = H264Encoder(configuration: .init(
            width: width, height: height, framerate: 30, bitrate: bitrate
        ))
        let frames = Mutex<[EncodedFrame]>([])
        encoder.onEncodedFrame = { units, sets, isKeyframe, _ in
            guard isKeyframe else { return }
            frames.withLock { $0.append(EncodedFrame(units: units, parameterSets: sets)) }
        }
        try encoder.start()
        encoder.encode(
            try VideoPathTests.makePixelBuffer(seed: 5, width: width, height: height),
            at: CMTime(value: 0, timescale: 90_000),
            forceKeyframe: true
        )
        encoder.teardown()
        return try #require(frames.withLock { $0.first }, "the encoder produced no keyframe")
    }

    private static let sender: UInt64 = 4_242

    private func davePair() -> (DAVEEncryptor, DAVEDecryptor) {
        let secret = [UInt8](repeating: 0x5A, count: 32)
        let encryptor = DAVEEncryptor()
        encryptor.setRatchet(MLSHashRatchet(baseSecret: secret))
        encryptor.setPassthrough(false)
        let decryptor = DAVEDecryptor(userID: Self.sender)
        decryptor.transition(to: MLSHashRatchet(baseSecret: secret), retaining: 0)
        return (encryptor, decryptor)
    }

    /// The payloads `VideoSendPath` sends for one access unit under DAVE.
    private func payloads(
        units: [[UInt8]], parameterSets: [[UInt8]], encryptor: DAVEEncryptor
    ) throws -> [[UInt8]] {
        let sealed = try #require(encryptor.encrypt(
            H264.annexB(units: parameterSets + units), codec: .h264
        ))
        return H264.packetize(nalUnits: H264.splitAnnexB(sealed), parameterSets: [])
    }

    /// What WebRTC hands its frame transformer for these payloads.
    private func assembledByWebRTC(_ payloads: [[UInt8]]) -> [UInt8] {
        var frame: [UInt8] = []
        func receive(_ unit: [UInt8]) {
            var unit = unit
            if unit.first.map({ $0 & 0x1F }) == H264.NALType.sps.rawValue,
               case .rewritten(let sps) = H264.vuiVerdict(forSPS: unit) {
                unit = sps
            }
            frame += H264.startCode + unit
        }
        for payload in payloads {
            switch payload[0] & 0x1F {
            case H264.NALType.stapA.rawValue:
                var offset = 1
                while offset + 2 <= payload.count {
                    let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                    offset += 2
                    receive(Array(payload[offset..<(offset + size)]))
                    offset += size
                }
            case H264.NALType.fuA.rawValue:
                if payload[1] & 0x80 != 0 {
                    frame += H264.startCode + [(payload[0] & 0xE0) | (payload[1] & 0x1F)]
                }
                frame += payload[2...]
            default:
                receive(payload)
            }
        }
        return frame
    }

    /// The decrypted frame through VideoToolbox's decoder: the picture's size,
    /// or nil when nothing decoded.
    private func decode(_ frame: [UInt8]) throws -> (width: Int, height: Int)? {
        let units = H264.splitAnnexB(frame)
        let builder = H264SampleBuilder()
        builder.updateParameterSets(units.filter { [7, 8].contains($0[0] & 0x1F) })
        let sample = try #require(builder.sampleBuffer(
            units: units.filter { ![7, 8].contains($0[0] & 0x1F) },
            presentationTime: .zero,
            isKeyframe: true
        ))
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        var session: VTDecompressionSession?
        #expect(VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session
        ) == noErr)
        let decoder = try #require(session)
        defer { VTDecompressionSessionInvalidate(decoder) }

        let size = Mutex<(width: Int, height: Int)?>(nil)
        VTDecompressionSessionDecodeFrame(
            decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            size.withLock { $0 = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        return size.withLock { $0 }
    }

    @Test("Our camera's keyframe decrypts and decodes at a WebRTC receiver")
    func keyframeDecodesAtTheFarEnd() throws {
        let frame = try Self.encodeKeyframe(width: 854, height: 480, bitrate: 1_000_000)
        let (encryptor, decryptor) = davePair()
        let received = assembledByWebRTC(try payloads(
            units: frame.units, parameterSets: frame.parameterSets, encryptor: encryptor
        ))

        let plain = try #require(
            decryptor.decrypt(received, isAudio: false),
            "DAVE refused the keyframe: the receiver changed bytes that were authenticated"
        )
        #expect(plain == H264.annexB(units: frame.parameterSets + frame.units))
        let size = try #require(try decode(plain), "VideoToolbox decoded nothing")
        #expect(size == (854, 480))
    }

    /// **The mutation check.** The same keyframe behind the SPS VideoToolbox
    /// writes, which is what left before the rewrite: the traced 854×480 SPS
    /// from the call nobody could see. A WebRTC receiver rewrites it, and DAVE
    /// refuses the frame.
    @Test("A keyframe behind VideoToolbox's own SPS fails DAVE at the far end")
    func rawSPSFailsAtTheFarEnd() throws {
        let frame = try Self.encodeKeyframe(width: 854, height: 480, bitrate: 1_000_000)
        let pps = try #require(frame.parameterSets.first { $0[0] & 0x1F == 8 })
        let (encryptor, decryptor) = davePair()
        let received = assembledByWebRTC(try payloads(
            units: frame.units, parameterSets: [bytes("2742c01fab406c1ef368"), pps],
            encryptor: encryptor
        ))
        #expect(decryptor.decrypt(received, isAudio: false) == nil)
    }
}
