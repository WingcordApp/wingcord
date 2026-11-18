import Foundation
import Testing
@testable import WingcordCore

/// The member list as Discord's server lays it out. The vectors for the hash,
/// the list name and the pages were produced by running Discord's own modules
/// (181370, 963307 and 361610) in node, not by reading them.
@Suite("Member lists")
struct MemberListTests {

    private static let admins = MemberList.GroupID.role(RoleID(rawValue: 7))
    private static func member(_ id: UInt64) -> MemberList.Row { .member(UserID(rawValue: id)) }

    // MARK: The hash

    @Test("MurmurHash3 matches Discord's module on every tail length")
    func murmur() {
        let vectors: [(String, UInt32)] = [
            ("", 0),
            ("a", 1_009_084_850),
            ("ab", 2_613_040_991),
            ("abc", 3_017_643_002),
            ("abcd", 1_139_631_978),
            ("hello", 613_153_351),
            ("allow:1,deny:2", 172_257_501),
            ("The quick brown fox jumps over the lazy dog", 776_992_547),
        ]
        for (input, expected) in vectors {
            #expect(MurmurHash3.hash32(input) == expected, "\(input)")
        }
    }

    // MARK: Which list

    private func channel(_ overwrites: [PermissionOverwrite], listID: String? = nil) -> Channel {
        Channel(
            id: ChannelID(rawValue: 50), kind: .text, guildID: GuildID(rawValue: 1000),
            overwrites: overwrites, memberListID: listID
        )
    }

    private func overwrite(_ id: UInt64, allow: Permissions = [], deny: Permissions = []) -> PermissionOverwrite {
        PermissionOverwrite(id: id, subject: .role, allow: allow, deny: deny)
    }

    @Test("A channel everyone can see shows the shared list")
    func everyone() {
        let open = channel([overwrite(9, allow: .viewChannel), overwrite(30, deny: .sendMessages)])
        #expect(MemberList.id(for: open, everyonePermissions: .viewChannel) == "everyone")
    }

    /// Vector from Discord's `v`: the grant and the denial of viewing are the
    /// audience, sorted as strings, and the overwrite that only touches sending
    /// is not part of it.
    @Test("A restricted channel is named by who may and may not view it")
    func restricted() {
        let restricted = channel([
            overwrite(1000, deny: .viewChannel),
            overwrite(2002, allow: .viewChannel),
            overwrite(30, allow: .sendMessages),
            overwrite(9, allow: .viewChannel),
        ])
        #expect(MemberList.id(for: restricted, everyonePermissions: .viewChannel) == "3456806593")
    }

    @Test("A server whose @everyone cannot view channels names every list")
    func everyoneCannotView() {
        #expect(MemberList.id(for: channel([]), everyonePermissions: []) == "0")
    }

    @Test("A list the server names outranks the rule")
    func namedByServer() {
        let named = channel([overwrite(1000, deny: .viewChannel)], listID: "123")
        #expect(MemberList.id(for: named, everyonePermissions: .viewChannel) == "123")
    }

    // MARK: Pages

    /// Each vector is Discord's `c` at a 46-point row, translated to the rows it
    /// saw: `lower` and `upper` from the scroll position, `margin` half a
    /// viewport.
    @Test("Pages follow the viewport and always include the first", arguments: [
        (0...20, 10, [0...99]),
        (0...100, 50, [0...99, 100...199]),
        (50...70, 10, [0...99]),
        (95...115, 10, [0...99, 100...199]),
        (100...120, 10, [0...99, 100...199]),
        (250...270, 10, [0...99, 200...299]),
        (999...1019, 10, [0...99, 900...999, 1000...1099]),
        (10000...10022, 11, [0...99, 9900...9999, 10000...10099]),
    ] as [(ClosedRange<Int>, Int, [ClosedRange<Int>])])
    func pages(visible: ClosedRange<Int>, margin: Int, expected: [ClosedRange<Int>]) {
        #expect(MemberList.pages(visible: visible, margin: margin) == expected)
    }

