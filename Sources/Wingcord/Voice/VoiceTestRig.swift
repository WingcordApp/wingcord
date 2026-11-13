import AVFoundation
import Foundation
import Observation
import WingcordVoice
import WingcordCore

// MARK: - The settings pane's own microphone
//
// A second, short-lived engine, running only while the reader has explicitly
// switched the microphone test on.
//
// **Opening the pane must not open the microphone.** It did, from `.task`, and
// it cost twice: macOS lit the orange recording indicator because somebody went
// to look at their settings, and bringing up a voice-processing `AVAudioEngine`
// is a synchronous main-actor call (§1.5 — it has to be), so the window sat
// blank until CoreAudio came back. Measured beside it, the device enumeration
// the same `.task` ran first was another 258 ms of main thread: 91 for the
// CoreAudio device list and 167 for the first `AVCaptureDevice.DiscoverySession`
// of the process, which loads the camera assistant. None of that may happen
// before the pane paints, and none of it may happen at all unless asked for.
//
// **It is not the call's engine and must not be.** The call's engine is bound
// to the devices the call is using, and a mic test that reconfigured it would
// interrupt whatever conversation the reader is checking their microphone *for*.
// Two engines on one input device is something CoreAudio handles; two engines
// fighting over one is not.
@Observable
@MainActor
final class VoiceTestRig {

    /// The live capture level, 0…1. What the meter draws.
    private(set) var level: Float = 0
    private(set) var isRunning = false
    /// Whether the reader has refused the microphone.
    ///
    /// Drawn rather than swallowed: a meter that never moves is
    /// indistinguishable from a microphone that does not work, and this pane is
    /// the one place somebody comes to tell those two apart.
    private(set) var isDenied = false
    /// Whether the system voice processor is actually in the path.
    ///
    /// Stored rather than forwarded, because the engine is not observable and a
    /// computed property reading it would never redraw the pane.
    private(set) var isVoiceProcessing = false
    /// Whether the microphone is being played back.
    var isMonitoring = false {
        didSet {
            guard isMonitoring != oldValue else { return }
            engine.isMonitoringInput = isMonitoring
        }
    }

    /// Five seconds of digital silence from the microphone since the test
    /// began, or since it last heard anything — Discord's "isn\u{2019}t
    /// detecting any input from your mic.", on the call's own five seconds.
    private(set) var isSilent = false

    @ObservationIgnored private let engine = VoiceAudioEngine()
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    /// When the input last carried anything at all.
    @ObservationIgnored private var lastHeard = ContinuousClock.now

    /// Brings the engine up on the devices the settings currently name.
    ///
    /// **Only ever called from the microphone test's own switch.** See the note
    /// at the top of the file: this opens the input, and nothing but somebody
    /// asking for it should.
    func start() async {
        let settings = AppSettings.shared
        engine.inputVolume = Float(settings.voiceInputVolume)
        engine.outputVolume = Float(settings.voiceOutputVolume)
        if isRunning {
            engine.reconfigure(
                inputUniqueID: settings.voiceInputDeviceID,
                outputUniqueID: settings.voiceOutputDeviceID,
                processing: settings.resolvedProcessing
            )
            return
        }
        // The same grant the call needs, asked for in the same way. Only the
        // first call in the app's life waits on a person.
        guard await VoiceAudioEngine.requestAccess() else {
            isDenied = true
            return
        }
        isDenied = false
        do {
            // The call's processing, so the test hears what the far end would.
            try engine.start(
                inputUniqueID: settings.voiceInputDeviceID,
                outputUniqueID: settings.voiceOutputDeviceID,
                processing: settings.resolvedProcessing
            )
        } catch {
            Log.fault(.voice, "the mic check's engine would not start: \(error)")
            return
        }
        isRunning = true
        isVoiceProcessing = engine.isVoiceProcessing
        engine.isMonitoringInput = isMonitoring
        startMeter()
    }

    /// Follows a device change, and only where there is something to follow.
    ///
    /// A full restart, because an IO unit is bound to its device and there is no
    /// supported way to move one. With the test off this does nothing at all —
    /// changing the input device in a pane you are only reading must not open
    /// the microphone, which is what calling `start()` here used to do.
    func reconfigure() {
        guard isRunning else { return }
        let settings = AppSettings.shared
        engine.reconfigure(
            inputUniqueID: settings.voiceInputDeviceID,
            outputUniqueID: settings.voiceOutputDeviceID,
            processing: settings.resolvedProcessing
        )
        isVoiceProcessing = engine.isVoiceProcessing
    }

    func stop() {
        meterTask?.cancel()
        meterTask = nil
        isMonitoring = false
        engine.stop()
        isRunning = false
        level = 0
        isSilent = false
    }

    private func startMeter() {
        meterTask?.cancel()
        lastHeard = .now
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                // Twenty a second. The meter is a bar a few points tall and
                // cannot show more, and publishing at the capture rate would
                // invalidate the pane fifty times a second for a value nobody
                // can read that fast.
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let next = engine.currentInputLevel
                noteSilence(next)
                guard abs(level - next) > 0.005 else { continue }
                level = next
            }
        }
    }

    /// Digital silence is nothing at all — a quiet room still moves the level.
    private func noteSilence(_ level: Float) {
        let now = ContinuousClock.now
        if level > Self.digitalSilence {
            lastHeard = now
            if isSilent { isSilent = false }
        } else if !isSilent, now - lastHeard >= Self.silenceWindow {
            isSilent = true
        }
    }

    private static let digitalSilence: Float = 0.000_01
    private static let silenceWindow: Duration = .seconds(5)

    /// The engine reads the input's own volume live, so the whole rig can be
    /// left running while a slider moves.
    func setInputVolume(_ volume: Double) { engine.inputVolume = Float(volume) }
    func setOutputVolume(_ volume: Double) { engine.outputVolume = Float(volume) }
}

// MARK: - The camera preview

/// The settings pane's camera, for the same reason and with the same rule: it is
/// never the call's.
@Observable
@MainActor
final class CameraTestRig {
    private(set) var session: AVCaptureSession?
    private(set) var isDenied = false

    @ObservationIgnored private var capture: CameraCapture?

    func start(deviceID: String?) async {
        guard await CameraCapture.requestAccess() else {
            isDenied = true
            return
        }
        isDenied = false
        let capture = self.capture ?? CameraCapture()
        self.capture = capture
        guard await capture.start(deviceID: deviceID, framerate: 30) else { return }
        session = capture.session
    }

    func stop() {
        capture?.stop()
        capture = nil
        session = nil
    }
}
