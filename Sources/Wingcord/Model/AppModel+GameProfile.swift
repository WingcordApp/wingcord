import Foundation
import WingcordCore

extension AppModel {

    /// Everything a game's profile draws, joined.
    ///
    /// Returns nil only while the game itself is still out — every other section
    /// is optional and simply does not appear. That is not defensive coding: the
    /// three captured games differ from each other in exactly which sections
    /// they have, and a sheet that reserved space for all of them would be three
    /// quarters empty on Beat Saber.
    func gamePresentation(for gameID: ApplicationID) -> GamePresentation? {
        guard let game = games[gameID] else { return nil }
        let announcements = gameAnnouncements[gameID]

        return GamePresentation(
            gameID: gameID,
            name: game.name,
            genreLine: game.genreLine,
            summary: game.summary,
            coverURL: gameArtURL(game, kind: .cover, side: 340),
            hasCoverArt: gameArtIsCover(game, kind: .cover),
            markURL: gameArtURL(game, kind: .mark, side: 64),
            artworkURL: gameArtworkURL(game, width: 1024),
            globalRank: game.globalRank,
            media: gameMedia(of: game),
            themes: game.themes,
            details: detailRows(of: game),
            links: game.socialLinks,
            storeLink: game.websites.first { $0.category == .steam },
            accountLink: accountLink(for: gameID),
            community: communityCard(for: gameID, game: game),
            reviews: game.reviews,
            openCriticURL: game.openCriticURL,
            announcements: (announcements?.messages ?? []).compactMap(Self.announcementCard),
            // **Only where the reader could actually go there.** The
            // announcements live in the game's own server, which most readers
            // are not in — and a "View All" that opens nothing is the inert
            // control `INVARIANTS.md` §5.5 forbids. Joining is offered one
            // section over, on the community card.
            announcementsChannel: announcements.flatMap { payload in
                guard let guildID = payload.guildID,
                      let channelID = payload.channelID,
                      canOpen(channelID)
                else { return nil }
                return (guildID, channelID)
            },
            similar: (similarGames[gameID] ?? []).compactMap { id in
                guard let similar = games[id] else { return nil }
                return BoardGame(
                    gameID: id,
                    name: similar.name,
                    coverURL: gameArtURL(similar, kind: .cover, side: 240),
                    isCoverArt: gameArtIsCover(similar, kind: .cover),
                    tags: []
                )
            },
            isLoading: gameProfilesLoading.contains(gameID)
        )
    }

    /// The tray's items: the trailer first, then every still.
    ///
    /// **The trailer was decoded and never drawn**, which made it the single
    /// biggest unbuilt thing on this page — a game's own moving pitch, sitting
    /// in the payload behind a shelf of stills. `GameTrailer` names a store
    /// asset, so it resolves through the same `/app-assets/{id}/store/` path
    /// the activity preview already probed.
    private func gameMedia(of game: Game) -> [GameMediaItem] {
        let trailers = game.trailers.compactMap {
            CDN.gameTrailer(id: $0.applicationID, assetID: $0.id).map(GameMediaItem.trailer)
        }
        return trailers + gameScreenshotURLs(game, width: 720).map(GameMediaItem.still)
    }

    /// The Details table, in Discord's own order.
    ///
    /// **Every row is conditional and the labels pluralise.** Beat Saber lists
    /// two publishers and one platform and reads "Publishers" and "Platform";
    /// The Sims lists one publisher and three platform marks and reads
    /// "Publisher" and "Platforms". A fixed label is wrong on one of them.
    private func detailRows(of game: Game) -> [GameDetailRow] {
        var rows: [GameDetailRow] = []

        if !game.genres.isEmpty {
            rows.append(GameDetailRow(title: "Genres", content: .text(game.genreLine)))
        }
        let publishers = game.publishers
        if !publishers.isEmpty {
            rows.append(GameDetailRow(
                title: publishers.count == 1 ? "Publisher" : "Publishers",
                content: .text(publishers.joined(separator: ", "))
            ))
        }
        let developers = game.developers
        if !developers.isEmpty {
            rows.append(GameDetailRow(
                title: developers.count == 1 ? "Developer" : "Developers",
                content: .text(developers.joined(separator: ", "))
            ))
        }
        if let date = game.releaseDate {
            rows.append(GameDetailRow(
                title: "Release Date",
                content: .text(date.formatted(.dateTime.month(.wide).day().year()))
            ))
        }
        let platforms = GamePlatform.displayGroups(of: game.platforms)
        if !platforms.isEmpty {
            rows.append(GameDetailRow(
                title: platforms.count == 1 ? "Platform" : "Platforms",
                content: .platforms(platforms)
            ))
        }
        return rows
    }

