import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization

// MARK: - Screen share
//
// ScreenCaptureKit, which is the only supported way to do this on a modern Mac
// and is better than what it replaced in every dimension that matters here: the
// frames arrive as IOSurface-backed `CVPixelBuffer`s already in a 4:2:0 format
// the encoder takes, the capture happens in the window server rather than
// through a screenshot loop, and it can capture an application's **audio**
// alongside its pixels — which is what makes sharing a game or a video with
// sound possible at all.
//
// **What is captured is chosen in the system's own picker**, never in a list
// this app draws. `SCContentSharingPicker` is Control Center's, it is what
// Discord uses on a Mac when its "Use operating system menus to select a screen
// capture source" is on, and a pick made in it grants the capture that one
// source without asking for Screen Recording at all. The cost is that the
// filter comes back whole: a display picked there includes this app's own
// windows, exactly as Discord's display shares include Discord's.
//
// **Captured from the pick, sent from Go Live.** The capture starts the moment
// a source is picked, so the Go Live sheet shows the picture that will be
// sent; nothing reaches an encoder until a media session takes the capture
// over and routes its outputs there.
//
// Three things it does that a naive integration misses, and each shows up as a
// visible defect:
//
//   * `queueDepth` bounds how many frames are in flight. Left at the default a
//     slow encoder builds a queue that never drains, and the share runs
//     seconds behind the screen.
//   * A frame arrives on **every change**, including none — ScreenCaptureKit
//     repeats the last frame to keep the stream alive. `SCStreamFrameInfo`'s
//     status says which, and encoding the idle repeats is a third of the
//     bitrate spent on a still picture.
//   * The configuration's size is the *capture* size. Asking for the display's
//     full retina dimensions means encoding 5120x2880, which no channel has the
//     bitrate for and no tile has the pixels to show.

/// What was picked in the system's picker, and what it measures.
///
/// **`@unchecked` because `SCContentFilter` is not marked `Sendable`**, and
/// nothing here mutates it: the picker hands it over complete, this reads its
/// size once, and ScreenCaptureKit is the only thing that reads it after that.
public struct ShareSource: @unchecked Sendable {
    let filter: SCContentFilter
    /// Discord's name for what is shared (its module 613235): the windows'
    /// titles, else the applications' names, else "Entire Screen".
    public let name: String
    /// The source's own size, in pixels.
    public let width: Int
    public let height: Int
    /// Whether windows or applications were picked rather than a display —
    /// what makes Discord's menu offer "Add Window" or "Add Application".
    public let hasWindows: Bool
    public let hasApplications: Bool

    init(filter: SCContentFilter) {
        self.filter = filter
        let scale = CGFloat(filter.pointPixelScale)
        width = Int((filter.contentRect.width * scale).rounded())
        height = Int((filter.contentRect.height * scale).rounded())
        let windows = filter.includedWindows.compactMap { $0.title.flatMap { $0.isEmpty ? nil : $0 } }
        let applications = filter.includedApplications.map(\.applicationName)
        hasWindows = !filter.includedWindows.isEmpty
        hasApplications = !filter.includedApplications.isEmpty
        if !windows.isEmpty {
            name = windows.joined(separator: ", ")
        } else if !applications.isEmpty {
            name = applications.joined(separator: ", ")
        } else if !filter.includedDisplays.isEmpty || filter.style == .display {
            name = "Entire Screen"
        } else {
            // Discord's own words for a pick it cannot name.
            name = "A window, screen, or app"
        }
    }
}

public final class ScreenShareCapture: NSObject, @unchecked Sendable {

    /// The box a share is fitted inside, how often it is captured, and
    /// whether its sound comes with it.
    public struct Quality: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var framerate: Int
        public var capturesAudio: Bool

