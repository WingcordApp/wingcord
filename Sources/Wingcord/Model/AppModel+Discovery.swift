import Foundation
import WingcordCore

// MARK: - Discovery
//
// Finding a server, or an app, that the account is not in yet.
//
// **Everything below the grid already existed.** A card opens a *preview* — the
// lurk this client has had since the game-profile session — and the join, the
// onboarding gate and the rules agreement are the same three surfaces a game's
// community card already leads to. `GuildPreview.Origin.discovery` was written
// then and left unused; this is the caller it was waiting for.

extension AppModel {

    var isDiscoveryShown: Bool { discovery != nil }

    /// Opens discovery, or closes it if it is already the page.
    ///
    /// **Kept rather than rebuilt when it is reopened**, so stepping away to a
    /// channel and coming back does not throw away a grid somebody was reading
    /// — the same rule the search panel keeps.
    func toggleDiscovery() {
        if discovery != nil {
            closeDiscovery()
            return
        }
        discovery = discoverySeed ?? DiscoveryState()
        sessionController.loadDiscovery()
    }

    func closeDiscovery() {
        discovery = nil
        sessionController.cancelDiscovery()
    }

    /// Which half is showing.
    func selectDiscoveryTab(_ tab: DiscoveryState.Tab) {
        guard discovery?.tab != tab else { return }
        discovery?.tab = tab
        sessionController.loadDiscovery()
    }

    /// Browses one heading, or the front page for nil.
    func selectDiscoveryCategory(_ categoryID: Int?) {
        guard discovery?.tab == .servers, discovery?.categoryID != categoryID else { return }
        discovery?.categoryID = categoryID
        // A new question is a new page, and a page number carried across is how
        // a category opens onto results 60–90 of a list that has twelve.
        discovery?.page = .empty
        sessionController.loadDiscovery()
    }

    func selectAppCategory(_ categoryID: Int?) {
        guard discovery?.tab == .apps, discovery?.appCategoryID != categoryID else { return }
        // Nil is not a heading here: it is the launcher's own narrowed search.
        let categoryID = categoryID ?? AppDirectoryCategory.featuredID
        discovery?.appCategoryID = categoryID
        discovery?.appPage = 1
        discovery?.apps = []
        sessionController.loadDiscovery()
    }

    /// What the field publishes.
    ///
    /// The request is raised here rather than from the view — a body that starts
    /// a fetch starts one per evaluation — and it is debounced inside the
    /// controller, because both routes behind it are real round trips.
    func setDiscoveryQuery(_ text: String) {
        guard discovery != nil, discovery?.query != text else { return }
        discovery?.query = text
        discovery?.appPage = 1
        sessionController.loadDiscovery(debounced: true)
    }

    /// The next page of whichever half is showing.
    ///
    /// **Appended, never replaced.** A grid that swapped its contents on scroll
    /// would move what somebody was reading; the whole point of a page two is
    /// that page one is still above it.
    func loadMoreDiscovery() {
        guard let state = discovery, !state.isBusy else { return }
        switch state.tab {
        case .servers:
            guard state.page.guilds.count < state.page.total else { return }
            sessionController.loadMoreDiscoveryGuilds()
        case .apps:
            guard state.appPage < state.appPageCount else { return }
            sessionController.loadMoreDirectoryApps()
        }
    }

    // MARK: Acting on a card

    /// Looks at a server without joining it.
    ///
    /// **A preview, not a join**, which is the whole gesture discovery exists
    /// for: read the channels, then decide. A server that cannot be previewed
    /// joins outright — that is what `canPreview` decides, and a card that
    /// offered a preview the route then refused would be the inert control §5.5
    /// forbids.
    func openDiscoveryCard(_ card: DiscoveryCard) {
        guard let loadID = discovery?.loadID else { return }
        // Already a member: this is navigation, not an invitation.
        if card.isJoined {
            closeDiscovery()
            selectGuild(card.id)
            return
        }
        // **Not closed here.** The lurk can be refused — at the hundred-server
        // cap it always is — and a page that closed on the click would leave the
        // reader somewhere they did not ask to be, reading a notice about a
        // server that is no longer on screen. `previewGuild` closes it once the
        // preview has actually started.
        sessionController.previewGuild(
            card.id,
            origin: .discovery,
            location: Self.discoveryLocation,
            // Captured as an empty object rather than a source — see
            // `DiscordREST.contextProperties`.
            source: nil,
            recommendationLoadID: loadID
        )
    }

    /// Discord's own analytics label for a click on a discovery card. Captured
    /// verbatim, capital G and capital D.
    static let discoveryLocation = "Guild Discovery"

    /// Opens an app's own page, one level inside discovery.
    ///
    /// **A page here, not the Add App sheet.** It went to the sheet first, which
    /// was wrong in the way §5.5 is usually wrong in reverse: it skipped the
    /// thing the reader was asking for. A directory card is a question — what
    /// *is* this app — and the answer is the page that carries its screenshots,
    /// its commands and what data it can read. Adding it is one button on that
    /// page.
    ///
    /// The page is `ActivityDetailPage`, the same one the composer's flyout
    /// shows, with **no channel**: there is none in the picture here, and the
    /// controls that need one draw only where there is one. That is what the
    /// reference client does too — its own directory page has no Launch.
    func openDiscoveryApp(_ app: ActivityApp) {
        discovery?.openAppID = app.id
    }

