import AVFAudio
import Foundation

// MARK: - The system's mute gesture
//
// AirPods mute a call with a press of the stem, and on the Mac that press goes
// to the app doing the call's audio — if the app has asked for it. The system
// keeps the state ("is this app's input muted") and, on a press, calls the
// block registered here with the state it should move to; the app does the
// muting. It is the same switch as the one in the call bar, moved from the
// other end.
//
// The state has to be told both ways. A press reaches `setMuted` through the
// block; a click in the call bar reaches the system through `syncSystemMute`,
// or the next press would ask for the state the call is already in and appear
// to do nothing.

extension VoiceController {

    /// Takes the mute gesture for the life of a call. Called once the call's
    /// audio is up.
    func adoptSystemMuteGesture() {
        let application = AVAudioApplication.shared
        do {
            try application.setInputMuteStateChangeHandler { [weak self] shouldBeMuted in
                // Called off the main actor. The answer is "yes" at once: the
                // mute itself is one hop away and cannot fail.
                Task { @MainActor [weak self] in
                    guard let self, hasCallAudio else { return }
                    // Unmuting while deafened would be a microphone nobody on
                    // the call can answer; the press undeafens, as the mute
                    // button does there.
                    if !shouldBeMuted, model.isSelfDeafened {
                        setDeafened(false)
                    }
                    setMuted(shouldBeMuted)
                }
                return true
            }
        } catch {
            VoiceControllerTrace.note("system mute gesture refused: \(error.localizedDescription)")
        }
        syncSystemMute()
    }

    /// Gives the gesture back at the end of a call, unmuted: a mute left on the
    /// application would silence the next recording this app makes.
    func releaseSystemMuteGesture() {
        let application = AVAudioApplication.shared
        try? application.setInputMuteStateChangeHandler(nil)
        if application.isInputMuted { try? application.setInputMuted(false) }
    }

    /// Tells the system which way the switch is, after the reader moved it
    /// here.
    func syncSystemMute() {
        guard hasCallAudio else { return }
        let application = AVAudioApplication.shared
        let muted = model.isSelfMuted
        guard application.isInputMuted != muted else { return }
        try? application.setInputMuted(muted)
    }
}

/// Where the gesture's one failure is written.
enum VoiceControllerTrace {
    static func note(_ message: @autoclosure () -> String) {
        DiagnosticLog.trace("voice", message())
    }
}
