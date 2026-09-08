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
        closeDiscovery()
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

    /// Adding an app the directory offered.
    ///
    /// **The Add App sheet, not the launcher's detail page.** The detail page
    /// lives inside the composer's flyout and is scoped to a channel; the
    /// directory is reached from the rail with no channel in the picture, and
    /// opening a composer surface from it would be a page about somewhere the
    /// reader is not. What the directory is *for* is adding the app to a server,
    /// which is exactly what this sheet does — and it is already built.
    func openDiscoveryApp(_ app: ActivityApp) {
        closeDiscovery()
        applicationInstallRequest = ApplicationInstallRequest(
            applicationID: app.id,
            name: app.name,
            iconHash: app.iconHash,
            summary: app.tagline ?? app.about
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

    /// The headings a reader can browse by.
    ///
    /// **The seventeen primary ones only.** The other thirty-two are refinements
    /// a server picks *in addition* — Theorycraft, LFG, Cryptocurrency — and a
    /// picker offering all forty-nine is a picker nobody reads to the end of.
    /// They are still decoded, because a search facet answers with them and a
    /// bucket nobody can name is a number with no label.
    var discoveryCategories: [DiscoveryCategory] {
        (discovery?.categories ?? [])
            .filter(\.isPrimary)
            .sorted { $0.id < $1.id }
    }

    var appDirectoryCategories: [AppDirectoryCategory] {
        (discovery?.appCategories ?? []).sorted { $0.id < $1.id }
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
