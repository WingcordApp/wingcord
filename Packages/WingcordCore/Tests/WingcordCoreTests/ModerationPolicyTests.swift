import Foundation
import Testing
@testable import WingcordCore

/// Discord's moderation gates, each with the clause that is not obvious.
@Suite("Who may do what to whom")
struct ModerationPolicyTests {

    private let guild = GuildID(rawValue: 100)

    private func role(_ id: UInt64, position: Int, permissions: Permissions = [], managed: Bool = false) -> Role {
        Role(id: RoleID(rawValue: id), name: "r\(id)", position: position, permissions: permissions, isManaged: managed)
    }

    private func context(
        actor: Permissions = [.kickMembers, .banMembers, .moderateMembers, .manageNicknames, .manageRoles],
        actorRole: Role? = nil,
        targetRole: Role? = nil,
        actorIsOwner: Bool = false,
        targetIsOwner: Bool = false,
        targetIsBot: Bool = false,
        targetIsAdministrator: Bool = false,
        targetIsSelf: Bool = false,
        features: Set<String> = [],
        flags: MemberFlags = []
    ) -> ModerationContext {
        ModerationContext(
            guildID: guild,
            guildFeatures: features,
            actorPermissions: actor,
            actorIsOwner: actorIsOwner,
            actorHighestRole: actorRole ?? role(1, position: 10),
            targetIsSelf: targetIsSelf,
            targetIsOwner: targetIsOwner,
            targetHighestRole: targetRole,
            targetIsAdministrator: targetIsAdministrator,
            targetIsBot: targetIsBot,
            targetFlags: flags,
            targetJoinedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("Nobody acts on the owner; the owner acts on anybody else")
    func ownership() {
        #expect(!ModerationPolicy.canManage(.kickMembers, context(targetIsOwner: true)))
        let owner = context(actor: [], actorRole: nil, targetRole: role(9, position: 99), actorIsOwner: true)
        #expect(!ModerationPolicy.canManage(.kickMembers, owner), "the owner still needs the permission")
        let ownerWithAll = context(actor: .all, targetRole: role(9, position: 99), actorIsOwner: true)
        #expect(ModerationPolicy.canManage(.kickMembers, ownerWithAll))
    }

    @Test("Only below the moderator's highest role, a tie going to the lower id")
    func hierarchy() {
        let mine = role(50, position: 5)
        #expect(ModerationPolicy.canManage(.kickMembers, context(actorRole: mine, targetRole: role(60, position: 4))))
        #expect(!ModerationPolicy.canManage(.kickMembers, context(actorRole: mine, targetRole: role(60, position: 6))))
        // Same position: the lower id ranks higher.
        #expect(ModerationPolicy.canManage(.kickMembers, context(actorRole: mine, targetRole: role(60, position: 5))))
        #expect(!ModerationPolicy.canManage(.kickMembers, context(actorRole: mine, targetRole: role(40, position: 5))))
        // Somebody with no roles above @everyone sits below everybody.
        #expect(ModerationPolicy.canManage(.kickMembers, context(actorRole: mine, targetRole: nil)))
    }

    @Test("Ban is hidden for bots, kick is not")
    func bots() {
        let actions = ModerationPolicy.actions(context(targetIsBot: true))
        #expect(actions.canKick)
        #expect(!actions.canBan)
    }

    @Test("Timeout refuses an administrator whatever the moderator's rank")
    func timeoutRefusesAdministrators() {
        #expect(ModerationPolicy.actions(context()).canTimeout)
        #expect(!ModerationPolicy.actions(context(targetIsAdministrator: true)).canTimeout)
    }

    @Test("Verify needs onboarding ever enabled, and reads the bypass flag")
    func verify() {
        #expect(!ModerationPolicy.actions(context(actor: .all)).canVerify)
        let onboarding: Set<String> = ["GUILD_ONBOARDING_EVER_ENABLED"]
        let actions = ModerationPolicy.actions(context(actor: .all, features: onboarding, flags: .bypassesVerification))
        #expect(actions.canVerify)
        #expect(actions.isVerified)
    }

    @Test("The reader is offered nothing about themselves but Mod View")
    func yourself() {
        let actions = ModerationPolicy.actions(context(actor: .all, targetIsSelf: true))
        #expect(actions.isEmpty)
        #expect(actions.canOpenModView)
    }

    @Test("The Members row and the settings entry follow Discord's two gates")
    func membersPage() {
        let moderator: Permissions = [.kickMembers]
        #expect(!ModerationPolicy.showsMembersRow(moderator, features: []))
        #expect(ModerationPolicy.showsMembersRow(moderator, features: ["COMMUNITY"]))
        #expect(ModerationPolicy.showsMembersRow(moderator, features: ["ENABLED_MODERATION_EXPERIENCE_FOR_NON_COMMUNITY"]))
        #expect(!ModerationPolicy.showsMembersRow([.sendMessages], features: ["COMMUNITY"]))
        let applications: Set<String> = ["MEMBER_VERIFICATION_MANUAL_APPROVAL", "MEMBER_VERIFICATION_GATE_ENABLED"]
        #expect(ModerationPolicy.showsMembersRow([.kickMembers], features: applications))
        #expect(ModerationPolicy.settingsOpenMembersPage([.banMembers], features: ["MEMBER_VERIFICATION_MANUAL_APPROVAL"]))
        #expect(!ModerationPolicy.settingsOpenMembersPage([.banMembers], features: []))
    }

    @Test("Prune takes Manage Server and Kick Members, or the owner where it is kept to admins")
    func prune() {
        #expect(!ModerationPolicy.canPrune([.kickMembers], isOwner: false, features: []))
        #expect(ModerationPolicy.canPrune([.kickMembers, .manageGuild], isOwner: false, features: []))
        let adminOnly: Set<String> = ["PRUNE_REQUIRES_ADMIN"]
        #expect(!ModerationPolicy.canPrune([.kickMembers, .manageGuild], isOwner: false, features: adminOnly))
        #expect(ModerationPolicy.canPrune([], isOwner: true, features: adminOnly))
        #expect(ModerationPolicy.canPrune(.all, isOwner: false, features: adminOnly))
    }

    @Test("Bulk ban takes the page and Manage Server with Ban Members")
    func bulkBan() {
        #expect(!ModerationPolicy.canBulkBan([.banMembers]))
        #expect(ModerationPolicy.canBulkBan([.banMembers, .manageGuild]))
    }

    @Test("The Roles list leaves out @everyone, locks what the moderator cannot reach, hides what they cannot touch")
    func assignableRoles() {
        let everyone = Role(id: RoleID(rawValue: guild.rawValue), name: "@everyone")
        let high = role(1, position: 10)
        let mine = role(2, position: 8)
        let low = role(3, position: 2)
        let managed = role(4, position: 1, managed: true)
        let held: Set<RoleID> = [high.id]
        let result = ModerationPolicy.assignableRoles(
            [everyone, high, mine, low, managed],
            holding: held,
            context: context(actorRole: mine)
        )
        #expect(result.map(\.role.id) == [high.id, low.id])
        #expect(result.map(\.isEnabled) == [false, true])
    }
}

@Suite("Mod View's numbers and words")
struct ModViewRulesTests {

    @Test("The countdown drops days at zero and stops at one second")
    func countdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(TimeoutCountdown.text(until: now.addingTimeInterval(6 * 86400 + 23 * 3600 + 59 * 60 + 30), now: now)
            == "06d 23h 59m 30s")
        #expect(TimeoutCountdown.text(until: now.addingTimeInterval(5 * 3600 + 59 * 60 + 30), now: now) == "05h 59m 30s")
        #expect(TimeoutCountdown.text(until: now.addingTimeInterval(-5), now: now) == "00h 00m 01s")
    }

    @Test("Mod Permissions lists only the moderator set, in the role editor's order")
    func heldPermissions() {
        let held = ModPermissions.held([.sendMessages, .banMembers, .manageChannels, .viewChannel])
        #expect(held.map(\.permission) == [.manageChannels, .banMembers])
        #expect(ModPermissions.elevated.contains(.banMembers))
        #expect(!ModPermissions.elevated.contains(.mentionEveryone))
    }

    @Test("A permission's sources are the roles that carry it or Administrator, and @everyone")
    func sources() {
        let guild = GuildID(rawValue: 100)
        let everyone = Role(id: RoleID(rawValue: 100), name: "@everyone", permissions: [.sendMessages])
        let admin = Role(id: RoleID(rawValue: 1), name: "Admin", position: 9, permissions: [.administrator])
        let mod = Role(id: RoleID(rawValue: 2), name: "Mod", position: 5, permissions: [.kickMembers])
        let roles = [everyone.id: everyone, admin.id: admin, mod.id: mod]
        let kick = ModPermissions.sources(
            of: .kickMembers, memberRoles: [mod.id, admin.id], roles: roles, guildID: guild, isOwner: false
        )
        #expect(kick.roles.map(\.id) == [admin.id, mod.id])
        #expect(!kick.grantsOwnership)
        let send = ModPermissions.sources(
            of: .sendMessages, memberRoles: [mod.id], roles: roles, guildID: guild, isOwner: true
        )
        #expect(send.roles.map(\.id) == [everyone.id])
        #expect(send.grantsOwnership)
    }

    @Test("A run of entries merges inside thirty minutes of its first, with the same options")
    func auditMerge() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ minutes: Double, _ action: AuditLogAction = .memberRoleUpdate, options: [String: String] = [:]) -> AuditLogEntry {
            AuditLogEntry(
                id: SnowflakeTime.snowflake(at: start.addingTimeInterval(minutes * 60)),
                action: action,
                userID: UserID(rawValue: 1),
                targetID: 2,
                changes: [AuditLogEntry.Change(key: "$add", after: "r\(Int(minutes))")],
                options: options
            )
        }
        // Newest first, as the route answers.
        let groups = AuditLogMerge.groups([entry(40), entry(20), entry(10), entry(0)])
        #expect(groups.count == 2, "40 minutes is past the first entry's window")
        #expect(groups.last?.changes.count == 3)
        #expect(AuditLogMerge.groups([entry(2, .messageDelete), entry(1, .messageDelete)]).count == 2)
        #expect(AuditLogMerge.groups([entry(2, options: ["a": "1"]), entry(1, options: ["a": "2"])]).count == 2)
    }
}

