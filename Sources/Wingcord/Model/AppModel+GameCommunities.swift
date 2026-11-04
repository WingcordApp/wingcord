import Foundation
import WingcordCore

/// A game profile's Communities tab — Discord's `2026-09-game-profiles-v3-communities-tab`
/// (stable `c82450…`): the servers a game lists, browsed as discovery cards.
///
/// **Shown on Discord's own data rule — three servers or more (`eM`) — and not
/// behind its rollout** (D7): the ids arrive on every `/games` answer that has
/// them, so a profile that has them is a profile that can show them.
extension AppModel {

    /// The fewest servers that make a tab — Discord's.
    nonisolated static let communitiesThreshold = 3

    /// How long a server's card is good for before it is asked again —
    /// Discord's `staleAfter: HOUR`, kept per server.
    nonisolated static let communityStaleness: TimeInterval = 3_600

    /// The tab's cards, in the game's own order — nil while they are still
    /// coming, empty once the route has answered with none (or refused).
    func communityTiles(for gameID: ApplicationID) -> [GameCommunityTile]? {
        guard let ids = games[gameID]?.communityGuildIDs else { return nil }
        let landed = ids.compactMap { communityGuilds[$0] }
        if landed.isEmpty {
            let answered = communitiesFailed.contains(gameID)
                || ids.allSatisfy { communityGuildsFetchedAt[$0] != nil }
            return answered && !communitiesLoading.contains(gameID) ? [] : nil
        }
        return landed.map { guild in
            GameCommunityTile(
                guildID: guild.id,
                name: guild.name,
                description: guild.description,
                iconURL: guild.iconHash.flatMap { CDN.guildIcon(guildID: guild.id, hash: $0, side: 56) },
                monogram: guild.monogram,
                mark: guild.mark,
                onlineCount: guild.onlineCount,
                memberCount: guild.memberCount,
                preferredLocale: guild.preferredLocale,
                isJoined: guilds[guild.id] != nil
            )
        }
    }

    /// Asks for the servers a game lists that are not fresh, in one request.
    ///
    /// **`--demo` answers from its own servers** and makes no request.
    func loadCommunities(for gameID: ApplicationID) {
        guard let ids = games[gameID]?.communityGuildIDs, ids.count >= Self.communitiesThreshold,
              !communitiesLoading.contains(gameID)
        else { return }
        let now = Date.now
        let stale = ids.filter { id in
            guard let fetched = communityGuildsFetchedAt[id] else { return true }
            return now.timeIntervalSince(fetched) >= Self.communityStaleness
        }
        guard !stale.isEmpty else { return }
        if LaunchOptions.current.usesDemoFixtures {
            for id in stale { communityGuildsFetchedAt[id] = now }
            return
        }
        communitiesLoading.insert(gameID)
        communitiesFailed.remove(gameID)
        Task { [weak self] in
            guard let self else { return }
            do {
                let guilds = try await sessionController.rest.discoverableGuilds(ids: stale)
                for guild in guilds { communityGuilds[guild.id] = guild }
                for id in stale { communityGuildsFetchedAt[id] = .now }
            } catch {
                communitiesFailed.insert(gameID)
            }
            communitiesLoading.remove(gameID)
        }
    }

    /// Opens a community from a game's profile — Discord's `t4`: the profile
    /// closes, a joined server opens, any other is previewed, and leaving the
    /// preview comes back to the game (`GuildPreview.Origin.gameProfile`).
    func openCommunity(_ guildID: GuildID, from gameID: ApplicationID) {
        dismissGameProfile()
        profileRequest = nil
        sessionController.previewGuild(
            guildID,
            origin: .gameProfile(gameID),
            // Discord's join source for this path, `GAME_PROFILE_COMMUNITIES`.
            location: "game profile",
            source: "Game Profile Communities"
        )
    }
}

/// One server on a game's Communities tab, resolved for drawing.
struct GameCommunityTile: Equatable, Identifiable, Sendable {
    var guildID: GuildID
    var name: String
    var description: String?
    var iconURL: URL?
    var monogram: String
    var mark: GuildMark?
    var onlineCount: Int
    var memberCount: Int
    var preferredLocale: String?
    var isJoined: Bool

    var id: GuildID { guildID }
}
