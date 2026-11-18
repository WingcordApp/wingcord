import AppKit
import SwiftUI

/// A press on the composer's words, which its glass cannot hear for itself.
///
/// **Interactive glass answers presses SwiftUI receives**, and a click on the
/// text lands in the `NSTextView` instead — so the plate bulged and stretched
/// when pressed on its rim and sat still under a press on its words, which is
/// most of it (Alex, 2026-11-18: "im clicking and it doesnt bulge"). There is
/// no handing one click to both: the text view runs its own tracking loop.
///
/// So the press is **watched, never taken**: `ComposerPressProbe` sees it go by
/// on its way to the text view, and the plate answers the way the glass does —
/// a light under the pointer and a small spring bulge, then following the
/// pointer while held, with resistance, and springing home on release. The
/// caret, selection, double-click and the menu are the text view's as before.
@MainActor
@Observable
final class ComposerPress {
    /// A press that began on the words is held.
    var isPressed = false
    /// Where the pointer is, in the plate's own space (top-left origin).
    var location: CGPoint = .zero
    /// How far it has moved since the press began, in points (down is +).
    var translation: CGSize = .zero
    /// The plate's size, for a bulge in points rather than a percentage.
    var plateSize: CGSize = .zero
}

/// Behind the plate: where it is in its window, and the presses on its words.
///
/// **It takes nothing**: its view answers no hit test, and its monitor hands
/// every event on unchanged.
struct ComposerPressProbe: NSViewRepresentable {
    var press: ComposerPress

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.press = press
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.press = press
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.stopWatching()
    }

    final class ProbeView: NSView {
        weak var press: ComposerPress?
        private var monitor: Any?
        /// Where the press began, in window space, while one is held.
        private var origin: CGPoint?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopWatching() } else { startWatching() }
        }

        override func layout() {
            super.layout()
            if press?.plateSize != bounds.size { press?.plateSize = bounds.size }
        }

        func startWatching() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            origin = nil
            press?.isPressed = false
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, let press else { return }
            let point = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                // Only on the words: on the rim the glass hears it itself.
                guard bounds.contains(point), isOnText(event, in: window) else { return }
                origin = event.locationInWindow
                press.location = point
                press.translation = .zero
                press.isPressed = true
            case .leftMouseDragged:
                guard let origin else { return }
                press.location = point
                press.translation = CGSize(
                    width: event.locationInWindow.x - origin.x,
                    height: origin.y - event.locationInWindow.y
                )
            case .leftMouseUp:
                guard origin != nil else { return }
                origin = nil
                press.isPressed = false
                press.translation = .zero
            default:
                break
            }
        }

        /// Whether the click lands in a text view inside this plate.
        private func isOnText(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard let root = window.contentView?.superview ?? window.contentView,
                  var view = root.hitTest(event.locationInWindow)
            else { return false }
            while true {
                if view is NSTextView { return true }
                guard let parent = view.superview else { return false }
                view = parent
            }
        }
    }
}

/// The light under a held press, on the material and under the words.
///
/// **Applied before the glass, as a background**, so it lands on the plate's
/// material the way the glass's own light does — and so a
/// `GlassEffectContainer`, which renders glass itself and lifts it above
/// ordinary siblings, cannot bury it under the plate.
///
/// **Faint and small** (Alex, 2026-11-18: "wayyy too much of the
/// highlighting"): 6 % white at its heart, gone within a bar's height or so.
struct ComposerPressLight: View {
    var press: ComposerPress
    var cornerRadius: CGFloat

    @Environment(\.motion) private var motion

    var body: some View {
        let size = press.plateSize
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                RadialGradient(
                    colors: [Color.white.opacity(0.06), Color.white.opacity(0)],
                    center: UnitPoint(
                        x: size.width > 0 ? press.location.x / size.width : 0.5,
                        y: size.height > 0 ? press.location.y / size.height : 0.5
                    ),
                    startRadius: 0,
                    endRadius: max(size.height * 1.5, 80)
                )
            )
            .opacity(press.isPressed ? 1 : 0)
            .allowsHitTesting(false)
            .animation(motion.reduceMotion ? nil : .easeOut(duration: 0.18), value: press.isPressed)
    }
}

/// The plate's answer to a held press: the glass's own gestures, in points.
///
/// **Small** (Alex, 2026-11-18: "wayyy too much of the ... drag effect"): the
/// native glass barely moves a surface this size, so a point of swell and four
/// of travel at most.
struct ComposerPressResponse: ViewModifier {
    var press: ComposerPress
    var cornerRadius: CGFloat

    @Environment(\.motion) private var motion

    /// How far the plate grows under a press, each way. Points, not a scale:
    /// a percentage of a bar this wide would be a lurch.
    private static let bulge: CGFloat = 1
    /// The most it follows the pointer, however far that goes.
    private static let reach: CGFloat = 4

    func body(content: Content) -> some View {
        let size = press.plateSize
        let pressed = press.isPressed
        content
            .scaleEffect(
                x: pressed && !motion.reduceMotion && size.width > 0 ? 1 + Self.bulge * 2 / size.width : 1,
                y: pressed && !motion.reduceMotion && size.height > 0 ? 1 + Self.bulge * 2 / size.height : 1
            )
            .offset(motion.reduceMotion ? .zero : Self.follow(press.translation))
            // A bulge that springs, and a follow that tracks: the spring the
            // glass uses for a press, a quicker one for the pointer.
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: pressed)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.86), value: press.translation)
    }

    /// The pointer's travel with resistance: close to it at first, never past
    /// `reach` — the rubber band of something held, not dragged away.
    static func follow(_ translation: CGSize) -> CGSize {
        func resist(_ value: CGFloat) -> CGFloat {
            let magnitude = reach * (1 - exp(-abs(value) / (reach * 3)))
            return value < 0 ? -magnitude : magnitude
        }
        return CGSize(width: resist(translation.width), height: resist(translation.height))
    }
}
