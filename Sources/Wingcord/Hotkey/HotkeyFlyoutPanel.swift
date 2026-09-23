import AppKit
import SwiftUI

// MARK: - The panel the flyout lives in
//
// Its own window, not a `.popover`, and the reason is geometry rather than
// taste: the flyout is 320 wide, centred on a control that sits 38 points from
// the settings window's trailing edge, so a hundred points of it hang off the
// window. There is nothing to clip it against but a window of its own.
//
// A borderless `NSPanel` and not an `NSWindow`, because a panel can be
// non-activating: the settings window keeps its key status and its focus ring
// while this is up, which is what the reference does and what keeps the ⌘ in
// the corner from dimming.
//
// **The keyboard is claimed by `HotkeyRecorder`, not by this window.** A local
// event monitor sees keys before the main menu does, which is the only place
// ⌘Q can be swallowed — see the note there. It follows that this panel does not
// need to be key at all, and not making it key is what stops the settings
// window's text fields from losing their insertion point.

@MainActor
final class HotkeyFlyoutPanel {

    static let shared = HotkeyFlyoutPanel()

    private var panel: NSPanel?
    /// The control the open panel belongs to, in screen coordinates. A click
    /// inside it is the trigger toggling itself and must NOT be read as a click
    /// outside the flyout — the panel would dismiss on mouse-down and the
    /// button's action would present it again on mouse-up, which is a flyout
    /// that cannot be closed by the control that opened it.
    private var anchor: NSRect = .zero
    private var recorder: HotkeyRecorder?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onChange: ((Hotkey?) -> Void)?

    private init() {}

    var isOpen: Bool { panel != nil }

    // MARK: Opening

    /// Show the flyout under `anchor`, which is in **screen** coordinates with
    /// the origin at the bottom left — the space `NSWindow.convertToScreen`
    /// hands back and the space `NSPanel.setFrameOrigin` expects.
    func present(
        anchor: NSRect,
        on parent: NSWindow?,
        hotkey: Hotkey?,
        onChange: @escaping (Hotkey?) -> Void
    ) {
        dismiss()
        self.onChange = onChange
        self.anchor = anchor

        let recorder = HotkeyRecorder(hotkey: hotkey)
        recorder.onCommit = { [weak self] in self?.onChange?($0) }
        recorder.onDismiss = { [weak self] in self?.dismiss() }
        self.recorder = recorder

        let placement = Self.place(anchor: anchor, on: parent?.screen ?? NSScreen.main)
        let panel = NSPanel(
            contentRect: placement.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // **Dark whatever the theme.** Its keycaps, dividers and lift are values
        // measured against a dark reference; a light room has no measured
        // counterpart, and a guessed one would be the one surface here that is
        // neither the reference nor the app.
        panel.appearance = NSAppearance(named: .darkAqua)
        // The shadow is drawn by the view, inside the panel's own bounds — see
        // `HotkeyMetrics.shadowMargin`. A window shadow as well would be two.
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(
            rootView: HotkeyFlyout(recorder: recorder, tailEdge: placement.tailEdge)
                .resolvesMotion()
        )
        // A child of the settings window: it travels with it, sorts above it and
        // goes away with it, none of which is true of a free-floating panel.
        parent?.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        self.panel = panel

        recorder.begin()
        installDismissal(parent: parent)
    }

    // MARK: Dismissal

    func dismiss() {
        recorder?.end()
        recorder = nil
        onChange = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        anchor = .zero
    }

    /// Everything that closes the flyout but a key press.
    ///
    /// The local monitor watches mouse-down **outside** the panel; the global
    /// one covers clicks in another application, which never reach this process
    /// as a local event. Both are removed in `dismiss()`, and the window
    /// notifications with them — an observer left on a window that outlives this
    /// panel is a callback into a torn-down recorder.
    private func installDismissal(parent: NSWindow?) {
        let outside: (NSEvent) -> Bool = { [weak self] event in
            guard let self, let panel = self.panel else { return false }
            // Screen coordinates, not the event's window: a click in another
            // application arrives with no window at all.
            if self.anchor.contains(NSEvent.mouseLocation) { return false }
            guard let eventWindow = event.window else { return true }
            return eventWindow != panel
        }
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] event in
                if outside(event) { self?.dismiss() }
                return event
            } as Any
        )
        monitors.append(
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] _ in self?.dismiss()
            } as Any
        )
        guard let parent else { return }
        for name in [NSWindow.willCloseNotification, NSWindow.willMoveNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: parent, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { HotkeyFlyoutPanel.shared.dismiss() }
                }
            )
        }
    }

    // MARK: Placement

    struct Placement {
        var frame: NSRect
        var tailEdge: VerticalEdge
    }

    /// Where the panel goes, given the control it belongs to.
    ///
    /// Centred on the control horizontally, and its edge `anchorGap` from the
    /// control's — a gap the tail exactly covers, which is why it is measured
    /// rather than chosen.
    ///
    /// **Below by preference, above when there is no room.** The reference
    /// prefers *above* and falls back to below, which was checked rather than
    /// assumed and is the wrong way round for a settings row: a flyout that
    /// jumps over the row the moment the window moves down the screen reads as a
    /// bug. Below is where every screenshot of it shows it, and it is what a
    /// popover does everywhere else in this app.
    nonisolated static func place(anchor: NSRect, on screen: NSScreen?) -> Placement {
        let size = NSSize(width: HotkeyMetrics.panelWidth, height: HotkeyMetrics.panelHeight)
        let gap = HotkeyMetrics.anchorGap
        // AppKit's screen space has y increasing upward, so "below the control"
        // is a smaller y.
        var origin = NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.minY - gap - size.height
        )
        var edge = VerticalEdge.top

        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY {
                let above = anchor.maxY + gap
                if above + size.height <= visible.maxY {
                    origin.y = above
                    edge = .bottom
                } else {
                    origin.y = visible.minY
                }
            }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        }
        return Placement(frame: NSRect(origin: origin, size: size), tailEdge: edge)
    }
}
