import SwiftUI

/// "Email or Phone Number", with Discord's phone rule: once what's typed is a
/// number, the country's code slides in at the front (D6).
struct LoginField: View {
    @Binding var login: String
    @Binding var phoneCode: PhoneCode
    var error: String?
    var focus: FocusState<SignInFlow.Field?>.Binding
    /// What's inside the glass, while the glass itself arrives from Get Started.
    var contentOpacity: Double = 1
    var onSubmit: () -> Void

    @Environment(\.motion) private var motion

    private var isPhone: Bool { LoginKind.isPhone(login) }

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: isPhone ? "phone.fill" : "envelope.fill")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
                .accessibilityHidden(true)
            if isPhone {
                PhoneCodePill(code: $phoneCode)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            TextField(
                "Email or Phone Number",
                text: $login,
                prompt: Text("Email or Phone Number").foregroundStyle(Ink.tertiary)
            )
            .textFieldStyle(.plain)
            .font(.system(.body))
            .foregroundStyle(Ink.primary)
            .textContentType(.username)
            .autocorrectionDisabled()
            // The brand's orange for the caret: on the field itself, since a
            // tint over the screen colours every glass button too.
            .tint(SignInStyle.brand)
            .focused(focus, equals: .login)
            .onSubmit(onSubmit)
        }
        .opacity(contentOpacity)
        .animation(Motion.panel.animation.delay(0.18), value: contentOpacity)
        .animation(motion.standard, value: isPhone)
        .signInField(isFocused: focus.wrappedValue == .login, hasError: error != nil)
    }
}

/// "Password", hidden until the eye says otherwise.
struct PasswordField: View {
    @Binding var password: String
    var error: String?
    var focus: FocusState<SignInFlow.Field?>.Binding
    var onSubmit: () -> Void

    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "lock.fill")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Group {
                if isRevealed {
                    TextField("Password", text: $password, prompt: Text("Password").foregroundStyle(Ink.tertiary))
                } else {
                    SecureField("Password", text: $password, prompt: Text("Password").foregroundStyle(Ink.tertiary))
                }
            }
            .textFieldStyle(.plain)
            .font(.system(.body))
            .foregroundStyle(Ink.primary)
            .textContentType(.password)
            .autocorrectionDisabled()
            .tint(SignInStyle.brand)
            .focused(focus, equals: .password)
            .onSubmit(onSubmit)
            .privacySensitive()

            Button(isRevealed ? "Hide Password" : "Show Password", systemImage: isRevealed ? "eye.slash" : "eye") {
                isRevealed.toggle()
                focus.wrappedValue = .password
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .contentTransition(.symbolEffect(.replace))
            .help(isRevealed ? "Hide password" : "Show password")
        }
        .signInField(isFocused: focus.wrappedValue == .password, hasError: error != nil)
    }
}

/// The country before a phone number: its letters and code, and Discord's
/// list behind a click.
struct PhoneCodePill: View {
    @Binding var code: PhoneCode
    @State private var isPicking = false

    var body: some View {
        Button {
            isPicking = true
        } label: {
            HStack(spacing: Spacing.tight) {
                Text(code.alpha2)
                    .font(.system(.caption, weight: .bold))
                Text(code.prefix)
                    .font(.system(.callout, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(.caption2, weight: .bold))
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, Spacing.base)
            .frame(height: 26)
            .background(.white.opacity(0.12), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("Choose the country code")
        .accessibilityLabel(Text("Country code, \(code.localizedName), \(code.prefix)"))
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            PhoneCodePicker(selection: $code) { isPicking = false }
        }
    }
}

/// Discord's country list, searchable by name or code.
private struct PhoneCodePicker: View {
    @Binding var selection: PhoneCode
    var dismiss: () -> Void

    @State private var query = ""

    private var matches: [PhoneCode] {
        PhoneCode.all
            .filter { $0.matches(query) }
            .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: Spacing.base) {
            SearchField(prompt: "Search countries", text: $query, takesFocus: true)
            List(matches) { code in
                Button {
                    selection = code
                    dismiss()
                } label: {
                    HStack(spacing: Spacing.base) {
                        Text(code.localizedName)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Spacer(minLength: Spacing.base)
                        Text(code.code)
                            .monospacedDigit()
                            .foregroundStyle(Ink.secondary)
                        Image(systemName: "checkmark")
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(SignInStyle.brand)
                            .opacity(code == selection ? 1 : 0)
                            .accessibilityHidden(code != selection)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: 300)
        }
        .padding(Spacing.snug)
        .frame(width: 300)
    }
}

/// Six digits, one to a box (D8): they advance as they're typed, take a paste
/// whole, and the sixth sends them. One real text field underneath does the
/// typing, so AutoFill can offer a code that came by text message.
struct OneTimeCodeField: View {
    @Binding var code: String
    var length: Int
    var hasError: Bool
    var onComplete: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.motion) private var motion

    var body: some View {
        ZStack {
            TextField("Code", text: $code)
                .textFieldStyle(.plain)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityLabel(Text("\(length)-digit authentication code"))

            HStack(spacing: Spacing.base) {
                ForEach(0..<length, id: \.self) { index in
                    CodeBox(
                        digit: digit(at: index),
                        isActive: isFocused && index == min(code.count, length - 1),
                        isEmptyActive: isFocused && index == code.count,
                        hasError: hasError
                    )
                }
            }
            .contentShape(.rect)
            .onTapGesture { isFocused = true }
            .accessibilityHidden(true)
        }
        .defaultFocus($isFocused, true)
        .onAppear { isFocused = true }
        .onChange(of: code) { _, typed in
            let digits = String(typed.filter { ("0"..."9").contains($0) }.prefix(length))
            if digits != typed {
                code = digits
                return
            }
            if digits.count == length { onComplete() }
        }
    }

    private func digit(at index: Int) -> String? {
        guard index < code.count else { return nil }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }
}

private struct CodeBox: View {
    var digit: String?
    var isActive: Bool
    var isEmptyActive: Bool
    var hasError: Bool

    @Environment(\.motion) private var motion
    @State private var caretOn = true

    var body: some View {
        ZStack {
            if let digit {
                Text(digit)
                    .font(.system(.title, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Ink.primary)
                    .transition(motion.reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            } else if isEmptyActive {
                Capsule()
                    .fill(SignInStyle.brand)
                    .frame(width: 2, height: 22)
                    .opacity(caretOn ? 1 : 0.15)
                    .onAppear {
                        guard !motion.reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 0.55).repeatForever()) { caretOn = false }
                    }
            }
        }
        .frame(width: 46, height: 54)
        .overlay {
            RoundedRectangle(cornerRadius: Radius.chip + 2, style: .continuous)
                .strokeBorder(hasError ? SignInStyle.error : SignInStyle.brand, lineWidth: 1.5)
                .opacity(hasError || isActive ? 1 : 0)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.chip + 2, style: .continuous))
        .animation(motion.hover, value: isActive)
        .animation(motion.standard, value: digit)
    }
}
