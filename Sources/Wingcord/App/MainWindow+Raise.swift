import AppKit

/// The workspace window, for code outside SwiftUI that has to reach it.
///
/// A namespace now — the view that used to carry the name became `WindowShell`
/// (REDESIGN.md) — kept under the old name so every caller still reads the same.
@MainActor
enum MainWindow {
    /// Activates the app with the main window key — from the global shortcut,
    /// and from a settings window handing the reader back to a page.
    ///
    /// The main window rather than `keyWindow`: from a hidden app there is no
    /// key window to raise, and from a settings window the settings window is
    /// not what was asked for.
    static func raise() {
        let app = NSApplication.shared
        app.activate()
        if let window = workspaceWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        app.windows.first { $0.isVisible && $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
    }

    /// The workspace's window — the `Window` scene whose id is `main`.
    static var workspaceWindow: NSWindow? {
        NSApplication.shared.windows.first { $0.identifier?.rawValue.contains("main") == true }
    }
}
