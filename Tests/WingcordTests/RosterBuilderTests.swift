import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// What the column makes of a server's list: Discord's friend rules, on a list
/// Discord didn't build them for. See `docs/MEMBER-LIST.md`.
@Suite("Roster builder")
struct RosterBuilderTests {
    private let adminRole = RoleID(rawValue: 7)

    private func person(
        _ id: UInt64,
        _ name: String,
        status: PresenceStatus = .online,
        game: String? = nil,
        room: UInt64? = nil,
        isBot: Bool = false
    ) -> MemberEntry {
        var entry = MemberEntry(
            userID: UserID(rawValue: id), name: name, monogram: "?",
            status: status, isOnMobile: false, isBot: isBot
        )
        if let game {
            entry.liveGame = MemberLiveGame(key: game, name: game)
            entry.line = MemberRowLine(glyph: .game, text: game, isLive: true)
            entry.gameSectionLine = MemberRowLine(text: "in \(game)")
            entry.art = .placeholder(.game)
        }
        if let room {
            entry.voiceChannelID = ChannelID(rawValue: room)
            entry.voiceGroupLine = MemberRowLine(text: "here")
        }
        return entry
    }

    /// Admin 2 at rows 1 and 2; Online 3 at rows 4, 5 and 6.
    private func builder(
        _ people: [MemberEntry],
        organization: MemberListOrganization,
        collapsed: Set<String> = [],
        isWhole: Bool = true,
        rooms: [ChannelID: RosterBuilder.Room] = [:]
    ) -> RosterBuilder {
        var rows: [Int: UserID] = [:]
        for (index, row) in [1, 2, 4, 5, 6].enumerated() where index < people.count {
            rows[row] = people[index].userID
        }
        return RosterBuilder(
            identity: "list",
            groups: [
                RosterBuilder.Group(key: .role(adminRole), title: "Admin", heading: 0, count: 2),
                RosterBuilder.Group(key: .online, title: "Online", glyph: .online, heading: 3, count: 3),
            ],
            rows: rows,
            entries: Dictionary(uniqueKeysWithValues: people.map { ($0.userID, $0) }),
            organization: organization,
            collapsed: collapsed,
            isWhole: isWhole,
            rooms: rooms
        )
    }

    private var everyone: [MemberEntry] {
        [
            person(1, "ada"), person(2, "bo", game: "Tarkov"),
            person(3, "cy"), person(4, "di", game: "Sims"), person(5, "ed"),
        ]
    }

    @Test("Roles is the server's own list, row for row")
    func roles() {
        let roster = builder(everyone, organization: .roles).build()
        #expect(roster.sections.map(\.label) == ["Admin · 2", "Online · 3"])
        #expect(roster.members[1]?.name == "ada")
        #expect(roster.members[2]?.name == "bo")
        #expect(roster.members[6]?.name == "ed")
        #expect(roster.serverRow(forView: 5) == 5)
    }

    /// **Moved, not copied**, and the counts say so: Discord never draws anybody twice.
    @Test("Active Now lifts people out of their groups and sits on top")
    func activeNow() {
        let roster = builder(everyone, organization: .activeNow).build()
        #expect(roster.sections.map(\.label) == ["Active Now · 2", "Admin · 1", "Online · 2"])
        #expect(roster.sections.first?.glyph == .activeNow)
        #expect(roster.members[1]?.name == "bo")
        #expect(roster.members[2]?.name == "di")
        #expect(roster.members[4]?.name == "ada")
        #expect(roster.members[6]?.name == "cy")
        #expect(roster.members[7]?.name == "ed")
        #expect(Set(roster.members.values.map(\.name)).count == roster.members.count)
    }

    /// What the subscription runs on: the column's rows back into the server's.
    @Test("Rows lifted out of a group don't lose the server's numbers")
    func serverRows() {
        let roster = builder(everyone, organization: .activeNow).build()
        #expect(roster.serverRow(forView: 0) == nil)
        #expect(roster.serverRow(forView: 1) == nil)
        #expect(roster.serverRow(forView: 3) == 0)
        #expect(roster.serverRow(forView: 4) == 1)
        #expect(roster.serverRow(forView: 5) == 3)
        #expect(roster.serverRow(forView: 6) == 4)
        #expect(roster.serverRow(forView: 7) == 6)
    }

    @Test("Listening, or an app's slogan, isn't active")
    func whoCounts() {
        var listener = person(1, "ada")
        listener.art = .placeholder(.music)
        var bot = person(2, "bot", game: "/help", isBot: true)
        bot.line = MemberRowLine(text: "/help")
        let offline = person(3, "cy", status: .offline, game: "Tarkov")
        let roster = builder([listener, bot, offline], organization: .activeNow).build()
        #expect(roster.sections.contains { $0.key == .activeNow } == false)
    }

