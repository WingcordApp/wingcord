import SwiftUI
import WebKit
import WingcordNet

/// The human check Discord puts in front of joining a server.
///
/// **A `WKWebView` is the only way to present one.** hCaptcha is a hosted
/// challenge — image grids, an audio fallback, its own accessibility
/// affordances — not something a native control can render, and reimplementing
/// it is not a thing that exists. Hand the step to the party that implements it.
///
/// The constraint that comes with that allowance: **nothing is layered over the
/// web view.** A `WKWebView` owns a `CALayer` tree outside SwiftUI's compositor,
/// so glass placed on top of it renders as a flat slab rather than lensing what
/// is underneath — `INVARIANTS.md` §4. Every piece of chrome is a sibling, and
/// the two states that must be *clicked* — loading and failure — replace the web
/// view rather than covering it.
struct CaptchaSheet: View {
    let challenge: CaptchaChallenge
    /// `nil` when nobody answered. The request behind this is resumed either
    /// way — see `CaptchaSolver.resolve`.
    let onFinish: (CaptchaSolution?) -> Void

    @Environment(\.motion) private var motion

    private enum Phase: Equatable {
        case loading
        case challenging
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// Bumped to rebuild the web view from scratch on a retry.
    ///
    /// `hcaptcha.reset` exists and is deliberately not used: a challenge can
    /// fail because the *page* failed, and resetting a widget that never
    /// rendered does nothing. Rebuilding costs one web view on a path somebody
    /// has already had to wait through, and recovers from every failure rather
    /// than from one of them.
    @State private var attempt = 0

    private static let width: CGFloat = 420
    /// Tall enough for hCaptcha's checkbox **and** the image grid it opens into,
    /// which the widget draws in an overlay inside the same document.
    private static let stageHeight: CGFloat = 460

    /// How long the page gets to say it is ready.
    ///
    /// **The spinner has to be able to give up.** `js.hcaptcha.com` is a
    /// third-party host that may be behind a blocklist or a captive portal, and
    /// a script that never loads calls no callback at all — not `error-callback`,
    /// not `onerror`, nothing. The only thing that fails is the document load,
    /// which cannot fail here because the document is a string. Without this the
    /// sheet is a spinner with no way out but Cancel, on a join that looked like
    /// it was working.
    private static let loadTimeout: Duration = .seconds(20)

    var body: some View {
        VStack(spacing: 0) {
            header
            stage
            footer
        }
        .frame(width: Self.width)
        .task(id: attempt) {
            try? await Task.sleep(for: Self.loadTimeout)
            guard phase == .loading else { return }
            withAnimation(motion.standard) {
                phase = .failed("Couldn't reach the verification service.")
            }
        }
    }

    private var header: some View {
        ModalHeader(
            title: "Quick check",
            subtitle: Text("Discord asks a new app for this now and then, before a sign-in or a join goes through."),
            close: { onFinish(nil) }
        )
    }

    /// Whatever the challenge currently is: a wait, the page, or a failure.
    ///
    /// A `ZStack` for the first two, because the page is transparent until
    /// hCaptcha paints — so the spinner sits *behind* it and fades out on the
    /// widget's own signal, with no frame where the sheet is empty. The failure
    /// state is a real swap: it has a button, and a button underneath a web view
    /// cannot be clicked.
    @ViewBuilder
    private var stage: some View {
        ZStack {
            if case .failed(let reason) = phase {
                failure(reason)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .opacity(phase == .loading ? 1 : 0)
                    .animation(motion.standard, value: phase)

                HCaptchaWebView(
                    sitekey: challenge.sitekey,
                    rqdata: challenge.rqdata,
                    isInvisible: challenge.serveInvisible,
                    onEvent: handle
                )
                // Identity, not a `.task` — a retry has to build a new web view,
                // and a modifier cannot reload one it does not own.
                .id(attempt)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.stageHeight)
    }

    private func failure(_ reason: String) -> some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(Ink.secondary)
                // Decorative. The sentence below says the same thing, and
                // VoiceOver reading "warning triangle" first delays the part
                // that carries the information.
                .accessibilityHidden(true)
            Text(reason)
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SurfaceQuietButton(title: "Try Again", systemImage: "arrow.clockwise") {
                withAnimation(motion.standard) { phase = .loading }
                attempt += 1
            }
        }
        .padding(.horizontal, Spacing.group)
        .transition(.opacity)
    }