        public init(width: Int, height: Int, framerate: Int, capturesAudio: Bool) {
            self.width = width
            self.height = height
            self.framerate = framerate
            self.capturesAudio = capturesAudio
        }
    }

    /// Where the capture's output goes.
    ///
    /// **Swapped while it runs**: a Go Live sheet's preview before the share
    /// is live, the encoder and the self tile after. So the whole set sits
    /// behind one lock that the capture queue reads once per sample, and a
    /// caller replaces it in one write rather than closure by closure — half
    /// a set is a frame routed to an encoder whose preview is still the
    /// sheet's.
    public struct Outputs: Sendable {
        /// Every frame whose content changed.
        public var frame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
        /// The last picture that changed, offered again on every tick the
        /// screen does not — so a viewer who needs a keyframe of a screen at
        /// rest can be sent one. The receiver decides whether anybody is
        /// waiting.
        public var still: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
        /// A **copy** of each frame, at the capture's own rate, for a preview.
        ///
        /// **ScreenCaptureKit has no `AVCaptureVideoPreviewLayer`.** A
        /// camera's self-view is a second hardware path that never goes near
        /// the encoder; a share has no such thing, so the only picture of our
        /// own screen is these frames. Without them the self tile falls
        /// through to the **inbound** video view, which waits for a stream
        /// from our own user id that by definition never arrives — measured
        /// live as a tile that stayed black for a whole call while the
        /// capture, the encoder and the send path were all healthy.
        ///
        /// **And the frames may not be ScreenCaptureKit's own.** Its buffers
        /// come from a pool `queueDepth` frames deep, and a buffer that is
        /// still referenced cannot be recycled — `AVSampleBufferDisplayLayer`
        /// retains every one it is given, so handing them straight over
        /// drains the pool and the stream stops producing. It does not error
        /// and it does not stop; it simply never calls the delegate again.
        /// Measured: one keyframe out, then `frames=0` for the rest of the
        /// call with the packet count frozen.
        ///
        /// So each frame is copied into a pool of ours first. **At the
        /// capture's own rate**, because a preview is how the reader judges
        /// what the far end is getting and a stuttering one reads as a
        /// stuttering share: throttling this to eight a second was measured as
        /// "very low fps, like 4-5" by the person watching it. The copy is a
        /// `memcpy` of a frame bounded by the quality box, and the pool makes
        /// it allocation-free after the first few.
        public var preview: (@Sendable (CMSampleBuffer) -> Void)?
        /// One 20 ms frame of the shared sound: 1,920 interleaved stereo
        /// samples at 48 kHz, and its linear level.
        public var audio: (@Sendable (UnsafePointer<Int16>, Float) -> Void)?
        /// The capture stopped for a reason that is not us — the window
        /// closed, the reader stopped it from the menu bar, the permission
        /// was revoked.
        public var stopped: (@Sendable (String) -> Void)?

        public init(
            frame: (@Sendable (CVPixelBuffer, CMTime) -> Void)? = nil,
            still: (@Sendable (CVPixelBuffer, CMTime) -> Void)? = nil,
            preview: (@Sendable (CMSampleBuffer) -> Void)? = nil,
            audio: (@Sendable (UnsafePointer<Int16>, Float) -> Void)? = nil,
            stopped: (@Sendable (String) -> Void)? = nil
        ) {
            self.frame = frame
            self.still = still
            self.preview = preview
            self.audio = audio
            self.stopped = stopped
        }
    }

    public enum Failure: Error, Sendable {
        /// Asked to change a capture that is not running.
        case notRunning
    }

    private let outputs = Mutex(Outputs())

    /// The running stream and what it was asked for. Changed from whichever
    /// actor drives the share — the app before Go Live, the media session
    /// after — and never from the capture queue.
    ///
    /// **`@unchecked` for the `SCStream`**, which is not marked `Sendable` but
    /// whose methods may be called from any thread; this only holds it and
    /// hands it back.
    private struct Control: @unchecked Sendable {
        var stream: SCStream?
        var source: ShareSource?
        var quality: Quality?
    }

    private let control = Mutex(Control())
    private let queue = DispatchQueue(label: "dev.wingcord.screenshare", qos: .userInitiated)

    // MARK: The self-view's own copies
    //
    // Touched only from `queue`, which ScreenCaptureKit delivers on serially.

    private var previewPool: CVPixelBufferPool?
    private var previewFormat: CMVideoFormatDescription?
    private var previewShape: (width: Int, height: Int, pixelFormat: OSType) = (0, 0, 0)
    private var hasReportedPreviewFailure = false
    /// The timestamp the preview's clock is measured from.
    ///
    /// **ScreenCaptureKit's presentation timestamps are on the mach timebase**,
    /// which is hundreds of thousands of seconds, and the renderer's own
    /// timebase starts at zero when its view is made. A sample handed over with
    /// its raw timestamp is a sample scheduled for a time that never comes: the
    /// layer paints the first one, because it has nothing else to show, and
    /// then holds every one after it for ever. That is a preview frozen on its
    /// first frame with a capture running perfectly behind it — and it is what
    /// the inbound path already avoids by rebasing to zero.
    private var previewClockBase: CMTime?
    /// The picture the screen last changed to, for `Outputs.still`.
    ///
    /// **One of ScreenCaptureKit's own buffers, and only ever one.** Its pool
    /// is `queueDepth` frames deep and a held buffer is not recycled — the
    /// self-view once held every frame it was given and stopped the capture
    /// dead. This holds the latest and lets it go the moment the next arrives,
    /// so the pool always keeps all but one, and a still screen costs no copy.
    /// Touched only from `queue`.
    private var lastPicture: CVPixelBuffer?

    // MARK: The sound's own frames
    //
    // ScreenCaptureKit delivers sound in buffers of its own length, and Opus
    // takes exactly 20 ms. These gather one frame, interleaved, as `Int16` —
    // allocated once, and touched only from `queue`.

    private var soundFrame = [Int16](repeating: 0, count: OpusFormat.interleavedCount)
    private var soundFilled = 0
    private var soundEnergy: Float = 0
    /// Room for the two channel buffers a stereo capture delivers, so reading
    /// one allocates nothing.
    private let soundBuffers = AudioBufferList.allocate(maximumBuffers: 2)
    private var hasReportedSoundFormat = false

    public override init() { super.init() }

    deinit { free(soundBuffers.unsafeMutablePointer) }

    // MARK: Routing

    /// Replaces where everything goes, in one write.
    ///
    /// **And the preview's clock starts again**, because a preview is a new
    /// renderer whose own clock starts at zero when its view is made. A frame
    /// still timed from when the capture began is ahead of that renderer by
    /// however long the capture ran before the view existed, and is shown that
    /// much late — every frame, for as long as the preview runs.
    public func route(_ outputs: Outputs) {
        self.outputs.withLock { $0 = outputs }
        queue.async { [self] in previewClockBase = nil }
    }

    /// The stream, for the picker to present against when the reader changes
    /// what is shared.
    var stream: SCStream? { control.withLock { $0.stream } }

    /// What is being shared, while it runs.
    public var source: ShareSource? { control.withLock { $0.source } }

    // MARK: Running

    /// The size frames arrive at, for a source in a quality's box.
    public struct Shape: Sendable, Equatable {
        public var width: Int
        public var height: Int
    }

    /// Starts capturing a picked source.
    ///
    /// - Returns: the size its frames will arrive at.
    @discardableResult
    public func start(source: ShareSource, quality: Quality) async throws -> Shape {
        let shape = Self.shape(of: source, in: quality)
        let stream = SCStream(
            filter: source.filter,
            configuration: Self.configuration(shape: shape, quality: quality),
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        // **Always, and switched by the configuration.** Share Audio can be
        // turned on while the share runs, and an output added to a running
        // stream is not one ScreenCaptureKit promises to honour.
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        control.withLock { $0 = Control(stream: stream, source: source, quality: quality) }
        return shape
    }

    /// Moves a running capture to another box, frame rate, or sound setting.
    @discardableResult
    public func update(quality: Quality) async throws -> Shape {
        guard let (stream, source) = control.withLock({ control in
            control.stream.flatMap { stream in control.source.map { (stream, $0) } }
        }) else { throw Failure.notRunning }
        let shape = Self.shape(of: source, in: quality)
        try await stream.updateConfiguration(Self.configuration(shape: shape, quality: quality))
        control.withLock { $0.quality = quality }
        if !quality.capturesAudio { queue.async { [self] in soundFilled = 0 } }
        return shape
    }

    /// Moves a running capture to another source — Discord's Change Windows.
    @discardableResult
    public func update(source: ShareSource) async throws -> Shape {
        guard let (stream, quality) = control.withLock({ control in
            control.stream.flatMap { stream in control.quality.map { (stream, $0) } }
        }) else { throw Failure.notRunning }
        let shape = Self.shape(of: source, in: quality)
        try await stream.updateContentFilter(source.filter)
        try await stream.updateConfiguration(Self.configuration(shape: shape, quality: quality))
        control.withLock { $0.source = source }
        // The held picture belongs to what was shared before.
        queue.async { [self] in lastPicture = nil }
        return shape
    }

    public func stop() async {
        let stream = control.withLock { control -> SCStream? in
            defer { control = Control() }
            return control.stream
        }
        route(Outputs())
        // **The preview's clock starts again with the next share.** Keeping the
        // old base makes a second share's first frame arrive minutes ahead of
        // the renderer's timebase, which is the freeze this rebasing exists to
        // prevent — one share later.
        queue.async { [self] in
            previewClockBase = nil
            lastPicture = nil
            soundFilled = 0
        }
        try? await stream?.stopCapture()
    }

    private static func shape(of source: ShareSource, in quality: Quality) -> Shape {
        let fitted = fit(
            width: source.width, height: source.height,
            into: quality.width, by: quality.height
        )
        return Shape(width: fitted.width, height: fitted.height)
    }

    private static func configuration(shape: Shape, quality: Quality) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // The source's aspect, fitted inside the quality's box. A configuration
        // whose ratio differs from the source's is letterboxed by
        // ScreenCaptureKit into bars this app then spends bitrate encoding.
        configuration.width = shape.width
        configuration.height = shape.height
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(quality.framerate)
        )
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        // Five frames of headroom. Fewer drops frames on any hitch; more is
        // latency the viewer sees and can never get back.
        configuration.queueDepth = 5
        configuration.scalesToFit = true
        configuration.capturesAudio = quality.capturesAudio
        configuration.sampleRate = Int(OpusFormat.sampleRate)
        configuration.channelCount = Int(OpusFormat.channels)
        // **Never our own sound.** This app plays the call; a share that
        // captured it would send everybody's voices back to them, a stream's
        // length late.
        configuration.excludesCurrentProcessAudio = true
        return configuration
    }

    /// The largest box with the source's aspect that fits inside the target,
    /// **rounded down to whole macroblocks**.
    ///
    /// Even numbers are the floor — 4:2:0 chroma is subsampled by two, and an
    /// odd dimension is a column the encoder has to pad. Sixteen is the number
    /// actually used, because that is H.264's macroblock and anything else is a
    /// picture the encoder describes with a cropping rectangle in its SPS. The
    /// crop is conformant and every decoder is required to honour it; what is
    /// not required is that every *implementation between here and a decoder*
    /// does, and a laptop's 1710-wide display fitted into 720p gives 1108,
    /// which is not a multiple of eight let alone sixteen.
    ///
    /// Discord's own boxes — 1280×720, 1920×1080, 2560×1440 — are all whole
    /// macroblocks, which is one fewer difference between what this client
    /// sends and what a client whose stream renders sends. Rounded **down**, so
    /// the result still fits inside the target.
    static func fit(width: Int, height: Int, into maxWidth: Int, by maxHeight: Int)
        -> (width: Int, height: Int)
    {
        guard width > 0, height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height), 1)
        let fittedWidth = max(16, Int((Double(width) * scale).rounded(.down)) & ~15)
        let fittedHeight = max(16, Int((Double(height) * scale).rounded(.down)) & ~15)
        return (fittedWidth, fittedHeight)
    }

    // MARK: The preview

    /// Copies one frame into a pool of ours and hands it to the preview — the
    /// Go Live sheet before the share is live, the self tile after.
    ///
    /// Runs on the capture queue, and returns without allocating when nothing
    /// is attached or the interval has not elapsed.
    private func emitPreview(_ source: CVPixelBuffer, at time: CMTime) {
        guard let deliver = outputs.withLock({ $0.preview }) else { return }
        let shape = (
            width: CVPixelBufferGetWidth(source),
            height: CVPixelBufferGetHeight(source),
            pixelFormat: CVPixelBufferGetPixelFormatType(source)
        )
        // The pool and the format description are rebuilt only when the shape
        // moves, which for a display share is never and for a window share is
        // whenever it is resized.
        if previewPool == nil || previewShape != shape {
            previewShape = shape
            previewFormat = nil
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: shape.pixelFormat,
                kCVPixelBufferWidthKey: shape.width,
                kCVPixelBufferHeightKey: shape.height,
                // IOSurface-backed, so the display layer gets the same
                // zero-copy path ScreenCaptureKit's own buffers would have had.
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var pool: CVPixelBufferPool?
            // A ceiling on the pool, because the display layer's hold is not
            // ours to predict: past it, a frame is dropped rather than a new
            // buffer allocated for ever.
            let policy: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                policy as CFDictionary,
                attributes as CFDictionary,
                &pool
            ) == kCVReturnSuccess else {
                // A share whose preview cannot allocate is still a share worth
                // sending — §1.5's "a call without the canceller is worth
                // having" one path over. Said once, then left alone.
                if !hasReportedPreviewFailure {
                    hasReportedPreviewFailure = true
                    VoiceTrace.fault("screen share preview pool would not allocate")
                }
                return
            }
            previewPool = pool
        }
        guard let previewPool else { return }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, previewPool, &destination
        ) == kCVReturnSuccess, let destination else {
            // The pool is exhausted because the display layer is still holding
            // what it was given. Dropping this frame is the whole point of
            // copying: the capture keeps running either way.
            return
        }

        guard Self.copyPlanes(from: source, to: destination) else { return }

        if previewFormat == nil {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: destination,
                formatDescriptionOut: &description
            ) == noErr else { return }
            previewFormat = description
        }
        guard let previewFormat else { return }

        // Rebased to zero, exactly as `InboundStreams` rebases the RTP clock.
        // Any value at or behind the renderer's timebase is shown at once, and
        // a preview that starts at zero is always behind it.
        if previewClockBase == nil { previewClockBase = time }
        let presentation = CMTimeSubtract(time, previewClockBase ?? .zero)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentation,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: destination,
            formatDescription: previewFormat,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        deliver(sample)
    }

    /// Plane-by-plane, honouring both buffers' own row strides.
    ///
    /// **The strides are not the same and neither is the width.** A pool
    /// aligns rows to its own boundary, so a single `memcpy` of the whole
    /// buffer copies one image into another with different padding — which
    /// renders as a picture sheared diagonally across the tile.
    private static func copyPlanes(from source: CVPixelBuffer, to destination: CVPixelBuffer)
        -> Bool
    {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess
        else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess
        else { return false }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        // A non-planar format reports zero planes and is copied as one.
        let planes = max(1, CVPixelBufferGetPlaneCount(source))
        guard planes == max(1, CVPixelBufferGetPlaneCount(destination)) else { return false }

        for plane in 0..<planes {
            let isPlanar = CVPixelBufferGetPlaneCount(source) > 0
            let sourceBase = isPlanar
                ? CVPixelBufferGetBaseAddressOfPlane(source, plane)
                : CVPixelBufferGetBaseAddress(source)
            let destinationBase = isPlanar
                ? CVPixelBufferGetBaseAddressOfPlane(destination, plane)
                : CVPixelBufferGetBaseAddress(destination)
            guard let sourceBase, let destinationBase else { return false }

            let sourceStride = isPlanar
                ? CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                : CVPixelBufferGetBytesPerRow(source)
            let destinationStride = isPlanar
                ? CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                : CVPixelBufferGetBytesPerRow(destination)
            let rows = isPlanar
                ? min(
                    CVPixelBufferGetHeightOfPlane(source, plane),
                    CVPixelBufferGetHeightOfPlane(destination, plane)
                )
                : min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
            let width = min(sourceStride, destinationStride)

            if sourceStride == destinationStride {
                memcpy(destinationBase, sourceBase, rows * width)
            } else {
                for row in 0..<rows {
                    memcpy(
                        destinationBase + row * destinationStride,
                        sourceBase + row * sourceStride,
                        width
                    )
                }
            }
        }
        return true
    }

    // MARK: The sound

    /// Gathers one buffer of the shared sound into 20 ms frames.
    ///
    /// Runs on the capture queue. **Allocates nothing**: the buffer list is
    /// read in place into storage made once, and each finished frame is handed
    /// over as a pointer into `soundFrame`.
    private func gatherSound(_ sampleBuffer: CMSampleBuffer) {
        guard let deliver = outputs.withLock({ $0.audio }),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return }
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(description.mChannelsPerFrame)
        // Asked for 48 kHz float, which is what ScreenCaptureKit delivers; any
        // other shape is said once and dropped rather than sent at the wrong
        // speed.
        guard isFloat, description.mBitsPerChannel == 32,
              description.mSampleRate == Double(OpusFormat.sampleRate),
              channels == 1 || channels == 2
        else {
            if !hasReportedSoundFormat {
                hasReportedSoundFormat = true
                VoiceTrace.fault(
                    "screen share sound is \(description.mSampleRate) Hz, "
                    + "\(channels) channels, flags \(description.mFormatFlags); not sent"
                )
            }
            return
        }

        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: soundBuffers.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        ) == noErr else { return }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let left: UnsafePointer<Float>
        let right: UnsafePointer<Float>
        let stride: Int
        if isInterleaved || channels == 1 {
            guard let base = soundBuffers[0].mData?.assumingMemoryBound(to: Float.self)
            else { return }
            left = UnsafePointer(base)
            right = channels == 2 ? UnsafePointer(base + 1) : UnsafePointer(base)
            stride = channels
        } else {
            guard soundBuffers.count >= 2,
                  let first = soundBuffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let second = soundBuffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return }
            left = UnsafePointer(first)
            right = UnsafePointer(second)
            stride = 1
        }

        let frameLength = soundFrame.count
        for index in 0..<frames {
            let l = max(-1, min(1, left[index * stride]))
            let r = max(-1, min(1, right[index * stride]))
            soundFrame[soundFilled] = Int16(l * 32_767)
            soundFrame[soundFilled + 1] = Int16(r * 32_767)
            soundEnergy += l * l + r * r
            soundFilled += 2
            if soundFilled == frameLength {
                let level = (soundEnergy / Float(frameLength)).squareRoot()
                soundFrame.withUnsafeBufferPointer { deliver($0.baseAddress!, level) }
                soundFilled = 0
                soundEnergy = 0
            }
        }
    }
}

