import AVFoundation
import Foundation
import OSLog
import WingcordCore
import WingcordVoice

/// Records one voice message, and holds it until it's sent or thrown away.
///
/// **The one microphone.** Rules are in `VoiceNoteFlow`; this is what acts on them. What
/// a view needs to redraw for is observed (`flow`, `held`, `notice`), and what changes
/// sixty times a second isn't: the level and the time are read straight off the recording
/// by whoever draws them.
@MainActor
@Observable
final class VoiceNoteRecorder {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "VoiceNote")

    /// What's being asked of the reader.
    enum Notice: Hashable {
        /// The microphone's refused: only System Settings can change that.
        case microphoneRefused
        /// It wouldn't start, or it started and nothing came out of it.
        case microphoneSilent
        /// The disk filled or the encoder gave up.
        case recordingFailed
        /// A note's waiting in another channel: go back to it, or throw it away and
        /// start the new one here.
        case heldElsewhere(ChannelID, wanted: ChannelID)
    }

    /// A finished note, waiting.
    struct Held: Equatable {
        var file: VoiceNoteFile
        /// What a message will carry: at most 256 bytes.
        var waveform: String
        /// The same, as values to draw.
        var values: [Float]
    }

    private(set) var flow = VoiceNoteFlow()
    private(set) var held: Held?
    var notice: Notice?

    /// When the recording stopped, on the clock the composer draws by: the bars fall and
    /// rise from here. Not observed: it's only read while they draw.
    @ObservationIgnored private(set) var stoppedAt: TimeInterval?
    @ObservationIgnored let meter = VoiceNoteMeter()
    @ObservationIgnored private var recording: VoiceNoteRecording?
    @ObservationIgnored private var capture: (any VoiceNoteCapture)?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// The channel a press is starting in, until the microphone's up.
    @ObservationIgnored private var startingIn: ChannelID?
    /// The engine being shut down: see `releaseCapture`.
    @ObservationIgnored private var letGo: Task<Void, Never>?

    /// Picks the capture when a recording starts: the call's, if there is one.
    @ObservationIgnored var makeCapture: () -> any VoiceNoteCapture = { EngineVoiceNoteCapture() }
    /// Asks the system for the microphone. `--synthetic-microphone` has nothing to ask
    /// for, and neither does a test.
    @ObservationIgnored var requestAccess: () async -> Bool = { await VoiceAudioEngine.requestAccess() }
    /// Tells the player to stop: the sound would be in the note.
    @ObservationIgnored var onWillRecord: () -> Void = {}

    // MARK: Reading, every frame

    /// The latest level, 0…1.
    var level: Float { recording?.level ?? 0 }

    /// How long it's run. A held note's length once it's stopped.
    var elapsedSeconds: Double { recording?.elapsedSeconds ?? held?.file.durationSeconds ?? 0 }

    // MARK: Starting

    /// Starts recording in a channel, or says why not.
    ///
    /// **The microphone first, and the composer once it's listening.** The engine has to
    /// come up on the main thread (`VoiceAudioEngine.start` says why), which blocks it for
    /// about 70 ms, and a composer already morphing would hitch. So nothing moves until the
    /// mic's live, and the morph runs on a free thread with frames already arriving. It also
    /// means nothing said after the composer turns is lost, and the composer never claims to
    /// be recording before it is.
    func start(in channelID: ChannelID) {
        guard startingIn == nil else { return }
        switch flow.channelID {
        case channelID:
            return
        case let other?:
            notice = .heldElsewhere(other, wanted: channelID)
            return
        case nil:
            break
        }
        notice = nil
        startingIn = channelID
        onWillRecord()
        Task { await begin(in: channelID) }
    }

    private func begin(in channelID: ChannelID) async {
        // A recording stopped a moment ago may still be letting go of the device.
        await letGo?.value
        if !(await requestAccess()) {
            // `--demo` still has a composer to look at (D13).
            guard LaunchOptions.current.usesDemoFixtures else {
                // Another press may have started since this one was left behind.
                if startingIn == channelID {
                    startingIn = nil
                    notice = .microphoneRefused
                }
                return
            }
            makeCapture = { SyntheticVoiceNoteCapture() }
        }
        // Gone elsewhere while the system's question was up.
        guard startingIn == channelID else { return }
        do {
            let url = try Self.newFileURL()
            let recording = try VoiceNoteRecording(url: url)
            let capture = makeCapture()
            let began = ContinuousClock.now
            do {
                try await capture.start { [recording] frame, level in
                    recording.ingest(frame, level: level)
                }
            } catch {
                recording.cancel()
                throw error
            }
            let took = ContinuousClock.now - began
            // Kept: this is the delay between the press and the morph.
            Self.log.notice("\(String(describing: type(of: capture)), privacy: .public) started in \(took, privacy: .public)")
            // Gone elsewhere while the engine was coming up, or the call took it.
            guard startingIn == channelID else {
                recording.cancel()
                await capture.stop()
                return
            }
            startingIn = nil
            self.recording = recording
            self.capture = capture
            stoppedAt = nil
            meter.reset()
            _ = flow.start(in: channelID)
            watch(recording)
        } catch {
            Self.log.error("capture failed: \(String(describing: error), privacy: .public)")
            if startingIn == channelID {
                startingIn = nil
                notice = .microphoneSilent
            }
        }
    }

    /// Stops it at the limit, and speaks up if the microphone never delivered.
    ///
    /// **Twice a second is plenty for a limit of twenty minutes**, and the engine's own
    /// failure mode is a microphone that reports itself healthy and delivers nothing, so
    /// that gets noticed rather than leaving somebody talking to a flat line.
    private func watch(_ recording: VoiceNoteRecording) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            let started = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.recording === recording, self.flow.isRecording else { return }
                let elapsed = recording.elapsedSeconds
                if VoiceNoteFlow.hasReachedLimit(elapsedSeconds: elapsed) {
                    self.stop()
                    return
                }
                if elapsed == 0, ContinuousClock.now - started > .seconds(4) {
                    self.fail(because: .microphoneSilent)
                    return
                }
            }
        }
    }

    // MARK: Stopping

    /// Stops recording. Into review, or nowhere, if it was too short.
    func stop() {
        guard flow.isRecording else { return }
        let recording = recording
        let duration = recording?.elapsedSeconds ?? 0
        self.recording = nil
        watchdog?.cancel()
        releaseCapture()
        switch flow.stop(durationSeconds: duration) {
        case .review:
            do {
                guard let file = try recording?.finish() else {
                    fail(because: .recordingFailed)
                    return
                }
                let waveform = VoiceWaveform.encode(file.samples)
                held = Held(file: file, waveform: waveform, values: VoiceWaveform.decode(waveform))
                stoppedAt = Date.now.timeIntervalSinceReferenceDate
            } catch {
                Self.log.error("finishing failed: \(String(describing: error), privacy: .public)")
                recording?.cancel()
                fail(because: .recordingFailed)
            }
        case .dropped, .nothing:
            recording?.cancel()
        }
    }

    /// A channel's composer is going away. A microphone left running on a channel the
    /// reader can't see seems wrong (D5), so it stops, and what was said waits there.
    func left(_ channelID: ChannelID) {
        if startingIn == channelID { startingIn = nil }
        guard flow.phase(in: channelID) == .recording(channelID) else { return }
        stop()
    }

    /// A call started or ended, so the microphone is about to change hands.
    func callChanged() {
        startingIn = nil
        stop()
    }

    private func fail(because notice: Notice) {
        recording?.cancel()
        recording = nil
        watchdog?.cancel()
        releaseCapture()
        flow.discard()
        held = nil
        self.notice = notice
    }

    /// Lets go of the microphone, straight away: measured at a few milliseconds, and the
    /// system's mic indicator should go out when the reader's finished.
    private func releaseCapture() {
        guard let capture else { return }
        self.capture = nil
        let previous = letGo
        letGo = Task {
            await previous?.value
            await capture.stop()
        }
    }

    // MARK: Ending

    /// Throws away whatever there is.
    func discard() {
        startingIn = nil
        recording?.cancel()
        recording = nil
        watchdog?.cancel()
        releaseCapture()
        if let held { try? FileManager.default.removeItem(at: held.file.url.deletingLastPathComponent()) }
        held = nil
        stoppedAt = nil
        flow.discard()
    }

    /// Hands over the note to send. It's the sender's file now.
    func takeForSending() -> Held? {
        guard let held, flow.sent() else { return nil }
        self.held = nil
        stoppedAt = nil
        return held
    }

    // MARK: Files

    /// A folder of its own for each, so the file's called what the wire calls it.
    private static func newFileURL() throws -> URL {
        let folder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(VoiceMessageLimits.filename)
    }

    private static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("VoiceNotes", isDirectory: true)

    /// Held notes don't survive quitting (D5), so anything here on the way in is from
    /// the last run. Called once, at launch.
    static func clearLeftovers() {
        try? FileManager.default.removeItem(at: folder)
    }
}
