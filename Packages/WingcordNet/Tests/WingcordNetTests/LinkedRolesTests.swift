import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Linked roles, against the two payloads Discord answered with.
///
/// **Captured 2026-09-22** in `serveroptions + privacy.har`, from the Linked
/// Roles modal of a server whose one linked role wants a Steam account at least
/// thirty days old. Both payloads are verbatim.
@Suite("Linked roles")
struct LinkedRolesTests {

    private static let guildID = GuildID(rawValue: 574_217_343_635_554_305)
    private static let roleID = RoleID(rawValue: 1_095_793_942_177_513_493)

    /// `GET /guilds/{id}/roles/connections-configurations`
    private let configuration = """
    [{"role_id":"1095793942177513493","rules":[[\
    {"connection_type":"steam","connection_metadata_field":null,"operator":null,"value":null},\
    {"connection_type":"steam","connection_metadata_field":"created_at","operator":4,\
    "value":"29"}]],"applications":{}}]
    """

    /// `GET /guilds/{id}/roles/{role}/connections/eligibility` — the same rules
    /// with a `result` on each, and **no role id**, because the role is in the
    /// path.
    private let eligibility = """
    [[{"connection_type":"steam","connection_metadata_field":null,"operator":null,\
    "value":null,"result":false},{"connection_type":"steam",\
    "connection_metadata_field":"created_at","operator":4,"value":"29","result":false}]]
    """

    private func roles() throws -> [LinkedRole] {
        try JSONDecoder()
            .decode([LinkedRoleConfigurationDTO].self, from: Data(configuration.utf8))
            .compactMap(\.domain)
    }

    @Test("The configuration decodes to one role with two rules in one group")
    func configurationDecodes() throws {
        let roles = try roles()
        #expect(roles.count == 1)
        let role = try #require(roles.first)
        #expect(role.id == Self.roleID)
        #expect(role.groups.count == 1)
        #expect(role.groups.first?.count == 2)
        #expect(role.connectionTypes == ["steam"])
    }

    /// **The first rule of every linked role is "you have this connection".**
    /// Field, operator and value all null, and a decoder that required them
    /// would drop the only rule most linked roles have.
    @Test("A rule with no field is the connection itself")
    func bareRuleIsTheConnection() throws {
        let rule = try #require(try roles().first?.groups.first?.first)
        #expect(rule.connectionType == "steam")
        #expect(rule.metadataField == nil)
        #expect(rule.op == nil)
        #expect(rule.summary(platformName: "Steam") == "Connect your Steam account")
    }