extension ScreenShareCapture: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let isOurs = control.withLock { control -> Bool in
            guard control.stream === stream else { return false }
            control = Control()
            return true
        }
        guard isOurs else { return }
        outputs.withLock { $0.stopped }?(error.localizedDescription)
    }
}

extension ScreenShareCapture: SCStreamOutput {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
                let raw = attachments.first?[.status] as? Int,
                let status = SCFrameStatus(rawValue: raw)
            else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let routed = outputs.withLock { ($0.frame, $0.still) }
            switch status {
            case .complete:
                guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                routed.0?(pixels, time)
                // After the encoder, never instead of it: a preview that is not
                // attached must cost this path a nil check and nothing else.
                emitPreview(pixels, at: time)
                lastPicture = pixels
            case .idle:
                // **Only frames whose content actually changed go to the
                // encoder.** ScreenCaptureKit repeats the tick to keep the
                // stream alive, and encoding the repeats spends a third of the
                // bitrate re-sending a picture the far end already has — so a
                // still screen is offered, and sent only to somebody waiting.
                guard let lastPicture else { return }
                routed.1?(lastPicture, time)
            default:
                // Blank, suspended, stopped: there is no picture to stand on.
                lastPicture = nil
            }

        case .audio:
            gatherSound(sampleBuffer)

