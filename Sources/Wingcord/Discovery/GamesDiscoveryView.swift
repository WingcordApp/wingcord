import SwiftUI
import WingcordCore
import WingcordNet

/// Discover › Games (`2026-10-game-discovery`, docs/QUEUE-NOV19.md §1):
/// Featured's shelves, Trending's table, or — while something is typed in the
/// toolbar's field — Discord's game search with its filters.
struct GamesDiscoveryView: View {
    var query: String

    @Environment(AppModel.self) private var model

    /// **One scroll view for every state.** Typing swapped Featured's scroll
    /// view for search's, which rebuilt the floating bar over it — and the
    /// search field in it came back focused with its first letter selected, so
    /// the next key replaced it ("grand" → "rand", Alex, 2026-11-19).
    var body: some View {
        ScrollView {
            Group {
                if !trimmedQuery.isEmpty {
                    GameSearchResultsView(query: trimmedQuery)
                } else if model.gamesDiscovery.section == .trending {
                    GamesTrendingView()
                } else {
                    GamesFeaturedView()
                }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.top, Spacing.margin)
            .padding(.bottom, Spacing.section)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .softScrollEdgesVertical()
        .task { model.sessionController.loadGamesDiscovery() }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Featured

private struct GamesFeaturedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 40) {
                let trending = model.trendingShelf
                if !trending.isEmpty {
                    GameShelfSection(title: "Trending games") {
                        ForEach(trending) { GameShelfCard(item: $0, width: 156) }
                    }
                } else if model.gamesDiscovery.trending == nil, !model.gamesDiscovery.trendingFailed {
                    GameShelfPlaceholder(title: "Trending games")
                }

                let recent = model.jumpBackIn
                if !recent.isEmpty {
                    GameShelfSection(title: "Jump back in") {
                        ForEach(recent) { JumpBackInCard(item: $0) }
                    }
                }

                if let similar = model.similarShelf {
                    GameShelfSection(title: "Because you played \(similar.seed.name)") {
                        ForEach(similar.items) { GameShelfCard(item: $0, width: 136) }
                    }
                }

                let playing = model.playWithFriendsShelf
                if !playing.isEmpty {
                    GameShelfSection(title: "Play with your friends") {
                        ForEach(playing) { GameShelfCard(item: $0, width: 136) }
                    }
                }

                let into = model.friendsAreIntoShelf
                if !into.isEmpty {
                    GameShelfSection(title: "Games your friends are into") {
                        ForEach(into) { GameShelfCard(item: $0, width: 136) }
                    }
                }
        }
    }
}

/// A titled shelf that scrolls sideways.
private struct GameShelfSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Text(title)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Spacing.margin) {
                    content
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
        }
    }
}

private struct GameShelfPlaceholder: View {
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Text(title)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(Ink.primary)
            HStack(spacing: Spacing.margin) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 156, height: 156 / GameArt.coverAspect)
                }
            }
            .redacted(reason: .placeholder)
        }
        .accessibilityLabel(Text("Loading \(title)"))
    }
}

/// A cover in a shelf: Trending's rank and genres on the art, friends' faces
/// under the name on the friends' shelves. Opens the game's profile.
private struct GameShelfCard: View {
    var item: GameShelfItem
    var width: CGFloat

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button { model.openGameProfile(item.game.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                GameCover(
                    game: BoardGame(
                        gameID: item.game.id,
                        name: item.game.name,
                        coverURL: model.gameArtURL(item.game, kind: .cover, side: width * 2),
                        isCoverArt: model.gameArtIsCover(item.game, kind: .cover),
                        tags: []
                    ),
                    width: width,
                    corner: 16
                )
                .overlay(alignment: .bottomLeading) { overlays }
                .scaleEffect(isHovered && !motion.reduceMotion ? 1.03 : 1)
                .shadow(color: .black.opacity(isHovered ? 0.35 : 0.18), radius: isHovered ? 14 : 6, y: isHovered ? 8 : 3)
                Text(item.game.name)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if !item.friends.isEmpty { FriendFaces(userIDs: item.friends) }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    @ViewBuilder
    private var overlays: some View {
        if item.rank != nil || item.genres != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let rank = item.rank {
                    Text("\(rank)")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
                }
                if let genres = item.genres {
                    Text(genres)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.7), radius: 3)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
            }
            .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let rank = item.rank { parts.append("Number \(rank)") }
        parts.append(item.game.name)
        if !item.friends.isEmpty { parts.append("\(item.friends.count) \(item.friends.count == 1 ? "friend" : "friends")") }
        parts.append("view game profile")
        return parts.joined(separator: ", ")
    }
}

