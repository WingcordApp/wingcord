import AppKit
import SwiftUI

/// Opens the clips library — Discord's Clips Home, as a window of its own
/// (docs/CLIPS-PRESENCE.md, D13 / Phase 4.2).
///
/// `SettingsWindow`'s shape: one `Window` scene, its `openWindow` captured
/// once by the root view, one call path for the File menu, Settings › Clips
/// and a saved clip's notice.
@MainActor
enum ClipsWindow {
    static let sceneID = "clips"

    private static var opener: (() -> Void)?

    static func register(_ open: @escaping () -> Void) {
        opener = open
    }

    /// The item to open in the editor once the window is up, if any.
    private(set) static var pendingEdit: URL?

    static func takePendingEdit() -> URL? {
        defer { pendingEdit = nil }
        return pendingEdit
    }

    /// - Parameter editing: a clip to open straight in the editor.
    static func open(editing: URL? = nil) {
        pendingEdit = editing
        NSApp.activate()
        opener?()
        if editing != nil { NotificationCenter.default.post(name: didRequestEdit, object: nil) }
    }

    static let didRequestEdit = Notification.Name("ClipsWindow.didRequestEdit")
}

extension View {
    /// Applied once, at the window root.
    func providesClipsWindow() -> some View {
        modifier(ClipsWindowOpenerModifier())
    }
}

private struct ClipsWindowOpenerModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            ClipsWindow.register { openWindow(id: ClipsWindow.sceneID) }
        }
    }
}
