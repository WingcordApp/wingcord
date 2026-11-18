import Foundation
import WingcordCore

extension AppModel {

    /// Which of a game's pictures a surface wants.
    ///
    /// **Two assets for two surfaces, and getting this wrong is what made the
    /// board look cheap.** A board tile is box art — tall, printed, the thing a
    /// shelf of games is made of; `media.cover` is IGDB's `t_cover_big` and is
    /// exactly that. The strip on the small card is a row of *marks*, and there
    /// `media.icon` — the square app icon — is right, because box art shrunk to
    /// thirty points is an unreadable smudge.
    ///
    /// This was a defect, not a preference: the board asked for `icon` and then
    /// stretched a 512-square logo into a poster frame.
    enum GameArtKind {
        /// Box art. Portrait, `GameArt.coverAspect`.
        case cover
        /// The app icon. Square.
        case mark
    }

    /// The picture a surface draws for a game.
    ///
    /// Falls through in the order that surface prefers and then to whatever
    /// exists, so a game carrying only one of the two still draws something
    /// rather than a plate.
    func gameArtURL(_ game: Game, kind: GameArtKind, side: CGFloat) -> URL? {
        let order: [GameMediaRef?] = switch kind {
        case .cover: [game.media.cover, game.media.icon, game.media.banner]
        case .mark: [game.media.icon, game.media.cover, game.media.banner]
        }
        for ref in order.compactMap({ $0 }) {
            switch ref {
            case .hash(let hash):
                if let url = CDN.gameAsset(id: game.id, hash: hash, side: side) { return url }
            case .url(let url):
                return url
            }
        }
        return nil
    }

    /// Whether the art `gameArtURL` will return for `kind` is genuinely box art.
    ///
    /// **A square icon in a portrait frame is drawn differently, not stretched.**
    /// Roughly a third of games carry no `cover`; upscaling their icon to fill a
    /// 3:4 box is the blurry result that started this. Told the truth, the tile
    /// centres the mark on a blurred, saturated copy of itself — the standard
    /// poster-from-a-square, and it reads as deliberate.
    func gameArtIsCover(_ game: Game, kind: GameArtKind) -> Bool {
        kind == .cover && game.media.cover != nil
    }

    /// The wide artwork behind a game profile's header.
    ///
    /// Banner first — it is the one authored to be wide — then the first
    /// artwork, then the cover. A header with nothing behind it is a flat plate,
    /// which is a state the header is built to look deliberate in.
    func gameArtworkURL(_ game: Game, width: CGFloat) -> URL? {
        let refs = [game.media.banner] + game.media.artwork.map { Optional($0) }
            + [game.media.cover]
        for ref in refs.compactMap({ $0 }) {
            switch ref {
            case .hash(let hash):
                if let url = CDN.gameAsset(id: game.id, hash: hash, side: width) { return url }
            case .url(let url):
                return url
            }
        }
        return nil
    }

    /// What the picture across the top of a game's profile is drawn from —
    /// Discord's rule exactly (`t4` in its game profile): `getBannerURL(1400)`,
    /// and where a game has no banner, **one of its `screenshot_urls` at
    /// random**, chosen once each time the page opens (its
    /// `useState(() => Math.random())`). So a game without a banner shows a
    /// different screenshot on each visit, in Discord and here; taking the
    /// first one is why GTA VI's never matched (Alex, 2026-11-18).
    func gameBackdropChoices(_ game: Game, width: CGFloat) -> [URL] {
        switch game.media.banner {
        case .hash(let hash):
            if let url = CDN.gameAsset(id: game.id, hash: hash, side: width) { return [url] }
        case .url(let url):
            return [url]
        case nil:
            break
        }
        return gameScreenshotURLs(game, width: width)
    }

    /// Every screenshot a game's carousel can show, proxied ones and hosted ones
    /// together.
    ///
    /// The proxied URLs come first because they are the ones nearly every game
    /// has — `screenshot_hashes` was empty on all three captures, and the field
    /// is honoured anyway because it is documented and costs one `compactMap`.
    func gameScreenshotURLs(_ game: Game, width: CGFloat) -> [URL] {
        game.screenshotURLs
            + game.screenshotHashes.compactMap {
                CDN.gameScreenshot(id: game.id, hash: $0, width: width)
            }
    }

    // MARK: The board

