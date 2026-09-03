import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

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

public struct ShareableTarget: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// The owning application, for a window. Nil for a display.
    public var application: String?
    public var width: Int
    public var height: Int
}

public final class ScreenShareCapture: NSObject, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "ScreenShare")

    public var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    /// A **copy** of the share's frames, at the capture's own rate, for the
    /// local self-view.
    ///
    /// **ScreenCaptureKit has no `AVCaptureVideoPreviewLayer`.** A camera's
    /// self-view is a second hardware path that never goes near the encoder,
    /// which is why it has no latency and why `cameraSession` is handed out
    /// rather than drawn. A share has no such thing, so the only picture of our
    /// own screen is these frames.
    ///
    /// Without it the self tile falls through to the **inbound** video view,
    /// which waits for a stream from our own user id that by definition never
    /// arrives — measured live as a tile that stayed black for a whole call
    /// while the capture, the encoder and the send path were all healthy.
    ///
    /// **And the frames may not be ScreenCaptureKit's own.** Its buffers come
    /// from a pool `queueDepth` frames deep, and a buffer that is still
    /// referenced cannot be recycled — `AVSampleBufferDisplayLayer` retains
    /// every one it is given, so handing them straight over drains the pool and
    /// the stream stops producing. It does not error and it does not stop; it
    /// simply never calls the delegate again. Measured: one keyframe out, then
    /// `frames=0` for the rest of the call with the packet count frozen.
    ///
    /// So each preview frame is copied into a pool of ours first. **At the
    /// capture's own rate**, because a self-view is how the reader judges what
    /// the far end is getting and a stuttering one reads as a stuttering share:
    /// throttling this to eight a second was measured as "very low fps, like
    /// 4-5" by the person watching it. The copy is a `memcpy` of a frame
    /// bounded by the quality box — 1280×720 of NV12 is about 1.4 MB — and the
    /// pool makes it allocation-free after the first few.
    public var onPreviewSample: (@Sendable (CMSampleBuffer) -> Void)?
    /// Interleaved stereo float32 at 48 kHz, from the shared application.
    public var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// The stream stopped for a reason that is not us — the window closed, the
    /// user revoked the permission, the display went away.
    public var onStopped: (@Sendable (String) -> Void)?

    private var stream: SCStream?
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

    public override init() { super.init() }

    // MARK: What can be shared

    /// Everything the user could pick.
    ///
    /// Throws when Screen Recording has not been granted — and that is the
    /// *only* way to find out. There is no authorisation-status API for screen
    /// capture the way there is for the camera; asking for the content is the
    /// check, which is why the caller has to treat a throw here as "send them
    /// to System Settings" rather than as a failure.
    public static func shareable() async throws -> [ShareableTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        var targets: [ShareableTarget] = []
        targets.reserveCapacity(content.displays.count + content.windows.count)

        for display in content.displays {
            targets.append(ShareableTarget(
                id: "display:\(display.displayID)",
                kind: .display(display.displayID),
                title: content.displays.count > 1
                    ? "Display \(display.displayID)"
                    : "Entire Screen",
                application: nil,
                width: display.width,
                height: display.height
            ))
        }
        for window in content.windows {
            // Untitled windows and the tiny ones are panels, shadows and
            // menu-bar helpers. A picker that lists them is a picker nobody can
            // find their editor in.
            guard let title = window.title, !title.isEmpty,
                  window.frame.width > 120, window.frame.height > 120 else { continue }
            targets.append(ShareableTarget(
                id: "window:\(window.windowID)",
                kind: .window(window.windowID),
                title: title,
                application: window.owningApplication?.applicationName,
                width: Int(window.frame.width),
                height: Int(window.frame.height)
            ))
        }
        return targets
    }


    // MARK: Running

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

        public static let standard = Quality(
            width: 1_280, height: 720, framerate: 30, capturesAudio: true
        )
    }

    public func start(target: ShareableTarget, quality: Quality) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let filter: SCContentFilter
        switch target.kind {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw Failure.targetGone
            }
            // Wingcord's own windows are excluded from a full-screen share.
            // Without it the shared picture contains the call it is being shared
            // into, which is the infinite corridor everybody has seen once.
            let own = content.applications.first {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: own.map { [$0] } ?? [],
                exceptingWindows: []
            )
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw Failure.targetGone
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let configuration = SCStreamConfiguration()
        // The aspect of the source, fitted inside the quality's box. A
        // configuration whose ratio differs from the source's is letterboxed by
        // ScreenCaptureKit into bars this app then spends bitrate encoding.
        let fitted = Self.fit(
            width: target.width, height: target.height,
            into: quality.width, by: quality.height
        )
        configuration.width = fitted.width
        configuration.height = fitted.height
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(quality.framerate)
        )
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        // Five frames of headroom. Fewer drops frames on any hitch; more is
        // latency the viewer sees and can never get back.
        configuration.queueDepth = 5
        configuration.capturesAudio = quality.capturesAudio
        configuration.sampleRate = Int(OpusFormat.sampleRate)
        configuration.channelCount = Int(OpusFormat.channels)
        configuration.scalesToFit = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if quality.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        // **The preview's clock starts again with the next share.** Keeping the
        // old base makes a second share's first frame arrive minutes ahead of
        // the renderer's timebase, which is the freeze this rebasing exists to
        // prevent — one share later.
        queue.async { [self] in previewClockBase = nil }
        try? await stream.stopCapture()
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
    /// Discord's own presets — 1280×720, 1920×1080, 848×480 — are all whole
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

    // MARK: The self-view

    /// Copies one frame into a pool of ours and hands it to the self-view.
    ///
    /// Runs on the capture queue, and returns without allocating when nothing
    /// is attached or the interval has not elapsed.
    private func emitPreview(_ source: CVPixelBuffer, at time: CMTime) {
        guard let onPreviewSample else { return }
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

        onPreviewSample(sample)
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

    public enum Failure: Error, Sendable { case targetGone }
}

extension ScreenShareCapture: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        self.stream = nil
        onStopped?(error.localizedDescription)
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
            // **Only frames whose content actually changed.** ScreenCaptureKit
            // repeats the previous frame to keep the stream alive, and encoding
            // the repeats spends a third of the bitrate re-sending a still
            // picture the far end already has.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
                let raw = attachments.first?[.status] as? Int,
                let status = SCFrameStatus(rawValue: raw), status == .complete,
                let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            onFrame?(pixels, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            // After the encoder, never instead of it: a preview that is not
            // attached must cost this path a nil check and nothing else.
            emitPreview(pixels, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        case .audio:
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)
            else { return }
            let audioFormat = AVAudioFormat(streamDescription: description)
            guard let audioFormat,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: audioFormat,
                      frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
                  ) else { return }
            buffer.frameLength = buffer.frameCapacity
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(buffer.frameLength),
                into: buffer.mutableAudioBufferList
            ) == noErr else { return }
            onAudio?(buffer)

        default:
            break
        }
    }
}
