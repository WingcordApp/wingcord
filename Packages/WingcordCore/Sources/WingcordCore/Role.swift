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
    /// The role's own short description, on the roles page only.
    public var description: String?
    /// The gradient, where the server has `ENHANCED_ROLE_COLORS`.
    ///
    /// **Carried even though nothing draws it yet**, because the role editor
    /// writes the whole role back — every captured `PATCH /roles/{id}` sends
    /// `color` *and* `colors` — and a client that decoded only `colorValue`
    /// would flatten somebody's three-stop gradient to its first stop the
    /// moment they renamed the role. Round-tripping a field you do not render
    /// is much cheaper than losing somebody's data.
    public var colors: RoleColors?
    /// Discord's role flags. `1 << 0` marks a role selectable in onboarding.
    public var flags: Int

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
        unicodeEmoji: String? = nil,
        description: String? = nil,
        colors: RoleColors? = nil,
        flags: Int = 0
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
        self.description = description
        self.colors = colors
        self.flags = flags
    }

    /// Whether this is the server's `@everyone` role.
    ///
    /// **The id equals the guild's**, which is Discord's own convention and the
    /// only reliable test — the name is localised and can be changed.
    public func isEveryone(in guildID: GuildID) -> Bool {
        id.rawValue == guildID.rawValue
    }

    /// Whether the roles page may offer to edit or delete this role.
    ///
    /// A managed role belongs to an integration — a bot's own role, a Twitch
    /// subscriber role, a boost role — and Discord refuses both. `INVARIANTS.md`
    /// §5.5: a control that cannot work must not look like one that can.
    public var isEditable: Bool { !isManaged }

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

/// A role's up-to-three colour stops.
///
/// Discord sends this beside the deprecated flat `color`, and sends **both** on
/// every write. `primary` duplicates `color` on a solid role; a gradient sets
/// the second and third.
public struct RoleColors: Hashable, Sendable, Codable {
    public var primary: UInt32
    public var secondary: UInt32?
    public var tertiary: UInt32?

    public init(primary: UInt32, secondary: UInt32? = nil, tertiary: UInt32? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
    }

    /// Whether the role uses more than one stop.
    public var isGradient: Bool { secondary != nil || tertiary != nil }

    /// The stops as Discord writes them, **wrapped back to the first colour**,
    /// or nil for a flat role.
    ///
    /// `linear-gradient(to right, c1, c2, c1)` for two and `(c1, c2, c3, c1)`
    /// for three. The wrap is not decoration: Discord's gradient is a repeating
    /// 100-point tile that scrolls, and a list that did not return to where it
    /// started would show a seam on every cycle. Kept here even though this
    /// client draws the tile once, because it is also what makes the two ends
    /// of a short name agree.
    ///
    /// One definition, because the chip on a profile and the painted member row
    /// draw the same rule from two different layers — and two copies is how
    /// they come to disagree about a colour somebody chose.
    public static func wrappedStops(_ colors: RoleColors) -> [UInt32]? {
        guard colors.isGradient else { return nil }
        var stops = [colors.primary]
        if let secondary = colors.secondary { stops.append(secondary) }
        if let tertiary = colors.tertiary { stops.append(tertiary) }
        guard stops.count >= 2 else { return nil }
        return stops + [colors.primary]
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
        nameColorRole(of: memberRoleIDs, in: roles)?.displayColorValue
    }

    /// The role the name's colour comes from, rather than the colour alone.
    ///
    /// **An enhanced role carries a gradient as well as a flat colour**, and the
    /// two have to come from the SAME role or a member whose top coloured role
    /// is gradient and whose second is not draws one role's stops over
    /// another's colour. Asking for the role once and reading both off it is
    /// the whole of that guarantee.
    public static func nameColorRole(
        of memberRoleIDs: [RoleID],
        in roles: [RoleID: Role]
    ) -> Role? {
        topRole(of: memberRoleIDs, in: roles) { $0.displayColorValue != nil }
    }

    /// The role whose icon is drawn beside a member's name, or nil.
    ///
    /// **The highest role that HAS one**, by the same rule the colour follows:
    /// a senior role with no icon does not blank out a junior role's. A role
    /// icon is either an uploaded image or a unicode emoji — never both, and
    /// Discord accepts either — so the predicate asks for whichever arrived.
    public static func iconRole(
        of memberRoleIDs: [RoleID],
        in roles: [RoleID: Role]
    ) -> Role? {
        topRole(of: memberRoleIDs, in: roles) {
            $0.iconHash != nil || $0.unicodeEmoji != nil
        }
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
