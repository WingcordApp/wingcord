import Foundation
import WingcordCore

/// What `emojiNameTable` is memoized on: the server the names are counted
/// from, the emoji sets, and the order the servers come in.
struct EmojiNameTableKey: Equatable {
    var guildID: GuildID?
    var expressionRevision: UInt64
    var guildOrder: [GuildID]
    var packCount: Int
}

// MARK: - Discord's emoji names (GitHub #25, docs/ACTIVITY-CARDS.md decision 3)

extension AppModel {

    /// Every emoji name the reader can type here, named as Discord names them:
    /// Unicode first, then this server's emoji, the other servers' in the
    /// rail's order, then the Nitro Emoji Packs'; a later duplicate becomes
    /// `name~1`. See `EmojiNameTable`.
    var emojiNameTable: EmojiNameTable {
        let order = orderedGuildIDs
        let key = EmojiNameTableKey(
            guildID: selectedGuildID,
            expressionRevision: expressionRevision,
            guildOrder: order,
            packCount: emojiPacks.count
        )
        let emojiTable = guildEmojis
        if let emojiNameTableCache, emojiNameTableCache.key == key { return emojiNameTableCache.value }
        var custom: [EmojiNameTable.Custom] = []
        let home = selectedGuildID
        var guildIDs: [GuildID] = home.map { [$0] } ?? []
        guildIDs += order.filter { $0 != home }
        for guildID in guildIDs {
            guard let emojis = emojiTable[guildID] else { continue }
            for emoji in emojis {
                guard let id = emoji.id else { continue }
                custom.append(EmojiNameTable.Custom(
                    id: id.rawValue, name: emoji.name, isAnimated: emoji.isAnimated, owner: .guild(guildID)
                ))
            }
        }
        // Discord indexes every available pack's emoji, added or not
        // (`getIndexablePackEmojis`).
        for pack in emojiPacks where pack.isAvailable {
            for emoji in pack.emojis where emoji.isAvailable {
                custom.append(EmojiNameTable.Custom(
                    id: emoji.id, name: emoji.name, isAnimated: emoji.isAnimated, owner: .pack(pack.id)
                ))
            }
        }
        let table = EmojiNameTable(unicode: Self.unicodeEmojiNames, custom: custom)
        emojiNameTableCache = (key, table)
        return table
    }

    /// Every Unicode emoji with Discord's name first, then the table's own
    /// names as aliases. Built once.
    nonisolated static let unicodeEmojiNames: [(glyph: String, names: [String])] = UnicodeEmoji.namedItems.map { entry in
        let discord = UnicodeEmoji.discordName(for: entry.item.glyph) ?? entry.item.name
        var names = [discord]
        for name in entry.names where name != discord { names.append(name) }
        return (entry.item.glyph, names)
    }

    /// The glyphs that take a skin tone, so a completion wears the reader's.
    nonisolated static let toneableEmojiGlyphs: Set<String> = Set(
        UnicodeEmoji.namedItems.filter(\.item.takesSkinTone).map(\.item.glyph)
    )

    /// Whether the composer may offer an entry here — the composer picker's
    /// own locks (`buildEmojiCatalog`): another server's emoji needs the
    /// external-emoji permission (or Fake Nitro), an animated one the perk,
    /// a pack's Nitro. Discord's list offers only its unlocked matches.
    func emojiOfferRule() -> (EmojiNameTable.Entry) -> Bool {
        let isFakeNitro = AppSettings.shared.sendsFakeEmoji
        let home = selectedGuildID
        let allowsExternal = isFakeNitro || selectedChannelID.map(canUseExternalEmoji(in:)) ?? true
        let allowsAnimated = isFakeNitro || entitlements.has(.animatedEmoji)
        let packsUsable = emojiPacksUsable
        let held = Set(guildEmojis.keys)
        return { entry in
            switch entry.owner {
            case .unicode:
                return true
            case .guild(let guildID):
                guard held.contains(guildID) else { return false }
                if guildID != home, !allowsExternal { return false }
                return !entry.isAnimated || allowsAnimated
            case .pack:
                return packsUsable
            }
        }
    }

    /// One name-table entry as the completion list and the closing colon
    /// insert it: a Unicode emoji in the reader's skin tone, a custom one as
    /// the token a message carries.
    func completionItem(for entry: EmojiNameTable.Entry) -> ExpressionItem {
        if let glyph = entry.glyph {
            let toned = Self.toneableEmojiGlyphs.contains(glyph)
                ? UnicodeEmoji.applying(AppSettings.shared.skinTone, to: glyph)
                : glyph
            return ExpressionItem(id: entry.name, art: .glyph(toned), name: entry.name, pick: .insert(toned))
        }
        let id = entry.id ?? 0
        let url: URL? = switch entry.owner {
        case .pack: emojiPacks.lazy.flatMap(\.emojis).first { $0.id == id }.flatMap { packEmojiURL($0, side: Self.emojiCellSide) }
        default: CDN.emoji(id: EmojiID(rawValue: id), animated: entry.isAnimated, side: Self.emojiCellSide)
        }
        return ExpressionItem(
            id: String(id),
            art: .image(url, animated: entry.isAnimated),
            name: entry.name,
            pick: .insert(entry.messageToken)
        )
    }
}