        default:
            break
        }
    }
}

// MARK: - The picker

/// The system's own picker for what to share — Control Center's, the one every
/// app on the Mac presents.
///
/// **One observer for the whole app**, because the picker is one object for
/// the whole process: it says what was picked, and for which running stream if
/// any, and the app decides whether that is a new share or a change to the one
/// already running.
@MainActor
public final class ScreenSourcePicker: NSObject {
    public static let shared = ScreenSourcePicker()

    public enum Event: Sendable {
        /// A source was picked. `isChange` when it was picked for a capture
        /// already running — Discord's Change Windows, or the menu bar's own
        /// control for the share.
        case picked(ShareSource, isChange: Bool)
        case cancelled
        case failed(String)
    }

    public var onEvent: ((Event) -> Void)?

    private var isObserving = false

    private override init() { super.init() }

    /// Whether the system offers this app's picker at all — in its own menu
    /// as well as when this app presents it. Discord keeps it on for as long
    /// as the reader is somewhere they may stream.
    public var isActive: Bool {
        get { SCContentSharingPicker.shared.isActive }
        set {
            let picker = SCContentSharingPicker.shared
            if newValue, !isObserving {
                isObserving = true
                var configuration = SCContentSharingPickerConfiguration()
                // Everything Discord's menu can name: a display, windows, or
                // applications, one or several.
                configuration.allowedPickerModes = [
                    .singleDisplay, .singleWindow, .multipleWindows,
                    .singleApplication, .multipleApplications,
                ]
                configuration.allowsChangingSelectedContent = true
                picker.defaultConfiguration = configuration
                picker.add(self)
            }
            picker.isActive = newValue
        }
    }

    /// Presents the picker — for a new share, or to change what `capture` is
    /// sharing.
    public func present(changing capture: ScreenShareCapture? = nil) {
        isActive = true
        if let stream = capture?.stream {
            SCContentSharingPicker.shared.present(for: stream)
        } else {
            SCContentSharingPicker.shared.present()
        }
    }
}

extension ScreenSourcePicker: SCContentSharingPickerObserver {
    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in self.onEvent?(.cancelled) }
    }

    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let source = ShareSource(filter: filter)
        let isChange = stream != nil
        Task { @MainActor in self.onEvent?(.picked(source, isChange: isChange)) }
    }

    public nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.onEvent?(.failed(message)) }
    }
}
