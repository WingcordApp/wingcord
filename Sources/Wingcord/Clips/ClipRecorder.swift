import AVFoundation
import Foundation
import OSLog
import ScreenCaptureKit

// MARK: - Keeping the last few seconds
//
// **`SCClipBufferingOutput`, which is new in macOS 27 and is exactly this.**
// Added to a running `SCStream`, it keeps a rolling buffer of the most recent
// samples and writes them out on demand without interrupting the buffering.
// There is no ring of `CMSampleBuffer`s to own here, no `AVAssetWriter` to
// babysit, and no encoder of ours to keep fed.
//
// **The ceiling is fifteen seconds, and it is Apple's.** The header documents
// "Maximum duration is 15 seconds" and `SCStream` exposes no knob for it
// anywhere. Discord's shortest clip is thirty, so matching the reference means
// keeping our own ring of compressed samples and a permanently-running encoder
// — a real week of work and a real battery cost. That is deliberately not what
// this does, and `ClipLength` says so where somebody will read it.
//
// Two things about the arming, both of which are the difference between a
// feature and a battery complaint:
//
//   * The stream runs **only while a detected game is in front** and clips are
//     switched on. Nothing captures at rest.
//   * It captures the **game's own window**, not the display. A display capture
//     would put the overlay, the menu bar and every notification into the clip.

@MainActor
final class ClipRecorder {

    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Clips")