@Suite("A channel's Permissions page")
struct ChannelPermissionCatalogTests {

    @Test("A text channel's sections, with the channel-level words")
    func textChannel() {
        let sections = ChannelPermissionCatalog.sections(for: .text)
        #expect(sections.map(\.title) == [
            "General Channel Permissions", "Membership Permissions",
            "Text Channel Permissions", "Apps Permissions",
        ])
        let general = sections[0].entries.map(\.title)
        #expect(general == ["View Channel", "Manage Channel", "Manage Permissions", "Manage Webhooks"])
        #expect(sections[2].entries.contains { $0.permission == .createPrivateThreads })
    }

    @Test("An announcement channel has no private threads; a forum says posts")
    func announcementAndForum() {
        let announcement = ChannelPermissionCatalog.sections(for: .announcement)
        #expect(!announcement[2].entries.contains { $0.permission == .createPrivateThreads })
        let forum = ChannelPermissionCatalog.sections(for: .forum)
        #expect(forum[2].title == "Forum Channel Permissions")
        #expect(forum[2].entries.first?.title == "Create Posts")
        #expect(!forum[2].entries.contains { $0.permission == .createPublicThreads })
    }

    @Test("A category speaks in the plural; @everyone hears about privacy")
    func categoryAndEveryone() {
        let category = ChannelPermissionCatalog.sections(for: .category)
        #expect(category.first?.title == "General Category Permissions")
        #expect(category.first?.entries.first?.title == "View Channels")
        let view = ChannelPermissionCatalog.sections(for: .text, isEveryone: true)[0].entries[0]
        #expect(view.detail.hasSuffix("will make this channel private."))
    }

    @Test("A stage lists its own voice set and no activities")
    func stage() {
        let stage = ChannelPermissionCatalog.sections(for: .stage)
        #expect(stage.map(\.title).contains("Stage Channel Permissions"))
        #expect(stage.last?.entries.map(\.permission) == [.useApplicationCommands, .useExternalApps])
    }

    @Test("The three-way switch writes one side or neither")
    func overwriteState() {
        var overwrite = PermissionOverwrite(id: 1, subject: .role, allow: [], deny: [])
        overwrite.set(.allow, for: .sendMessages)
        #expect(overwrite.state(of: .sendMessages) == .allow)
        overwrite.set(.deny, for: .sendMessages)
        #expect(overwrite.allow.isEmpty)
        #expect(overwrite.state(of: .sendMessages) == .deny)
        overwrite.set(.inherit, for: .sendMessages)
        #expect(overwrite.allow.isEmpty && overwrite.deny.isEmpty)
    }

    @Test("Private is @everyone denied every access permission; voice includes Connect")
    func privacy() {
        let guild = GuildID(rawValue: 9)
        var voice = Channel(id: ChannelID(rawValue: 1), kind: .voice, guildID: guild, name: "v", position: 0)
        voice.overwrites = [PermissionOverwrite(id: 9, subject: .role, allow: [], deny: .viewChannel)]
        #expect(!ChannelAccess.isPrivate(voice, guildID: guild))
        let closed = ChannelAccess.everyoneOverwrite(for: voice, guildID: guild, makingPrivate: true)
        #expect(closed.deny == [.viewChannel, .connect])
        voice.overwrites = [closed]
        #expect(ChannelAccess.isPrivate(voice, guildID: guild))
        let open = ChannelAccess.everyoneOverwrite(for: voice, guildID: guild, makingPrivate: false)
        #expect(open.deny.isEmpty)
    }
}

