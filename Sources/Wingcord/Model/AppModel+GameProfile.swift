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
            launchOffers: game.launchOffers,
            accountLink: accountLink(for: gameID),
            community: communityCard(for: gameID, game: game),
            reviews: game.reviews,
            steamURL: game.steamStoreURL,
            openCriticURL: game.openCriticURL,
            announcements: (announcements?.messages ?? []).compactMap(Self.announcementCard),
            // **The ids are enough, and the permission check that used to be
            // here was the whole of "clicking an announcement does nothing".**
            //
            // It asked `canOpen(channelID)`, which resolves against the channel
            // INDEX — and a channel in a server the reader has not joined is not
            // in the index at all, so it answered false for every reader this
            // shelf is drawn for. That was the right answer while nothing could
            // open the destination. Previewing is what changed it: the server a
            // game's announcements live in carries `PREVIEW_ENABLED` by
            // construction — Discord only surfaces it here because it is
            // discoverable — so the destination exists for everyone, and the
            // lurk is what makes it reachable. See `AppModel.openAnnouncement`.
            //
            // The failure is still handled rather than assumed away: a lurk that
            // is refused clears the preview and leaves the reader where they
            // were, which is `SessionController.previewGuild`'s own guard.
            announcementsChannel: announcements.flatMap { payload in
                guard let guildID = payload.guildID, let channelID = payload.channelID
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
        let trailers = game.trailers.compactMap { trailer in
            CDN.gameTrailer(id: trailer.applicationID, assetID: trailer.id).map {
                GameMediaItem.trailer(
                    video: $0,
                    poster: CDN.gameTrailerPoster(id: trailer.applicationID, assetID: trailer.id, width: 720)
                )
            }
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
    /// The Link Account card's application: **the game's own official one
    /// first** — Discord's `getOfficialApplicationId`, which is how Valorant
    /// offers it — then any widget application linked to the game, which is
    /// how Arknights did before this. Either way only one that publishes where
    /// to link from (`connection_entrypoint_url`), since that page is what the
    /// button opens.
    private func accountLink(for gameID: ApplicationID) -> GameAccountLink? {
        let official = games[gameID]?.officialApplicationID.flatMap { widgetApplications[$0] }
        guard let application = official?.connectionEntrypointURL != nil
            ? official
            : widgetApplications.values.first(where: {
                $0.linkedGameIDs.contains(gameID) && $0.connectionEntrypointURL != nil
            }),
            let url = application.connectionEntrypointURL
        else { return nil }
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
            mark: profile.mark,
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
            // **The markdown is reduced rather than rendered.** These posts
            // are headed with `##` and studded with links; a shelf card three
            // hundred points wide has no room for a heading scale, and leaving
            // the marks in prints "## Map Tools Update" on the card.
            text: Self.excerpt(joined),
            postedAt: message.sentAt,
            reactionCount: message.reactions.reduce(0) { $0 + $1.count }
        )
    }

    private static func mediaURL(_ media: Embed.Media) -> URL? {
        URL(string: media.proxyURL ?? media.url)
    }

    /// Markdown reduced to the words a card can carry.
    ///
    /// **The app's own parser, not a second pass of string replacements.** What
    /// this replaces stripped `#`, `**` and `__` and left everything else on
    /// screen, so a Rockstar post reached the shelf as
    ///
    /// ```
    /// … official site <@&1299097019163480074>
    /// [youtube.com/rockstargames](<https://www.youtube.com/watch?v=…>)
    /// ```
    ///
    /// — which is the raw wire content with three marks missing. A card excerpt
    /// is not a smaller kind of markdown, it is the *fold* of the same tree the
    /// transcript paints, and `MarkdownParser` already builds that tree.
    ///
    /// **Mentions and timestamps are dropped rather than named**, which is the
    /// one place this differs from `MarkdownDocument.plainText`. That fold
    /// answers `@role` and `time`, which is right for an accessibility label
    /// read aloud in place and is a fake name on a card: these posts come from
    /// the game's own server, which the reader is usually not in, so there is no
    /// role table to resolve `<@&…>` against. A trailing ping carries nothing a
    /// digest needs either way.
    static func excerpt(_ markdown: String) -> String {
        var out = ""
        out.reserveCapacity(markdown.count)
        for (index, block) in MarkdownParser().parse(markdown).blocks.enumerated() {
            if index > 0 { out += "\n" }
            append(block, to: &out)
        }
        return tidied(out)
    }

    private static func append(_ block: BlockNode, to out: inout String) {
        switch block {
        case .paragraph(let nodes), .subtext(let nodes), .heading(_, let nodes):
            append(nodes, to: &out)
        case .codeBlock(_, let code):
            out += code
        case .quote(let children):
            for (index, child) in children.enumerated() {
                if index > 0 { out += "\n" }
                append(child, to: &out)
            }
        case .list(_, _, let items):
            for (index, item) in items.enumerated() {
                if index > 0 { out += "\n" }
                for child in item { append(child, to: &out) }
            }
        }
    }

    private static func append(_ nodes: [InlineNode], to out: inout String) {
        for node in nodes {
            switch node {
            case .text(let value), .code(let value), .autoLink(let value):
                out += value
            // A link becomes its label, which is what the author wrote for a
            // reader rather than for a browser.
            case .styled(_, let children), .link(let children, _):
                append(children, to: &out)
            case .customEmoji(let emoji):
                out += ":\(emoji.name):"
            case .lineBreak:
                out += "\n"
            case .userMention, .roleMention, .channelMention, .commandMention, .gameMention,
                 .everyoneMention, .hereMention, .timestamp, .staticRoute:
                continue
            }
        }
    }

    /// One space between words, one line per line, nothing blank anywhere.
    ///
    /// **Dropping a node leaves the space that was around it**, so a sentence
    /// ending in a ping comes out with a hole in it and a paragraph that was
    /// nothing but a ping comes out empty. Both are the excerpt's own doing and
    /// are cleaned up here rather than left for a `Text` to render as a gap.
    ///
    /// Blank lines go entirely, not down to one: blocks are already joined with
    /// a single newline, so every empty line reaching this point is one the fold
    /// made, and a 240-point card has no room to spend on the ones it did not.
    private static func tidied(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let squeezed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if squeezed.isEmpty { continue }
            lines.append(squeezed)
        }
        return lines.joined(separator: "\n")
    }
}