    /// Back to the grid.
    func closeDiscoveryApp() {
        discovery?.openAppID = nil
    }

    /// Adds an app to a server, from its page.
    func addDiscoveredApp(_ id: ApplicationID) {
        let app = activityApp(id)
        closeDiscovery()
        applicationInstallRequest = ApplicationInstallRequest(
            applicationID: id,
            name: app?.name ?? "",
            iconHash: app?.iconHash,
            summary: app?.tagline ?? app?.about ?? ""
        )
    }

    // MARK: What the page draws

    /// The servers grid.
    ///
    /// Built per answer rather than memoized: the page is replaced by a request
    /// rather than by a store write, so there is no counter this could key on
    /// that moves less often than the value itself.
    var discoveryCards: [DiscoveryCard] {
        guard let state = discovery else { return [] }
        return state.page.guilds.map { guild in
            DiscoveryCard(
                id: guild.id,
                name: guild.name,
                description: guild.description,
                artworkURL: Self.artworkURL(for: guild),
                iconURL: guild.iconHash.flatMap {
                    CDN.guildIcon(guildID: guild.id, hash: $0, side: Metrics.discoveryCardIcon)
                },
                monogram: guild.monogram,
                standing: guild.standing,
                memberCount: guild.memberCount,
                onlineCount: guild.onlineCount,
                canPreview: guild.canPreview,
                isJoined: guilds[guild.id] != nil
            )
        }
    }

    /// The wide picture across a card's head.
    ///
    /// **Three hashes, in the order a card wants them.** The discovery splash is
    /// the one authored for this surface; a server that has none very often has
    /// an invite splash, and a banner is the last resort because it is authored
    /// to sit *behind a channel list* rather than to be looked at whole. Nil is
    /// a real answer and the card draws its own ground.
    private static func artworkURL(for guild: DiscoverableGuild) -> URL? {
        if let hash = guild.discoverySplashHash {
            return CDN.guildDiscoverySplash(
                guildID: guild.id, hash: hash, width: Metrics.discoveryCardWidth
            )
        }
        if let hash = guild.splashHash {
            return CDN.guildSplash(
                guildID: guild.id, hash: hash, width: Metrics.discoveryCardWidth
            )
        }
        return guild.bannerHash.flatMap {
            CDN.guildBanner(guildID: guild.id, hash: $0, width: Metrics.discoveryCardWidth)
        }
    }

    /// The headings the picker offers, in the reference client's own order.
    ///
    /// **Six, not forty-nine and not seventeen.** The route answers forty-nine
    /// headings of which seventeen are primary; Discord's own tab strip shows
    /// *five* of them plus Home. That is a curation rather than a limitation,
    /// and copying it is what makes a segmented control the right instrument —
    /// see `Self.featuredCategoryIDs`.
    ///
    /// The rest stay decoded and are not wasted: a search facet answers in
    /// category ids, and a bucket nobody can name is a number with no label.
    /// Reaching one of them is a search rather than a tab, which is the trade —
    /// and widening it is one line.
    var discoveryCategories: [DiscoveryCategory] {
        let byID = Dictionary(
            (discovery?.categories ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.featuredCategoryIDs.compactMap { byID[$0] }
    }

    /// Gaming, Music, Entertainment, Science & Tech, Education.
    ///
    /// **Ids rather than names, and the names still come from the route** — so a
    /// reader in another language gets their own. The ids are stable: the same
    /// five have been these headings for years, and the capture confirms every
    /// one of them.
    static let featuredCategoryIDs = [1, 2, 3, 5, 6]

    /// The app headings, Featured first.
    ///
    /// **Featured is prepended rather than fetched**, because the route does not
    /// send it — see `AppDirectoryCategory.featured`. The rest keep the order
    /// the route answers in, which is Discord's own.
    var appDirectoryCategories: [AppDirectoryCategory] {
        guard let fetched = discovery?.appCategories, !fetched.isEmpty else { return [] }
        return [.featured] + fetched.filter { $0.id != AppDirectoryCategory.featuredID }
    }

    /// What the page says when it has nothing to show.
    ///
    /// Three different nothings, and they are not the same news — a browse that
    /// has not answered yet, a search that found none, and a route that refused.
    var discoveryEmptyLine: String? {
        guard let state = discovery, !state.isBusy else { return nil }
        let failure = state.tab == .servers ? state.failure : state.appFailure
        if let failure { return failure }
        let isEmpty = state.tab == .servers ? state.page.guilds.isEmpty : state.apps.isEmpty
        guard isEmpty else { return nil }
        let query = state.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Nothing here yet." }
        // The search route's own floor, stated rather than left as a mystery:
        // it refuses to answer for servers under two hundred members.
        return state.tab == .servers
            ? "No servers match “\(query)”. Discovery only lists servers with more than 200 members."
            : "No apps match “\(query)”."
    }
}