    /// The ✕ in the heading is the way out; the foot keeps the web page's
    /// breathing room.
    private var footer: some View {
        Color.clear.frame(height: Spacing.margin)
    }

    private func handle(_ event: HCaptchaWebView.Event) {
        switch event {
        case .ready:
            withAnimation(motion.standard) { phase = .challenging }
        case .token(let token):
            onFinish(
                CaptchaSolution(
                    key: token,
                    rqtoken: challenge.rqtoken,
                    sessionID: challenge.sessionID
                )
            )
        case .closed:
            // Dismissed from inside the page. There is nothing left on screen at
            // that point, so an explicit retry is the only way back — and
            // silently re-executing would trap somebody who meant to stop.
            withAnimation(motion.standard) {
                phase = .failed("The check was closed before it finished.")
            }
        case .failed(let reason):
            withAnimation(motion.standard) { phase = .failed(reason) }
        }
    }
}

// MARK: - The page

/// hCaptcha, hosted.
///
/// Four things make this work against Discord's sitekey, and none is obvious
/// from hCaptcha's own documentation:
///
///   * **The document is loaded with `baseURL` set to `https://discord.com`.**
///     Discord's sitekey is registered against that host and hCaptcha checks the
///     origin. Served from `about:blank` the widget renders happily and then
///     issues a token Discord will not take.
///   * **`rqdata` goes in with `hcaptcha.setData`, after the render — not
///     among the render's options**, which don't read it. Discord's own captcha
///     (`283cac4b…`, the `S` callback) calls `setData({rqdata})` the moment the
///     widget loads, and again after an error or a close. It is the enterprise
///     payload out of Discord's 400 and what binds the token to this challenge;
///     without it the token comes back well-formed and is refused, which reads
///     as a wrong answer — and it is why, until 2026-11-06, no token this app
///     made had ever been accepted (it was passed at render).
///   * **`render=explicit`.** The implicit form races the container element and
///     intermittently renders nothing at all.
///   * **The checkbox, unless Discord asks for invisible.** Discord's modal
///     (`645320`) renders `size: "invisible"` and executes at once when the 400
///     says `should_serve_invisible`, and the checkbox otherwise — the shape
///     `forza onboarding1.har`'s screenshot shows for a join. This does the same.
///   * **`recaptchacompat=off`**, as hCaptcha's React wrapper loads the script
///     for Discord (`reCaptchaCompat: false`).
private struct HCaptchaWebView: NSViewRepresentable {
    let sitekey: String
    let rqdata: String?
    let isInvisible: Bool
    let onEvent: (Event) -> Void

    enum Event: Equatable {
        /// The widget exists and is waiting for a person.
        case ready
        case token(String)
        /// Dismissed from inside the page.
        case closed
        case failed(String)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        // A **weak** proxy, not the coordinator itself. `WKUserContentController`
        // retains its handlers, the web view retains the controller and SwiftUI
        // retains the coordinator — registering directly is a cycle that keeps a
        // whole web view, and its network activity, alive after the sheet closes.
        controller.add(WeakMessageHandler(context.coordinator), name: Coordinator.messageName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // Non-persistent: a check solved under one account must not leave state
        // behind for the next, and there is nothing here worth keeping on disk.
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Transparent, so the sheet's own surface is what the challenge sits on.
        // Without this the default white background flashes over a dark sheet
        // for a frame and then stays there as a slab.
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(page, baseURL: URL(string: "https://discord.com"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Explicit teardown. Without it the page keeps running after the sheet is
        // gone — hCaptcha polls while a challenge is open — and the handler
        // registration outlives the view that needed it.
        coordinator.isFinished = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Coordinator.messageName)
    }

    private var page: String {
        HCaptchaPage.html(sitekey: sitekey, rqdata: rqdata, isInvisible: isInvisible, messageName: Coordinator.messageName)
    }

    /// Forwards script messages without retaining the coordinator.
    private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: (any WKScriptMessageHandler)?

        init(_ target: any WKScriptMessageHandler) { self.target = target }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            target?.userContentController(controller, didReceive: message)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let messageName = "wingcordCaptcha"

        var onEvent: (Event) -> Void
        /// A one-way latch. hCaptcha can report an expiry *after* a token, and
        /// the sheet is already gone by then — the late event would turn a
        /// solved challenge into a failure on a view nobody is looking at.
        var isFinished = false

        init(onEvent: @escaping (Event) -> Void) { self.onEvent = onEvent }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard !isFinished, message.name == Self.messageName,
                  let payload = message.body as? [String: Any],
                  let kind = payload["kind"] as? String
            else { return }
            let value = payload["value"] as? String ?? ""

            switch kind {
            case "ready":
                onEvent(.ready)
            case "token":
                let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { return }
                isFinished = true
                onEvent(.token(token))
            case "closed":
                onEvent(.closed)
            default:
                onEvent(.failed(Self.explain(value)))
            }
        }

