import Foundation

// MARK: - Role order

/// Discord's role order (`AT`): `@everyone` last, then position descending,
/// and a tie to the **lower** id. Every "may this moderator act on that member"
/// question reduces to comparing two highest roles in this order.
public enum RoleOrder {
    /// Whether `a` sorts above `b`.
    public static func outranks(_ a: Role, _ b: Role, guildID: GuildID) -> Bool {
        let everyone = guildID.rawValue
        if a.id.rawValue == everyone { return false }
        if b.id.rawValue == everyone { return true }
        if a.position != b.position { return a.position > b.position }
        return a.id.rawValue < b.id.rawValue
    }

    /// The highest of somebody's roles, or nil where they hold none above
    /// `@everyone`.
    public static func highest(
        of roleIDs: [RoleID],
        in roles: [RoleID: Role],
        guildID: GuildID
    ) -> Role? {
        roleIDs
            .compactMap { roles[$0] }
            .filter { $0.id.rawValue != guildID.rawValue }
            .max { lhs, rhs in outranks(rhs, lhs, guildID: guildID) }
    }
}

// MARK: - Who may do what to whom

/// Everything Discord's moderation gates read, for one moderator and one
/// person in one server.
public struct ModerationContext: Hashable, Sendable {
    public var guildID: GuildID
    public var guildFeatures: Set<String>
    /// The moderator's permissions in the server, computed.
    public var actorPermissions: Permissions
    public var actorIsOwner: Bool
    public var actorHighestRole: Role?
    public var targetIsSelf: Bool
    public var targetIsOwner: Bool
    public var targetHighestRole: Role?
    /// The target's own computed permissions hold Administrator.
    public var targetIsAdministrator: Bool
    public var targetIsBot: Bool
    /// A system user or a webhook — Discord's `isNonUserBot`.
    public var targetIsSystem: Bool
    /// They are in the server, rather than a name seen in a message.
    public var targetIsMember: Bool
    /// Here as a guest or a lurker, which no moderation reaches.
    public var targetIsGuest: Bool
    public var targetFlags: MemberFlags
    public var targetJoinedAt: Date?
    public var targetTimedOutUntil: Date?

    public init(
        guildID: GuildID,
        guildFeatures: Set<String> = [],
        actorPermissions: Permissions,
        actorIsOwner: Bool = false,
        actorHighestRole: Role? = nil,
        targetIsSelf: Bool = false,
        targetIsOwner: Bool = false,
        targetHighestRole: Role? = nil,
        targetIsAdministrator: Bool = false,
        targetIsBot: Bool = false,
        targetIsSystem: Bool = false,
        targetIsMember: Bool = true,
        targetIsGuest: Bool = false,
        targetFlags: MemberFlags = [],
        targetJoinedAt: Date? = nil,
        targetTimedOutUntil: Date? = nil
    ) {
        self.guildID = guildID
        self.guildFeatures = guildFeatures
        self.actorPermissions = actorPermissions
        self.actorIsOwner = actorIsOwner
        self.actorHighestRole = actorHighestRole
        self.targetIsSelf = targetIsSelf
        self.targetIsOwner = targetIsOwner
        self.targetHighestRole = targetHighestRole
        self.targetIsAdministrator = targetIsAdministrator
        self.targetIsBot = targetIsBot
        self.targetIsSystem = targetIsSystem
        self.targetIsMember = targetIsMember
        self.targetIsGuest = targetIsGuest
        self.targetFlags = targetFlags
        self.targetJoinedAt = targetJoinedAt
        self.targetTimedOutUntil = targetTimedOutUntil
    }

    public func isTimedOut(asOf now: Date = .now) -> Bool {
        guard let targetTimedOutUntil else { return false }
        return targetTimedOutUntil > now
    }
}

