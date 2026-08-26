import Foundation

/// A guild role.
public struct Role: Hashable, Sendable, Identifiable, Codable {
    public var id: RoleID
    public var name: String
    /// Discord's 24-bit colour integer. **Zero means "no colour", not black**,
    /// and collapsing the two paints every uncoloured member's name pure black
    /// on a near-black ground. `displayColor` is the only place that decision is
    /// made.
    public var colorValue: UInt32
    /// Whether members with this role are grouped separately in the member list.
    public var isHoisted: Bool
    /// Higher is more senior. The highest *coloured* role a member holds decides
    /// their name colour; the highest role overall decides their rank.
    public var position: Int
    public var permissions: Permissions
    public var isManaged: Bool
    public var isMentionable: Bool
    public var iconHash: String?
    public var unicodeEmoji: String?

    public init(
        id: RoleID,
        name: String,
        colorValue: UInt32 = 0,
        isHoisted: Bool = false,
        position: Int = 0,
        permissions: Permissions = [],
        isManaged: Bool = false,
        isMentionable: Bool = false,
        iconHash: String? = nil,
        unicodeEmoji: String? = nil
    ) {
        self.id = id
        self.name = name
        self.colorValue = colorValue
        self.isHoisted = isHoisted
        self.position = position
        self.permissions = permissions
        self.isManaged = isManaged
        self.isMentionable = isMentionable
        self.iconHash = iconHash
        self.unicodeEmoji = unicodeEmoji
    }

    /// Nil when the role sets no colour. Every renderer takes the nil branch and
    /// falls back to the default text colour; none of them re-derives the
    /// zero test, because four independent copies of that test is how one of
    /// them ends up missing the guard.
    public var displayColorValue: UInt32? {
        colorValue == 0 ? nil : colorValue
    }

    /// Seniority order: highest position first, ties broken on id ascending,
    /// which is Discord's own rule for two roles created at the same position.
    public static func seniorityOrder(_ lhs: Role, _ rhs: Role) -> Bool {
        lhs.position != rhs.position
            ? lhs.position > rhs.position
            : lhs.id.rawValue < rhs.id.rawValue
    }
}

/// A member of a guild: the account, plus everything true only inside that
/// guild.
public struct Member: Hashable, Sendable, Codable {
    public var userID: UserID
    /// The per-guild nickname. Beats `User.preferredName` wherever this guild is
    /// the context.
    public var nickname: String?
    /// A per-guild avatar override.
    public var avatarHash: String?
    public var roleIDs: [RoleID]
    public var joinedAt: Date?
    /// Boosting since, or nil.
    public var premiumSince: Date?
    /// Timed-out until, or nil. A past date is not a timeout.
    public var communicationDisabledUntil: Date?
    public var isPending: Bool

    public init(
        userID: UserID,
        nickname: String? = nil,
        avatarHash: String? = nil,
        roleIDs: [RoleID] = [],
        joinedAt: Date? = nil,
        premiumSince: Date? = nil,
        communicationDisabledUntil: Date? = nil,
        isPending: Bool = false
    ) {
        self.userID = userID
        self.nickname = nickname
        self.avatarHash = avatarHash
        self.roleIDs = roleIDs
        self.joinedAt = joinedAt
        self.premiumSince = premiumSince
        self.communicationDisabledUntil = communicationDisabledUntil
        self.isPending = isPending
    }

    public func isTimedOut(now: Date = .now) -> Bool {
        guard let communicationDisabledUntil else { return false }
        return communicationDisabledUntil > now
    }

    /// What to call this person in this guild.
    public func resolvedName(user: User?) -> String {
        if let nickname, !nickname.isEmpty { return nickname }
        return user?.preferredName ?? "Unknown"
    }
}

/// Resolves a member's name colour and hoist group.
///
/// **Never resolve this by filtering the guild's whole role table per row.** A
/// guild with 250 roles and 500 visible members is 125,000 comparisons per
/// roster evaluation, and the roster re-evaluates on every presence flush. The
/// caller holds a `[RoleID: Role]` map and this walks only the member's own
/// roles — typically two or three.
public enum RoleResolver {

    /// The highest-positioned role the member holds that satisfies `predicate`.
    public static func topRole(
        of memberRoleIDs: [RoleID],
        in roles: [RoleID: Role],
        where predicate: (Role) -> Bool
    ) -> Role? {
        var best: Role?
        for roleID in memberRoleIDs {
            guard let role = roles[roleID], predicate(role) else { continue }
            if let current = best, !Role.seniorityOrder(role, current) { continue }
            best = role
        }
        return best
    }

    /// The colour a member's name is drawn in, or nil for the default.
    ///
    /// The highest role *with a colour* — which is not necessarily the highest
    /// role. A senior colourless role does not blank out a junior coloured one.
    public static func nameColorValue(
        of memberRoleIDs: [RoleID],
        in roles: [RoleID: Role]
    ) -> UInt32? {
        topRole(of: memberRoleIDs, in: roles) { $0.displayColorValue != nil }?
            .displayColorValue
    }

    /// The role a member is grouped under in the member list, or nil for the
    /// ungrouped section. The highest role *with hoist set*, by the same rule.
    public static func hoistRole(
        of memberRoleIDs: [RoleID],
        in roles: [RoleID: Role]
    ) -> Role? {
        topRole(of: memberRoleIDs, in: roles) { $0.isHoisted }
    }
}
