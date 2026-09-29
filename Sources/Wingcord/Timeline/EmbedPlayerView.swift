import AppKit
import WebKit
import WingcordCore

/// A site's own video player over an embed's thumbnail — Discord's iframe
/// (module `259407`), started by the Play control.
///
/// **Framed by a page whose origin is discord.com**, as Discord's own is.
/// YouTube will not play in a frame with no origin, and Twitch checks its
/// `parent` against the framing page's host — see `EmbedLayoutEngine.playerURL`.
///
/// A subview of the transcript's canvas, placed in its coordinates, so it
/// scrolls with the row it belongs to; the coordinator moves it on relayout and
/// takes it away when its row is gone.
final class EmbedPlayerView: NSView {
    let messageID: MessageID
    let player: URL
    private let webView: WKWebView

    init(messageID: MessageID, player: URL) {
        self.messageID = messageID
        self.player = player
        let configuration = WKWebViewConfiguration()
        // Play pressed is the gesture; the player should not ask for another.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        webView.autoresizingMask = [.width, .height]
        webView.underPageBackgroundColor = .black
        addSubview(webView)
        webView.loadHTMLString(Self.page(for: player), baseURL: URL(string: "https://discord.com"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// Ends playback and leaves the canvas.
    func stop() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        removeFromSuperview()
    }

    /// The page the player is framed in. The URL is escaped for the attribute
    /// it sits in: it came from somebody else's message.
    static func page(for player: URL) -> String {
        let source = player.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><style>\
        html,body{margin:0;height:100%;background:#000;overflow:hidden}\
        iframe{border:0;width:100%;height:100%}\
        </style></head><body><iframe src="\(source)" \
        allow="autoplay; fullscreen; encrypted-media; picture-in-picture" allowfullscreen>\
        </iframe></body></html>
        """
    }
}
