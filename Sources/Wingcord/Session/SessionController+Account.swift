import Foundation
import WingcordCore
import WingcordNet

// MARK: - Account standing

extension SessionController {
    /// Loaded once and left alone — a moderation state does not change on
    /// its own between one look at Settings and the next, and refetching it
    /// on every appearance would ask a sensitive question nobody clicked to
    /// ask again.
    func loadAccountStanding() {
        guard model.accountStanding == nil, !accountStandingFetchInFlight else { return }
        accountStandingFetchInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { accountStandingFetchInFlight = false }
            do {
                model.accountStanding = try await rest.accountStanding()
            } catch {
                // Left absent, not guessed — see `AppModel.accountStanding`.
                Self.trace("account standing failed: \(Self.describe(error))")
            }
        }
    }

    /// The account's own e-mail, phone and second-factor state.
    ///
    /// **Fetched when the pane opens rather than kept from launch.** The token
    /// check at startup already calls this route, but it throws the extra fields
    /// away deliberately: an e-mail address and a phone number held for a whole
    /// session are two secrets in memory for a page most readers never open.
    func loadAccountDetails() async {
        guard model.accountDetails == nil else { return }
        do {
            let answer = try await rest.currentAccount()
            model.accountDetails = answer.details
            model.entitlements = model.entitlements.updated(
                premiumType: answer.account.premiumType,
                ageVerificationStatus: answer.account.ageVerificationStatus
            )
            if let verification = answer.account.verification { model.accountVerification = verification }
        } catch {
            Self.trace("account details failed: \(Self.describe(error))")
        }
    }

    /// Everywhere the account is signed in.
    ///
    /// **Absent and empty are different states** and the pane draws them
    /// differently: nil is "not asked yet or the route refused", `[]` is "one
    /// session, this one". Collapsing them would have a failed request read as
    /// "you are signed in nowhere", which on a security page is the wrong
    /// direction to be wrong in.
    func loadAuthSessions() async {
        guard model.authSessions == nil else { return }
        do {
            model.authSessions = try await rest.authSessions()
        } catch {
            Self.trace("auth sessions failed: \(Self.describe(error))")
        }
    }
}
