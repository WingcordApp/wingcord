import CoreMedia
import CoreVideo
import Foundation
import OSLog
import VideoToolbox

// MARK: - H.264, in hardware, both ways
//
// **Nothing here implements a codec.** VideoToolbox encodes on the Apple Neural
// Engine's media block and `AVSampleBufferDisplayLayer` decodes on the same
// hardware and puts the result straight on a surface — so the whole video path
// is two frameworks and a packetiser, with no software codec, no colour-space
// conversion in Swift and no per-frame copy anywhere.
//
// The profile is **constrained baseline**, and that is an interoperability
// decision rather than a quality one. High profile is better at the same
// bitrate; constrained baseline is the one profile every WebRTC implementation
// is required to decode, which is what the reference client is built on. A
// stream nobody can see is not a better stream.

public final class H264Encoder: @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Video")

    public struct Configuration: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var framerate: Int
        public var bitrate: Int

        public init(width: Int, height: Int, framerate: Int, bitrate: Int) {
            self.width = width
            self.height = height
            self.framerate = framerate
            self.bitrate = bitrate
        }
    }

    /// Called on VideoToolbox's own callback thread with one finished access
    /// unit: its NAL units, the parameter sets to send ahead of it, whether it
    /// is a keyframe, and the presentation time it was submitted with — which
    /// is when it was captured, not when it finished encoding.
    public var onEncodedFrame: (@Sendable ([[UInt8]], [[UInt8]], Bool, CMTime) -> Void)?
    /// Each sample as VideoToolbox made it, before anything is taken out of
    /// it — a Go Live stream's clips come off this (docs/CLIPS-PRESENCE.md,
    /// Phase 3.6). Set before `start`.
    public var onSample: (@Sendable (CMSampleBuffer) -> Void)?

    private var session: VTCompressionSession?
    private var configuration: Configuration
    private let lock = NSLock()

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit { teardown() }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        try open()
    }

    private func open() throws {
        teardownLocked()

        // **No low-latency rate controller.** It was here to hold the bitrate
        // tightly frame to frame, and it costs two things that matter far more.
        //
        // It declares a **five frame reference buffer** in the SPS —
        // `max_num_ref_frames = 5`, with a VUI carrying
        // `max_dec_frame_buffering = 5` — which tells a receiver to hold five
        // frames before it may show anything. And it **drops half the frames**:
        // measured, ninety submitted and forty-seven emitted, at any data rate
        // ceiling. A thirty frame stream arriving at fifteen.
        //
        // Without it the encoder emits `max_num_ref_frames = 1` and every frame
        // it is given. `EncoderConformanceTests` pins the first of those; the
        // frame count is visible in the trace as `frames=` beside `video=`.
        //
        // It also emits **no VUI**, and that is not harmless: a WebRTC
        // receiver rewrites such an SPS before DAVE checks it, and the keyframe
        // then fails authentication. `emit` gives every SPS the VUI WebRTC's
        // own sender gives it — see `H264VUI.swift`.
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw Failure.session(status) }
        self.session = session

        applyCommonProperties()
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// Everything a realtime H.264 stream has to be told, in one place.
    private func applyCommonProperties() {
        apply(kVTCompressionPropertyKey_RealTime, true)
        apply(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
        // No entropy coding a baseline decoder cannot read. Constrained
        // baseline forbids CABAC anyway; naming it means a profile change
        // cannot quietly introduce it.
        apply(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CAVLC)
        // Emit each frame as it finishes rather than holding any back. With
        // reordering already off this should be implied; it is one more way for
        // a frame to arrive late and it costs nothing to close.
        apply(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        // No B-frames. They cost a frame of latency to gain a few per cent of
        // bitrate, and constrained baseline has none anyway — naming it means a
        // profile change cannot quietly add one.
        apply(kVTCompressionPropertyKey_AllowFrameReordering, false)
        apply(kVTCompressionPropertyKey_MaxKeyFrameInterval, configuration.framerate * 2)
        apply(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2)
        apply(kVTCompressionPropertyKey_ExpectedFrameRate, configuration.framerate)
        applyBitrate(configuration.bitrate)
    }

    /// The average and its ceiling, which always move together.
    ///
    /// The ceiling is over one second, in bytes. Without it the encoder is free
    /// to spend a whole second's budget on one keyframe, and a keyframe that
    /// needs forty packets in one frame interval is a keyframe the path drops
    /// half of.
    ///
    /// **Twice the average, and twice everywhere.** A ceiling a quarter over
    /// the target does not shape the bitrate, it makes the encoder drop frames
    /// to stay under it: measured, ninety frames submitted and **forty-seven**
    /// emitted, at 1.25× — which is what a reconfiguration used to write while
    /// the session's creation wrote twice.
    private func applyBitrate(_ bitrate: Int) {
        apply(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        apply(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8 * 2, 1] as CFArray)
    }

    /// A new size, rate or bitrate.
    ///
    /// A size change is a new session, because the encoder's dimensions are
    /// fixed at creation — and a new session's first frame is a keyframe
    /// carrying the new parameter sets, which is what a receiver needs to
    /// follow it. Anything else is a property write on the running session.
    public func reconfigure(_ next: Configuration) {
        lock.lock()
        defer { lock.unlock() }
        guard next != configuration else { return }
        let needsNewSession = next.width != configuration.width
            || next.height != configuration.height
        configuration = next
        if needsNewSession {
            do {
                try open()
            } catch {
                Self.log.error("encoder would not reopen at \(next.width)x\(next.height): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            apply(kVTCompressionPropertyKey_ExpectedFrameRate, next.framerate)
            applyBitrate(next.bitrate)
        }
    }

    /// Only the bitrate, as the far end's reports move it.
    public func setBitrate(_ bitrate: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard bitrate != configuration.bitrate else { return }
        configuration.bitrate = bitrate
        applyBitrate(bitrate)
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime, forceKeyframe: Bool) {
        lock.lock()
        guard let session else { lock.unlock(); return }
        lock.unlock()

        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer,
                  CMSampleBufferDataIsReady(sampleBuffer) else { return }
            emit(sampleBuffer)
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        onSample?(sampleBuffer)
        let units = H264.nalUnits(from: sampleBuffer)
        guard !units.isEmpty else { return }

        // A keyframe carries the parameter sets with it. Sending them only once
        // at the start of a stream means anybody who joins later — which is
        // everybody, in a channel people come and go from — has no format
        // description and shows a black rectangle for ever.
        //
        // **The SPS leaves in the form a WebRTC receiver keeps.** VideoToolbox
        // writes it with no VUI, which the receiver rewrites before DAVE
        // authenticates it, so every keyframe would fail at the far end. This
        // is the pass WebRTC's own sender makes on its encoder's output. An
        // AVCC sample never carries an SPS in-band, so the format
        // description's are the only ones there are.
        let isKeyframe = Self.isKeyframe(sampleBuffer)
        var sets: [[UInt8]] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            sets = H264.parameterSets(from: format).map(H264.receiverStableSPS)
        }
        onEncodedFrame?(
            units, sets, isKeyframe, CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[CFString: Any]], let first = attachments.first else { return true }
        // The attachment says whether the frame DEPENDS on others. Its absence
        // means it does not, which is a keyframe — so the default when the
        // attachment is missing has to be `true`, not `false`.
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private func apply(_ key: CFString, _ value: Any) {
        guard let session else { return }
        VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
    }

    public func teardown() {
        lock.lock()
        defer { lock.unlock() }
        teardownLocked()
    }

    private func teardownLocked() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    public enum Failure: Error, Sendable { case session(OSStatus) }
}

// MARK: - The receiving side

/// Turns reassembled NAL units into something a display layer can take.
///
/// **There is no decompression session here on purpose.**
/// `AVSampleBufferDisplayLayer` decodes what it is given, on the same hardware a
/// `VTDecompressionSession` would use, and puts the result on its own surface —
/// so decoding by hand and then drawing the `CVPixelBuffer` means a decode, a
/// texture upload and a draw where the framework does one step. It is also the
/// only path that keeps the frames in the display's colour space without a
/// conversion in the middle.
public final class H264SampleBuilder {
    private var format: CMFormatDescription?
    private var parameterSetsFingerprint: [[UInt8]] = []

    public init() {}

    /// Rebuilds the format description when the parameter sets change.
    ///
    /// Compared by value rather than by "have I seen any": a stream that
    /// changes resolution sends new sets, and a builder that keeps the first
    /// description it made hands the decoder pictures of a size the description
    /// says they are not.
    public func updateParameterSets(_ sets: [[UInt8]]) {
        guard sets.count >= 2, sets != parameterSetsFingerprint,
              !sets.contains(where: \.isEmpty)
        else { return }

        // **One buffer, and every pointer into it made and used inside the one
        // closure that lends it.** This used to collect each set's
        // `baseAddress` from its own `withUnsafeBufferPointer` and use them
        // after those closures had returned — which worked only because nothing
        // happened to move the arrays in between, and is undefined behaviour
        // whether or not it does.
        let sizes = sets.map(\.count)
        let joined = Array(sets.joined())
        var description: CMFormatDescription?
        let created = joined.withUnsafeBufferPointer { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
            var offset = 0
            let pointers = sizes.map { size -> UnsafePointer<UInt8> in
                defer { offset += size }
                return base + offset
            }
            return pointers.withUnsafeBufferPointer { list in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: list.count,
                    parameterSetPointers: list.baseAddress!,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard created == noErr, let description else { return }
        format = description
        parameterSetsFingerprint = sets
    }

    /// One access unit as a sample buffer, in AVCC with four-byte lengths.
    public func sampleBuffer(
        units: [[UInt8]],
        presentationTime: CMTime,
        isKeyframe: Bool
    ) -> CMSampleBuffer? {
        guard let format, !units.isEmpty else { return nil }

        var avcc = [UInt8]()
        avcc.reserveCapacity(units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let length = UInt32(unit.count)
            avcc.append(UInt8(truncatingIfNeeded: length >> 24))
            avcc.append(UInt8(truncatingIfNeeded: length >> 16))
            avcc.append(UInt8(truncatingIfNeeded: length >> 8))
            avcc.append(UInt8(truncatingIfNeeded: length))
            avcc.append(contentsOf: unit)
        }

        var block: CMBlockBuffer?
        // The bytes are copied into the block buffer's own allocation rather
        // than referenced, because `avcc` is a Swift array whose storage goes
        // away at the end of this call while the sample buffer outlives it.
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }
        guard CMBlockBufferReplaceDataBytes(
            with: avcc, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count
        ) == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sizes = [avcc.count]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizes,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        // **Display immediately, and it is what makes this a call rather than a
        // broadcast.** Without it the renderer holds each frame until its
        // presentation time comes round on its own timebase, which for a live
        // stream with no timebase means a growing delay that never recovers.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true
        ) as? [CFMutableDictionary], let first = attachments.first {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !isKeyframe {
                CFDictionarySetValue(
                    first,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sample
    }

    public func reset() {
        format = nil
        parameterSetsFingerprint = []
    }
}
