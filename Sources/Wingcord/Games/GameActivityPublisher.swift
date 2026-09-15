import SwiftUI

// MARK: - Keeping the sharing preference honest
//
// A modifier at the window root rather than a `didSet` on `AppSettings`, and
// for the reason written up on that type: every `didSet` there fires while its
// own one-time initialisation is still in flight, so nothing in it may reach
// another singleton. By the time a view body runs, the store has finished
// loading and the session can be told the truth. `GlobalHotkeyInstaller` exists
// for exactly the same reason and in exactly this shape.
//
// **Without this the setting is a lie in the dangerous direction.** The
// preference is read at publish time, so turning sharing *off* would change
// nothing until something else happened to republish — leaving a game on
// everybody's roster that the reader has just asked this client to hide.

private struct GameActivityPublisher: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    func body(content: Content) -> some View {
        content
            // **`--overlay` seeds a game before anything is listening for one.**
            // The real arming happens in the detector's own callback, which no
            // fixture reaches, so the flag has to do by hand what a detection
            // would have done — and then unlock, because locked is the state
            // with the fewest widgets in it and looking at the thing is the
            // whole reason the flag exists. Escape leaves, as it does over a
            // real game.
            .task {
                guard LaunchOptions.current.pretendsAGameIsRunning else { return }
                // **From the default arrangement, every time.** The flag exists
                // to be photographed, and a capture whose widget positions come
                // out of whatever the last session dragged them to is a capture
                // that cannot be compared with the one before it. Nobody who is
                // not photographing this passes the flag.
                model.overlay.resetLayout()
                model.refreshOverlay()
                model.overlay.toggle()
                // **And a conversation open in it**, because the chat window is
                // the most expensive widget on this overlay and the only one
                // whose resting state is nothing at all — a flag that draws
                // every widget but that one leaves the expensive half of the
                // surface unlookable. The X in its header closes it.
                // **Two conversations, not one.** The rail down the chat
                // window's leading edge only exists when something else is open
                // behind it, so a flag that opened one left a whole sub-surface
                // undrawable. Opened oldest first, so the newest ends up the one
                // on screen.
                let conversations = model.channelIndex.privateChannelIDs().prefix(2).reversed()
                for channelID in conversations { model.overlay.openChat(channelID) }
                if let channelID = conversations.last {
                    // **And one toast**, for the same reason: the notification
                    // widget's resting state is nothing, so the reply field
                    // inside it — the pause, the send, the hold on the
                    // auto-dismiss — could not be looked at without waiting for
                    // somebody to write to the account mid-game.
                    let notice = DemoFixtures.notice(in: channelID, model: model)
                    model.overlay.show(notice)
                    // **And its reply field open**, which is also what stops the
                    // toast retiring seven seconds into the launch: a reply in
                    // progress holds the auto-dismiss, so the one state worth
                    // photographing is the one that stays put. The resting form
                    // is one click away — the X closes the field.
                    model.overlay.beginReply(to: notice)
                }
            }
            // `initial: false`: the first publish is the session's own, and
            // sending a second one at launch is a wasted frame on the socket.
            .onChange(of: settings.sharesGameActivity) { _, _ in
                model.sessionController.gameSharingPreferenceChanged()
            }
            // The overlay and the clip buffer are armed from the same two
            // facts — is a game running, and is the feature switched on — so
            // both preferences land in one place. `refreshOverlay` is
            // idempotent, which is what lets this be a blunt re-evaluation
            // rather than four separate handlers.
            .onChange(of: settings.isOverlayEnabled) { _, _ in model.refreshOverlay() }
            .onChange(of: settings.clipsEnabled) { _, _ in model.refreshOverlay() }
            .onChange(of: settings.overlayHasClickableRegions) { _, _ in
                model.overlay.refreshPresentation()
            }
            // The corner is a widget position, so changing it moves the widget
            // rather than adding a second way of saying where things are.
            .onChange(of: settings.overlayNotificationCorner) { _, corner in
                var layout = model.overlay.layout
                layout.move(.notifications, to: corner.centre)
                model.overlay.layout = layout
            }
    }
}

extension View {
    /// Applied once, at the window root.
    func publishesGameActivity() -> some View {
        modifier(GameActivityPublisher())
    }
}
