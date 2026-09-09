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
        // `ApplicationProfile.fallbackStats`.
        if bottom == nil || bottom?.stats.isEmpty == true,
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
                CDN.applicationIcon(id: applicationID, hash: $0, side: 20)
            },
            isVerified: application.isVerified,
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

    // MARK: The mini card's strip

    /// The covers the small card shows, and how many it could not fit.
    ///
    /// **One flat list in widget order, deduplicated.** A game can sit in three
    /// of somebody's tiles at once — one captured board has Genshin Impact in
    /// both the rotation and the liked list — and a strip that drew it twice
    /// would be claiming a larger collection than there is.
    ///
    /// The count is the honest one: covers shown plus `overflow` equals the
    /// collection. Discord's own chip reads **one lower** than that on both
    /// captured cards, which is either an off-by-one in its overflow arithmetic
    /// or a rule no capture here can distinguish it from. A chip that
    /// under-reports is a chip that lies about a number the reader can go and
    /// count, so this reports the total.
    func gameCollection(for userID: UserID, coverSide: CGFloat = 64) -> GameCollection? {
        guard let widgets = profileWidgets[userID] else { return nil }
        var seen = Set<ApplicationID>()
        var ordered: [ApplicationID] = []
        for widget in widgets {
            for game in widget.games where seen.insert(game.gameID).inserted {
                ordered.append(game.gameID)
            }
        }
        guard !ordered.isEmpty else { return nil }

        let fits = ordered.count <= GameCollection.slots
        let shown = fits ? ordered : Array(ordered.prefix(GameCollection.slots - 1))
        let covers = shown.map { id -> BoardGame in
            guard let game = games[id] else { return BoardGame(gameID: id, tags: []) }
            return BoardGame(
                gameID: id,
                name: game.name,
                // **Marks here, not covers.** This strip is thirty points tall;
                // box art at that size is a smudge, and the square icon is what
                // a reader recognises.
                coverURL: gameArtURL(game, kind: .mark, side: coverSide),
                isCoverArt: false,
                tags: []
            )
        }
        return GameCollection(covers: covers, overflow: ordered.count - shown.count)
    }

    /// Every game id a board names, in the order the tiles do.
    ///
    /// What the batched `/games` call is built from. Deduplicated by the caller
    /// rather than here — `DiscordREST.games(ids:)` already does it, and doing
    /// it twice is one pass nobody reads.
    func boardGameIDs(for userID: UserID) -> [ApplicationID] {
        (profileWidgets[userID] ?? []).flatMap { $0.games.map(\.gameID) }
    }

    // MARK: A game's profile

    /// Opens a game's own profile, and starts whatever it still needs.
    func openGameProfile(_ gameID: ApplicationID) {
        gameProfileRequest = GameProfileRequest(gameID: gameID)
        sessionController.loadGameProfile(gameID)
    }

    func dismissGameProfile() {
        gameProfileRequest = nil
    }
}
