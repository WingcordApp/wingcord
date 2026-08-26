import Foundation
import Testing
@testable import WingcordCore

/// The permission model, case by case.
///
/// This is a security boundary: every case here is one where getting it wrong
/// shows somebody a channel they cannot open, or offers a composer that will
/// 403. The order of the six steps is Discord's, and several of these tests exist
/// specifically to pin an ordering that is easy to get subtly wrong.
@Suite("Permission resolver")
struct PermissionResolverTests {

    private let guildID = GuildID(rawValue: 100)
    private let ownerID = UserID(rawValue: 1)
    private let memberID = UserID(rawValue: 2)

    /// `@everyone` is the role whose id equals the guild's.
    private var everyoneID: RoleID { RoleID(rawValue: guildID.rawValue) }

    private func roles(_ entries: [Role]) -> [RoleID: Role] {
        var table: [RoleID: Role] = [:]
        for role in entries { table[role.id] = role }
        return table
    }

    private func channel(_ overwrites: [PermissionOverwrite] = []) -> Channel {
        Channel(
            id: ChannelID(rawValue: 900),
            kind: .text,
            guildID: guildID,
            name: "general",
            overwrites: overwrites
        )
    }

    private func resolve(
        memberRoles: [RoleID],
        userID: UserID? = nil,
        roles table: [RoleID: Role],
        channel: Channel?
    ) -> Permissions {
        PermissionResolver.permissions(
            forMember: memberRoles,
            userID: userID ?? memberID,
            guildID: guildID,
            guildOwnerID: ownerID,
            roles: table,
            channel: channel
        )
    }

    // MARK: Base

    @Test("The owner has everything, whatever the overwrites say")
    func ownerHasEverything() {
        let denyAll = PermissionOverwrite(
            id: everyoneID.rawValue, subject: .role, allow: [], deny: .all
        )
        let resolved = resolve(
            memberRoles: [],
            userID: ownerID,
            roles: roles([Role(id: everyoneID, name: "@everyone")]),
            channel: channel([denyAll])
        )
        #expect(resolved.contains(.viewChannel))
        #expect(resolved.contains(.administrator))
    }

    @Test("Administrator short-circuits, but only after roles are unioned")
    func administratorShortCircuits() {
        let adminRole = RoleID(rawValue: 5)
        let table = roles([
            Role(id: everyoneID, name: "@everyone", permissions: []),
            Role(id: adminRole, name: "Admin", permissions: [.administrator]),
        ])
        let denyAll = PermissionOverwrite(
            id: everyoneID.rawValue, subject: .role, allow: [], deny: .all
        )
        let resolved = resolve(
            memberRoles: [adminRole],
            roles: table,
            channel: channel([denyAll])
        )
        #expect(resolved.contains(.viewChannel))
    }

    @Test("`@everyone` is applied even though Discord omits it from a member's roles")
    func everyoneIsAlwaysIncluded() {
        let table = roles([
            Role(id: everyoneID, name: "@everyone", permissions: [.viewChannel, .sendMessages])
        ])
        let resolved = resolve(memberRoles: [], roles: table, channel: nil)
        #expect(resolved.contains(.viewChannel))
        #expect(resolved.contains(.sendMessages))
    }

    @Test("Roles GRANT: a role cannot take away what another role gave")
    func rolesOnlyGrant() {
        let a = RoleID(rawValue: 5)
        let b = RoleID(rawValue: 6)
        let table = roles([
            Role(id: everyoneID, name: "@everyone", permissions: []),
            Role(id: a, name: "A", permissions: [.sendMessages]),
            Role(id: b, name: "B", permissions: [.viewChannel]),
        ])
        let resolved = resolve(memberRoles: [a, b], roles: table, channel: nil)
        #expect(resolved.contains(.sendMessages))
        #expect(resolved.contains(.viewChannel))
    }

    // MARK: Channel overwrites

