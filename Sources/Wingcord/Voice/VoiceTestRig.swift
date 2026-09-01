import AVFoundation
import Foundation
import Observation
import WingcordVoice

// MARK: - The settings pane's own microphone
//
// A second, short-lived engine, running only while the Voice & Video pane is
// open and only while something in it is switched on.
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

    @ObservationIgnored private let engine = VoiceAudioEngine()
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    /// Brings the engine up on the devices the settings currently name.
    ///
    /// Called on appear and again whenever a device changes, which is a full
    /// restart: an IO unit is bound to its device and there is no supported way
    /// to move one.
    func start() async {
        let settings = AppSettings.shared
        engine.inputVolume = Float(settings.voiceInputVolume)
        engine.outputVolume = Float(settings.voiceOutputVolume)
        if isRunning {
            engine.reconfigure(
                inputUniqueID: settings.voiceInputDeviceID,
                outputUniqueID: settings.voiceOutputDeviceID
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
            try engine.start(
                inputUniqueID: settings.voiceInputDeviceID,
                outputUniqueID: settings.voiceOutputDeviceID
            )
        } catch {
            DiagnosticLog.trace("voice", "mic check engine would not start: \(error)")
            return
        }
        isRunning = true
        isVoiceProcessing = engine.isVoiceProcessing
        engine.isMonitoringInput = isMonitoring
        startMeter()
    }

    func stop() {
        meterTask?.cancel()
        meterTask = nil
        isMonitoring = false
        engine.stop()
        isRunning = false
        level = 0
    }

    func applyVolumes() {
        let settings = AppSettings.shared
        engine.inputVolume = Float(settings.voiceInputVolume)
        engine.outputVolume = Float(settings.voiceOutputVolume)
    }

    /// Plays a short chime through the **chosen** output device.
    ///
    /// Synthesised and pushed through this engine rather than handed to
    /// `NSSound`: a speaker test that plays on the system's default output tests
    /// the wrong device, which is exactly the case somebody opening this pane is
    /// trying to diagnose.
    func playTestTone() {
        guard isRunning else { return }
        engine.enqueue(Self.chime, frames: Self.chime.count / Int(OpusFormat.channels))
    }

    /// Two short notes a fifth apart, with a raised-cosine envelope on each.
    ///
    /// The envelope is the whole reason this is not a bare sine: a tone that
    /// starts and stops at full amplitude clicks at both ends, and on a speaker
    /// test the click is the loudest thing in it.
    private static let chime: [Float] = {
        let rate = Float(OpusFormat.sampleRate)
        let channels = Int(OpusFormat.channels)
        var samples: [Float] = []
        for (frequency, seconds) in [(Float(660), Float(0.14)), (Float(990), Float(0.20))] {
            let count = Int(rate * seconds)
            samples.reserveCapacity(samples.count + count * channels)
            for index in 0..<count {
                let phase = 2 * Float.pi * frequency * Float(index) / rate
                let progress = Float(index) / Float(count)
                let envelope = 0.5 - 0.5 * cos(2 * Float.pi * progress)
                let value = sin(phase) * envelope * 0.28
                for _ in 0..<channels { samples.append(value) }
            }
        }
        return samples
    }()

    private func startMeter() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                // Twenty a second. The meter is a bar a few points tall and
                // cannot show more, and publishing at the capture rate would
                // invalidate the pane fifty times a second for a value nobody
                // can read that fast.
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let next = engine.currentInputLevel
                guard abs(level - next) > 0.005 else { continue }
                level = next
            }
        }
    }

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
