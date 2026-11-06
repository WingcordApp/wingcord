import SwiftUI
import WingcordNet

/// Wingcord's own login (docs/LOGIN-ONBOARDING.md D5–D10): the form on the
/// left, the QR code on the right, and the pages that turn in over them — the
/// second factor and a deleted account's question.
///
/// Drawn the same on the sign-in screen and in Add an Account's card; only the
/// heading differs.
struct LoginView: View {
    @Bindable var flow: SignInFlow
    /// The welcome's Get Started morphs into the email field (D4).
    var glass: Namespace.ID?
    /// Something the session itself said — a stored account that wouldn't come
    /// back up — shown until the next try.
    var sessionProblem: String?
    var demoScan: (() -> Void)?
    /// "Having trouble?": Discord's own page, the way out for anything this
    /// can't do. Nil in `--demo`.
    var openWebSignIn: (() -> Void)?

    @Environment(\.motion) private var motion
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            switch flow.page {
            case .credentials:
                CredentialsPage(
                    flow: flow,
                    glass: glass,
                    sessionProblem: sessionProblem,
                    demoScan: demoScan,
                    openWebSignIn: openWebSignIn,
                    openWebsite: openWebsite
                )
                .transition(.modalStep(forward: false))
            case .mfa:
                MFAPage(flow: flow)
                    .transition(.modalStep(forward: true))
            case .restore(let kind):
                RestorePage(flow: flow, kind: kind)
                    .transition(.modalStep(forward: true))
            }
        }
        .animation(motion.reposition, value: flow.page)
        // The QR code runs while the login is up, and starts over when asked.
        .task(id: flow.qrGeneration) { await flow.runQR() }
    }

    private func openWebsite() {
        if let url = URL(string: "https://discord.com/login") { openURL(url) }
    }
}

/// The form and the code, side by side.
private struct CredentialsPage: View {
    @Bindable var flow: SignInFlow
    var glass: Namespace.ID?
    var sessionProblem: String?
    var demoScan: (() -> Void)?
    var openWebSignIn: (() -> Void)?
    var openWebsite: () -> Void