    /// Somebody's board, joined and ready to draw.
    ///
    /// Returns nil where the person has no widgets — which is most people, and
    /// is what keeps the Board tab from existing for them at all.
    func boardPresentation(for userID: UserID, coverSide: CGFloat = 240) -> BoardPresentation? {
        guard let widgets = profileWidgets[userID], !widgets.isEmpty else { return nil }
        let identities = applicationIdentities[userID] ?? []

        var missingGame = false
        func entry(_ widgetGame: ProfileWidgetGame) -> BoardGame {
            guard let game = games[widgetGame.gameID] else {
                missingGame = true
                return BoardGame(
                    gameID: widgetGame.gameID,
                    comment: widgetGame.comment,
                    tags: widgetGame.tags.sorted { $0.sortRank < $1.sortRank }
                )
            }
            return BoardGame(
                gameID: game.id,
                name: game.name,
                // Box art. A board is a shelf of games, and a shelf is made of
                // covers — see `GameArtKind`.
                coverURL: gameArtURL(game, kind: .cover, side: coverSide),
                isCoverArt: gameArtIsCover(game, kind: .cover),
                comment: widgetGame.comment,
                tags: widgetGame.tags.sorted { $0.sortRank < $1.sortRank }
            )
        }

        let tiles: [BoardTile] = widgets.compactMap { widget in
            switch widget.content {
            case .favouriteGames(let games), .currentGames(let games):
                guard !games.isEmpty else { return nil }
                return BoardTile(
                    id: widget.id,
                    title: widget.title,
                    content: .detailed(games.map(entry))
                )
            case .playedGames(let games), .wantToPlayGames(let games):
                guard !games.isEmpty else { return nil }
                return BoardTile(
                    id: widget.id,
                    title: widget.title,
                    content: .grid(games.map(entry))
                )
            case .application(let applicationID):
                guard let tile = applicationTile(applicationID, identities: identities) else {
                    return nil
                }
                return BoardTile(id: widget.id, title: tile.name, content: .application(tile))
            case .personal(let personal):
                // **Drawn even when it is nearly empty**, unlike a game list.
                // An empty game widget is a promise of games somebody has not
                // chosen; a personal widget with a heading and a cover title is
                // already the thing they made.
                guard !personal.header.isEmpty || !personal.cover.title.isEmpty
                        || personal.cover.image != nil
                else { return nil }
                return BoardTile(
                    id: widget.id,
                    title: personal.header,
                    content: .personal(personal)
                )
            case .clipsGallery(let clips):
                // Only what can play: a clip whose video has not been
                // processed yet has nothing behind its picture.
                let playable = clips.filter { $0.videoURL != nil }
                guard !playable.isEmpty else { return nil }
                return BoardTile(
                    id: widget.id,
                    title: widget.title,
                    content: .clips(playable.map(boardClip))
                )
            case .unknown:
                // A widget kind added after this was written draws nothing
                // rather than an empty frame — `INVARIANTS.md` §5.5.
                return nil
            }
        }

        guard !tiles.isEmpty else { return nil }
        return BoardPresentation(tiles: tiles, isLoadingGames: missingGame)
    }

    /// One application widget, with its template and its data joined.
    ///
    /// Nil only when the application itself is still unresolved: without it the
    /// tile has no name and no header, and a card headed by a snowflake is worse
    /// than a card that has not appeared yet.
    private func applicationTile(
        _ applicationID: ApplicationID,
        identities: [ApplicationIdentity]
    ) -> BoardApplicationTile? {
        guard let application = widgetApplications[applicationID] else { return nil }
        let profile = identities.first { $0.applicationID == applicationID }?.profile
        let config = widgetConfigs[applicationID]

        func resolve(_ kind: WidgetSurface.Kind) -> ResolvedSurface? {
            config?.resolve(kind, with: profile) { id, assetID in
                CDN.applicationAsset(id: id, assetID: assetID, side: 512)
            }
        }

        var bottom = resolve(.widgetBottom)
        // **The identity's own fields, when no template said what to call
        // them.** A linked game whose config has not arrived — or one Discord
        // has never featured — would otherwise show a header and nothing else,
        // while the numbers to fill it are already in hand. The labels are the
        // field names in title case rather than the game's authored ones; see
        // `ApplicationProfile.fallbackStats`. A goal or a collection is a
        // template too: keyed on stats alone, a progress widget fell through
        // to here and printed its raw fraction as "0,69 Progress".
        if bottom?.isEmpty ?? true,
           let stats = profile?.fallbackStats, !stats.isEmpty
        {
            bottom = ResolvedSurface(
                layout: "widget_bottom_stats",
                isHero: false,
                stats: stats
            )
        }

        var top = resolve(.widgetTop)
        // Same fallback for the header: the person's in-game name is the one
        // thing every linked game publishes, and a card that omits it is
        // anonymous.
        if top == nil || top?.isEmpty == true, let profile, let username = profile.username {
            top = ResolvedSurface(
                layout: "widget_top_hero",
                isHero: true,
                title: username,
                subtitles: Self.serverLine(of: profile).map { [$0] } ?? [],
                heroImageURL: profile.featuredCharacterImageURL
            )
        }

        return BoardApplicationTile(
            applicationID: applicationID,
            name: application.name,
            iconURL: application.iconHash.flatMap {
                CDN.applicationIcon(id: applicationID, hash: $0, side: 16)
            },
            top: top,
            bottom: bottom,
            characterImageURL: profile?.featuredCharacterImageURL,
            gameID: application.primaryGameID
        )
    }

