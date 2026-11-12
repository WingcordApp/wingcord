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

    /// Whether the game overlay is on screen.
    ///
    /// **Its own answer, and only for what arrives.** The overlay is a
    /// borderless panel over a game, so it does not make `isVisible` true, and
    /// it should not: a game running is when this app has to cost least, and
    /// counting the overlay as a window would start every animation and keep
    /// every cache for it. But a chat somebody is reading over their game was
    /// then up to a second behind, because nothing could be "seen". So the
    /// overlay being up means updates are applied as they arrive, and nothing
    /// else. Set by `OverlayController`, which is the only thing that knows.
    private(set) var isOverlayShown = false

    /// Whether an update should be applied the moment it arrives: a window can
    /// be seen, or the overlay is up.
    var deliversAtOnce: Bool { isVisible || isOverlayShown }

    private var listeners: [ObjectIdentifier: Listener] = [:]
    private var deliveryListeners: [ObjectIdentifier: Listener] = [:]
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
        deliveryListeners[ObjectIdentifier(owner)] = nil
    }

    /// Calls `changed` whenever `deliversAtOnce` changes. One registration an
    /// owner, held weakly, beside whatever it registered with `observe`.
    func observeDelivery(_ owner: AnyObject, changed: @escaping (Bool) -> Void) {
        deliveryListeners[ObjectIdentifier(owner)] = Listener(owner: owner, changed: changed)
    }

    func setOverlayShown(_ shown: Bool) {
        guard shown != isOverlayShown else { return }
        let before = deliversAtOnce
        isOverlayShown = shown
        if deliversAtOnce != before { noteDeliveryChanged() }
    }

    private func noteDeliveryChanged() {
        deliveryListeners = deliveryListeners.filter { $0.value.owner != nil }
        let delivers = deliversAtOnce
        for listener in deliveryListeners.values { listener.changed(delivers) }
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
        let before = deliversAtOnce
        isVisible = visible
        listeners = listeners.filter { $0.value.owner != nil }
        for listener in listeners.values { listener.changed(visible) }
        if deliversAtOnce != before { noteDeliveryChanged() }
    }
}
