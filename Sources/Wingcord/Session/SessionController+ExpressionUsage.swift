import Foundation
import WingcordCore
import WingcordNet

/// Uses waiting for the next frecency write.
struct PendingExpressionUses {
    var emojis: [(key: String, at: Date)] = []
    var reactions: [(key: String, at: Date)] = []
    var stickers: [(id: UInt64, at: Date)] = []

    var isEmpty: Bool { emojis.isEmpty && reactions.isEmpty && stickers.isEmpty }
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
        do {
            var usage = try await rest.expressionUsage()
            // Uses made here and not yet written stay counted.
            apply(pendingExpressionUses, to: &usage, now: .now)
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

    /// One use — Discord's `EMOJI_TRACK_USAGE`, `STICKER_TRACK_USAGE` and the
    /// reaction table's own. Frequently Used moves at once; the use is written
    /// into the account ten seconds after the last one, so a run of picks is
    /// one write.
    func trackExpressionUse(emoji: String? = nil, reaction: String? = nil, sticker: UInt64? = nil) {
        let now = Date.now
        var pending = PendingExpressionUses()
        if let emoji { pending.emojis.append((emoji, now)) }
        if let reaction { pending.reactions.append((reaction, now)) }
        if let sticker { pending.stickers.append((sticker, now)) }
        guard !pending.isEmpty else { return }
        pendingExpressionUses.emojis += pending.emojis
        pendingExpressionUses.reactions += pending.reactions
        pendingExpressionUses.stickers += pending.stickers
        var usage = model.expressionUsage ?? .empty(now: now)
        apply(pending, to: &usage, now: now)
        model.expressionUsage = usage

        guard !LaunchOptions.current.usesDemoFixtures else {
            pendingExpressionUses = PendingExpressionUses()
            return
        }
        expressionUseWrite?.cancel()
        expressionUseWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            let uses = pendingExpressionUses
            pendingExpressionUses = PendingExpressionUses()
            do {
                var written = try await rest.recordExpressionUses(
                    emojis: uses.emojis, reactions: uses.reactions, stickers: uses.stickers
                )
                apply(pendingExpressionUses, to: &written, now: .now)
                model.expressionUsage = written
            } catch {
                // Kept for the next write, as Discord keeps its pending usage
                // until a save lands.
                pendingExpressionUses.emojis = uses.emojis + pendingExpressionUses.emojis
                pendingExpressionUses.reactions = uses.reactions + pendingExpressionUses.reactions
                pendingExpressionUses.stickers = uses.stickers + pendingExpressionUses.stickers
                Self.trace("expression frecency write failed: \(Self.describe(error))")
            }
        }
    }

    /// Stars or unstars an emoji (by Discord's key) or a sticker. The star
    /// shows at once and is taken back if Discord refuses the write.
    func setFavorite(emoji key: String? = nil, sticker id: UInt64? = nil, favorite: Bool) {
        var usage = model.expressionUsage ?? .empty()
        let before = usage
        if let key {
            if favorite {
                guard !usage.favoriteEmojis.contains(key) else { return }
                guard usage.favoriteEmojis.count < ExpressionUsage.favoriteLimit else {
                    model.reportActionFailure("You can have up to 250 favorites.")
                    return
                }
                usage.favoriteEmojis.append(key)
            } else {
                usage.favoriteEmojis.removeAll { $0 == key }
            }
        }
        if let id {
            if favorite {
                guard !usage.favoriteStickerIDs.contains(id) else { return }
                guard usage.favoriteStickerIDs.count < ExpressionUsage.favoriteLimit else {
                    model.reportActionFailure("You can have up to 250 favorites.")
                    return
                }
                usage.favoriteStickerIDs.append(id)
            } else {
                usage.favoriteStickerIDs.removeAll { $0 == id }
            }
        }
        model.expressionUsage = usage
        guard !LaunchOptions.current.usesDemoFixtures else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                if let key {
                    if let written = try await rest.setFavoriteEmoji(key, favorite: favorite) {
                        model.expressionUsage?.favoriteEmojis = written
                    } else {
                        model.expressionUsage = before
                        model.reportActionFailure("You can have up to 250 favorites.")
                    }
                }
                if let id {
                    if let written = try await rest.setFavoriteSticker(id, favorite: favorite) {
                        model.expressionUsage?.favoriteStickerIDs = written
                    } else {
                        model.expressionUsage = before
                        model.reportActionFailure("You can have up to 250 favorites.")
                    }
                }
            } catch {
                model.expressionUsage = before
                model.reportActionFailure("Couldn’t update your favorites. Try again in a moment.")
                Self.trace("favorite write failed: \(Self.describe(error))")
            }
        }
    }

    private func apply(_ pending: PendingExpressionUses, to usage: inout ExpressionUsage, now: Date) {
        for use in pending.emojis { usage.emojis.track(use.key, at: use.at) }
        for use in pending.reactions { usage.reactions.track(use.key, at: use.at) }
        for use in pending.stickers { usage.stickers.track(String(use.id), at: use.at) }
    }
}