/// Up to four friends' faces, overlapping, and how many more.
private struct FriendFaces: View {
    var userIDs: [UserID]

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: -6) {
            ForEach(userIDs.prefix(4), id: \.self) { userID in
                let user = model.users[userID]
                AvatarView(
                    url: user.flatMap { model.avatarURL(for: $0, side: 20) },
                    monogram: String((user?.displayName ?? user?.username ?? "?").prefix(1)),
                    side: 20
                )
                .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1.5))
            }
            if userIDs.count > 4 {
                Text("+\(userIDs.count - 4)")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .padding(.leading, 10)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Jump back in's card (Discord's `l_`): the cover, the name, when it was last
/// played, and the game's latest update or how many friends played it.
private struct JumpBackInCard: View {
    var item: JumpBackInItem

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button { model.openGameProfile(item.game.id) } label: {
            HStack(alignment: .center, spacing: Spacing.margin) {
                GameCover(
                    game: BoardGame(
                        gameID: item.game.id,
                        name: item.game.name,
                        coverURL: model.gameArtURL(item.game, kind: .cover, side: 220),
                        isCoverArt: model.gameArtIsCover(item.game, kind: .cover),
                        tags: []
                    ),
                    width: 104,
                    corner: 12
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.game.name)
                        .font(.system(.headline))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                    Text(playedLine)
                        .font(.system(.subheadline))
                        .foregroundStyle(item.isPlayingNow ? Color.green : Ink.secondary)
                    if item.friendsThisWeek > 0 {
                        Label(
                            "\(item.friendsThisWeek) \(item.friendsThisWeek == 1 ? "friend" : "friends") played this week",
                            systemImage: "person.2.fill"
                        )
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                    }
                    if let announcement = item.announcement {
                        HStack(spacing: 8) {
                            if let url = announcement.media?.url {
                                RemoteImage(url: url, side: 36) { Color.white.opacity(0.08) }
                                    .frame(width: 36, height: 36)
                                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
                            }
                            // Discord's markdown, not its raw tokens: a role
                            // from a server you're not in reads "@unknown-role",
                            // and a custom emoji is drawn.
                            ProseText(
                                markdown: announcementText(announcement),
                                font: .system(.caption),
                                color: InkColor.secondary,
                                emojiSide: 14,
                                mentions: model.mentionContext(inGuild: nil),
                                isSelectable: false
                            )
                            .lineLimit(2)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.margin)
            .frame(width: 400, height: 172, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.09 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.edge, lineWidth: 1)
            )
            .contentShape(.rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .accessibilityLabel(Text("\(item.game.name), \(playedLine), view game profile"))
    }

    /// The title, or the body where there is none (Discord's `l_`).
    private func announcementText(_ announcement: GameAnnouncementCard) -> String {
        if let title = announcement.title, !title.isEmpty { return title }
        return announcement.body.isEmpty ? "Latest update" : announcement.body
    }

    private var playedLine: String {
        if item.isPlayingNow { return "Playing now" }
        guard let last = item.lastPlayedAt else { return "Played recently" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last played \(formatter.localizedString(for: last, relativeTo: Date()))"
    }
}

// MARK: - Trending

private struct GamesTrendingView: View {
    @Environment(AppModel.self) private var model

    private enum Column {
        static let rank: CGFloat = 36
        static let change: CGFloat = 90
        static let category: CGFloat = 170
    }

    var body: some View {
            VStack(alignment: .leading, spacing: Spacing.margin) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
                    Text("Top trending games")
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(Ink.primary)
                        .accessibilityAddTraits(.isHeader)
                    if let week = model.trendingWeekLine {
                        Text(week)
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.secondary)
                    }
                }
                table
            }
    }