/// What the person menu, Mod View and the Members page offer for one person —
/// resolved once, read by all three.
public struct ModerationActions: Hashable, Sendable {
    public var canKick = false
    public var canBan = false
    public var canTimeout = false
    public var isTimedOut = false
    public var canChangeNickname = false
    /// Manage Roles — the Roles submenu edits rather than lists.
    public var canManageRoles = false
    /// Verify / Unverify Member is offered at all.
    public var canVerify = false
    /// Which of the two the row says.
    public var isVerified = false
    public var canOpenModView = false

    public init() {}

    /// Nothing at all to offer — the reader, a guest, a stranger.
    public var isEmpty: Bool {
        !(canKick || canBan || canTimeout || canChangeNickname || canManageRoles || canVerify)
    }
}

/// Discord's moderation gates, as pure functions over a context.
///
/// Each rule is a port with its module named, because every one of them has a
/// non-obvious clause:
///
/// - **Ban is hidden for bots** (`EZ` in `351001`: `!e.bot`), kick is not.
/// - **Timeout refuses an administrator and the owner** (`838111`), whatever
///   the moderator's own rank.
/// - **Verify needs the server to have ever enabled onboarding**
///   (`GUILD_ONBOARDING_EVER_ENABLED`) and toggles one member flag.
/// - **Everything is the role hierarchy** (`canManageUser`): the owner can act
///   on anybody but themselves, and anybody else only below their highest role.
public enum ModerationPolicy {

    /// Discord's `canManageUser(permission, user, guild)`.
    public static func canManage(_ permission: Permissions, _ context: ModerationContext) -> Bool {
        if context.targetIsOwner { return false }
        let permitted = context.actorPermissions.contains(.administrator)
            || context.actorPermissions.isSuperset(of: permission)
        guard permitted else { return false }
        if context.actorIsOwner { return true }
        guard let mine = context.actorHighestRole else { return false }
        guard let theirs = context.targetHighestRole else { return true }
        return RoleOrder.outranks(mine, theirs, guildID: context.guildID)
    }

    /// Whether the reader sees the Members page and Mod View at all.
    public static func canOpenModView(_ permissions: Permissions) -> Bool {
        !permissions.isDisjoint(with: .moderatorAccess)
    }

    /// Whether the server's sidebar carries the Members row
    /// (`useGuildActionRows`): moderator access in a community server, or one
    /// Discord has given the moderation experience — or applications to review,
    /// which takes Kick Members and a server that asks for them.
    public static func showsMembersRow(_ permissions: Permissions, features: Set<String>) -> Bool {
        let community = features.contains("COMMUNITY")
            || features.contains("ENABLED_MODERATION_EXPERIENCE_FOR_NON_COMMUNITY")
        let reviewsApplications = features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL")
            && features.contains("MEMBER_VERIFICATION_GATE_ENABLED")
            && permissions.contains(.kickMembers)
        return (canOpenModView(permissions) && community) || reviewsApplications
    }

    /// Whether Server Settings → Members leaves settings for the Members page
    /// (`566fbdb0`) rather than drawing the older list inside settings.
    public static func settingsOpenMembersPage(_ permissions: Permissions, features: Set<String>) -> Bool {
        canOpenModView(permissions)
            && (features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL")
                || features.contains("COMMUNITY")
                || features.contains("ENABLED_MODERATION_EXPERIENCE_FOR_NON_COMMUNITY"))
    }

    /// Prune Members (`134413`): Manage Server and Kick Members together — or,
    /// where the server keeps pruning to admins (`PRUNE_REQUIRES_ADMIN`), only
    /// the owner or an administrator.
    public static func canPrune(_ permissions: Permissions, isOwner: Bool, features: Set<String>) -> Bool {
        if features.contains("PRUNE_REQUIRES_ADMIN") {
            return isOwner || permissions.contains(.administrator)
        }
        return permissions.isSuperset(of: [.manageGuild, .kickMembers])
    }

