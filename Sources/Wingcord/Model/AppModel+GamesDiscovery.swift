import Foundation
import WingcordCore
import WingcordNet

/// Discover's Games tab: what each section shows and where it came from
/// (`2026-10-game-discovery`, docs/QUEUE-NOV19.md §1).
struct GamesDiscoveryState {
    enum Section: Hashable, Sendable {
        case featured
        case trending
    }

    var section: Section = .featured

    var trending: TrendingGames?
    var trendingFailed = false
    var trendingLoadedAt: Date?

    /// What the reader has played; nil until asked.
    var played: [GamePlayStatistic]?
    var playedLoadedAt: Date?
    /// Each Jump back in game's latest announcement.
    var announcements: [ApplicationID: GameAnnouncementCard] = [:]

    var similarSeed: ApplicationID?
    var similar: [ApplicationID] = []

    var search = Search()

    struct Search: Equatable {
        var query = ""
        var genres: Set<Int> = []
        var platforms: Set<String> = []
        var page = 1
        var results: [ApplicationID] = []
        var total = 0
        var genreCounts: [GameSearchPage.Facet<Int>] = []
        var platformCounts: [GameSearchPage.Facet<String>] = []
        var isLoading = false
        var failed = false

        var pageCount: Int {
            let capped = min(total, DiscordREST.gameSearchMaxResults)
            return max(1, Int(ceil(Double(capped) / Double(DiscordREST.gameSearchPageSize))))
        }
    }
}

/// One game in a shelf, with whatever its shelf says about it.
struct GameShelfItem: Identifiable, Hashable {
    var game: Game
    /// Trending's rank.
    var rank: Int?
    /// Two genres, "Adventure • Shooter", for Trending's covers.
    var genres: String?
    /// Friends on this game, for the friend shelves.
    var friends: [UserID] = []
    var id: ApplicationID { game.id }
}

/// One of Jump back in's cards.
struct JumpBackInItem: Identifiable, Hashable {
    var game: Game
    var isPlayingNow: Bool
    var lastPlayedAt: Date?
    /// "11 friends played this week", where the activity feed knows it.
    var friendsThisWeek: Int
    var announcement: GameAnnouncementCard?
    var id: ApplicationID { game.id }
}

extension AppModel {
    /// Whether Discover shows Games: Discord's assignment (variant 1), or the
    /// reader's preview toggle.
    var offersGamesDiscovery: Bool {
        if AppSettings.shared.showsGamesDiscovery { return true }
        let hash = MurmurHash3.hash32("2026-10-game-discovery")
        return experiments.apexReader[hash]?.variantID == 1
    }

    /// Discord's 18 category names (`df1df7d8`).
    static func gameCategoryName(_ id: Int) -> String? {
        let names = [
            "Adventure", "Crafting", "Fantasy", "FPS", "Horror", "Indie", "MMO", "Open World", "RPG",
            "Sandbox", "Sci-Fi", "Shooter", "Simulation", "Sports", "Story Rich", "Strategy", "Survival", "Tactical",
        ]
        return (1...names.count).contains(id) ? names[id - 1] : nil
    }

    static func gamePlatformName(_ value: String) -> String {
        switch value {
        case "desktop": "Desktop"
        case "mobile": "Mobile"
        case "console": "Console"
        case "roblox": "Roblox"
        default: value.capitalized
        }
    }

    /// The order Discord lists platforms in.
    static let gamePlatformOrder = ["desktop", "mobile", "console", "roblox"]

    // MARK: Featured

    var trendingShelf: [GameShelfItem] {
        (gamesDiscovery.trending?.entries ?? []).prefix(10).compactMap { entry in
            guard let game = games[entry.gameID] else { return nil }
            let genres = entry.categories.prefix(2).compactMap(Self.gameCategoryName).joined(separator: " \u{2022} ")
            return GameShelfItem(game: game, rank: entry.rank, genres: genres.isEmpty ? nil : genres)
        }
    }

