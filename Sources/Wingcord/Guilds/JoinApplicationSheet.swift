import SwiftUI
import WingcordCore

/// Discord's member verification modal (`823591`): the server's card on a
/// tinted panel, and the form beside it — the rules to agree to and, where the
/// server reviews who joins, its questions.
///
/// **Every word is Discord's**, from `0d2ddc8b`: the two titles, the two lines
/// under them, "Agree to rules", "Enter your answer", Submit and its two notes,
/// and the warning before closing on answers.
///
/// **Its layout is Discord's stylesheet** (`_b962dc`, `__0a749`, `_d48a51`):
/// the panel is a third of the width with the card centred on a gradient at a
/// third of its strength; each question sits 40 points under the last with its
/// title 12 above its control; the rules are a numbered list in a rounded well
/// with the checkbox 16 below it; the footer puts Submit on the right and the
/// notes on the left.
struct JoinApplicationSheet: View {
    var request: JoinApplicationRequest

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    @State private var phase = Phase.loading
    @State private var application: JoinApplication?
    /// The rules with their markdown resolved, parsed once when the form lands.
    @State private var rules: [AttributedString] = []
    @State private var isSubmitting = false
    @State private var failure: String?
    @State private var isConfirmingClose = false
    /// The verification row, decided once when the form lands — Discord's
    /// `useRef`: a reader verified when the form opened is never shown one, and
    /// one who verifies while it is open keeps the row and watches it tick.
    @State private var verificationRow: AccountVerification.Requirement?

    enum Phase: Equatable {
        case loading
        case failed
        case ready
    }

    private static let panelWidth: CGFloat = 360

    var body: some View {
        HStack(spacing: 0) {
            panel
                .frame(width: Self.panelWidth)
            VStack(spacing: 0) {
                ScrollView {
                    content
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.horizontal, Spacing.group)
                        .padding(.top, 52)
                        .padding(.bottom, Spacing.group)
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                if phase == .ready { footer }
            }
        }
        .frame(width: 920)
        .frame(minHeight: 480, idealHeight: 640, maxHeight: 760)
        .background(Palette.surface)
        .overlay(alignment: .topTrailing) { closeButton }
        // Answers typed are not thrown away by a stray Escape — the close
        // button asks first, as Discord's does.
        .interactiveDismissDisabled(application?.hasProgress == true)
        .alert("Are you sure? Your progress will be lost.", isPresented: $isConfirmingClose) {
            Button("Close Anyway", role: .destructive, action: close)
            Button("Cancel", role: .cancel) {}
        }
        .task(id: request) { await load() }
    }

    // MARK: The panel

    /// The server's card on a wash of its own colour.
    private var panel: some View {
        let card = model.joinApplicationCard(for: request.guildID, outsider: application?.form.guild)
        let colour = card.bannerColor ?? GuildBannerArt.defaultColour(isLight: colorScheme == .light)
        return ZStack {
            // Discord's `-45deg` gradient at a third of its strength: the
            // server's colour in the upper left, the subtle border colour at
            // the lower right.
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: colour), Palette.hairlineHovered],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .opacity(0.33)
            GuildProfileCard(profile: card, openGuild: { _ in }, showsEntry: false)
                .background(Palette.surfaceRaised)
                .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
                .specularEdge(in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .padding(.vertical, Spacing.base)
        .padding(.horizontal, Spacing.margin)
    }

