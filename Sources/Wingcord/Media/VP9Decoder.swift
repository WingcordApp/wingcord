import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Everything a VP9 frame says about itself before its first coefficient.
///
/// **Read here because VideoToolbox will not read it.** A WebM carries no
/// configuration record for VP9 — ffmpeg writes no `CodecPrivate`, and there is
/// nowhere in Matroska for one — so the profile, the bit depth, the chroma
/// layout and the colour range exist only in the bitstream's own uncompressed
/// header. `VTDecompressionSessionCreate` needs all four *before* it will look
/// at a frame, so they are parsed out and handed back to it as the `vpcC` box
/// the ISOBMFF binding defines. Without that box the session refuses to open at
/// all — measured: `-8971`, with a format description that is otherwise
/// complete.
///
/// Only the fields that decide those four are read. The rest of the header is
/// loop-filter levels, segmentation and tile layout, which is the decoder's
/// business and not this file's.
nonisolated struct VP9Header: Equatable, Sendable {
    /// 0-3. Only profile 0 — eight-bit 4:2:0 — is played; see `isPlayable`.
    var profile: Int
    var isKeyframe: Bool
    var bitDepth: Int
    /// VP9's own colour space enum, 0-7. 0 is "unknown", which is what every
    /// nameplate carries and what makes the conversion matrix this app's choice.
    var colorSpace: Int
    /// Video range (16-235) or full (0-255). **This decides the pixel format the
    /// session is asked for**, and getting it wrong silently rescales the alpha
    /// channel — which is stored as a luma plane and must arrive untouched.
    var isFullRange: Bool
    var subsamplingX: Bool
    var subsamplingY: Bool
    var width: Int
    var height: Int

    /// Eight-bit 4:2:0, which is every nameplate and every WebM libvpx writes by
    /// default.
    ///
    /// **Anything else is refused rather than attempted.** A 10-bit or 4:4:4
    /// stream would need a different pixel format, a different vImage
    /// conversion and a different premultiply, and there is no asset on
    /// Discord's CDN to check any of it against — an untested path that produces
    /// pictures is worse than a still, because nobody sees that it is wrong.
    var isPlayable: Bool {
        profile == 0 && bitDepth == 8 && subsamplingX && subsamplingY
            && width > 0 && height > 0
    }

    /// VP9's marker for "these are RGB samples, not luma and chroma".
    private static let colorSpaceRGB = 7

    /// Parses the uncompressed header, or returns nil when the bytes are not a
    /// VP9 frame at all.
    ///
    /// Only a **keyframe** carries the frame size and the colour configuration;
    /// an inter frame refers back to the last one. That is enough, because the
    /// only header this app reads is the first frame's and a stream whose first
    /// frame is not a keyframe cannot be decoded from the start anyway.
    static func parse(_ frame: Data) -> VP9Header? {
        var reader = BitReader(frame)
        guard reader.bits(2) == 2 else { return nil }  // frame_marker
        // Two bits, low first — the one place in this header where the order
        // is not the order the value reads in.
        let profileLow = reader.next()
        let profileHigh = reader.next()
        let profile = Int(profileHigh << 1 | profileLow)
        if profile == 3, reader.next() != 0 { return nil }  // reserved_zero
        guard reader.next() == 0 else { return nil }  // show_existing_frame
        let isKeyframe = reader.next() == 0
        _ = reader.next()  // show_frame
        _ = reader.next()  // error_resilient_mode
        guard isKeyframe else { return nil }
        // The sync code, which is what makes this a VP9 frame rather than three
        // bytes that happened to start with the right two bits.
        guard reader.bits(24) == 0x49_8342 else { return nil }

        let bitDepth = profile >= 2 ? (reader.next() == 1 ? 12 : 10) : 8
        let colorSpace = Int(reader.bits(3))
        var isFullRange = true
        var subsamplingX = true
        var subsamplingY = true
        if colorSpace == colorSpaceRGB {
            // RGB is 4:4:4 by definition and always full range.
            subsamplingX = false
            subsamplingY = false
            if profile == 1 || profile == 3, reader.next() != 0 { return nil }
        } else {
            isFullRange = reader.next() == 1
            if profile == 1 || profile == 3 {
                subsamplingX = reader.next() == 1
                subsamplingY = reader.next() == 1
                if reader.next() != 0 { return nil }  // reserved_zero
            }
        }
        let width = Int(reader.bits(16)) + 1
        let height = Int(reader.bits(16)) + 1
        guard !reader.isOverrun else { return nil }

        return VP9Header(
            profile: profile,
            isKeyframe: isKeyframe,
            bitDepth: bitDepth,
            colorSpace: colorSpace,
            isFullRange: isFullRange,
            subsamplingX: subsamplingX,
            subsamplingY: subsamplingY,
            width: width,
            height: height
        )
    }

    /// The `vpcC` configuration record, as the VP9-in-ISOBMFF binding defines
    /// it — twelve bytes, and the whole of what VideoToolbox is told about this
    /// stream before it sees a frame.
    ///
    /// **The level is written as 0, "unspecified", and that is verified rather
    /// than assumed.** A level is a ceiling on sample rate and tile count, and
    /// the real one is derivable only from the frame rate — which lives in the
    /// container, not the bitstream. VideoToolbox opens the session on 0 and
    /// takes the frame's real dimensions from the bitstream's own header, which
    /// is the number that actually bounds its allocations.
    var configurationRecord: Data {
        var record = Data(capacity: 12)
        record.append(1)  // version
        record.append(contentsOf: [0, 0, 0])  // flags
        record.append(UInt8(profile))
        record.append(0)  // level: unspecified
        let chroma: UInt8 = subsamplingX && subsamplingY ? 1 : (subsamplingX ? 2 : 3)
        record.append(UInt8(bitDepth) << 4 | chroma << 1 | (isFullRange ? 1 : 0))
        record.append(colorPrimaries)
        record.append(transferCharacteristics)
        record.append(matrixCoefficients)
        record.append(contentsOf: [0, 0])  // codecInitializationDataSize
        return record
    }

    /// VP9's eight colour spaces, as the CICP codes `vpcC` carries. The mapping
    /// is the one the VP9 specification's own colour-space table defines; `2` is
    /// "unspecified" in all three fields.
    private var colorPrimaries: UInt8 {
        switch colorSpace {
        case 1: 5   // BT.470 System B/G
        case 2: 1   // BT.709
        case 3, 4: 6  // SMPTE 170M / 240M share primaries
        case 5: 9   // BT.2020
        default: 2
        }
    }

    private var transferCharacteristics: UInt8 {
        switch colorSpace {
        case 1: 6   // BT.601
        case 2: 1   // BT.709
        case 3: 6
        case 4: 7   // SMPTE 240M
        case 5: 14  // BT.2020 10-bit
        default: 2
        }
    }

    private var matrixCoefficients: UInt8 {
        switch colorSpace {
        case 1: 5   // BT.470BG
        case 2: 1   // BT.709
        case 3: 6   // SMPTE 170M
        case 4: 7   // SMPTE 240M
        case 5: 9   // BT.2020 non-constant luminance
        case Self.colorSpaceRGB: 0  // Identity
        default: 2
        }
    }

    /// Big-endian bits, most significant first — VP9's own order.
    ///
    /// Overrun is latched rather than trapped: a truncated frame is an ordinary
    /// thing to be handed off a network, and the caller's answer to it is the
    /// same as its answer to a frame that is not VP9 at all.
    private struct BitReader {
        private let data: Data
        private var index: Int
        private var shift = 0
        private(set) var isOverrun = false

        init(_ data: Data) {
            self.data = data
            index = data.startIndex
        }

        mutating func next() -> UInt32 {
            guard index < data.endIndex else {
                isOverrun = true
                return 0
            }
            let value = UInt32(data[index] >> (7 - shift) & 1)
            shift += 1
            if shift == 8 {
                shift = 0
                index += 1
            }
            return value
        }

        mutating func bits(_ count: Int) -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<count { value = value << 1 | next() }
            return value
        }
    }
}

