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
