import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore
@testable import WingcordNet

/// Discover › Games' shelves (docs/QUEUE-NOV19.md §1): what each one shows
/// from what the model holds, and when the tab is offered.
@MainActor
@Suite("Games in Discover")
struct GamesDiscoveryTests {
    private let hades = ApplicationID(rawValue: 100)
    private let tunic = ApplicationID(rawValue: 101)
    private let friendA = UserID(rawValue: 42)
    private let friendB = UserID(rawValue: 43)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 7)
        model.games[hades] = Game(id: hades, name: "Hades")
        model.games[tunic] = Game(id: tunic, name: "Tunic", releaseDate: Date(timeIntervalSince1970: 1_794_528_000))
        return model
    }

    @Test("Trending's shelf shows the rank and two genres")
    func trendingShelf() {
        let model = model()
        model.gamesDiscovery.trending = TrendingGames(week: "2026-11-16", entries: [
            .init(gameID: hades, rank: 1, playersChange: 0.12, categories: [1, 12, 9], officialGuild: nil),
        ])
        let item = model.trendingShelf.first
        #expect(item?.rank == 1)
        #expect(item?.genres == "Adventure \u{2022} Shooter")
    }

    @Test("A game with no change released in the week before the list's week is New")
    func newRelease() {
        let model = model()
        // 2026-11-16 is the list's week; Tunic came out on 2026-11-13.
        model.gamesDiscovery.trending = TrendingGames(week: "2026-11-16", entries: [
            .init(gameID: tunic, rank: 1, playersChange: 0, categories: [], officialGuild: nil),
            .init(gameID: hades, rank: 2, playersChange: 0, categories: [], officialGuild: nil),
        ])
        let rows = model.trendingRows
        #expect(rows.first?.isNew == true)
        #expect(rows.last?.isNew == false)
        // In the Mac's own date order ("Nov 16" or "16 Nov").
        #expect(model.trendingWeekLine?.hasPrefix("Week of ") == true)
        #expect(model.trendingWeekLine?.contains("16") == true)
    }

    @Test("Friends playing now fill Play with your friends, most friends first")
    func playWithFriends() {
        let model = model()
        model.relationships = [friendA: .friend, friendB: .friend]
        let playing = { (id: ApplicationID) in
            Presence(userID: UserID(rawValue: 1), status: .online, activities: PresenceActivities(list: [
                Activity(kind: .playing, name: "game", applicationID: id),
            ]))
        }
        model.presences[friendA] = playing(hades)
        model.presences[friendB] = playing(hades)
        let shelf = model.playWithFriendsShelf
        #expect(shelf.first?.game.id == hades)
        #expect(shelf.first?.friends.count == 2)
    }

    @Test("The tab is offered by Discord's assignment or the preview")
    func gate() async {
        let model = model()
        await withAppSettings(\.showsGamesDiscovery) { settings in
            settings.showsGamesDiscovery = false
            #expect(!model.offersGamesDiscovery)
            settings.showsGamesDiscovery = true
            #expect(model.offersGamesDiscovery)
            settings.showsGamesDiscovery = false
            let hash = MurmurHash3.hash32("2026-10-game-discovery")
            model.experiments.apexReader[hash] = ApexAssignment(hash: hash, variantID: 1, isOverride: false, revision: 0)
            #expect(model.offersGamesDiscovery)
        }
    }
}
