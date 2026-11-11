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
    func withUsageSections(_ catalog: ExpressionCatalog, stickers: Bool, reacting: Bool) -> ExpressionCatalog {
        let usage = (expressionUsage ?? .empty()).seeded()
        var cells: [String: ExpressionItem] = [:]
        for section in catalog.sections {
            for item in section.items where cells[item.id] == nil { cells[item.id] = item }
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
    func quickReactions(in channelID: ChannelID) -> [EmojiRef] {
        let usage = expressionUsage ?? .empty()
        return usage.quickReactions { key in
            guard let emoji = emojiRef(forUsageKey: key) else { return false }
            return canReact(with: emoji, in: channelID)
        }
        .compactMap(emojiRef(forUsageKey:))
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
