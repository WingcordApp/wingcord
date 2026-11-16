import Foundation
import WingcordCore

// MARK: - Server Hub: the page as values

extension AppModel {

    /// The page for the selected server, or nil with none selected.
    var serverHubPresentation: ServerHubPresentation? {
        guard let guildID = selectedGuildID, let guild = guilds[guildID] else { return nil }
        let store = serverHub
        let draft = store.draft?.guildID == guildID ? store.draft : nil
        let space = store.spaces[guildID]
        let canEdit = canEditServerHub(guildID)
        let isEditing = draft != nil

        let phase: ServerHubPresentation.Phase = if draft != nil || space != nil {
            .ready
        } else if store.missing.contains(guildID) {
            canEdit ? .ready : .missing
        } else if store.failed.contains(guildID) {
            .failed
        } else {
            .loading
        }

        let widgets = draft?.widgets ?? space?.widgets ?? []
        let columns = GuildSpaceLayout.columns(widgets).map { column in
            column
                .filter(\.kind.isDrawn)
                // Discord's `e2`: a locked widget is the editor's business.
                .filter { canEdit || !$0.isLocked }
                .map { serverHubWidget($0, guildID: guildID, channelID: space?.channelID, isEditing: isEditing) }
        }

        return ServerHubPresentation(
            guildID: guildID,
            header: serverHubHeader(guild, space: space, draft: draft),
            columns: columns,
            isEditing: isEditing,
            canEdit: canEdit,
            isPublished: guild.spaceSettings?.isPublished ?? (space != nil),
            phase: phase,
            saveState: draft?.saveState ?? .idle,
            hasChanges: draft?.hasChanges ?? false,
            isPublishing: store.settingsInFlight.contains(guildID)
        )
    }

    // MARK: The banner

    private func serverHubHeader(_ guild: Guild, space: GuildSpace?, draft: ServerHubDraft?) -> ServerHubPresentation.Header {
        let profile = guildProfiles[guild.id]
        var preview: Data?
        var customHash = space?.customBannerHash
        switch draft?.banner {
        case .replaced(_, let data): preview = data
        case .removed: customHash = nil
        case .unchanged, nil: break
        }
        let bannerURL = (customHash != nil ? serverHub.demoBannerURL : nil) ?? customHash.flatMap {
            CDN.guildSpaceBanner(guildID: guild.id, hash: $0, width: ServerHubMetrics.pageWidth)
        } ?? guild.bannerHash.flatMap {
            CDN.guildBanner(guildID: guild.id, hash: $0, width: ServerHubMetrics.pageWidth)
        }
        return ServerHubPresentation.Header(
            name: guild.name,
            iconURL: guild.iconHash.flatMap { CDN.guildIcon(guildID: guild.id, hash: $0, side: ServerHubMetrics.bannerIconSide) },
            monogram: Guild.monogram(of: guild.name),
            bannerURL: preview == nil ? bannerURL : nil,
            bannerPreview: preview,
            tint: profile?.brandColorPrimary,
            hasCustomBanner: preview != nil || customHash != nil,
            onlineCount: profile?.onlineCount,
            memberCount: profile?.memberCount ?? guild.memberCount,
            boostCount: guild.premiumSubscriptionCount
        )
    }

    // MARK: One widget

