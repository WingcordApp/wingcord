import AppKit

extension MainWindow {
    /// Activates the app with the main window key — from the global shortcut,
    /// and from a settings window handing the reader back to a page.
    ///
    /// The main window rather than `keyWindow`: from a hidden app there is no
    /// key window to raise, and from a settings window the settings window is
    /// not what was asked for.
    static func raise() {
        let app = NSApplication.shared
        app.activate()
        for window in app.windows where window.identifier?.rawValue.contains("main") == true {
            window.makeKeyAndOrderFront(nil)
            return
        }
        app.windows.first { $0.isVisible && $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
    }
}
