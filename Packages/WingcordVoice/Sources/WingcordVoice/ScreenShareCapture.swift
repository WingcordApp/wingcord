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
    /// Interleaved stereo float32 at 48 kHz, from the shared application.
    public var onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// The stream stopped for a reason that is not us — the window closed, the
    /// user revoked the permission, the display went away.
    public var onStopped: (@Sendable (String) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "dev.wingcord.screenshare", qos: .userInitiated)

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

    /// Whether the permission is there, without raising the prompt twice.
    public static func hasPermission() async -> Bool {
        (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
            != nil
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
        try? await stream.stopCapture()
    }

    /// The largest box with the source's aspect that fits inside the target,
    /// rounded to even numbers because 4:2:0 chroma is subsampled by two and an
    /// odd dimension is a column the encoder has to pad.
    static func fit(width: Int, height: Int, into maxWidth: Int, by maxHeight: Int)
        -> (width: Int, height: Int)
    {
        guard width > 0, height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height), 1)
        let fittedWidth = max(2, Int((Double(width) * scale).rounded()) & ~1)
        let fittedHeight = max(2, Int((Double(height) * scale).rounded()) & ~1)
        return (fittedWidth, fittedHeight)
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