        /// hCaptcha reports failures as machine codes — `invalid-data`,
        /// `network-error`, `rate-limited`. Those are for a log, not for
        /// somebody who was trying to join a server: `invalid-data` under a
        /// warning triangle names no cause and suggests no action.
        ///
        /// The codes that mean something different to a person are translated;
        /// everything else becomes one honest sentence. The raw code is dropped
        /// rather than appended, because a sentence with a slug after it reads
        /// as a bug report either way.
        static func explain(_ code: String) -> String {
            switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "": "The check couldn't be completed."
            case "network-error", "network_error":
                "The check couldn't reach its server. Check your connection."
            case "rate-limited", "rate_limited":
                "Too many attempts. Wait a moment and try again."
            case "invalid-data", "invalid_data", "invalid-request", "sitekey-secret-mismatch":
                "Discord's verification rejected this app's request."
            case let expired where expired.contains("expire"):
                "The check expired. Try again."
            default: "The check couldn't be completed."
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            guard !isFinished, (error as NSError).code != NSURLErrorCancelled else { return }
            onEvent(.failed(error.localizedDescription))
        }
    }
}

extension String {
    /// This string as a JavaScript literal.
    ///
    /// Through `JSONSerialization` rather than by hand: a sitekey is a UUID and
    /// `rqdata` is base64 with `+` and `/` in it, and the day one of them
    /// contains a quote is the day a hand-rolled escape becomes a syntax error
    /// in a page that then reports nothing at all.
    var jsQuoted: String {
        guard let data = try? JSONSerialization.data(withJSONObject: [self]),
              let text = String(data: data, encoding: .utf8),
              text.count > 2
        else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}

/// The page `HCaptchaWebView` loads: hCaptcha, rendered and bound the way
/// Discord's own client does it (see the notes on `HCaptchaWebView`). Its own
/// type so a test can hold it to that.
enum HCaptchaPage {
    static func html(sitekey: String, rqdata: String?, isInvisible: Bool, messageName: String) -> String {
        let rqdataValue = rqdata.map(\.jsQuoted) ?? "null"
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://js.hcaptcha.com/1/api.js?render=explicit&onload=onHCaptchaLoad&recaptchacompat=off" async defer></script>
        <style>
          html, body { margin: 0; height: 100%; background: transparent; }
          #box { display: flex; align-items: flex-start; justify-content: center; padding-top: 8px; }
        </style></head>
        <body><div id="box"></div>
        <script>
          function post(kind, value) {
            try {
              window.webkit.messageHandlers.\(messageName)
                .postMessage({ kind: kind, value: value || '' });
            } catch (e) {}
          }
          var widget = null;
          var rqdata = \(rqdataValue);
          var invisible = \(isInvisible ? "true" : "false");
          // Discord's own order (283cac4b…, its `S`): the widget, then its
          // rqdata through setData, then — invisible only — execute.
          function bind() {
            if (widget === null) { return; }
            if (rqdata) { hcaptcha.setData(widget, { rqdata: rqdata }); }
          }
          function onHCaptchaLoad() {
            try {
              widget = hcaptcha.render('box', {
                sitekey: \(sitekey.jsQuoted),
                theme: 'dark',
                size: invisible ? 'invisible' : 'normal',
                callback: function (token) { post('token', token); },
                'error-callback': function (e) { bind(); post('error', String(e)); },
                'expired-callback': function () { post('error', 'expired'); },
                'chalexpired-callback': function () { post('error', 'expired'); },
                'close-callback': function () { bind(); post('closed'); },
                'open-callback': function () { post('ready'); }
              });
              bind();
              // Invisible keeps the spinner until hCaptcha opens a challenge —
              // or passes straight to a token — as Discord's modal does.
              if (invisible) { hcaptcha.execute(widget); } else { post('ready'); }
            } catch (e) { post('error', String(e)); }
          }
          window.onerror = function (m) { post('error', String(m)); };
        </script></body></html>
        """
    }
}
