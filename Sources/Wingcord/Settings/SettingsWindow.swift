import AppKit
import SwiftUI

/// Opens the settings window.
///
/// A free function rather than an `@Environment(\.openSettings)` read at every
/// call site: the now bar's gear, the menu bar's item and the keyboard shortcut
/// all want the same thing, and routing three of them through an environment
/// value that only resolves inside a view is how one of them silently stops
/// working.
enum SettingsWindow {
    static func open() {
        NSApp.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: nil
        )
    }
}
