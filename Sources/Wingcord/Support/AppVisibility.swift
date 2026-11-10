import AppKit

/// Whether any of the app's windows can actually be seen.
///
/// **The one answer for everything that should not run for nobody**: the window
/// covered by another one, minimized, on another Space, or the app hidden.
/// Decided per window rather than by `NSApp.occlusionState`, because a borderless
/// strip or a status item counts as visible to the app and would keep that true
/// for good. Only real windows count, the ones with a title bar.
@MainActor
final class AppVisibility {
    static let shared = AppVisibility()

    /// True until proven otherwise: with no `NSApp`, as in a test, everything
    /// runs as it always has.
    private(set) var isVisible = true

    private struct Listener {
        weak var owner: AnyObject?
        var changed: (Bool) -> Void
    }

    private var listeners: [ObjectIdentifier: Listener] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                MainActor.assumeIsolated { AppVisibility.shared.refresh(excluding: closing) }
            })
        }
    }

    /// Calls `changed` with the new answer whenever it changes. Replaces the
    /// owner's earlier registration; the owner is held weakly.
    func observe(_ owner: AnyObject, changed: @escaping (Bool) -> Void) {
        listeners[ObjectIdentifier(owner)] = Listener(owner: owner, changed: changed)
    }

    func stopObserving(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
    }

    private func refresh(excluding closing: NSWindow?) {
        guard let application = NSApp else { return }
        let visible = !application.isHidden && application.windows.contains { window in
            window !== closing
                && window.styleMask.contains(.titled)
                && window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
        guard visible != isVisible else { return }
        isVisible = visible
        listeners = listeners.filter { $0.value.owner != nil }
        for listener in listeners.values { listener.changed(visible) }
    }
}
