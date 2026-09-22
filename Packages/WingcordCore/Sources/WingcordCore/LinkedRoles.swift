import Foundation

// MARK: - Linked Roles
//
// A role a server grants for something true about an account **somewhere else**
// — a Steam account older than thirty days, a Reddit account with enough karma,
// a bot's own record of how many hours somebody has played.
//
// Three routes, all captured in `serveroptions + privacy.har`:
//
//     GET  /guilds/{id}/roles/connections-configurations
//     GET  /guilds/{id}/roles/{role}/connections/eligibility
//     POST /guilds/{id}/roles/{role}/connections/assign      (and /unassign)
//
// The first answers every linked role in the server and what each one requires;
// the second answers the same rules for one role with a `result` on each; the
// third is the button that actually grants it.

/// How a rule compares the account's value against the server's.
///
/// **This is NOT `ApplicationRoleConnectionMetadataType`, and confusing the two
/// inverts every rule.** Discord's bundle declares both enums a few bytes apart:
/// the metadata *type* is `INTEGER_LESS_THAN_EQUAL = 1 … BOOLEAN_NOT_EQUAL = 8`
/// and describes what an application's own field holds, while this — the
/// `operator` on a rule — is its own four-case enum. The capture reads
/// `operator: 4` on a `created_at` rule that Discord renders as "Must have at
/// least 30 days old account", which is `GREATER_THAN` and is nonsense as
/// `INTEGER_NOT_EQUAL`.
public enum RoleConnectionOperator: Int, Hashable, Sendable {
    case equal = 1
    case notEqual = 2
    case lessThan = 3
    case greaterThan = 4

    public init?(rawValue: Int) {
        switch rawValue {
        case 1: self = .equal
        case 2: self = .notEqual
        case 3: self = .lessThan
        case 4: self = .greaterThan
        default: return nil
        }
    }
}

/// The metadata fields Discord itself computes, per platform.
///
/// **Lifted from the bundle's own table**, where every one of these is a
/// constant beside the platform it belongs to. An application's linked role uses
/// its *own* fields instead, whose names this client has never seen and cannot
/// have a table for — those fall back to the raw key, humanised.
public enum RoleConnectionField {
    /// Every platform has one, and it is the only field measured in **days
    /// before today** rather than in its own units.
    public static let createdAt = "created_at"

    /// One line naming what the field holds, for the platforms Discord computes
    /// these for. Nil for anything this table does not know, which is every
    /// application-defined field.
    public static func title(_ field: String, connectionType: String) -> String? {
        switch (connectionType, field) {
        case (_, createdAt): "Account age"
        case ("reddit", "total_karma"): "Total karma"
        case ("reddit", "gold"): "Reddit Gold"
        case ("reddit", "mod"): "Moderator"
        case ("bluesky", "followers_count"), ("tiktok", "follower_count"),
             ("twitter", "followers_count"):
            "Followers"
        case ("bluesky", "statuses_count"), ("twitter", "statuses_count"): "Posts"
        case ("steam", "game_count"): "Games owned"
        case ("steam", "item_count_tf2"): "Team Fortress 2 items"
        case ("steam", "item_count_dota2"): "Dota 2 items"
        case ("twitter", "verified"), ("paypal", "verified"), ("tiktok", "verified"):
            "Verified"
        case ("ebay", "positive_feedback_percentage"): "Positive feedback"
        case ("ebay", "top_rated_seller"): "Top rated seller"
        case ("ebay", "unique_negative_feedback_count"): "Negative feedback"
        case ("ebay", "unique_positive_feedback_count"): "Positive feedback count"
        case ("tiktok", "following_count"): "Following"
        default: nil
        }
    }
}

/// One condition a linked role puts on an account.
public struct RoleConnectionRule: Hashable, Sendable, Identifiable {
    /// The platform key — `"steam"`, `"reddit"` — or, for a role granted by a
    /// bot rather than by a platform, one of the two application sentinels.
    public var connectionType: String
    /// The field being compared. **Nil is the rule "you have this connection at
    /// all"**, which is the whole condition on most linked roles and is exactly
    /// how the capture's first rule arrives: type `steam`, everything else null.
    public var metadataField: String?
    /// The application whose own metadata this reads, when the rule is a bot's
    /// rather than a platform's.
    public var applicationID: ApplicationID?
    public var op: RoleConnectionOperator?
    /// Always a string on the wire, whatever it means — a count, a day count,
    /// or `"1"` for a boolean.
    public var value: String?
    /// Whether this account satisfies it. **Nil from the configuration route**,
    /// which describes the rule without measuring it; only the eligibility route
    /// answers this.
    public var isMet: Bool?

