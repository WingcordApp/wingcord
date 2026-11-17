import AppKit
import Foundation
import WingcordCore

// MARK: - The two cards a transcript can raise
//
// An emoji or a sticker somebody sent, and the server behind a tag somebody
// wears. Both are questions a reader asks *about a picture* — "what is that"
// and "where is it from" — and both are answered from tables the account
// already holds wherever it can be.

extension AppModel {

    // MARK: Expressions

    /// Opens the card for an emoji drawn in a transcript.
    ///
    /// `anchor` is the emoji's own rect, so the card appears beside the picture
    /// that was clicked rather than beside the message or at the pointer.
    func openExpressionInfo(_ subject: ExpressionInfoRequest.Subject, anchor: CGRect) {
        expressionInfoRequest = ExpressionInfoRequest(subject: subject, anchor: anchor)
    }

    /// Everything that card draws.
    ///
    /// Not memoized: it is built once per click, from a scan bounded by the
    /// account's own servers, and a memo over it would be a cache invalidated by
    /// every catalog event for a value read once.
    func expressionInfo(for request: ExpressionInfoRequest) -> ExpressionInfo {
        switch request.subject {
        case .emoji(let emoji): emojiInfo(emoji)
        case .sticker(let sticker): stickerInfo(sticker)
        }
    }

    private func emojiInfo(_ emoji: EmojiRef) -> ExpressionInfo {
        guard let id = emoji.id else {
            // A Unicode emoji belongs to nobody and works everywhere, which is
            // the entire answer — and the only one of these cases with no server
            // behind it.
            let name = UnicodeEmoji.shortcode(for: emoji.name) ?? emoji.name
            return ExpressionInfo(
                artURL: nil,
                isVector: false,
                glyph: emoji.name,
                title: ":\(name):",
                // Discord's own sentence for a default emoji.
                detail: "A default emoji. You can use this emoji everywhere on Discord.",
                source: nil
            )
        }

        // A Nitro Emoji Pack's: Discord's card says whose pack and that it's
        // Nitro's, in its own words (`/jdd/7`, `VEfeux`), with View Set.
        if let pack = emojiPacks.first(where: { $0.emojis.contains { $0.id == id.rawValue } }) {
            return ExpressionInfo(
                artURL: CDN.emoji(id: id, animated: emoji.isAnimated, side: Self.expressionArtSide),
                isVector: false,
                glyph: nil,
                title: ":\(emoji.name):",
                detail: "This emoji is from a Nitro Emoji Pack. It\u{2019}s in Beta and only available to select Nitro members.",
                source: nil,
                emojiPack: ExpressionInfo.EmojiPackLink(id: pack.id, name: pack.name)
            )
        }
        let owner = guildEmojis.first { _, emojis in emojis.contains { $0.id == id } }?.key
        return ExpressionInfo(
            artURL: CDN.emoji(id: id, animated: emoji.isAnimated, side: Self.expressionArtSide),
            isVector: false,
            glyph: nil,
            title: ":\(emoji.name):",
            detail: detail(owner: owner, id: id.rawValue, noun: "emoji"),
            source: resolvedSource(owner: owner, id: id.rawValue)
        )
    }

    private func stickerInfo(_ sticker: StickerRef) -> ExpressionInfo {
        let owner = guildStickers.first { _, stickers in
            stickers.contains { $0.id == sticker.id }
        }?.key
        var info = ExpressionInfo(
            artURL: CDN.sticker(id: sticker.id, format: sticker.format),
            isVector: sticker.format == .lottie,
            glyph: nil,
            title: sticker.name.isEmpty ? "Sticker" : sticker.name,
            detail: "",
            source: nil,
            sticker: sticker
        )
        guard owner == nil else {
            info.detail = detail(owner: owner, id: sticker.id, noun: "sticker")
            info.source = resolvedSource(owner: owner, id: sticker.id)
            return info
        }

        // **Discord's own packs answer before any server is asked.** A server
        // is only the answer for a sticker that is not one of them, and asking
        // the source route about a stock sticker is what produced "a custom
        // sticker from a server you are not in" for Wumpus.
        switch standardStickerLookup(for: sticker.id) {
        case .standard(let pack, let isOffered):
            info.pack = ExpressionInfo.Pack(
                sectionID: ExpressionSection.stickerPackID(pack.id),
                name: pack.name,
                isOffered: isOffered,
                samples: Array(pack.stickers.prefix(4).filter { $0.id != sticker.id }.prefix(3))
            )
        case .resolving:
            info.detail = "Finding out where this came from…"
        case .standardUnnamed:
            info.detail = "One of Discord's own stickers."
        case .guildSticker, .failed, nil:
            info.detail = detail(owner: nil, id: sticker.id, noun: "sticker")
            info.source = resolvedSource(owner: nil, id: sticker.id)
        }
        return info
    }

