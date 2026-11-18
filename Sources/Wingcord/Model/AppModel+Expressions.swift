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
    /// What the reader's subscription buys.
    ///
    /// Part of the key because it decides what is locked, and it can move under
    /// a built catalog: READY merges over the sign-in's answer and
    /// `USER_UPDATE` over both, and a memo blind to it would serve a catalog
    /// computed while the answer was still "no" for the rest of the launch.
    var entitlements: AccountEntitlements
    /// Fake Nitro's switch for this kind of expression, which unlocks the
    /// picker the way the subscription does. See `AppSettings.fakeNitro`.
    var isFakeNitro = false
}

extension AppModel {

    /// Files Discord's own sticker packs: the picker's sections, and the two
    /// tables a stock sticker's card is answered from.
    func installStandardStickerPacks(_ packs: [StickerPack]) {
        var byID: [String: StickerPack] = [:]
        var packOfSticker: [UInt64: String] = [:]
        for pack in packs {
            byID[pack.id] = pack
            for sticker in pack.stickers { packOfSticker[sticker.id] = pack.id }
        }
        standardStickerPacks = byID
        standardPackIDByStickerID = packOfSticker
        // Eight of Discord's fourteen standard packs are entirely Lottie, which
        // the picker's grid rasterises and a sticker's card plays as vectors —
        // see `LottieStickerLayer`.
        defaultStickerPacks = packs.compactMap { pack in
            guard !pack.stickers.isEmpty else { return nil }
            let cover = pack.stickers.first { $0.id == pack.coverStickerID }
                ?? pack.stickers[0]
            return ExpressionSection(
                id: ExpressionSection.stickerPackID(pack.id),
                title: pack.name,
                badge: .image(
                    CDN.sticker(id: cover.id, format: cover.format),
                    monogram: String(pack.name.prefix(1)).uppercased()
                ),
                items: pack.stickers.map { sticker in
                    ExpressionItem(
                        id: String(sticker.id),
                        art: .image(
                            CDN.sticker(id: sticker.id, format: sticker.format),
                            animated: sticker.format.isAnimated
                        ),
                        name: sticker.name.lowercased(),
                        pick: .sticker(sticker.id)
                    )
                }
            )
        }
        // The catalog is memoized on this counter, and the packs are one of its
        // inputs — without the bump a picker already open never sees them.
        expressionRevision &+= 1
        stickerCatalogCache = nil
    }

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
        let isFakeNitro = AppSettings.shared.sendsFakeEmoji
        let key = ExpressionMemoKey(
            channelID: selectedChannelID,
            expressionRevision: expressionRevision,
            skinTone: AppSettings.shared.skinTone,
            entitlements: entitlements,
            isFakeNitro: isFakeNitro
        )
        // Read every observable input before the early return: a memo that
        // returns its cache without touching them registers no dependency, and
        // its reader is then never invalidated.
        let emojiTable = guildEmojis
        let guildTable = guilds

        if let emojiCatalogCache, emojiCatalogCache.key == key {
            return emojiCatalogCache.value
        }

