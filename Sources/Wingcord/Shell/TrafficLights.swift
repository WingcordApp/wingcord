import AppKit
import SwiftUI

/// Puts the window's close, minimise and zoom buttons where the shell's header
/// rows expect them, and keeps them there.
///
/// **The buttons stay the system's** — their artwork, their hover, their
/// behaviour and their place in the accessibility tree. Only their origin moves:
/// down to `ShellMetrics.trafficLightsCenterY` and in to the panel's inset, which
/// is what puts them inside a floating sidebar the way macOS 26's own sidebars
/// carry them.
///
/// **Kept there by pinning each button** — `TrafficLightPin`, which makes
/// AppKit's own placement land on the shell's — and, behind that, by watching
/// the buttons' frames as this did before the pin: on a system where the pin
/// cannot be made, the watching is what is left.
///
/// **Watched through the close button's own frame.** AppKit lays the
/// title bar out again on a resize, on a change of key status and on leaving
/// full screen, and puts the buttons back where it thinks they go each time.
/// Answering the frame change synchronously moves them back inside the same
/// layout pass, before anything is drawn — answering a window notification
/// instead lets one frame through with the buttons in the wrong place.
struct TrafficLightsPlacement: NSViewRepresentable {
    var leading: CGFloat
    var centerY: CGFloat

    func makeNSView(context: Context) -> TrafficLightsProbe {
        TrafficLightsProbe()
    }

    func updateNSView(_ probe: TrafficLightsProbe, context: Context) {
        probe.update(leading: leading, centerY: centerY)
    }

    static func dismantleNSView(_ probe: TrafficLightsProbe, coordinator: ()) {
        probe.stopObserving()
    }
}

@MainActor
final class TrafficLightsProbe: NSView {
    private var leading: CGFloat = 20
    private var centerY: CGFloat = 16
    private var windowObservers: [NSObjectProtocol] = []
    private var buttonObservers: [NSObjectProtocol] = []
    /// The buttons the frame observers are on, checked on every placement in
    /// case AppKit has replaced them — observers left on old buttons would see
    /// nothing.
    private var observedButtons: [ObjectIdentifier] = []
    /// Set while this view is moving the buttons, so the frame changes its own
    /// moves post are not answered.
    private var isPlacing = false
    /// A placement is queued for when AppKit's current layout has returned.
    private var isPlacementQueued = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(leading: CGFloat, centerY: CGFloat) {
        guard leading != self.leading || centerY != self.centerY else { return }
        self.leading = leading
        self.centerY = centerY
        place()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        // Every moment AppKit lays the title bar out again that is not a
        // button's own frame changing: a resize, a zoom, a change of key
        // status, a move to another screen, a return from the Dock or from
        // full screen.
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didExitFullScreenNotification,
        ]
        for name in names {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeNowAndAfterLayout() }
            })
        }
        placeNowAndAfterLayout()
    }

    func stopObserving() {
        (windowObservers + buttonObservers).forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        buttonObservers.removeAll()
        observedButtons.removeAll()
    }

    private static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// Places the buttons now, and again once whatever AppKit is in the middle
    /// of has returned.
    ///
    /// **Now is not enough on its own — measured.** AppKit lays the title bar
    /// out by setting the three buttons' frames one after another (a change of
    /// the window's title is enough: opening another channel), and a button's
    /// frame-change notification arrives *inside* AppKit's own `setFrame` of
    /// it. A move made there sticks for the other two buttons and is lost for
    /// that one. The zoom button is set last, so it was left at AppKit's own
    /// place — x 55, sixteen points down — with nothing left to move it back:
    /// the green light sitting above the other two. The second pass runs after
    /// the layout, in the same turn of the run loop, before anything is drawn.
    private func placeNowAndAfterLayout() {
        place()
        guard !isPlacementQueued else { return }
        isPlacementQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPlacementQueued = false
            self.place()
        }
    }

    /// Watches the window's current three buttons' own frames.
    private func observeButtons(of window: NSWindow) {
        let buttons = Self.buttonTypes.compactMap { window.standardWindowButton($0) }
        let identities = buttons.map(ObjectIdentifier.init)
        guard identities != observedButtons else { return }
        buttonObservers.forEach(NotificationCenter.default.removeObserver)
        buttonObservers = buttons.map { button in
            button.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Our own moves post this too; only AppKit's are answered.
                    guard let self, !self.isPlacing else { return }
                    self.placeNowAndAfterLayout()
                }
            }
        }
        observedButtons = identities
    }

    private func place() {
        guard !isPlacing, let window,
              // Full screen hides the buttons in the menu-bar reveal, where the
              // system's own placement is the right one.
              !window.styleMask.contains(.fullScreen)
        else { return }
        observeButtons(of: window)
        isPlacing = true
        defer { isPlacing = false }
        for type in Self.buttonTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            // **Pinned, so AppKit's own layout lands here too** — see
            // `TrafficLightPin`. Everything else in this file moves the buttons
            // back after AppKit has moved them, which is a frame too late when
            // the layout runs inside the commit; the pin has no "after".
            TrafficLightPin.pin(button) { [weak self] button in self?.origin(of: button) }
            guard let origin = origin(of: button) else { continue }
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    /// Where `button` belongs, in its superview's space — nil where the
    /// system's own place is the right one.
    private func origin(of button: NSButton) -> NSPoint? {
        guard let window, button.window === window, let bar = button.superview,
              !window.styleMask.contains(.fullScreen),
              let index = Self.buttonTypes.firstIndex(where: { window.standardWindowButton($0) === button })
        else { return nil }
        // Placed in the window's space (y up from its foot) and brought into
        // the button's own, so the answer holds whatever container AppKit puts
        // each button in.
        let target = NSPoint(
            x: leading + CGFloat(index) * ShellMetrics.trafficLightSpacing,
            y: window.frame.height - centerY
        )
        let inBar = bar.convert(target, from: nil)
        return NSPoint(
            x: inBar.x.rounded(),
            y: (inBar.y - button.frame.height / 2).rounded()
        )
    }
}