    @Test("Nobody active means no Active Now at all")
    func noActive() {
        let roster = builder([person(1, "ada")], organization: .activeNow).build()
        #expect(roster.sections.first?.key == .role(adminRole))
    }

    /// **A floor, and it says so**, over a list the server won't send whole.
    @Test("A count over a list that isn't held whole has a plus")
    func floor() {
        let roster = builder(everyone, organization: .activeNow, isWhole: false).build()
        #expect(roster.sections.first?.countText == "2+")
        // The server's own counts are still counts.
        #expect(roster.sections.last?.countText == "2")
    }

    /// The rows past the first page aren't live, so they stay where they are.
    @Test("Over a long list, only the first page can be lifted")
    func onlyFirstPage() {
        let rows: [Int: UserID] = [5: UserID(rawValue: 1), 150: UserID(rawValue: 2)]
        let near = person(1, "near", game: "Tarkov")
        let far = person(2, "far", game: "Tarkov")
        let roster = RosterBuilder(
            identity: "list",
            groups: [RosterBuilder.Group(key: .online, title: "Online", heading: 0, count: 5000)],
            rows: rows,
            entries: [near.userID: near, far.userID: far],
            organization: .activeNow,
            isWhole: false
        ).build()
        #expect(roster.sections.map(\.label) == ["Active Now · 1+", "Online · \(4_999.formatted())"])
        #expect(roster.members[1]?.name == "near")
        // `far` is at the server's row 150, one up for `near` having left, under
        // two more rows for Active Now's heading and its one person.
        #expect(roster.members.values.contains { $0.name == "far" })
    }

    @Test("Somebody the client hears about elsewhere joins Active Now without a row")
    func candidates() {
        var builder = builder(Array(everyone.prefix(1)), organization: .activeNow)
        let visitor = person(9, "zed", game: "Tarkov")
        builder.entries[visitor.userID] = visitor
        builder.candidates = [visitor.userID]
        let roster = builder.build()
        #expect(roster.members[1]?.name == "zed")
    }

    @Test("Game gathers each game under its name, and the row stops repeating it")
    func game() {
        let people = [
            person(1, "ada", game: "Tarkov"), person(2, "bo", game: "Sims"),
            person(3, "cy", game: "Tarkov"), person(4, "di"), person(5, "ed"),
        ]
        let roster = builder(people, organization: .game).build()
        #expect(roster.sections.map(\.label) == ["Sims · 1", "Tarkov · 2", "Online · 2"])
        #expect(roster.members[1]?.line?.text == "in Sims")
        #expect(roster.members[1]?.art == nil)
        #expect(roster.sections[1].key == .game("Tarkov"))
    }

    @Test("Alphabetical files everyone by letter, numbers and symbols last")
    func alphabetical() {
        let people = [
            person(1, "bo"), person(2, "Ada"), person(3, "9lives"), person(4, "ben", status: .offline), person(5, "Ähri"),
        ]
        let roster = builder(people, organization: .alphabetical).build()
        #expect(roster.sections.map(\.key) == [.letter("A"), .letter("B"), .letter("#")])
        #expect(roster.sections.allSatisfy { $0.span == nil })
        #expect(roster.members[1]?.name == "Ada")
        #expect(roster.members[2]?.name == "Ähri")
        // Offline people stay among the letters, as Discord's `fz` has it.
        #expect(roster.members[4]?.name == "ben")
        #expect(roster.members[5]?.name == "bo")
    }

    // MARK: Folding

    @Test("A folded section keeps its heading and its count, and draws no rows")
    func folded() {
        let roster = builder(everyone, organization: .roles, collapsed: ["online"]).build()
        let online = roster.sections.last
        #expect(online?.isCollapsed == true)
        #expect(online?.count == 0)
        #expect(online?.countText == "3")
        #expect(roster.rowCount == 4)
        #expect(roster.members.count == 2)
        #expect(roster.serverRow(forView: 3) == 3)
    }

    @Test("Offline names itself and no count")
    func offlineHasNoCount() {
        let builder = RosterBuilder(
            identity: "list",
            groups: [RosterBuilder.Group(key: .offline, title: "Offline", glyph: .offline, heading: 0, count: 30)],
            rows: [:],
            entries: [:],
            organization: .roles,
            isWhole: true
        )
        #expect(builder.build().sections.first?.label == "Offline")
    }

    @Test("A list with no name yet is one heading that can't fold")
    func placeholder() {
        let roster = RosterBuilder(
            identity: "list",
            groups: [RosterBuilder.Group(key: .unknown, heading: 0, count: 0)],
            rows: [:],
            entries: [:],
            organization: .activeNow,
            collapsed: ["unknown"],
            isWhole: true
        ).build()
        #expect(roster.sections.count == 1)
        #expect(roster.sections.first?.isPlaceholder == true)
        #expect(roster.sections.first?.canCollapse == false)
        #expect(roster.sections.first?.isCollapsed == false)
    }

