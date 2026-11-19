import Foundation
import WingcordCore

// MARK: - Games in Discover (`2026-10-game-discovery`, docs/QUEUE-NOV19.md §1)

/// `GET /games/trending`: the week's top games, as the Trending table and the
/// Featured shelf draw them.
public struct TrendingGames: Hashable, Sendable {
    /// The week the list is for, as Discord sends it ("2026-11-16").
    public var week: String?
    public var entries: [Entry]

    public struct Entry: Hashable, Sendable, Identifiable {
        public var gameID: ApplicationID
        public var rank: Int
        /// The week's change in players, as a fraction (0.12 is "+12%").
        public var playersChange: Double
        /// Category ids (Discord's 1–18), most fitting first.
        public var categories: [Int]
        public var officialGuild: OfficialGuild?
        public var id: ApplicationID { gameID }
    }

    public struct OfficialGuild: Hashable, Sendable {
        public var id: GuildID
        public var name: String
        public var iconURL: URL?
        public var inviteURL: URL?
        public var isVerified: Bool
        public var isPartnered: Bool
        public var onlineCount: Int?
    }
}

/// `GET /games/search`: a page of games and the counts each filter would leave.
public struct GameSearchPage: Hashable, Sendable {
    public var games: [Game]
    public var totalCount: Int
    public var genreCounts: [Facet<Int>]
    public var platformCounts: [Facet<String>]

    public struct Facet<Value: Hashable & Sendable>: Hashable, Sendable {
        public var value: Value
        public var count: Int
    }
}

/// One game the reader has played, from
/// `GET /users/@me/activities/statistics/applications`.
public struct GamePlayStatistic: Hashable, Sendable {
    public var applicationID: ApplicationID
    public var lastPlayedAt: Date?
    /// Seconds played in all.
    public var totalDuration: Int
}

extension DiscordREST {
    /// The page's search size and the most results it pages through.
    public static let gameSearchPageSize = 25
    public static let gameSearchMaxResults = 500

    public func trendingGames() async throws -> TrendingGames {
        struct Answer: Decodable {
            var week: String?
            var games: [Row]?
            struct Row: Decodable {
                var game_id: ApplicationID?
                var rank: Int?
                var total_players_pct_change: Double?
                var categories: [Category]?
                var official_guild: Guild?
                struct Category: Decodable { var id: Int?; var rank: Int? }
                struct Guild: Decodable {
                    var id: GuildID?
                    var name: String?
                    var icon_url: String?
                    var invite_link_url: String?
                    var is_verified: Bool?
                    var is_partnered: Bool?
                    var approximate_online_count: Int?
                }
            }
        }
        let answer = try await get("/games/trending", route: "games/trending", as: Answer.self)
        let entries: [TrendingGames.Entry] = (answer.games ?? []).enumerated().compactMap { index, row in
            guard let gameID = row.game_id else { return nil }
            let categories = (row.categories ?? [])
                .sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
                .compactMap(\.id)
            let guild = row.official_guild.flatMap { dto -> TrendingGames.OfficialGuild? in
                guard let id = dto.id, let name = dto.name else { return nil }
                return TrendingGames.OfficialGuild(
                    id: id,
                    name: name,
                    iconURL: dto.icon_url.flatMap(URL.init(string:)),
                    inviteURL: dto.invite_link_url.flatMap(URL.init(string:)),
                    isVerified: dto.is_verified ?? false,
                    isPartnered: dto.is_partnered ?? false,
                    onlineCount: dto.approximate_online_count
                )
            }
            return TrendingGames.Entry(
                gameID: gameID,
                rank: row.rank ?? index + 1,
                playersChange: row.total_players_pct_change ?? 0,
                categories: categories,
                officialGuild: guild
            )
        }
        return TrendingGames(week: answer.week, entries: entries.sorted { $0.rank < $1.rank })
    }

    /// Discord's search, in its showcase group (what the Games page asks).
    public func discoverGames(
        query: String,
        genres: [Int] = [],
        platforms: [String] = [],
        offset: Int = 0
    ) async throws -> GameSearchPage {
        struct Answer: Decodable {
            var games: LossyList<GameDTO>?
            var total_count: Int?
            var facets: Facets?
            struct Facets: Decodable {
                var genres: [Count<Int>]?
                var platform_availability: [Count<String>]?
            }
            struct Count<V: Decodable>: Decodable { var value: V?; var count: Int? }
        }
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "filter_group", value: "showcase"),
        ]
        items += Set(genres).sorted().map { URLQueryItem(name: "genres", value: String($0)) }
        items += Set(platforms).sorted().map { URLQueryItem(name: "platform_availability", value: $0) }
        items += [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(Self.gameSearchPageSize)),
        ]
        let answer = try await get("/games/search", route: "games/search", query: items, as: Answer.self)
        return GameSearchPage(
            games: answer.games?.elements.compactMap(\.domain) ?? [],
            totalCount: answer.total_count ?? 0,
            genreCounts: (answer.facets?.genres ?? []).compactMap { count in
                count.value.map { .init(value: $0, count: count.count ?? 0) }
            },
            platformCounts: (answer.facets?.platform_availability ?? []).compactMap { count in
                count.value.map { .init(value: $0, count: count.count ?? 0) }
            }
        )
    }

    /// Each game's newest announcement, for Jump back in's "Latest update".
    public func latestGameAnnouncements(_ ids: [ApplicationID]) async throws -> [ApplicationID: Message] {
        guard !ids.isEmpty else { return [:] }
        struct Answer: Decodable {
            var announcements: [Row]?
            struct Row: Decodable { var game_id: ApplicationID?; var message: MessageDTO? }
        }
        let answer = try await get(
            "/games/announcements/latest",
            route: "games/announcements/latest",
            query: ids.map { URLQueryItem(name: "game_ids", value: $0.description) },
            as: Answer.self
        )
        var latest: [ApplicationID: Message] = [:]
        for row in answer.announcements ?? [] {
            if let id = row.game_id, let message = row.message { latest[id] = message.domain }
        }
        return latest
    }

    /// What the reader has played, most recent first.
    public func playStatistics() async throws -> [GamePlayStatistic] {
        struct Row: Decodable {
            var application_id: ApplicationID?
            var last_played_at: Date?
            var total_duration: Int?
        }
        let rows = try await get(
            "/users/@me/activities/statistics/applications",
            route: "users/@me/activities/statistics/applications",
            as: LossyList<Row>.self
        )
        return rows.elements.compactMap { row in
            row.application_id.map {
                GamePlayStatistic(applicationID: $0, lastPlayedAt: row.last_played_at, totalDuration: row.total_duration ?? 0)
            }
        }
        .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }
}
