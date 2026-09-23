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
                detail: "A standard emoji. It works in every conversation, "
                    + "in every server, for everyone.",
                source: nil
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
        // Discord's own packs are not a server, so they answer the "where from"
        // question with a pack name rather than with a rail icon.
        let pack = owner == nil ? standardStickerPack(containing: sticker.id) : nil

        return ExpressionInfo(
            artURL: CDN.sticker(id: sticker.id, format: sticker.format),
            isVector: sticker.format == .lottie,
            glyph: nil,
            title: sticker.name.isEmpty ? "Sticker" : sticker.name,
            detail: pack.map { "From the \($0) sticker pack." }
                ?? detail(owner: owner, id: sticker.id, noun: "sticker"),
            source: pack == nil ? resolvedSource(owner: owner, id: sticker.id) : nil
        )
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
                standing: isPublic ? guild.standing : nil,
                sample: sample,
                isJoined: false
            )
        }
    }

    /// Starts the lookup a foreign expression needs.
    ///
    /// Called by the presenter rather than by the resolver: a resolver that
    /// fires a request is a resolver that fires one every time a view body runs.
    func loadExpressionSourceIfNeeded(for request: ExpressionInfoRequest) {
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
            // One of Discord's own packs has a pack name and no server behind it.
            guard standardStickerPack(containing: sticker.id) == nil else { return }
            sessionController.loadExpressionSource(sticker.id, isSticker: true)
        }
    }

    /// The pack one of Discord's own stickers belongs to.
    ///
    /// A scan over the standard packs, which is a few hundred entries fetched
    /// once per launch — small enough that an index keyed by sticker id would be
    /// a second structure to keep correct for a lookup made on a click.
    private func standardStickerPack(containing id: UInt64) -> String? {
        for section in defaultStickerPacks
        where section.items.contains(where: { $0.id == String(id) }) {
            return section.title
        }
        return nil
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
            standing: GuildProfile.Standing(features: guild.features),
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
        // the answer — which it is: the card below it already says "You are not
        // in this server", and this is the same fact said in the title.
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
            // **Both hashes, because they are two different CDN families** —
            // see `CDN.guildProfileBanner`. The resident guild's own banner
            // stands in for a server the reader is already a member of, which
            // is the one case the profile route may not have been asked for.
            bannerURL: CDN.guildProfileBanner(
                guildID: guildID,
                bannerHash: profile?.bannerHash ?? resident?.bannerHash,
                customBannerHash: profile?.customBannerHash,
                width: 340
            ),
            badgeURL: profile?.badgeHash.flatMap {
                CDN.guildTagBadge(guildID: guildID, hash: $0)
            } ?? badgeURL,
            badgeColorPrimary: profile?.badgeColorPrimary,
            badgeColorSecondary: profile?.badgeColorSecondary,
            standing: profile?.standing
                ?? resident.flatMap { GuildProfile.Standing(features: $0.features) },
            description: profile?.description,
            memberCount: profile?.memberCount ?? resident?.memberCount,
            onlineCount: profile?.onlineCount,
            traits: profile?.traits ?? [],
            games: guildProfileGames(profile),
            createdAt: guildID.timestamp,
            isJoined: resident != nil,
            isLoading: guildProfilesLoading.contains(guildID),
            entry: guildEntry(for: guildID, profile: profile, isJoined: resident != nil)
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
        jumpToken &+= 1
        pendingJump = MessageJump(
            channelID: channelID,
            messageID: messageID,
            token: jumpToken,
            highlights: highlights
        )
    }

    /// Follows a message link.
    func openMessageLink(_ link: MessageLink) {
        // The permission gate answers for every channel in the account, so a
        // link into a private channel the reader cannot see stops here rather
        // than opening an empty transcript.
        guard canOpen(link.channelID) else { return }
        profileRequest = nil
        expressionInfoRequest = nil
        if let guildID = link.guildID, selectedGuildID != guildID {
            selectGuild(guildID)
        } else if link.guildID == nil, selectedGuildID != nil {
            selectGuild(nil)
        }
        sessionController.jumpToMessage(link.messageID, in: link.channelID)
    }

    /// Follows a link somebody wrote — in a message, in a bio, in a status.
    ///
    /// **One opener for every surface**, because two of them is two places for
    /// the boundary below to be got right. A link into this account goes to the
    /// channel it names; everything else goes to the browser, and only after the
    /// scheme has been checked *here* rather than trusted from wherever the
    /// string came from. `INVARIANTS.md` §5.5: a client that navigates on an
    /// unchecked host is a client anybody who can write to it can steer.
    func openLink(_ string: String) {
        // A Discord message link the renderer could not name is still a place in
        // this account. The store has the whole index, so it can answer what a
        // single surface could not.
        if let link = MessageLink.parse(string), channelIndex[link.channelID] != nil {
            openMessageLink(link)
            return
        }
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
    /// The card used to say "You are not in this server." and stop, on the
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
        return profile.features.contains("MEMBER_VERIFICATION_GATE_ENABLED")
            ? .apply
            : .join
    }
}