    /// **`operator: 4` is `GREATER_THAN`, not `INTEGER_NOT_EQUAL`.** Discord
    /// declares two enums a few bytes apart in its own bundle and only one of
    /// them belongs to a rule; read as the other, this rule becomes "account age
    /// is not 29" and the sentence beside it is nonsense.
    ///
    /// The expected string is the copy Discord's own modal drew beside this very
    /// rule in the capture — `created_at` is counted in days before today, so
    /// "more than 29" is an account at least thirty days old.
    @Test("The captured Steam rule reads the way Discord renders it")
    func steamAgeRule() throws {
        let rule = try #require(try roles().first?.groups.first?.last)
        #expect(rule.metadataField == RoleConnectionField.createdAt)
        #expect(rule.op == .greaterThan)
        #expect(rule.value == "29")
        #expect(
            rule.summary(platformName: "Steam") == "Must have at least 30 days old account"
        )
    }

    @Test("Eligibility answers the same rules with a result on each")
    func eligibilityDecodes() throws {
        let groups = try JSONDecoder()
            .decode([[RoleConnectionRuleDTO]].self, from: Data(eligibility.utf8))
            .map { $0.map(\.domain) }
        #expect(groups.count == 1)
        #expect(groups.first?.count == 2)
        #expect(groups.first?.allSatisfy { $0.isMet == false } == true)
    }

    /// The rule's identity has to survive the two payloads, or merging the
    /// eligibility onto the configuration pairs nothing up.
    @Test("A rule keeps its identity between the two routes")
    func ruleIdentityMatches() throws {
        let configured = try #require(try roles().first?.groups.first)
        let measured = try JSONDecoder()
            .decode([[RoleConnectionRuleDTO]].self, from: Data(eligibility.utf8))
            .map { $0.map(\.domain) }
        #expect(configured.map(\.id) == (measured.first ?? []).map(\.id))
    }

    // MARK: What a role's state is

    @Test("A role nobody has measured is neither eligible nor refused")
    func unmeasuredRoleIsUnknown() throws {
        #expect(try roles().first?.isEligible == nil)
    }

    @Test("A role is eligible only when a whole group holds")
    func eligibilityNeedsEveryRuleInAGroup() {
        func role(_ results: [Bool]) -> LinkedRole {
            LinkedRole(
                id: Self.roleID,
                groups: [
                    results.enumerated().map { index, isMet in
                        RoleConnectionRule(
                            connectionType: "steam",
                            metadataField: "field\(index)",
                            op: .greaterThan,
                            value: "1",
                            isMet: isMet
                        )
                    }
                ]
            )
        }
        #expect(role([true, true]).isEligible == true)
        #expect(role([true, false]).isEligible == false)
        #expect(role([false, false]).isEligible == false)
    }

    /// Two groups are alternatives: either one, whole, is enough.
    @Test("Alternatives are satisfied by one group")
    func alternativeGroups() {
        let met = RoleConnectionRule(connectionType: "steam", metadataField: "a", isMet: true)
        let unmet = RoleConnectionRule(connectionType: "reddit", metadataField: "b", isMet: false)
        #expect(LinkedRole(id: Self.roleID, groups: [[unmet], [met]]).isEligible == true)
        #expect(LinkedRole(id: Self.roleID, groups: [[unmet], [unmet]]).isEligible == false)
    }

    // MARK: The sentences

    @Test("A boolean rule reads as a state, not as a comparison")
    func booleanRuleReadsPlainly() {
        let verified = RoleConnectionRule(
            connectionType: "paypal", metadataField: "verified", op: .equal, value: "1"
        )
        #expect(verified.summary(platformName: "PayPal") == "Verified")

        let unverified = RoleConnectionRule(
            connectionType: "paypal", metadataField: "verified", op: .notEqual, value: "1"
        )
        #expect(unverified.summary(platformName: "PayPal") == "Not verified")
    }

    @Test("A counted rule names the field and the threshold")
    func countedRule() {
        let games = RoleConnectionRule(
            connectionType: "steam", metadataField: "game_count", op: .greaterThan, value: "50"
        )
        #expect(games.summary(platformName: "Steam") == "Games owned over 50")
    }

    /// An application defines its own metadata and this client has never seen
    /// the keys. A rule it cannot name still has to say something.
    @Test("An unknown field is humanised rather than dropped")
    func unknownFieldStillReads() {
        let rule = RoleConnectionRule(
            connectionType: "application",
            metadataField: "hours_played",
            op: .greaterThan,
            value: "100"
        )
        #expect(rule.summary(platformName: "The app") == "Hours played over 100")
        #expect(rule.isApplication)
    }

    /// A role granted by a bot has no platform to send anybody to, so the list
    /// row must not offer its marks either.
    @Test("An application rule contributes no platform mark")
    func applicationRulesHaveNoMark() {
        let role = LinkedRole(
            id: Self.roleID,
            groups: [[
                RoleConnectionRule(connectionType: "application_identity"),
                RoleConnectionRule(connectionType: "steam"),
            ]]
        )
        #expect(role.connectionTypes == ["steam"])
    }

    @Test("An operator Discord adds later is read as no operator, never as one")
    func unknownOperatorIsNil() {
        #expect(RoleConnectionOperator(rawValue: 9) == nil)
        #expect(RoleConnectionOperator(rawValue: 0) == nil)
        #expect(RoleConnectionOperator(rawValue: 4) == .greaterThan)
    }
}
