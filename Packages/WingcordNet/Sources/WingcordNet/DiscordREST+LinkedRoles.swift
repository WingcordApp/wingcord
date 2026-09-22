import Foundation
import WingcordCore

// MARK: - Linked roles
//
// Captured in `serveroptions + privacy.har`, 2026-09-22. Three routes, and the
// first two answer the **same shape** — a list of rule groups — which is why
// one decoder serves both: the eligibility route adds a `result` to each rule
// and changes nothing else.
//
//     GET /guilds/574217343635554305/roles/connections-configurations
//     → [{"role_id":"1095793942177513493","rules":[[
//          {"connection_type":"steam","connection_metadata_field":null,
//           "operator":null,"value":null},
//          {"connection_type":"steam","connection_metadata_field":"created_at",
//           "operator":4,"value":"29"}]],"applications":{}}]
//
//     GET /guilds/574217343635554305/roles/1095793942177513493/connections/eligibility
//     → [[{…,"result":false},{…,"result":false}]]

extension DiscordREST {

    /// Every linked role in a server, and what each one requires.
    ///
    /// **An empty array is the answer for most servers**, not a failure: a
    /// server with no linked roles has no configuration, and the menu's row is
    /// drawn from this being non-empty.
    public func linkedRoles(inGuild guildID: GuildID) async throws -> [LinkedRole] {
        try await get(
            "/guilds/\(guildID.rawValue)/roles/connections-configurations",
            route: "guilds/{id}/roles/connections-configurations",
            as: [LinkedRoleConfigurationDTO].self
        ).compactMap(\.domain)
    }

    /// The same rules for one role, each measured against this account.
    ///
    /// The route answers the groups alone — no role id, because the role is in
    /// the path — so the caller pairs them back up.
    public func linkedRoleEligibility(
        _ roleID: RoleID,
        inGuild guildID: GuildID
    ) async throws -> [[RoleConnectionRule]] {
        try await get(
            "/guilds/\(guildID.rawValue)/roles/\(roleID.rawValue)/connections/eligibility",
            route: "guilds/{id}/roles/{role}/connections/eligibility",
            as: [[RoleConnectionRuleDTO]].self
        ).map { $0.map(\.domain) }
    }

    /// Takes the role, once the account qualifies.
    ///
    /// **The body is empty and the answer is nothing.** Discord's own client
    /// posts and re-reads; so does this — `GUILD_MEMBER_UPDATE` is what actually
    /// puts the role on, and a client that added it optimistically would be
    /// inventing a grant the server may refuse.
    public func assignLinkedRole(_ roleID: RoleID, inGuild guildID: GuildID) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/roles/\(roleID.rawValue)/connections/assign",
            route: "guilds/{id}/roles/{role}/connections/assign",
            body: Optional<Never>.none
        )
    }

    /// Gives it back.
    public func unassignLinkedRole(_ roleID: RoleID, inGuild guildID: GuildID) async throws {
        _ = try await requestData(
            method: "POST",
            path: "/guilds/\(guildID.rawValue)/roles/\(roleID.rawValue)/connections/unassign",
            route: "guilds/{id}/roles/{role}/connections/unassign",
            body: Optional<Never>.none
        )
    }
}

// MARK: - The wire

struct LinkedRoleConfigurationDTO: Decodable, Sendable {
    var role_id: RoleID?
    var rules: [[RoleConnectionRuleDTO]]?

    var domain: LinkedRole? {
        guard let role_id else { return nil }
        return LinkedRole(id: role_id, groups: (rules ?? []).map { $0.map(\.domain) })
    }
}

struct RoleConnectionRuleDTO: Decodable, Sendable {
    var connection_type: String?
    var connection_metadata_field: String?
    var application_id: ApplicationID?
    var `operator`: Int?
    /// **A string on the wire whatever it holds** — `"29"` for a day count,
    /// `"1"` for a boolean. Typed as one here rather than guessed at: a decoder
    /// that expected a number would drop the whole rule on a field that is a
    /// name, and a dropped rule reads as a requirement that does not exist.
    var value: String?
    /// Only the eligibility route sends it.
    var result: Bool?

    var domain: RoleConnectionRule {
        RoleConnectionRule(
            // A rule with no type is not a rule this client can name a platform
            // for; the empty string draws the fallback mark rather than
            // vanishing, which is what §5.5 asks for.
            connectionType: connection_type ?? "",
            connectionMetadataField: connection_metadata_field,
            applicationID: application_id,
            operatorValue: `operator`,
            value: value,
            isMet: result
        )
    }
}

extension RoleConnectionRule {
    /// The wire's own spelling, so the DTO reads like the capture.
    fileprivate init(
        connectionType: String,
        connectionMetadataField: String?,
        applicationID: ApplicationID?,
        operatorValue: Int?,
        value: String?,
        isMet: Bool?
    ) {
        self.init(
            connectionType: connectionType,
            metadataField: connectionMetadataField,
            applicationID: applicationID,
            op: operatorValue.flatMap(RoleConnectionOperator.init(rawValue:)),
            value: value,
            isMet: isMet
        )
    }
}
