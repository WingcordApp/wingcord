import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// A game profile's Communities tab, through what the page reads.
@MainActor
@Suite("Game communities")
struct GameCommunitiesTests {

    private let gameID = ApplicationID(rawValue: 1)

    private func model(ids: Int, landed: Int? = nil) -> AppModel {
        let model = AppModel()
        var game = Game(id: gameID, name: "Cyberpunk 2077")
        game.communityGuildIDs = (0..<ids).map { GuildID(rawValue: 100 + UInt64($0)) }
        model.games[gameID] = game
        for (index, id) in game.communityGuildIDs.prefix(landed ?? ids).enumerated() {
            model.communityGuilds[id] = DiscoverableGuild(
                id: id, name: "Server \(index)", memberCount: 1_000 * (index + 1), onlineCount: 10,
                preferredLocale: index.isMultiple(of: 2) ? "en-US" : "fr"
            )
            model.communityGuildsFetchedAt[id] = .now
        }
        return model
    }

    @Test("The tab needs three servers, Discord's own rule")
    func threshold() {
        #expect(model(ids: 2).gamePresentation(for: gameID)?.hasCommunities == false)
        #expect(model(ids: 3).gamePresentation(for: gameID)?.hasCommunities == true)
    }

    @Test("Cards come in the game's own order, and know which servers are joined")
    func tilesInOrder() throws {
        let model = model(ids: 4)
        model.guilds[GuildID(rawValue: 101)] = Guild(id: GuildID(rawValue: 101), name: "Server 1", ownerID: UserID(rawValue: 9))
        let tiles = try #require(model.communityTiles(for: gameID))
        #expect(tiles.map(\.name) == ["Server 0", "Server 1", "Server 2", "Server 3"])
        #expect(tiles.map(\.isJoined) == [false, true, false, false])
    }

    @Test("Nothing landed and nothing asked is still loading; answered with none is empty")
    func loadingVersusEmpty() {
        let waiting = model(ids: 3, landed: 0)
        #expect(waiting.communityTiles(for: gameID) == nil)
        for id in waiting.games[gameID]!.communityGuildIDs { waiting.communityGuildsFetchedAt[id] = .now }
        #expect(waiting.communityTiles(for: gameID) == [])
    }

    @Test("The language filter lists the commonest language first")
    func locales() throws {
        let tiles = try #require(model(ids: 5).communityTiles(for: gameID))
        #expect(GameCommunitiesPage.locales(in: tiles) == ["en-US", "fr"])
    }
}
