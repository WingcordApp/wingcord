import Foundation

/// Discord's permission bitfield.
///
/// `UInt64` and not `Int`: the field is 64 bits wide and Discord is using the
/// high ones. A signed 64-bit integer holds them but any arithmetic on the sign
/// bit is a trap waiting for the day bit 63 is allocated, and `Int` on a 32-bit
/// slice would not hold them at all.
public struct Permissions: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Parses Discord's string form. Anything unparseable is *no* permissions,
    /// never all of them: the failure mode of a permissive default is showing a
    /// user controls that will 403.
    public init(string: some StringProtocol) {
        rawValue = UInt64(string) ?? 0
    }

    /// The form Discord's write routes want: a **decimal string**, not a number.
    ///
    /// The bitfield is already wider than a JSON number can carry exactly, which
    /// is why Discord sends and takes it as text — encoding it as an integer
    /// works for every permission set anybody tests with and silently loses the
    /// low bits of one that uses a high flag.
    public var apiString: String { String(rawValue) }

    public static let createInvite = Permissions(rawValue: 1 << 0)
    public static let kickMembers = Permissions(rawValue: 1 << 1)
    public static let banMembers = Permissions(rawValue: 1 << 2)
    public static let administrator = Permissions(rawValue: 1 << 3)
    public static let manageChannels = Permissions(rawValue: 1 << 4)
    public static let manageGuild = Permissions(rawValue: 1 << 5)
    public static let addReactions = Permissions(rawValue: 1 << 6)
    public static let viewAuditLog = Permissions(rawValue: 1 << 7)
    public static let prioritySpeaker = Permissions(rawValue: 1 << 8)
    public static let stream = Permissions(rawValue: 1 << 9)
    public static let viewChannel = Permissions(rawValue: 1 << 10)
    public static let sendMessages = Permissions(rawValue: 1 << 11)
    public static let sendTTSMessages = Permissions(rawValue: 1 << 12)
    public static let manageMessages = Permissions(rawValue: 1 << 13)
    public static let embedLinks = Permissions(rawValue: 1 << 14)
    public static let attachFiles = Permissions(rawValue: 1 << 15)
    public static let readMessageHistory = Permissions(rawValue: 1 << 16)
    public static let mentionEveryone = Permissions(rawValue: 1 << 17)
    public static let useExternalEmojis = Permissions(rawValue: 1 << 18)
    public static let viewGuildInsights = Permissions(rawValue: 1 << 19)
    public static let connect = Permissions(rawValue: 1 << 20)
    public static let speak = Permissions(rawValue: 1 << 21)
    public static let muteMembers = Permissions(rawValue: 1 << 22)
    public static let deafenMembers = Permissions(rawValue: 1 << 23)
    public static let moveMembers = Permissions(rawValue: 1 << 24)
    public static let useVAD = Permissions(rawValue: 1 << 25)
    public static let changeNickname = Permissions(rawValue: 1 << 26)
    public static let manageNicknames = Permissions(rawValue: 1 << 27)
    public static let manageRoles = Permissions(rawValue: 1 << 28)
    public static let manageWebhooks = Permissions(rawValue: 1 << 29)
    public static let manageExpressions = Permissions(rawValue: 1 << 30)
    public static let useApplicationCommands = Permissions(rawValue: 1 << 31)
    public static let requestToSpeak = Permissions(rawValue: 1 << 32)
    public static let manageEvents = Permissions(rawValue: 1 << 33)
    public static let manageThreads = Permissions(rawValue: 1 << 34)
    public static let createPublicThreads = Permissions(rawValue: 1 << 35)
    public static let createPrivateThreads = Permissions(rawValue: 1 << 36)
    public static let useExternalStickers = Permissions(rawValue: 1 << 37)
    public static let sendMessagesInThreads = Permissions(rawValue: 1 << 38)
    public static let useEmbeddedActivities = Permissions(rawValue: 1 << 39)
    public static let moderateMembers = Permissions(rawValue: 1 << 40)
    public static let viewCreatorMonetizationAnalytics = Permissions(rawValue: 1 << 41)
    public static let useSoundboard = Permissions(rawValue: 1 << 42)
    public static let createExpressions = Permissions(rawValue: 1 << 43)

    /// Who may open a server's settings window at all.
    ///
    /// **Ten permissions, read out of Discord's own bundle**, where the mask is
    /// declared in one line and `canAccessGuildSettings` is a single test
    /// against it. Two things it deliberately does NOT contain:
    ///
    ///  - `createInvite`, which `@everyone` holds on almost every server. A gate
    ///    that included it opened the window for every member of every server —
    ///    which is exactly what happened when this client derived the gate from
    ///    its own per-page requirements instead, because the Invites page asks
    ///    for `createInvite` and nothing else.
    ///  - `kickMembers`. Discord's Members page is gated by its own separate
    ///    check, not by this mask.
    public static let guildSettingsAccess: Permissions = [
        .manageGuild, .manageRoles, .administrator, .banMembers, .manageNicknames,
        .createExpressions, .manageExpressions, .manageWebhooks, .viewAuditLog,
        .viewGuildInsights,
    ]
    public static let createEvents = Permissions(rawValue: 1 << 44)
    public static let useExternalSounds = Permissions(rawValue: 1 << 45)
    public static let sendVoiceMessages = Permissions(rawValue: 1 << 46)
    // 1 << 47 was `USE_CLYDE_AI` and is retired. Left as a gap rather than
    // renumbered: a role created while it existed still carries the bit, and
    // reusing 47 would read somebody's dead Clyde grant as whatever went there.
    public static let setVoiceChannelStatus = Permissions(rawValue: 1 << 48)
    public static let sendPolls = Permissions(rawValue: 1 << 49)
    public static let useExternalApps = Permissions(rawValue: 1 << 50)
    /// Split out of `manageMessages`, and the audit log records the migration
    /// as its own action (212). A server that has been migrated grants pinning
    /// through this bit alone.
    public static let pinMessages = Permissions(rawValue: 1 << 51)
    /// Also split out of `manageMessages`, alongside `manageChannels` and
    /// `manageThreads` — audit action 213.
    public static let bypassSlowmode = Permissions(rawValue: 1 << 52)
    public static let manageOfficialMessages = Permissions(rawValue: 1 << 53)

    /// Everything a **lurker** keeps: read the channel, read its history.
    ///
    /// **An allow-list, and it has to be one.** A lurker is not a member, so the
    /// resolver computing their permissions finds no member record, falls back
    /// to `@everyone` alone, and hands back whatever a server grants the public
    /// — which on most servers includes `SEND_MESSAGES` and `ADD_REACTIONS`.
    /// Every one of those would 403, and §5.5 forbids a control that looks like
    /// it works and does not.
    ///
    /// Written as the two bits that are kept rather than as the many that are
    /// taken away, because the failure modes are not symmetric: a deny-list that
    /// misses a bit grants it, and Discord adds bits. This misses nothing by
    /// construction, and a bit added tomorrow is denied by default.
    ///
    /// Not "read-only": `VIEW_CHANNEL` alone still lists a voice channel, and
    /// connecting to one is a write in every sense that matters here.
    public static let lurker: Permissions = [.viewChannel, .readMessageHistory]
}

