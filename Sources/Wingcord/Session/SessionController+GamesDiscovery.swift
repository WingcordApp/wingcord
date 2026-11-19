import Foundation
import WingcordCore
import WingcordNet

/// Discover's Games tab, asked the way Discord's page asks
/// (docs/QUEUE-NOV19.md §1): trending every six hours, the reader's games and
/// what is like them once, the friends' shelves from what is already held.
extension SessionController {
    /// Everything the Featured and Trending sections draw.
    func loadGamesDiscovery() {
        let state = model.gamesDiscovery
        let now = Date()
        Task { [weak self] in
            guard let self else { return }
            var wanted: [ApplicationID] = []

            if state.trendingLoadedAt.map({ now.timeIntervalSince($0) > 6 * 3_600 }) ?? true {
                do {
                    let trending = try await rest.trendingGames()
                    model.gamesDiscovery.trending = trending
                    model.gamesDiscovery.trendingFailed = false
                    model.gamesDiscovery.trendingLoadedAt = Date()
                } catch {
                    model.gamesDiscovery.trendingFailed = true
                    Self.trace("trending games failed: \(Self.describe(error))")
                }
            }
            wanted += model.gamesDiscovery.trending?.entries.map(\.gameID) ?? []

            if state.playedLoadedAt.map({ now.timeIntervalSince($0) > 6 * 3_600 }) ?? true {
                do {
                    model.gamesDiscovery.played = try await rest.playStatistics()
                    model.gamesDiscovery.playedLoadedAt = Date()
                } catch {
                    if model.gamesDiscovery.played == nil { model.gamesDiscovery.played = [] }
                    Self.trace("play statistics failed: \(Self.describe(error))")
                }
            }
            let played = model.gamesDiscovery.played ?? []
            let recent = played.prefix(5).map(\.applicationID)
            wanted += recent

            // The friends' shelves name games by what friends are doing.
            wanted += model.playWithFriendsGameIDs + Array(model.friendsThisWeekByGame().keys)
            if model.activityFeed.inbox == nil { loadActivityFeed() }

            await loadGames(ids: Array(Set(wanted)))

            // Jump back in's latest update, one request for all five.
            let needAnnouncements = recent.filter { model.gamesDiscovery.announcements[$0] == nil }
            if !needAnnouncements.isEmpty,
               let latest = try? await rest.latestGameAnnouncements(needAnnouncements)
            {
                for (gameID, message) in latest {
                    if let card = AppModel.announcementCard(message) {
                        model.gamesDiscovery.announcements[gameID] = card
                    }
                }
            }

            // Because you played: the latest game with half an hour on it.
            if model.gamesDiscovery.similarSeed == nil,
               let seed = played.first(where: { $0.totalDuration >= 30 * 60 })?.applicationID,
               let similar = try? await rest.similarGames(to: seed)
            {
                await loadGames(ids: Array(similar.prefix(8)) + [seed])
                model.gamesDiscovery.similarSeed = seed
                model.gamesDiscovery.similar = similar
            }
        }
    }

    /// A page of Discord's game search with the filters the reader set.
    func searchGamesDiscovery() {
        let search = model.gamesDiscovery.search
        let query = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        model.gamesDiscovery.search.isLoading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await rest.discoverGames(
                    query: query,
                    genres: Array(search.genres),
                    platforms: Array(search.platforms),
                    offset: (search.page - 1) * DiscordREST.gameSearchPageSize
                )
                // A newer search went out while this one was away.
                guard model.gamesDiscovery.search.query == search.query,
                      model.gamesDiscovery.search.genres == search.genres,
                      model.gamesDiscovery.search.platforms == search.platforms,
                      model.gamesDiscovery.search.page == search.page
                else { return }
                for game in page.games { model.games[game.id] = game }
                model.gamesDiscovery.search.results = page.games.map(\.id)
                model.gamesDiscovery.search.total = page.totalCount
                model.gamesDiscovery.search.genreCounts = page.genreCounts
                model.gamesDiscovery.search.platformCounts = page.platformCounts
                model.gamesDiscovery.search.failed = false
            } catch {
                model.gamesDiscovery.search.failed = true
                Self.trace("game search failed: \(Self.describe(error))")
            }
            model.gamesDiscovery.search.isLoading = false
        }
    }
}

extension AppModel {
    /// The games friends are playing now, by id, for loading their records.
    var playWithFriendsGameIDs: [ApplicationID] {
        var ids: [ApplicationID] = []
        for (userID, relationship) in relationships where relationship == .friend {
            for activity in presences[userID]?.activities?.list ?? [] where activity.kind == .playing {
                if let id = activity.applicationID { ids.append(id) }
            }
        }
        return ids
    }
}
