import SwiftUI
import WingcordCore

/// "Choose an account": the saved accounts, when nobody's signed in and some
/// are on this Mac (D12) — usually because a session died and it needs its
/// password again.
struct AccountChooser: View {
    var accounts: [StoredAccount]
    var choose: (StoredAccount) -> Void
    var forget: (StoredAccount) -> Void
    var logInToAnother: () -> Void
    var sessionProblem: String?

    var body: some View {
        VStack(spacing: Spacing.group) {
            VStack(spacing: Spacing.base) {
                Text("Choose an account")
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .accessibilityAddTraits(.isHeader)
                Text("Pick up where you left off, or log in to another account.")
                    .font(.system(.title3))
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
            }

            if let sessionProblem {
                SignInNoticeView(notice: .failed(sessionProblem), openWebsite: {})
                    .frame(width: SignInStyle.columnWidth + 40)
            }

            VStack(spacing: Spacing.base) {
                ForEach(accounts) { account in
                    AccountChoiceRow(account: account, choose: { choose(account) }, forget: { forget(account) })
                }
            }
            .frame(width: SignInStyle.columnWidth + 40)

            Button("Log in to another account", systemImage: "plus") { logInToAnother() }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
        }
    }
}

/// One saved account. **A real button**, for `SignInView`'s old reason: the
/// first control anyone touches has to take the keyboard and speak to VoiceOver.
/// Forget sits outside it, since a button in a button is one button.
private struct AccountChoiceRow: View {
    var account: StoredAccount
    var choose: () -> Void
    var forget: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: choose) {
                HStack(spacing: Spacing.snug) {
                    AvatarView(url: account.avatarURL(side: 40), monogram: account.monogram, side: 40)
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(account.preferredName)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        Text(account.isSessionExpired ? "Session expired. Log in again." : "@\(account.username)")
                            .font(.system(.callout))
                            .foregroundStyle(account.isSessionExpired ? SignInStyle.error : Ink.secondary)
                    }
                    Spacer(minLength: Spacing.base)
                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(Ink.secondary)
                }
                .padding(.leading, Spacing.snug)
                .padding(.trailing, Spacing.base)
                .frame(height: 60)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(account.isSessionExpired
                                     ? "Log in again as \(account.preferredName)"
                                     : "Continue as \(account.preferredName)"))

            Button("Forget \(account.preferredName)", systemImage: "xmark", action: forget)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Ink.secondary)
                .frame(width: 36, height: 36)
                .contentShape(.rect)
                .padding(.trailing, Spacing.base)
                .help("Forget this account on this Mac")
        }
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Radius.glass + 4, style: .continuous))
    }
}
