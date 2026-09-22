import Foundation
import WingcordCore

extension DiscordREST {

    // MARK: - Messaging permissions

    /// The whole page, and the two raw messages a write has to splice into.
    ///
    /// **Fetched rather than taken from READY.** The same argument
    /// `activityPrivacySettings` makes: a splice needs the bytes it is splicing
    /// into, and an account whose READY arrived before this client kept them has
    /// none. One round trip when the pane opens is cheap; writing without them
    /// would replace somebody's whole `text_and_images` message — which holds
    /// their emoji picker's collapsed sections, their keyword filters and a
    /// dozen other things — with one field.
    public func messagingPrivacy() async throws -> (
        privacy: MessagingPrivacy, textRaw: Data?, privacyRaw: Data?
    ) {
        struct Response: Decodable { var settings: String? }
        let blob = try await get(
            "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            as: Response.self
        ).settings ?? ""
        let data = Data(base64Encoded: blob, options: .ignoreUnknownCharacters) ?? Data()
        return MessagingPrivacyProto.decode(data)
    }

    /// Writes one control.
    ///
    /// **Proto 1, not proto 2** — `/settings-proto/1` is `PreloadedUserSettings`
    /// and `/settings-proto/2` is `FrecencyUserSettings`. Sending this to 2 is
    /// accepted and quietly writes the wrong message's field 6.
    public func setMessagingPrivacy(
        _ change: MessagingPrivacyProto.Change,
        preserving raw: Data
    ) async throws {
        struct Body: Encodable { var settings: String }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/1",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: MessagingPrivacyProto.patch(applying: change, to: raw))
        )
    }
}
