import Foundation
import WingcordCore

/// The pickers' Favorites and Frequently Used, the message bar's quick
/// reactions, and the stars — the account's own, through Discord's frecency
/// settings (`settings-proto/2`).
extension AppModel {

    /// Discord's key for an emoji (`C` in its emoji actions): a custom emoji's
    /// id, else the Unicode emoji's base name — tone stripped, which is what
    /// `UnicodeEmoji.shortcode(for:)` answers.
    static func usageKey(for emoji: EmojiRef) -> String? {
        if let id = emoji.id { return String(id.rawValue) }
        return UnicodeEmoji.discordName(for: emoji.name)
    }

    /// Discord's key for a picker cell: a custom emoji's id (the cell's own),
    /// or Discord's name for a Unicode glyph — which is not the cell's id for
    /// two glyphs in three (`+1` here, `thumbsup` there). Nil for a sticker.
    static func usageKey(for item: ExpressionItem) -> String? {
        if case .sticker = item.pick { return nil }
        guard case .glyph = item.art else { return item.id }
        return UnicodeEmoji.glyph(for: item.id).flatMap(UnicodeEmoji.discordName(for:)) ?? item.id
    }

    /// Whether a picker cell is starred.
    func isFavorite(_ item: ExpressionItem) -> Bool {
        guard let usage = expressionUsage else { return false }
        if case .sticker(let id) = item.pick { return usage.favoriteStickerIDs.contains(id) }
        return Self.usageKey(for: item).map(usage.favoriteEmojis.contains) ?? false
    }

    func toggleFavorite(_ item: ExpressionItem) {
        let favorite = !isFavorite(item)
        if case .sticker(let id) = item.pick {
            sessionController.setFavorite(sticker: id, favorite: favorite)
        } else if let key = Self.usageKey(for: item) {
            sessionController.setFavorite(emoji: key, favorite: favorite)
        }
    }

    /// A pick in a picker that writes a message — a use, as Discord counts it.
    func notePicked(_ item: ExpressionItem) {
        if case .sticker(let id) = item.pick {
            sessionController.trackExpressionUse(sticker: id)
        } else if let key = Self.usageKey(for: item) {
            sessionController.trackExpressionUse(emoji: key)
        }
    }

    /// Favorites and Frequently Used over a catalog's own sections, built from
    /// the cells the catalog already has — so a star or a use the reader can
    /// no longer reach (a server left) simply is not shown, as Discord's
    /// `lookupKey` drops it.
    ///
    /// - Parameter reacting: a reaction picker ranks by the reaction table,
    ///   as Discord's picker does for a reaction's intention.
    ///
    /// **Memoized, and the picker is why.** It reads its catalog from four
    /// places a pass and is run again for every cell the pointer crosses, and
    /// this filed every cell of every server under its id each time: on an
    /// account with ten thousand emoji, a few milliseconds a hover step. The
    /// answer moves with the stars and uses (`expressionUsageRevision`) and
    /// with the catalog under it, which is itself a memo — so its sections are
    /// the same buffer from one read to the next and comparing them is free.
    func withUsageSections(_ catalog: ExpressionCatalog, stickers: Bool, reacting: Bool) -> ExpressionCatalog {
        // Read before the early return, so a cache hit still registers it.
        let usage = (expressionUsage ?? .empty())
        let key = UsageCatalogKey(stickers: stickers, reacting: reacting, usageRevision: expressionUsageRevision)
        if let cached = usageCatalogCache[key], cached.base == catalog.sections { return cached.value }
        let value = buildUsageSections(catalog, usage: usage.seeded(), stickers: stickers, reacting: reacting)
        // One entry a kind of picker: an older revision's is never asked for again.
        usageCatalogCache = usageCatalogCache.filter {
            $0.key.stickers != stickers || $0.key.reacting != reacting
        }
        usageCatalogCache[key] = (catalog.sections, value)
        return value
    }