    // MARK: Rooms

    private func room(_ occupants: Int, isReaderIn: Bool = false) -> RosterBuilder.Room {
        RosterBuilder.Room(name: "lounge", isStage: false, occupants: occupants, isReaderIn: isReaderIn, canJoin: true)
    }

    @Test("Two in a room gather under it, first; one alone stays a row")
    func rooms() {
        let people = [
            person(1, "ada", room: 50), person(2, "bo", game: "Tarkov"),
            person(3, "cy", room: 50), person(4, "di", room: 60), person(5, "ed"),
        ]
        let roster = builder(
            people, organization: .activeNow,
            rooms: [ChannelID(rawValue: 50): room(3), ChannelID(rawValue: 60): room(1)]
        ).build()
        #expect(roster.sections.map(\.key.storageKey) == ["active_now", "voice:50", "rest:active_now", "online"])
        // Everybody counts in the heading, wherever they ended up under it.
        #expect(roster.sections[0].countText == "4")
        guard case .voiceGroup(let group) = roster.sections[1].kind else {
            Issue.record("the second section is the room")
            return
        }
        #expect(group.extraCount == 1)
        #expect(roster.members[2]?.name == "ada")
        #expect(roster.members[2]?.line?.text == "here")
        #expect(roster.members[3]?.name == "cy")
        #expect(roster.sections[2].kind == .continuation)
        #expect(roster.members[5]?.name == "bo")
        #expect(roster.members[6]?.name == "di")
    }

    @Test("The reader isn't one of the others in the room")
    func readerIsNotExtra() {
        let people = [person(1, "ada", room: 50), person(2, "bo", room: 50)]
        let roster = builder(
            people, organization: .activeNow,
            rooms: [ChannelID(rawValue: 50): room(3, isReaderIn: true)]
        ).build()
        guard case .voiceGroup(let group) = roster.sections[1].kind else {
            Issue.record("the second section is the room")
            return
        }
        #expect(group.extraCount == 0)
    }

    @Test("Folding a section folds its rooms with it")
    func foldedRooms() {
        let people = [person(1, "ada", room: 50), person(2, "bo", room: 50)]
        let roster = builder(
            people, organization: .activeNow, collapsed: ["active_now"],
            rooms: [ChannelID(rawValue: 50): room(2)]
        ).build()
        #expect(roster.sections.first?.isCollapsed == true)
        #expect(!roster.sections.contains { if case .voiceGroup = $0.kind { true } else { false } })
    }

    @Test("Turned off, nobody gathers")
    func noRooms() {
        let people = [person(1, "ada", room: 50), person(2, "bo", room: 50)]
        let roster = builder(people, organization: .activeNow, rooms: [:]).build()
        #expect(roster.sections.first?.count == 2)
    }

    // MARK: Layout

    @Test("Rooms lay out by Discord's arithmetic, and the rows still round-trip")
    func roomLayout() {
        let people = [
            person(1, "ada", room: 50), person(2, "bo", room: 50), person(3, "cy", game: "Tarkov"),
        ]
        let roster = builder(
            people, organization: .activeNow,
            rooms: [ChannelID(rawValue: 50): room(3)]
        ).build()
        let layout = RosterLayout(roster)
        let room = layout.sectionFrame(1, width: 288)
        // `2 * 16 + 24 + 4 + 2 * 50 + 24`.
        #expect(room.height == CGFloat(184))
        #expect(layout.bodyHeight(ofSectionAt: 0) == CGFloat(184 + 50))
        for index in 0..<roster.rowCount where roster.members[index] != nil {
            #expect(layout.index(at: layout.frame(at: index, width: 288).midY) == index, "row \(index)")
        }
        // The rest of the section has no heading to hit.
        #expect(layout.frame(at: roster.sections[2].index, width: 288).height == 0)
    }

    @Test("The hairline is every heading's but the first's, and a room has none")
    func hairlines() {
        let people = [person(1, "ada", room: 50), person(2, "bo", room: 50), person(3, "cy")]
        let roster = builder(
            people, organization: .activeNow,
            rooms: [ChannelID(rawValue: 50): room(2)]
        ).build()
        let layout = RosterLayout(roster)
        #expect(layout.isSeparated(0) == false)
        #expect(layout.isSeparated(1) == false)
        #expect(layout.isSeparated(roster.sections.count - 1) == true)
        #expect(RosterLayout(roster, separatesFirst: true).isSeparated(0) == true)
    }
}