    /// What is known about a sticker no resident server owns: from the packs
    /// in hand when they have it, and otherwise from a lookup already made.
    ///
    /// **The packs first, and synchronously.** They are fetched once per
    /// launch; once they are in, a stock sticker's card is complete on the
    /// frame it opens, with no request behind it.
    private func standardStickerLookup(for id: UInt64) -> StickerLookup? {
        if let packID = standardPackIDByStickerID[id], let pack = standardStickerPacks[packID] {
            return .standard(pack, isOffered: true)
        }
        return stickerLookups[id]
    }

    /// The sentence under the title.
    ///
    /// **Honest rather than an upsell.** This client sells nothing, and where
    /// the expression is *from* is the fact a reader actually wants — "you
    /// cannot use this" is a non-answer they already worked out from the picture
    /// in front of them.
    private func detail(owner: GuildID?, id: UInt64, noun: String) -> String {
        if owner != nil { return "A custom \(noun) from one of your servers." }
        switch expressionSources[id] {
        case .application(let name, _):
            return "A custom \(noun) belonging to \(name)."
        case .guild(let guild) where guild.isPublic:
            return "A custom \(noun) from a server you can join."
        case .guild:
            // **A private server's details are not the reader's to see.** Its
            // name is already on screen because the expression carries it; its
            // size, its description and the rest of its set are not.
            return "A custom \(noun) from a private server."
        case nil:
            return expressionSourcesLoading.contains(id)
                ? "Finding out where this came from…"
                : "A custom \(noun) from a server you are not in."
        }
    }

    /// The source row: a resident server named with no round trip, a fetched one
    /// named from the route, or a placeholder while the route is out.
    private func resolvedSource(owner: GuildID?, id: UInt64) -> ExpressionInfo.Source? {
        if let owner { return expressionSource(for: owner) }
        if let fetched = expressionSources[id] { return Self.foreignSource(fetched) }
        guard expressionSourcesLoading.contains(id) else { return nil }
        return ExpressionInfo.Source(
            name: "Looking it up…",
            monogram: "?",
            isJoined: false,
            isLoading: true
        )
    }

    /// A source the reader is **not** in, resolved from the fetched answer.
    private static func foreignSource(_ source: ExpressionSource) -> ExpressionInfo.Source? {
        switch source {
        case .application(let name, _):
            return ExpressionInfo.Source(
                guildID: nil,
                name: name,
                // No icon: an app-owned emoji's source route decodes a hash but
                // never the application's own id, and the CDN path needs both —
                // building a URL from the hash alone is exactly the guess that
                // 404s. The monogram carries this card until that id is captured.
                iconURL: nil,
                monogram: AppModel.monogram(of: name),
                isJoined: false
            )
        case .guild(let guild):
            let isPublic = guild.isPublic
            var sample: [ExpressionInfo.Sample] = []
            if isPublic {
                for emoji in guild.sampleEmoji {
                    guard let id = emoji.id else { continue }
                    sample.append(ExpressionInfo.Sample(
                        url: CDN.emoji(id: id, animated: emoji.isAnimated, side: 22),
                        isVector: false
                    ))
                }
                for sticker in guild.sampleStickers {
                    sample.append(ExpressionInfo.Sample(
                        url: CDN.sticker(id: sticker.id, format: sticker.format),
                        isVector: sticker.format == .lottie
                    ))
                }
            }
            return ExpressionInfo.Source(
                guildID: guild.id,
                name: guild.name,
                iconURL: guild.iconHash.flatMap {
                    CDN.guildIcon(guildID: guild.id, hash: $0, side: Metrics.avatarMessage)
                },
                monogram: AppModel.monogram(of: guild.name),
                // Everything below the name is withheld for a server that is not
                // open to be looked at.
                description: isPublic ? guild.description : nil,
                onlineCount: isPublic ? guild.onlineCount : nil,
                memberCount: isPublic ? guild.memberCount : nil,
                mark: isPublic ? guild.mark : nil,
                sample: sample,
                isJoined: false,
                isDiscoverable: guild.features.contains("DISCOVERABLE")
            )
        }
    }