    private var table: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            let rows = model.trendingRows
            if rows.isEmpty {
                Text(model.gamesDiscovery.trendingFailed
                    ? "Unable to load trending games."
                    : (model.gamesDiscovery.trending == nil ? "Loading trending games\u{2026}" : "No trending games available right now."))
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.entry.id) { index, row in
                    TrendingRow(entry: row.entry, game: row.game, isNew: row.isNew)
                    if index < rows.count - 1 { Divider().opacity(0.25).padding(.leading, Spacing.margin) }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.edge, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: Spacing.margin) {
            Text("#").frame(width: Column.rank, alignment: .leading)
                .accessibilityLabel(Text("Rank"))
            Text("Game").frame(maxWidth: .infinity, alignment: .leading)
            Text("Plays").frame(width: Column.change, alignment: .leading)
            Text("Category").frame(width: Column.category, alignment: .leading)
            Text("Official server").frame(width: 260, alignment: .leading)
        }
        .font(.system(.caption, weight: .medium))
        .foregroundStyle(Ink.tertiary)
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, 10)
    }

    private struct TrendingRow: View {
        var entry: TrendingGames.Entry
        var game: Game
        var isNew: Bool

        @Environment(AppModel.self) private var model

        var body: some View {
            HStack(spacing: Spacing.margin) {
                Text("\(entry.rank)")
                    .font(.system(.callout, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Ink.secondary)
                    .frame(width: Column.rank, alignment: .leading)
                Button { model.openGameProfile(game.id) } label: {
                    HStack(spacing: 12) {
                        GameCover(
                            game: BoardGame(
                                gameID: game.id,
                                name: game.name,
                                coverURL: model.gameArtURL(game, kind: .cover, side: 96),
                                isCoverArt: model.gameArtIsCover(game, kind: .cover),
                                tags: []
                            ),
                            width: 38,
                            corner: 6
                        )
                        Text(game.name)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("\(game.name), view game profile"))
                changeText.frame(width: Column.change, alignment: .leading)
                Text(categories)
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .frame(width: Column.category, alignment: .leading)
                OfficialServerCell(guild: entry.officialGuild)
                    .frame(width: 260, alignment: .leading)
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.vertical, 12)
        }

        /// Discord's column: the week's change in players, green up and red
        /// down, or "New" for a game released that week.
        private var changeText: some View {
            let change = entry.playersChange
            let text: String = isNew ? "New" : change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)))
            let color: Color = isNew || change == 0 ? Palette.accent : (change > 0 ? .green : .red)
            return Text(text)
                .font(.system(.callout, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }

        private var categories: String {
            let names = entry.categories.prefix(2).compactMap(AppModel.gameCategoryName)
            return names.isEmpty ? "\u{2013}" : names.joined(separator: ", ")
        }
    }

    /// The game's official server: its icon, name and badge, who's online,
    /// and Join — or Go to server for one the reader is in.
    private struct OfficialServerCell: View {
        var guild: TrendingGames.OfficialGuild?

        @Environment(AppModel.self) private var model

        var body: some View {
            if let guild {
                HStack(spacing: 10) {
                    RemoteImage(url: guild.iconURL, side: 32) { Color.white.opacity(0.08) }
                        .frame(width: 32, height: 32)
                        .clipShape(.rect(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(guild.name)
                                .font(.system(.callout, weight: .semibold))
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                            if guild.isVerified || guild.isPartnered {
                                Image(systemName: guild.isVerified ? "checkmark.seal.fill" : "star.circle.fill")
                                    .font(.system(.caption))
                                    .foregroundStyle(guild.isVerified ? Color.green : Palette.accent)
                                    .accessibilityLabel(Text(guild.isVerified ? "Verified" : "Partnered"))
                            }
                        }
                        if let online = guild.onlineCount {
                            Text("\(online.formatted(.number.notation(.compactName))) Online")
                                .font(.system(.caption))
                                .foregroundStyle(Ink.tertiary)
                        }
                    }
                    Spacer(minLength: 6)
                    if model.guilds[guild.id] != nil {
                        Button("Go to server") {
                            model.closeDiscovery()
                            model.selectGuild(guild.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else if let code = guild.inviteURL?.lastPathComponent, !code.isEmpty {
                        Button("Join") { model.openInvite(key: code) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            } else {
                Text("\u{2013}")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }
}

// MARK: - Search

private struct GameSearchResultsView: View {
    var query: String

    @Environment(AppModel.self) private var model

    private var search: GamesDiscoveryState.Search { model.gamesDiscovery.search }

    @State private var isFilterPanelShown = false

    var body: some View {
            VStack(alignment: .leading, spacing: Spacing.margin) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Search results for \u{201C}\(query)\u{201D}")
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Spacer()
                    filters
                }
                if !activeFilters.isEmpty { activeFilterRow }
                results
                if search.total > DiscordREST.gameSearchPageSize { pager }
            }
        .task(id: query) {
            // A pause while typing, then the search — and back to page one.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.gamesDiscovery.search.query = query
            model.gamesDiscovery.search.page = 1
            model.sessionController.searchGamesDiscovery()
        }
    }

    @ViewBuilder
    private var results: some View {
        let games = search.results.compactMap { model.games[$0] }
        if games.isEmpty {
            Text(search.isLoading ? "Searching\u{2026}"
                : search.failed ? "We dropped the magnifying glass. Can you try searching again?"
                : "No games match your search")
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.margin, alignment: .top)],
                alignment: .leading,
                spacing: Spacing.section
            ) {
                ForEach(games, id: \.id) { game in
                    GameShelfCard(item: GameShelfItem(game: game), width: 140)
                }
            }
            .opacity(search.isLoading ? 0.6 : 1)
        }
    }

    /// Discord's two filters — platforms, then genres — each with the count
    /// the search would leave, as chips on a panel under the button (the
    /// popover Discord opens on a narrow page).
    private var filters: some View {
        Button {
            isFilterPanelShown.toggle()
        } label: {
            Label(filterTitle, systemImage: "line.3.horizontal.decrease")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(platformOptions.isEmpty && genreOptions.isEmpty)
        .popover(isPresented: $isFilterPanelShown, arrowEdge: .bottom) {
            GameFilterPanel(
                platforms: platformOptions.map { ($0, count(platform: $0)) },
                genres: genreOptions.map { ($0, count(genre: $0)) },
                selectedPlatforms: search.platforms,
                selectedGenres: search.genres,
                togglePlatform: { toggle(platform: $0) },
                toggleGenre: { toggle(genre: $0) },
                clear: clearFilters
            )
        }
    }

    private var filterTitle: String {
        let active = search.genres.count + search.platforms.count
        return active == 0 ? "Filters" : "Filters (\(active))"
    }

    /// What is narrowing the results, each a chip that takes itself off.
    private var activeFilters: [(id: String, title: String, remove: () -> Void)] {
        let platforms = search.platforms.sorted(by: Self.platformOrder).map { value in
            (id: "p-\(value)", title: AppModel.gamePlatformName(value), remove: { toggle(platform: value) })
        }
        let genres = search.genres.sorted { Self.genreName($0) < Self.genreName($1) }.map { value in
            (id: "g-\(value)", title: Self.genreName(value), remove: { toggle(genre: value) })
        }
        return platforms + genres
    }

    private var activeFilterRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(activeFilters, id: \.id) { filter in
                Button(action: filter.remove) {
                    HStack(spacing: 4) {
                        Text(filter.title)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(.caption, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Palette.accent.opacity(0.22)))
                    .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.6), lineWidth: 1))
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove filter \(filter.title)"))
            }
            Button("Clear all", action: clearFilters)
                .buttonStyle(.plain)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .padding(.vertical, 5)
        }
    }

    private var platformOptions: [String] {
        Set(search.platformCounts.map(\.value)).union(search.platforms).sorted(by: Self.platformOrder)
    }

    /// Genres the search can narrow to, the busiest first.
    private var genreOptions: [Int] {
        Set(search.genreCounts.map(\.value)).union(search.genres).sorted {
            let (a, b) = (count(genre: $0), count(genre: $1))
            return a == b ? Self.genreName($0) < Self.genreName($1) : a > b
        }
    }

    private static func platformOrder(_ a: String, _ b: String) -> Bool {
        (AppModel.gamePlatformOrder.firstIndex(of: a) ?? 99) < (AppModel.gamePlatformOrder.firstIndex(of: b) ?? 99)
    }

    /// A search facet's genre is a game genre (Discord's `541830.du`), not one
    /// of trending's eighteen categories.
    static func genreName(_ id: Int) -> String {
        GameGenre(rawValue: id).title
    }

    private func count(platform: String) -> Int {
        search.platformCounts.first { $0.value == platform }?.count ?? 0
    }

    private func count(genre: Int) -> Int {
        search.genreCounts.first { $0.value == genre }?.count ?? 0
    }

    private func toggle(platform: String) {
        if model.gamesDiscovery.search.platforms.contains(platform) {
            model.gamesDiscovery.search.platforms.remove(platform)
        } else {
            model.gamesDiscovery.search.platforms.insert(platform)
        }
        model.gamesDiscovery.search.page = 1
        model.sessionController.searchGamesDiscovery()
    }

    private func toggle(genre: Int) {
        if model.gamesDiscovery.search.genres.contains(genre) {
            model.gamesDiscovery.search.genres.remove(genre)
        } else {
            model.gamesDiscovery.search.genres.insert(genre)
        }
        model.gamesDiscovery.search.page = 1
        model.sessionController.searchGamesDiscovery()
    }

    private func clearFilters() {
        model.gamesDiscovery.search.platforms = []
        model.gamesDiscovery.search.genres = []
        model.gamesDiscovery.search.page = 1
        model.sessionController.searchGamesDiscovery()
    }

    private var pager: some View {
        HStack(spacing: Spacing.margin) {
            Button {
                model.gamesDiscovery.search.page -= 1
                model.sessionController.searchGamesDiscovery()
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(search.page <= 1 || search.isLoading)
            Text("Page \(search.page) of \(search.pageCount)")
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
            Button {
                model.gamesDiscovery.search.page += 1
                model.sessionController.searchGamesDiscovery()
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(search.page >= search.pageCount || search.isLoading)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }
}


/// The Filters panel: platforms, then genres, as chips with the count each
/// would leave. A chip is a toggle; Clear takes them all off.
private struct GameFilterPanel: View {
    var platforms: [(value: String, count: Int)]
    var genres: [(value: Int, count: Int)]
    var selectedPlatforms: Set<String>
    var selectedGenres: Set<Int>
    var togglePlatform: (String) -> Void
    var toggleGenre: (Int) -> Void
    var clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Filters")
                    .font(.system(.headline))
                Spacer()
                if !selectedPlatforms.isEmpty || !selectedGenres.isEmpty {
                    Button("Clear", action: clear)
                        .buttonStyle(.plain)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !platforms.isEmpty {
                        section("Platforms") {
                            ForEach(platforms, id: \.value) { platform in
                                FilterChip(
                                    title: AppModel.gamePlatformName(platform.value),
                                    symbol: Self.symbol(for: platform.value),
                                    count: platform.count,
                                    isOn: selectedPlatforms.contains(platform.value)
                                ) { togglePlatform(platform.value) }
                            }
                        }
                    }
                    if !genres.isEmpty {
                        section("Genres") {
                            ForEach(genres, id: \.value) { genre in
                                FilterChip(
                                    title: GameGenre(rawValue: genre.value).title,
                                    symbol: nil,
                                    count: genre.count,
                                    isOn: selectedGenres.contains(genre.value)
                                ) { toggleGenre(genre.value) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 400)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ chips: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) { chips() }
        }
    }

    private static func symbol(for platform: String) -> String? {
        switch platform {
        case "desktop": "desktopcomputer"
        case "mobile": "iphone"
        case "console": "gamecontroller"
        case "roblox": "cube"
        default: nil
        }
    }
}

/// One filter: its name, how many it would leave, and whether it is on.
private struct FilterChip: View {
    var title: String
    var symbol: String?
    var count: Int
    var isOn: Bool
    var toggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(.callout, weight: isOn ? .semibold : .regular))
                Text(count.formatted(.number.notation(.compactName)))
                    .font(.system(.caption, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(isOn ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(
                Capsule().fill(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.12 : 0.07)))
            )
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(Text("\(title), \(count) games"))
    }
}