    @Test("The channel's @everyone overwrite denies then allows")
    func everyoneOverwrite() {
        let table = roles([
            Role(id: everyoneID, name: "@everyone", permissions: [.viewChannel, .sendMessages])
        ])
        let overwrite = PermissionOverwrite(
            id: everyoneID.rawValue, subject: .role, allow: [], deny: [.sendMessages]
        )
        let resolved = resolve(memberRoles: [], roles: table, channel: channel([overwrite]))
        #expect(resolved.contains(.viewChannel))
        #expect(!resolved.contains(.sendMessages))
    }

    @Test("A role overwrite restores what the channel denied to everyone")
    func roleOverwriteRestores() {
        let staff = RoleID(rawValue: 5)
        let table = roles([
            Role(id: everyoneID, name: "@everyone", permissions: [.viewChannel]),
            Role(id: staff, name: "Staff", permissions: []),
        ])
        let channel = channel([
            PermissionOverwrite(
                id: everyoneID.rawValue, subject: .role, allow: [], deny: [.viewChannel]
            ),
            PermissionOverwrite(id: staff.rawValue, subject: .role, allow: [.viewChannel], deny: []),
        ])
        #expect(!resolve(memberRoles: [], roles: table, channel: channel).contains(.viewChannel))
        #expect(resolve(memberRoles: [staff], roles: table, channel: channel).contains(.viewChannel))
    }

    /// The classic bug this algorithm is written to avoid.
    @Test("Role overwrites are UNIONED before being applied, not applied one at a time")
    func roleOverwritesAreUnioned() {
        let allower = RoleID(rawValue: 5)
        let denier = RoleID(rawValue: 6)
        let table = roles([
            Role(id: everyoneID, name: "@everyone", permissions: []),
            Role(id: allower, name: "Allower", position: 1),
            Role(id: denier, name: "Denier", position: 2),
        ])
        // A member holding BOTH: one overwrite allows, one denies. Discord
        // unions every role allow and every role deny and applies the two masks
        // together — deny first, then allow — so the allow wins.
        //
        // Applying them one role at a time in position order would let the
        // denier cancel the allower, which is the bug.
        let channel = channel([
            PermissionOverwrite(id: allower.rawValue, subject: .role, allow: [.sendMessages], deny: []),
            PermissionOverwrite(id: denier.rawValue, subject: .role, allow: [], deny: [.sendMessages]),
        ])
        let resolved = resolve(memberRoles: [allower, denier], roles: table, channel: channel)
        #expect(resolved.contains(.sendMessages))
    }

    @Test("A member overwrite beats every role overwrite")
    func memberOverwriteWins() {
        let staff = RoleID(rawValue: 5)
        let table = roles([
            Role(id: everyoneID, name: "@everyone", permissions: [.viewChannel]),
            Role(id: staff, name: "Staff", permissions: [.sendMessages]),
        ])
        let channel = channel([
            PermissionOverwrite(id: staff.rawValue, subject: .role, allow: [.sendMessages], deny: []),
            PermissionOverwrite(
                id: memberID.rawValue, subject: .member, allow: [], deny: [.sendMessages]
            ),
        ])
        let resolved = resolve(memberRoles: [staff], roles: table, channel: channel)
        #expect(!resolved.contains(.sendMessages))
        #expect(resolved.contains(.viewChannel))
    }

    @Test("A member overwrite does NOT beat administrator")
    func administratorBeatsMemberOverwrite() {
        let admin = RoleID(rawValue: 5)
        let table = roles([
            Role(id: everyoneID, name: "@everyone"),
            Role(id: admin, name: "Admin", permissions: [.administrator]),
        ])
        let channel = channel([
            PermissionOverwrite(
                id: memberID.rawValue, subject: .member, allow: [], deny: .all
            )
        ])
        #expect(resolve(memberRoles: [admin], roles: table, channel: channel).contains(.viewChannel))
    }

    // MARK: Failure modes

