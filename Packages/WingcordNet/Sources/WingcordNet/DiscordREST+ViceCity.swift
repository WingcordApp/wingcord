import Foundation

// MARK: - Discord's Vice City campaign ("Hexagon" in its bundle)
//
// `211824`: the campaign is a special event at
// `/quests/special-events/1549285425984831508/enroll`; joining it is what puts
// `SOURCE_HEXAGON_CAMPAIGN` on the account's display-name-style perk, and only
// then does `PATCH /users/@me` take the campaign's font (id 17) from an account
// without Nitro. Discord's client posts it with no body (`471865`'s `Br`).

extension DiscordREST {

    /// The campaign's special event.
    public static let viceCityEventID = "1549285425984831508"

    /// Joins the Vice City campaign.
    public func enrollInViceCityCampaign() async throws {
        struct NoBody: Encodable {}
        _ = try await requestData(
            method: "POST",
            path: "/quests/special-events/\(Self.viceCityEventID)/enroll",
            route: "quests/special-events/{id}/enroll",
            body: NoBody?.none
        )
    }
}