    /// The reader's five most recent games (Discord's `lF`), newest first.
    var jumpBackIn: [JumpBackInItem] {
        let running = Set(runningGameIDs)
        let friendCounts = friendsThisWeekByGame()
        var seen = Set<ApplicationID>()
        var items: [JumpBackInItem] = []
        for stat in (gamesDiscovery.played ?? []).prefix(5) {
            guard let game = games[stat.applicationID], seen.insert(game.id).inserted else { continue }
            items.append(JumpBackInItem(
                game: game,
                isPlayingNow: running.contains(game.id),
                lastPlayedAt: stat.lastPlayedAt,
                friendsThisWeek: friendCounts[game.id]?.count ?? 0,
                announcement: gamesDiscovery.announcements[game.id]
            ))
        }
        return items
    }

    var similarShelf: (seed: Game, items: [GameShelfItem])? {
        guard let seedID = gamesDiscovery.similarSeed, let seed = games[seedID] else { return nil }
        let items = gamesDiscovery.similar.prefix(8).compactMap { games[$0].map { GameShelfItem(game: $0) } }
        return items.isEmpty ? nil : (seed, items)
    }

    /// Games friends are playing right now, most friends first — Wingcord's
    /// own answer to a shelf Discord's code leaves empty (G3).
    var playWithFriendsShelf: [GameShelfItem] {
        var byGame: [ApplicationID: [UserID]] = [:]
        for (userID, relationship) in relationships where relationship == .friend {
            for activity in presences[userID]?.activities?.list ?? [] where activity.kind == .playing {
                let id = activity.applicationID ?? gamesByActivityName[Self.activityNameKey(activity.name)]
                if let id { byGame[id, default: []].append(userID) }
            }
        }
        return ranked(byGame)
    }

    /// Games most friends played lately (the activity feed), most friends
    /// first — Wingcord's own answer to the other empty shelf (G3).
    var friendsAreIntoShelf: [GameShelfItem] {
        ranked(friendsThisWeekByGame())
    }

    private func ranked(_ byGame: [ApplicationID: [UserID]]) -> [GameShelfItem] {
        byGame
            .compactMap { id, friends in games[id].map { GameShelfItem(game: $0, friends: Array(Set(friends))) } }
            .sorted { $0.friends.count == $1.friends.count ? $0.game.name < $1.game.name : $0.friends.count > $1.friends.count }
            .prefix(12)
            .map { $0 }
    }

    /// Who among friends played each game in the activity feed this week.
    func friendsThisWeekByGame(now: Date = Date()) -> [ApplicationID: [UserID]] {
        var byGame: [ApplicationID: Set<UserID>] = [:]
        for entry in activityFeed.inbox?.entries ?? [] {
            guard case .game(_, let applicationID?) = entry.activity.subject,
                  relationships[entry.activity.authorID] == .friend
            else { continue }
            let when = entry.activity.endedAt ?? entry.activity.startedAt ?? now
            guard now.timeIntervalSince(when) < 7 * 86_400 else { continue }
            byGame[applicationID, default: []].insert(entry.activity.authorID)
        }
        return byGame.mapValues { Array($0) }
    }

    /// The games this Mac sees running, by id.
    var runningGameIDs: [ApplicationID] {
        (presences[currentUserID ?? UserID(rawValue: 0)]?.activities?.list ?? [])
            .filter { $0.kind == .playing }
            .compactMap(\.applicationID)
    }

    // MARK: Trending

    var trendingRows: [(entry: TrendingGames.Entry, game: Game, isNew: Bool)] {
        guard let trending = gamesDiscovery.trending else { return [] }
        let week = trending.week.flatMap { ISO8601DateFormatter.weekDay.date(from: $0) }
        return trending.entries.compactMap { entry in
            guard let game = games[entry.gameID] else { return nil }
            // Discord's "New" (`lH`): no change, and released in the week
            // before the list's own week.
            var isNew = false
            if entry.playersChange == 0, let week, let released = game.releaseDate {
                isNew = released > week.addingTimeInterval(-7 * 86_400) && released <= week
            }
            return (entry, game, isNew)
        }
    }

    var trendingWeekLine: String? {
        guard let week = gamesDiscovery.trending?.week.flatMap({ ISO8601DateFormatter.weekDay.date(from: $0) })
        else { return nil }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "Week of \(formatter.string(from: week))"
    }
}

extension ISO8601DateFormatter {
    /// "2026-11-16", the trending list's week.
    static let weekDay: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}
