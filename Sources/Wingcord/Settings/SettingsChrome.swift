import AppKit
import SwiftUI

// MARK: - The window
//
// THE ONE WINDOW IN WINGCORD THAT IS TRANSLUCENT, and the one place the app
// configures an `NSWindow`.
//
// §1 of INVARIANTS says never to set `isOpaque = false` and that the `Window`
// scene takes no `NSWindow` configuration. Both are about the *workspace*
// window, and both are load-bearing there: the reading surface has to stay
// opaque or a transcript over a photograph is unreadable, and with no
// hand-rolled vibrancy anywhere in that window there is nothing to switch.
//
// Settings is a different object. Nothing in it is read for minutes at a time,
// every surface it draws is one this file owns, and the bleed *is* the design —
// the source list is not painted at all, it is the desktop coming through the
// window's own material. That requires the switch, so this file makes it, once,
// where it can be seen.

/// Applies the window configuration the settings surface needs, once, when its
/// host view joins a window.
///
/// A representable rather than an `NSApplication` lookup: the settings scene's
/// window does not exist until SwiftUI builds it, and a lookup by title breaks
/// the moment the window is renamed or localised.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            configure(window)
        }

        private func configure(_ window: NSWindow) {
            // Translucent, so the material below is what the desktop reaches.
            window.isOpaque = false
            window.backgroundColor = .clear
            // The chrome is drawn by the content, and the traffic lights sit over
            // the source list rather than in a bar of their own.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.contentMinSize = NSSize(
                width: SettingsMetrics.minWidth,
                height: SettingsMetrics.minHeight
            )
            // A settings window is not a document: it has nothing to restore per
            // tab and nothing to merge with.
            window.tabbingMode = .disallowed
        }
    }
}

extension View {
    /// The settings window's chrome: transparent titlebar, non-opaque window,
    /// and the material every surface in the pane is defined against.
    func settingsWindowChrome() -> some View {
        background(SettingsGround())
            .background(SettingsWindowConfigurator().frame(width: 0, height: 0))
    }
}

// MARK: - The ground

/// The material the whole settings window is made of.
///
/// One surface, edge to edge, behind both columns — which is why the source list
/// and the ten points of margin around the detail pane read as the same
/// substance. The pane is this *minus light* (`SettingsSurface.paneScrim`), not a
/// second material; stacking a second one is what §4 forbids and is also what
/// makes a pane read as a flat slab instead of as a darker region of one sheet.
private struct SettingsGround: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            // No glass and no scrim. The system already substitutes an opaque
            // material for `.glassEffect` here, and the 26% below would then be
            // darkening a solid rather than tuning a transmission — so both come
            // off together, and the window states its own colour.
            Rectangle().fill(SettingsSurface.opaqueGround).ignoresSafeArea()
        } else {
            translucent
        }
    }

    private var translucent: some View {
        Rectangle()
            .fill(.clear)
            .glassEffect(.regular, in: .rect)
            // The material alone transmits a quarter more light than the window
            // is meant to. Measured, not guessed: captured over black, grey,
            // white, red and blue, the material's response is the right SHAPE —
            // the ratio to the target is 0.74 on all five, to within a least
            // significant bit — and wrong only in scale. A single multiply fixes
            // scale, and that is what a black overlay is.
            //
            // It goes here, inside the ground, so every fill defined against the
            // ground composites over the darkened value rather than being
            // darkened itself.
            .overlay(Color.black.opacity(0.26))
            .ignoresSafeArea()
    }
}

// MARK: - Shapes

extension Shape where Self == RoundedRectangle {
    /// Every rounded rect in this window is continuous. The reference's corners
    /// were matched against rendered candidates rather than guessed, and circular
    /// corners at these radii are visibly tighter at the shoulder.
    static func settingsRect(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
