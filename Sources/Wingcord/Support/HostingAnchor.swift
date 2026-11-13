import AppKit
import CoreGraphics
import WingcordCore

/// Where SwiftUI's root view starts, inside the window's hosting view.
///
/// **Measured, because it is not zero and nothing else in the app can say what
/// it is.** A window with a toolbar lays its SwiftUI root out *below* the
/// titlebar strip while the hosting view spans the whole content area — measured
/// on a live window, root at `(0, 52)` in a hosting view whose bounds are
/// `(0, 0, 1512, 872)`. An anchor converted into the hosting view is therefore
/// exactly one titlebar too low, which is what put every profile card a row
/// below the person clicked and every emoji card half a message down.
///
/// Three attempts guessed at this before it was read off a running window. It is
/// published rather than assumed so it cannot go stale: a different toolbar
/// height, a titlebar accessory, or no toolbar at all changes the number, and
/// none of those would change a constant.
@MainActor
enum PresentationOrigin {
    /// The SwiftUI root's origin, in its own global space.
    private(set) static var value: CGPoint = .zero

    /// Called by the window root as its geometry changes.
    static func record(_ origin: CGPoint) {
        // A write of an equal value would publish nothing, but this is called
        // from a layout observer and the guard keeps it honest.
        guard origin != value else { return }
        value = origin
        Log.debug(.ui, .raw(String(format: "anchor: swiftui root origin=(%.1f,%.1f)", origin.x, origin.y)))
    }
}

/// Turns a rect in a drawn canvas's own space into the rect a SwiftUI
/// `.popover` will anchor to.
///
/// **The space is the outermost hosting view's, not the window's**, and three
/// plausible answers are wrong before this one. Window coordinates are
/// bottom-left, so handing them to SwiftUI mirrors the anchor vertically.
/// Subtracting from the content view's height double-flips it, because a
/// SwiftUI window's content view *is* an `NSHostingView` and is therefore
/// already flipped. And converting into the content view still answers in the
/// wrong space whenever the hosting view does not start at its origin — which is
/// what left a card opening a row or two below the person clicked.
///
/// Converting into the hosting view removes the whole class of error: it is the
/// exact view the presentation modifier is attached within, so its coordinates
/// are the ones the attachment anchor is interpreted in, whatever AppKit has
/// done with the window around it.
///
/// One definition, shared by both canvases. Two copies of this arithmetic is two
/// places for the flip to be forgotten, and the failure is a card that opens
/// somewhere plausible but wrong.
extension NSView {
    /// - Parameter insidePopover: the view is inside a popover, whose SwiftUI
    ///   root starts at its hosting view's own origin — there is no titlebar
    ///   strip above it, and `PresentationOrigin` is the main window's.
    func anchorInHostingRoot(_ rect: CGRect, insidePopover: Bool = false) -> CGRect {
        guard let host = Self.hostingAncestor(of: self) ?? window?.contentView else {
            return convert(rect, to: nil)
        }
        let inHost = convert(rect, to: host)
        let flipped = host.isFlipped
            ? inHost
            : CGRect(
                x: inHost.minX,
                y: host.bounds.height - inHost.maxY,
                width: inHost.width,
                height: inHost.height
            )
        // **And finally into the SwiftUI ROOT's space, which is not the hosting
        // view's.** The root is laid out below the titlebar strip while the
        // hosting view spans the whole content area, so a rect that stops here
        // is one titlebar too low. See `PresentationOrigin`.
        let origin = insidePopover ? .zero : PresentationOrigin.value
        let result = flipped.offsetBy(dx: -origin.x, dy: -origin.y)
        Self.traceAnchor(rect, in: self, host: host, result: result)
        return result
    }

    /// One line naming every space involved, so the next disagreement is read
    /// rather than guessed at. Off by default and free when off.
    private static func traceAnchor(
        _ rect: CGRect,
        in view: NSView,
        host: NSView,
        result: CGRect
    ) {
        guard Log.isDetailed else { return }
        let window = view.window
        let content = window?.contentView
        let strip = (content?.bounds.height ?? 0) - (window?.contentLayoutRect.height ?? 0)
        var line = "source=" + brief(rect)
        line += " view=" + String(describing: type(of: view))
        line += " host=" + String(describing: type(of: host))
        line += " hostFlipped=" + String(host.isFlipped)
        line += " hostBounds=" + brief(host.bounds)
        line += " hostInWindow=" + brief(host.convert(host.bounds, to: nil))
        line += " contentBounds=" + brief(content?.bounds ?? .zero)
        line += " layoutRect=" + brief(window?.contentLayoutRect ?? .zero)
        line += " strip=" + String(format: "%.1f", strip)
        line += " result=" + brief(result)
        Log.debug(.ui, .raw("anchor: " + line))
    }

    private static func brief(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    /// The outermost SwiftUI hosting view above `view`.
    ///
    /// Walked to the TOP of the chain rather than stopping at the first match:
    /// SwiftUI nests hosting views for representables, and the innermost one is
    /// the canvas's own container, whose origin is the scroll view's — not the
    /// window root's.
    private static func hostingAncestor(of view: NSView) -> NSView? {
        var found: NSView?
        var candidate: NSView? = view.superview
        while let current = candidate {
            if String(describing: type(of: current)).contains("Hosting") { found = current }
            candidate = current.superview
        }
        return found
    }
}


// MARK: - The same conversion, for a SwiftUI view

import SwiftUI

extension View {
    /// Reports this view's frame in the SwiftUI root's own space — the space
    /// `ProfileRequest.anchor` and every other window-root presenter is
    /// interpreted in.
    ///
    /// **`.global` minus the root's own origin.** A SwiftUI view has no AppKit
    /// view to convert through, so `anchorInHostingRoot` does not apply; what
    /// does apply is the same correction it ends with, because `.global` is the
    /// window's space and the root is laid out below the titlebar strip.
    ///
    /// `onGeometryChange` rather than a `GeometryReader`: it reads the value the
    /// layout already computed and fires only when it changes, where a reader is
    /// an extra container and an extra pass.
    func reportsPresentationAnchor(_ action: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            let origin = PresentationOrigin.value
            action(frame.offsetBy(dx: -origin.x, dy: -origin.y))
        }
    }
}
