import SwiftUI
import WingcordCore

// MARK: - The call surfaces raised at the window root
//
// **Presented once, here, and never from a row.** §2: a `.popover`, a `.sheet`
// or a `.confirmationDialog` written inline in a list row is evaluated as part
// of that row's body — titles included — by every row on every pass. Go Live is
// opened from two places and a call rings while the reader is anywhere in the
// app; both route through the store and are presented at the root.

private struct VoiceRootPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content
            .overlay { GoLiveLayer() }
            .overlay(alignment: .top) { incomingCall }
            .animation(motion.panel, value: model.incomingCallChannelID)
    }

    @ViewBuilder
    private var incomingCall: some View {
        if let channelID = model.incomingCallChannelID,
           let channel = model.channelIndex[channelID] {
            let caller = channel.recipientIDs.first { $0 != model.currentUserID }
            let user = caller.flatMap { model.users[$0] }
            IncomingCallCard(
                callerName: user?.preferredName ?? model.displayName(of: channel),
                avatarURL: user.flatMap { model.avatarURL(for: $0, side: 44) },
                monogram: user?.monogram ?? "?",
                accept: { model.answerCall(in: channelID) },
                decline: { model.declineCall(in: channelID) }
            )
        }
    }
}

extension View {
    /// Applied once, at the window root.
    func presentsVoiceSurfaces() -> some View {
        modifier(VoiceRootPresenter())
    }
}

// MARK: - Push to talk

/// Watches the push-to-talk key while a call is up.
///
/// **A local monitor, not a global one, and that is a deliberate limit.** A
/// global monitor needs Accessibility permission — the same one a keylogger
/// asks for — and asking a chat client's users to grant it so a key works while
/// another app is frontmost is not a trade this app makes without being asked.
/// The key works while Wingcord is frontmost, which is where the vast majority
/// of push-to-talk actually happens; the alternative is offered in the settings
/// pane in words rather than by silently requesting the permission.
///
/// Installed only while the mode is push-to-talk **and** there is a call. A
/// monitor that is always installed is a closure evaluated on every key press in
/// the application for a feature nobody is using.
private struct PushToTalkMonitor: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared
    @State private var monitor: Any?
    @State private var isHeld = false
    /// Discord's Push to Talk (Priority), held.
    @State private var isPriorityHeld = false

    func body(content: Content) -> some View {
        content
            .onChange(of: shouldWatch, initial: true) { _, watch in
                if watch { install() } else { remove() }
            }
            .onDisappear { remove() }
    }

    /// In a call, with a key to watch: push to talk's in its own mode, and the
    /// priority key in either.
    private var shouldWatch: Bool {
        model.connectedVoiceChannelID != nil
            && ((settings.inputMode == .pushToTalk && settings.pushToTalkKey != nil)
                || settings.priorityPushToTalkKey != nil)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { event in
            // The key press is **not swallowed**: push-to-talk is very often
            // bound to a modifier or a function key that other things in the
            // window also answer to, and eating every one of them would break
            // the composer.
            handle(event)
            return event
        }
    }

    /// The keys are read as each event arrives, so a binding changed while the
    /// call runs is the one that works.
    private func handle(_ event: NSEvent) {
        if settings.inputMode == .pushToTalk, let key = settings.pushToTalkKey,
           let held = Self.held(after: event, key: key, wasHeld: isHeld) {
            isHeld = held
            model.setPushToTalkHeld(held)
        }
        if let key = settings.priorityPushToTalkKey,
           let held = Self.held(after: event, key: key, wasHeld: isPriorityHeld) {
            isPriorityHeld = held
            model.setPriorityHeld(held)
        }
    }

    /// Whether `key` is held after `event`, when that changed.
    private static func held(after event: NSEvent, key: Hotkey, wasHeld: Bool) -> Bool? {
        let matches = event.keyCode == key.keyCode
        switch event.type {
        case .keyDown where matches && !wasHeld:
            return true
        case .keyUp where matches && wasHeld:
            return false
        case .flagsChanged:
            // A modifier-only binding has no key-up: the flags simply stop
            // carrying it, which is the only signal there is.
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .contains(key.modifiers)
            return held == wasHeld ? nil : held
        default:
            return nil
        }
    }

    private func remove() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        if isHeld {
            isHeld = false
            model.setPushToTalkHeld(false)
        }
        if isPriorityHeld {
            isPriorityHeld = false
            model.setPriorityHeld(false)
        }
    }
}

extension View {
    /// Applied once, at the window root.
    func watchesPushToTalk() -> some View {
        modifier(PushToTalkMonitor())
    }
}
