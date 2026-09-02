import Foundation
import WingcordCore

// MARK: - Account standing
//
// `GET /safety-hub/@me`. Undocumented, and every field below is what a live
// capture actually carried — see `SafetyHubDecodeTests`.

extension DiscordREST {
    /// `nil` only when the response carries no `account_standing.state` at
    /// all — every capture so far has, but a decode this defensive costs one
    /// `nil` check at the call site against a route this client has never
    /// seen documented.
    public func accountStanding() async throws -> AccountStanding? {
        try await get(
            "/safety-hub/@me",
            route: "safety-hub/@me",
            as: SafetyHubDTO.self
        ).domain
    }
}

struct SafetyHubDTO: Decodable, Sendable {
    var account_standing: StandingDTO?

    struct StandingDTO: Decodable, Sendable {
        var state: Int?
    }

    var domain: AccountStanding? {
        guard let wireValue = account_standing?.state else { return nil }
        return AccountStanding(state: .init(wireValue: wireValue))
    }
}
