import AppKit
import WebKit
import WingcordCore

/// The one live web view for the running activity, and everything that keeps
/// it running.
///
/// **The frame outlives the view that shows it, and that is the whole point.**
/// The stage is scoped to the channel the activity was launched into, so
/// reading another conversation takes it off screen — and a `WKWebView` owned
/// by that view is destroyed with it. Coming back built a *new* one, which
/// reloaded the app from nothing while the instance was still running: Watch
/// Together rejoined mid-playback and started its own player beside the one
/// already going, so the same video played twice at once.
///
/// An activity is a session, not a subview. It is created when one is launched,
/// torn down when it is left, and nothing in between may end it.
@MainActor
final class ActivityRuntime {
    let instance: ActivityInstanceID
    let container: ActivityFrameContainer
    private let bridge: ActivityBridge
    private var isStopped = false

    init(activity: RunningActivity, model: AppModel) {
        instance = activity.instance
        bridge = ActivityBridge(model: model, activity: activity)
        container = ActivityFrameContainer(
            hosting: ActivityRuntime.makeWebView(bridge: bridge)
        )
        bridge.attach(container.webView)
        container.webView.loadHTMLString(
            ActivityBridge.hostPage(framing: activity.frameURL),
            baseURL: ActivityBridge.hostOrigin
        )
    }

    /// **Idempotent, and the only thing that may end the session.** Called from
    /// Leave and from the app closing itself — never from a view going away.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        bridge.detach(container.webView)
        container.webView.removeFromSuperview()
    }

    private static func makeWebView(bridge: ActivityBridge) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(bridge, name: ActivityBridge.messageHandler)
        controller.addUserScript(WKUserScript(
            source: ActivityBridge.hostScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // **Its own data store, not the default one.** An activity is a third
        // party running inside somebody's messenger; sharing cookies and local
        // storage with the login web view would put the account's session in
        // reach of every app in the directory.
        configuration.websiteDataStore = ActivityBridge.dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = bridge
        webView.uiDelegate = bridge
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        // A frame that could be dragged by its background would let an app move
        // the window, which is the app's window and not its business.
        webView.allowsMagnification = false
        return webView
    }
}
