import AppKit
import Foundation
import WingcordCore

/// A switch under way: who to, for the veil, and which one, for what's waiting on it.
struct AccountSwitch: Equatable {
    var target: StoredAccount
    var serial: UInt64
    /// What the veil says: a switch, or a sign-in landing (docs/LOGIN-ONBOARDING.md D11).
    var kind: Kind = .switching

    enum Kind: Equatable {
        case switching
        case signingIn
    }

    /// How long the veil takes to cover the window, before anything's let go of.
    static let veilIn: TimeInterval = 0.24
    /// How long it stays up at the least, so a fast switch isn't a flicker.
    static let veilAtLeast: TimeInterval = 0.8
    /// Nothing leaves it up for longer than this.
    static let timeout: TimeInterval = 25
}

/// What a switch would end.
enum AccountSwitchLoss: Hashable {
    case call
    case voiceNote
    case upload
}

/// A switch that'd cost something, asked about first.
///
/// **Only then.** Most switches lose nothing, and a card in front of each would be a
/// question with one answer. Discord just drops these.
struct AccountSwitchPrompt: Equatable {
    var target: StoredAccount
    var losses: [AccountSwitchLoss]

    /// What it says it'll cost, in a sentence.
    var message: String {
        let parts = losses.map { loss in
            switch loss {
            case .call: "you'll leave your call"
            case .voiceNote: "your voice message will be discarded"
            case .upload: "the file you're sending will be cancelled"
            }
        }
        let joined: String = switch parts.count {
        case 0: ""
        case 1: parts[0]
        case 2: "\(parts[0]) and \(parts[1])"
        default: parts.dropLast().joined(separator: ", ") + " and \(parts[parts.count - 1])"
        }
        return "If you switch to \(target.preferredName), \(joined)."
    }
}

extension AppModel {
    /// Reads the list again, after anything that changes it. Nothing else reads the
    /// ledger, because that asks the Keychain.
    func reloadAccounts() {
        let fresh = AccountLedger.accounts()
        if fresh != storedAccounts { storedAccounts = fresh }
    }

    /// A switch that didn't happen, which left everything where it was.
    func reportAccountProblem(_ text: String) {
        reportActionFailure(text)
    }

    /// What a switch right now would end.
    var accountSwitchLosses: [AccountSwitchLoss] {
        var losses: [AccountSwitchLoss] = []
        if connectedVoiceChannelID != nil { losses.append(.call) }
        if voiceRecorder.flow.phase != .idle { losses.append(.voiceNote) }
        let isSending = messageBoxes.values.contains { box in
            box.outbox.contains { !$0.files.isEmpty && $0.state == .sending }
        }
        if isSending { losses.append(.upload) }
        return losses
    }

    /// A press on an account's row, wherever it's drawn.
    func requestAccountSwitch(to account: StoredAccount) {
        guard account.id != currentUserID?.description, accountSwitch == nil else { return }
        // Nothing to switch to until it's signed in again.
        if account.isSessionExpired {
            profileRequest = nil
            presentAddAccount()
            return
        }
        let losses = accountSwitchLosses
        guard losses.isEmpty else {
            // The request first, then the dismissal: `INVARIANTS.md` §5.
            accountSwitchPrompt = AccountSwitchPrompt(target: account, losses: losses)
            profileRequest = nil
            showWorkspaceForCard()
            return
        }
        sessionController.switchAccount(to: account)
    }

    /// Add an Account: Wingcord's own login, in a card over the app. `--demo` shows the
    /// same card with its scripted sign-in, which adds somebody it made up.
    func presentAddAccount() {
        isAddingAccount = true
        showWorkspaceForCard()
    }

    /// Asks about logging out of an account: this one, with no argument.
    ///
    /// **Asked, because it can't be taken back without a password and a code**, and the
    /// row's directly under Switch Accounts. Discord asks too.
    func requestLogOut(of account: StoredAccount? = nil) {
        guard let account = account ?? currentStoredAccount else {
            logOut()
            return
        }
        logOutPrompt = account
        profileRequest = nil
        showWorkspaceForCard()
    }

    /// The card's answer. The active account has the session to take down too.
    func confirmLogOut(of account: StoredAccount) {
        if account.id == currentUserID?.description {
            logOut()
        } else {
            AccountLedger.remove(account.id)
            reloadAccounts()
        }
    }

    /// **A card's drawn by the window it's in**, and these are the main window's. Asked for
    /// from Settings, a window of its own that may well cover it, they'd open behind where
    /// the reader's looking.
    private func showWorkspaceForCard() {
        guard NSApp.keyWindow !== MainWindow.workspaceWindow else { return }
        MainWindow.raise()
    }

    /// This account's entry, which a session that's come from nowhere might not have.
    var currentStoredAccount: StoredAccount? {
        storedAccounts.first { $0.id == currentUserID?.description }
    }
}
