import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The member list's Activity section, through the store's own projection.
@MainActor
@Suite("Member list activity")
struct MemberActivityTests {

    private let me = UserID(rawValue: 1)
    private let guildID = GuildID(rawValue: 100)
    private let channelID = ChannelID(rawValue: 200)

    private func entry(_ id: String, author: UInt64, rank: Int, traits: [RecentActivity.Trait] = []) -> ActivityFeedEntry {
        ActivityFeedEntry(
            activity: RecentActivity(
                id: id, authorID: UserID(rawValue: author),
                subject: .game(name: "Game \(id)", applicationID: nil),
                traits: traits
            ),
            rank: rank,
            participants: [UserID(rawValue: author)],
            raw: Data("{}".utf8)
        )
    }

    private func model(entries: [ActivityFeedEntry], memberCount: Int = 50) -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.guilds[guildID] = Guild(id: guildID, name: "Test", ownerID: me, memberCount: memberCount)
        // @everyone may see channels.
        model.roles[guildID] = [
            RoleID(rawValue: guildID.rawValue): Role(id: RoleID(rawValue: guildID.rawValue), name: "@everyone", permissions: .viewChannel),
        ]
        var members: [UserID: Member] = [me: Member(userID: me, roleIDs: [])]
        for author in Set(entries.map(\.activity.authorID)) {
            members[author] = Member(userID: author, roleIDs: [])
            model.users[author] = User(id: author, username: "user\(author.rawValue)")
            model.presences[author] = Presence(userID: author, status: .online)
        }
        model.members[guildID] = members
        model.channelIndex.replaceChannels(
            [Channel(id: channelID, kind: .text, guildID: guildID, name: "general")],
            inGuild: guildID
        )
        model.selectedGuildID = guildID
        model.selectedChannelID = channelID
        model.activityFeed.inbox = ActivityInbox(entries: entries, refreshToken: nil, expiresAt: nil, announcesStaleness: false)
        return model
    }

    @Test("Three cards until it is unfolded, in the server's order")
    func collapsedThenExpanded() async throws {
        try await withAppSettings(\.hidesActivityCards) { settings in
            let entries = (1...5).map { entry("\($0)", author: UInt64(10 + $0), rank: 6 - $0) }
            let model = model(entries: entries)
            settings.hidesActivityCards = false
            let block = try #require(model.memberActivityBlock)
            #expect(block.count == 5)
            #expect(block.cards.map(\.id) == ["5", "4", "3"])
            #expect(block.canToggle)
            model.toggleActivitySection()
            #expect(model.memberActivityBlock?.cards.count == 5)
        }
    }

    @Test("Hidden keeps the heading and folds the cards away")
    func hidden() async throws {
        try await withAppSettings(\.hidesActivityCards) { settings in
            let model = model(entries: [entry("1", author: 11, rank: 1)])
            settings.hidesActivityCards = true
            let block = try #require(model.memberActivityBlock)
            #expect(block.isHidden)
            #expect(block.cards.isEmpty)
            #expect(block.height == MemberActivityGeometry.headerHeight)
            // The heading brings it back.
            model.toggleActivitySection()
            #expect(settings.hidesActivityCards == false)
        }
    }

    @Test("A server of ten thousand shows no section, and nobody outside the server is shown")
    func audience() {
        #expect(model(entries: [entry("1", author: 11, rank: 1)], memberCount: 10_000).memberActivityBlock == nil)
        let stranger = model(entries: [entry("1", author: 11, rank: 1)])
        stranger.members[guildID]?[UserID(rawValue: 11)] = nil
        #expect(stranger.memberActivityBlock == nil)
    }

    @Test("A card's markers: Discord's order, the first two drawn, New Player's glyph green")
    func markers() throws {
        let fresh = String((UInt64(Date.now.timeIntervalSince1970 * 1000) - 1_420_070_400_000) << 22)
        let model = model(entries: [
            entry(fresh, author: 11, rank: 1, traits: [.newPlayer, .streak(days: 4), .trending]),
        ])
        let card = try #require(model.memberActivityBlock?.cards.first)
        let labels = card.markers.compactMap { marker -> String? in
            if case .words(let text) = marker.text { return text }
            return nil
        }
        #expect(labels == ["New Player", "4x Streak", "Trending"])
        #expect(card.markers.first { $0.text == .words("New Player") }?.tintsSymbol == true)
        #expect(card.markers.first { $0.text == .words("4x Streak") }?.tooltip == "Played 4 days in a row")
    }

    /// `--demo` draws one entry of every kind (`DemoActivityFeed`): if the
    /// fixtures stop reaching the section, the demo can't show the cards.
    @Test("The demo's section holds every kind, and its popouts resolve")
    func demoFeed() async throws {
        try await withAppSettings(\.hidesActivityCards) { settings in
            settings.hidesActivityCards = false
            let demo = AppModel()
            DemoFixtures.populate(demo)
            let block = try #require(demo.memberActivityBlock)
            #expect(block.count == 7)
            let guildID = try #require(demo.selectedGuildID)
            let entries = demo.activityFeed.inbox?.entries ?? []
            let titles = entries.map { demo.activityPopout(for: $0, inGuild: guildID, now: .now).verb }
            #expect(titles.contains("listened to"))
            #expect(titles.contains("is playing"))
            #expect(titles.contains("is listening to"))
            // The live game names its party, and its popout its voice room.
            let live = try #require(entries.first { $0.activity.isLive && $0.activity.subject.isMusic == false })
            let popout = demo.activityPopout(for: live, inGuild: guildID, now: .now)
            #expect(popout.markers.contains { $0.text == .words("In a Match (2 of 4)") })
            #expect(popout.voice != nil)
        }
    }

    @Test("The section's own geometry: a heading, then Discord's 78-point bands")
    func geometry() {
        let card = MemberActivityCard(
            id: "1", authorID: UserID(rawValue: 1), faces: [], extraPeople: 0, name: "A", nameColor: nil,
            nameFont: nil, title: "T", markers: [], artURL: nil, artSymbol: "gamecontroller.fill",
            liveSince: nil, occurredAt: nil
        )
        let block = MemberActivityBlock(count: 2, isExpanded: false, isHidden: false, cards: [card, card])
        #expect(block.height == MemberActivityGeometry.headerHeight + 156)
        #expect(block.cardIndex(at: 1) == nil)
        #expect(block.cardIndex(at: MemberActivityGeometry.headerHeight + 80) == 1)
        #expect(block.cardIndex(at: block.height + 1) == nil)
    }
}

