import Foundation
import WingcordCore

struct ExpressionMemoKey: Hashable, Sendable {
    var channelID: ChannelID?
    /// **Not `railRevision`.** That counter moves on every unread badge, which
    /// is every inbound message in the account — keying on it would rebuild tens
    /// of thousands of items several times a second, which is the exact failure
    /// `INVARIANTS.md` §2 describes: a memo present, correct, and never hit.
    ///
    /// `expressionRevision` moves only when a server's emoji or sticker set
    /// changes, or when a server is added, removed or renamed.
    var expressionRevision: UInt64
    var skinTone: UnicodeEmoji.SkinTone
    /// Whether the reader carries Nitro.
    ///
    /// Part of the key because it decides which sections are locked, and it
    /// arrives *after* the first catalog is built: `/users/@me` answers a beat
    /// into the session, and a memo blind to it would serve a catalog computed
    /// while the answer was still "no" for the rest of the launch.
    var hasNitro: Bool
}

extension AppModel {

    /// Everything the emoji tab shows: the account's custom emoji, one section
    /// per server, then Unicode's nine categories.
    ///
    /// **Memoized, and it is the most load-bearing memo in the app.** These
    /// sections are built from every guild in the account — on a real account
    /// that is tens of thousands of items — and the picker reads them from four
    /// places: the rail, the search filter, the grid, and the jump bar. Computed
    /// rather than cached, that is four full passes over the account's whole
    /// emoji set *per frame*.
    ///
    /// The key deliberately excludes anything that moves on a message arriving.
    /// An emoji set changes on a gateway event, not on a frame.
    var emojiCatalog: ExpressionCatalog {
        let key = ExpressionMemoKey(
            channelID: selectedChannelID,
            expressionRevision: expressionRevision,
            skinTone: AppSettings.shared.skinTone,
            hasNitro: hasNitro
        )
        // Read every observable input before the early return: a memo that
        // returns its cache without touching them registers no dependency, and
        // its reader is then never invalidated.
        let emojiTable = guildEmojis
        let guildTable = guilds

        if let emojiCatalogCache, emojiCatalogCache.key == key {
            return emojiCatalogCache.value
        }

        var sections: [ExpressionSection] = []
        let allowsExternal = selectedChannelID.map(canUseExternalEmoji(in:)) ?? true
        let home = selectedGuildID

        for guildID in orderedGuildIDs where emojiTable[guildID] != nil {
            guard let guild = guildTable[guildID], let emojis = emojiTable[guildID] else { continue }
            var items: [ExpressionItem] = []
            items.reserveCapacity(emojis.count)
            for emoji in emojis {
                guard let id = emoji.id else { continue }
                items.append(ExpressionItem(
                    id: String(id.rawValue),
                    // The moving rendition for an animated emoji — the same URL
                    // the filmstrip is decoded from, so the still store's first
                    // frame stands in until the strip lands rather than the
                    // cell being blank.
                    art: .image(
                        CDN.emoji(id: id, animated: emoji.isAnimated, side: Self.emojiCellSide),
                        animated: emoji.isAnimated
                    ),
                    name: emoji.name.lowercased(),
                    pick: .insert(emoji.messageToken)
                ))
            }
            sections.append(ExpressionSection(
                id: String(guildID.rawValue),
                title: guild.name,
                badge: .image(
                    guild.iconHash.flatMap {
                        CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarRow)
                    },
                    monogram: Self.monogram(for: guild.name)
                ),
                items: items,
                isLocked: !allowsExternal && guildID != home
            ))
        }

        sections.append(contentsOf: Self.unicodeSections(tone: AppSettings.shared.skinTone))

