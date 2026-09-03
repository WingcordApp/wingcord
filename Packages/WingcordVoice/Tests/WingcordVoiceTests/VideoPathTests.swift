import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
import VideoToolbox

@testable import WingcordVoice

// MARK: - The whole video path, minus the network
//
// **Every layer of this has been checked alone and the two ends have never been
// joined.** `VideoSendRoundTripTests` proves the packetiser preserves bytes,
// `DAVETransformTests` proves the transform round-trips, `H264Tests` proves the
// reassembler reassembles — and a share built from all three arrived black at
// both ends while every counter above them read healthy.
//
// What is exercised here is the seam none of those covers: real parameter sets
// from VideoToolbox, through the real `H264.packetize`, the real `RTPWriter`,
// the real `VoiceSealer`, into the real `InboundStreams`, and out as a sample
// buffer a display layer would accept. It is not an interop proof — only
// Discord can give that — but it is the difference between "each piece works"
// and "the picture comes out".

@Suite("Video path", .serialized)
struct VideoPathTests {

    fileprivate static let width = 320
    fileprivate static let height = 240

    // MARK: A real encoded frame

    /// A pixel buffer with something in it, so the encoder has detail to spend
    /// bits on and a keyframe that is not four bytes long.
    fileprivate func makePixelBuffer(seed: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        let created = CVPixelBufferCreate(
            kCFAllocatorDefault, Self.width, Self.height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        )
        let pixels = try #require(created == kCVReturnSuccess ? buffer : nil)

        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<Self.height {
            for column in 0..<Self.width {
                let offset = row * stride + column * 4
                bytes[offset] = UInt8(truncatingIfNeeded: column &* 3 &+ Int(seed))
                bytes[offset + 1] = UInt8(truncatingIfNeeded: row &* 5 &+ Int(seed))
                bytes[offset + 2] = UInt8(truncatingIfNeeded: (row ^ column) &+ Int(seed))
                bytes[offset + 3] = 0xFF
            }
        }
        return pixels
    }

    private struct EncodedFrame: Sendable {
        var units: [[UInt8]]
        var parameterSets: [[UInt8]]
        var isKeyframe: Bool
    }

    /// The frames the encoder handed back, for the same reason `Drawn` exists.
    private final class Encoded: Sendable {
        private let frames = Mutex<[EncodedFrame]>([])
        func append(_ frame: EncodedFrame) { frames.withLock { $0.append(frame) } }
        var all: [EncodedFrame] { frames.withLock { $0 } }
    }

