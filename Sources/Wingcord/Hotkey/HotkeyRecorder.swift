import AppKit
import Carbon.HIToolbox
import Observation

// MARK: - Recording a shortcut
//
// While this is running the keyboard belongs to it and to nothing else. That is
// the whole difficulty: a recorder that only listens on the responder chain
// never sees ⌘Q, because `NSApplication.sendEvent(_:)` hands a key equivalent to
// the main menu FIRST and the menu quits the app. `addLocalMonitorForEvents`
// runs earlier still — before `sendEvent`, as the event leaves the queue — so
// returning nil there is the one place a key can be swallowed whole.
//
// Two consequences, both load-bearing:
//
//   1. The monitor MUST be removed. AppKit keeps the closure — and everything it
//      captured — alive for the life of the process otherwise, and a recorder
//      that leaks its monitor leaves ⌘Q dead in an app that looks idle.
//   2. Nothing else in the app may install a competing monitor for `.keyDown`
//      while this one is up. There is exactly one recorder, owned by the panel.

@MainActor
@Observable
final class HotkeyRecorder {

    /// What the flyout is showing.
    enum Phase: Equatable {
        /// Nothing held: the stored binding, or the empty prompt.
        case idle
        /// Keys are down. `caps` is what to draw right now.
        case recording(caps: [Hotkey.Cap])
        /// A binding just landed. Drives the green flash.
        case accepted
        /// The last combination was refused, with the reason to print.
        case rejected(reason: String)
    }

    private(set) var phase: Phase = .idle

    /// The binding as it stands — the stored one until a new one is accepted.
    private(set) var hotkey: Hotkey?

    /// Raised for `flashHold + flashFade` after a binding is accepted, and read
    /// by the view as the flash's opacity driver.
    private(set) var isFlashing = false

    /// Called once, with the accepted binding, the moment it is valid.
    var onCommit: ((Hotkey?) -> Void)?

    /// Called when the reader asks to close — ⎋ or ↩ with nothing held.
    var onDismiss: (() -> Void)?

    private var monitor: Any?
    private var flashTask: Task<Void, Never>?
    /// The modifiers held right now, live, so a chord builds up glyph by glyph
    /// the way the reference's does.
    private var liveModifiers: NSEvent.ModifierFlags = []

    init(hotkey: Hotkey?) {
        self.hotkey = hotkey
    }

    /// **`isolated deinit`, and it is load-bearing.** An `NSEvent` monitor must
    /// be removed on the main actor, and a plain `deinit` is nonisolated — it
    /// cannot even read the stored reference. Without this, a recorder released
    /// without `end()` leaves a local monitor installed for the life of the
    /// process, which means every key press in the app goes through a closure
    /// belonging to a flyout that closed hours ago, and ⌘Q never reaches the
    /// menu again.
    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: Lifecycle

    func begin() {
        guard monitor == nil else { return }
        liveModifiers = []
        phase = .idle
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
            [weak self] event in
            guard let self else { return event }
            // Nil swallows the event. Everything reaching this closure is meant
            // for the recorder, including the combinations that would otherwise
            // quit the app.
            return self.handle(event) ? nil : event
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        flashTask?.cancel()
        flashTask = nil
        isFlashing = false
        phase = .idle
        liveModifiers = []
    }

    // MARK: Events

    /// - Returns: whether the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            liveModifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .option, .control, .shift])
            if liveModifiers.isEmpty {
                // Every modifier released without a character: back to showing
                // what is actually bound. The reference does the same, and it is
                // what stops a half-pressed chord from looking committed.
                if case .recording = phase { phase = .idle }
            } else {
                phase = .recording(caps: modifierCaps())
            }
            return true

        case .keyDown:
            // ⎋ and ↩ close, but only when they are not part of a chord — ⌥↩ is
            // a shortcut somebody may genuinely want.
            if liveModifiers.isEmpty {
                switch Int(event.keyCode) {
                case kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter:
                    onDismiss?()
                    return true
                case kVK_Delete, kVK_ForwardDelete:
                    // Clearing is deliberate and is not in the reference: a
                    // binding you cannot remove is a global shortcut you cannot
                    // give back to the rest of the machine.
                    hotkey = nil
                    onCommit?(nil)
                    accept()
                    return true
                default:
                    break
                }
            }
            let candidate = Hotkey(keyCode: event.keyCode, modifiers: liveModifiers)
            guard candidate.isValid else {
                phase = .rejected(reason: candidate.rejection ?? "")
                return true
            }
            hotkey = candidate
            onCommit?(candidate)
            accept()
            return true

        case .keyUp:
            return true

        default:
            return false
        }
    }

    private func modifierCaps() -> [Hotkey.Cap] {
        var caps: [Hotkey.Cap] = []
        if liveModifiers.contains(.control) { caps.append(.init(kind: .modifier, label: "⌃")) }
        if liveModifiers.contains(.option) { caps.append(.init(kind: .modifier, label: "⌥")) }
        if liveModifiers.contains(.shift) { caps.append(.init(kind: .modifier, label: "⇧")) }
        if liveModifiers.contains(.command) { caps.append(.init(kind: .modifier, label: "⌘")) }
        return caps
    }

    /// The flash: full for `flashHold`, then out over `flashFade`.
    ///
    /// One task, cancelled and replaced, so pressing three combinations quickly
    /// leaves one flash rather than three overlapping fades.
    private func accept() {
        phase = .accepted
        flashTask?.cancel()
        isFlashing = true
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(HotkeyMetrics.flashHold))
            guard !Task.isCancelled else { return }
            self?.isFlashing = false
        }
    }
}