        // Fake Nitro sends what is locked as a link, so nothing is — the
        // permission included, as the plugin bypasses it too.
        let catalog = buildEmojiCatalog(
            emojiAllowance(for: .composer),
            emojiTable: emojiTable,
            guildTable: guildTable
        )
        emojiCatalogCache = (key, catalog)
        return catalog
    }

    /// The catalog for wherever a picker sends its pick (`EmojiDestination`).
    func emojiCatalog(for destination: EmojiDestination) -> ExpressionCatalog {
        switch destination {
        case .composer:
            return emojiCatalog
        case .channel(let channelID):
            return reactionEmojiCatalog(in: channelID)
        case .personal, .community, .unicodeOnly:
            // Memoized as the others are, for their reason: the picker reads
            // its catalog from four places a frame.
            let key = ExpressionMemoKey(
                channelID: nil,
                expressionRevision: expressionRevision,
                skinTone: AppSettings.shared.skinTone,
                entitlements: entitlements,
                isFakeNitro: false
            )
            let emojiTable = guildEmojis
            let guildTable = guilds
            if let cached = destinationEmojiCatalogCache[destination], cached.key == key {
                return cached.value
            }
            let catalog = buildEmojiCatalog(
                emojiAllowance(for: destination),
                emojiTable: emojiTable,
                guildTable: guildTable
            )
            destinationEmojiCatalogCache[destination] = (key, catalog)
            return catalog
        }
    }

    /// Discord's rule for a destination (`getEmojiUnavailableReason`).
    ///
    /// - A **message** in the composer: this server's emoji, another's with
    ///   Nitro and the channel's `USE_EXTERNAL_EMOJIS`, an animated one with
    ///   the perk — and Fake Nitro's links stand in for all of it.
    /// - A **reaction or poll** in a channel: the same, without Fake Nitro.
    /// - **Nowhere in particular** (a DM from a status or activity, the
    ///   reader's status, bio or typing indicator): no server is home, so
    ///   every custom emoji needs Nitro.
    /// - A **server's own page**: its emoji only, with no Nitro asked.
    /// - **Unicode only**: nothing custom.
    func emojiAllowance(for destination: EmojiDestination) -> EmojiAllowance {
        switch destination {
        case .composer:
            let isFakeNitro = AppSettings.shared.sendsFakeEmoji
            return EmojiAllowance(
                home: selectedGuildID,
                allowsExternal: isFakeNitro || selectedChannelID.map(canUseExternalEmoji(in:)) ?? true,
                // An animated emoji is the subscription's in its own server too.
                allowsAnimated: isFakeNitro || entitlements.has(.animatedEmoji),
                packsUsable: emojiPacksUsable
            )
        case .channel(let channelID):
            return EmojiAllowance(
                home: channelIndex.guildID(of: channelID),
                allowsExternal: canUseExternalEmoji(in: channelID),
                allowsAnimated: entitlements.has(.animatedEmoji),
                // A reaction names the pack's emoji itself; Discord refuses it
                // without Nitro whatever Fake Nitro says.
                packsUsable: entitlements.has(.emojiPacks)
            )
        case .personal:
            return EmojiAllowance(
                home: nil,
                allowsExternal: entitlements.has(.emojiEverywhere),
                allowsAnimated: entitlements.has(.animatedEmoji),
                packsUsable: entitlements.has(.emojiPacks)
            )
        case .community(let guildID):
            return EmojiAllowance(
                home: guildID,
                allowsExternal: false,
                allowsAnimated: true,
                packsUsable: false,
                showsOtherServers: false,
                showsPacks: false
            )
        case .unicodeOnly:
            return EmojiAllowance(
                home: nil,
                allowsExternal: false,
                allowsAnimated: false,
                packsUsable: false,
                showsOtherServers: false,
                showsPacks: false,
                allowsCustom: false
            )
        }
    }

    /// The emoji a **reaction** may use in a channel — Discord's own rule,
    /// which Fake Nitro cannot bend.
    ///
    /// A message's emoji Fake Nitro sends as a link to the picture; a reaction
    /// names the emoji itself, and Discord refuses one the account may not
    /// use. So another server's emoji needs Nitro and the channel's
    /// `USE_EXTERNAL_EMOJIS`, and an animated one needs Nitro anywhere —
    /// whatever Fake Nitro says (Alex, 2026-10-26: it let him react with
    /// external emoji he could not use). Built on demand: the picker is open
    /// on one message at a time, and its channel need not be the selected one.
    func reactionEmojiCatalog(in channelID: ChannelID) -> ExpressionCatalog {
        // Memoized as the composer's is, and for its reason: the picker reads
        // its catalog from four places a frame. Fake Nitro is no input here.
        let key = ExpressionMemoKey(
            channelID: channelID,
            expressionRevision: expressionRevision,
            skinTone: AppSettings.shared.skinTone,
            entitlements: entitlements,
            isFakeNitro: false
        )
        let emojiTable = guildEmojis
        let guildTable = guilds
        if let reactionEmojiCatalogCache, reactionEmojiCatalogCache.key == key {
            return reactionEmojiCatalogCache.value
        }
        let catalog = buildEmojiCatalog(
            emojiAllowance(for: .channel(channelID)),
            emojiTable: emojiTable,
            guildTable: guildTable
        )
        reactionEmojiCatalogCache = (key, catalog)
        return catalog
    }

    /// Whether a reaction may use this emoji here — the same rule as
    /// `reactionEmojiCatalog`, for a reaction that did not come from the
    /// picker: a quick reaction off the hover bar, a chip somebody else began.
    func canReact(with emoji: EmojiRef, in channelID: ChannelID) -> Bool {
        guard let id = emoji.id else { return true }
        if emoji.isAnimated, !entitlements.has(.animatedEmoji) { return false }
        // A Nitro Emoji Pack's emoji is Nitro proper's alone (`TIER_2`), with
        // the external-emoji permission like any other server's.
        if emojiPacks.contains(where: { $0.emojis.contains { $0.id == id.rawValue } }) {
            return entitlements.has(.emojiPacks) && canUseExternalEmoji(in: channelID)
        }
        let isHome = channelIndex.guildID(of: channelID)
            .flatMap { guildEmojis[$0] }?
            .contains { $0.id == id } ?? false
        return isHome || canUseExternalEmoji(in: channelID)
    }

    /// Whether a Nitro Emoji Pack's emoji can be sent: Nitro proper
    /// (Discord asks `TIER_2`, not the animated-emoji perk), or Fake Nitro's
    /// links.
    var emojiPacksUsable: Bool {
        entitlements.has(.emojiPacks) || AppSettings.shared.fakeNitro
    }

    /// A pack emoji's picture: Discord's CDN, or in `--demo` a drawn one
    /// (`DemoEmojiPacks`), since the demo's packs have made-up ids.
    func packEmojiURL(_ emoji: EmojiPack.Emoji, side: CGFloat) -> URL? {
        if LaunchOptions.current.usesDemoFixtures, let drawn = DemoEmojiPacks.artURL(for: emoji.id) { return drawn }
        return CDN.emoji(id: EmojiID(rawValue: emoji.id), animated: emoji.isAnimated, side: side)
    }

    /// One pack emoji as the picker offers it — the grid's section and the
    /// packs page send the same thing.
    func packEmojiItem(_ emoji: EmojiPack.Emoji, isLocked: Bool) -> ExpressionItem {
        ExpressionItem(
            id: String(emoji.id),
            art: .image(packEmojiURL(emoji, side: Self.emojiCellSide), animated: emoji.isAnimated),
            name: emoji.name.lowercased(),
            pick: .insert(emoji.messageToken),
            isLocked: isLocked
        )
    }

    /// The emoji sections, locked by the rule the caller states.
    private func buildEmojiCatalog(
        _ allowance: EmojiAllowance,
        emojiTable: [GuildID: [EmojiRef]],
        guildTable: [GuildID: Guild]
    ) -> ExpressionCatalog {
        let home = allowance.home
        let allowsExternal = allowance.allowsExternal
        let allowsAnimated = allowance.allowsAnimated
        guard allowance.allowsCustom else {
            return ExpressionCatalog(sections: Self.unicodeSections(tone: AppSettings.shared.skinTone))
        }
        var sections: [ExpressionSection] = []
        // Discord's names for them here — a duplicate's tooltip says
        // `:blob~1:`, the name that types it (`EmojiNameTable`). Only for the
        // selected server's table: a reaction elsewhere keeps the plain names.
        let names: EmojiNameTable? = home == selectedGuildID ? emojiNameTable : nil
        // The Nitro Emoji Packs the reader added, first (decision 16). Nitro's
        // to use; in a message Fake Nitro sends them as links like any other
        // emoji (`emojiAllowance`).
        let packsUsable = allowance.packsUsable
        for packID in allowance.showsPacks ? pinnedEmojiPackIDs : [] {
            guard let pack = emojiPacks.first(where: { $0.id == packID }), pack.isAvailable else { continue }
            sections.append(ExpressionSection(
                id: "pack-\(pack.id)",
                title: "\(pack.name) Pack",
                badge: .image(
                    pack.cover.flatMap { packEmojiURL($0, side: Self.emojiCellSide) },
                    monogram: String(pack.name.prefix(1)).uppercased()
                ),
                items: pack.emojis.filter(\.isAvailable).map { emoji in
                    var item = packEmojiItem(emoji, isLocked: !packsUsable)
                    if let name = names?.name(ofCustom: emoji.id) { item.name = name.lowercased() }
                    return item
                },
                isLocked: !packsUsable
            ))
        }
        for guildID in Self.homeFirst(orderedGuildIDs, home: home) where emojiTable[guildID] != nil {
            guard allowance.showsOtherServers || guildID == home,
                  let guild = guildTable[guildID], let emojis = emojiTable[guildID]
            else { continue }
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
                    name: (names?.name(ofCustom: id.rawValue) ?? emoji.name).lowercased(),
                    pick: .insert(emoji.messageToken),
                    isLocked: emoji.isAnimated && !allowsAnimated
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
        return ExpressionCatalog(sections: sections)
    }


    /// The sticker tab: one section per server that has any.
    ///
    /// Servers with none are absent rather than empty — a rail icon that opens
    /// onto nothing is a server you have to click to learn is irrelevant.
    var stickerCatalog: ExpressionCatalog {
        let isFakeNitro = AppSettings.shared.sendsFakeStickers
        let key = ExpressionMemoKey(
            channelID: selectedChannelID,
            expressionRevision: expressionRevision,
            skinTone: .default,
            entitlements: entitlements,
            isFakeNitro: isFakeNitro
        )
        let stickerTable = guildStickers
        let guildTable = guilds

        if let stickerCatalogCache, stickerCatalogCache.key == key {
            return stickerCatalogCache.value
        }

        var sections: [ExpressionSection] = []
        let allowsExternal = isFakeNitro || selectedChannelID.map(canUseExternalStickers(in:)) ?? true
        let home = selectedGuildID

        for guildID in Self.homeFirst(orderedGuildIDs, home: home) where stickerTable[guildID] != nil {
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
    /// `folders` already holds every joined server — `GuildArrangement` puts
    /// the ones the settings do not mention on top — so the tail only catches
    /// a server in the store that is not in the rail, which is a lurked one.
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

    /// Whether the reader pays for any tier at all — what super reactions and
    /// the inbox's quotas ask. Everything else asks `entitlements.has(_:)` for
    /// its own perk, because the tiers do not nest.
    var hasNitro: Bool { entitlements.isPremium }

    /// The servers in the rail's order — **the one being read first**, as
    /// Discord's picker leads with the server you are in: its own emoji are the
    /// ones you can always use there.
    static func homeFirst(_ order: [GuildID], home: GuildID?) -> [GuildID] {
        guard let home, let index = order.firstIndex(of: home) else { return order }
        var reordered = order
        reordered.remove(at: index)
        reordered.insert(home, at: 0)
        return reordered
    }

    /// Whether another server's emoji may be used in this channel.
    ///
    /// **Two halves, and the channel permission is only one of them.**
    /// `useExternalEmojis` is granted to `@everyone` in most servers, so a gate
    /// on that alone unlocks every server's emoji for every account — and the
    /// send then arrives as literal text. The subscription grants the right;
    /// the permission decides whether this *channel* lets it be exercised.
    func canUseExternalEmoji(in channelID: ChannelID) -> Bool {
        entitlements.has(.emojiEverywhere)
            && permissionGate.permissions(in: channelID).contains(.useExternalEmojis)
    }

    /// The same pair for stickers, **with their own perk and their own bit**:
    /// Nitro Classic has emoji everywhere and not stickers, and a server can
    /// allow one and refuse the other (`USE_EXTERNAL_STICKERS`, bit 37).
    func canUseExternalStickers(in channelID: ChannelID) -> Bool {
        entitlements.has(.stickersEverywhere)
            && permissionGate.permissions(in: channelID).contains(.useExternalStickers)
    }
}
