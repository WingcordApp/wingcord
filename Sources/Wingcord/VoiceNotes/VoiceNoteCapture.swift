import Foundation
import WingcordCore
import WingcordVoice

/// What a recorder's frames come from: 20 ms of 48 kHz mono, and how loud each is.
typealias VoiceNoteFrameSink = @Sendable (UnsafePointer<Int16>, Float) -> Void

/// Where a voice message's sound comes from.
///
/// **Three, because a recording has three ways to start.** With no call there's nothing
/// running, so it brings up its own engine. In a call the engine's already there, and a
/// second would fight it for the device. And where the microphone's refused in `--demo`,
/// a made-up voice still lets the composer be looked at.
@MainActor
protocol VoiceNoteCapture: AnyObject {
    func start(deliver: @escaping VoiceNoteFrameSink) async throws
    func stop() async
}

/// The microphone, through the engine a call uses: the same device and the same volume.
///
/// **Without the voice processor, which is the one thing a call has that this doesn't.**
/// Measured on this Mac: with the processor the engine takes 1.1 to 1.65 seconds to come up,
/// on the main thread, which is the whole app frozen after a press and the first second of
/// what somebody says gone. Without it, 70 ms. There's no far end to cancel an echo for, and
/// what it gives up is noise suppression and gain. The processor's there during a call,
/// because a note then listens to the call's own engine (`CallVoiceNoteCapture`).
@MainActor
final class EngineVoiceNoteCapture: VoiceNoteCapture {
    private let engine = VoiceAudioEngine()

    func start(deliver: @escaping VoiceNoteFrameSink) async throws {
        let settings = AppSettings.shared
        engine.inputVolume = Float(settings.voiceInputVolume)
        engine.setCaptureTap(deliver)
        // **On the main thread**, which the engine insists on and has good reason to:
        // see `VoiceAudioEngine.start`. Short enough now not to be seen.
        try engine.start(
            inputUniqueID: settings.voiceInputDeviceID,
            outputUniqueID: settings.voiceOutputDeviceID,
            processing: VoiceAudioEngine.Processing(echoCancellation: false, automaticGainControl: false)
        )
    }

    func stop() async {
        engine.setCaptureTap(nil)
        engine.stop()
    }
}

/// The call's own microphone, lent for as long as the note runs.
@MainActor
final class CallVoiceNoteCapture: VoiceNoteCapture {
    enum Failure: Error { case noMicrophone }

    private let session: MediaSession

    init(session: MediaSession) {
        self.session = session
    }

    func start(deliver: @escaping VoiceNoteFrameSink) async throws {
        guard await session.beginVoiceNote(deliver) else { throw Failure.noMicrophone }
    }

    func stop() async {
        await session.endVoiceNote()
    }
}

/// A made-up voice, at the pace a microphone would deliver it. Only `--demo` asks for
/// this, and only where it can't have the real thing.
@MainActor
final class SyntheticVoiceNoteCapture: VoiceNoteCapture {
    private var task: Task<Void, Never>?

    func start(deliver: @escaping VoiceNoteFrameSink) async throws {
        task = Task.detached(priority: .userInitiated) {
            var voice = SyntheticVoice()
            var frame = [Int16](repeating: 0, count: Int(OpusFormat.voiceFrameCount))
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                let level = voice.fill(&frame)
                frame.withUnsafeBufferPointer { deliver($0.baseAddress!, level) }
                next += .milliseconds(20)
                try? await clock.sleep(until: next)
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
    }
}