/// Resolves what one member may do in one channel.
///
/// A pure function of the guild's roles, the member's roles, and the channel's
/// overwrites — no store, no actor, no I/O — so the whole permission model is
/// testable against a table of cases rather than against a running session.
///
/// The order is Discord's and every step matters:
///
///   1. The guild owner has everything, unconditionally.
///   2. Start from `@everyone`'s permissions, then OR in every role the member
///      holds. Roles GRANT; a role cannot take away what another role gave.
///   3. Administrator short-circuits to everything, but only *after* step 2 —
///      a member is an administrator by holding a role that says so.
///   4. Apply the channel's `@everyone` overwrite: deny first, then allow.
///   5. Accumulate every role overwrite that applies into ONE pair of masks and
///      apply them together. Applying them one role at a time is the classic bug
///      — a later role's deny then cancels an earlier role's allow, when Discord
///      unions all role denies and all role allows and applies the union.
///   6. Apply the member-specific overwrite last, deny then allow. It beats
///      everything except owner and administrator.
public enum PermissionResolver {

    public static func permissions(
        forMember memberRoleIDs: some Sequence<RoleID>,
        userID: UserID,
        guildID: GuildID,
        guildOwnerID: UserID,
        roles: [RoleID: Role],
        channel: Channel?
    ) -> Permissions {
        if userID == guildOwnerID { return .all }

        // `@everyone` is the role whose id equals the guild's id. Discord does
        // not send it in a member's role list, so it is always added here.
        let everyoneRoleID = RoleID(rawValue: guildID.rawValue)
        var base = roles[everyoneRoleID]?.permissions ?? []
        for roleID in memberRoleIDs {
            if let role = roles[roleID] { base.formUnion(role.permissions) }
        }
        if base.contains(.administrator) { return .all }

        guard let channel, !channel.overwrites.isEmpty else { return base }

        var resolved = base

        // Step 4: the channel-wide overwrite.
        if let everyone = channel.overwrites.first(where: {
            $0.subject == .role && $0.id == everyoneRoleID.rawValue
        }) {
            resolved.subtract(everyone.deny)
            resolved.formUnion(everyone.allow)
        }

        // Step 5: every role overwrite, unioned before being applied.
        var roleAllow: Permissions = []
        var roleDeny: Permissions = []
        for overwrite in channel.overwrites where overwrite.subject == .role {
            guard overwrite.id != everyoneRoleID.rawValue,
                  memberRoleIDs.contains(RoleID(rawValue: overwrite.id))
            else { continue }
            roleAllow.formUnion(overwrite.allow)
            roleDeny.formUnion(overwrite.deny)
        }
        resolved.subtract(roleDeny)
        resolved.formUnion(roleAllow)

        // Step 6: the member's own overwrite wins.
        if let member = channel.overwrites.first(where: {
            $0.subject == .member && $0.id == userID.rawValue
        }) {
            resolved.subtract(member.deny)
            resolved.formUnion(member.allow)
        }

        return resolved
    }
}

extension Permissions {
    /// Every bit set. What an owner or an administrator resolves to.
    public static let all = Permissions(rawValue: .max)

    /// Whether a channel is visible at all.
    ///
    /// Losing `viewChannel` hides the row; losing `readMessageHistory` shows the
    /// row and an empty transcript, which is a different state and must not be
    /// collapsed into this one.
    public var canSeeChannel: Bool { contains(.viewChannel) }
}