    // MARK: Operations

    @Test("A new list is one unnamed heading")
    func fresh() {
        let list = MemberList()
        #expect(list.groups == [MemberList.Group(id: .unknown, count: 0)])
        #expect(list.rowCount == 1)
        #expect(list.rows.isEmpty)
    }

    /// The report that started this: a column that stopped at a hundred rows and
    /// counted only the members this client held.
    @Test("The groups size the whole list before its rows arrive")
    func groupsSizeTheList() {
        var list = MemberList()
        list.apply(
            [.sync(start: 0, rows: [.group(Self.admins), Self.member(1), Self.member(2)])],
            groups: [
                MemberList.Group(id: Self.admins, count: 101),
                MemberList.Group(id: .online, count: 5000),
            ]
        )
        #expect(list.headingIndexes == [0, 102])
        #expect(list.rowCount == 102 + 5001)
        #expect(list.rows[1] == Self.member(1))
        #expect(list.rows[50] == nil)
    }

    @Test("Insert and delete move the rows after them")
    func insertAndDelete() {
        var list = MemberList()
        let groups = [MemberList.Group(id: .online, count: 3)]
        list.apply(
            [.sync(start: 0, rows: [.group(.online), Self.member(1), Self.member(2), Self.member(3)])],
            groups: groups
        )
        list.apply([.insert(1, Self.member(9))], groups: [MemberList.Group(id: .online, count: 4)])
        #expect(list.rows[1] == Self.member(9))
        #expect(list.rows[4] == Self.member(3))

        list.apply([.delete(2)], groups: groups)
        #expect(list.rows[1] == Self.member(9))
        #expect(list.rows[2] == Self.member(2))
        #expect(list.rows[3] == Self.member(3))
        #expect(list.rows[4] == nil)
    }

    @Test("An unreadable row stays a hole and keeps its neighbours in place")
    func unreadable() {
        var list = MemberList()
        list.apply(
            [.sync(start: 0, rows: [.group(.online), nil, Self.member(2)])],
            groups: [MemberList.Group(id: .online, count: 2)]
        )
        #expect(list.rows[1] == nil)
        #expect(list.rows[2] == Self.member(2))
    }

    @Test("An update this client could not read keeps the row it had, as Discord's store does")
    func unreadableUpdateKeepsTheRow() {
        var list = MemberList()
        let groups = [MemberList.Group(id: .online, count: 2)]
        list.apply([.sync(start: 0, rows: [.group(.online), Self.member(1), Self.member(2)])], groups: groups)
        list.apply([.update(1, nil)], groups: groups)
        #expect(list.rows[1] == Self.member(1))
        list.apply([.update(1, Self.member(5))], groups: groups)
        #expect(list.rows[1] == Self.member(5))
    }

    @Test("An invalidated range goes back to placeholders")
    func invalidate() {
        var list = MemberList()
        let groups = [MemberList.Group(id: .online, count: 300)]
        list.apply(
            [.sync(start: 100, rows: [Self.member(1), Self.member(2)])],
            groups: groups
        )
        list.apply([.invalidate(100...199)], groups: groups)
        #expect(list.rows.isEmpty)
    }

    @Test("A list that shrinks drops the rows past its end")
    func shrinks() {
        var list = MemberList()
        list.apply(
            [.sync(start: 0, rows: [.group(.online), Self.member(1), Self.member(2)])],
            groups: [MemberList.Group(id: .online, count: 2)]
        )
        list.apply([], groups: [MemberList.Group(id: .online, count: 1)])
        #expect(list.rowCount == 2)
        #expect(list.rows[2] == nil)
    }

    @Test("Group ids read the wire's names and role ids")
    func groupIDs() {
        #expect(MemberList.GroupID(wire: "online") == .online)
        #expect(MemberList.GroupID(wire: "offline") == .offline)
        #expect(MemberList.GroupID(wire: "7") == Self.admins)
        #expect(MemberList.GroupID(wire: "unknown") == .unknown)
    }
}