    private func serverHubWidget(
        _ widget: GuildSpaceWidget,
        guildID: GuildID,
        channelID: ChannelID?,
        isEditing: Bool
    ) -> ServerHubPresentation.Widget {
        var item = ServerHubPresentation.Widget(
            id: widget.id,
            kind: widget.kind,
            title: widget.defaultTitle ?? ServerHubWidgetNames.defaultTitle(widget.kind),
            symbolName: ServerHubWidgetNames.symbol(widget.kind),
            content: .loading,
            isLocked: widget.isLocked,
            boostPrice: serverHub.catalogs[guildID]?.first { $0.kind == widget.kind }?.boostPrice
        )
        let hydration = serverHub.hydrations[widget.id]

        switch widget.kind {
        case .leaderboard:
            switch hydration {
            case .loaded(.leaderboard(let board)):
                item.title = board.stat.name
                if let days = board.daysLeft() {
                    item.accessory = "\(days)d left"
                    item.accessoryHelp = "\(board.stat.question) This competition ends \(board.endsAt.formatted(date: .abbreviated, time: .shortened))."
                } else {
                    item.accessory = "Ended"
                    item.accessoryHelp = "This competition ended. The next one is \(board.nextStat.name)."
                }
                if board.hasEnoughEntries {
                    item.content = .leaderboard(leaderboardModel(board, guildID: guildID))
                    item.expansion = .leaderboard(widgetID: widget.id)
                } else {
                    item.content = .notEnoughData(
                        title: "Not enough data",
                        detail: "There need to be at least 3 server members sharing their gaming activity to have a leaderboard."
                    )
                }
            default:
                item.content = hydratedFallback(hydration, isDraft: widget.isDraft || isEditing && hydration == nil,
                    title: "Save to see the leaderboard",
                    detail: "Member rankings will show up here once there\u{2019}s enough gaming activity.")
            }

        case .popularGames:
            switch hydration {
            case .loaded(.popularGames(let games)):
                item.content = games.hasEnoughData
                    ? .popularGames(popularGamesModel(games))
                    : .notEnoughData(
                        title: "Not enough data",
                        detail: "There need to be at least 3 server members sharing their gaming activity to have popular games."
                    )
            default:
                item.content = hydratedFallback(hydration, isDraft: widget.isDraft || isEditing && hydration == nil,
                    title: "Save to see popular games",
                    detail: "Games your members are playing will show up here once there\u{2019}s enough gaming activity.")
            }

        case .popularMusic:
            switch hydration {
            case .loaded(.popularMusic(let music)):
                item.content = music.hasPlays
                    ? .popularMusic(popularMusicModel(music, guildID: guildID))
                    : .notEnoughData(
                        title: "No music yet",
                        detail: "There need to be at least 3 server members sharing their Spotify listening activity to have popular music."
                    )
            default:
                item.content = hydratedFallback(hydration, isDraft: widget.isDraft || isEditing && hydration == nil,
                    title: "Save to see popular music",
                    detail: "What your members listen to on Spotify will show up here.")
            }

        case .imageText:
            item.title = widget.config.title ?? ""
            item.content = .imageText(imageTextModel(widget, guildID: guildID))
            item.settings = .imageText(widgetID: widget.id)

        case .whiteboard:
            item.content = .whiteboard(whiteboardModel(channelID: channelID, guildID: guildID, isEditing: isEditing))
            if canEditServerHub(guildID), channelID != nil {
                item.settings = .whiteboardAccess(widgetID: widget.id)
            }

        default:
            break
        }
        return item
    }

    private func hydratedFallback(
        _ state: ServerHubHydrationState?,
        isDraft: Bool,
        title: String,
        detail: String
    ) -> ServerHubPresentation.Widget.Content {
        if isDraft { return .awaitingSave(title: title, detail: detail) }
        return switch state {
        case .failed: .failed
        default: .loading
        }
    }

    // MARK: The leaderboard