/// The list's height counts the Activity section above the rows (Alex,
/// 2026-11-16: "the offline users go past overscroll and I can't see them").
@MainActor
struct MemberListHeightTests {
    @Test("The document holds the Activity section and every row under it")
    func heightIncludesActivity() {
        let canvas = MemberListCanvas(style: MessageTextStyle.current())
        canvas.frame = CGRect(x: 0, y: 0, width: 280, height: 600)
        var roster = Roster(identity: "1:everyone", sections: [], members: [:], rowCount: 0)
        roster.sections.append(RosterSection(
            key: .role(RoleID(rawValue: 1)), title: "Offline", countText: "3", index: 0, count: 3
        ))
        roster.rowCount = 4
        let rowsOnly = canvas.apply(roster: roster)
        let block = MemberActivityBlock(count: 0, isExpanded: false, isHidden: false, cards: [])
        canvas.apply(activity: block)
        let withActivity = canvas.apply(roster: roster)
        // The section on top, and the hairline its arrival puts over the first
        // heading (`RosterLayout.isSeparated`).
        let hairline = MemberSectionGeometry.separatedHeight - MemberSectionGeometry.height
        #expect(withActivity == rowsOnly + block.height + hairline)
        // The last row ends inside the document, where a scroll can reach it.
        #expect(canvas.rowFrame(at: 3).maxY <= withActivity)
    }
}
