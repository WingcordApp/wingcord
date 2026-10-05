import Foundation
import WingcordCore

// MARK: - The Welcome Screen
//
// Discord's `225315`: one route, read and patched. Not captured; the shapes
// are Discord's own reader and writer of it — `welcome_channels` objects of
// `{channel_id, description, emoji_id, emoji_name}`, and a PATCH that sends
// only the fields the page changed.

extension DiscordREST {

    /// `GET /guilds/{id}/welcome-screen`, which Discord asks when a Community
    /// server's settings open — its answer is what offers the page at all.
    public func welcomeScreen(of guildID: GuildID) async throws -> WelcomeScreen {
        try await get(
            "/guilds/\(guildID.rawValue)/welcome-screen",
            route: "guilds/{id}/welcome-screen",
            as: WelcomeScreenDTO.self
        ).domain
    }

    /// Turns it off — the one switch Discord's frozen page still has, and only
    /// in that direction. `{"enabled": false}` and nothing else, as Discord's
    /// toggle sends it.
    public func disableWelcomeScreen(in guildID: GuildID) async throws -> WelcomeScreen {
        struct Body: Encodable { var enabled: Bool }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/welcome-screen",
            route: "guilds/{id}/welcome-screen",
            body: Body(enabled: false),
            as: WelcomeScreenDTO.self
        ).domain
    }

    /// Saves the channels after one was taken out or moved — the whole list,
    /// in its new order, and only the list.
    ///
    /// - Parameter disables: Discord turns the screen off in the same breath
    ///   when its last channel goes; both fields then ride one PATCH here
    ///   rather than its two.
    public func setWelcomeChannels(
        _ channels: [WelcomeScreen.Channel],
        in guildID: GuildID,
        disables: Bool = false
    ) async throws -> WelcomeScreen {
        struct Body: Encodable {
            var welcome_channels: [WelcomeScreenDTO.ChannelDTO]
            var enabled: Bool?
        }
        return try await request(
            method: "PATCH",
            path: "/guilds/\(guildID.rawValue)/welcome-screen",
            route: "guilds/{id}/welcome-screen",
            body: Body(
                welcome_channels: channels.map(WelcomeScreenDTO.ChannelDTO.init),
                enabled: disables ? false : nil
            ),
            as: WelcomeScreenDTO.self
        ).domain
    }
}

/// The Welcome Screen object, both ways.
struct WelcomeScreenDTO: Decodable, Sendable {
    var description: String?
    var welcome_channels: LossyList<ChannelDTO>?

    struct ChannelDTO: Codable, Sendable {
        var channel_id: ChannelID
        var description: String?
        var emoji_id: EmojiID?
        var emoji_name: String?

        init(_ channel: WelcomeScreen.Channel) {
            channel_id = channel.channelID
            description = channel.description
            emoji_id = channel.emojiID
            emoji_name = channel.emojiName
        }
    }

    var domain: WelcomeScreen {
        WelcomeScreen(
            description: description.flatMap { $0.isEmpty ? nil : $0 },
            channels: (welcome_channels?.elements ?? []).map {
                WelcomeScreen.Channel(
                    channelID: $0.channel_id,
                    description: $0.description ?? "",
                    emojiID: $0.emoji_id,
                    emojiName: $0.emoji_name.flatMap { $0.isEmpty ? nil : $0 }
                )
            }
        )
    }
}