    /// Starts the lookup a foreign expression needs.
    ///
    /// Called by the presenter rather than by the resolver: a resolver that
    /// fires a request is a resolver that fires one every time a view body runs.
    func loadExpressionSourceIfNeeded(for request: ExpressionInfoRequest) async {
        switch request.subject {
        case .emoji(let emoji):
            guard let id = emoji.id else { return }
            guard !guildEmojis.contains(where: { _, list in list.contains { $0.id == id } })
            else { return }
            sessionController.loadExpressionSource(id.rawValue, isSticker: false)
        case .sticker(let sticker):
            guard !guildStickers.contains(where: { _, list in
                list.contains { $0.id == sticker.id }
            }) else { return }
            await sessionController.resolveSticker(sticker.id)
        }
    }

    // MARK: The sticker picker, from a card

    /// Whether "View More Stickers" can do what it says: the reader is in a
    /// conversation they can write in, so its composer has a picker to open.
    var canOpenStickerPicker: Bool {
        guard let channelID = selectedChannelID, !isPreviewingSelectedGuild else { return false }
        return permissionGate.canSend(in: channelID)
    }

    /// Opens the selected conversation's sticker picker at one pack, and closes
    /// the card that asked.
    ///
    /// **The request first, then the dismissal** — `INVARIANTS.md` §5: a
    /// presentation deferred behind another's dismissal is a race.
    func openStickerPicker(at sectionID: String) {
        guard let channelID = selectedChannelID else { return }
        composerControlToken &+= 1
        composerControlRequest = ComposerControlRequest(
            channelID: channelID,
            control: .sticker,
            stickerSectionID: sectionID,
            token: composerControlToken
        )
        expressionInfoRequest = nil
    }

    /// Opens the selected conversation's emoji picker on the Nitro Emoji Packs
    /// page, at one pack — an emoji card's View Set — and closes the card.
    func openEmojiPack(_ packID: UInt64) {
        guard let channelID = selectedChannelID else { return }
        composerControlToken &+= 1
        composerControlRequest = ComposerControlRequest(
            channelID: channelID,
            control: .emoji,
            stickerSectionID: nil,
            emojiPackID: packID,
            token: composerControlToken
        )
        expressionInfoRequest = nil
    }

    /// Discord's ⌘E, ⌘G and ⌘S: the open conversation's picker, opened — or
    /// closed, when it is the one already open.
    func toggleComposerControl(_ control: ComposerControl) {
        guard let channelID = selectedChannelID else { return }
        composerControlToken &+= 1
        composerControlRequest = ComposerControlRequest(
            channelID: channelID, control: control, token: composerControlToken
        )
    }

