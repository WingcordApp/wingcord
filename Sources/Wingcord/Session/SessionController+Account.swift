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
}
