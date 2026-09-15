import AppKit
import Observation
import SwiftUI
import WingcordCore

// MARK: - The overlay's state machine
//
// **Two states and one boolean**, which is the model Discord's own overlay
// turned out to be built on — `isInputLocked(pid)`, read out of the bundle:
//
//                  locked (passive)          unlocked (open)
//   widgets        pinned only               all
//   interactive    no                        yes
//   ground         nothing                   a scrim
//   chrome         an unlock button          close, and the keybind that closed it
//
// Everything else follows. `OverlayLayout.visibleWidgets(locked:)` is the whole
// of the first row; `OverlayPanel.setIgnoresMouseEvents` is the second.
//
// Four things put it back to sleep, and one of them is the ground itself:
//
//   1. the keybind,
//   2. Escape,
//   3. a click on the background — not on a widget, which is the distinction
//      that makes "click outside to dismiss" work at all,
//   4. the game going away.

@Observable
@MainActor
final class OverlayController {

    /// Whether the overlay window is on screen at all.
    ///
    /// **Not the same as unlocked.** A game running with the voice panel pinned
    /// has the overlay present and locked: visible, click-through, showing one
    /// widget. Presented is about the window existing; locked is about who owns
    /// the mouse.
    private(set) var isPresented = false

    /// Whether the game has the mouse.
    ///
    /// Starts locked. An overlay that opened unlocked would steal the pointer
    /// from a game the moment somebody launched it.
    private(set) var isLocked = true

    /// Whether the reader is rearranging widgets.
    ///
    /// Only reachable from the unlocked state, and locking leaves it.
    private(set) var isEditingLayout = false

    /// Suppresses every widget while held, so the reader can see the game.
    ///
    /// **Discord binds this to Alt, and it HIDES rather than reveals** — which
    /// is the opposite of what the layout-mode screenshots suggest and was
    /// worth reading the dispatch to be sure of.
    private(set) var isPeeking = false

    /// Where the widgets are.
    var layout: OverlayLayout {
        didSet {
            guard layout != oldValue else { return }
            OverlayLayoutStore.save(layout)
        }
    }

    /// Toasts on screen right now. See `OverlayNotice`.
    var notices: [OverlayNotice] = []

    /// What the clip key just did, if anything.
    var clipFeedback: ClipFeedback?
    /// Which `showClipFeedback` call owns the current message, so a later one
    /// cannot be cleared by an earlier one's timer.
    var clipFeedbackToken: UUID?

    /// The last thing that went wrong, for the settings pane to show.
    private(set) var lastFailure: String?

    private let panel = OverlayPanel()
    private var peekMonitor: Any?
    private var escapeMonitor: Any?
    private weak var model: AppModel?

    init(model: AppModel? = nil) {
        self.model = model
        layout = OverlayLayoutStore.load()
    }

    func attach(model: AppModel) {
        self.model = model
    }

    // MARK: What decides whether it is up at all

    /// Re-evaluates presence from the world: is a game running, and is the
    /// overlay switched on.
    ///
    /// Called whenever the detected game or the preference changes. Idempotent,
    /// so callers do not have to know whether anything actually moved.
    func refreshPresentation() {
        let settings = AppSettings.shared
        let wanted = settings.isOverlayEnabled && model?.detectedGame != nil
        if wanted {
            present()
        } else {
            dismiss()
        }
    }

    private func present() {
        guard let model else { return }
        guard let screen = NSScreen.main else { return }
        isPresented = true
        panel.present(
            on: screen,
            // The shield covers the menu bar, which is right over a game and
            // wrong over anything else. A detected game is the licence.
            level: model.detectedGame != nil ? .aboveCapturedDisplay : .ordinary,
            content: OverlayScene(controller: self).environment(model)
        )
        applyInputState()
        installPeekMonitor()
    }

    private func dismiss() {
        guard isPresented else { return }
        isPresented = false
        isEditingLayout = false
        isLocked = true
        removeMonitors()
        panel.dismiss()
    }