        let catalog = ExpressionCatalog(sections: sections)
        emojiCatalogCache = (key, catalog)
        return catalog
    }


    /// The sticker tab: one section per server that has any.
    ///
    /// Servers with none are absent rather than empty — a rail icon that opens
    /// onto nothing is a server you have to click to learn is irrelevant.
    var stickerCatalog: ExpressionCatalog {
        let key = ExpressionMemoKey(
            channelID: selectedChannelID,
            expressionRevision: expressionRevision,
            skinTone: .default,
            hasNitro: hasNitro
        )
        let stickerTable = guildStickers
        let guildTable = guilds

        if let stickerCatalogCache, stickerCatalogCache.key == key {
            return stickerCatalogCache.value
        }

        var sections: [ExpressionSection] = []
        let allowsExternal = selectedChannelID.map(canUseExternalStickers(in:)) ?? true
        let home = selectedGuildID

        for guildID in orderedGuildIDs where stickerTable[guildID] != nil {
            guard let guild = guildTable[guildID], let stickers = stickerTable[guildID] else { continue }
            var items: [ExpressionItem] = []
            items.reserveCapacity(stickers.count)
            for sticker in stickers {
                items.append(ExpressionItem(
                    id: String(sticker.id),
                    art: .image(
                        CDN.sticker(id: sticker.id, format: sticker.format),
                        animated: sticker.format.isAnimated
                    ),
                    name: sticker.name.lowercased(),
                    pick: .sticker(sticker.id)
                ))
            }
            guard !items.isEmpty else { continue }
            sections.append(ExpressionSection(
                id: String(guildID.rawValue),
                title: guild.name,
                badge: .image(
                    guild.iconHash.flatMap {
                        CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarRow)
                    },
                    monogram: Self.monogram(for: guild.name)
                ),
                items: items,
                isLocked: !allowsExternal && guildID != home
            ))
        }

        // Discord's own packs come after the servers': a picker opens on what
        // this account has, which is the servers it is in, and the standard set
        // is the fallback nobody scrolls to first.
        sections.append(contentsOf: defaultStickerPacks)

        let catalog = ExpressionCatalog(sections: sections)
        stickerCatalogCache = (key, catalog)
        return catalog
    }

    // MARK: Unicode
    //
    // Built from the generated table and cached on the tone alone: it is the
    // same nineteen hundred glyphs for every account, and the only thing that
    // can change them is the reader picking a different skin tone.

    private static var unicodeCache: (tone: UnicodeEmoji.SkinTone, sections: [ExpressionSection])?

    static func unicodeSections(tone: UnicodeEmoji.SkinTone) -> [ExpressionSection] {
        if let unicodeCache, unicodeCache.tone == tone { return unicodeCache.sections }

        var sections: [ExpressionSection] = []
        sections.reserveCapacity(UnicodeEmoji.Category.allCases.count)
        for category in UnicodeEmoji.Category.allCases {
            let items = UnicodeEmoji.items(in: category).map { item in
                // The tone is applied here rather than at draw time: the grid
                // redraws far more often than the tone changes, and a glyph
                // rebuilt per repaint is a string allocation per visible cell
                // per frame.
                let glyph = item.takesSkinTone
                    ? UnicodeEmoji.applying(tone, to: item.glyph)
                    : item.glyph
                return ExpressionItem(
                    id: item.name,
                    art: .glyph(glyph),
                    name: item.name,
                    pick: .insert(glyph)
                )
            }
            sections.append(ExpressionSection(
                id: "unicode.\(category.rawValue)",
                title: category.title,
                badge: .glyph(category.symbol),
                items: items
            ))
        }
        unicodeCache = (tone, sections)
        return sections
    }

    /// The account's servers in the order the rail shows them: the folders'
    /// contents in order, then anything the folder list does not mention.
    ///
    /// `guild_positions` is the order for loose servers and the folder list is
    /// the order for the rest — see `HANDOFF.md`. Both are already flattened
    /// into `folders` by the settings decode, so this only has to catch guilds
    /// that arrived after the settings did.
    var orderedGuildIDs: [GuildID] {
        var seen = Set<GuildID>()
        var order: [GuildID] = []
        order.reserveCapacity(guilds.count)
        for folder in folders {
            for guildID in folder.guildIDs where seen.insert(guildID).inserted {
                order.append(guildID)
            }
        }
        for guildID in guilds.keys.sorted(by: { $0.rawValue < $1.rawValue })
        where seen.insert(guildID).inserted {
            order.append(guildID)
        }
        return order
    }

    /// The side a custom emoji cell is drawn at, which is also the CDN rung it
    /// is fetched at. Asking for more is paid for in decode time and in cache.
    static let emojiCellSide: CGFloat = 32

    private static func monogram(for name: String) -> String {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first)
        return initials.isEmpty ? "#" : String(initials).uppercased()
    }

    // MARK: Gates

    /// Whether the reader carries Nitro.
    ///
    /// **This is the gate, and the channel permission is only half of it.**
    /// `useExternalEmojis` is granted to `@everyone` in most servers, so a gate
    /// written on that alone unlocks every server's emoji for every account —
    /// and then the send fails server-side with the shortcode left in the
    /// message as literal text. The subscription is what actually grants the
    /// right; the permission decides whether the *channel* allows exercising it.
    ///
    /// Read off the reader's own record, which is the one place `premium_type`
    /// arrives — `/users/@me` carries it and no other user object does.
    var hasNitro: Bool {
        guard let currentUserID, let user = users[currentUserID] else { return false }
        return user.decoration?.premiumTier ?? .none != .none
    }

    /// Whether another server's emoji may be used in this channel.
    ///
    /// A server's own emoji are always usable in that server, by anyone. Using
    /// one *anywhere else* is the Nitro perk, and it still needs the channel to
    /// permit external emoji.
    func canUseExternalEmoji(in channelID: ChannelID) -> Bool {
        hasNitro && permissionGate.permissions(in: channelID).contains(.useExternalEmojis)
    }

    /// Stickers ride the same pair on this client. Discord has a separate
    /// permission bit for them; it is not modelled here, and treating them alike
    /// is the answer that is wrong in the safe direction — a locked section is
    /// dimmed, never hidden, so nothing becomes unreachable either way.
    func canUseExternalStickers(in channelID: ChannelID) -> Bool {
        canUseExternalEmoji(in: channelID)
    }
}