    // MARK: The form

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 240)
        case .failed:
            Text("Oops, something went wrong...")
                .font(.system(.body))
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, minHeight: 240)
        case .ready:
            if let application {
                VStack(alignment: .leading, spacing: 0) {
                    heading(application.form)
                    if let verificationRow {
                        VerificationRequirementRow(
                            requirement: verificationRow,
                            isMet: model.accountVerification?.meets(verificationRow) ?? false,
                            resend: { await model.sessionController.resendVerificationEmail() }
                        )
                        .padding(.top, 40)
                    }
                    ForEach(application.form.fields) { field in
                        question(field)
                            .padding(.top, 40)
                    }
                }
            }
        }
    }

    private func heading(_ form: MemberVerification) -> some View {
        let name = model.joinApplicationCard(for: request.guildID, outsider: form.guild).name
        return VStack(alignment: .leading, spacing: Spacing.base) {
            Group {
                if form.asksQuestions {
                    Text("Answer a few questions to join \(Text(name).bold())")
                } else {
                    Text("Before you can talk here...")
                }
            }
            .font(.system(.title))
            .foregroundStyle(Ink.primary)
            .fixedSize(horizontal: false, vertical: true)
            Text(form.asksQuestions
                ? "The server admin will get back to you shortly after you submit."
                : "You\u{2019}ll need to complete the required steps below.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func question(_ field: JoinApplicationForm.Field) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(field.kind.isTerms ? "Agree to rules" : field.label)
                .font(.system(.body))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            switch field.kind {
            case .terms:
                rulesWell
                Toggle("I have read and agree to the rules", isOn: agreement(field))
                    .toggleStyle(.checkbox)
                    .padding(.top, Spacing.tight)
            case .textInput:
                TextField("Enter your answer", text: text(field))
                    .textFieldStyle(.plain)
                    .fieldWell()
            case .paragraph:
                TextField("Enter your answer", text: text(field), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(3...10)
                    .fieldWell()
                    .overlay(alignment: .bottomTrailing) {
                        // Discord's remaining count, in the corner of the box.
                        Text("\(JoinApplication.paragraphLimit - currentText(field).count)")
                            .font(.system(.caption2).monospacedDigit())
                            .foregroundStyle(Ink.tertiary)
                            .padding(Spacing.tight)
                            .accessibilityLabel(Text("Characters left"))
                    }
            case .multipleChoice(let choices):
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        RadioChoice(title: choice, isSelected: chosen(field) == index) {
                            application?.answers[field.id] = .choice(index)
                        }
                    }
                }
                .fieldWell()
            case .unrecognised:
                // A kind this client has never seen: its label, and nothing
                // to answer it with — the server would not take a guess.
                EmptyView()
            }
        }
    }

    /// The rules, numbered, in a rounded well — `termsFieldBody`.
    private var rulesWell: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                if index > 0 { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1).")
                        .foregroundStyle(Ink.tertiary)
                        .monospacedDigit()
                    Text(rule)
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.body))
                .padding(.horizontal, Spacing.tight)
                .padding(.top, index == 0 ? Spacing.base : Spacing.margin)
                .padding(.bottom, index == rules.count - 1 ? Spacing.base : Spacing.margin)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: The footer

    /// Submit on the right; on the left, what went wrong or Discord's two
    /// notes for an application.
    private var footer: some View {
        HStack(alignment: .center, spacing: Spacing.margin) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if let failure {
                    Text(failure)
                        .foregroundStyle(Palette.destructive)
                } else if application?.form.asksQuestions == true {
                    Text("Make sure you have not entered your password or any other sensitive information.")
                    Text("By applying, you give the server admins permission to message you regarding your application.")
                }
            }
            .font(.system(.caption))
            .foregroundStyle(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            let isComplete = application?.isComplete == true && meetsVerification
            Button(action: submit) {
                ZStack {
                    Text("Submit").opacity(isSubmitting ? 0 : 1)
                    if isSubmitting { ProgressView().controlSize(.small) }
                }
                .font(.system(.body, weight: .semibold))
                .padding(.horizontal, Spacing.group)
                .frame(height: Metrics.composerControlHeight)
                .background(Palette.accent.opacity(isComplete ? 1 : 0.45), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(!isComplete || isSubmitting)
            .keyboardShortcut(.return, modifiers: .command)
            // Discord's tooltip over the disabled button names what is missing.
            .help(isComplete ? "" : (application?.incompleteMessage ?? ""))
        }
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.margin)
        .overlay(alignment: .top) { Divider() }
    }

    private var closeButton: some View {
        Button(action: requestClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: Metrics.control, height: Metrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.secondary)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel(Text("Close"))
        .padding(Spacing.margin)
    }

    /// Discord's submit gate (`eS`): the server's level asks for an e-mail or
    /// a phone, and the form waits for it. **An account whose state this
    /// client never heard is not held back** — a gate on an unknown is a
    /// form nobody can send.
    private var meetsVerification: Bool {
        guard let requirement = requirement(for: application?.form),
              let verification = model.accountVerification
        else { return true }
        return verification.meets(requirement)
    }

    /// What this server asks of an account: its own level where the reader is
    /// in it, else the one the form's `with_guild` answer carried — the order
    /// Discord's `Q` reads them in.
    private func requirement(for form: MemberVerification?) -> AccountVerification.Requirement? {
        let level = model.guilds[request.guildID]?.verificationLevel ?? form?.guild?.verificationLevel
        return level.flatMap(AccountVerification.requirement(for:))
    }

    // MARK: Answers

    private func agreement(_ field: JoinApplicationForm.Field) -> Binding<Bool> {
        Binding(
            get: {
                if case .agreed(let agreed)? = application?.answers[field.id] { return agreed }
                return false
            },
            set: { application?.answers[field.id] = .agreed($0) }
        )
    }

    private func text(_ field: JoinApplicationForm.Field) -> Binding<String> {
        Binding(
            get: { currentText(field) },
            set: { application?.answers[field.id] = .text(JoinApplication.clamped($0, for: field.kind)) }
        )
    }

    private func currentText(_ field: JoinApplicationForm.Field) -> String {
        if case .text(let text)? = application?.answers[field.id] { return text }
        return ""
    }

    private func chosen(_ field: JoinApplicationForm.Field) -> Int? {
        if case .choice(let index)? = application?.answers[field.id] { return index }
        return nil
    }

    // MARK: Acts

    private func load() async {
        phase = .loading
        do {
            let form = try await model.sessionController.joinApplicationForm(
                request.guildID,
                inviteCode: request.inviteCode
            )
            rules = form.rules.map(Self.attributed)
            application = JoinApplication(form: form)
            if let requirement = requirement(for: form),
               model.accountVerification?.meets(requirement) == false
            {
                verificationRow = requirement
            }
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    private func submit() {
        guard let application, application.isComplete, !isSubmitting else { return }
        isSubmitting = true
        failure = nil
        Task {
            let refusal = await model.sessionController.submitJoinApplication(application)
            isSubmitting = false
            if let refusal {
                failure = refusal
            } else {
                close()
            }
        }
    }

    private func requestClose() {
        if application?.hasProgress == true, !isSubmitting {
            isConfirmingClose = true
        } else {
            close()
        }
    }

    private func close() {
        model.joinApplicationRequest = nil
    }

    /// A rule's `**bold**` and links resolved; the plain sentence where the
    /// markdown does not parse — a rule with asterisks in it is still a rule.
    nonisolated private static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

private extension View {
    /// The box a written answer sits in, the moderation reason field's.
    func fieldWell() -> some View {
        padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip))
            .specularEdge(in: RoundedRectangle(cornerRadius: Radius.chip))
    }
}

