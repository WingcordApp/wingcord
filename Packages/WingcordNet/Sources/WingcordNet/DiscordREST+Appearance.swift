import Foundation
import WingcordCore

extension DiscordREST {

    // MARK: - Appearance

    /// Writes Appearance → "Default theme in servers".
    ///
    /// **The blob is fetched first**, for `messagingPrivacy()`'s reason: the
    /// write splices one field into the stored `appearance` message and has to
    /// have that message to splice into — see
    /// `UserSettingsProto.patchDefaultServerTheme`. One round trip for a
    /// setting changed a handful of times ever.
    ///
    /// **Proto 1, not proto 2**, for `setInboxTab`'s reason. The field and its
    /// values come from Discord's descriptor and its own settings module; the
    /// write itself has not been captured.
    public func setDefaultServerTheme(_ source: GuildThemeSource) async throws {
        struct Stored: Decodable { var settings: String? }
        struct Body: Encodable { var settings: String }
        let blob = try await get(
            "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            as: Stored.self
        ).settings ?? ""
        let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) ?? Data()
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: UserSettingsProto.patchDefaultServerTheme(source, in: data))
        )
    }
}

// MARK: - The inbox's folded groups

/// One inbox group folded or unfolded.
public struct InboxFold: Sendable {
    /// Nil for a direct message, which Discord files under guild `0`.
    public var guildID: GuildID?
    /// Nil for the server's scheduled-events group.
    public var channelID: ChannelID?
    public var collapsed: Bool

    public init(guildID: GuildID?, channelID: ChannelID?, collapsed: Bool) {
        self.guildID = guildID
        self.channelID = channelID
        self.collapsed = collapsed
    }
}

extension DiscordREST {
    /// Folds or unfolds inbox groups — Discord's `collapsedInInbox`, written
    /// the way its settings updater writes it: the whole `guilds` field, one
    /// flag changed per group, every other byte as it was. See
    /// `UserSettingsProto.patchInboxCollapsed`.
    /// Writes people's volumes and mutes, as Discord's `AudioSettingsManager`
    /// does: the blob fetched, the changed entries spliced in, the field sent
    /// back whole. See `AudioContextProto.patch`.
    public func setAudioContext(_ changes: [AudioContextProto.Change]) async throws {
        guard !changes.isEmpty else { return }
        struct Stored: Decodable { var settings: String? }
        struct Body: Encodable { var settings: String }
        let blob = try await get(
            "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            as: Stored.self
        ).settings ?? ""
        let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) ?? Data()
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: AudioContextProto.patch(changes, in: data))
        )
    }

    public func setInboxFolds(_ folds: [InboxFold]) async throws {
        guard !folds.isEmpty else { return }
        struct Stored: Decodable { var settings: String? }
        struct Body: Encodable { var settings: String }
        let blob = try await get(
            "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            as: Stored.self
        ).settings ?? ""
        let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) ?? Data()
        let changes = folds.map { fold in
            UserSettingsProto.InboxCollapseChange(
                guild: fold.guildID?.rawValue ?? 0,
                channel: fold.channelID?.rawValue ?? UserSettingsProto.guildEventsChannel,
                collapsed: fold.collapsed
            )
        }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: UserSettingsProto.patchInboxCollapsed(changes, in: data))
        )
    }
}