    /// One keyframe out of the real encoder, with the parameter sets it
    /// produced. **VideoToolbox's own SPS**, because a hand-written one would
    /// prove only that the test can write an SPS.
    private func encodeKeyframe() throws -> EncodedFrame {
        let encoder = H264Encoder(configuration: .init(
            width: Self.width, height: Self.height, framerate: 30, bitrate: 800_000
        ))
        let frames = Encoded()
        encoder.onEncodedFrame = { units, sets, isKeyframe in
            frames.append(
                EncodedFrame(units: units, parameterSets: sets, isKeyframe: isKeyframe)
            )
        }
        try encoder.start()
        encoder.encode(
            try makePixelBuffer(seed: 1),
            at: CMTime(value: 0, timescale: 90_000),
            forceKeyframe: true
        )
        // Flushes the session, which is what makes the callback above have run
        // by the time this returns.
        encoder.teardown()

        let keyframe = try #require(
            frames.all.first { $0.isKeyframe },
            "the encoder produced no keyframe to test with"
        )
        #expect(keyframe.parameterSets.count >= 2, "a keyframe carries its SPS and PPS")
        return keyframe
    }

    // MARK: Putting it on a wire and taking it off again

    /// The sending half: DAVE if asked, then packetisation, then RTP, then the
    /// transport cipher — the same order and the same calls `VideoSendPath`
    /// makes.
    private func datagrams(
        for frame: EncodedFrame,
        writer: inout RTPWriter,
        sealer: VoiceSealer,
        dave: DAVEEncryptor?,
        extensions: TransportSequence? = nil
    ) throws -> [[UInt8]] {
        let payloads: [[UInt8]]
        if let dave {
            let annexB = H264.annexB(units: frame.parameterSets + frame.units)
            let sealed = try #require(dave.encrypt(annexB, codec: .h264))
            payloads = H264.packetize(nalUnits: H264.splitAnnexB(sealed), parameterSets: [])
        } else {
            payloads = H264.packetize(
                nalUnits: frame.units, parameterSets: frame.parameterSets
            )
        }
        writer.advanceClock(by: 3_000)
        return try payloads.enumerated().map { index, payload in
            // The two elements a working stream carries, written exactly as
            // `VideoSendPath` writes them.
            var block: [UInt8] = []
            if let extensions {
                block += RTPExtension.absoluteSendTime(
                    id: RTPExtension.DefaultID.absoluteSendTime, seconds: 47.0
                )
                block += RTPExtension.transportSequence(
                    id: RTPExtension.DefaultID.transportSequence, sequence: extensions.next()
                )
            }
            let header = writer.next(
                advancingClockBy: 0,
                marker: index == payloads.count - 1,
                extensions: block
            )
            return try [UInt8](payload.withUnsafeBytes { try sealer.seal(payload: $0, header: header) })
        }
    }

    /// A padding-only datagram on the same SSRC: what an SFU sends to measure
    /// the path, and what a receiver must not mistake for a sequence gap.
    private func paddingDatagram(writer: inout RTPWriter, sealer: VoiceSealer) throws -> [UInt8] {
        var header = writer.next(advancingClockBy: 0)
        // The padding bit lives in the first octet, beside the version.
        header.clear[0] |= 0x20
        let filler = [UInt8](repeating: 0, count: 15) + [16]
        return try [UInt8](filler.withUnsafeBytes { try sealer.seal(payload: $0, header: header) })
    }

    private static let ssrc: UInt32 = 4242
    private static let sender: UInt64 = 777

    /// What reached a display layer, as the only thing worth asserting about
    /// it: the size the decoder was told each picture is.
    ///
    /// The dimensions rather than the buffers, because a `CMSampleBuffer` is
    /// not `Sendable` and a collector that keeps one has to say why it is safe
    /// — and here it does not need to keep one. A reference type holding the
    /// mutex, for the reason `StreamPreview` is one.
    private final class Drawn: Sendable {
        private let sizes = Mutex<[(width: Int, height: Int)]>([])

        func append(_ sample: CMSampleBuffer) {
            let size = CMSampleBufferGetFormatDescription(sample)
                .map(CMVideoFormatDescriptionGetDimensions)
            sizes.withLock {
                $0.append((Int(size?.width ?? 0), Int(size?.height ?? 0)))
            }
        }

        var count: Int { sizes.withLock { $0.count } }
        var first: (width: Int, height: Int)? { sizes.withLock { $0.first } }
    }

    /// A receiver wired the way a call wires one, with the picture collected.
    private func receiver(sealer: VoiceSealer, dave: DAVEDecryptor?) -> (InboundStreams, Drawn) {
        let inbound = InboundStreams()
        inbound.setSealer(sealer)
        inbound.bindVideo(ssrc: Self.ssrc, to: Self.sender)
        if let dave {
            inbound.setDAVE(decryptors: [Self.sender: dave], active: true)
        }
        let drawn = Drawn()
        inbound.setVideoSink({ drawn.append($0) }, for: Self.sender)
        return (inbound, drawn)
    }

    private func transportPair() -> VoiceSealer {
        VoiceSealer(cipher: .aes256GCM, secretKey: [UInt8](repeating: 0x11, count: 32))
    }

    private func davePair() -> (DAVEEncryptor, DAVEDecryptor) {
        let secret = [UInt8](repeating: 0x3C, count: 32)
        let encryptor = DAVEEncryptor()
        encryptor.setRatchet(MLSHashRatchet(baseSecret: secret))
        encryptor.setPassthrough(false)
        let decryptor = DAVEDecryptor(userID: Self.sender)
        decryptor.transition(to: MLSHashRatchet(baseSecret: secret), retaining: 0)
        return (encryptor, decryptor)
    }

    // MARK: The tests

    @Test("A keyframe leaves the encoder and arrives as a sample buffer")
    func keyframeSurvivesTheWholePath() throws {
        let frame = try encodeKeyframe()
        let sealer = transportPair()
        var writer = RTPWriter(ssrc: Self.ssrc, payloadType: RTP.PayloadType.h264)
        let packets = try datagrams(for: frame, writer: &writer, sealer: sealer, dave: nil)
        let (inbound, drawn) = receiver(sealer: sealer, dave: nil)

        for packet in packets { inbound.accept(packet, arrival: 0) }

        #expect(drawn.count == 1, "one access unit in, one sample out")
        let size = try #require(drawn.first)
        #expect(
            size == (Self.width, Self.height),
            "the format description came from the parameter sets that arrived"
        )
    }

    /// The same path with the end-to-end transform in it, which is the shape a
    /// real call always has.
    @Test("A keyframe survives the path end-to-end encrypted")
    func keyframeSurvivesUnderDAVE() throws {
        let frame = try encodeKeyframe()
        let sealer = transportPair()
        let (encryptor, decryptor) = davePair()
        var writer = RTPWriter(ssrc: Self.ssrc, payloadType: RTP.PayloadType.h264)
        let packets = try datagrams(
            for: frame, writer: &writer, sealer: sealer, dave: encryptor
        )
        let (inbound, drawn) = receiver(sealer: sealer, dave: decryptor)

        for packet in packets { inbound.accept(packet, arrival: 0) }

        #expect(drawn.count == 1)
        let report = inbound.drainVideoReport()
        #expect(report.census.frames == 1)
        #expect(report.census.drawn == 1)
        #expect(report.census.unrouted == 0)
    }

    /// **The bug this exists to pin.** A padding-only packet trims to nothing
    /// and returns before anything reads it — and if it returns before the
    /// sequence is recorded, the next real packet looks like it followed a gap
    /// and the frame in progress is thrown away. At a few probes a second that
    /// is every frame, for ever, with no drop counted anywhere.
    @Test("A padding-only packet between fragments does not break the frame")
    func paddingDoesNotBreakContiguity() throws {
        let frame = try encodeKeyframe()
        let sealer = transportPair()
        var writer = RTPWriter(ssrc: Self.ssrc, payloadType: RTP.PayloadType.h264)
        let payloads = H264.packetize(
            nalUnits: frame.units, parameterSets: frame.parameterSets
        )
        #expect(payloads.count >= 3, "the keyframe has to span several packets")

        let (inbound, drawn) = receiver(sealer: sealer, dave: nil)
        writer.advanceClock(by: 3_000)
        for payload in payloads.dropLast() {
            let header = writer.next(advancingClockBy: 0)
            inbound.accept(
                try [UInt8](payload.withUnsafeBytes {
                    try sealer.seal(payload: $0, header: header)
                }),
                arrival: 0
            )
        }
        // The probe, which consumes a sequence number of its own.
        inbound.accept(try paddingDatagram(writer: &writer, sealer: sealer), arrival: 0)

        let header = writer.next(advancingClockBy: 0, marker: true)
        inbound.accept(
            try [UInt8](payloads[payloads.count - 1].withUnsafeBytes {
                try sealer.seal(payload: $0, header: header)
            }),
            arrival: 0
        )

        #expect(
            drawn.count == 1,
            "the probe is not a gap, and the frame it sat inside still assembles"
        )
    }

    /// **The regression this exists to catch.** Header extensions were added to
    /// every packet this client sends, and they change the shape of one: the X
    /// bit goes up, four bytes of preamble join the authenticated clear prefix,
    /// and the elements themselves ride *inside* the ciphertext ahead of the
    /// media. A receiver that computes any of those three lengths differently
    /// from the sender decrypts nothing, or decrypts and hands the decoder
    /// eight bytes of preamble — and both look like a camera that spins for
    /// ever at the far end.
    @Test("A keyframe survives with the header extensions a working stream carries")
    func keyframeSurvivesWithExtensions() throws {
        let frame = try encodeKeyframe()
        let sealer = transportPair()
        let (encryptor, decryptor) = davePair()
        var writer = RTPWriter(ssrc: Self.ssrc, payloadType: RTP.PayloadType.h264)
        let packets = try datagrams(
            for: frame, writer: &writer, sealer: sealer,
            dave: encryptor, extensions: TransportSequence()
        )
        // Every packet carries the block, so every one has to be four bytes of
        // preamble and eight of body longer than it was.
        let header = try #require(RTPHeader(parsing: packets[0]))
        #expect(header.extensionBodyLength == 8, "abs-send-time and transport-cc, padded")
        #expect(header.clearPrefixLength == RTP.headerLength + 4, "the preamble is clear")

        let (inbound, drawn) = receiver(sealer: sealer, dave: decryptor)
        for packet in packets { inbound.accept(packet, arrival: 0) }

        #expect(drawn.count == 1, "the picture survives the extension block")
        #expect(try #require(drawn.first) == (Self.width, Self.height))
    }

    /// The size announced in opcode 12 and the size given to the encoder are
    /// the same number, and it has to be one an H.264 encoder describes without
    /// a cropping rectangle.
    @Test("A shared display is fitted to whole macroblocks")
    func shareIsFittedToMacroblocks() {
        // The laptop this was measured on: 1710×1112 into a 720p box gave
        // 1108×720, and 1108 is not a multiple of eight.
        let fitted = ScreenShareCapture.fit(width: 1_710, height: 1_112, into: 1_280, by: 720)
        #expect(fitted.width % 16 == 0 && fitted.height % 16 == 0)
        #expect(fitted.width <= 1_280 && fitted.height <= 720, "and it still fits")
        #expect(fitted == (1_104, 720))

        // A source already smaller than the box is not scaled up, only aligned.
        let small = ScreenShareCapture.fit(width: 300, height: 200, into: 1_280, by: 720)
        #expect(small == (288, 192))

        // Nothing degenerate, whatever it is handed.
        #expect(ScreenShareCapture.fit(width: 0, height: 0, into: 1_280, by: 720) == (1_280, 720))
        let tiny = ScreenShareCapture.fit(width: 3, height: 1, into: 1_280, by: 720)
        #expect(tiny.width >= 16 && tiny.height >= 16)
    }

    /// **Nothing may leave a stream before a keyframe has.** Measured twice on
    /// a real share as `video first frame in=[1:17455]` — one P-slice, sent
    /// under a key that had just arrived, which no decoder can start from.
    @Test("A stream does not open with anything but a keyframe")
    func nothingLeavesBeforeAKeyframe() throws {
        let path = VideoSendPath()
        path.configure(
            sealer: transportPair(),
            transport: VoiceTransport(host: "127.0.0.1", port: 1),
            ssrc: Self.ssrc,
            sendTimeExtensionID: nil,
            transportSequenceExtensionID: nil,
            transportSequence: nil,
            label: "test"
        )
        path.isActive = true

        let delta = [[UInt8]([0x41, 0x9A, 0x02, 0x03])]
        path.send(units: delta, parameterSets: [], isKeyframe: false, presentationTime: 0)
        var report = path.drainCounters()
        #expect(report.packets == 0, "a delta frame cannot open a stream")
        #expect(report.unstartable == 1)
        #expect(path.takeKeyframeRequest(), "and the encoder is asked for one")

        let key = try encodeKeyframe()
        path.send(
            units: key.units, parameterSets: key.parameterSets,
            isKeyframe: true, presentationTime: 0
        )
        report = path.drainCounters()
        // `packets` is the running total the trace prints, so it is read as a
        // difference rather than a per-window count.
        let afterKeyframe = report.packets
        #expect(afterKeyframe > 0, "the keyframe opens it")
        #expect(report.unstartable == 0)

        // And once it is open, delta frames flow.
        path.send(units: delta, parameterSets: [], isKeyframe: false, presentationTime: 0.033)
        report = path.drainCounters()
        #expect(report.packets == afterKeyframe + 1)
        #expect(report.unstartable == 0)
    }
}