    /// "Server: Europe", when the game publishes one.
    ///
    /// Two field names because the two captured games disagree — Arknights
    /// publishes `server` and Wuthering Waves publishes `server_name` — and
    /// neither is more canonical than the other.
    private static func serverLine(of profile: ApplicationProfile) -> String? {
        for name in ["server", "server_name"] {
            if case .text(let value)? = profile.fields[name], !value.isEmpty {
                return "Server: \(value)"
            }
        }
        return nil
    }

    // MARK: The popout's stack

    /// The popout's widget cards, in the person's widget order — Discord's
    /// stack (module `657538`).
    ///
    /// **Not one card per widget.** An application widget is a card only once
    /// its application, its template and the person's identity have all
    /// arrived and the template has a `mini_profile` surface; every game list
    /// together is one "Game Collection" strip, at the first list's place; a
    /// widget the person wrote is its own card.
    func widgetPreviews(for userID: UserID) -> [WidgetPreview] {
        guard let widgets = profileWidgets[userID], !widgets.isEmpty else { return [] }
        let identities = applicationIdentities[userID] ?? []
        var previews: [WidgetPreview] = []
        var hasGames = false
        for widget in widgets {
            switch widget.content {
            case .application(let applicationID):
                if let mini = miniApplicationWidget(applicationID, identities: identities) {
                    previews.append(.application(mini))
                }
            case .favouriteGames, .currentGames, .playedGames, .wantToPlayGames:
                guard !hasGames, let collection = gameCollection(of: widgets) else { continue }
                hasGames = true
                previews.append(.games(collection))
            case .personal(let personal):
                previews.append(.personal(id: widget.id, widget: personal))
            case .clipsGallery(let clips):
                let playable = clips.filter { $0.videoURL != nil }
                guard !playable.isEmpty else { continue }
                previews.append(.clips(id: widget.id, clips: playable.map(boardClip)))
            case .unknown:
                continue
            }
        }
        return previews
    }

    /// A gallery's clip as a board draws it.
    func boardClip(_ clip: ProfileClip) -> BoardClip {
        BoardClip(
            id: clip.id,
            title: clip.title,
            gameName: clip.gameID.flatMap { games[$0]?.name },
            thumbnailURL: clip.thumbnailURL,
            videoURL: clip.videoURL
        )
    }

    /// Plays a board's clips in the viewer, from `index` — Discord's carousel
    /// (`location: "user_profile_widget_clip"`), one clip after another.
    func playBoardClips(_ clips: [BoardClip], from index: Int, owner: String) {
        var items: [MediaItem] = []
        var start = 0
        for (position, clip) in clips.enumerated() {
            guard let video = clip.videoURL else { continue }
            if position == index { start = items.count }
            // An attachment in all but name — the viewer's one item shape. Its
            // id only has to be distinct among these, for this viewing.
            let attachment = Attachment(
                id: AttachmentID(rawValue: UInt64(position + 1)),
                filename: (clip.title ?? "Clip") + ".mp4",
                url: video.absoluteString,
                proxyURL: video.absoluteString,
                contentType: "video/mp4"
            )
            guard let item = MediaItem(
                attachment, posterWidth: 640, posterURL: clip.thumbnailURL, attachmentIndex: position
            ) else { continue }
            items.append(item)
        }
        guard !items.isEmpty else { return }
        mediaViewer = MediaViewerRequest(
            items: items,
            index: start,
            messageID: nil,
            channelID: nil,
            authorName: owner,
            sentAt: .now,
            // Opened from a profile's board, which is drawn over the viewer's
            // own place under the profiles.
            isAboveSheets: true
        )
    }

