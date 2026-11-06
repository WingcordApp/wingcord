import SwiftUI
import WingcordNet

/// "Multi-Factor Authentication": the page that turns in over the form when
/// the account has a second factor (D8). Discord's words throughout.
struct MFAPage: View {
    @Bindable var flow: SignInFlow

    @Environment(\.motion) private var motion
    @FocusState private var backupFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("Multi-Factor Authentication")
                    .font(.system(.title, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .accessibilityAddTraits(.isHeader)
                subtitle
                    .font(.system(.body))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ZStack(alignment: .topLeading) {
                content
                    .id(flow.method)
                    .transition(.modalStep(forward: flow.method != nil))
            }
            .animation(motion.standard, value: flow.method)

            buttons

            SignInLinkButton(title: "Go back") { flow.returnToLogin() }
        }
        .frame(width: SignInStyle.columnWidth + 40, alignment: .leading)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch flow.method {
        case nil:
            Text("This extra step shows it's really you.")
        case .totp:
            Text("Verify with your authenticator app")
        case .sms:
            if let destination = flow.smsDestination {
                Text("We've sent a message to \(destination). Please enter the code you received.")
            } else {
                Text("Sending...")
            }
        case .backup:
            Text("Enter Discord Backup Code")
        case .webauthn:
            Text("Use a passkey or security key")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.method {
        case nil:
            MethodList(methods: flow.methods) { flow.choose($0) }
        case .totp, .sms:
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("Enter Discord Auth Code")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                OneTimeCodeField(
                    code: $flow.code,
                    length: 6,
                    hasError: flow.fieldErrors[.code] != nil
                ) {
                    Task { await flow.submitCode() }
                }
                .shakes(on: flow.rejections, reduceMotion: motion.reduceMotion)
                SignInFieldError(message: flow.fieldErrors[.code])
                if flow.method == .sms {
                    SignInLinkButton(title: flow.isSendingSMS ? "Sending..." : "Resend Code") {
                        Task { await flow.sendSMS() }
                    }
                    .disabled(flow.isSendingSMS)
                }
            }
        case .backup:
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("Backup codes can only be used one time each and are for emergency access to your account!")
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(SignInStyle.link)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.base) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    TextField("8-digit backup code", text: $flow.code, prompt: Text("8-digit backup code").foregroundStyle(Ink.tertiary))
                        .textFieldStyle(.plain)
                        .font(.system(.body).monospaced())
                        .foregroundStyle(Ink.primary)
                        .autocorrectionDisabled()
                        .tint(SignInStyle.brand)
                        .focused($backupFocused)
                        .onSubmit { Task { await flow.submitCode() } }
                }
                .signInField(isFocused: backupFocused, hasError: flow.fieldErrors[.code] != nil)
                .shakes(on: flow.rejections, reduceMotion: motion.reduceMotion)
                .onAppear { backupFocused = true }
                SignInFieldError(message: flow.fieldErrors[.code])
            }
        case .webauthn:
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Text("Passkeys and security keys work only in apps Discord's website names as its own, and Wingcord isn't one of them. Use another method, or log in with the QR code: your phone is already signed in, so it won't ask for a second step.")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                SignInLinkButton(title: "Log in with the QR code instead") { flow.returnToLogin() }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let canChooseAnother = flow.methods.count > 1 && flow.method != nil
        let needsConfirm = flow.method == .totp || flow.method == .sms || flow.method == .backup
        if canChooseAnother || needsConfirm {
            HStack(spacing: Spacing.snug) {
                if canChooseAnother {
                    // The same height as Confirm beside it: controls in a row
                    // share one height.
                    Button { flow.choose(nil) } label: {
                        Text("Verify with something else")
                            .font(.system(.body, weight: .semibold))
                            .padding(.horizontal, Spacing.tight)
                            .frame(minHeight: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.extraLarge)
                    .fixedSize()
                }
                if needsConfirm {
                    SignInPrimaryButton(
                        title: "Confirm",
                        isWorking: flow.isWorking || flow.isFinished,
                        isEnabled: flow.canSubmitCode
                    ) {
                        Task { await flow.submitCode() }
                    }
                }
            }
        }
    }
}

/// "Verify with something else": each method the account has, in Discord's words.
private struct MethodList: View {
    var methods: [MFAMethod]
    var choose: (MFAMethod) -> Void

    var body: some View {
        VStack(spacing: Spacing.base) {
            ForEach(methods, id: \.self) { method in
                Button {
                    choose(method)
                } label: {
                    HStack(spacing: Spacing.snug) {
                        Image(systemName: Self.symbol(method))
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(SignInStyle.link)
                            .frame(width: 22)
                        Text(Self.title(method))
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        Spacer(minLength: Spacing.base)
                        Image(systemName: "chevron.right")
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(Ink.secondary)
                    }
                    .padding(.horizontal, Spacing.margin)
                    .frame(height: SignInStyle.fieldHeight + 4)
                    .contentShape(.capsule)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// `611248`'s labels.
    static func title(_ method: MFAMethod) -> String {
        switch method {
        case .totp: "Use your authenticator app"
        case .sms: "Use a code sent to your phone"
        case .backup: "Use a backup code"
        case .webauthn: "Use a passkey or security key"
        }
    }

    static func symbol(_ method: MFAMethod) -> String {
        switch method {
        case .totp: "lock.shield.fill"
        case .sms: "message.fill"
        case .backup: "key.fill"
        case .webauthn: "person.badge.key.fill"
        }
    }
}
