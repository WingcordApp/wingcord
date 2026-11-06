import SwiftUI
import WingcordCore
import WingcordNet

/// The login screen's right-hand column: the code, and what happens when a
/// phone scans it (D7).
///
/// **The code turns over** to show who scanned it — their picture, "Check your
/// phone!", "Logging in as …", and Discord's "Not me, start over" — and turns
/// back for a new code. Under Reduce Motion it cross-fades.
struct QRLoginPanel: View {
    var flow: SignInFlow
    /// `--demo` has no phone: a click on the code is the scan.
    var demoScan: (() -> Void)?

    @Environment(\.motion) private var motion

    private static let side: CGFloat = 196

    private var scanned: RemoteAuthUser? {
        switch flow.qr {
        case .scanned(let user): user
        default: nil
        }
    }

    private var isTurned: Bool {
        switch flow.qr {
        case .scanned, .loggingIn: true
        default: false
        }
    }

    private var readyURL: URL? {
        if case .ready(let url) = flow.qr { return url }
        return nil
    }

    var body: some View {
        VStack(spacing: Spacing.group) {
            ZStack {
                code
                    .modifier(TurnOver(progress: isTurned ? 1 : 0, face: .front, reduceMotion: motion.reduceMotion))
                ScannedFace(user: lastScanned, isLoggingIn: flow.qr == .loggingIn || flow.isFinished, isShowing: isTurned)
                    .frame(width: Self.side, height: Self.side)
                    .modifier(TurnOver(progress: isTurned ? 1 : 0, face: .back, reduceMotion: motion.reduceMotion))
            }
            .animation(motion.reduceMotion ? motion.fade : .spring(response: 0.6, dampingFraction: 0.86), value: isTurned)

            VStack(spacing: Spacing.base) {
                Text(isTurned ? "Check your phone!" : "Log in with QR Code")
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .contentTransition(.opacity)
                caption
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if isTurned, !flow.isFinished {
                    SignInLinkButton(title: "Not me, start over") { flow.restartQR() }
                        .padding(.top, Spacing.tight)
                        .transition(.opacity)
                }
            }
            .animation(motion.standard, value: isTurned)
            .frame(width: 240)
        }
        .onChange(of: scanned) { _, user in
            if let user { lastScanned = user }
        }
    }

    /// Kept after the scan moves on to logging in, so the back face still
    /// knows whose it is.
    @State private var lastScanned: RemoteAuthUser?

    @ViewBuilder
    private var code: some View {
        let tile = QRCodeTile(url: readyURL, side: Self.side)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        if let demoScan, readyURL != nil {
            Button(action: demoScan) { tile }
                .buttonStyle(.plain)
                .help("In the demo, a click is the phone scanning the code")
        } else {
            tile
        }
    }

    @ViewBuilder
    private var caption: some View {
        if isTurned, let user = lastScanned {
            Text("Logging in as \(user.username)")
        } else {
            Text("Scan this with the **Discord mobile app** to log in instantly.")
        }
    }
}

/// The back of the code: who scanned it.
private struct ScannedFace: View {
    var user: RemoteAuthUser?
    var isLoggingIn: Bool
    /// The back face is always in the tree, at no opacity while the code shows;
    /// a pulse left running there would animate for nobody, every frame.
    var isShowing: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.28))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            VStack(spacing: Spacing.snug) {
                if let user {
                    let account = StoredAccount(id: user.id, username: user.username, avatarHash: user.avatarHash)
                    AvatarView(url: account.avatarURL(side: 96), monogram: account.monogram, side: 96)
                        .overlay(alignment: .bottomTrailing) {
                            Circle()
                                .fill(Palette.presenceOnline)
                                .frame(width: 22, height: 22)
                                .overlay { Circle().strokeBorder(.black.opacity(0.6), lineWidth: 3) }
                        }
                }
                Image(systemName: isLoggingIn ? "checkmark.circle.fill" : "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(isLoggingIn ? Palette.presenceOnline : SignInStyle.link)
                    .symbolEffect(.pulse, isActive: isShowing && !isLoggingIn)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(user.map { "Scanned by \($0.username). Check your phone." } ?? ""))
    }
}

/// One face of a card turning over on its vertical axis: the front shows
/// until halfway, the back from halfway. Reduce Motion cross-fades instead.
private struct TurnOver: ViewModifier, Animatable {
    enum Face { case front, back }

    var progress: Double
    var face: Face
    var reduceMotion: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let angle = face == .front ? progress * 180 : progress * 180 - 180
        let visible = face == .front ? progress < 0.5 : progress >= 0.5
        if reduceMotion {
            content.opacity(face == .front ? 1 - progress : progress)
        } else {
            content
                .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .opacity(visible ? 1 : 0)
        }
    }
}
