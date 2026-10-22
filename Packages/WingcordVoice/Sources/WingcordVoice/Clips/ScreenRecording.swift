import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit
import Synchronization

// MARK: - Recording the screen
//
// docs/CLIPS-PRESENCE.md, D12 / Phase 3.7. ScreenCaptureKit records the file
// itself — `SCRecordingOutput`, HEVC into a QuickTime movie — and on macOS 27
// `mixesAudioWithMicrophone = NO` keeps **the system's sound and the
// microphone as two tracks**, which is what an editor needs to turn one down
// without the other. The cursor is left out of the picture (the capture bar
// logs it instead, for an editor to draw again), and this app's own sound —
// a call — is never in it: the people in the call did not agree to a
// recording.
//
// A screen output rides along only to learn **when the first frame was
// taken**, on the host clock: the movie starts there, so the cursor log and
// the camera are measured from it.

public final class ScreenRecording: NSObject, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Capture")

    public struct Settings: Sendable, Equatable {
        public var framerate: Int
        public var capturesSystemAudio: Bool
        public var capturesMicrophone: Bool
        /// A Core Audio unique id; nil is the system's default input.
        public var microphoneID: String?

        public init(framerate: Int, capturesSystemAudio: Bool, capturesMicrophone: Bool, microphoneID: String? = nil) {
            self.framerate = framerate
            self.capturesSystemAudio = capturesSystemAudio
            self.capturesMicrophone = capturesMicrophone
            self.microphoneID = microphoneID
        }
    }

    public enum Failure: Error, LocalizedError, Sendable {
        case notRecording
        case couldNotStart(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notRecording: "Nothing is being recorded."
            case .couldNotStart(let reason): "The recording could not start: \(reason)"
            case .failed(let reason): "The recording stopped: \(reason)"
            }
        }
    }

    /// The biggest picture recorded: 4K, whatever the display. Past it a
    /// recording is a file nobody can upload and an encode nobody asked for.
    public static let largest = CGSize(width: 3_840, height: 2_160)

    private struct Control: @unchecked Sendable {
        var stream: SCStream?
        var output: SCRecordingOutput?
        var url: URL?
        /// Whoever is waiting for the file to be finished.
        var finished: CheckedContinuation<Void, Error>?
        /// How it finished, when that happened before anybody waited: nil
        /// not yet, `.some(nil)` cleanly, `.some(reason)` with a failure.
        var outcome: String??
    }

    private let control = Mutex(Control())
    private let firstFrame = Mutex<Double?>(nil)
    private let queue = DispatchQueue(label: "dev.wingcord.capture.screen", qos: .userInitiated)

    /// Called when the recording stops by itself — the window closed, the
    /// display went away, the permission was taken back.
    public var onStop: (@Sendable (String) -> Void)?

    public override init() { super.init() }

    /// When the first frame was taken, on the host clock — the movie's zero.
    public var startTime: Double? { firstFrame.withLock { $0 } }

    public var isRecording: Bool { control.withLock { $0.stream != nil } }

    /// The size a source of `points` at `scale` is recorded at — its own
    /// pixels, inside `largest`, even.
    public static func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let pixels = CGSize(width: points.width * scale, height: points.height * scale)
        let fit = min(1, largest.width / max(pixels.width, 1), largest.height / max(pixels.height, 1))
        return (Int(pixels.width * fit) & ~1, Int(pixels.height * fit) & ~1)
    }

    // MARK: What is recorded

    /// What the capture bar chose — by Core Graphics id, so it crosses into
    /// here as plain values and the lookup happens on this side.
    public enum Source: Sendable, Equatable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
        /// Part of a display, in its points from its top left.
        case area(CGDirectDisplayID, CGRect)
    }

    /// Where a source is and what to call it, once it is found.
    public struct Located: Sendable {
        /// The recorded picture's frame in global points, top-left origin —
        /// what the cursor log is measured against.
        public var frame: CGRect
        public var width: Int
        public var height: Int
        /// "Built-in Display", or the window's app and title.
        public var name: String
        public var application: String?
    }

    /// Starts recording `source`, leaving out `excluding` — the capture bar's
    /// own windows, which are on screen while it records.
    public func start(
        _ source: Source, excluding: Set<CGWindowID>, to url: URL, settings: Settings
    ) async throws -> Located {
        let (filter, located, sourceRect) = try await Self.filter(for: source, excluding: excluding)
        try await start(filter: filter, sourceRect: sourceRect, size: (located.width, located.height), to: url, settings: settings)
        return located
    }

    /// The still picture of `source` — a screenshot, cursor left out as
    /// macOS's own leaves it.
    public static func screenshot(_ source: Source, excluding: Set<CGWindowID>) async throws -> CGImage {
        let (filter, located, sourceRect) = try await Self.filter(for: source, excluding: excluding)
        let configuration = SCStreamConfiguration()
        configuration.width = located.width
        configuration.height = located.height
        if let sourceRect { configuration.sourceRect = sourceRect }
        configuration.showsCursor = false
        configuration.scalesToFit = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// **Asking for the content is the permission check** — a throw here is
    /// "allow Screen Recording", not a fault.
    private static func filter(for source: Source, excluding: Set<CGWindowID>) async throws
        -> (SCContentFilter, Located, CGRect?)
    {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = content.windows.filter { excluding.contains($0.windowID) }
        switch source {
        case .display(let id), .area(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw Failure.couldNotStart("That display is not there any more.")
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale = CGFloat(filter.pointPixelScale)
            let name = Self.displayName(id)
            if case .area(_, let rect) = source {
                let size = pixelSize(points: rect.size, scale: scale)
                let frame = rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
                return (filter, Located(frame: frame, width: size.width, height: size.height, name: name), rect)
            }
            let size = pixelSize(points: display.frame.size, scale: scale)
            return (filter, Located(frame: display.frame, width: size.width, height: size.height, name: name), nil)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw Failure.couldNotStart("That window is not there any more.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = pixelSize(points: window.frame.size, scale: CGFloat(filter.pointPixelScale))
            let application = window.owningApplication?.applicationName
            return (filter, Located(
                frame: window.frame, width: size.width, height: size.height,
                name: window.title ?? application ?? "Window", application: application
            ), nil)
        }
    }

    /// What macOS calls a display — "Built-in Retina Display", a monitor's
    /// own name — from its Core Graphics id.
    private static func displayName(_ id: CGDirectDisplayID) -> String {
        CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }

    /// Starts recording what `filter` selects into `url`.
    ///
    /// - Parameters:
    ///   - sourceRect: part of a display, in its points — an area recording.
    ///   - size: the picture, in pixels.
    public func start(
        filter: sending SCContentFilter, sourceRect: CGRect?, size: (width: Int, height: Int),
        to url: URL, settings: Settings
    ) async throws {
        firstFrame.withLock { $0 = nil }
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, size.width)
        configuration.height = max(2, size.height)
        if let sourceRect { configuration.sourceRect = sourceRect }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.framerate)))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.queueDepth = 8
        configuration.capturesAudio = settings.capturesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = settings.capturesMicrophone
        if let microphoneID = settings.microphoneID { configuration.microphoneCaptureDeviceID = microphoneID }

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.videoCodecType = .hevc
        recording.outputFileType = .mov
        recording.mixesAudioWithMicrophone = false
        let output = SCRecordingOutput(configuration: recording, delegate: self)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            // **Before the capture starts**, or its first samples are not in
            // the file — the header's own condition.
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        control.withLock { control in
            control.stream = stream
            control.output = output
            control.url = url
            control.outcome = nil
        }
        Self.log.info("capture: recording \(size.width, privacy: .public)×\(size.height, privacy: .public) at \(settings.framerate, privacy: .public) fps")
    }

    /// Stops, and hands back the finished file once it is written.
    public func stop() async throws -> URL {
        let (stream, url) = control.withLock { ($0.stream, $0.url) }
        guard let stream, let url else { throw Failure.notRecording }
        // Stopping the capture finishes the file; the delegate says when.
        try? await stream.stopCapture()
        defer { control.withLock { $0 = Control() } }
        // **Never for ever.** A stream the system already ended may never say
        // its file is finished; ten seconds is far past any real one.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitForFinish() }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw Failure.failed("The recording did not finish writing.")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        return url
    }

    /// Until the delegate says the file is finished. Cancelling it gives up.
    private func waitForFinish() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let outcome = control.withLock { control -> String?? in
                    if control.outcome == nil { control.finished = continuation }
                    return control.outcome
                }
                switch outcome {
                case .none: break
                case .some(.none): continuation.resume()
                case .some(.some(let reason)): continuation.resume(throwing: Failure.failed(reason))
                }
            }
        } onCancel: {
            finish("The recording did not finish writing.")
        }
    }

    private func finish(_ error: String?) {
        let continuation = control.withLock { control -> CheckedContinuation<Void, Error>? in
            defer { control.finished = nil }
            if control.finished == nil { control.outcome = .some(error) }
            return control.finished
        }
        if let continuation {
            if let error { continuation.resume(throwing: Failure.failed(error)) } else { continuation.resume() }
        }
    }
}

extension ScreenRecording: SCRecordingOutputDelegate {
    public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Self.log.debug("capture: file started")
    }

    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Self.log.warning("capture: file failed: \(error.localizedDescription, privacy: .public)")
        finish(error.localizedDescription)
    }

    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finish(nil)
    }
}

extension ScreenRecording: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let isOurs = control.withLock { $0.stream === stream }
        guard isOurs else { return }
        Self.log.warning("capture: stream stopped: \(error.localizedDescription, privacy: .public)")
        onStop?(error.localizedDescription)
    }
}

extension ScreenRecording: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        firstFrame.withLock { first in
            guard first == nil else { return }
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete
            else { return }
            first = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        }
    }
}