    private func miniApplicationWidget(
        _ applicationID: ApplicationID,
        identities: [ApplicationIdentity]
    ) -> MiniApplicationWidget? {
        guard let application = widgetApplications[applicationID],
              let config = widgetConfigs[applicationID],
              let identity = identities.first(where: { $0.applicationID == applicationID }),
              let surface = config.resolve(.miniProfile, with: identity.profile, assetURL: { id, assetID in
                  CDN.applicationAsset(id: id, assetID: assetID, side: 256)
              })
        else { return nil }
        return MiniApplicationWidget(
            applicationID: applicationID,
            name: application.name,
            iconURL: application.iconHash.flatMap {
                CDN.applicationIcon(id: applicationID, hash: $0, side: 16)
            },
            surface: surface
        )
    }

    /// Every game the board names, as the strip draws them.
    ///
    /// **One flat list in widget order, deduplicated**, and an application
    /// widget's own game is in it too, as Discord counts it. A game can sit in
    /// three of somebody's tiles at once — one captured board has Genshin Impact
    /// in both the rotation and the liked list — and a strip that drew it twice
    /// would be claiming a larger collection than there is.
    ///
    /// A game `/games` has answered for with no art at all is skipped rather
    /// than drawn as a blank, as Discord skips it; one still on its way draws a
    /// plate so the strip does not reflow when it lands.
    private func gameCollection(of widgets: [ProfileWidget]) -> GameCollection? {
        var seen = Set<ApplicationID>()
        var ordered: [ApplicationID] = []
        for widget in widgets {
            let ids = widget.applicationID.map {
                widgetApplications[$0]?.primaryGameID.map { [$0] } ?? []
            } ?? widget.games.map(\.gameID)
            for id in ids where seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        guard !ordered.isEmpty else { return nil }

        var covers: [BoardGame] = []
        for id in ordered where covers.count < GameCollection.slots {
            guard let game = games[id] else {
                covers.append(BoardGame(gameID: id, tags: []))
                continue
            }
            // **Marks, not covers.** The strip is twenty-four points tall;
            // box art at that size is a smudge, and the square icon is what a
            // reader recognises.
            guard let url = gameArtURL(game, kind: .mark, side: GameArt.markSide) else { continue }
            covers.append(BoardGame(
                gameID: id,
                name: game.name,
                coverURL: url,
                isCoverArt: false,
                tags: []
            ))
        }
        return GameCollection(
            covers: covers,
            overflow: ordered.count > GameCollection.slots ? ordered.count - covers.count : 0
        )
    }

    // MARK: A game's profile

    /// Opens a game's own profile, and starts whatever it still needs.
    /// What opens an activity's game profile — **only a game that has one**,
    /// Discord's rule (modules `692969` and `921138`): its record came back
    /// from `/games`, and it does not carry `GAME_DISABLED`.
    ///
    /// Nil for anything else, and the card then has nothing to click, as
    /// Discord's does. An app somebody is "Playing" — an editor, a bot's own
    /// status — has no record, and opening the page for one anyway was a
    /// spinner that never ended.
    func gameProfileOpener(for applicationID: ApplicationID?) -> (() -> Void)? {
        guard let applicationID else { return nil }
        let gameID = canonicalGameID(for: applicationID)
        guard let game = games[gameID], !game.isProfileDisabled else { return nil }
        return { [weak self] in self?.openGameProfile(gameID) }
    }

    /// The game an application is about — Discord's `getCanonicalGameId`.
    ///
    /// **An activity's application is not always the game.** A title played on
    /// a PlayStation or an Xbox arrives under the application the console's
    /// integration published it as, and that one is no game: `/games` has
    /// nothing for it, and its record names the real game in `linked_games`.
    /// Looking the activity's own id up and stopping there is why a console
    /// game's card had nothing to click.
    func canonicalGameID(for applicationID: ApplicationID) -> ApplicationID {
        if games[applicationID] != nil { return applicationID }
        return widgetApplications[applicationID]?.primaryGameID ?? applicationID
    }

    func openGameProfile(_ gameID: ApplicationID) {
        let gameID = canonicalGameID(for: gameID)
        gameProfileRequest = GameProfileRequest(gameID: gameID)
        sessionController.loadGameProfile(gameID)
    }

    func dismissGameProfile() {
        gameProfileRequest = nil
    }
}
