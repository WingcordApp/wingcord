import AppKit
import SwiftUI

/// Opens the settings window.
///
/// A free function rather than an `@Environment(\.openSettings)` read at every
/// call site: the now bar's gear, the menu bar's item and the keyboard shortcut
/// all want the same thing, and routing three of them through an environment
/// value that only resolves inside a view is how one of them silently stops
/// working.
///
/// **Not a `Settings` scene.** SwiftUI's own settings scene builds a window that
/// cannot be resized — it writes its style mask after the content view joins the
/// window, so neither `windowResizability` nor an `NSWindow` configuration
/// survives, and the source list's drag divider then has nothing to give. This
/// is an ordinary `Window` scene wearing the settings scene's keyboard shortcut
/// and menu item.
///
/// The one piece of machinery that costs is `openWindow`, which resolves only
/// inside a view. It is captured **once**, by the root view, into the static
/// below — so there is still exactly one call path, which is the property the
/// doc comment above is really about.
@MainActor
enum SettingsWindow {
    /// The scene's identifier, shared by the scene and by everything that opens
    /// it, so a rename cannot leave one of them behind.
    static let sceneID = "settings"

    private static var opener: (() -> Void)?

    /// Called once by the root view. Idempotent.
    static func register(_ open: @escaping () -> Void) {
        opener = open
    }

    static func open() {
        // An already-open window is raised rather than reopened: `openWindow`
        // on a `Window` scene does raise it, but it does not make the app active
        // when the call came from a background context.
        NSApp.activate()
        opener?()
    }
}

extension View {
    /// Applied once, at the root of the main window, so `SettingsWindow.open()`
    /// has something to call.
    func providesSettingsWindow() -> some View {
        modifier(SettingsWindowOpenerModifier())
    }
}

private struct SettingsWindowOpenerModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            SettingsWindow.register { openWindow(id: SettingsWindow.sceneID) }
        }
    }
}
