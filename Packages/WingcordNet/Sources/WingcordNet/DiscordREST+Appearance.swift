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
