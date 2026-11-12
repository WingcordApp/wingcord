import AppKit
import SwiftUI

/// A right-click on a composed row, reported as a rect in the SwiftUI root's
/// own space.
///
/// # Why this is AppKit, and why it is not a `.contextMenu`
///
/// SwiftUI on macOS offers no secondary-click gesture. The only thing it has is
/// `.contextMenu`, and `INVARIANTS.md` §2 forbids that on a list row: the
/// menu's *content closure* is evaluated as part of every row's body, in a list
/// that can hold a hundred of them, and what this app raises is its own glass
/// flyout rather than an `NSMenu` anyway.
///
/// **This builds no menu.** It is one empty layer-less `NSView` per row that
/// reports a point, which is a cost of a different order — and it is the same
/// arrangement the two drawn canvases already have, where `rightMouseDown` on
/// the canvas writes a request and stops.
///
/// # It is invisible to every other event
///
/// An overlay that took hits would swallow the row's own click. `hitTest`
/// therefore answers **only while the event being routed is a secondary
/// click** — a right button, or a control-click, which AppKit delivers as a
/// left button with `.control` set and every Mac user expects to work. For
/// everything else it returns nil and the row underneath never knows it is
/// there.
///
/// # The rect is the ROW's, not the pointer's
///
/// A flyout hung off a two-point rect under the cursor has nothing to point at
/// and lands wherever the presentation engine likes. The whole row is the
/// anchor, so the surface sits beside the conversation it is about — the same
/// thing `MemberListCanvas` passes for a roster row. `anchorInHostingRoot`
/// converts it, and it is the one place that arithmetic lives.
struct SecondaryClickCatcher: NSViewRepresentable {
    /// Called with the row's own frame, already in the root's coordinate space.
    var onClick: (CGRect) -> Void
    /// The row is inside a popover, whose root is its own — see
    /// `anchorInHostingRoot(_:insidePopover:)`.
    var isInPopover = false

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        view.isInPopover = isInPopover
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        // Refreshed rather than captured once: the closure closes over the
        // current generation's state, and a stale one reports into a dead row.
        nsView.onClick = onClick
        nsView.isInPopover = isInPopover
    }

    /// Open to one subclass: a sidebar row's catcher also answers for the
    /// row's hover — see `SidebarRowAgentView`.
    class CatcherView: NSView {
        var onClick: (CGRect) -> Void = { _ in }
        var isInPopover = false

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard Self.isSecondary(NSApp.currentEvent) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            report()
        }

        /// Control-click. AppKit routes it as a left button with `.control`
        /// set, so it never reaches `rightMouseDown` and has to be caught here.
        override func mouseDown(with event: NSEvent) {
            guard Self.isSecondary(event) else {
                super.mouseDown(with: event)
                return
            }
            report()
        }

        private func report() {
            onClick(anchorInHostingRoot(bounds, insidePopover: isInPopover))
        }

        private static func isSecondary(_ event: NSEvent?) -> Bool {
            guard let event else { return false }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return true
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                return event.modifierFlags.contains(.control)
            default:
                return false
            }
        }
    }
}

extension View {
    /// Reports a secondary click on this view, with its own frame as the
    /// anchor. See `SecondaryClickCatcher` for why this is not a
    /// `.contextMenu`.
    ///
    /// - Parameter inPopover: the view is inside a popover, and the rect is
    ///   for a presenter at that popover's root rather than the window's.
    func onSecondaryClick(inPopover: Bool = false, perform action: @escaping (CGRect) -> Void) -> some View {
        overlay { SecondaryClickCatcher(onClick: action, isInPopover: inPopover) }
    }
}
