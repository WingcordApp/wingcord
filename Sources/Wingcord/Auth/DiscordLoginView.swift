import OSLog
import SwiftUI
import WebKit
import WingcordCore

/// Discord's own sign-in page, hosted.
///
/// **Discord's page rather than a hand-built form, and that is the safer choice
/// on both counts.** A native email-and-password form would have to reimplement
/// captcha, two-factor, backup codes, passkeys, the "new login location" email
/// challenge and every future change to any of them — and every one of those is
/// a place to get it subtly wrong. More importantly, it would mean this app
/// handling the password itself. Here it never sees one: the credentials go from
/// the web view straight to Discord over TLS, and what comes back out is a
/// session token.
///
/// The token is read once, stored in the Keychain, and the web view's data is
/// discarded — the login session is a means to a credential, not something worth
/// keeping.
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

/// The sign-in surface: the account picker when there are stored accounts, and
/// the web sign-in when there are not.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var isPresentingWebLogin = false
    @State private var accounts: [StoredAccount] = []

    var body: some View {
        VStack(spacing: Spacing.group) {
            VStack(spacing: Spacing.base) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Palette.accent)
                Text("Wingcord")
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(Ink.primary)
                Text(subtitle)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
            }

            if !accounts.isEmpty {
                VStack(spacing: Spacing.base) {
                    ForEach(accounts) { account in
                        AccountRow(
                            account: account,
                            resume: { model.resumeSession(for: account) },
                            forget: {
                                AccountLedger.remove(account.id)
                                accounts = AccountLedger.accounts()
                            }
                        )
                    }
                }
                .frame(maxWidth: 320)
            }

            Button("Sign in with Discord", systemImage: "arrow.right.circle.fill") {
                isPresentingWebLogin = true
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Palette.accent)
            .controlSize(.extraLarge)

            if case .failed(let reason) = model.connectionState {
                Text(reason)
                    .font(.system(.caption))
                    .foregroundStyle(Palette.destructive)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .readingSurface()
        .task { accounts = AccountLedger.accounts() }
        .modal(isPresented: $isPresentingWebLogin, style: .panel) {
            DiscordLoginView { token in
                isPresentingWebLogin = false
                model.beginSession(token: token)
            }
            .frame(width: 560, height: 720)
            .overlay(alignment: .topTrailing) {
                ModalCloseButton { isPresentingWebLogin = false }
                    .padding(Spacing.margin)
            }
        }
    }

    private var subtitle: String {
        switch model.connectionState {
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        default: accounts.isEmpty
            ? "Sign in to your Discord account to continue."
            : "Pick an account, or sign in to another."
        }
    }
}

/// One stored account.
///
/// **A real `Button`, not a row with `.onTapGesture`.** A tap gesture looks
/// identical and is not the same control: it takes no keyboard focus, reports
/// nothing to VoiceOver, gives no press feedback, and cannot be activated by
/// Return or by an automation click. This is the first control anyone touches in
/// the app, so it has to be the real thing.
///
/// The Forget button sits OUTSIDE the account button rather than inside it — a
/// button nested in a button is one hit region the outer one swallows.
private struct AccountRow: View {
    var account: StoredAccount
    var resume: () -> Void
    var forget: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: resume) {
                HStack(spacing: Spacing.snug) {
                    AvatarView(
                        url: account.avatarHash.flatMap {
                            URL(string: "\(CDN.host)/avatars/\(account.id)/\($0).webp?size=64")
                        },
                        monogram: account.preferredName.first.map(String.init)?.uppercased() ?? "?",
                        side: 32
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.preferredName)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        Text(account.username)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength: Spacing.base)
                }
                .padding(Spacing.snug)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Continue as \(account.preferredName)"))

            Button("Forget", systemImage: "xmark", action: forget)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Ink.tertiary)
                .padding(.trailing, Spacing.snug)
                .accessibilityLabel(Text("Forget \(account.preferredName)"))
        }
        .background {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .fill(isHovering ? Palette.selectionFill : Palette.surfaceRaised)
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
    }
}
