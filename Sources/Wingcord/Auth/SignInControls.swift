import SwiftUI

/// The sign-in screen's colours: Wingcord's own, off the icon and the
/// wallpaper, on a ground that's always dark.
nonisolated enum SignInStyle {
    /// The act's glass: between the icon's orange and its red.
    static let brand = Color(red: 0.91, green: 0.29, blue: 0.13)
    /// A link on the dark ground: the wallpaper's cream, warmed.
    static let link = Color(red: 1.0, green: 0.76, blue: 0.56)
    /// A complaint on the dark ground — the system's red is too dark to read
    /// at a caption's size over the ember.
    static let error = Color(red: 1.0, green: 0.48, blue: 0.42)
    static let fieldHeight: CGFloat = 44
    static let columnWidth: CGFloat = 360
}

extension View {
    /// A field on the sign-in screen: the system's text field in a Liquid Glass
    /// capsule, ringed in the brand while it has the keyboard and tinted red
    /// while Discord has a complaint about it.
    ///
    /// **The ring is drawn inside the glass**, before `.glassEffect`: inside a
    /// `GlassEffectContainer` anything laid over the glass from outside draws
    /// under it (INVARIANTS §4).
    func signInField(isFocused: Bool, hasError: Bool) -> some View {
        padding(.horizontal, Spacing.margin)
            .frame(height: SignInStyle.fieldHeight)
            .overlay {
                Capsule()
                    .strokeBorder(
                        hasError ? SignInStyle.error : SignInStyle.brand,
                        lineWidth: hasError || isFocused ? 1.5 : 0
                    )
                    .opacity(hasError || isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(.capsule)
            .glassEffect(hasError ? .regular.tint(SignInStyle.error.opacity(0.18)).interactive() : .regular.interactive(), in: .capsule)
    }
}

/// A complaint under a field, in Discord's words.
struct SignInFieldError: View {
    var message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(SignInStyle.error)
                .padding(.leading, Spacing.margin)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// A word that does something: "Forgot your password?", "Register".
struct SignInLinkButton: View {
    var title: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(SignInStyle.link)
                .underline(isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The act on each page: Log In, Confirm, Restore. Orange-red glass, full width,
/// a spinner where the word was while Discord answers.
struct SignInPrimaryButton: View {
    var title: String
    var isWorking: Bool
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .font(.system(.body, weight: .semibold))
                    .opacity(isWorking ? 0 : 1)
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.extraLarge)
        .tint(SignInStyle.brand)
        .disabled(!isEnabled || isWorking)
        .accessibilityLabel(Text(isWorking ? "\(title), in progress" : title))
    }
}

/// A shake for a refusal: the form says no the way a Mac's login window does.
/// Under Reduce Motion it doesn't move; the red says it.
struct RefusalShake: GeometryEffect {
    var shakes: CGFloat

    nonisolated var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(shakes * .pi * 4), y: 0))
    }
}

extension View {
    func shakes(on rejections: Int, reduceMotion: Bool) -> some View {
        modifier(RefusalShake(shakes: reduceMotion ? 0 : CGFloat(rejections)))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.42), value: rejections)
    }
}

/// What the screen has to say that isn't about one field.
struct SignInNoticeView: View {
    var notice: SignInFlow.Notice
    var openWebsite: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
            Image(systemName: symbol)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                message
                    .font(.system(.callout))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if needsWebsite {
                    SignInLinkButton(title: "Open Discord's website", action: openWebsite)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.snug)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: Radius.glass, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var needsWebsite: Bool {
        switch notice {
        case .suspended, .phoneVerification: true
        default: false
        }
    }

    private var symbol: String {
        switch notice {
        case .newLocation: "envelope.badge.shield.half.filled"
        case .suspended: "exclamationmark.octagon.fill"
        case .phoneVerification: "iphone.gen3.badge.exclamationmark"
        case .tooManyAttempts: "hourglass"
        case .resetSent: "paperplane.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch notice {
        case .resetSent, .newLocation: SignInStyle.link
        default: SignInStyle.error
        }
    }

    @ViewBuilder
    private var message: some View {
        switch notice {
        case .newLocation(let sentence):
            Text("\(sentence) Once you've approved the sign-in from the email, log in again.")
        case .suspended:
            Text("This account has been suspended. Log in on Discord's website to see why and what you can do.")
        case .phoneVerification:
            Text("Discord wants to verify the phone number on this account before it signs in from here. Log in with the QR code, or on Discord's website.")
        case .tooManyAttempts(let until):
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                Text(seconds > 0
                     ? "Too many attempts. Try again in \(seconds) seconds."
                     : "You can try again now.")
            }
        case .resetSent(let email):
            Text("We sent instructions to change your password to **\(email)**, please check both your inbox and spam folder.")
        case .failed(let message):
            Text(message)
        }
    }
}
