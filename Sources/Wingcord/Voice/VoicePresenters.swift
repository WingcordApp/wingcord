import SwiftUI
import WingcordCore

// MARK: - The three call surfaces raised at the window root
//
// **Presented once, here, and never from a row.** §2: a `.popover`, a `.sheet`
// or a `.confirmationDialog` written inline in a list row is evaluated as part
// of that row's body — titles included — by every row on every pass. The
// soundboard is opened from three places, the screen picker from two, and a
// call rings while the reader is anywhere in the app; all three route through
// the store and are presented at the root.

private struct VoiceRootPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content
            // A sheet rather than a popover: choosing what to share is a
            // decision with a Cancel and a default action, and it anchors to
            // nothing in particular.
            .sheet(isPresented: screenPickerBinding) {
                ScreenSharePicker(
                    start: { model.startScreenShare(target: $0) },
                    dismiss: { model.isScreenSharePickerOpen = false }
                )
            }
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

    /// **The setter may only clear when the store is still showing this one.**
    /// Clearing unconditionally lets a dismissal that arrives while a second
    /// presentation is opening take the new one down with it.
    private var screenPickerBinding: Binding<Bool> {
        Binding(
            get: { model.isScreenSharePickerOpen },
            set: {
                if !$0, model.isScreenSharePickerOpen { model.isScreenSharePickerOpen = false }
            }
        )
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

    func body(content: Content) -> some View {
        content
            .onChange(of: shouldWatch, initial: true) { _, watch in
                if watch { install() } else { remove() }
            }
            .onDisappear { remove() }
    }

    private var shouldWatch: Bool {
        model.connectedVoiceChannelID != nil
            && settings.inputMode == .pushToTalk
            && settings.pushToTalkKey != nil
    }

    private func install() {
        guard monitor == nil, let key = settings.pushToTalkKey else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { event in
            // The key press is **not swallowed**: push-to-talk is very often
            // bound to a modifier or a function key that other things in the
            // window also answer to, and eating every one of them would break
            // the composer.
            handle(event, key: key)
            return event
        }
    }

    private func handle(_ event: NSEvent, key: Hotkey) {
        let matches = event.keyCode == key.keyCode
        switch event.type {
        case .keyDown where matches && !isHeld:
            isHeld = true
            model.setPushToTalkHeld(true)
        case .keyUp where matches && isHeld:
            isHeld = false
            model.setPushToTalkHeld(false)
        case .flagsChanged:
            // A modifier-only binding has no key-up: the flags simply stop
            // carrying it, which is the only signal there is.
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .contains(key.modifiers)
            guard held != isHeld else { return }
            isHeld = held
            model.setPushToTalkHeld(held)
        default:
            break
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
    }
}

extension View {
    /// Applied once, at the window root.
    func watchesPushToTalk() -> some View {
        modifier(PushToTalkMonitor())
    }
}
