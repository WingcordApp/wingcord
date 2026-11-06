import OSLog
import SwiftUI
import WebKit
import WingcordCore

/// Discord's own sign-in page, hosted: **the way out, no longer the way in.**
///
/// Wingcord signs in with its own screen now (`SignInScreen`,
/// docs/LOGIN-ONBOARDING.md D1), sending the password to Discord over TLS as
/// Discord's own client does and keeping only the token. This page stays
/// behind "Having trouble?" for whatever that screen can't do yet — Discord
/// changing a step under it, or a check it hasn't met.
///
/// It never sees a password either: the credentials go from the web view to
/// Discord, and what comes back out is a session token. The token is read once
/// and the web view's data is discarded — the login session is a means to a
/// credential, not something worth keeping.
struct DiscordLoginView: View {
    var onToken: (String) -> Void

    @State private var page: WebPage
    @State private var isPolling = true
    @State private var didFail = false
    @State private var hasPainted = false

    init(onToken: @escaping (String) -> Void) {
        self.onToken = onToken
        var configuration = WebPage.Configuration()
        // A non-persistent store: nothing about this sign-in outlives the
        // window. Cookies exist for the length of the flow, which is all the
        // flow needs, and there is no browser profile left behind on disk for
        // anything else to read.
        configuration.websiteDataStore = .nonPersistent()
        _page = State(initialValue: WebPage(configuration: configuration))
    }

    var body: some View {
        // A web view paints its own white ground before the page it is loading
        // has anything to draw, and on a dark sheet that is a full-window white
        // flash. The ground underneath is painted first and the web view is
        // faded in once the page reports it has content, so the sheet opens dark
        // and stays dark.
        ZStack {
            Palette.canvas

            WebView(page)
                .opacity(hasPainted ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: hasPainted)

            if !hasPainted {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(minWidth: 520, minHeight: 640)
        .background(Palette.canvas)
            .task {
                page.load(URLRequest(url: DiscordLoginView.loginURL))
                await pollForToken()
            }
            .onChange(of: page.isLoading) { _, isLoading in
                // The first time loading STOPS, the page has painted. Fading in
                // on the first navigation instead would show Discord's own
                // white pre-paint, which is the flash this exists to remove.
                if !isLoading, page.url != nil { hasPainted = true }
            }
            .overlay(alignment: .bottom) {
                if didFail {
                    Text("Signed in, but the session token could not be read.")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .padding(Spacing.snug)
                        .glassEffect(.regular, in: .rect(cornerRadius: Radius.chip))
                        .padding(Spacing.margin)
                }
            }
    }

    static let loginURL = URL(string: "https://discord.com/login")!

    /// Watches for the token to appear.
    ///
    /// Polling rather than a navigation callback, because Discord's login is a
    /// single-page app: a successful sign-in changes no top-level URL that a
    /// navigation delegate would see, and the token appears in storage a moment
    /// *after* the route changes. A poll is a few JavaScript evaluations a second
    /// against a page that is otherwise idle, and it stops the instant it
    /// succeeds.
    private func pollForToken() async {
        // Bounded, so a window left open on the login page does not evaluate
        // JavaScript forever. Ten minutes is far longer than any real sign-in,
        // including one that goes through an email challenge.
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while isPolling, !Task.isCancelled, ContinuousClock.now < deadline {
            if let token = await readToken() {
                isPolling = false
                onToken(token)
                return
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
    }

    /// Reads the session token out of the page.
    ///
    /// Discord's client deletes `window.localStorage` from its own frame, so the
    /// value is reached through a fresh iframe — which gets an untouched
    /// `localStorage` for the same origin. The frame is removed immediately
    /// afterwards.
    ///
    /// The stored value is JSON, so it arrives wrapped in quotes; it is parsed
    /// rather than trimmed, because a token that keeps its quotes authenticates
    /// nothing and fails with a 401 that looks like a wrong password.
    private func readToken() async -> String? {
        let script = """
        try {
            const frame = document.createElement('iframe');
            document.body.appendChild(frame);
            const raw = frame.contentWindow.localStorage.getItem('token');
            frame.remove();
            if (!raw) { return null; }
            return JSON.parse(raw);
        } catch (error) {
            return null;
        }
        """
        do {
            let result = try await page.callJavaScript(script)
            guard let token = result as? String, !token.isEmpty else { return nil }
            return token
        } catch {
            return nil
        }
    }
}
