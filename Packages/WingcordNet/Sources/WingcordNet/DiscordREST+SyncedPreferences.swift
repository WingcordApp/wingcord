import Foundation
import WingcordCore

extension DiscordREST {
    /// Writes one synced preference, splicing it into the account's own blob.
    ///
    /// **Fetched just before**, for `messagingPrivacy`'s reason: a splice needs
    /// the bytes it splices into, and READY's may be older than another
    /// client's last write.
    public func setSyncedPreference(_ change: SyncedPreferencesProto.Change) async throws {
        struct Response: Decodable { var settings: String? }
        struct Body: Encodable { var settings: String }
        let blob = try await get(
            "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            as: Response.self
        ).settings ?? ""
        let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) ?? Data()
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: SyncedPreferencesProto.patch(applying: change, to: data))
        )
    }
}
