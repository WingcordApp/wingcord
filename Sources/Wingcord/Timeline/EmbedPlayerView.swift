import AppKit
import WebKit
import WingcordCore

/// A video over an embed's thumbnail, started by the Play control: a site's
/// own player in Discord's iframe (module `259407`), or a video file in a
/// `<video>` with the browser engine's own controls, as Discord plays Blip's.
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
    let video: EmbedVideo
    private let webView: WKWebView

    init(messageID: MessageID, video: EmbedVideo) {
        self.messageID = messageID
        self.video = video
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
        // **Sized by its mask, never by `layout()`.** Fullscreen takes the web
        // view out of this one and into WebKit's own window, leaving a
        // placeholder here; a `layout()` that set its frame to these bounds ran
        // on the next pass and shrank the fullscreen player back to the embed's
        // box, in the corner of a black screen. Coming back, WebKit returns it
        // with the placeholder's frame, which the same mask kept current.
        webView.autoresizingMask = [.width, .height]
        webView.underPageBackgroundColor = .black
        addSubview(webView)
        webView.loadHTMLString(Self.page(for: video), baseURL: URL(string: "https://discord.com"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Ends playback and leaves the canvas.
    func stop() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        removeFromSuperview()
    }

    /// The page the video plays in. The URL is escaped for the attribute it
    /// sits in: it came from somebody else's message.
    static func page(for video: EmbedVideo) -> String {
        let element: String
        switch video {
        case .player(let player):
            element = """
            <iframe src="\(escaped(player))" \
            allow="autoplay; fullscreen; encrypted-media; picture-in-picture" allowfullscreen></iframe>
            """
        case .file(let file), .loop(let file):
            element = """
            <video src="\(escaped(file))" controls autoplay playsinline></video>
            """
        }
        return """
        <!doctype html><html><head><style>\
        html,body{margin:0;height:100%;background:#000;overflow:hidden}\
        iframe{border:0;width:100%;height:100%}\
        video{display:block;width:100%;height:100%;object-fit:contain}\
        </style></head><body>\(element)</body></html>
        """
    }

    private static func escaped(_ url: URL) -> String {
        url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
