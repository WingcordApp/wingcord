import AppKit
import SwiftUI

/// Where a SwiftUI view inside a nested hosting view sits in its window's root
/// hosting view — what the root's presenters anchor popovers to. A hosted card
/// lives in its own `NSHostingView` over the transcript, so its `.global` space
/// is its own, not the window's.
final class WindowAnchorBox {
    weak var view: NSView?

    /// The view's bounds in the window's content view, top-left origin.
    func rectInWindowRoot() -> CGRect {
        guard let view, let root = view.window?.contentView else { return .zero }
        let inRoot = view.convert(view.bounds, to: root)
        guard !root.isFlipped else { return inRoot }
        return CGRect(x: inRoot.minX, y: root.bounds.height - inRoot.maxY, width: inRoot.width, height: inRoot.height)
    }
}

/// Records the view it's laid over into a `WindowAnchorBox`.
struct WindowAnchorProbe: NSViewRepresentable {
    let box: WindowAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        box.view = view
    }
}
