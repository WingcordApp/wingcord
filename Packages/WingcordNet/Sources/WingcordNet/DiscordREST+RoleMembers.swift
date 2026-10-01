import Foundation
import WingcordCore

// MARK: - Who holds a role
//
// What a click on a role mention asks, captured in `member ids and counts.har`:
// the role's members by id (the head counts are `roleMemberCounts(inGuild:)`).
// The members themselves are then asked for over the gateway by id — Discord's
// `requestMembersById` — because the route carries neither a name nor a face.

extension DiscordREST {

    /// The members holding a role, by id — at most a hundred, which is where
    /// Discord's own list stops and its "more" line takes over.
    public func roleMemberIDs(of roleID: RoleID, in guildID: GuildID) async throws -> [UserID] {
        try await get(
            "/guilds/\(guildID.rawValue)/roles/\(roleID.rawValue)/member-ids",
            route: "guilds/{id}/roles/{id}/member-ids",
            as: [UserID].self
        )
    }
}
