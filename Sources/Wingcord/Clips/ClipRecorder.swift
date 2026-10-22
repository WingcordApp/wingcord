import AVFoundation
import Foundation
import OSLog
import ScreenCaptureKit
import WingcordCore
import WingcordVoice

// MARK: - Keeping the last minutes of a game
//
// docs/CLIPS-PRESENCE.md, Phase 3 (D10, D11). **Our own replay buffer**:
// `ReplayCapture` keeps the game's window and its sound — hardware HEVC into a
// ring a group of pictures at a time, the sound as Opus — for Discord's 30 s,
// 1 or 2 minutes. `SCClipBufferingOutput`, which this replaced, stops at
// fifteen.
//
// **The call reaches a clip only through `callTap`**, track by track, under
// Discord's own consent rules (the plan is the model's — see
// `AppModel.refreshClipCallPlan`): the capture never takes this app's sound.
//
// Two things about the arming, both of which are the difference between a
// feature and a battery complaint:
//
//   * The capture runs **only while a detected game is in front** and clips
//     are switched on. Nothing captures at rest.
//   * It captures the **game's own window**, not the display. A display
//     capture would put the overlay, the menu bar and every notification into
//     the clip.

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

    /// The call's side of every clip — handed to the voice session while
    /// clips are on.
    let callTap = ClipAudioTap()

    /// Whether the capture is running and a clip could be taken right now.
    private(set) var isArmed = false

    private var capture: ReplayCapture?
    /// The process the current capture is of, so a re-arm for the same game is
    /// a no-op rather than a restart.
    private var armedProcess: pid_t?
    /// The process the kept pictures belong to — still set after the game
    /// quits, so the moment before it did can be clipped.
    private var bufferedProcess: pid_t?
    /// What the capture was started with, so a change of quality restarts it
    /// and a change of length only resizes the rings.
    private var armedSettings: ReplayCapture.Settings?

    /// Where pictures past the memory budget go while a game runs. Caches:
    /// nothing in it is worth a backup or survives a relaunch.
    static var spillDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "dev.wingcord.Wingcord"
        return caches.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("Replay", isDirectory: true)
    }

    /// The bytes of picture held in memory before the oldest go to disk —
    /// enough for two minutes of 1080p60, which is most of what anybody keeps.
    static let memoryBudget = 256 * 1_024 * 1_024

    /// What clips are kept at, from Settings › Clips.
    static func currentSettings() -> ReplayCapture.Settings {
        let settings = AppSettings.shared
        return ReplayCapture.Settings(
            maxHeight: settings.clipResolution.height,
            framerate: settings.clipFrameRate.rate,
            length: settings.clipLength.seconds,
            capturesAudio: true,
            memoryBudget: memoryBudget
        )
    }

    /// What a clip of the current settings holds in memory, for the settings
    /// pane — the picture at the encoder's rate for the whole length.
    static func estimatedBytes(for settings: ReplayCapture.Settings = currentSettings()) -> Int {
        let height = settings.maxHeight
        let width = height * 16 / 9
        let bitrate = ReplayVideoEncoder.Configuration.bitrate(width: width, height: height, framerate: settings.framerate)
        return Int(Double(bitrate) / 8 * (settings.length + 3))
    }

    // MARK: Arming

    /// Starts keeping the window belonging to `pid`, or stops if nil.
    ///
    /// Idempotent for the same process: re-arming a game that is already being
    /// kept does nothing, which matters because the caller is a state observer
    /// and fires on any change.
    func arm(processIdentifier pid: pid_t?) async {
        guard let pid else {
            await disarm()
            return
        }
        let settings = Self.currentSettings()
        if armedProcess == pid, let armedSettings {
            guard armedSettings.maxHeight != settings.maxHeight || armedSettings.framerate != settings.framerate else {
                if armedSettings.length != settings.length {
                    capture?.setLength(settings.length)
                    self.armedSettings = settings
                }
                return
            }
        }

        do {
            let capture = self.capture ?? ReplayCapture(
                settings: settings, spillDirectory: Self.spillDirectory.appendingPathComponent("Window", isDirectory: true)
            )
            if self.capture == nil { self.capture = capture }
            if capture.settings.length != settings.length { capture.setLength(settings.length) }
            try await capture.start(processIdentifier: pid, fresh: bufferedProcess != pid)
            armedProcess = pid
            bufferedProcess = pid
            armedSettings = settings
            isArmed = true
            Self.log.info("clips: armed on pid \(pid, privacy: .public)")
        } catch {
            armedProcess = nil
            isArmed = false
            Self.log.warning("clips: arm failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disarm() async {
        await capture?.stop()
        armedProcess = nil
        armedSettings = nil
        isArmed = false
    }

    /// Clips were switched off: nothing is kept any more, of the game or the
    /// call.
    func forgetEverything() async {
        await disarm()
        capture?.reset()
        capture = nil
        bufferedProcess = nil
        streamVideo?.reset()
        streamVideo = nil
        streamSound = nil
        callTap.reset()
        try? FileManager.default.removeItem(at: Self.spillDirectory)
    }

    /// Whether there is anything to save — a game or a stream being kept, or
    /// one that was until a moment ago.
    var hasPictures: Bool { (capture?.video.duration ?? 0) > 0 || (streamVideo?.duration ?? 0) > 0 }

    // MARK: Going Live

    /// The reader's own stream, while they stream — Discord's `STREAMER`
    /// source, off the stream's encoder, so a stream is clippable whatever it
    /// shows and a streamed game is not captured twice.
    private var streamVideo: ReplayVideoRing?
    private var streamSound: TimedAudioBuffer?
    private(set) var isStreaming = false

    /// Where the stream's picture and sound go, while clips are on.
    func streamClipSink() -> MediaSession.StreamClipSink? {
        guard AppSettings.shared.clipsEnabled else { return nil }
        let window = AppSettings.shared.clipLength.seconds + 3
        let video = streamVideo ?? ReplayVideoRing(
            window: window, memoryBudget: Self.memoryBudget,
            spillDirectory: Self.spillDirectory.appendingPathComponent("Stream", isDirectory: true)
        )
        video.setWindow(window)
        streamVideo = video
        let sound = streamSound ?? TimedAudioBuffer(window: window)
        sound.setWindow(window)
        streamSound = sound
        return MediaSession.StreamClipSink(video: video, sound: sound)
    }

    /// A stream began: its clips start from nothing. Before the sink is
    /// handed over, or the reset takes its first frames with it.
    func streamDidStart() {
        isStreaming = true
        streamVideo?.reset()
        streamSound?.reset()
    }

    /// It ended; what it kept stays for its window, as a game's does.
    func streamDidStop() {
        isStreaming = false
    }

    // MARK: Saving

    /// What a save needs to know that the recorder does not.
    struct Context {
        var selfUserID: UInt64?
        /// Who each voice is, for the track titles and the participants.
        var names: [UInt64: String]
        var avatars: [UInt64: URL]
        /// Everybody in the call right now, in the call's order.
        var callMembers: [UInt64]
        var game: ClipGame?
        /// What the game reported lately, on the host clock.
        var gameEvents: [GameEventMoment] = []
    }

    /// Writes the last `seconds` to a file, its sidecar beside it.
    ///
    /// **Saving never interrupts the keeping**: the rings are read, not
    /// drained, so two clips a second apart both work and the second still
    /// has its whole window behind it.
    /// - Parameter auto: why Auto Clips is keeping it, for one it chose —
    ///   filed as Discord's `clipMethod: "auto"`.
    /// - Parameter remote: the moment's shared id and who clipped it first,
    ///   for a clip kept because somebody in the call clipped (Phase 7.3).
    func save(
        seconds: TimeInterval, to folder: URL, named name: String, context: Context,
        auto: AutoClipReason? = nil, remote: (clipID: String, triggeredBy: UInt64)? = nil
    ) async throws -> URL {
        // **The stream while there is one** — Discord's order: an active
        // stream is the source, else a game's window; a stream that has just
        // ended is still clippable when no game was kept.
        let windowHasPictures = (capture?.video.duration ?? 0) > 0
        let source: ClipManifest.Source
        let video: ReplayVideoRing
        let sound: TimedAudioTrack
        if let streamVideo, streamVideo.duration > 0, isStreaming || !windowHasPictures {
            source = .stream
            video = streamVideo
            sound = streamSound?.track ?? TimedAudioTrack()
        } else if let capture, windowHasPictures {
            source = .window
            video = capture.video
            sound = capture.gameSound()
        } else {
            throw Failure.notArmed
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = ClipLibrary.availableURL(in: folder, named: name, extension: "mp4")

        let call = callTap.snapshot()
        let request = ClipWriter.Request(
            url: url, length: seconds, video: video, gameSound: sound, call: call,
            selfUserID: context.selfUserID, names: context.names,
            gameName: context.game?.name ?? (source == .stream ? "Stream" : nil)
        )
        let result: ClipWriter.Result
        do {
            result = try await ClipWriter.write(request)
        } catch let failure as ClipWriter.Failure {
            throw Failure.exportFailed(failure.errorDescription ?? "Could not save that one.")
        }

        // Who was there: the call as it is, then anybody heard in the clip
        // who has since left.
        var order = context.callMembers
        for userID in result.voices where !order.contains(userID) { order.append(userID) }
        if let me = context.selfUserID, !order.isEmpty, !order.contains(me) { order.insert(me, at: 0) }
        let participants = order.map {
            ClipParticipant(userID: $0, name: context.names[$0] ?? "Somebody", avatarURL: context.avatars[$0])
        }
        // Speech is on the timeline for the voices in the clip, as Discord
        // keeps it only while the voice track is.
        let heard = Set(result.voices)
        let speaking = call.speaking
            .filter { heard.contains($0.userID) }
            .map { ClipTimeline.SpeakingChange(time: $0.time, userID: $0.userID, flags: $0.flags) }
        let manifest = ClipManifest(
            createdAt: .now,
            duration: result.duration,
            source: source,
            game: context.game,
            participants: participants,
            tracks: result.tracks,
            timeline: ClipTimeline.events(
                start: result.start, end: result.end, speaking: speaking,
                games: context.gameEvents.map(\.timelineMoment)
            )
        )
        var filed = manifest
        filed.method = auto == nil ? .manual : .auto
        filed.autoReason = auto
        filed.remoteClipID = remote?.clipID
        filed.triggeredBy = remote?.triggeredBy
        ClipLibrary.writeManifest(filed, for: url)
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
        let url = ClipLibrary.availableURL(in: folder, named: name, extension: "png")
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
}