    enum Failure: Error, LocalizedError {
        case notArmed
        case noWindow
        case permissionDenied
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .notArmed:
                "Clips is not running. Turn it on in Settings, and start a game."
            case .noWindow:
                "Nothing to clip — the game has no window on screen."
            case .permissionDenied:
                "Wingcord needs Screen Recording permission to take clips."
            case .exportFailed(let reason):
                reason
            }
        }
    }

    /// Whether the buffer is running and a clip could be taken right now.
    private(set) var isArmed = false

    private var stream: SCStream?
    private var buffering: SCClipBufferingOutput?
    private var delegate: BufferingDelegate?
    /// The process the current stream is capturing, so a re-arm for the same
    /// game is a no-op rather than a restart.
    private var armedProcess: pid_t?

    // MARK: Arming

    /// Starts buffering the window belonging to `pid`, or stops if nil.
    ///
    /// Idempotent for the same process: re-arming a game that is already being
    /// buffered does nothing, which matters because the caller is a state
    /// observer and fires on any change.
    func arm(processIdentifier pid: pid_t?) async {
        guard let pid else {
            await disarm()
            return
        }
        guard armedProcess != pid else { return }
        await disarm()

        do {
            // **Asking for the content IS the permission check.** There is no
            // authorisation-status API for screen capture the way there is for
            // the camera, so a throw here means "send them to System Settings"
            // rather than "something went wrong" — the same fact
            // `ScreenShareCapture` documents.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let window = Self.largestWindow(of: pid, in: content) else {
                throw Failure.noWindow
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = Self.configuration(for: window)
            let delegate = BufferingDelegate()
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            let buffering = SCClipBufferingOutput(delegate: delegate)

            try await stream.startCapture()
            // **The stream has to be capturing before the buffer can be added** —
            // the header says so, and adding it first fails rather than queueing.
            try stream.addClipBufferingOutput(buffering)

            self.stream = stream
            self.buffering = buffering
            self.delegate = delegate
            armedProcess = pid
            isArmed = true
            Self.log.info("clips: armed on pid \(pid, privacy: .public)")
        } catch {
            armedProcess = nil
            isArmed = false
            Self.log.warning("clips: arm failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disarm() async {
        guard let stream else {
            isArmed = false
            armedProcess = nil
            return
        }
        if let buffering { try? stream.removeClipBufferingOutput(buffering) }
        try? await stream.stopCapture()
        self.stream = nil
        buffering = nil
        delegate = nil
        armedProcess = nil
        isArmed = false
    }

    // MARK: Saving

    /// Writes the last `seconds` to a file and hands back where it went.
    ///
    /// **The export does not interrupt buffering**, which the header is explicit
    /// about — so two clips taken a second apart both work and the second one
    /// still has its full window of history.
    func save(seconds: TimeInterval, to folder: URL, named name: String) async throws -> URL {
        guard let buffering, isArmed else { throw Failure.notArmed }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name).appendingPathExtension("mp4")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            buffering.exportClip(to: url, duration: seconds) { error in
                if let error {
                    continuation.resume(throwing: Failure.exportFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
        return url
    }

    /// The frame that is on screen, as a file.
    ///
    /// Separate from the clip on purpose: a screenshot needs no buffer, no
    /// stream and no arming, so it works whether or not clips is switched on.
    /// Discord binds it separately too.
    static func screenshot(
        processIdentifier pid: pid_t?,
        to folder: URL,
        named name: String
    ) async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let filter: SCContentFilter
        if let pid, let window = largestWindow(of: pid, in: content) {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display = content.displays.first {
            // No game: the main display, minus Wingcord's own windows. A
            // screenshot of the overlay taking a screenshot is not a
            // screenshot anybody wanted.
            let ours = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            filter = SCContentFilter(
                display: display, excludingApplications: ours, exceptingWindows: []
            )
        } else {
            throw Failure.noWindow
        }

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: {
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int(filter.contentRect.width * scale)
            configuration.height = Int(filter.contentRect.height * scale)
            return configuration
        }())

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name).appendingPathExtension("png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else {
            throw Failure.exportFailed("Could not create \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.exportFailed("Could not write \(url.lastPathComponent).")
        }
        return url
    }

    // MARK: Choosing what to capture

    /// The biggest on-screen window the process owns.
    ///
    /// **Biggest, not first.** A game very often has a small helper window — a
    /// launcher splash, an anti-cheat shim, an invisible input sink — and the
    /// order `SCShareableContent` returns them in is not the order anybody would
    /// guess. Zero-sized windows are skipped outright.
    private static func largestWindow(
        of pid: pid_t,
        in content: SCShareableContent
    ) -> SCWindow? {
        content.windows
            .filter { $0.owningApplication?.processID == pid }
            .filter { $0.frame.width > 1 && $0.frame.height > 1 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func configuration(for window: SCWindow) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let settings = AppSettings.shared

        // The capture size is bounded by the preference, and the aspect is the
        // window's own. Asking for a 5K window's full pixel count is a clip
        // nobody can upload and an encode nobody asked for.
        let scale = min(1, CGFloat(settings.clipResolution.height) / max(window.frame.height, 1))
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(settings.clipFrameRate.rate)
        )

        // **The game's audio, and not ours.** A clip with Wingcord's own
        // notification blips in it is a clip somebody has to re-record.
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true

        // Bounded in flight. Left at the default, a slow encoder builds a queue
        // that never drains — the same trap `ScreenShareCapture` documents.
        configuration.queueDepth = 6
        configuration.showsCursor = false
        return configuration
    }
}

// MARK: - The buffer's own callbacks

/// `SCClipBufferingOutput` will not start without a delegate, and its three
/// callbacks are the only way to learn that buffering stopped on its own — the
/// window closed, the permission was revoked, the display went away.
private final class BufferingDelegate: NSObject, SCClipBufferingOutputDelegate {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Clips")

    func clipBufferingOutputDidStartBuffering(_ output: SCClipBufferingOutput) {
        Self.log.debug("clips: buffering")
    }

    func clipBufferingOutput(_ output: SCClipBufferingOutput, didFailWithError error: any Error) {
        Self.log.warning("clips: buffering failed: \(error.localizedDescription, privacy: .public)")
    }

    func clipBufferingOutputDidStopBuffering(_ output: SCClipBufferingOutput) {
        Self.log.debug("clips: stopped")
    }
}
