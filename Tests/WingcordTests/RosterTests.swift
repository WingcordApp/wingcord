import AppKit
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The member list column, from the server's list through the roster the
/// canvas draws.
///
/// **The report this answers**: a column that ended at the hundredth row and
/// counted only the members this client held — "Level 20 — 11" beside
/// Discord's "Level 20 — 101".
@MainActor
@Suite("Roster")
struct RosterTests {

    private let guild = GuildID(rawValue: 100)
    private let general = ChannelID(rawValue: 101)
    private let staff = ChannelID(rawValue: 102)
    private let thread = ChannelID(rawValue: 103)
    private let level20 = RoleID(rawValue: 20)
    private let ada = UserID(rawValue: 1)
    private let bo = UserID(rawValue: 2)
    private let cy = UserID(rawValue: 3)

    private func model() -> AppModel {
        let model = AppModel()
        model.guilds = [guild: Guild(id: guild, name: "Here", ownerID: ada)]
        model.roles[guild] = [
            RoleID(rawValue: guild.rawValue): Role(
                id: RoleID(rawValue: guild.rawValue), name: "@everyone", position: 0,
                permissions: [.viewChannel]
            ),
            level20: Role(id: level20, name: "Level 20", isHoisted: true, position: 5),
        ]
        for (id, name) in [(ada, "ada"), (bo, "bo"), (cy, "cy")] {
            model.users[id] = User(id: id, username: name)
        }
        model.members[guild] = [
            ada: Member(userID: ada, roleIDs: [level20]),
            bo: Member(userID: bo, roleIDs: [level20]),
            cy: Member(userID: cy, roleIDs: []),
        ]
        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: general, kind: .text, guildID: guild, name: "general"),
                Channel(
                    id: staff, kind: .text, guildID: guild, name: "staff",
                    overwrites: [PermissionOverwrite(
                        id: guild.rawValue, subject: .role, allow: [], deny: .viewChannel
                    )]
                ),
                Channel(id: thread, kind: .publicThread, guildID: guild, name: "a thread", parentID: staff),
            ],
            inGuild: guild
        )
        model.channelIndex = index
        model.selectedGuildID = guild
        model.selectedChannelID = general
        return model
    }

    /// The first page of a server whose groups run far past it.
    private func firstPage() -> MemberList {
        var list = MemberList()
        list.apply(
            [.sync(start: 0, rows: [.group(.role(level20)), .member(ada), .member(bo)])],
            groups: [
                MemberList.Group(id: .role(level20), count: 101),
                MemberList.Group(id: .online, count: 700),
            ]
        )
        return list
    }

    @Test("The headings count the server's groups, not the members held")
    func countsAreTheServers() {
        let model = model()
        model.memberLists[MemberListKey(guildID: guild, listID: "everyone")] = firstPage()
        let roster = model.roster
        #expect(roster.sections.map(\.label) == ["Level 20 — 101", "Online — 700"])
        #expect(roster.sections.map(\.index) == [0, 102])
        #expect(roster.rowCount == 102 + 701)
    }

    @Test("Only the rows the server sent are built; the rest are placeholders")
    func placeholders() {
        let model = model()
        model.memberLists[MemberListKey(guildID: guild, listID: "everyone")] = firstPage()
        let roster = model.roster
        #expect(roster.members.keys.sorted() == [1, 2])
        #expect(roster.members[1]?.userID == ada)

        let layout = RosterLayout(roster)
        guard case .placeholder = layout.row(at: 50, in: roster) else {
            Issue.record("row 50 has not been sent and must be a placeholder")
            return
        }
        guard case .header(let online) = layout.row(at: 102, in: roster) else {
            Issue.record("row 102 is the Online heading")
            return
        }
        #expect(online.label == "Online — 700")
    }

    @Test("Before the server answers, the list is one unnamed heading")
    func beforeTheAnswer() {
        let roster = model().roster
        #expect(roster.sections.count == 1)
        #expect(roster.sections.first?.label == nil)
        #expect(roster.rowCount == 1)
    }

    @Test("A restricted channel shows a different list than the shared one")
    func restrictedChannel() {
        let model = model()
        let open = model.memberListTarget(for: general)
        let restricted = model.memberListTarget(for: staff)
        #expect(open?.key.listID == "everyone")
        #expect(restricted?.key.listID != "everyone")
        #expect(restricted?.channelID == staff)
    }

    @Test("A thread shows, and subscribes, its parent's list")
    func threadShowsItsParent() {
        let model = model()
        let target = model.memberListTarget(for: thread)
        #expect(target?.channelID == staff)
        #expect(target?.key == model.memberListTarget(for: staff)?.key)
    }

    // MARK: Layout

    @Test("Positions are arithmetic over the sections, both ways")
    func layoutRoundTrips() {
        let model = model()
        model.memberLists[MemberListKey(guildID: guild, listID: "everyone")] = firstPage()
        let layout = RosterLayout(model.roster)
        let header = RosterLayout.headerHeight
        let member = RosterLayout.memberHeight

        #expect(layout.contentHeight == 2 * header + 801 * member)
        for index in [0, 1, 2, 101, 102, 103, 802] {
            let frame = layout.frame(at: index, width: 240)
            #expect(layout.index(at: frame.midY) == index, "row \(index)")
        }
        #expect(layout.frame(at: 102, width: 240).minY == header + 101 * member)
        #expect(layout.frame(at: 102, width: 240).height == header)
        #expect(layout.index(at: -40) == 0)
        #expect(layout.index(at: layout.contentHeight + 40) == 802)
    }

    @Test("A heading with nobody under it is still one row")
    func emptyGroup() {
        let model = model()
        var list = MemberList()
        list.apply([], groups: [
            MemberList.Group(id: .role(level20), count: 0),
            MemberList.Group(id: .online, count: 2),
        ])
        model.memberLists[MemberListKey(guildID: guild, listID: "everyone")] = list
        let layout = RosterLayout(model.roster)
        #expect(layout.rowCount == 4)
        #expect(layout.index(at: RosterLayout.headerHeight + 1) == 1)
        #expect(layout.index(at: 2 * RosterLayout.headerHeight + 1) == 2)
    }
}