    /// The Members page's selection and its Ban button (`134413`): the page
    /// itself, and Manage Server with Ban Members.
    public static func canBulkBan(_ permissions: Permissions) -> Bool {
        canOpenModView(permissions) && permissions.isSuperset(of: [.manageGuild, .banMembers])
    }

    public static func actions(_ context: ModerationContext) -> ModerationActions {
        var actions = ModerationActions()
        actions.canOpenModView = canOpenModView(context.actorPermissions)
        guard !context.targetIsSelf else { return actions }

        actions.canKick = canManage(.kickMembers, context) && !context.targetIsSystem
        actions.canBan = canManage(.banMembers, context)
            && !context.targetIsSystem && !context.targetIsBot
        actions.canTimeout = context.targetIsMember && !context.targetIsGuest
            && !context.targetIsSystem && !context.targetIsOwner
            && !context.targetIsAdministrator
            && canManage(.moderateMembers, context)
        actions.isTimedOut = context.isTimedOut()
        actions.canChangeNickname = context.targetIsMember && !context.targetIsGuest
            && canManage(.manageNicknames, context)
        actions.canManageRoles = context.targetIsMember
            && (context.actorPermissions.contains(.administrator)
                || context.actorPermissions.contains(.manageRoles))

        let moderates = canManage(.moderateMembers, context)
            && canManage(.kickMembers, context)
            && canManage(.banMembers, context)
        let manages = canManage(.manageGuild, context) || canManage(.manageRoles, context)
        actions.canVerify = context.targetIsMember && context.targetJoinedAt != nil
            && (moderates || manages)
            && context.guildFeatures.contains("GUILD_ONBOARDING_EVER_ENABLED")
        actions.isVerified = context.targetFlags.contains(.bypassesVerification)
        return actions
    }

    /// The roles a moderator may put on or take off somebody — Discord's Roles
    /// submenu (`180798`): not `@everyone`, not a managed role, and below the
    /// moderator's own highest. A role the person holds that the moderator
    /// cannot touch is still listed, disabled, so the list says what they have.
    public static func assignableRoles(
        _ roles: [Role],
        holding held: Set<RoleID>,
        context: ModerationContext
    ) -> [(role: Role, isEnabled: Bool)] {
        roles
            .filter { $0.id.rawValue != context.guildID.rawValue }
            .sorted { RoleOrder.outranks($0, $1, guildID: context.guildID) }
            .compactMap { role in
                let editable = !role.isManaged && outranksForEdit(role, context)
                guard editable || held.contains(role.id) else { return nil }
                return (role, editable)
            }
    }

    /// `isRoleHigher(guild, myHighest, role)` — the owner outranks everything.
    private static func outranksForEdit(_ role: Role, _ context: ModerationContext) -> Bool {
        if context.actorIsOwner { return true }
        guard let mine = context.actorHighestRole else { return false }
        return RoleOrder.outranks(mine, role, guildID: context.guildID)
    }
}

// MARK: - Durations, deletions, reasons

/// Discord's six timeout lengths (`DisableCommunicationDuration`), labelled
/// the way its picker labels them.
public enum TimeoutDuration: Int, CaseIterable, Identifiable, Sendable {
    case sixtySeconds = 60
    case fiveMinutes = 300
    case tenMinutes = 600
    case oneHour = 3600
    case oneDay = 86400
    case oneWeek = 604800

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public var title: String {
        switch self {
        case .sixtySeconds: "60 secs"
        case .fiveMinutes: "5 mins"
        case .tenMinutes: "10 mins"
        case .oneHour: "1 hour"
        case .oneDay: "1 day"
        case .oneWeek: "1 week"
        }
    }

    /// The instant a timeout chosen now ends. The route takes the instant,
    /// never the duration.
    public func until(from now: Date = .now) -> Date { now.addingTimeInterval(seconds) }
}

