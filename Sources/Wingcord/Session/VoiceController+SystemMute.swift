import AVFAudio
import Foundation
import WingcordCore

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
            try application.setInputMuteStateChangeHandler(
                Self.systemMuteHandler { [weak self] shouldBeMuted in
                    self?.applySystemMute(shouldBeMuted)
                }
            )
        } catch {
            VoiceControllerTrace.note("system mute gesture refused: \(error.localizedDescription)")
        }
        syncSystemMute()
    }

    /// The block the system calls on a press of the stem.
    ///
    /// **Built here, in a nonisolated function, and never inline in
    /// `adoptSystemMuteGesture`.** The system calls it on a dispatch queue of
    /// its own. A closure literal written inside a main-actor method is
    /// main-actor isolated in Swift 6 — this target's default isolation — and
    /// the compiler guards its entry with a runtime isolation check, which
    /// traps on that queue: every voice join crashed with `SIGTRAP` in
    /// `dispatch_assert_queue` the moment the system first called it
    /// (2026-11-12, three reports). Made here, the closure has no isolation;
    /// only the `Task` inside hops to the main actor.
    ///
    /// The answer is "yes" at once: the mute itself is one hop away and cannot
    /// fail.
    nonisolated static func systemMuteHandler(
        _ apply: @escaping @Sendable @MainActor (Bool) -> Void
    ) -> @Sendable (Bool) -> Bool {
        { shouldBeMuted in
            Task { @MainActor in apply(shouldBeMuted) }
            return true
        }
    }

    /// A press, on the main actor.
    private func applySystemMute(_ shouldBeMuted: Bool) {
        guard hasCallAudio else { return }
        // Unmuting while deafened would be a microphone nobody on the call can
        // answer; the press undeafens, as the mute button does there.
        if !shouldBeMuted, model.isSelfDeafened {
            setDeafened(false)
        }
        setMuted(shouldBeMuted)
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
        Log.fault(.voice, .raw(message()))
    }
}
