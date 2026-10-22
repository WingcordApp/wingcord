import AppKit
import Observation
import WingcordCore

// MARK: - Game Mode
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D21). Discord's `GameModeStore`
// (`2026-08-game-mode`), read out of build 643186:
//
//   isActive     = enabled (on unless switched off) && a game is running that
//                  is not a launcher
//   isThrottling = isActive && !Discord focused && !Discord hovered
//
// Focus is read two seconds after it changes, and the pointer counts as gone
// two seconds after it leaves — so glancing across the window does not flap.
// While throttling Discord overrides GIF autoplay and animated emoji off and
// stickers to animate on interaction ("This is temporarily off while Game
// Mode is active."), and caps its window at ten frames a second; while active
// it caps the overlay at thirty.
//
// Wingcord already holds most moving pictures while it is in the background —
// the animation clock and the transcript's layers stop with the app — so
// Game Mode's levers here are the ones that would otherwise keep running
// beside a game: the video wallpaper (it plays whenever its window is on
// screen), animated emoji and banners outside that clock, and the house
// animations (reduced, as Reduce Motion reduces them).

@Observable
@MainActor
final class GameMode {
    static let shared = GameMode()

    /// Discord's "Enable Game Mode". On unless switched off — Discord's
    /// `enabled !== false`.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.key)
            update()
        }
    }

    /// The game Game Mode is for, when one runs.
    private(set) var game: DetectedGame?

    /// Whether Wingcord is in front, as last settled.
    private(set) var isFocused = NSApp?.isActive ?? true
    /// Whether the pointer is over one of Wingcord's own windows.
    private(set) var isHovered = false

    /// Discord's `isActive`.
    var isActive: Bool { isEnabled && game.map { !$0.isLauncher } == true }

    /// Discord's `isThrottling`: the overrides are on.
    var isThrottling: Bool { isActive && !isFocused && !isHovered }

    /// Discord's words beside a setting Game Mode is holding off.
    static let overrideNote = "This is temporarily off while Game Mode is active."

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pointerMonitor: Any?
    @ObservationIgnored private var localPointerMonitor: Any?
    @ObservationIgnored private var wasThrottling = false
    private static let key = "gameMode.enabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    // MARK: The game

    /// The detected game changed. Called by the session with the game it
    /// publishes — a game whose detection is switched off never gets here.
    func gameChanged(_ game: DetectedGame?) {
        guard self.game != game else { return }
        self.game = game
        update()
    }

    // MARK: Focus and the pointer

    private func update() {
        if isActive { startWatching() } else { stopWatching() }
        settle()
    }

    private func startWatching() {
        guard observers.isEmpty else { return }
        let centre = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusChanged() }
            })
        }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: kinds) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        isFocused = NSApp?.isActive ?? true
        pointerMoved()
    }

    private func stopWatching() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        pointerMonitor = nil
        localPointerMonitor = nil
        focusTask?.cancel()
        hoverTask?.cancel()
    }

    /// Focus is read two seconds after it changes — Discord's debounce.
    private func focusChanged() {
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let focused = NSApp?.isActive ?? true
            guard focused != self.isFocused else { return }
            self.isFocused = focused
            self.settle()
        }
    }

    /// The pointer counts at once on the way in and two seconds after it
    /// leaves.
    private func pointerMoved() {
        let over = Self.isPointerOverWingcord()
        if over {
            hoverTask?.cancel()
            hoverTask = nil
            guard !isHovered else { return }
            isHovered = true
            settle()
        } else if isHovered, hoverTask == nil {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.hoverTask = nil
                guard !Self.isPointerOverWingcord() else { return }
                self.isHovered = false
                self.settle()
            }
        }
    }

    /// Whether the pointer is over a Wingcord window a reader looks at — not
    /// the overlay, which covers the game and is under the pointer all the
    /// time, and not a floating panel over it.
    private static func isPointerOverWingcord() -> Bool {
        let location = NSEvent.mouseLocation
        return (NSApp?.windows ?? []).contains { window in
            window.isVisible && !(window is NSPanel) && window.frame.contains(location)
        }
    }

    /// Tells everything that reads the overrides when they flip.
    private func settle() {
        let throttling = isThrottling
        guard throttling != wasThrottling else { return }
        wasThrottling = throttling
        Breadcrumbs.record("game mode: \(throttling ? "throttling" : "not throttling")")
        // The drawn canvases read the overrides through the animation clock's
        // gate; this is how they learn it moved.
        PresentationRevision.shared.settingsDidChange()
    }
}
