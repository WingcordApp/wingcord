import Foundation
import SwiftUI
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

    /// Narrows a search to servers that speak one language.
    ///
    /// **A refinement of the search, not a new question.** The facet stays — it
    /// describes the query rather than the filtered result, which is exactly why
    /// the captured request turns `with_counts` off — and the page starts again
    /// because a language is a different set of results under the same heading.
    func selectDiscoveryLanguage(_ code: String?) {
        guard discovery?.tab == .servers, discovery?.languageCode != code else { return }
        discovery?.languageCode = code
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
        guard let state = discovery, state.query != text else { return }
        discovery?.query = text
        discovery?.appPage = 1
        // **A new question drops the category, and both captures agree.** The
        // first request for a query text carries no `category_id` — the facet
        // it comes back with is what the reader then narrows *from*, and a
        // bucket held over from the last search would filter the new one by a
        // heading nobody chose. The page goes with it: results 12-24 of an
        // answer that no longer exists.
        if state.query.trimmingCharacters(in: .whitespaces)
            != text.trimmingCharacters(in: .whitespaces)
        {
            discovery?.categoryID = nil
            discovery?.page = .empty
        }
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
        case .games:
            // Games pages with its own pager.
            return
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
    func openDiscoveryApp(_ id: ApplicationID) {
        discovery?.openAppID = id
    }

    /// Back to the grid.
    func closeDiscoveryApp() {
        discovery?.openAppID = nil
    }

    /// Adds an app, from its page.
    ///
    /// **The page stays up and the sheet opens over it.** This used to close
    /// discovery and write the request, which only the composer's launcher
    /// presents — so from the rail the button did nothing at all. Adding is a
    /// task with an end and the reader is meant to come back to the page they
    /// were reading; §1's rule about a page staying up until the thing it
    /// raised has happened is the same rule.
    func addDiscoveredApp(_ id: ApplicationID) {
        let app = activityApp(id)
        applicationInstallRequest = ApplicationInstallRequest(
            applicationID: id,
            name: app?.name ?? "",
            iconHash: app?.iconHash,
            summary: app?.tagline ?? app?.about ?? ""
        )
    }

    /// The app's storefront, one page deeper inside discovery.
    func openDiscoveredAppStore(_ id: ApplicationID) {
        discovery?.openStoreID = id
    }

    func closeDiscoveredAppStore() {
        discovery?.openStoreID = nil
    }

    /// Looks at an app's support server without joining it.
    ///
    /// The same lurk a discovery card opens — `GuildPreview.Origin.discovery` —
    /// which is the one thing this client can honestly do with a server the
    /// reader is not in. Nothing else on this page leaves it.
    func previewSupportGuild(_ id: GuildID) {
        guard let loadID = discovery?.loadID else { return }
        if guilds[id] != nil {
            closeDiscovery()
            selectGuild(id)
            return
        }
        sessionController.previewGuild(
            id,
            origin: .discovery,
            location: Self.discoveryLocation,
            source: nil,
            recommendationLoadID: loadID
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
                mark: guild.mark,
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

    /// The buckets the Show menu offers, in Discord's own order.
    ///
    /// **A search has a facet; a browse has six headings, and they are not the
    /// same control.** The route answers a count per category for the *query* —
    /// 142 in all, 107 Gaming, 71 General Chatting, down to 19 Emoji in
    /// `Show filters.har` — which is forty-five buckets carrying numbers. A
    /// six-segment strip cannot hold that and a strip has nowhere to put a
    /// count, so while there is a query the strip stands down and this menu
    /// takes the category over.
    ///
    /// **Sorted by count, descending, which is the order the facet arrives in**
    /// — and it is the order Discord draws, so All is first because it is the
    /// largest rather than because it is special.
    ///
    /// A bucket whose id is not in the categories list is dropped: the names
    /// come from the route, and a number with no label is not a filter anybody
    /// can use.
    var discoveryFacetBuckets: [DiscoveryFacetBucket] {
        guard let state = discovery, let facet = state.facet else { return [] }
        let names = Dictionary(
            discoveryCategoryIndex.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return facet.counts
            .sorted { lhs, rhs in
                // Count first, id second — a stable order for the buckets that
                // tie, of which there are several in the capture.
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .compactMap { id, count in
                if id == DiscoveryPage.allCategoriesFacet {
                    // Not a category: the total across every one of them, and
                    // the row that clears the filter.
                    return DiscoveryFacetBucket(id: nil, name: "All", count: count)
                }
                guard let name = names[id] else { return nil }
                return DiscoveryFacetBucket(id: id, name: name, count: count)
            }
    }

    /// What the Show menu's own label says.
    var discoveryFacetLabel: String {
        guard let id = discovery?.categoryID else { return "All" }
        return discoveryCategoryIndex.first { $0.id == id }?.name ?? "All"
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
            discoveryCategoryIndex.map { ($0.id, $0) },
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
        guard !appDirectoryCategoryIndex.isEmpty else { return [] }
        return [.featured]
            + appDirectoryCategoryIndex.filter { $0.id != AppDirectoryCategory.featuredID }
    }

    /// The apps grid.
    ///
    /// **Every picture the card draws, resolved once per answer.** A directory
    /// result carries five different candidates and none of them is guaranteed,
    /// so the order below is the whole decision — and **the first two are
    /// Discord's own**, read off its banner component rather than inferred:
    ///
    /// ```js
    /// let cover = useAsset({applicationId, size: 600, names: ["embedded_cover"]})
    /// let {imageUrl} = cover.state === "fetched" && cover.url != null
    ///   ? {imageUrl: cover.url}
    ///   : {imageUrl: botBannerUrl, imageUrlAnimated: botBannerUrlAnimated}
    /// ```
    ///
    ///  1. **`embedded_cover`**, when the shelf has been loaded and knows this
    ///     app. The wide artwork an *activity* registers, and the one Discord
    ///     reaches for first.
    ///  2. **The bot's own profile banner.** Not an application asset at all —
    ///     `/banners/{id}/{hash}`, off the bot user the application ships.
    ///     **180 of the captured 265 have one**, against 75 with a
    ///     `cover_image`, which is why a client that skipped it drew a banner
    ///     for a quarter of the directory and an empty band for the rest.
    ///  3. **`cover_image`**, the other wide artwork an application registers.
    ///     Below the two Discord uses because Discord does not use it here.
    ///  4. **The preview loop's first frame** — `CDN.activityPreviewPoster`,
    ///     probed. Above the screenshots deliberately: it is the frame the loop
    ///     starts on, so the picture does not jump when the pointer arrives.
    ///  5. **The carousel's first still**, which is a screenshot rather than a
    ///     banner and is the last thing worth cropping to a wide box.
    ///
    /// Nil is a real answer: the card falls back to the bot's accent colour, and
    /// then to the gradient Discord derives from the icon — `AppIconGradient`.
    var discoveryAppCards: [DiscoveryAppCard] {
        guard let apps = discovery?.apps else { return [] }
        return apps.map { app in
            // The shelf knows `embedded_cover` for the seventy-odd apps it
            // carries and the directory's own answer does not, so the tile is
            // filled in from there where the two overlap.
            Self.directoryCard(for: app, shelfCover: activityDirectory.apps[app.id]?.tileAssetID)
        }
    }

    /// One app, as a card or as a row. **Static**, because the neighbours under
    /// an app's page are drawn from a list the page holds rather than from the
    /// grid — one projection, not two.
    static func directoryCard(
        for app: ActivityApp,
        shelfCover: String? = nil
    ) -> DiscoveryAppCard {
        let video = app.config?.previewVideoAssetID
        let banner = appBanner(
            for: app,
            shelfCover: shelfCover ?? app.tileAssetID,
            video: video,
            width: Metrics.discoveryCardWidth
        )
        return DiscoveryAppCard(
            id: app.id,
            name: app.name,
            subtitle: app.rowSubtitle
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            isVerified: app.isVerified,
            category: app.categoryNames.first,
            guildCount: app.guildCount,
            bannerURL: banner?.url,
            accentColor: app.botAccentColor.flatMap(UInt32.init(exactly:)).map { Color(hex: $0) },
            videoURL: video.flatMap { CDN.activityPreviewVideo(id: app.id, assetID: $0) },
            // **The banner's own film, and only in the one case Discord offers
            // it**: the still is the bot's profile banner, that banner is an
            // `a_` asset, and there is no preview loop to show instead.
            animatedBannerURL: video == nil ? banner?.animatedURL : nil,
            row: row(for: app),
            iconHash: app.iconHash
        )
    }

    /// The wide picture an app is drawn on, wherever one is drawn.
    ///
    /// **One order, two surfaces** — the grid's tile and the app's own page —
    /// because "what does this app look like" has one answer and two definitions
    /// of it is how a card and the page it opens show different pictures.
    ///
    /// It answers *which* artwork it found rather than only the address,
    /// because the two are authored at different shapes and the caller has to
    /// know: see `AppBanner.aspectRatio`.
    static func appBanner(
        for app: ActivityApp,
        shelfCover: String? = nil,
        video: String? = nil,
        width: CGFloat
    ) -> AppBanner? {
        if let cover = shelfCover ?? app.tileAssetID,
           let url = CDN.applicationAsset(id: app.id, assetID: cover, side: width)
        {
            return .embeddedCover(url)
        }
        if let hash = app.botBannerHash,
           let url = CDN.userBanner(
               userID: UserID(rawValue: app.id.rawValue), hash: hash, width: width
           )
        {
            return .profileBanner(url)
        }
        if let hash = app.coverHash,
           let url = CDN.applicationCover(id: app.id, hash: hash, width: width)
        {
            return .cover(url)
        }
        if let video = video ?? app.config?.previewVideoAssetID,
           let url = CDN.activityPreviewPoster(id: app.id, assetID: video, width: width)
        {
            return .previewPoster(url)
        }
        return app.heroImageURL.map { .screenshot($0) }
    }

    /// What the page says when it has nothing to show.
    ///
    /// Three different nothings, and they are not the same news — a browse that
    /// has not answered yet, a search that found none, and a route that refused.
    var discoveryEmptyLine: String? {
        guard let state = discovery, !state.isBusy else { return nil }
        // **The emptiness comes first, and the failure second.** This line
        // *replaces* the grid, so a refusal read before the grid was checked
        // replaced a page somebody was reading with an apology — a failed page
        // two, or a category route that answered while the front page was on
        // screen, took the whole surface down with it.
        let isEmpty = state.tab == .servers ? state.page.guilds.isEmpty : state.apps.isEmpty
        guard isEmpty else { return nil }
        if let failure = state.tab == .servers ? state.failure : state.appFailure {
            return failure
        }
        let query = state.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Nothing here yet." }
        // The search route's own floor, stated rather than left as a mystery:
        // it refuses to answer for servers under two hundred members.
        return state.tab == .servers
            ? "No servers match “\(query)”. Discovery only lists servers with more than 200 members."
            : "No apps match “\(query)”."
    }
}

/// Which of an app's five artworks a surface ended up with.
///
/// **The kind matters, not only the address.** A bot's profile banner is
/// authored at 5:2 and an activity's cover and preview at 16:9; filling a 16:9
/// box with a banner crops a third of it off the sides — `.fmbot`'s reads
/// ".fmbo" at 760 points. A caller that only had the URL had to guess from the
/// path, which is how the hero's ratio and the resolver's order drifted apart
/// the first time the order changed.
enum AppBanner: Hashable, Sendable {
    /// The wide artwork an activity registers. Discord reaches for this first.
    case embeddedCover(URL)
    /// The bot user's own profile banner, at `/banners/{id}/{hash}`.
    case profileBanner(URL)
    /// The application's `cover_image`, under `/app-icons/`.
    case cover(URL)
    /// The still the preview loop starts on.
    case previewPoster(URL)
    /// The developer's first screenshot, from the directory carousel.
    case screenshot(URL)

    var url: URL {
        switch self {
        case .embeddedCover(let url), .profileBanner(let url), .cover(let url),
             .previewPoster(let url), .screenshot(let url):
            url
        }
    }

    /// This artwork's animated rendition, where it has one.
    ///
    /// **Only a profile banner ever does**, which is the whole reason the kind
    /// travels with the address: `embedded_cover` and the rest are stills, and
    /// an `a_` hash resolves to the `.gif` this returns — the same URL, drawn
    /// as a first frame by `RemoteImage` and as film by `AnimatedDecoration`.
    var animatedURL: URL? {
        guard case .profileBanner(let url) = self, CDN.canAnimate(url) else { return nil }
        return url
    }

    /// The shape the artwork was authored at.
    var aspectRatio: CGFloat {
        switch self {
        case .profileBanner: 5 / 2
        case .embeddedCover, .cover, .previewPoster, .screenshot: 16 / 9
        }
    }
}