    private func leaderboardModel(_ board: GuildSpaceLeaderboard, guildID: GuildID) -> LeaderboardCardModel {
        let reader = currentUserID
        let rows = board.visibleEntries(limit: 20, reader: reader).map { entry in
            let user = users[entry.userID]
            let isHidden = relationships[entry.userID] == .blocked
            let shownGames = entry.applicationCount > 3 ? 2 : 3
            let games = isHidden ? [] : entry.applicationIDs.prefix(shownGames).map { id in
                LeaderboardCardModel.Game(id: id, name: serverHubGameName(id), iconURL: serverHubGameIcon(id, side: 24))
            }
            return LeaderboardCardModel.Row(
                id: entry.userID,
                rank: entry.rank,
                name: isHidden ? "Blocked User" : voiceName(of: entry.userID, inGuild: guildID),
                nameColor: isHidden ? nil : voiceNameColor(of: entry.userID, inGuild: guildID),
                avatarURL: isHidden ? nil : user.flatMap { avatarURL(for: $0, side: 32) },
                monogram: user?.monogram ?? "?",
                lastPlayed: isHidden ? nil : entry.applicationIDs.first.map { "Last played \(serverHubGameName($0))" },
                value: GuildSpaceFormat.value(entry.value, stat: board.stat),
                detail: board.stat == .hoursPlayed ? nil : entry.timePlayedSeconds.map {
                    "\(GuildSpaceFormat.playTime(seconds: Double($0))) total"
                },
                valueSymbol: Self.leaderboardSymbol(board.stat),
                games: Array(games),
                moreGames: isHidden ? 0 : max(0, entry.applicationCount - games.count),
                isReader: entry.userID == reader,
                isHidden: isHidden
            )
        }
        var unranked: LeaderboardCardModel.Unranked?
        if let reader, board.entry(for: reader) == nil, let user = users[reader] {
            unranked = .init(
                name: voiceName(of: reader, inGuild: guildID),
                avatarURL: avatarURL(for: user, side: 32),
                monogram: user.monogram,
                message: selfStatus == .invisible
                    ? "Being invisible hides your gaming activity. Go Online to join the leaderboard."
                    : "Play some games to join the leaderboard! Progress will be shown starting tomorrow."
            )
        }
        return LeaderboardCardModel(stat: board.stat, rows: rows, unranked: unranked, lastUpdated: board.computedAt)
    }

    static func leaderboardSymbol(_ stat: GuildSpaceLeaderboard.Stat) -> String {
        switch stat {
        case .daysPlayed: "calendar"
        case .uniqueGamesPlayed: "gamecontroller.fill"
        case .hoursPlayed, .unspecified: "clock.fill"
        }
    }

    // MARK: Popular Games

    private func popularGamesModel(_ data: GuildSpacePopularGames) -> PopularGamesCardModel {
        let tiles = data.games.prefix(ServerHubMetrics.maxGameTiles).map { game in
            PopularGamesCardModel.Tile(
                id: game.applicationID,
                name: serverHubGameName(game.applicationID),
                coverURL: serverHubGameCover(game.applicationID, side: ServerHubMetrics.gameTileWidth),
                iconURL: serverHubGameIcon(game.applicationID, side: 64),
                players: game.userIDs.count
            )
        }
        let faces = data.userIDs
            .filter { relationships[$0] != .blocked }
            .prefix(4)
            .compactMap { id -> StackedFace? in
                guard let user = users[id] else { return nil }
                return StackedFace(id: id, url: avatarURL(for: user, side: Metrics.avatarInline), monogram: user.monogram)
            }
        return PopularGamesCardModel(
            tiles: Array(tiles),
            backdropURL: tiles.first?.coverURL ?? tiles.first?.iconURL,
            playerCount: data.totalUsers,
            gameCount: data.totalGames,
            faces: Array(faces),
            moreFaces: max(0, data.totalUsers - faces.count)
        )
    }

    /// A widget's game by its application id, as Discord names it: the
    /// canonical game's name, else the application's own.
    func serverHubGameName(_ id: ApplicationID) -> String {
        games[canonicalGameID(for: id)]?.name ?? widgetApplications[id]?.name
            ?? activityApp(id)?.name ?? "Unknown game"
    }

    /// The application's own icon first, as Discord draws it on a leaderboard
    /// row (`getIconURL(64)`), then the game's mark.
    func serverHubGameIcon(_ id: ApplicationID, side: CGFloat) -> URL? {
        if let hash = widgetApplications[id]?.iconHash { return CDN.applicationIcon(id: id, hash: hash, side: side) }
        if let game = games[canonicalGameID(for: id)], let url = gameArtURL(game, kind: .mark, side: side) { return url }
        return applicationIconURL(id, side: side)
    }