@Suite("Safety Setup's counts")
struct SafetyCountsTests {

    @Test("AutoMod counts each offered kind once even with no rule of it")
    func autoModCounts() {
        let rules = [
            AutoModRule(id: 1, name: "Block Common Spam", isEnabled: true, trigger: .spam),
            AutoModRule(id: 2, name: "Block Mention Spam", isEnabled: true, trigger: .mentionSpam(limit: 20, raidProtection: true)),
            AutoModRule(id: 3, name: "Words", isEnabled: false, trigger: .keyword(filter: ["x"], regexes: [], allowList: [])),
            AutoModRule(id: 4, name: "More words", isEnabled: true, trigger: .keyword(filter: ["y"], regexes: [], allowList: [])),
        ]
        // Keyword ×2 (one on), spam ✓, preset —, mention ✓, profile —.
        let count = SafetyCounts.autoMod(rules)
        #expect(count.enabled == 3)
        #expect(count.total == 6)
        #expect(SafetyCounts.sentence(count) == "3 of 6 enabled")
        #expect(SafetyCounts.autoMod([]).total == 5)
    }

    @Test("Raid protection drops one when Activity Alerts are off")
    func raidCounts() {
        #expect(SafetyCounts.raidProtection(features: []) == (3, 3))
        #expect(SafetyCounts.raidProtection(features: ["RAID_ALERTS_DISABLED"]) == (2, 3))
    }

    @Test("Permissions count two-factor, admin-only prune and a clean @everyone")
    func permissionCounts() {
        #expect(SafetyCounts.permissions(mfaLevel: 0, features: [], everyonePermissions: .administrator) == (0, 3))
        #expect(SafetyCounts.permissions(
            mfaLevel: 1,
            features: ["PRUNE_REQUIRES_ADMIN"],
            everyonePermissions: [.viewChannel, .sendMessages]
        ) == (3, 3))
    }
}