    @Test("An unknown role contributes nothing rather than everything")
    func unknownRoleIsIgnored() {
        let table = roles([Role(id: everyoneID, name: "@everyone", permissions: [.viewChannel])])
        let resolved = resolve(memberRoles: [RoleID(rawValue: 999)], roles: table, channel: nil)
        #expect(resolved.contains(.viewChannel))
        #expect(!resolved.contains(.administrator))
    }

    @Test("An empty role table denies everything")
    func emptyTableDeniesEverything() {
        #expect(resolve(memberRoles: [], roles: [:], channel: nil).isEmpty)
    }

    @Test("An unparseable permission string is NO permissions, never all")
    func unparseablePermissionsFailClosed() {
        #expect(Permissions(string: "not a number").isEmpty)
        #expect(Permissions(string: "").isEmpty)
    }

    @Test("The high bits survive, because the field is 64 bits wide")
    func highBitsSurvive() {
        let parsed = Permissions(string: String(Permissions.sendPolls.rawValue))
        #expect(parsed.contains(.sendPolls))
        #expect(Permissions.sendPolls.rawValue == 1 << 49)
    }

    @Test("An overwrite for a role the member does not hold is ignored")
    func irrelevantOverwriteIgnored() {
        let other = RoleID(rawValue: 7)
        let table = roles([Role(id: everyoneID, name: "@everyone", permissions: [.viewChannel])])
        let channel = channel([
            PermissionOverwrite(id: other.rawValue, subject: .role, allow: [], deny: [.viewChannel])
        ])
        #expect(resolve(memberRoles: [], roles: table, channel: channel).contains(.viewChannel))
    }
}

@Suite("Role resolution")
struct RoleResolverTests {
    private func table(_ entries: [Role]) -> [RoleID: Role] {
        var result: [RoleID: Role] = [:]
        for role in entries { result[role.id] = role }
        return result
    }

    @Test("Zero is 'no colour', not black")
    func zeroIsNotBlack() {
        #expect(Role(id: RoleID(rawValue: 1), name: "x", colorValue: 0).displayColorValue == nil)
        #expect(
            Role(id: RoleID(rawValue: 1), name: "x", colorValue: 0x00FF00).displayColorValue
                == 0x00FF00
        )
    }

    @Test("The name colour is the highest COLOURED role, not the highest role")
    func nameColourSkipsColourlessRoles() {
        let senior = RoleID(rawValue: 10)
        let junior = RoleID(rawValue: 11)
        let roles = table([
            Role(id: senior, name: "Senior", colorValue: 0, position: 10),
            Role(id: junior, name: "Junior", colorValue: 0xFF0000, position: 5),
        ])
        #expect(RoleResolver.nameColorValue(of: [senior, junior], in: roles) == 0xFF0000)
    }

    @Test("The hoist group is the highest role with hoist set")
    func hoistGroup() {
        let hoisted = RoleID(rawValue: 10)
        let higher = RoleID(rawValue: 11)
        let roles = table([
            Role(id: hoisted, name: "Mods", isHoisted: true, position: 5),
            Role(id: higher, name: "Quiet", isHoisted: false, position: 20),
        ])
        #expect(RoleResolver.hoistRole(of: [hoisted, higher], in: roles)?.id == hoisted)
    }

    @Test("Ties break on id, so a sort over equal positions is stable")
    func seniorityTieBreaksOnID() {
        let first = Role(id: RoleID(rawValue: 1), name: "a", position: 3)
        let second = Role(id: RoleID(rawValue: 2), name: "b", position: 3)
        #expect(Role.seniorityOrder(first, second))
        #expect(!Role.seniorityOrder(second, first))
    }

    @Test("No coloured role means the default colour")
    func noColourMeansNil() {
        let plain = RoleID(rawValue: 10)
        let roles = table([Role(id: plain, name: "Plain", colorValue: 0)])
        #expect(RoleResolver.nameColorValue(of: [plain], in: roles) == nil)
    }
}
