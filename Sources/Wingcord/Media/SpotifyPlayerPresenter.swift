import SwiftUI
import WebKit
import WingcordCore

/// The one place the full Spotify player is presented.
///
/// Attached at the window root, exactly as `ProfilePresenter` is and for the
/// same reasons: the transcript is a drawn canvas and cannot host a
/// presentation, so a card publishes a rect and this anchors to it — and a panel
/// written inline would be a panel per row.
///
/// **A layer in the window rather than a popover**, again for `ProfilePresenter`'s
/// reasons: a presentation is an `NSWindow` that paints its own backdrop behind
/// the whole of its content, and a web view under a system material is a grey
/// slab with a player somewhere inside it.
struct SpotifyPlayerPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content.overlay {
            if let session = model.spotifyPlayer {
                let _ = DiagnosticLog.trace(
                    "spotify", "panel presenting \(session.card.key) anchor=\(session.anchor)"
                )
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        // Outside-click and Escape, with no event monitor and
                        // nothing to tear down — `ProfilePresenter`'s pattern.
                        Button {
                            model.closeSpotifyPlayer()
                        } label: {
                            Color.black.opacity(0.001)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .ignoresSafeArea()

                        panel(session, container: proxy.size)
                    }
                }
            }
        }
        .animation(motion.panel, value: model.spotifyPlayerRevision)
    }

    private func panel(_ session: SpotifyPlayerSession, container: CGSize) -> some View {
        let width = SpotifyPlayerSession.width
        let height = SpotifyPlayerSession.height(for: session.card.kind)
        let placement = ProfileCardPlacement(
            anchor: session.anchor,
            cardWidth: width,
            overhang: EdgeInsets(),
            container: container
        )
        return VStack(alignment: .leading, spacing: 0) {
            bar(session)
            SpotifyPlayerWebView(session: session)
                .frame(width: width, height: height)
        }
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .fill(Palette.surface)
        }
        .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        // **Both axes by alignment guide, never one by `.offset`.** An offset
        // does not participate in layout, so mixing the two places the panel
        // against two different origins — `ProfilePresenter` solves the same
        // problem with the same pair and this has to match it.
        .alignmentGuide(.leading) { _ in -placement.cardX }
        .alignmentGuide(.top) { box in -placement.cardY(forHeight: box.height) }
        .transition(.materialize(from: placement.growthAnchor))
    }

    /// The panel's own strip: what is playing, the way back and forth between
    /// the player and Spotify's site, and a close.
    ///
    /// **The sign-in route is a navigation, not a second web view.** Spotify's
    /// embed has no sign-in of its own, and the site it belongs to is the same
    /// origin — so going there, signing in, and coming back is one session
    /// gaining cookies rather than two web views and a handoff.
    private func bar(_ session: SpotifyPlayerSession) -> some View {
        HStack(spacing: Spacing.base) {
            Text(session.card.title)
                .font(Typeface.rowTitleUnread)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Spacer(minLength: Spacing.tight)
            Button(session.page == .player ? "Sign in" : "Player") {
                model.spotifyPlayer?.load(session.page == .player ? .signIn : .player)
                // The session's own page is not observable, so the panel is
                // nudged rather than left showing the previous label.
                model.spotifyPlayerRevision &+= 1
            }
            .buttonStyle(.plain)
            .font(Typeface.rowSubtitle)
            .foregroundStyle(Ink.secondary)
            .help(
                session.page == .player
                    ? "Open Spotify to sign in — the player keeps the session"
                    : "Back to the player"
            )
            Button {
                model.closeSpotifyPlayer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close the player"))
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
    }
}

/// The session's web view, adopted rather than created.
///
/// **The session owns it**, for `ActivityWebView`'s reason: a view that built one
/// would rebuild it on every update, and each rebuild is a fresh page load and a
/// fresh `WebContent` process.
private struct SpotifyPlayerWebView: NSViewRepresentable {
    var session: SpotifyPlayerSession

    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ webView: WKWebView, context: Context) {}
    /// Deliberately empty: only `closeSpotifyPlayer` ends the session.
    static func dismantleNSView(_ webView: WKWebView, coordinator: ()) {}
}

extension View {
    /// Apply once, at the window root.
    func presentsSpotifyPlayer() -> some View {
        modifier(SpotifyPlayerPresenter())
    }
}
