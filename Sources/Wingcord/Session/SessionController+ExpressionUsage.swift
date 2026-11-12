import Foundation
import WingcordCore
import WingcordNet

/// Uses waiting for the next frecency write.
///
/// **Kept on disk until a write lands** (`store`, `stored`): the write waits
/// ten seconds for company, and a use made in the last ten seconds before the
/// app quit was simply never counted. The next session's first read picks them
/// up and writes them.
struct PendingExpressionUses: Codable {
    struct KeyUse: Codable {
        var key: String
        var at: Date
    }

    struct StickerUse: Codable {
        var id: UInt64
        var at: Date
    }

    var emojis: [KeyUse] = []
    var reactions: [KeyUse] = []
    var stickers: [StickerUse] = []

    var isEmpty: Bool { emojis.isEmpty && reactions.isEmpty && stickers.isEmpty }

    /// These, with `earlier` ahead of them.
    func following(_ earlier: PendingExpressionUses) -> PendingExpressionUses {
        PendingExpressionUses(
            emojis: earlier.emojis + emojis,
            reactions: earlier.reactions + reactions,
            stickers: earlier.stickers + stickers
        )
    }

    private static func defaultsKey(for userID: UserID) -> String {
        "expressionUses.pending.\(userID.rawValue)"
    }

    /// One account's unwritten uses, as the last session left them.
    static func stored(for userID: UserID, in defaults: UserDefaults = .standard) -> PendingExpressionUses {
        guard let data = defaults.data(forKey: defaultsKey(for: userID)),
              let uses = try? JSONDecoder().decode(PendingExpressionUses.self, from: data)
        else { return PendingExpressionUses() }
        return uses
    }

    func store(for userID: UserID, in defaults: UserDefaults = .standard) {
        let key = Self.defaultsKey(for: userID)
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

// The account's favourite and most-used emoji and stickers.

extension SessionController {

    /// Reads the stars and the use tables once; later reads come from the
    /// gateway saying the blob moved. Never in the demo, which has no token.
    func loadExpressionUsage(force: Bool = false) async {
        guard force || model.expressionUsage == nil else { return }
        guard !LaunchOptions.current.usesDemoFixtures else {
            if model.expressionUsage == nil { model.expressionUsage = .empty() }
            return
        }
        adoptStoredExpressionUses()
        do {
            var usage = try await rest.expressionUsage()
            // Uses made here and not yet written stay counted.
            apply(pendingExpressionUses, to: &usage, now: .now)
            // And a star on its way is not in a blob read before it landed.
            if favoriteWritesPending > 0, let shown = model.expressionUsage {
                usage.favoriteEmojis = shown.favoriteEmojis
                usage.favoriteStickerIDs = shown.favoriteStickerIDs
            }
            model.expressionUsage = usage
        } catch {
            Self.trace("expression frecency read failed: \(Self.describe(error))")
            if model.expressionUsage == nil { model.expressionUsage = .empty() }
        }
    }

    /// The blob changed in another client (or echoed this one's write): read
    /// it again a moment later, once, however many updates arrive together.
    func refreshExpressionUsageSoon() {
        guard model.expressionUsage != nil else { return }
        expressionUsageRefresh?.cancel()
        expressionUsageRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await loadExpressionUsage(force: true)
        }
    }

    /// The last session's unwritten uses, taken up once and written with
    /// whatever this one adds.
    private func adoptStoredExpressionUses() {
        guard !hasAdoptedStoredExpressionUses, let userID = model.currentUserID else { return }
        hasAdoptedStoredExpressionUses = true
        let stored = PendingExpressionUses.stored(for: userID)
        guard !stored.isEmpty else { return }
        pendingExpressionUses = pendingExpressionUses.following(stored)
        scheduleExpressionUseWrite()
    }

    /// One use — Discord's `EMOJI_TRACK_USAGE`, `STICKER_TRACK_USAGE` and the
    /// reaction table's own. Frequently Used moves at once; the use is written
    /// into the account ten seconds after the last one, so a run of picks is
    /// one write.
    func trackExpressionUse(emoji: String? = nil, reaction: String? = nil, sticker: UInt64? = nil) {
        let now = Date.now
        var pending = PendingExpressionUses()
        if let emoji { pending.emojis.append(.init(key: emoji, at: now)) }
        if let reaction { pending.reactions.append(.init(key: reaction, at: now)) }
        if let sticker { pending.stickers.append(.init(id: sticker, at: now)) }
        guard !pending.isEmpty else { return }
        var usage = model.expressionUsage ?? .empty(now: now)
        apply(pending, to: &usage, now: now)
        model.expressionUsage = usage

        guard !LaunchOptions.current.usesDemoFixtures else { return }
        pendingExpressionUses = pending.following(pendingExpressionUses)
        storePendingExpressionUses()
        scheduleExpressionUseWrite()
    }

    private func storePendingExpressionUses() {
        guard let userID = model.currentUserID else { return }
        pendingExpressionUses.store(for: userID)
    }

    private func scheduleExpressionUseWrite() {
        expressionUseWrite?.cancel()
        expressionUseWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            let uses = pendingExpressionUses
            pendingExpressionUses = PendingExpressionUses()
            do {
                var written = try await rest.recordExpressionUses(
                    emojis: uses.emojis.map { ($0.key, $0.at) },
                    reactions: uses.reactions.map { ($0.key, $0.at) },
                    stickers: uses.stickers.map { ($0.id, $0.at) }
                )
                apply(pendingExpressionUses, to: &written, now: .now)
                // The stars are not this write's to answer for: one may be on
                // its way, and the blob read here predates it.
                if favoriteWritesPending > 0, let shown = model.expressionUsage {
                    written.favoriteEmojis = shown.favoriteEmojis
                    written.favoriteStickerIDs = shown.favoriteStickerIDs
                }
                model.expressionUsage = written
            } catch {
                // Kept for the next write, as Discord keeps its pending usage
                // until a save lands.
                pendingExpressionUses = pendingExpressionUses.following(uses)
                Self.trace("expression frecency write failed: \(Self.describe(error))")
            }
            storePendingExpressionUses()
        }
    }