// MARK: - What the encoder promises a decoder

/// **A realtime stream declares one reference frame, and this is the only place
/// that is checked.**
///
/// The low-latency rate controller defaults to a five-frame reference buffer
/// and writes it into the SPS — `max_num_ref_frames = 5`, with a VUI carrying
/// `max_dec_frame_buffering = 5`. Legal H.264; nonsensical for a call, because
/// it tells a receiver to hold five frames before it may show anything. Discord
/// answers such a stream with "Failed to start camera, Error 2015" over a black
/// tile while every counter on this side reads healthy.
///
/// Nothing above the encoder can see this. The bytes are the only evidence, so
/// they are parsed.
@Suite("Encoder conformance")
struct EncoderConformanceTests {

    /// Enough of an SPS to answer the one question. RBSP unescaping and
    /// exponential-Golomb, both of which the DAVE codec already needed.
    private struct SPSReader {
        private let bytes: [UInt8]
        private var bit = 0

        /// Takes the NAL **payload**, emulation-prevention bytes removed.
        init(payload: [UInt8]) {
            var out: [UInt8] = []
            var index = 0
            while index < payload.count {
                if index + 2 < payload.count, payload[index] == 0,
                   payload[index + 1] == 0, payload[index + 2] == 3 {
                    out.append(0); out.append(0); index += 3
                } else {
                    out.append(payload[index]); index += 1
                }
            }
            bytes = out
        }

