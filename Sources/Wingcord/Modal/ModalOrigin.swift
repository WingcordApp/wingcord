import AppKit
import SwiftUI

/// Where the last press in a window landed — the point a card that opens next
/// grows out of, and shrinks back into (D11c).
///
/// **A press, not a control's frame.** The sites that open cards set a value
/// in the store, a long way from the button that was clicked, and a menu item
/// has no frame to hand over at all. What every one of them has is the click
/// that started it: the button, the row a menu was raised on, the item in one
/// of this app's glass menus. A card that opens within a moment of a press in
/// its own window grows from there; one opened by a key, from a menu bar item
/// or by the network has no origin and condenses in place instead.
@MainActor
final class ModalOrigins {
    static let shared = ModalOrigins()

    /// How long a press stays the origin. Long enough for a menu to be read
    /// and an item chosen; short enough that a card a reply opened later does
    /// not fly out of a button pressed for something else.
    static let freshness: TimeInterval = 4

    private struct Press {
        weak var window: NSWindow?
        /// On the screen, so a press in a popover — a window of its own, over
        /// this one — still says where on this window it happened.
        var point: CGPoint
        var time: TimeInterval
    }

    private var monitor: Any?
    private var last: Press?

    /// Starts listening. Once, for the app; idempotent.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated { ModalOrigins.shared.note(event) }
            return event
        }
    }

    private func note(_ event: NSEvent) {
        guard event.type != .keyDown else {
            // A key opened whatever opens next — Return on a form, ⌘N.
            last = nil
            return
        }
        guard let window = event.window else { return }
        last = Press(window: window, point: window.convertPoint(toScreen: event.locationInWindow), time: event.timestamp)
    }

    /// The origin for a card opening now in `window`, if a press there — or
    /// in a popover or menu hung off it — is still fresh. In the window's
    /// content view, from its top-left corner: SwiftUI's global space at the
    /// window's root.
    func origin(in window: NSWindow?) -> CGPoint? {
        guard let last, let window, let pressed = last.window, let view = window.contentView,
              ProcessInfo.processInfo.systemUptime - last.time < Self.freshness,
              Self.isWithin(pressed, window)
        else { return nil }
        var point = view.convert(window.convertPoint(fromScreen: last.point), from: nil)
        if !view.isFlipped { point.y = view.bounds.height - point.y }
        return point
    }

    /// The window itself, or one hung off it — a popover's, a child panel's.
    private static func isWithin(_ candidate: NSWindow, _ window: NSWindow) -> Bool {
        var current: NSWindow? = candidate
        while let next = current {
            if next === window { return true }
            current = next.parent
        }
        return false
    }
}

/// The window a view is in, for whoever asks later. A box rather than state,
/// because nothing is drawn from it — it is read when a card opens.
final class ModalWindowBox {
    weak var window: NSWindow?
}

/// Fills a `ModalWindowBox` from where it is placed.
struct ModalWindowReader: NSViewRepresentable {
    var box: ModalWindowBox

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.box = box
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.box = box
        box.window = nsView.window
    }

    final class Probe: NSView {
        var box: ModalWindowBox?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
