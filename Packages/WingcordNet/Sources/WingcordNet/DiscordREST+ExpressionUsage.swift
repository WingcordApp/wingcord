import Foundation
import WingcordCore

extension DiscordREST {

    /// The emoji and sticker halves of the frecency blob: what is starred and
    /// what is used, scored as Discord scores them.
    public func expressionUsage(now: Date = .now) async throws -> ExpressionUsage {
        let blob = try await frecencySettings()
        return Self.expressionUsage(base64: blob, now: now)
    }

    static func expressionUsage(base64: String, now: Date) -> ExpressionUsage {
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
        return ExpressionUsage(
            favoriteEmojis: FrecencyProto.favoriteEmojis(in: data),
            favoriteStickerIDs: FrecencyProto.favoriteStickerIDs(in: data),
            emojis: ExpressionFrecency(
                history: FrecencyProto.useHistory(in: data, field: FrecencyProto.Field.emojiFrecency), now: now
            ),
            reactions: ExpressionFrecency(
                history: FrecencyProto.useHistory(in: data, field: FrecencyProto.Field.emojiReactionFrecency), now: now
            ),
            stickers: ExpressionFrecency(
                history: FrecencyProto.useHistory(in: data, field: FrecencyProto.Field.stickerFrecency), now: now
            )
        )
    }

    /// Stars or unstars one emoji by Discord's key, applied to the list as it
    /// stands now — so a star made in another client since is kept. Discord's
    /// own add and remove (`V4`, `Sw`): no duplicates, at most 250.
    ///
    /// - Returns: the list as written, or nil when the limit refused the star
    ///   and nothing was written.
    public func setFavoriteEmoji(_ key: String, favorite: Bool) async throws -> [String]? {
        let data = try await frecencyData()
        var keys = Self.unique(FrecencyProto.favoriteEmojis(in: data))
        if favorite {
            guard !keys.contains(key) else { return keys }
            guard keys.count < ExpressionUsage.favoriteLimit else { return nil }
            keys.append(key)
        } else {
            guard keys.contains(key) else { return keys }
            keys.removeAll { $0 == key }
        }
        try await patchFrecency(FrecencyProto.favoriteEmojisField(keys))
        return keys
    }

    /// The same for a sticker.
    public func setFavoriteSticker(_ id: UInt64, favorite: Bool) async throws -> [UInt64]? {
        let data = try await frecencyData()
        var ids = Self.unique(FrecencyProto.favoriteStickerIDs(in: data))
        if favorite {
            guard !ids.contains(id) else { return ids }
            guard ids.count < ExpressionUsage.favoriteLimit else { return nil }
            ids.append(id)
        } else {
            guard ids.contains(id) else { return ids }
            ids.removeAll { $0 == id }
        }
        try await patchFrecency(FrecencyProto.favoriteStickersField(ids))
        return ids
    }

    /// This client's uses, added to the tables as they stand now and written
    /// back in one PATCH — Discord's `overwriteHistory(stored, pending)` and its
    /// write of the hundred used most recently. Read just before, so another
    /// client's uses since are kept. Only the tables that moved are sent.
    public func recordExpressionUses(
        emojis: [(key: String, at: Date)],
        reactions: [(key: String, at: Date)],
        stickers: [(id: UInt64, at: Date)],
        now: Date = .now
    ) async throws -> ExpressionUsage {
        let blob = try await frecencySettings()
        var usage = Self.expressionUsage(base64: blob, now: now)
        for use in emojis { usage.emojis.track(use.key, at: use.at) }
        for use in reactions { usage.reactions.track(use.key, at: use.at) }
        for use in stickers { usage.stickers.track(String(use.id), at: use.at) }
        var patch = Data()
        if !stickers.isEmpty {
            patch += FrecencyProto.useField(FrecencyProto.Field.stickerFrecency, usage.stickers.written, fixedKeys: true)
        }
        if !emojis.isEmpty {
            patch += FrecencyProto.useField(FrecencyProto.Field.emojiFrecency, usage.emojis.written, fixedKeys: false)
        }
        if !reactions.isEmpty {
            patch += FrecencyProto.useField(FrecencyProto.Field.emojiReactionFrecency, usage.reactions.written, fixedKeys: false)
        }
        if !patch.isEmpty { try await patchFrecency(patch) }
        return usage
    }

    // MARK: Plumbing

    private func frecencyData() async throws -> Data {
        let blob = try await frecencySettings()
        return Data(base64Encoded: blob, options: .ignoreUnknownCharacters) ?? Data()
    }

    private func patchFrecency(_ fields: Data) async throws {
        struct Body: Encodable { var settings: String }
        _ = try await requestData(
            method: "PATCH",
            path: "/users/@me/settings-proto/2",
            route: "users/@me/settings-proto/:type",
            body: Body(settings: fields.base64EncodedString())
        )
    }

    private static func unique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen = Set<Value>()
        return values.filter { seen.insert($0).inserted }
    }
}