    public init(
        connectionType: String,
        metadataField: String? = nil,
        applicationID: ApplicationID? = nil,
        op: RoleConnectionOperator? = nil,
        value: String? = nil,
        isMet: Bool? = nil
    ) {
        self.connectionType = connectionType
        self.metadataField = metadataField
        self.applicationID = applicationID
        self.op = op
        self.value = value
        self.isMet = isMet
    }

    /// Stable across a refetch, so a list does not rebuild every row when the
    /// eligibility answer lands on top of the configuration.
    public var id: String {
        "\(connectionType)/\(metadataField ?? "")/\(op?.rawValue ?? 0)/\(value ?? "")"
    }

    /// Discord's two sentinel connection types for a role a **bot** grants.
    public static let applicationType = "application"
    public static let applicationIdentityType = "application_identity"

    public var isApplication: Bool {
        connectionType == Self.applicationType
            || connectionType == Self.applicationIdentityType
    }

    /// What the rule asks for, in one line.
    ///
    /// **This client's own words, not Discord's string table** — the same trade
    /// `OAuthScope.description` makes and for the same reason: the wire sends a
    /// field key, an operator and a number, never a sentence. What is reproduced
    /// exactly is the *arithmetic*, which is the part that can be wrong:
    /// `created_at` is counted in **days before today**, so `> 29` is "at least
    /// 30 days old" — which is the copy Discord's own modal drew beside this
    /// very rule in the capture.
    ///
    /// - Parameter platformName: what to call the platform, since this module
    ///   has no brand table — `BrandMark` owns that, in the app target.
    public func summary(platformName: String) -> String {
        guard let metadataField, let op else {
            return "Connect your \(platformName) account"
        }
        if metadataField == RoleConnectionField.createdAt {
            return ageSummary(op: op, platformName: platformName)
        }
        let name = RoleConnectionField.title(metadataField, connectionType: connectionType)
            ?? Self.humanised(metadataField)
        guard let value else { return name }
        // A boolean field is written as a comparison against 1, and a sentence
        // reading "Verified must be more than 1" is the arithmetic showing
        // through the words.
        if value == "1" || value == "0", op == .equal || op == .notEqual {
            let wants = (value == "1") == (op == .equal)
            return wants ? name : "Not \(name.lowercased())"
        }
        return switch op {
        case .equal: "\(name) is exactly \(value)"
        case .notEqual: "\(name) is not \(value)"
        case .lessThan: "\(name) under \(value)"
        case .greaterThan: "\(name) over \(value)"
        }
    }

    /// `created_at` is the one field measured in days before today, and the one
    /// whose comparison has to be turned inside out to read naturally.
    private func ageSummary(op: RoleConnectionOperator, platformName: String) -> String {
        guard let value, let days = Int(value) else { return "\(platformName) account age" }
        return switch op {
        // "older than N days" — the account was created more than N days ago —
        // is an account at least N + 1 days old, which is the sentence Discord
        // draws: value 29 under this operator rendered as "at least 30 days".
        case .greaterThan: "Must have at least \(days + 1) days old account"
        case .lessThan: "Account must be newer than \(days) days"
        case .equal: "Account must be exactly \(days) days old"
        case .notEqual: "Account must not be exactly \(days) days old"
        }
    }

    /// A field key this table has never seen still reads as something rather
    /// than as a raw identifier — an application defines its own and this client
    /// cannot have a name for them.
    private static func humanised(_ field: String) -> String {
        let words = field.split(separator: "_").map(String.init)
        guard let first = words.first else { return field }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }
}

/// One linked role, and what it takes.
///
/// **The rules are a list of lists and the nesting is the logic**: the outer
/// list is alternatives and the inner one is requirements — any group, all of
/// its rules. Discord's own modal says "You must verify **all** of the following
/// accounts", which is the inner list; a server that offered two ways in would
/// send two groups.
public struct LinkedRole: Hashable, Sendable, Identifiable {
    public var id: RoleID
    /// Each group is a set of rules that must **all** hold.
    public var groups: [[RoleConnectionRule]]

    public init(id: RoleID, groups: [[RoleConnectionRule]]) {
        self.id = id
        self.groups = groups
    }

    /// Every distinct platform this role reads, in the order it first names
    /// them — which is what the list row draws beside the role's name.
    public var connectionTypes: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for rule in groups.flatMap(\.self) where !rule.isApplication {
            guard seen.insert(rule.connectionType).inserted else { continue }
            result.append(rule.connectionType)
        }
        return result
    }

    /// Whether the account satisfies at least one whole group.
    ///
    /// **Nil until the eligibility route has answered.** A rule with no result
    /// has not been measured, and treating that as "not met" would draw every
    /// requirement red the moment a list appeared.
    public var isEligible: Bool? {
        let measured = groups.flatMap(\.self).compactMap(\.isMet)
        guard !measured.isEmpty else { return nil }
        return groups.contains { group in
            !group.isEmpty && group.allSatisfy { $0.isMet == true }
        }
    }
}
