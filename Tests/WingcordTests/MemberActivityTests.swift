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

    @Test("A card's chips: New Player in green, a streak only from three fresh days")
    func badges() throws {
        let fresh = String((UInt64(Date.now.timeIntervalSince1970 * 1000) - 1_420_070_400_000) << 22)
        let model = model(entries: [
            entry(fresh, author: 11, rank: 1, traits: [.newPlayer, .streak(days: 4), .trending]),
        ])
        let card = try #require(model.memberActivityBlock?.cards.first)
        let labels = card.badges.compactMap { badge -> String? in
            if case .label(_, let text, _) = badge { return text }
            return nil
        }
        #expect(labels == ["New Player", "4x Streak", "Trending"])
        #expect(card.badges.contains(.label(symbol: "person.fill.badge.plus", text: "New Player", isPositive: true)))
    }

    @Test("The section's own geometry: a heading, then 72-point cards")
    func geometry() {
        let card = MemberActivityCard(
            id: "1", authorID: UserID(rawValue: 1), faces: [], name: "A", title: "T",
            badges: [], artURL: nil, artSymbol: "gamecontroller.fill", liveSince: nil, occurredAt: nil
        )
        let block = MemberActivityBlock(count: 2, isExpanded: false, isHidden: false, cards: [card, card])
        #expect(block.height == MemberActivityGeometry.headerHeight + 144)
        #expect(block.cardIndex(at: 1) == nil)
        #expect(block.cardIndex(at: MemberActivityGeometry.headerHeight + 80) == 1)
        #expect(block.cardIndex(at: block.height + 1) == nil)
    }
}