    private func expressionSource(for guildID: GuildID) -> ExpressionInfo.Source? {
        guard let guild = guilds[guildID] else { return nil }
        return ExpressionInfo.Source(
            guildID: guildID,
            name: guild.name,
            iconURL: guild.iconHash.flatMap {
                CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarMessage)
            },
            monogram: guild.monogram,
            mark: guild.mark,
            isJoined: true
        )
    }

    /// The side an expression card draws its picture at, which is also the CDN
    /// rung it is fetched at.
    static let expressionArtSide: CGFloat = 48

    // MARK: Server tags

    /// Starts the fetch a tag card needs.
    ///
    /// The card is raised by its chip first and this called after, so it appears
    /// on the click rather than on the round trip — the name and the letters are
    /// already in hand, and the description, the counts and the traits land into
    /// a card that is already open.
    func loadGuildProfile(_ guildID: GuildID) {
        sessionController.loadGuildProfile(guildID)
    }

    /// The card's "Unable to load server profile", pressed: ask again.
    func retryGuildProfile(_ guildID: GuildID) {
        guildProfileRefusals[guildID] = nil
        sessionController.loadGuildProfile(guildID)
    }

    /// Everything the tag card draws, merged from what has arrived and what was
    /// already resident.
    ///
    /// A server the reader is in can be named, pictured and dated with no
    /// request at all, which is why the card is never empty: the fetch adds the
    /// description, the counts, the badge and the traits to a card that already
    /// says which server it is.
    /// The games a server names, as far as this client has resolved them.
    ///
    /// **Only the ones it has.** A game whose store entry has not arrived yet is
    /// dropped rather than drawn as a grey square with no name — the card asks
    /// for them as it opens and the row fills in, which is the same trade the
    /// profile board makes for its covers.
    private func guildProfileGames(_ profile: GuildProfile?) -> [GuildProfileGame] {
        guard let profile else { return [] }
        return profile.gameApplicationIDs.compactMap { id in
            guard let game = games[id] else { return nil }
            return GuildProfileGame(
                id: id,
                name: game.name,
                iconURL: gameArtURL(game, kind: .mark, side: 40),
                isHot: profile.gameActivity[id]?.isHot ?? false
            )
        }
    }

    /// - Parameter badgeURL: the tag's own emblem, as the *person wearing it*
    ///   published it. **Handed in rather than looked up**, and that is the whole
    ///   point: a server that has limited who can see its profile answers the
    ///   profile route with nothing, so the card had no icon and drew a `?` — for
    ///   a server whose mark was on screen an inch above it, in the chip that
    ///   opened the card. The badge rides `primary_guild` on the user, which is
    ///   readable by anybody who can see them.
    func guildProfilePresentation(
        of guildID: GuildID,
        tag: String?,
        badgeURL: URL? = nil
    ) -> GuildProfilePresentation {
        let profile = guildProfiles[guildID]
        let resident = guilds[guildID]
        // **"Private Server", not "Server".** A server whose tag somebody wears
        // but whose profile the reader may not fetch has no name here, and
        // "Server" reads as a placeholder that failed to load rather than as
        // the answer — which it is: the card below it says the server has
        // limited who can see its profile, and this is the same fact said in
        // the title.
        let name = profile?.name ?? resident?.name ?? "Private Server"

        return GuildProfilePresentation(
            guildID: guildID,
            name: name,
            tag: profile?.tag ?? tag,
            iconURL: (profile?.iconHash ?? resident?.iconHash).flatMap {
                CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarProfile)
            },
            // **"?" rather than a letter of the placeholder.** A monogram is
            // an abbreviation of a real name; taking one off "Private Server"
            // draws a confident "P" for a server nobody can name.
            monogram: {
                if let known = resident?.monogram { return known }
                if let named = profile?.name { return AppModel.monogram(of: named) }
                return "?"
            }(),
            // **Discord's rule, not the server's banner.** Its profile card
            // shows the tag profile's own artwork for a discoverable server and
            // a glow of the server's colour for every other — never the banner
            // over the channel list (`_3` and `n6` in module `649640`).
            bannerURL: GuildBannerArt.artworkURL(
                guildID: guildID,
                customBannerHash: profile?.customBannerHash,
                features: profile?.features ?? resident?.features ?? [],
                width: 340
            ),
            bannerColor: profile?.brandColorPrimary ?? (profile?.iconHash ?? resident?.iconHash).flatMap {
                GuildBannerArt.paletteURL(guildID: guildID, iconHash: $0).flatMap { derivedPalettes[$0]?.first }
            },
            badgeURL: profile?.badgeHash.flatMap {
                CDN.guildTagBadge(guildID: guildID, hash: $0)
            } ?? badgeURL,
            mark: profile?.mark ?? resident?.mark,
            description: profile?.description,
            memberCount: profile?.memberCount ?? resident?.memberCount,
            onlineCount: profile?.onlineCount,
            traits: profile?.traits ?? [],
            games: guildProfileGames(profile),
            createdAt: guildID.timestamp,
            isJoined: resident != nil,
            isLoading: guildProfilesLoading.contains(guildID),
            entry: guildEntry(for: guildID, profile: profile, isJoined: resident != nil),
            refusal: profile == nil && resident == nil ? guildProfileRefusals[guildID] : nil
        )
    }

    /// Leaves the card and takes the reader to the server.
    func openGuild(_ guildID: GuildID) {
        expressionInfoRequest = nil
        profileRequest = nil
        selectGuild(guildID)
    }

    // MARK: Jumping

    /// Sends the transcript to one message.
    ///
    /// The token is what makes the *same* message reachable twice: without it
    /// the request value is unchanged, the representable sees no difference, and
    /// the second click reads as a broken link.
    func requestJump(to messageID: MessageID, in channelID: ChannelID, highlights: Bool = true) {
        // A jump into a fold opens it — Discord's `hasJumpTarget` — or there
        // would be no row to land on.
        openCollapsedGroups[channelID, default: []].insert(messageID)
        jumpToken &+= 1
        pendingJump = MessageJump(
            channelID: channelID,
            messageID: messageID,
            token: jumpToken,
            highlights: highlights
        )
    }

    /// Follows a link into this account: a channel, or one message in it.
    ///
    /// **A channel this account cannot name opens in the browser**, from the
    /// URL it was written as — Discord's own chip for one still goes somewhere,
    /// and a chip that did nothing would be the inert control §5.5 forbids. A
    /// forum post this client has not been told about opens its forum, which
    /// is what Discord's chip names in that case.
    func openChannelLink(_ link: ChannelLink, fallbackURL: String?) {
        let destination: ChannelID? = if channelIndex[link.destinationID] != nil {
            link.destinationID
        } else if link.threadID != nil, channelIndex[link.channelID] != nil {
            link.channelID
        } else {
            nil
        }
        guard let destination else {
            if let fallbackURL, InlineScannerSchemeCheck.isSafe(fallbackURL),
               let url = URL(string: fallbackURL)
            {
                NSWorkspace.shared.open(url)
            }
            return
        }
        // The permission gate answers for every channel in the account, so a
        // link into a private channel the reader cannot see stops here rather
        // than opening an empty transcript.
        guard canOpen(destination) else { return }
        profileRequest = nil
        expressionInfoRequest = nil
        let guildID = channelIndex.guildID(of: destination)
        if selectedGuildID != guildID { selectGuild(guildID) }
        // A message in a post whose post is unknown cannot be jumped to from
        // its forum; the forum is where the link goes then.
        if let messageID = link.messageID, destination == link.destinationID {
            sessionController.jumpToMessage(messageID, in: destination)
        } else {
            selectChannel(destination)
        }
    }

    /// Follows a link somebody wrote — in a message, in a bio, in a status.
    ///
    /// **One opener for every surface**, because two of them is two places for
    /// the boundary below to be got right. A link into this account goes to the
    /// channel it names; everything else goes to the browser, and only after the
    /// scheme has been checked *here* rather than trusted from wherever the
    /// string came from. `INVARIANTS.md` §5.5: a client that navigates on an
    /// unchecked host is a client anybody who can write to it can steer.
    /// A link followed from the events panel. **Going to a channel takes the
    /// reader out of the panel**: a page stays up until what it raised has
    /// happened, and arriving in the channel is that — left up, the panel hid
    /// the very channel its link had just opened.
    func openLinkFromEvents(_ string: String) {
        if let link = ChannelLink.parse(string),
           channelIndex[link.destinationID] != nil || channelIndex[link.channelID] != nil {
            eventsPanel = nil
        }
        openLink(string)
    }

    func openLink(_ string: String) {
        // A link into this account is a place in it, whichever surface it was
        // written on.
        if let link = ChannelLink.parse(string) {
            openChannelLink(link, fallbackURL: string)
            return
        }
        // An event in a server the reader is in opens its page here.
        if let link = EventLink.parse(string), openEventLink(link) { return }
        // An invite is a sheet here, never the browser.
        if openInviteLink(string) { return }
        guard InlineScannerSchemeCheck.isSafe(string), let url = URL(string: string) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

extension AppModel {

    /// How a reader gets into a server they are looking at from the outside.
    ///
    /// **Decided by the server's own feature list, which the profile route
    /// already carries.** `MEMBER_VERIFICATION_GATE_ENABLED` is the bit that
    /// turns Join into Apply to Join — both are on the yoho club payload the
    /// join capture answered with, beside `MEMBER_VERIFICATION_MANUAL_APPROVAL`
    /// — and the features were being decoded and read by nothing here.
    ///
    /// The card used to stop at a sentence of this client's own, on the
    /// reading that this client had no route for it. It has had one all along:
    /// `PUT /guilds/{id}/members/@me` is what discovery's own join button
    /// sends, and the application form is the gate the invite flow already
    /// draws.
    func guildEntry(
        for guildID: GuildID,
        profile: GuildProfile?,
        isJoined: Bool
    ) -> GuildProfilePresentation.Entry {
        if isJoined { return .none }
        // Waiting on a moderator beats offering the form again.
        if pendingJoinRequestGuildIDs.contains(guildID) { return .pending }
        guard let profile else { return .none }
        // **Discord's own button for a card with no invite in hand** (module
        // `461888`): the application where the server recruits in public, a
        // look inside where it is discoverable — its Join is a preview, not a
        // membership — and nothing at all otherwise.
        let features = profile.features
        if features.contains("MEMBER_VERIFICATION_GATE_ENABLED"),
           features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL"),
           profile.visibility == 3
        {
            return .apply
        }
        return features.contains("DISCOVERABLE") ? .join : .none
    }
}