    /// The canonical game's box art, for a Popular Games tile.
    func serverHubGameCover(_ id: ApplicationID, side: CGFloat) -> URL? {
        games[canonicalGameID(for: id)].flatMap { gameArtURL($0, kind: .cover, side: side) }
    }

    // MARK: Popular Music

    private func popularMusicModel(_ music: GuildSpacePopularMusic, guildID: GuildID) -> PopularMusicCardModel {
        let songs = music.songs.prefix(10).enumerated().map { index, song in
            PopularMusicCardModel.Row(
                id: song.trackID,
                rank: index + 1,
                title: song.title,
                detail: song.artistName,
                imageURL: song.coverArtHash.flatMap(GuildSpacePopularMusic.imageURL),
                isPerson: false,
                monogram: "\u{266A}",
                plays: GuildSpaceFormat.count(song.plays, "play", "plays")
            )
        }
        let artists = music.artists.prefix(10).enumerated().map { index, artist in
            PopularMusicCardModel.Row(
                id: artist.artistID,
                rank: index + 1,
                title: artist.name,
                detail: nil,
                imageURL: artist.imageHash.flatMap(GuildSpacePopularMusic.imageURL),
                isPerson: false,
                monogram: String(artist.name.prefix(1)),
                plays: GuildSpaceFormat.count(artist.plays, "play", "plays")
            )
        }
        let listeners = music.listeners.prefix(10).enumerated().map { index, listener in
            let user = users[listener.userID]
            let lastHeard = [listener.lastTrackTitle, listener.lastArtistName].compactMap(\.self).joined(separator: " \u{00B7} ")
            return PopularMusicCardModel.Row(
                id: String(listener.userID.rawValue),
                rank: index + 1,
                title: voiceName(of: listener.userID, inGuild: guildID),
                detail: lastHeard.isEmpty ? nil : lastHeard,
                imageURL: user.flatMap { avatarURL(for: $0, side: 40) },
                isPerson: true,
                monogram: user?.monogram ?? "?",
                plays: GuildSpaceFormat.count(listener.plays, "play", "plays")
            )
        }
        var summary: String?
        if music.distinctSongs > 0, music.distinctListeners > 0 {
            summary = "\(GuildSpaceFormat.count(music.distinctSongs, "song", "songs")) played by \(GuildSpaceFormat.count(music.distinctListeners, "member", "members")) this week"
        }
        return PopularMusicCardModel(
            songs: Array(songs),
            artists: Array(artists),
            listeners: Array(listeners),
            backdropURL: songs.first?.imageURL,
            summary: summary
        )
    }

    // MARK: Image + Text and the whiteboard

    private func imageTextModel(_ widget: GuildSpaceWidget, guildID: GuildID) -> ImageTextCardModel {
        let config = widget.config
        var model = ImageTextCardModel(text: config.text)
        switch config.imageChange {
        case .replaced(let dataURL):
            model.imagePreview = Self.decodeDataURL(dataURL)
        case .removed:
            break
        case .unchanged:
            model.imageURL = serverHub.demoImageURLs[widget.id] ?? config.imageHash.flatMap {
                CDN.guildSpaceWidgetImage(guildID: guildID, widgetID: widget.id, hash: $0, width: ServerHubMetrics.pageWidth / 2)
            }
        }
        return model
    }

    private func whiteboardModel(channelID: ChannelID?, guildID: GuildID, isEditing: Bool) -> WhiteboardCardModel {
        let access: WhiteboardCardModel.Access = if let channelID {
            permissionGate.permissions(in: channelID).contains(.useEmbeddedActivities) ? .allowed : .denied
        } else {
            .unavailable
        }
        return WhiteboardCardModel(
            channelID: channelID,
            access: access,
            isRunning: channelID != nil && runningActivity?.instance.location.channelID == channelID,
            isLaunching: serverHub.launchingWhiteboard == guildID,
            isEditing: isEditing
        )
    }

    /// The bytes inside a `data:…;base64,` URL.
    static func decodeDataURL(_ dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }
}