    private func buildUsageSections(
        _ catalog: ExpressionCatalog,
        usage: ExpressionUsage,
        stickers: Bool,
        reacting: Bool
    ) -> ExpressionCatalog {
        var cells: [String: ExpressionItem] = [:]
        for section in catalog.sections {
            for item in section.items where cells[item.id] == nil {
                // **A locked section's emoji are locked wherever they are
                // offered.** The lock was the section's alone, so another
                // server's static emoji came back unlocked in Frequently Used
                // and Favorites — one click from being sent where it can't go
                // (Alex, 2026-11-18).
                var item = item
                if section.isLocked { item.isLocked = true }
                cells[item.id] = item
            }
        }
        // A key is a cell's id for a custom emoji or a sticker; a Unicode one
        // goes through its glyph to this table's own name for it.
        func cell(_ key: String) -> ExpressionItem? {
            if let glyph = UnicodeEmoji.glyph(forDiscordName: key),
               let name = UnicodeEmoji.shortcode(for: glyph),
               let found = cells[name] {
                return found
            }
            return cells[key]
        }
        var sections: [ExpressionSection] = []
        let starred = stickers
            ? usage.favoriteStickerIDs.map { String($0) }
            : usage.favoriteEmojis
        let favorites = starred.compactMap(cell)
        if !favorites.isEmpty {
            sections.append(ExpressionSection(
                id: "usage.favorites",
                title: "Favorites",
                badge: .symbol("star.fill"),
                items: favorites
            ))
        }
        let table = stickers ? usage.stickers : (reacting ? usage.reactions : usage.emojis)
        let frequent = table.ranked
            .compactMap(cell)
            .filter { !$0.isLocked }
            .prefix(stickers ? 16 : ExpressionFrecency.emojiShown)
        if !frequent.isEmpty {
            sections.append(ExpressionSection(
                id: "usage.frequent",
                title: "Frequently Used",
                badge: .symbol("clock"),
                items: Array(frequent)
            ))
        }
        return ExpressionCatalog(sections: sections + catalog.sections)
    }

    /// The message bar's quick reactions: Discord's three most-reacted, of
    /// those the reader may react with in this channel.
    ///
    /// **Worked out once per channel, not once per row pointed at.** The bar
    /// asks every time the pointer changes rows; the answer is a sort of the
    /// reaction table and, for a custom emoji, a search of every server's set.
    /// It moves with the uses, the emoji sets, and what the reader may do here.
    func quickReactions(in channelID: ChannelID) -> [EmojiRef] {
        // Read before the early return, so a cache hit still registers them.
        let usage = expressionUsage ?? .empty()
        let key = QuickReactionsKey(
            channelID: channelID,
            usageRevision: expressionUsageRevision,
            expressionRevision: expressionRevision,
            roleRevision: roleRevision,
            structureRevision: channelIndex.structureRevision,
            entitlements: entitlements
        )
        if let quickReactionsCache, quickReactionsCache.key == key { return quickReactionsCache.value }
        var resolved: [String: EmojiRef] = [:]
        let keys = usage.quickReactions { key in
            guard let emoji = emojiRef(forUsageKey: key) else { return false }
            resolved[key] = emoji
            return canReact(with: emoji, in: channelID)
        }
        let value = keys.compactMap { resolved[$0] }
        quickReactionsCache = (key, value)
        return value
    }

    /// The emoji a key names: a custom one this session knows, or a Unicode
    /// one by shortcode — the glyph, as a reaction writes it.
    func emojiRef(forUsageKey key: String) -> EmojiRef? {
        // **A name first**: `100` and `1234` are Unicode emoji whose names are
        // numbers, and read as an id they are emoji nobody has.
        if let glyph = UnicodeEmoji.glyph(forDiscordName: key) {
            return EmojiRef(id: nil, name: glyph, isAnimated: false)
        }
        guard let raw = UInt64(key) else { return nil }
        for emojis in guildEmojis.values {
            if let emoji = emojis.first(where: { $0.id?.rawValue == raw }) { return emoji }
        }
        return nil
    }
}

/// What a picker's catalog with its usage sections is filed under.
struct UsageCatalogKey: Hashable {
    var stickers: Bool
    var reacting: Bool
    var usageRevision: UInt64
}

/// What the message bar's quick reactions move with.
struct QuickReactionsKey: Equatable {
    var channelID: ChannelID
    var usageRevision: UInt64
    var expressionRevision: UInt64
    var roleRevision: UInt64
    var structureRevision: UInt64
    var entitlements: AccountEntitlements
}