    func tearDown() {
        removeMonitors()
        panel.tearDown()
        isPresented = false
        isLocked = true
        isEditingLayout = false
    }

    // MARK: The lock

    /// The overlay keybind. Opens it, or puts it back to sleep.
    ///
    /// **Presents on demand even with no game running.** A reader who bound a
    /// key and pressed it expects something to happen; refusing silently
    /// because no game was detected is the single most confusing thing this
    /// surface could do.
    func toggle() {
        if !isPresented {
            AppSettings.shared.isOverlayEnabled = true
            present()
            setLocked(false)
            return
        }
        setLocked(!isLocked)
    }

    /// The second keybind: hand the mouse back without dismissing.
    func toggleInputLock() {
        guard isPresented else { return }
        setLocked(!isLocked)
    }

    func setLocked(_ locked: Bool) {
        guard isLocked != locked else { return }
        isLocked = locked
        if locked { isEditingLayout = false }
        applyInputState()
    }

    /// A click that landed on the ground rather than on a widget.
    ///
    /// The test lives in the view — a `.background` that only the ground hosts —
    /// because SwiftUI cannot tell us what a click passed over, only what it
    /// reached.
    func backgroundClicked() {
        setLocked(true)
    }

    func setEditingLayout(_ editing: Bool) {
        // **The lock is the precondition, not the window.** Whether a panel
        // exists is the panel's business; arranging widgets is about who owns
        // the mouse. `dismiss()` clears this, so it cannot survive the overlay
        // going away.
        guard !isLocked else { return }
        isEditingLayout = editing
    }

    // MARK: Plumbing the state into the window

    private func applyInputState() {
        // **Nothing to configure when nothing is up.** `setLocked` is reachable
        // before the panel exists — the settings pane and the keybind both
        // change the lock — and reaching for a window that was never built is
        // work at best and, where it activates the app, a crash.
        guard isPresented else { return }
        // Locked, the panel is inert unless the reader has asked for clickable
        // regions — in which case the transparent ground still passes clicks
        // through and only the widgets take them. See `OverlayPanel`.
        let clickable = !isLocked || AppSettings.shared.overlayHasClickableRegions
        panel.setIgnoresMouseEvents(!clickable)
        if isLocked {
            panel.releaseKeyboardFocus()
        } else {
            panel.takeKeyboardFocus()
        }
        installEscapeMonitor()
    }

    // MARK: Alt to peek, Escape to leave

    private func installPeekMonitor() {
        guard peekMonitor == nil else { return }
        // A **local** monitor: this fires only while Wingcord has key focus,
        // which is exactly when the overlay is unlocked and peeking means
        // anything. A global one would need the accessibility permission to
        // watch every modifier press on the machine, for a convenience.
        peekMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) {
            [weak self] event in
            let held = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated {
                guard let self, self.isPresented, !self.isLocked else { return }
                if self.isPeeking != held { self.isPeeking = held }
            }
            return event
        }
    }

    private func installEscapeMonitor() {
        if isLocked {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            return
        }
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            // 53 is Escape. Swallowed rather than passed on: the overlay is in
            // front and the key belongs to it.
            guard event.keyCode == 53 else { return event }
            var handled = false
            MainActor.assumeIsolated {
                guard let self, self.isPresented, !self.isLocked else { return }
                self.setLocked(true)
                handled = true
            }
            return handled ? nil : event
        }
    }

    private func removeMonitors() {
        if let peekMonitor { NSEvent.removeMonitor(peekMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        peekMonitor = nil
        escapeMonitor = nil
        isPeeking = false
    }

    func report(_ failure: String) {
        lastFailure = failure
        Breadcrumbs.record("overlay: \(failure)")
    }
}

// MARK: - The layout, between launches

enum OverlayLayoutStore {
    private static let key = "overlay.layout"

    static func load() -> OverlayLayout {
        guard let data = UserDefaults.standard.data(forKey: key),
              let layout = try? JSONDecoder().decode(OverlayLayout.self, from: data)
        else { return .default }
        return layout
    }

    static func save(_ layout: OverlayLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
