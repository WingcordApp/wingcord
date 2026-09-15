import AppKit
import SwiftUI

// MARK: - The window the overlay lives in
//
// **A floating window over the game, not an injected compositor**, and that is
// forced rather than chosen: `DYLD_INSERT_LIBRARIES` is ignored for any
// hardened-runtime binary, which is every notarized and every App Store game,
// and doing it anyway would cost Wingcord its own notarization.
//
// It is also the architecture Discord shipped *second* — their V3 overlay is an
// out-of-process window with named click zones — and it carries the same
// constraint they state in their own copy: it works over a game running
// windowed or borderless, not over one that has captured the display outright.
// On a Mac that is a far weaker constraint than on Windows, because Mac games
// are borderless-fullscreen Metal almost without exception.
//
// Four properties make it work, and each is load-bearing:
//
//   * `isOpaque = false` with a clear background. **This is what makes clicks
//     fall through.** The window server hit-tests the rendered alpha, so a fully
//     transparent pixel passes the click to whatever is behind it. Every
//     "click-through except the widgets" behaviour below is this one fact.
//   * `.nonactivatingPanel`. The overlay can take a click without pulling
//     Wingcord in front of the game, which is what "clickable regions while
//     locked" needs.
//   * `.canJoinAllSpaces` plus `.fullScreenAuxiliary`. Without the first the
//     window is invisible the moment the game takes its own full-screen space.
//   * A level above the game. `CGShieldingWindowLevel()` is above even a
//     captured display; `.screenSaver` is enough for everything else and does
//     not cover the menu bar. See `Level` below.

@MainActor
final class OverlayPanel {

    /// How high the panel floats.
    ///
    /// **The shield is not the default, deliberately.** At shielding level the
    /// panel also covers the menu bar and the Dock, which is right over a game
    /// and wrong over a browser somebody added by hand. `.screenSaver` sits
    /// above every ordinary window and every full-screen space, and is what the
    /// overlay uses until a game is actually detected.
    enum Level {
        case ordinary
        case aboveCapturedDisplay

        var windowLevel: NSWindow.Level {
            switch self {
            case .ordinary: .screenSaver
            case .aboveCapturedDisplay: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            }
        }
    }

    private var panel: NSPanel?
    private(set) var screen: NSScreen?
    private var frameObserver: NSObjectProtocol?

    /// The panel exists and is on screen.
    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Presenting

    /// Puts the overlay up on `screen`, building the window if it is not there.
    func present(
        on screen: NSScreen,
        level: Level,
        content: some View
    ) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        self.screen = screen

        panel.setFrame(screen.frame, display: false)
        panel.level = level.windowLevel
        // Replacing the root view rather than the hosting view: a new
        // `NSHostingView` per present drops every piece of SwiftUI state the
        // widgets hold, which on a toolbar mid-animation is a visible snap.
        if let hosting = panel.contentView as? NSHostingView<AnyView> {
            hosting.rootView = AnyView(content)
        } else {
            let hosting = NSHostingView(rootView: AnyView(content))
            // The hosting view must not paint a ground of its own, or the
            // window is opaque everywhere and nothing falls through.
            hosting.layer?.backgroundColor = .clear
            panel.contentView = hosting
        }
        panel.orderFrontRegardless()
        observeScreenChanges()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    func tearDown() {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
            self.frameObserver = nil
        }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        screen = nil
    }

    /// Whether clicks reach the overlay at all.
    ///
    /// **All-or-nothing per window, which is why the locked state has a
    /// setting.** With this `true` the panel is inert and every click goes to
    /// the game. With it `false` the transparent parts still pass clicks
    /// through — the alpha hit-test above — so only the widgets themselves are
    /// live. There is no third state, and pretending otherwise by returning nil
    /// from `hitTest` does not work: the window server never consults it.
    func setIgnoresMouseEvents(_ ignores: Bool) {
        panel?.ignoresMouseEvents = ignores
    }

    /// Takes keyboard focus, so the composer can be typed into.
    ///
    /// Only ever called for the unlocked state. A non-activating panel that
    /// never becomes key cannot receive a keystroke, and a chat window you
    /// cannot type in is not a chat window.
    func takeKeyboardFocus() {
        guard let panel else { return }
        NSApplication.shared.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func releaseKeyboardFocus() {
        panel?.resignFirstResponder()
    }

    // MARK: Building

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            // Follows the reader into the game's own full-screen space. Without
            // it the overlay simply is not there when it is most wanted.
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            // Never in ⌘` or Mission Control: it is chrome, not a window
            // somebody navigates to.
            .ignoresCycle,
        ]
        // **Sharing is left at the default, deliberately.** The obvious move is
        // `.none`, so the overlay never lands inside a stream of the game it is
        // drawn over — but `ScreenShareCapture` already excludes every Wingcord
        // window from a display share for exactly that reason, so `.none` buys
        // nothing there and takes two things away: a third-party recorder can no
        // longer capture an overlay somebody may well want on their stream, and
        // `screencapture -l` returns nothing, which is the only way to look at
        // this surface at all. `ImageRenderer` cannot substitute — it renders
        // Liquid Glass as *empty*, measured at exactly 0.0 ink in
        // `GlassRenderProbeTests`.
        return panel
    }

    /// Keeps the panel matching its screen.
    ///
    /// A game that changes resolution, or a display that is unplugged, resizes
    /// the space underneath us. The widget layout is stored normalised — see
    /// `OverlayLayout` — so the panel only has to follow the frame.
    private func observeScreenChanges() {
        guard frameObserver == nil else { return }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, let screen = self.screen else { return }
                // The screen object is stale after a parameter change; find the
                // one at the same origin, and fall back to the main display
                // when it is gone entirely.
                let current = NSScreen.screens.first { $0.frame.origin == screen.frame.origin }
                    ?? NSScreen.main
                guard let current else { return }
                self.screen = current
                panel.setFrame(current.frame, display: true)
            }
        }
    }
}

// MARK: - A borderless panel that can still be typed into

/// `NSPanel` refuses key status when it is borderless, which would leave the
/// overlay's composer unable to receive a keystroke. Overriding `canBecomeKey`
/// is the documented way round it, and the panel is still non-activating — so
/// it takes keys only once something has deliberately made it key.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