    /// Stars or unstars an emoji (by Discord's key) or a sticker. The star
    /// shows at once and is taken back if Discord refuses the write.
    ///
    /// **One write at a time, each after the one before.** A write reads the
    /// list as the account holds it and sends it back whole, so two stars made
    /// within one round trip both read the list without the other's star, and
    /// the second to land erased the first. And a refusal takes back its own
    /// star and nothing else: it used to put back everything as it stood when
    /// the star was pressed, which threw away whatever had been used or starred
    /// since.
    func setFavorite(emoji key: String? = nil, sticker id: UInt64? = nil, favorite: Bool) {
        var usage = model.expressionUsage ?? .empty()
        // Where an unstarred one sat, so a refusal puts it back there.
        let emojiPlace = key.flatMap { usage.favoriteEmojis.firstIndex(of: $0) }
        let stickerPlace = id.flatMap { usage.favoriteStickerIDs.firstIndex(of: $0) }
        if let key {
            if favorite {
                guard emojiPlace == nil else { return }
                guard usage.favoriteEmojis.count < ExpressionUsage.favoriteLimit else {
                    model.reportActionFailure("You can have up to 250 favorites.")
                    return
                }
                usage.favoriteEmojis.append(key)
            } else {
                guard emojiPlace != nil else { return }
                usage.favoriteEmojis.removeAll { $0 == key }
            }
        }
        if let id {
            if favorite {
                guard stickerPlace == nil else { return }
                guard usage.favoriteStickerIDs.count < ExpressionUsage.favoriteLimit else {
                    model.reportActionFailure("You can have up to 250 favorites.")
                    return
                }
                usage.favoriteStickerIDs.append(id)
            } else {
                guard stickerPlace != nil else { return }
                usage.favoriteStickerIDs.removeAll { $0 == id }
            }
        }
        model.expressionUsage = usage
        guard !LaunchOptions.current.usesDemoFixtures else { return }

        let earlier = favoriteWrite
        favoriteWritesPending += 1
        favoriteWrite = Task { [weak self] in
            await earlier?.value
            guard let self else { return }
            defer { favoriteWritesPending -= 1 }
            // Only the last write in the queue speaks for the whole list: an
            // earlier one's answer does not have the stars queued behind it.
            let isLast = { self.favoriteWritesPending == 1 }
            do {
                if let key {
                    if let written = try await rest.setFavoriteEmoji(key, favorite: favorite) {
                        if isLast() { model.expressionUsage?.favoriteEmojis = written }
                    } else {
                        undoFavorite(emoji: key, wasFavorite: !favorite, place: emojiPlace)
                        model.reportActionFailure("You can have up to 250 favorites.")
                    }
                }
                if let id {
                    if let written = try await rest.setFavoriteSticker(id, favorite: favorite) {
                        if isLast() { model.expressionUsage?.favoriteStickerIDs = written }
                    } else {
                        undoFavorite(sticker: id, wasFavorite: !favorite, place: stickerPlace)
                        model.reportActionFailure("You can have up to 250 favorites.")
                    }
                }
            } catch {
                if let key { undoFavorite(emoji: key, wasFavorite: !favorite, place: emojiPlace) }
                if let id { undoFavorite(sticker: id, wasFavorite: !favorite, place: stickerPlace) }
                model.reportActionFailure("Couldn’t update your favorites. Try again in a moment.")
                Self.trace("favorite write failed: \(Self.describe(error))")
            }
        }
    }

    /// Takes one refused star back, or puts one refused unstar back where it was.
    private func undoFavorite(emoji key: String, wasFavorite: Bool, place: Int?) {
        guard var usage = model.expressionUsage else { return }
        usage.favoriteEmojis.removeAll { $0 == key }
        if wasFavorite {
            usage.favoriteEmojis.insert(key, at: min(place ?? usage.favoriteEmojis.count, usage.favoriteEmojis.count))
        }
        model.expressionUsage = usage
    }

    private func undoFavorite(sticker id: UInt64, wasFavorite: Bool, place: Int?) {
        guard var usage = model.expressionUsage else { return }
        usage.favoriteStickerIDs.removeAll { $0 == id }
        if wasFavorite {
            usage.favoriteStickerIDs.insert(id, at: min(place ?? usage.favoriteStickerIDs.count, usage.favoriteStickerIDs.count))
        }
        model.expressionUsage = usage
    }

    private func apply(_ pending: PendingExpressionUses, to usage: inout ExpressionUsage, now: Date) {
        for use in pending.emojis { usage.emojis.track(use.key, at: use.at) }
        for use in pending.reactions { usage.reactions.track(use.key, at: use.at) }
        for use in pending.stickers { usage.stickers.track(String(use.id), at: use.at) }
    }
}
