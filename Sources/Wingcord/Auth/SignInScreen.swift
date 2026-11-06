import SwiftUI
import WingcordCore

/// Everything before the workspace (docs/LOGIN-ONBOARDING.md): the welcome on
/// a first launch, the saved accounts when there are some, and the login — all
/// over one living backdrop that never stops between them.
///
/// **Always dark.** It's the ember wallpaper underneath, whatever the Mac's
/// appearance, and the glass and the ink are chosen for that ground.
struct SignInScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @Environment(\.openURL) private var openURL

    enum Stage: Equatable {
        case welcome
        case accounts
        case login
    }

    @Namespace private var glass
    @State private var stage: Stage?
    @State private var flow: SignInFlow?
    @State private var demoService: DemoSignInService?
    @State private var isShowingWebSignIn = false

    var body: some View {
        ZStack {
            // Not before the stage is known: the backdrop starts as what it's
            // first given, and a welcome begun as a login has no particles.
            if let stage {
                SignInBackdrop(stage: stage == .welcome ? .welcome : .login)
            } else {
                Color.black.ignoresSafeArea()
            }

            GlassEffectContainer(spacing: 0) {
                ZStack {
                    switch stage {
                    case .welcome:
                        WelcomeView(glass: glass, getStarted: getStarted)
                    case .accounts:
                        AccountChooser(
                            accounts: model.storedAccounts,
                            choose: choose,
                            forget: forget,
                            logInToAnother: { go(to: .login) },
                            sessionProblem: sessionProblem
                        )
                        .transition(arrival)
                    case .login:
                        if let flow {
                            LoginView(
                                flow: flow,
                                glass: glass,
                                sessionProblem: sessionProblem,
                                demoScan: demoService.map { service in { service.scan() } },
                                openWebSignIn: LaunchOptions.current.usesDemoFixtures ? nil : { isShowingWebSignIn = true }
                            )
                            // The page brings itself in (`Arrival`), around the
                            // email field's glass, which is Get Started's; going
                            // back, it fades.
                            .transition(.asymmetric(insertion: .identity, removal: .opacity))
                        }
                    case nil:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Under the sign-in's veil the form steps back, leaving the ember
            // and who's arriving.
            .opacity(model.accountSwitch == nil ? 1 : 0)
            .animation(motion.fade, value: model.accountSwitch == nil)
        }
        .overlay(alignment: .topLeading) {
            if showsBack {
                BackToWelcomeButton { go(to: .welcome) }
                    .padding(.top, Spacing.snug)
                    .padding(.leading, Spacing.group)
                    .transition(.opacity)
            }
        }
        .animation(motion.standard, value: showsBack)
        .environment(\.colorScheme, .dark)
        .captchaHost()
        .environment(model.captchaSolver)
        .onAppear(perform: start)
        .task(id: flow.map(ObjectIdentifier.init)) {
            guard let flow else { return }
            await flow.service.installCaptchaSolver(model.captchaSolver)
            await flow.service.prepare()
        }
        .modal(isPresented: $isShowingWebSignIn, style: .panel) {
            DiscordLoginView { token in
                isShowingWebSignIn = false
                model.beginSession(token: token)
            }
            .frame(width: 560, height: 720)
            .overlay(alignment: .topTrailing) {
                ModalCloseButton { isShowingWebSignIn = false }
                    .padding(Spacing.margin)
            }
        }
    }

    /// Back to Get Started (Alex, 2026-11-06): from the login's own page and from
    /// the saved accounts — not from the second factor or a deleted account's
    /// question, which have their own way back to the form.
    private var showsBack: Bool {
        guard model.accountSwitch == nil else { return false }
        switch stage {
        case .accounts: return true
        case .login: return flow?.page == .credentials && flow?.isFinished == false
        default: return false
        }
    }

    /// A page arriving: it condenses out of the backdrop, a beat behind Get
    /// Started's glass so that travels first. No blur: there's glass in it, and
    /// glass inside a blur paints black (INVARIANTS §4).
    private var arrival: AnyTransition {
        motion.reduceMotion
            ? .opacity
            : AnyTransition(.materialize(from: .center, blurring: false)).animation(motion.panel.delay(0.12))
    }

    /// What the session said about the last try, when it failed.
    private var sessionProblem: String? {
        if case .failed(let reason) = model.connectionState { return reason }
        return nil
    }

    private func start() {
        if flow == nil {
            let service: any SignInService
            if LaunchOptions.current.usesDemoFixtures {
                let demo = DemoSignInService()
                demoService = demo
                service = demo
            } else {
                service = LiveSignInService(metadata: model.sessionController.metadata)
            }
            flow = SignInFlow(purpose: .signIn, service: service) { [model] token in
                await model.sessionController.signIn(token: token)
            }
        }
        guard stage == nil else { return }
        if WelcomeRecord.shouldShow {
            stage = .welcome
        } else {
            stage = model.storedAccounts.isEmpty ? .login : .accounts
        }
    }

    private func getStarted() {
        WelcomeRecord.markSeen()
        go(to: model.storedAccounts.isEmpty ? .login : .accounts)
    }

    private func go(to next: Stage) {
        withAnimation(motion.reduceMotion ? motion.fade : motion.glassMorph) {
            stage = next
        }
    }

    /// A saved account: straight in if its session's alive, the login if not.
    private func choose(_ account: StoredAccount) {
        if account.isSessionExpired {
            go(to: .login)
        } else {
            model.resumeSession(for: account)
        }
    }

    private func forget(_ account: StoredAccount) {
        AccountLedger.remove(account.id)
        model.reloadAccounts()
        if model.storedAccounts.isEmpty { go(to: .login) }
    }
}

/// Back to the welcome: a glass capsule at the top left, and ⌘[ — the Mac's
/// own Back.
private struct BackToWelcomeButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "chevron.left")
                    .font(.system(.body, weight: .semibold))
                Text("Back")
                    .font(.system(.body, weight: .semibold))
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, Spacing.snug)
            .frame(height: 34)
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to the welcome")
        .accessibilityLabel(Text("Back to the welcome"))
    }
}

