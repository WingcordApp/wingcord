import SwiftUI
import WingcordCore

/// The accounts on this Mac: a picture, a name, and a tick on the current one.
///
/// **No status dot and no unread count.** An account that isn't connected has neither,
/// and a stale one would be a guess.
struct AccountSwitcherFlyout: View {
    var actions: OwnProfileActions

    static let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(actions.accounts) { account in
                let isCurrent = account.id == actions.userID.description
                AccountFlyoutRow(
                    account: account,
                    isCurrent: isCurrent,
                    isChecking: actions.checkingAccountID == account.id
                ) {
                    actions.switchAccount(account)
                }
                .contextMenu {
                    if !isCurrent {
                        Button("Log Out of \(account.preferredName)", role: .destructive) {
                            actions.logOutOfAccount(account)
                        }
                    }
                }
            }
            FlyoutDivider()
            if AccountList(actions.accounts).canAdd {
                FlyoutRow(title: "Add an Account", symbolName: "plus", act: actions.addAccount)
            }
            FlyoutRow(title: "Manage Accounts", symbolName: "gearshape", act: actions.manageAccounts)
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
        // **The window's light or dark, not the card's.** The card wears its profile's,
        // which this inherits, while the popover's glass is the window's: dark words
        // on dark glass, on a light profile in a dark room.
        .colorScheme(ThemeInk.current.isLight ? .light : .dark)
    }
}

/// One account in the flyout.
private struct AccountFlyoutRow: View {
    var account: StoredAccount
    var isCurrent: Bool
    var isChecking: Bool
    var act: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private static let picture: CGFloat = 28

    var body: some View {
        Button(action: act) {
            HStack(spacing: Spacing.snug) {
                AvatarView(
                    url: account.avatarURL(side: Self.picture),
                    monogram: account.monogram,
                    side: Self.picture
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.preferredName)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(InkColor.solid)
                        .lineLimit(1)
                    Text(account.isSessionExpired ? "Session expired. Log in again." : "@\(account.username)")
                        .font(.system(.caption))
                        .foregroundStyle(account.isSessionExpired ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.base)
                trailing
            }
            .padding(.horizontal, Spacing.snug)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(isHovering ? Palette.selectionFill : .clear)
                    .padding(.horizontal, Spacing.tight)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Not `.disabled`, which would dim the one row that says who you are.
        .allowsHitTesting(!isCurrent && !isChecking)
        .onHover { hovering in
            guard isHovering != hovering, !isCurrent else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .animation(motion.standard, value: isChecking)
        .animation(motion.standard, value: account.isSessionExpired)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    @ViewBuilder
    private var trailing: some View {
        if isChecking {
            ProgressView().controlSize(.small)
        } else if account.isSessionExpired {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.destructive)
        } else if isCurrent {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.accent)
        }
    }

    private var accessibilityLabel: String {
        if account.isSessionExpired { return "\(account.preferredName), session expired, log in again" }
        return isCurrent
            ? "\(account.preferredName), current account"
            : "Switch to \(account.preferredName), @\(account.username)"
    }
}
