import Foundation
import WingcordCore

extension DiscordREST {

    // MARK: - Activity privacy

    /// The whole settings blob, for a write that has to preserve it.
    ///
    /// **Fetched rather than remembered, when the blob from READY is missing.**
    /// A splice needs the bytes it is splicing into (see
    /// `ActivityPrivacyProto.replacing`), and an account whose READY arrived
    /// before this client knew to keep them has none. One conditional round trip
    /// is cheap; writing without them is not.
    public func activityPrivacySettings() async throws -> (
        privacy: ActivityPrivacy, raw: Data?, statusRaw: Data?
    ) {
        struct Response: Decodable { var settings: String? }
        let blob = try await get(
            "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            as: Response.self
        ).settings ?? ""
        let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) ?? Data()
        return ActivityPrivacyProto.decode(data)
    }

    /// Writes one activity-privacy field.
    ///
    /// **Proto 1, not proto 2** — the same trap the inbox tab documents:
    /// `/settings-proto/1` is `PreloadedUserSettings` and `/settings-proto/2` is
    /// `FrecencyUserSettings`. Sending this to 2 would be accepted and would
    /// quietly write field 8 of the wrong message.
    ///
    /// - Parameter raw: the `privacy` message as it arrived. **Required**, and
    ///   the caller is expected to have fetched it — a write built on an empty
    ///   message replaces the account's whole privacy section with one field.
    public func setActivityPrivacy(
        _ change: ActivityPrivacyProto.Change,
        preserving raw: Data
    ) async throws {
        struct Body: Encodable { var settings: String }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: ActivityPrivacyProto.privacyPatch(applying: change, to: raw))
        )
    }

    /// Writes "Share my activity", which lives on `status` rather than
    /// `privacy`.
    public func setSharesCurrentGame(_ shares: Bool, preserving statusRaw: Data?) async throws {
        struct Body: Encodable { var settings: String }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            body: Body(
                settings: ActivityPrivacyProto.showCurrentGamePatch(shares, statusRaw: statusRaw)
            )
        )
    }
}
