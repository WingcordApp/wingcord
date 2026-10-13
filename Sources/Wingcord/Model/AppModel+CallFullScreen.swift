import AppKit

// MARK: - A call, full screen
//
// Discord's call control "Full Screen" / "Exit Full Screen" (its strings
// `OIDkcp` / `Z7MyNB`): the call view's `FULL_SCREEN` mode, which gives the
// whole screen to the tiles and the controls. Here that is the workspace's own
// window in macOS full screen with the call drawn over everything else in it
// (`CallFullScreenLayer`).
//
// **The window is borrowed, never kept.** Entering puts the window into full
// screen only if it was not there already, and leaving takes it back out only
// if entering is what put it there — so a reader who works full screen keeps
// working full screen. The system's own View › Enter Full Screen is untouched.

extension AppModel {
    /// Gives the screen to the call. Nothing without a call to show.
    func enterCallFullScreen() {
        guard connectedVoiceChannelID != nil, !isCallFullScreen else { return }
        isCallFullScreen = true
        guard let window = MainWindow.workspaceWindow else { return }
        callFullScreenTookWindow = !window.styleMask.contains(.fullScreen)
        if callFullScreenTookWindow { window.toggleFullScreen(nil) }
    }

    /// Back to the workspace — from the button, from Escape, or because the
    /// call ended.
    func exitCallFullScreen() {
        guard isCallFullScreen else { return }
        isCallFullScreen = false
        let tookWindow = callFullScreenTookWindow
        callFullScreenTookWindow = false
        guard tookWindow, let window = MainWindow.workspaceWindow,
              window.styleMask.contains(.fullScreen)
        else { return }
        window.toggleFullScreen(nil)
    }

    /// The window left full screen by the system's own control — the green
    /// button, ⌃⌘F, View › Exit Full Screen. The call goes back into the
    /// workspace with it rather than taking over a window that is no longer
    /// full screen.
    func callFullScreenWindowDidExit() {
        guard isCallFullScreen else { return }
        callFullScreenTookWindow = false
        isCallFullScreen = false
    }
}
