import AppKit
import WebKit
import WingcordCore

/// The full Spotify player, raised on demand beside a card.
///
/// **The one place this app pays for a web view in a transcript, and it pays
/// only while somebody is looking at it.** Measured on this machine: a `WKWebView`
/// on Spotify's embed costs 148 MB for the first (four helper processes) and
/// about 65 MB for each one after, because every web view gets its own
/// `WebContent` process. The app's whole steady state is 86–106 MB with 220
/// messages resident, so one *inline* per Spotify link would have multiplied the
/// app several times over — and the transcript is a single viewport-sized
/// `NSView` that paints every row and has no subviews to put one in anyway.
///
/// So the card is drawn, and this is a second thing the reader asks for. Exactly
/// one exists at a time, and closing it takes the processes with it.
///
/// **A persistent store, scoped to Spotify and nothing else — and that is a
/// deliberate departure from `INVARIANTS.md` §4.75.** That rule gives a hosted
/// guest a *non*-persistent store, and it is right: an activity is an arbitrary
/// app out of Discord's directory, and sharing cookies with the sign-in web view
/// would put the account's own session in reach of every one of them. This is a
/// different proposition — one known origin, in a store of its own that shares
/// nothing with the default one or with the activities' — and persistence is the
/// entire point: it is what lets somebody sign into Spotify once and get full
/// playback, the saved tick, save and unsave, and the overflow menu, in
/// Spotify's own interface, without this client ever handling a credential.
@MainActor
final class SpotifyPlayerSession {

    /// What is being played, so the presenter can title it and place it.
    let card: SpotifyUnfurl
    /// Where the card was, in the window root's own space. The panel is anchored
    /// to it — §1, which is why a drawn canvas publishes a rect rather than
    /// hosting a presentation.
    let anchor: CGRect
    let webView: WKWebView

    /// Spotify's own sizes for an embed. A track is short; anything with a list
    /// in it is not.
    static let width: CGFloat = 456
    static func height(for kind: SpotifyUnfurl.Kind) -> CGFloat {
        switch kind {
        case .track, .episode: 152
        case .album, .playlist, .artist, .show: 352
        }
    }

    /// The store the Spotify session lives in.
    ///
    /// **Named, so it is the same store every time.** An identifier-less
    /// persistent store is the *default* one, which is where the account's
    /// Discord cookies are; a fresh non-persistent one would ask somebody to
    /// sign in again every time they opened a player. The UUID is a constant
    /// rather than generated, because a generated one is a new empty store on
    /// every launch.
    private static let store: WKWebsiteDataStore = {
        let identifier = UUID(uuidString: "5B0A9E27-6C41-4E3A-9B77-0F2E1D8C4A61")!
        return WKWebsiteDataStore(forIdentifier: identifier)
    }()

    init(card: SpotifyUnfurl, anchor: CGRect) {
        self.card = card
        self.anchor = anchor

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.store
        // A player the reader opened deliberately may start when they press its
        // own button; this is what stops WebKit demanding a second gesture.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        load(.player)
    }

    /// The two pages this panel ever shows.
    enum Page {
        /// Spotify's embed for the entity — the player itself.
        case player
        /// Spotify's own site, which is where signing in happens. **The same
        /// origin as the embed**, so a session established here is the session
        /// the player picks up the next time it loads.
        case signIn
    }

    private(set) var page: Page = .player

    func load(_ page: Page) {
        self.page = page
        let address = switch page {
        case .player:
            "https://open.spotify.com/embed/\(card.kind.rawValue)/\(card.id)?utm_source=oembed"
        case .signIn:
            "https://open.spotify.com/\(card.kind.rawValue)/\(card.id)"
        }
        guard let url = URL(string: address) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Ends the session and, with it, the processes behind it.
    ///
    /// **Explicit, because nothing else will do it.** A `WKWebView` left in a
    /// view hierarchy that goes away keeps its `WebContent` process; this is
    /// what makes the 148 MB a cost of *having a player open* rather than a cost
    /// of having opened one.
    func stop() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }
}