/// One VP9 elementary stream, decoded a frame at a time.
///
/// **VideoToolbox does the decoding and nothing here does.** macOS ships a VP9
/// decoder; it is simply not registered by default, because VP9 is not a
/// platform format — `VTRegisterSupplementalVideoDecoderIfAvailable` is the
/// documented opt-in and without it the session cannot be created. That call is
/// made once, lazily, by the first decoder anybody builds.
///
/// **One instance per stream, and a nameplate is two of them.** WebM stores
/// alpha as a second complete VP9 bitstream with its own reference frames, so
/// feeding both through one session would have each frame predicting from the
/// other stream's picture — which decodes to something, which is the worst kind
/// of wrong. See `WebMDemuxer` for how the two arrive.
///
/// **Frames go in in order and come back one at a time.** VP9 has no B-frames,
/// so presentation order is coded order and there is no reordering to undo; the
/// session is drained after every frame so the peak is one picture rather than
/// the whole loop.
nonisolated final class VP9Decoder {
    private let session: VTDecompressionSession
    private let format: CMVideoFormatDescription
    private let sink = Sink()

    /// Where VideoToolbox leaves the picture.
    ///
    /// **A box rather than the decoder itself**, because the output handler is
    /// `@Sendable` and a decoder is not — capturing `self` in one is the
    /// warning this exists to avoid rather than silence.
    ///
    /// The `@unchecked` is discharged by the drain, not waved at: with neither
    /// asynchronous flag set, `VTDecompressionSessionDecodeFrame` is documented
    /// not to return until the handler has run, and the wait after it is a
    /// second barrier. There is no moment when two threads are looking at this.
    private final class Sink: @unchecked Sendable {
        var buffer: CVPixelBuffer?
    }

    /// The registration is a process-wide, idempotent opt-in; `let` on a static
    /// is Swift's once-only initialiser.
    private static let isVP9Registered: Bool = {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        return true
    }()

    /// Nil when the stream is one VideoToolbox will not open. Two things put it
    /// there, and both are answers the caller treats the same way — draw the
    /// still:
    ///
    ///  - **A profile this does not play.** See `VP9Header.isPlayable`.
    ///  - **A frame smaller than 64x64 in either dimension.** Measured: the
    ///    session refuses 63 rows and accepts 64, at every width, and refuses
    ///    63 columns at every height. Nothing Discord serves comes near it — a
    ///    nameplate is 672x126 — but a fixture written small enough to read
    ///    inline does, which is how it was found.
    ///
    /// - Parameter pixelFormat: what the frames are wanted as. **Pass the format
    ///   matching the stream's own range** — `420v` for video range, `420f` for
    ///   full — so VideoToolbox hands the decoded planes over untouched. Asking
    ///   for the other one makes it rescale them, which is right for a picture
    ///   and destroys an alpha channel stored as luma.
    init?(header: VP9Header, pixelFormat: OSType) {
        guard header.isPlayable, Self.isVP9Registered else { return nil }

        var format: CMVideoFormatDescription?
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:
                ["vpcC": header.configurationRecord] as CFDictionary
        ]
        guard CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_VP9,
            width: Int32(header.width),
            height: Int32(header.height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var session: VTDecompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            // Backed by an IOSurface so the planes can be read without a copy
            // out of the decoder's own memory.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        ) == noErr, let session else { return nil }

        self.format = format
        self.session = session
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    /// Decodes one frame, in order.
    ///
    /// Nil means this frame did not produce a picture — a corrupt frame, or one
    /// predicting from a reference that never arrived. The caller stops rather
    /// than skipping: every frame after it predicts from this one.
    func decode(_ frame: Data) -> CVPixelBuffer? {
        guard let sample = sampleBuffer(for: frame) else { return nil }
        let sink = sink
        sink.buffer = nil
        var flags = VTDecodeInfoFlags()
        // **Neither asynchronous flag**, which is what makes the handler run
        // before this returns and keeps the peak at one picture rather than the
        // whole loop.
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: &flags
        ) { status, _, image, _, _ in
            guard status == noErr else { return }
            sink.buffer = image
        }
        guard status == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return sink.buffer
    }

    /// Wraps one coded frame as a sample buffer.
    ///
    /// The timing is nominal — one frame at time zero. Nothing downstream reads
    /// it: the filmstrip's timeline comes from the container's timestamps, which
    /// is where a WebM keeps it.
    private func sampleBuffer(for frame: Data) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.count,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }

        let copied = frame.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: frame.count
            )
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = frame.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}
