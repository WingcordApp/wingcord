import Foundation
import WingcordCore

// MARK: - Nitro Emoji Packs
//
// Discord's `EmojiPackActionCreators` (web.js, 2026-11-17): `GET /emoji-packs`,
// a 404 meaning "emoji packs are not enabled for this user"; the picks live in
// the frecency settings blob, field 14, `PinnedEmojiPacks { repeated fixed64
// pack_ids = 1 }`.

extension DiscordREST {

    /// Every pack the account may see, or **nil where Discord answers 404**,
    /// which its own client reads as "emoji packs are not enabled for this
    /// user" (`934499`). Kept apart from an empty list and from a failure: only
    /// the 404 may say "not available on this account".
    ///
    /// **A 404 here has also meant a stale client**: at build 617,136 Discord
    /// refused the route to an account that had a pack added (2026-11-17) —
    /// see `ClientMetadata.Baseline`.
    public func emojiPacks() async throws -> [EmojiPack]? {
        do {
            return try await get("/emoji-packs", route: "emoji-packs", as: [EmojiPackDTO].self)
                .compactMap(\.domain)
        } catch Failure.notFound {
            return nil
        }
    }

    /// The packs added to the picker, in the order they were added.
    public func pinnedEmojiPacks() async throws -> [UInt64] {
        FrecencyProto.pinnedEmojiPacks(base64: try await frecencySettings())
    }

    /// Replaces the picker's packs.
    public func setPinnedEmojiPacks(_ ids: [UInt64]) async throws {
        struct Body: Encodable { var settings: String }
        frecencyBlob = nil
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/2",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: FrecencyProto.pinnedEmojiPacksPatch(ids))
        )
    }
}

struct EmojiPackDTO: Decodable, Sendable {
    var id: String?
    var name: String?
    var description: String?
    var available: Bool?
    var representative_emoji_id: String?
    var emojis: [EmojiDTO]?

    struct EmojiDTO: Decodable, Sendable {
        var id: String?
        var name: String?
        var animated: Bool?
        var available: Bool?
    }

    var domain: EmojiPack? {
        guard let id = id.flatMap(UInt64.init), let name else { return nil }
        return EmojiPack(
            id: id,
            name: name,
            description: description,
            isAvailable: available ?? true,
            representativeEmojiID: representative_emoji_id.flatMap(UInt64.init),
            emojis: (emojis ?? []).compactMap { emoji in
                guard let id = emoji.id.flatMap(UInt64.init), let name = emoji.name else { return nil }
                return EmojiPack.Emoji(
                    id: id, name: name, isAnimated: emoji.animated ?? false, isAvailable: emoji.available ?? true
                )
            }
        )
    }
}
