import Foundation
import WingcordCore

// MARK: - Server Hub
//
// Discord's "guild space" routes (docs/BETA2.md, phase 9). See
// `GuildSpaceWireTypes` for the shapes and where they were read.

extension DiscordREST {

    /// A server's hub, or nil where it has none — Discord answers 404, which its
    /// own client stores as "missing" rather than an error.
    public func guildSpace(_ guildID: GuildID) async throws -> GuildSpace? {
        do {
            return try await get(
                "/guilds/\(guildID.rawValue)/space",
                route: "guilds/{id}/space",
                as: GuildSpaceDTO.self
            ).domain(guildID: guildID)
        } catch Failure.notFound {
            // What a 404 becomes in `requestData`: Discord's "Unknown Guild
            // Space" (10142). Read as an error, it showed "didn't load, check
            // your connection" on servers that simply have no hub.
            return nil
        } catch Failure.api(let status, _, _) where status == 404 {
            return nil
        }
    }

    /// Replaces the hub whole — header and every widget — and answers it as
    /// saved. A server with no hub yet gets one.
    ///
    /// - Parameter banner: a data URL to set, `.remove` to clear, nil to keep.
    public func saveGuildSpace(
        _ guildID: GuildID,
        banner: GuildSpaceBannerChange?,
        widgets: [GuildSpaceWidget]
    ) async throws -> GuildSpace {
        let body = GuildSpaceSaveBody(
            banner: banner.map {
                switch $0 {
                case .set(let dataURL): .set(dataURL)
                case .remove: .remove
                }
            },
            widgets: widgets
        )
        return try await request(
            method: "PUT",
            path: "/guilds/\(guildID.rawValue)/space",
            route: "guilds/{id}/space",
            body: body,
            as: GuildSpaceDTO.self
        ).domain(guildID: guildID)
    }

    /// What the widgets that need it show: the standings, the games, the music.
    /// Keyed by widget id; a widget Discord had nothing for is left out.
    public func hydrateGuildSpaceWidgets(
        _ guildID: GuildID,
        widgetIDs: [String]
    ) async throws -> [String: GuildSpaceHydration] {
        guard !widgetIDs.isEmpty else { return [:] }
        let response = try await get(
            "/guilds/\(guildID.rawValue)/space/widgets/hydrate",
            route: "guilds/{id}/space/widgets/hydrate",
            // Repeated, as Discord's client sends an array query.
            query: widgetIDs.map { URLQueryItem(name: "widget_ids", value: $0) },
            as: GuildSpaceHydrateResponse.self
        )
        return Dictionary(
            response.widgets.map { ($0.id, $0.data.domain) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The widgets a server can add.
    public func guildSpaceCatalog(_ guildID: GuildID) async throws -> [GuildSpaceCatalogEntry] {
        try await get(
            "/guilds/\(guildID.rawValue)/space/widgets/catalog",
            route: "guilds/{id}/space/widgets/catalog",
            as: GuildSpaceCatalogResponse.self
        ).domain
    }

    /// Turns the hub on or off, or publishes it — each sent only when given.
    public func updateGuildSpaceSettings(
        _ guildID: GuildID,
        isEnabled: Bool? = nil,
        publishStatus: GuildSpaceSettings.PublishStatus? = nil
    ) async throws -> GuildSpaceSettings {
        struct Body: Encodable {
            var enabled: Bool?
            var publish_status: Int?
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/space/settings",
            route: "guilds/{id}/space/settings",
            body: Body(enabled: isEnabled, publish_status: publishStatus?.rawValue),
            as: GuildSpaceSettingsDTO.self
        ).domain
    }

    /// The server's system-message switches alone — what the leaderboard's own
    /// settings send (`PATCH /guilds/{id}` with `system_channel_flags`).
    public func updateSystemChannelFlags(
        in guildID: GuildID,
        flags: SystemChannelFlags
    ) async throws {
        struct Body: Encodable { var system_channel_flags: Int }
        _ = try await requestData(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)",
            route: "guilds/{id}",
            body: Body(system_channel_flags: flags.rawValue)
        )
    }
}

/// What a save does to the hub's banner.
public enum GuildSpaceBannerChange: Hashable, Sendable {
    /// A new picture, as a data URL.
    case set(String)
    case remove
}