/// The Ban dialog's "Delete Message History" — Discord's seven choices.
public enum BanMessageDeletion: Int, CaseIterable, Identifiable, Sendable {
    case none = 0
    case previousHour = 3600
    case previousSixHours = 21600
    case previousTwelveHours = 43200
    case previousDay = 86400
    case previousThreeDays = 259200
    case previousWeek = 604800

    public var id: Int { rawValue }

    /// Discord's default for an ordinary ban.
    public static let `default` = BanMessageDeletion.previousHour

    public var title: String {
        switch self {
        case .none: "Don't Delete Any"
        case .previousHour: "Previous Hour"
        case .previousSixHours: "Previous 6 Hours"
        case .previousTwelveHours: "Previous 12 Hours"
        case .previousDay: "Previous 24 Hours"
        case .previousThreeDays: "Previous 3 Days"
        case .previousWeek: "Previous 7 Days"
        }
    }
}

/// The Ban dialog's reason picker. The three named reasons go up as their own
/// words; Other is whatever was typed.
public enum BanReason: String, CaseIterable, Identifiable, Sendable {
    case spam = "Suspicious or spam account"
    case compromised = "Compromised or hacked account"
    case rules = "Breaking server rules"
    case other = "Other"

    public var id: String { rawValue }
}

/// The cap Discord puts on a moderation reason (`hlA`).
public enum ModerationReason {
    public static let maximumLength = 512
}

/// The cap Discord puts on a nickname (`d0r`).
public enum NicknameLimits {
    public static let maximumLength = 32
}

// MARK: - The audit log, as Discord reads it

/// Discord's merge of consecutive audit-log entries (`el` in Mod View).
///
/// **Two entries become one** when the same moderator did the same thing to
/// the same target, less than thirty minutes apart, with the same options —
/// so four role edits read as one line, and a nickname and a timeout set
/// together read as one "Update Member". This is why Mod View says "3" over a
/// response holding seven entries.
///
/// Message deletions, moves, disconnects, position changes, bot adds, command
/// permission updates and prunes never merge, and neither does an invite.
/// A run stops at fifty merges.
public enum AuditLogMerge {
    public struct Group: Hashable, Sendable, Identifiable {
        /// The first entry of the run — Discord keeps it as the row's identity
        /// and measures the window from it.
        public var entry: AuditLogEntry
        /// Every change of every entry in the run, oldest first.
        public var changes: [AuditLogEntry.Change]
        public var started: Date
        public var ended: Date
        public var id: UInt64 { entry.id }
    }

    static let window: TimeInterval = 30 * 60
    static let maximumRun = 50

    public static func groups(_ entries: [AuditLogEntry]) -> [Group] {
        // Discord walks oldest first and prepends, so the result is newest
        // first, exactly as the route answers.
        var result: [Group] = []
        var run = 0
        for entry in entries.reversed() {
            if var last = result.last, run < maximumRun, merges(last, entry) {
                last.changes += entry.changes
                last.ended = entry.timestamp
                result[result.count - 1] = last
                run += 1
                continue
            }
            run = 0
            result.append(
                Group(entry: entry, changes: entry.changes, started: entry.timestamp, ended: entry.timestamp)
            )
        }
        return result.reversed()
    }

    /// Discord's test, against the run's FIRST entry: same action, target,
    /// moderator and options, less than thirty minutes after it started.
    private static func merges(_ group: Group, _ later: AuditLogEntry) -> Bool {
        guard !neverMerges.contains(later.action) else { return false }
        let first = group.entry
        return first.action == later.action
            && first.targetID == later.targetID
            && first.userID == later.userID
            && later.timestamp.timeIntervalSince(group.started) < window
            && first.options == later.options
    }

    private static let neverMerges: Set<AuditLogAction> = [
        .messageDelete, .messageBulkDelete, .messagePin, .messageUnpin,
        .memberMove, .memberDisconnect, .botAdd, .commandPermissionUpdate, .memberPrune,
        .inviteCreate, .inviteUpdate, .inviteDelete,
    ]
}

