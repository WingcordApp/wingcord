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
            mobileReviews: game.mobileStoreReviews,
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
            isLoading: gameProfilesLoading.contains(gameID),
            hasCommunities: game.communityGuildIDs.count >= Self.communitiesThreshold
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

    /// One announcement, digested — Discord's `pp` (`05ea9e44…`), step for step.
    ///
    /// **The words**: a components post's text displays, joined line by line; a
    /// plain post's content — or, when the content is nothing but a link, the
    /// link's embed, as `# title` and its description. **The title** is the
    /// first line when it is a heading. **The picture** is the first one of: a
    /// gallery's first item, an image attachment, a video attachment's first
    /// frame, an embed's video thumbnail, image or thumbnail. A forward is
    /// digested from what it carries. Nil for a post that has nothing to show.
    static func announcementCard(_ message: Message) -> GameAnnouncementCard? {
        let forwarded = message.forwarded
        let content = forwarded?.content ?? message.content
        let attachments = forwarded?.attachments ?? message.attachments
        let embeds = forwarded?.embeds ?? message.embeds
        let components = forwarded == nil ? message.displayComponents : []

        var texts: [String] = []
        var galleryMedia: Embed.Media?
        var sectionThumbnail: Embed.Media?
        func walk(_ nodes: [DisplayComponent]) {
            for node in nodes {
                switch node {
                case .container(_, let children):
                    walk(children)
                case .section(let children, let thumbnail):
                    walk(children)
                    if sectionThumbnail == nil { sectionThumbnail = thumbnail }
                case .text(let value):
                    if !value.isEmpty { texts.append(value) }
                case .gallery(let items):
                    if galleryMedia == nil { galleryMedia = items.first(where: { !$0.isSpoiler }) }
                // A separator has nothing to say on a card, and a row of
                // buttons is a control this card is not.
                case .separator, .row:
                    continue
                }
            }
        }
        walk(components)

        // The words.
        var words: String
        var wordsFromEmbed = false
        if !components.isEmpty {
            words = texts.joined(separator: "\n")
        } else {
            words = content
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLoneLink = trimmed.wholeMatch(of: /https?:\/\/\S+/) != nil
            if trimmed.isEmpty || isLoneLink, let embed = embeds.first {
                let parts = [embed.title.map { "# \($0)" }, embed.description].compactMap { $0 }
                if !parts.isEmpty {
                    words = parts.joined(separator: "\n")
                    wordsFromEmbed = true
                }
            }
        }

        // The title, when the first line is a heading.
        var title: String?
        var body = words
        let firstBreak = words.firstIndex(of: "\n")
        let firstLine = firstBreak.map { String(words[..<$0]) } ?? words
        if let heading = firstLine.wholeMatch(of: /#{1,3}\s+(.+)/) {
            title = String(heading.1).trimmingCharacters(in: .whitespaces)
            body = firstBreak.map { String(words[words.index(after: $0)...]) } ?? ""
            body = String(body.drop(while: \.isWhitespace))
        }

        let media = announcementMedia(
            gallery: galleryMedia,
            attachments: attachments,
            embeds: embeds,
            sectionThumbnail: sectionThumbnail
        )
        let poll = message.poll.map { poll in
            GameAnnouncementCard.PollDigest(
                question: poll.question,
                answers: poll.answers.prefix(3).map(\.text),
                more: max(0, poll.answers.count - 3),
                expiresAt: poll.expiresAt,
                isClosed: poll.isClosed
            )
        }
        let source: GameAnnouncementCard.Source? = {
            guard wordsFromEmbed, let embed = embeds.first else { return nil }
            let found = GameAnnouncementCard.Source(
                url: embed.url,
                authorName: embed.author?.name,
                authorIconURL: (embed.author?.iconURL).flatMap(URL.init(string:)),
                colorValue: embed.colorValue
            )
            return found.url == nil && found.authorName == nil && embed.footer == nil
                && embed.providerName == nil ? nil : found
        }()

        guard title != nil || !body.isEmpty || media != nil || poll != nil else { return nil }
        let spoken = [title.map(excerpt), body.isEmpty ? nil : excerpt(body), poll?.question]
            .compactMap { $0 }
            .joined(separator: ". ")
        return GameAnnouncementCard(
            id: message.id,
            title: title,
            body: body,
            media: media,
            postedAt: message.sentAt,
            reactionCount: message.reactions.reduce(0) { $0 + $1.count },
            poll: poll,
            source: source,
            spokenText: spoken
        )
    }

    /// The card's picture, in Discord's order of preference.
    private static func announcementMedia(
        gallery: Embed.Media?,
        attachments: [Attachment],
        embeds: [Embed],
        sectionThumbnail: Embed.Media?
    ) -> GameAnnouncementCard.Media? {
        if let gallery {
            return cardMedia(gallery.proxyURL ?? gallery.url, width: gallery.width, height: gallery.height)
        }
        if let image = attachments.first(where: { $0.isImage && !$0.isSpoiler }) {
            return cardMedia(image.proxyURL.isEmpty ? image.url : image.proxyURL, width: image.width, height: image.height)
        }
        // **A video is shown by its first frame**, which the media proxy cuts
        // when it is asked for a picture format — the request Discord makes for
        // this card. Without this a post whose picture is a video had none.
        if let video = attachments.first(where: { $0.isVideo && !$0.isSpoiler }), !video.proxyURL.isEmpty {
            return cardMedia(video.proxyURL, width: video.width, height: video.height)
        }
        if let embed = embeds.first(where: { $0.video != nil && $0.thumbnail != nil }), let thumb = embed.thumbnail {
            return cardMedia(thumb.proxyURL ?? thumb.url, width: thumb.width, height: thumb.height)
        }
        if let image = embeds.lazy.compactMap(\.image).first {
            return cardMedia(image.proxyURL ?? image.url, width: image.width, height: image.height)
        }
        if let thumb = embeds.lazy.compactMap(\.thumbnail).first {
            return cardMedia(thumb.proxyURL ?? thumb.url, width: thumb.width, height: thumb.height)
        }
        if let sectionThumbnail {
            return cardMedia(
                sectionThumbnail.proxyURL ?? sectionThumbnail.url,
                width: sectionThumbnail.width, height: sectionThumbnail.height
            )
        }
        return nil
    }

    /// The width a card's picture is fetched at: Discord's 364 points, at two
    /// pixels a point.
    static let announcementPictureWidth = 728

    /// A picture asked of the media proxy at the card's size, as WebP — Discord's
    /// `nB`. Only Discord's own hosts are given the parameters; anything else is
    /// fetched as it is.
    static func cardMedia(_ raw: String, width: Int?, height: Int?) -> GameAnnouncementCard.Media? {
        guard var parts = URLComponents(string: raw), let host = parts.host else { return nil }
        var aspect = 16.0 / 9
        if let width, let height, width > 0, height > 0 { aspect = Double(width) / Double(height) }
        if host == "media.discordapp.net" || host.hasSuffix(".discordapp.net") {
            let wide = announcementPictureWidth
            var items = parts.queryItems ?? []
            items.removeAll { ["format", "width", "height"].contains($0.name) }
            items += [
                URLQueryItem(name: "format", value: "webp"),
                URLQueryItem(name: "width", value: String(wide)),
                URLQueryItem(name: "height", value: String(Int((Double(wide) / aspect).rounded()))),
            ]
            parts.queryItems = items
        }
        guard let url = parts.url else { return nil }
        return GameAnnouncementCard.Media(url: url, aspect: aspect)
    }

    /// A mention table for one server — the announcements' own — so a role
    /// mention in a post names the role where this session knows the server.
    func mentionContext(inGuild guildID: GuildID?) -> MentionContext {
        mentionContextWithoutPeople(guildID: guildID)
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