    /// The Link Account card, when a widget application publishes an address for
    /// this game.
    ///
    /// **Reached backwards, through `linked_games`.** A game does not name the
    /// application that publishes stats for it; the application names the game.
    /// So this scans the applications already resident — every one of which was
    /// fetched because somebody's board named it — rather than asking a route
    /// that does not exist.
    private func accountLink(for gameID: ApplicationID) -> GameAccountLink? {
        guard let application = widgetApplications.values.first(where: {
            $0.linkedGameIDs.contains(gameID) && $0.connectionEntrypointURL != nil
        }), let url = application.connectionEntrypointURL else { return nil }
        return GameAccountLink(
            applicationName: application.name,
            iconURL: application.iconHash.flatMap {
                CDN.applicationIcon(id: application.id, hash: $0, side: 40)
            },
            url: url
        )
    }

    private func communityCard(for gameID: ApplicationID, game: Game) -> GameCommunityCard? {
        guard let code = game.communityInviteCode,
              let profile = gameCommunities[gameID]
        else { return nil }
        return GameCommunityCard(
            guildID: profile.id,
            name: profile.name,
            iconURL: profile.iconHash.flatMap {
                CDN.guildIcon(guildID: profile.id, hash: $0, side: 48)
            },
            monogram: Self.monogram(of: profile.name),
            description: profile.description,
            memberCount: profile.memberCount,
            onlineCount: profile.onlineCount,
            isVerified: profile.standing == .verified || profile.standing == .partner,
            inviteCode: code,
            // The reader is in it or they are not, and the button says which.
            isJoined: guilds[profile.id] != nil
        )
    }

    /// One announcement, digested.
    ///
    /// Walks the message's component tree for the first picture and for the
    /// words, and falls back to the plain `content` and the attachments for a
    /// post that predates components v2. Nil for a post with neither: a card
    /// carrying a date and nothing else says less than no card.
    static func announcementCard(_ message: Message) -> GameAnnouncementCard? {
        var image: URL?
        var text: [String] = []

        func walk(_ nodes: [DisplayComponent]) {
            for node in nodes {
                switch node {
                case .container(_, let children):
                    walk(children)
                case .section(let children, let thumbnail):
                    walk(children)
                    if image == nil, let thumbnail { image = Self.mediaURL(thumbnail) }
                case .text(let value):
                    if !value.isEmpty { text.append(value) }
                case .gallery(let items):
                    if image == nil, let first = items.first { image = Self.mediaURL(first) }
                // A separator has nothing to say in a digest, and a row of
                // buttons is a control this card is not.
                case .separator, .row:
                    continue
                }
            }
        }
        walk(message.displayComponents)

        if text.isEmpty, !message.content.isEmpty { text.append(message.content) }
        if image == nil {
            image = message.attachments.first(where: \.isImage)
                .flatMap { URL(string: $0.proxyURL.isEmpty ? $0.url : $0.proxyURL) }
                ?? message.embeds.compactMap { $0.image ?? $0.thumbnail }.first
                    .flatMap(Self.mediaURL)
        }

        let joined = text.joined(separator: "\n\n")
        guard !joined.isEmpty || image != nil else { return nil }
        return GameAnnouncementCard(
            id: message.id,
            imageURL: image,
            // **The markdown is stripped rather than rendered.** These posts
            // are headed with `##` and studded with links; a shelf card three
            // hundred points wide has no room for a heading scale, and leaving
            // the marks in prints "## Map Tools Update" on the card.
            text: Self.plainText(joined),
            postedAt: message.sentAt,
            reactionCount: message.reactions.reduce(0) { $0 + $1.count }
        )
    }

    private static func mediaURL(_ media: Embed.Media) -> URL? {
        URL(string: media.proxyURL ?? media.url)
    }

    /// Markdown reduced to its words.
    ///
    /// Heading and emphasis marks removed, links reduced to their label. Not a
    /// parser: this is a *card excerpt*, and the app's real parser produces a
    /// node tree for a painted canvas that this surface does not have.
    static func plainText(_ markdown: String) -> String {
        var result = ""
        result.reserveCapacity(markdown.count)
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = Substring(line)
            while text.first == "#" { text = text.dropFirst() }
            if text.first == " " { text = text.dropFirst() }
            result += text
            result += "\n"
        }
        result = result.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