// MARK: - Mod View's numbers

/// Mod View's Server Activity: what somebody has posted here, counted by the
/// search route's three tabs.
public struct MemberActivityCounts: Hashable, Sendable {
    public var messages: Int
    public var links: Int
    public var media: Int

    public init(messages: Int, links: Int, media: Int) {
        self.messages = messages
        self.links = links
        self.media = media
    }

    /// The extensions Discord's Media tab searches for — the captured list,
    /// in its order.
    public static let mediaExtensions = [
        "png", "jpg", "webp", "mov", "mp4", "qt", "gif", "mp3", "wav", "flac", "ogg", "opus",
    ]
}

// MARK: - Remove Timeout's countdown

/// The time left on a timeout as Discord's dialog counts it down (`576470`
/// with `showUnits`): days, hours, minutes and seconds, two digits each, the
/// days left out at zero — "06d 23h 59m 30s". It stops at one second rather
/// than reaching zero, as Discord's does.
public enum TimeoutCountdown {
    public static func text(until end: Date, now: Date = .now) -> String {
        let remaining = max(1, Int(end.timeIntervalSince(now)))
        let days = remaining / 86400
        var parts = [
            (remaining % 86400 / 3600, "h"),
            (remaining % 3600 / 60, "m"),
            (remaining % 60, "s"),
        ]
        if days > 0 { parts.insert((days, "d"), at: 0) }
        return parts.map { value, unit in (value < 10 ? "0\(value)" : "\(value)") + unit }
            .joined(separator: " ")
    }
}

// MARK: - Mod View's permissions

/// Mod View's Mod Permissions section and its Permissions panel.
public enum ModPermissions {
    /// The permissions the section lists when somebody holds them — Discord's
    /// `tI`: the community moderation set, the elevated set, and the webhook,
    /// thread and mention permissions beside them.
    public static let listed: Permissions = [
        .administrator, .kickMembers, .banMembers, .manageGuild, .manageChannels, .manageRoles,
        .manageMessages, .manageExpressions, .createExpressions, .manageEvents, .createEvents,
        .moderateMembers, .mentionEveryone, .manageOfficialMessages, .manageThreads, .manageWebhooks,
    ]

    /// The ones Discord marks elevated — the set a server's two-factor
    /// requirement covers.
    public static let elevated: Permissions = [
        .kickMembers, .banMembers, .administrator, .manageChannels, .manageGuild, .manageRoles,
        .manageMessages, .manageThreads, .moderateMembers,
    ]

    /// What somebody holds of `listed`, in the role editor's order.
    public static func held(_ permissions: Permissions) -> [PermissionCatalog.Entry] {
        granted(permissions).filter { listed.contains($0.permission) }
    }

    /// Every permission somebody holds, in the role editor's order.
    public static func granted(_ permissions: Permissions) -> [PermissionCatalog.Entry] {
        PermissionCatalog.groups.flatMap(\.entries).filter { permissions.contains($0.permission) }
    }

    /// What grants somebody a permission they hold — Discord's `tG`: each of
    /// their roles that carries it or Administrator, `@everyone` likewise, and
    /// for the owner, ownership itself (`grantsOwnership`).
    public static func sources(
        of permission: Permissions,
        memberRoles: [RoleID],
        roles: [RoleID: Role],
        guildID: GuildID,
        isOwner: Bool
    ) -> (roles: [Role], grantsOwnership: Bool) {
        let granting = memberRoles
            .compactMap { roles[$0] }
            .filter { $0.permissions.contains(.administrator) || $0.permissions.contains(permission) }
            .sorted { RoleOrder.outranks($0, $1, guildID: guildID) }
        let everyone = roles[RoleID(rawValue: guildID.rawValue)].flatMap {
            $0.permissions.contains(.administrator) || $0.permissions.contains(permission) ? $0 : nil
        }
        return (granting + (everyone.map { [$0] } ?? []), isOwner)
    }
}
