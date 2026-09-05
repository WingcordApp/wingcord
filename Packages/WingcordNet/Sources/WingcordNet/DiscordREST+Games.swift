import Foundation
import WingcordCore

extension DiscordREST {

    // MARK: - Games

    /// How many game ids one `/games` call may name.
    ///
    /// **Discord's own client sends far more than this in a single URL** — a
    /// captured board asks for seventeen at once and a similar-games list asks
    /// for twenty — but the ceiling is undocumented and a URL has one. Chunked
    /// at fifty, which is comfortably under any server limit and keeps the query
    /// string under two kilobytes.
    public static let gamePageSize = 50

    /// Every game a board names, in one round trip per chunk.
    ///
    /// **Batched, and that is the whole design of the board's fetch.** A profile
    /// with five widgets names up to forty-six distinct games; asking for them
    /// one at a time is forty-six requests through one rate-limit bucket, and
    /// the board would fill in over several seconds in front of the reader.
    ///
    /// Chunks run **in sequence, not concurrently**. They share a bucket, so
    /// firing them together only moves the queueing from the client into the
    /// limiter — and a 429 there costs more than the second chunk saves.
    public func games(ids: [ApplicationID]) async throws -> [Game] {
        // Deduplicated before the split: the same game is very often in two
        // widgets — Genshin Impact is in both the rotation and the liked list on
        // one captured profile — and a duplicate id is a wasted slot in a chunk.
        var seen = Set<ApplicationID>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }

        var games: [Game] = []
        games.reserveCapacity(unique.count)
        for chunk in stride(from: 0, to: unique.count, by: Self.gamePageSize) {
            let slice = unique[chunk..<min(chunk + Self.gamePageSize, unique.count)]
            let page = try await get(
                "/games",
                route: "games",
                query: slice.map { URLQueryItem(name: "game_ids", value: $0.description) },
                as: [GameDTO].self
            )
            games.append(contentsOf: page.compactMap(\.domain))
        }
        return games
    }

    /// One game.
    public func game(_ id: ApplicationID) async throws -> Game? {
        try await get("/games/\(id.rawValue)", route: "games/{id}", as: GameDTO.self).domain
    }

    /// The game's own server's recent posts.
    ///
    /// **An empty envelope is the ordinary answer**, not a failure: Beat Saber
    /// has no announcements channel and returns `{"guild_id": null,
    /// "channel_id": null, "messages": []}` with a 200. The section is drawn
    /// only when something came back.
    ///
    /// The authors come out with the messages for the same reason a history page
    /// does it: these are posted by webhooks and bots that appear in no roster
    /// this client holds, so dropping them leaves every announcement headed
    /// "Unknown".
    public func gameAnnouncements(
        _ id: ApplicationID,
        limit: Int = 8
    ) async throws -> GameAnnouncements {
        let payload = try await get(
            "/games/\(id.rawValue)/announcements",
            route: "games/{id}/announcements",
            query: [URLQueryItem(name: "limit", value: String(limit))],
            as: GameAnnouncementsDTO.self
        )
        var authors: [UserID: User] = [:]
        for dto in payload.messages ?? [] {
            guard let author = dto.author else { continue }
            authors[author.id] = author.domain
        }
        return GameAnnouncements(
            guildID: payload.guild_id,
            channelID: payload.channel_id,
            // **Not reversed.** A transcript wants oldest first because it is
            // read downward; a shelf of announcements is read left to right with
            // the newest at the leading edge, which is the order the route
            // already sends.
            messages: (payload.messages ?? []).map(\.domain),
            authors: authors
        )
    }

    /// Games Discord thinks play like this one.
    ///
    /// The ids only — the games themselves are a second, batched call, which is
    /// what lets the row share one fetch with the board's own games.
    public func similarGames(to id: ApplicationID) async throws -> [ApplicationID] {
        try await get(
            "/content-inventory/users/@me/similar-games/\(id.rawValue)",
            route: "content-inventory/users/@me/similar-games/{id}",
            as: SimilarGamesDTO.self
        ).similar_games ?? []
    }

    // MARK: - Invites

    /// What is behind an invite code, without joining anything.
    ///
    /// The community card's whole content. `with_counts` is what fills in the
    /// online and member figures — without it the card can name the server and
    /// not say how big it is, which is most of why anybody reads the card.
    ///
    /// The response nests a `profile` of exactly the shape `/guilds/{id}/profile`
    /// answers with, so it decodes through the same type — including the
    /// `features` set that `GuildProfile.standing` reads the verified rosette
    /// out of.
    public func invitePreview(code: String) async throws -> GuildProfile? {
        struct Reply: Decodable, Sendable {
            var profile: GuildProfileDTO?
        }
        return try await get(
            "/invites/\(code)",
            route: "invites/{code}",
            query: [
                URLQueryItem(name: "with_counts", value: "true"),
                URLQueryItem(name: "with_expiration", value: "true"),
            ],
            as: Reply.self
        ).profile?.domain
    }
}
