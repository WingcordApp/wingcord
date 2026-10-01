import Foundation
import WingcordCore

extension DiscordREST {

    // MARK: - The rail's arrangement

    /// Saves the rail's arrangement, and answers with what the server now holds.
    ///
    /// `PATCH /users/@me/settings-proto/1` with `guild_folders` alone — see
    /// `UserSettingsProto.encodeGuildFolders`. **The answer is the whole
    /// settings blob**, and its folders are the settled state: what a reader
    /// sees once the write has landed is what Discord will hand every other
    /// client, not what this one guessed. Nil when the answer did not carry
    /// the field, which it always has.
    public func setGuildFolders(
        _ folders: [GuildFolder],
        guildPositions: [GuildID]
    ) async throws -> GuildFolderSettings? {
        struct Body: Encodable { var settings: String }
        struct Response: Decodable { var settings: String? }
        let data = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: UserSettingsProto.encodeGuildFolders(folders, guildPositions: guildPositions))
        )
        guard let blob = try JSONDecoder().decode(Response.self, from: data).settings,
              let proto = Data(base64Encoded: blob, options: .ignoreUnknownCharacters)
        else { return nil }
        return UserSettingsProto.guildFolders(in: proto)
    }
}