/// Add an Account, while somebody's signed in (D12): the same login, in a card
/// over the app, with no welcome. The token proves itself first and becomes a
/// switch, with its questions — `SessionController.addSignedInAccount`.
struct AddAccountCard: View {
    var close: () -> Void

    @Environment(AppModel.self) private var model
    @State private var flow: SignInFlow?
    @State private var demoService: DemoSignInService?

    var body: some View {
        ZStack {
            SignInBackdrop(stage: .login)
            if let flow {
                LoginView(flow: flow, demoScan: demoService.map { service in { service.scan() } })
                    .padding(Spacing.section + Spacing.base)
            }
        }
        .frame(width: 880, height: 600)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(alignment: .topTrailing) {
            ModalCloseButton(action: close)
                .padding(Spacing.margin)
        }
        .environment(\.colorScheme, .dark)
        // The card is drawn by the modal host, outside the window root's
        // environment, so the solver comes from the model — for the host here
        // to register, and for the sign-in's own client.
        .captchaHost()
        .environment(model.captchaSolver)
        .onAppear(perform: start)
        .task(id: flow.map(ObjectIdentifier.init)) {
            guard let flow else { return }
            await flow.service.installCaptchaSolver(model.captchaSolver)
            await flow.service.prepare()
        }
    }

    private func start() {
        guard flow == nil else { return }
        let service: any SignInService
        if LaunchOptions.current.usesDemoFixtures {
            let demo = DemoSignInService()
            demoService = demo
            service = demo
        } else {
            service = LiveSignInService(metadata: model.sessionController.metadata)
        }
        flow = SignInFlow(purpose: .addAccount, service: service) { [model, close] token in
            let problem = await model.sessionController.addSignedInAccount(token: token)
            if problem == nil { close() }
            return problem
        }
    }
}

/// While a saved account comes back up at launch: nothing to sign in to yet.
struct SignInConnectingView: View {
    var body: some View {
        VStack(spacing: Spacing.snug) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting…")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .readingSurface()
    }
}
