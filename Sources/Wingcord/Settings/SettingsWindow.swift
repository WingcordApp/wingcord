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
/// survives — and twenty scrolling panes of very different lengths want a
/// window the reader can make taller. This is an ordinary `Window` scene wearing
/// the settings scene's keyboard shortcut and menu item.
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

    /// The page an incoming `request(_:)` asked for, until the window takes it.
    ///
    /// **A pending value rather than a parameter on the scene**, because this is
    /// a `Window` and not a `WindowGroup`: it has no value to be presented with,
    /// and one already open cannot be re-opened at a different page. The window
    /// reads this as it appears and on every `didRequestSection`, and clears it —
    /// so a second caller asking for a second page moves the window rather than
    /// being ignored.
    ///
    /// `ServerSettingsWindow` does not need this: its scene *is* value-driven,
    /// and the page rides `ServerSettingsTarget`.
    private(set) static var pendingSection: SettingsSection?

    /// Takes the pending page, if there is one. Reading it consumes it.
    static func takePendingSection() -> SettingsSection? {
        defer { pendingSection = nil }
        return pendingSection
    }

    /// - Parameter section: the page to open on, or nil to leave the window
    ///   wherever it was — which is what every existing caller wants.
    static func open(_ section: SettingsSection? = nil) {
        if let section { request(section) }
        // An already-open window is raised rather than reopened: `openWindow`
        // on a `Window` scene does raise it, but it does not make the app active
        // when the call came from a background context.
        NSApp.activate()
        opener?()
    }

    /// Asks the window for a page: an open window moves to it now, and a closed
    /// one opens on it.
    static func request(_ section: SettingsSection) {
        pendingSection = section
        NotificationCenter.default.post(name: didRequestSection, object: nil)
    }

    /// Posted when a page is asked for, so a window that is already open moves
    /// to it.
    ///
    /// **Not the app becoming active**, which is what the window listened for
    /// before: a window already open in an app already active sees no such
    /// thing, so "Activity Settings" on a card raised the window on whatever
    /// page it was showing — and the page it asked for then arrived at the next
    /// activation, unasked.
    static let didRequestSection = Notification.Name("WingcordSettingsDidRequestSection")

    /// The pane the window was last on, so it reopens there — the HIG's
    /// "Restore the most recently viewed pane".
    static var lastSection: SettingsSection {
        get {
            UserDefaults.standard.string(forKey: lastSectionKey)
                .flatMap(SettingsSection.init(rawValue:)) ?? .general
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lastSectionKey) }
    }

    private static let lastSectionKey = "settings.lastSection"
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