    @FocusState private var focus: SignInFlow.Field?
    @Environment(\.motion) private var motion
    @Environment(\.openURL) private var openURL
    /// The page cascades in by itself, a beat behind the email field — whose
    /// glass is already there, because it's Get Started's, arriving (D4).
    @State private var arrived = false

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.section + Spacing.group) {
            form
                .frame(width: SignInStyle.columnWidth)
            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(width: 1, height: 280)
                .accessibilityHidden(true)
                .modifier(Arrival(arrived: arrived, order: 3, reduceMotion: motion.reduceMotion))
            QRLoginPanel(flow: flow, demoScan: demoScan)
                .modifier(Arrival(arrived: arrived, order: 3, reduceMotion: motion.reduceMotion))
        }
        .onAppear {
            arrived = true
            if focus == nil { focus = flow.login.isEmpty ? .login : .password }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(flow.purpose == .addAccount ? "Add Account" : "Welcome back!")
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(flow.purpose == .addAccount
                     ? "Logging in to another account will let you easily switch between accounts on this device."
                     : "We're so excited to see you again!")
                    .font(.system(.title3))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(Arrival(arrived: arrived, order: 0, reduceMotion: motion.reduceMotion))

            if let notice = flow.notice {
                SignInNoticeView(notice: notice, openWebsite: openWebsite)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let sessionProblem {
                SignInNoticeView(notice: .failed(sessionProblem), openWebsite: openWebsite)
            }

            VStack(alignment: .leading, spacing: Spacing.snug) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    LoginField(
                        login: $flow.login,
                        phoneCode: $flow.phoneCode,
                        error: flow.fieldErrors[.login],
                        focus: $focus,
                        contentOpacity: arrived ? 1 : 0,
                        onSubmit: submitLogin
                    )
                    .modifier(GlassID(id: "primary", namespace: glass))
                    SignInFieldError(message: flow.fieldErrors[.login])
                }
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    PasswordField(
                        password: $flow.password,
                        error: flow.fieldErrors[.password],
                        focus: $focus,
                        onSubmit: logIn
                    )
                    SignInFieldError(message: flow.fieldErrors[.password])
                }
                .modifier(Arrival(arrived: arrived, order: 1, reduceMotion: motion.reduceMotion))
                SignInLinkButton(title: "Forgot your password?", action: forgotPassword)
                    .padding(.leading, Spacing.margin)
                    .modifier(Arrival(arrived: arrived, order: 1, reduceMotion: motion.reduceMotion))
            }
            .shakes(on: flow.rejections, reduceMotion: motion.reduceMotion)
            .animation(motion.standard, value: flow.fieldErrors)

            SignInPrimaryButton(
                title: "Log In",
                isWorking: flow.isWorking || flow.isFinished,
                isEnabled: flow.canLogIn,
                action: logIn
            )
            .modifier(Arrival(arrived: arrived, order: 2, reduceMotion: motion.reduceMotion))

            HStack(spacing: Spacing.tight) {
                Text("Need an account?")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                SignInLinkButton(title: "Register") {
                    if let url = URL(string: "https://discord.com/register") { openURL(url) }
                }
                if let openWebSignIn {
                    Spacer(minLength: Spacing.base)
                    SignInLinkButton(title: "Having trouble?", action: openWebSignIn)
                        .help("Log in on Discord's own page instead")
                }
            }
            .modifier(Arrival(arrived: arrived, order: 3, reduceMotion: motion.reduceMotion))
        }
        .animation(motion.standard, value: flow.notice)
    }

    private func submitLogin() {
        if flow.password.isEmpty {
            focus = .password
        } else {
            logIn()
        }
    }

    private func logIn() {
        Task { await flow.logIn() }
    }

    private func forgotPassword() {
        Task {
            if await flow.resetPassword() == false {
                // A phone number: Discord's own page texts the code.
                openWebsite()
            }
        }
    }
}

/// "Account Scheduled for Deletion" and "Account Disabled", as Discord asks them.
private struct RestorePage: View {
    var flow: SignInFlow
    var kind: SignInFlow.RestoreKind

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Image(systemName: kind == .scheduledForDeletion ? "clock.badge.exclamationmark.fill" : "person.crop.circle.badge.xmark")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(SignInStyle.link)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(kind == .scheduledForDeletion ? "Account Scheduled for Deletion" : "Account Disabled")
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(kind == .scheduledForDeletion
                     ? "Your account is scheduled to self-destruct soon."
                     : "You cannot use it while it's disabled.")
                    .font(.system(.body))
                    .foregroundStyle(Ink.secondary)
            }
            if let notice = flow.notice {
                SignInNoticeView(notice: notice, openWebsite: {})
            }
            HStack(spacing: Spacing.tight) {
                Text("Change your mind?")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                SignInLinkButton(title: flow.isWorking ? "Restoring…" : "Restore Account") {
                    Task { await flow.restoreAccount() }
                }
                .disabled(flow.isWorking)
            }
            Button("Return to Login") { flow.returnToLogin() }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
        }
        .frame(width: SignInStyle.columnWidth, alignment: .leading)
    }
}

/// One part of the login arriving, in order: it rises a few points into place
/// as it fades up. Reduce Motion fades it.
private struct Arrival: ViewModifier {
    var arrived: Bool
    var order: Int
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived || reduceMotion ? 0 : 10)
            .animation(
                reduceMotion
                    ? .easeOut(duration: Motion.reducedDuration)
                    : Motion.panel.animation.delay(0.10 + Double(order) * 0.05),
                value: arrived
            )
    }
}

/// `glassEffectID`, where there's a namespace to give it.
struct GlassID: ViewModifier {
    var id: String
    var namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}