/// The form's verification row (`823591`'s `ei` and `ed`): what the server's
/// level asks for, whether the account has it, and the way to get it.
///
/// **The e-mail row can act; the phone row cannot.** Discord's phone Verify
/// opens its phone-number flow — a number, an SMS code, sometimes a captcha —
/// none of which has been watched on the wire, so it is left out the way the
/// account page leaves out its security writes. The row still says what the
/// server asks, which is why Submit waits.
private struct VerificationRequirementRow: View {
    var requirement: AccountVerification.Requirement
    var isMet: Bool
    var resend: () async -> Bool

    /// Discord's three states for the button: Verify, "Email sent!" for two
    /// seconds, then Resend Email.
    @State private var isSending = false
    @State private var showsSent = false
    @State private var hasSent = false

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.snug) {
            Image(symbol: isMet ? "checkmark" : (requirement == .email ? "envelope.fill" : "iphone"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isMet ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.secondary))
                .frame(width: 32, height: 32)
                .background(isMet ? AnyShapeStyle(Palette.affirmative) : AnyShapeStyle(Palette.surfaceRaised), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Ink.primary)
                Text("Your email and phone number will not be shared with the community staff.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if requirement == .email, !isMet {
                emailButton
            }
        }
        .padding(Spacing.snug)
        .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch requirement {
        case .email: isMet ? "Email Verified" : "Verify your email."
        case .phone: isMet ? "Phone Verified" : "Verify your phone number."
        }
    }

    @ViewBuilder
    private var emailButton: some View {
        if showsSent {
            Text("Email sent!")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Palette.affirmative)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    showsSent = false
                }
        } else {
            Button {
                Task {
                    isSending = true
                    if await resend() {
                        hasSent = true
                        showsSent = true
                    }
                    isSending = false
                }
            } label: {
                ZStack {
                    Text(hasSent ? "Resend Email" : "Verify").opacity(isSending ? 0 : 1)
                    if isSending { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .disabled(isSending)
        }
    }
}
