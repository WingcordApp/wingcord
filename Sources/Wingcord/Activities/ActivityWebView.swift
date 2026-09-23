import SwiftUI
import WebKit

/// The activity itself, framed.
///
/// **An iframe inside a local host page, not the activity as the top
/// document.** The Embedded App SDK posts to `window.parent`; loaded as the top
/// document, `window.parent === window` and the frame would be talking to
/// itself. A one-element host page gives it a real parent to talk to, and that
/// parent is this app.
///
/// **This is only possible because the origin allows it.** Checked live against
/// Watch Together, Wordle and Farm Merge Valley: `{id}.discordsays.com` sends
/// no `X-Frame-Options` and no CSP `frame-ancestors`, so it will frame
/// anywhere. If Discord ever adds one, this stops working and nothing else
/// here can fix it — see `ActivityFrame.host`.
struct ActivityWebView: NSViewRepresentable {
    var runtime: ActivityRuntime

    /// **Adopted, never created.** The web view belongs to `ActivityRuntime`
    /// and outlives every view that shows it; building one here is what made
    /// leaving the channel restart the activity.
    func makeNSView(context: Context) -> ActivityFrameContainer { runtime.container }

    func updateNSView(_ container: ActivityFrameContainer, context: Context) {}

    /// **Deliberately empty.** SwiftUI takes the container out of the hierarchy
    /// by itself, and the session must survive that — only `Leave` and the app
    /// closing itself may end it. See `ActivityRuntime.stop`.
    static func dismantleNSView(_ container: ActivityFrameContainer, coordinator: ()) {}
}

/// The web view's superview, and the end of the responder chain for a key the
/// page did not want.
///
/// **This exists to stop a beep, and the beep was not cosmetic.** When a page
/// listens for keys on `document` with no focused text field — which is how
/// every keyboard game is written, Wordle included — WebKit does not consider
/// the event consumed, so it hands it back up the responder chain.
/// `NSResponder.keyDown` forwards to `nextResponder` by default, the walk
/// reaches the window with nobody claiming it, and AppKit answers with the
/// system alert sound. Every letter typed into Wordle produced one.
///
/// Ending the walk here is the narrowest place it can be ended: the window's
/// own `noResponderFor(_:)` would silence the whole app, and silencing the whole
/// app hides the legitimate "that key does nothing" feedback everywhere else.
///
/// **Command shortcuts are unaffected.** `performKeyEquivalent(with:)` runs
/// *before* `keyDown` and walks the hierarchy downward from the window, so ⌘Q,
/// ⌘W and every menu item still work while an activity has focus. The global
/// hotkey is an event monitor and never enters this chain at all.
final class ActivityFrameContainer: NSView {
    let webView: WKWebView

    init(hosting webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Swallowed. **Deliberately not `super.keyDown(with:)`** — the default
    /// implementation is precisely the forward-to-`nextResponder` that ends in
    /// the beep. A key that reached here was offered to the page and declined
    /// by it, and while an activity is focused that key is the activity's
    /// business rather than the transcript's.
    override func keyDown(with event: NSEvent) {}

    /// The same, for the text-input path: an unhandled command selector is the
    /// other route to `noResponderFor(_:)`.
    override func doCommand(by selector: Selector) {}

    /// Clicking the frame gives it the keyboard, which is what makes a game
    /// playable without a mode to enter. The page's own focus handling takes
    /// over from there.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(webView)
        super.mouseDown(with: event)
    }
}