        mutating func u(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count {
                guard bit >> 3 < bytes.count else { return value }
                value = value << 1 | Int(bytes[bit >> 3] >> (7 - (bit & 7)) & 1)
                bit += 1
            }
            return value
        }

        mutating func ue() -> Int {
            var zeros = 0
            while bit >> 3 < bytes.count, u(1) == 0 { zeros += 1 }
            return (1 << zeros) - 1 + (zeros > 0 ? u(zeros) : 0)
        }

        /// `max_num_ref_frames`, for a baseline SPS.
        static func maxReferenceFrames(inSPS nal: [UInt8]) -> Int? {
            guard nal.count > 4, nal[0] & 0x1F == H264.NALType.sps.rawValue else { return nil }
            var reader = SPSReader(payload: Array(nal[4...]))
            _ = reader.ue()                 // seq_parameter_set_id
            _ = reader.ue()                 // log2_max_frame_num_minus4
            let pocType = reader.ue()
            if pocType == 0 { _ = reader.ue() }   // log2_max_pic_order_cnt_lsb_minus4
            return reader.ue()
        }
    }

    @Test("The stream declares one reference frame, not five")
    func oneReferenceFrame() throws {
        let encoder = H264Encoder(configuration: .init(
            width: 1_280, height: 720, framerate: 30, bitrate: 2_500_000
        ))
        let sets = Mutex<[[UInt8]]>([])
        encoder.onEncodedFrame = { _, parameterSets, _ in
            guard !parameterSets.isEmpty else { return }
            sets.withLock { if $0.isEmpty { $0 = parameterSets } }
        }
        try encoder.start()
        encoder.encode(
            try VideoPathTests().makePixelBuffer(seed: 3),
            at: CMTime(value: 0, timescale: 90_000),
            forceKeyframe: true
        )
        encoder.teardown()

        let parameterSets = sets.withLock { $0 }
        let sps = try #require(
            parameterSets.first { $0.first.map { $0 & 0x1F } == H264.NALType.sps.rawValue },
            "the keyframe carried no SPS"
        )
        let references = try #require(SPSReader.maxReferenceFrames(inSPS: sps))
        // One literal, because a `Comment` is expressible by string
        // interpolation and not by concatenation.
        #expect(references == 1, "Error 2015: the stream declares \(references) reference frames")
    }
}
