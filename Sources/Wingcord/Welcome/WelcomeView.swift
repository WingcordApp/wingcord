import SwiftUI

/// The first thing Wingcord shows, once (docs/LOGIN-ONBOARDING.md D2–D4).
///
/// **The lockup isn't drawn here**: it's the backdrop's particles, gathering
/// into the wings and "Wingcord" (`EmberRenderer`). This is what goes over
/// them — the name for VoiceOver, and Get Started once the lockup has formed.
/// Get Started's glass is the email field's: pressed, it travels and becomes it.
struct WelcomeView: View {
    var glass: Namespace.ID
    var getStarted: () -> Void

    @Environment(\.motion) private var motion
    @State private var showsButton = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // What the particles say, for VoiceOver.
                Text("Wingcord")
                    .font(.system(.largeTitle, weight: .bold))
                    .opacity(0)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(Text("Welcome to Wingcord"))

                if showsButton {
                    Button(action: getStarted) {
                        HStack(spacing: Spacing.base) {
                            Text("Get Started")
                                .font(.system(.title3, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(.body, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.section)
                        .frame(height: SignInStyle.fieldHeight + 6)
                        .contentShape(.capsule)
                        .glassEffect(.regular.tint(SignInStyle.brand.opacity(0.75)).interactive(), in: .capsule)
                        .glassEffectID("primary", in: glass)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * 0.77)
                    .transition(motion.reduceMotion ? AnyTransition.opacity : AnyTransition(.materialize(from: .center, blurring: false)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task {
            // As the lockup finishes gathering; at once where nothing gathers.
            let delay = motion.reduceMotion ? 0.5 : EmberRenderer.lockupFormedAt - 0.35
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(motion.panel) { showsButton = true }
        }
    }
}

/// Whether the welcome has been seen on this Mac (D2): once, then never again
/// unless asked for with `--welcome`.
nonisolated enum WelcomeRecord {
    private static let key = "dev.wingcord.welcomeSeen"

    static var shouldShow: Bool {
        LaunchOptions.current.forcesWelcome || !UserDefaults.standard.bool(forKey: key)
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: key)
    }
}
