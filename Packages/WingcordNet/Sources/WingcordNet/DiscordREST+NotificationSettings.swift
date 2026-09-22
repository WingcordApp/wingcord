import Foundation
import WingcordCore

extension DiscordREST {

    /// The account's notification preferences, and the bytes a write splices
    /// into.
    public func notificationSubscriptions() async throws -> (
        settings: NotificationSubscriptions, raw: Data?
    ) {
        struct Response: Decodable { var settings: String? }
        let blob = try await get(
            "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            as: Response.self
        ).settings ?? ""
        let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) ?? Data()
        return NotificationSettingsProto.decode(data)
    }

    public func setNotificationSubscription(
        _ change: NotificationSettingsProto.Change,
        preserving raw: Data
    ) async throws {
        struct Body: Encodable { var settings: String }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: NotificationSettingsProto.patch(applying: change, to: raw))
        )
    }
}
