import Foundation
import Testing
import WingcordCore
import WingcordNet
@testable import Wingcord

/// Discovery, driven through the real store.
///
/// What is worth pinning is the half a wire test cannot see: which column
/// discovery takes, what a card says about a server the account is already in,
/// and the two envelopes the two routes answer with — which is the one thing
/// here that produces a plausible wrong answer rather than a failure.
@Suite("Discovery")
@MainActor
struct DiscoveryTests {

    private let joinedID = GuildID(rawValue: 1000)
    private let strangerID = GuildID(rawValue: 2000)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 1)
        model.guilds = [
            joinedID: Guild(id: joinedID, name: "Lumen Club", ownerID: UserID(rawValue: 1)),
        ]
        return model
    }

    private func guild(_ id: GuildID, features: Set<String> = ["DISCOVERABLE"]) -> DiscoverableGuild {
        DiscoverableGuild(
            id: id,
            name: "Server \(id.rawValue)",
            description: "A server.",
            features: features,
            memberCount: 4_453_182,
            onlineCount: 880_686
        )
    }

    // MARK: The column

    /// §1: anything added to the detail column arrives as a case on the enum.
    @Test("Discovery is a case on the detail column, not a window")
    func discoveryTakesTheColumn() {
        let model = model()
        model.toggleDiscovery()
        #expect(model.isDiscoveryShown)
        #expect(model.workspacePresentation.primary == .discovery)
        #expect(model.workspacePresentation.supplementary == nil)
    }

    /// It is not about the selected server, so nothing that answers *for* the
    /// selected server can be the right answer while it is open.
    @Test("Discovery outranks a server page and the join gate")
    func discoveryOutranksEverything() {
        let model = model()
        model.selectedGuildID = joinedID
        model.openGuildSurface = .serverGuide
        #expect(model.workspacePresentation.primary == .guildSurface(joinedID, .serverGuide))

        model.toggleDiscovery()
        #expect(model.workspacePresentation.primary == .discovery)
    }

    /// A takeover has no channel list to sit beside, and both takeovers narrow
    /// the sidebar the same way — one flag rather than two to keep in step.
    @Test("A takeover narrows the sidebar and draws no chrome")
    func takeoverNarrowsTheSidebar() {
        let model = model()
        #expect(!model.isColumnTakenOver)

        model.toggleDiscovery()
        #expect(model.isColumnTakenOver)
        #expect(model.channelChrome.name.isEmpty)
    }

    @Test("The compass toggles, and reopening keeps the grid")
    func togglingKeepsTheGrid() {
        let model = model()
        model.toggleDiscovery()
        model.discovery?.page = DiscoveryPage(guilds: [guild(strangerID)], total: 1)
        model.setDiscoveryQuery("marvel")

        model.toggleDiscovery()
        #expect(!model.isDiscoveryShown)
        model.toggleDiscovery()
        // A fresh state, because nothing caches a grid — but the seed is what
        // `--demo` puts there, and it must not leak into a real session.
        #expect(model.discovery?.query.isEmpty == true)
    }

    // MARK: Cards

    @Test("A card carries the server's counts and its rosette")
    func cardCarriesTheFacts() throws {
        let model = model()
        model.toggleDiscovery()
        model.discovery?.page = DiscoveryPage(
            guilds: [guild(strangerID, features: ["DISCOVERABLE", "VERIFIED"])],
            total: 1
        )
        let card = try #require(model.discoveryCards.first)
        #expect(card.memberCount == 4_453_182)
        #expect(card.onlineCount == 880_686)
        #expect(card.mark?.kind == .verified)
        #expect(!card.isJoined)
    }

    /// A card for a server the reader is standing in is navigation, not an
    /// invitation — and it must say so rather than offering to join it again.
    @Test("A server the account is already in is marked joined")
    func joinedServersAreMarked() throws {
        let model = model()
        model.toggleDiscovery()
        model.discovery?.page = DiscoveryPage(guilds: [guild(joinedID)], total: 1)
        let card = try #require(model.discoveryCards.first)
        #expect(card.isJoined)

        model.openDiscoveryCard(card)
        #expect(!model.isDiscoveryShown)
        #expect(model.selectedGuildID == joinedID)
        // No lurk was raised for a server the account is in.
        #expect(model.guildPreview == nil)
    }

    /// Lurking needs `PREVIEW_ENABLED`, and a discoverable server does not
    /// always carry it. §5.5: a card offering a preview the route would refuse
    /// is a control that cannot work.
    @Test("Whether a card can be previewed is read, not assumed")
    func previewIsGatedOnTheFeature() throws {
        let model = model()
        model.toggleDiscovery()
        model.discovery?.page = DiscoveryPage(
            guilds: [
                guild(strangerID, features: ["DISCOVERABLE"]),
                guild(GuildID(rawValue: 3000), features: ["DISCOVERABLE", "PREVIEW_ENABLED"]),
            ],
            total: 2
        )
        let cards = model.discoveryCards
        #expect(cards.first?.canPreview == false)
        #expect(cards.last?.canPreview == true)
    }

    // MARK: The headings

    /// The route answers forty-nine headings; the picker offers the five the
    /// reference client's own tab strip shows, **in its order**. The rest stay
    /// decoded, because a search facet answers in category ids and a bucket
    /// nobody can name is a number with no label.
    @Test("The picker offers Discord's own five, in Discord's order")
    func headingsAreCurated() {
        let model = model()
        model.toggleDiscovery()
        model.discoveryCategoryIndex = [
            DiscoveryCategory(id: 30, name: "LFG", isPrimary: false),
            DiscoveryCategory(id: 6, name: "Education", isPrimary: true),
            DiscoveryCategory(id: 1, name: "Gaming", isPrimary: true),
            DiscoveryCategory(id: 13, name: "Other", isPrimary: true),
            DiscoveryCategory(id: 3, name: "Entertainment", isPrimary: true),
        ]
        // Gaming, Entertainment, Education — the featured ids that were sent,
        // in the featured order, with the primary-but-unfeatured one out.
        #expect(model.discoveryCategories.map(\.name) == ["Gaming", "Entertainment", "Education"])
    }

    /// The names come from the route so a reader in another language gets their
    /// own; only the ids are this client's.
    @Test("A heading nobody sent is not invented")
    func missingHeadingsAreDropped() {
        let model = model()
        model.toggleDiscovery()
        model.discoveryCategoryIndex = []
        #expect(model.discoveryCategories.isEmpty)
    }

    /// A page number carried across a question is how a category opens onto
    /// results 60–90 of a list that has twelve.
    @Test("Changing the heading starts a new page")
    func changingCategoryResetsThePage() {
        let model = model()
        model.toggleDiscovery()
        model.discovery?.page = DiscoveryPage(guilds: [guild(strangerID)], total: 400)
        model.selectDiscoveryCategory(1)
        #expect(model.discovery?.page.guilds.isEmpty == true)
        #expect(model.discovery?.categoryID == 1)
    }

    /// **Featured is category `0`, not "no category".** Captured: with
    /// `category_id=0` the route answered forty-eight apps and with no category
    /// at all it answered seven — that second one is the launcher's own narrowed
    /// search. A tab labelled All with no category would have been a nearly empty
    /// grid that looked like a route which had stopped working.
    @Test("The app picker opens on Featured, which is a real category")
    func featuredIsACategory() {
        let model = model()
        model.toggleDiscovery()
        #expect(model.discovery?.appCategoryID == AppDirectoryCategory.featuredID)

        model.appDirectoryCategoryIndex = [
            AppDirectoryCategory(id: 6, name: "Games"),
            AppDirectoryCategory(id: 9, name: "Social"),
        ]
        // Prepended, because the route does not send it.
        #expect(model.appDirectoryCategories.map(\.name) == ["Featured", "Games", "Social"])
    }

    /// Nil is not a heading here, so it resolves back to Featured rather than
    /// becoming the seven-result search.
    @Test("Clearing the app heading returns to Featured")
    func clearingAppCategoryReturnsToFeatured() {
        let model = model()
        model.toggleDiscovery()
        model.selectDiscoveryTab(.apps)
        model.selectAppCategory(6)
        #expect(model.discovery?.appCategoryID == 6)
        model.selectAppCategory(nil)
        #expect(model.discovery?.appCategoryID == AppDirectoryCategory.featuredID)
    }

    /// The two id spaces are different — `6` is Games in the app directory and
    /// Education in server discovery — so the two pickers cannot share a value.
    @Test("The app headings are their own id space")
    func appCategoriesAreSeparate() {
        let model = model()
        model.toggleDiscovery()
        model.selectDiscoveryCategory(6)
        model.selectDiscoveryTab(.apps)
        #expect(model.discovery?.appCategoryID == AppDirectoryCategory.featuredID)
        model.selectAppCategory(6)
        #expect(model.discovery?.categoryID == 6)
        #expect(model.discovery?.appCategoryID == 6)
    }

    // MARK: What the page says

    @Test("An empty search says why discovery may not have found it")
    func emptySearchExplainsTheFloor() {
        let model = model()
        model.toggleDiscovery()
        model.discovery?.query = "a tiny server"
        model.discovery?.isLoading = false
        let line = model.discoveryEmptyLine
        #expect(line?.contains("200 members") == true)
    }

    /// Captured: a *lurk* counts against the hundred-server cap, so an account
    /// at the limit cannot even look — and nothing about the card explains it.
    @Test("The server limit is answered in words")
    func serverLimitHasItsOwnSentence() {
        let failure = SessionController.discoveryFailure(
            DiscordREST.Failure.api(status: 400, code: 30001, message: "You are at the 100 server limit.")
        )
        #expect(failure.contains("100 servers"))
    }
}

// MARK: - The two filters a search has

/// `Show filters.har` and `HAR language code and category_id.har`, driven
/// through the store. Both filters are refinements of a *query*, and the whole
/// question here is what survives one and what does not.
@Suite("Discovery filters")
@MainActor
struct DiscoveryFilterTests {

    private func searching(_ text: String = "hey") -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 1)
        model.toggleDiscovery()
        model.discoveryCategoryIndex = [
            DiscoveryCategory(id: 1, name: "Gaming", isPrimary: true),
            DiscoveryCategory(id: 3, name: "Entertainment", isPrimary: true),
            DiscoveryCategory(id: 14, name: "General Chatting", isPrimary: true),
            DiscoveryCategory(id: 43, name: "Emoji", isPrimary: false),
        ]
        model.setDiscoveryQuery(text)
        return model
    }

    /// The facet as it arrives: `-1` is the total, and the buckets are ordered
    /// by count. Captured for "hey" — 142 in all, 107 Gaming, 71 General
    /// Chatting, 62 Entertainment, 19 Emoji.
    private static let capturedFacet: [Int: Int] = [
        DiscoveryPage.allCategoriesFacet: 142, 1: 107, 14: 71, 3: 62, 43: 19,
    ]

    @Test("The Show menu is the facet, largest first, with All as the -1 bucket")
    func facetIsOrderedByCount() {
        let model = searching()
        model.discovery?.facet = DiscoveryState.Facet(query: "hey", counts: Self.capturedFacet)
        let buckets = model.discoveryFacetBuckets
        #expect(buckets.map(\.name) == ["All", "Gaming", "General Chatting", "Entertainment", "Emoji"])
        #expect(buckets.map(\.count) == [142, 107, 71, 62, 19])
        // The All row clears the filter rather than naming a category, because
        // `-1` is a total and there is no category behind it.
        #expect(buckets.first?.id == nil)
        #expect(buckets.last?.id == 43)
    }

    /// The names come from the route. A bucket the categories list cannot name
    /// is a number with no label, which is not a filter anybody can use.
    @Test("A bucket with no name is dropped rather than numbered")
    func unnamedBucketsAreDropped() {
        let model = searching()
        model.discovery?.facet = DiscoveryState.Facet(
            query: "hey",
            counts: [DiscoveryPage.allCategoriesFacet: 9, 1: 5, 9_999: 4]
        )
        #expect(model.discoveryFacetBuckets.map(\.name) == ["All", "Gaming"])
    }

    /// **Once per query text.** Captured: `with_counts=true` goes out for the
    /// query and `false` for every refinement of it — a bucket, a language.
    @Test("The facet is asked for once per query and never for a refinement")
    func facetIsAskedForOncePerQuery() throws {
        let model = searching()
        var state = try #require(model.discovery)
        #expect(state.wantsFacet(for: state.serverRequest))

        model.discovery?.facet = DiscoveryState.Facet(query: "hey", counts: Self.capturedFacet)
        model.selectDiscoveryCategory(1)
        state = try #require(model.discovery)
        #expect(!state.wantsFacet(for: state.serverRequest))

        model.selectDiscoveryLanguage("en-US")
        state = try #require(model.discovery)
        #expect(!state.wantsFacet(for: state.serverRequest))

        // A different question is a different facet.
        model.setDiscoveryQuery("mid")
        state = try #require(model.discovery)
        #expect(state.wantsFacet(for: state.serverRequest))
    }

    /// The first request for a query carries no `category_id` in either
    /// capture: the facet it answers with is what the reader narrows *from*.
    @Test("A new query drops the category it was narrowed to")
    func newQueryDropsTheCategory() {
        let model = searching()
        model.discovery?.facet = DiscoveryState.Facet(query: "hey", counts: Self.capturedFacet)
        model.selectDiscoveryCategory(43)
        #expect(model.discovery?.categoryID == 43)

        model.setDiscoveryQuery("mid")
        #expect(model.discovery?.categoryID == nil)
        #expect(model.discovery?.page.guilds.isEmpty == true)
    }

    /// A language is the reader's own standing preference rather than part of
    /// the question, so it survives a new query — and it composes with a
    /// category, which is exactly the last two requests in the language capture.
    @Test("The language survives a new query and composes with a category")
    func languageComposes() throws {
        let model = searching("mid")
        model.selectDiscoveryLanguage("zh-TW")
        #expect(model.discovery?.serverRequest.languageCode == "zh-TW")

        model.selectDiscoveryLanguage("en-US")
        model.selectDiscoveryCategory(3)
        let request = try #require(model.discovery?.serverRequest)
        #expect(request.languageCode == "en-US")
        #expect(request.categoryID == 3)
        #expect(request.query == "mid")

        model.setDiscoveryQuery("hey")
        #expect(model.discovery?.languageCode == "en-US")
    }

    /// **Servers only.** `language_code` goes to the server search route and
    /// the app directory has no such parameter, so the control must not be
    /// offered there — §5.5.
    @Test("The language filter is not offered on the apps tab")
    func languageIsServersOnly() {
        let model = searching()
        model.selectDiscoveryTab(.apps)
        model.selectDiscoveryLanguage("da")
        #expect(model.discovery?.languageCode == nil)
    }
}

// MARK: - The apps grid

@Suite("Discovery app cards")
@MainActor
struct DiscoveryAppCardTests {

    private func model(_ app: ActivityApp) -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 1)
        model.toggleDiscovery()
        model.discovery?.tab = .apps
        model.discovery?.apps = [app]
        return model
    }

    private let id = ApplicationID(rawValue: 1_187_013_846_746_005_515)

    /// **The banner has five candidates and the order is the whole decision.**
    /// Each step below removes the one above it.
    ///
    /// **The first two are Discord's own**, read off its banner component:
    /// `embedded_cover` if the asset lookup answers, else the bot's profile
    /// banner. The rest are this client's, below the two Discord uses. `bot`
    /// matters most in volume — 180 of the captured 265 have one against
    /// `cover_image`'s 75 — which is why a client that skipped it drew an empty
    /// band for three quarters of the grid.
    @Test("A tile's banner falls back through the five artworks in order")
    func bannerFallsBackInOrder() throws {
        var app = ActivityApp(
            id: id,
            name: "Farm Merge Valley",
            coverHash: "cover",
            botBannerHash: "b084bfd45ac87a1f8c764fe256923273",
            heroImageURL: URL(string: "https://images-ext-1.discordapp.net/carousel.png"),
            config: EmbeddedActivityConfig(previewVideoAssetID: "1232355776870223923")
        )
        app.tileAssetID = "embeddedcover"

        // 1. `embedded_cover`, which is what Discord reaches for first.
        var card = AppModel.directoryCard(for: app)
        #expect(card.bannerURL?.path().contains("/app-assets/") == true)
        #expect(card.bannerURL?.path().contains("embeddedcover") == true)

        // 2. The bot's own profile banner — `/banners/{id}/`, not an app asset.
        app.tileAssetID = nil
        card = AppModel.directoryCard(for: app)
        #expect(card.bannerURL?.path().hasPrefix("/banners/\(id.rawValue)/") == true)

        // 3. `cover_image`, which lives under `/app-icons/`, not `/app-assets/`.
        app.botBannerHash = nil
        card = AppModel.directoryCard(for: app)
        #expect(card.bannerURL?.path().contains("/app-icons/") == true)

        // 4. The loop's own first frame — the `.png` at the video's asset id.
        app.coverHash = nil
        card = AppModel.directoryCard(for: app)
        let poster = try #require(card.bannerURL)
        #expect(poster.path().hasSuffix("/store/1232355776870223923.png"))

        // 5. The carousel's first still, which is a screenshot rather than a
        //    banner and is therefore last.
        app.config = nil
        card = AppModel.directoryCard(for: app)
        #expect(card.bannerURL?.host() == "images-ext-1.discordapp.net")

        // Nil is a real answer, and the tile falls back to the bot's accent.
        app.heroImageURL = nil
        app.botAccentColor = 0x2ECC71
        card = AppModel.directoryCard(for: app)
        #expect(card.bannerURL == nil)
        #expect(card.accentColor != nil)
    }

    /// **The shape travels with the address**, because the two are authored
    /// differently and a 5:2 banner in a 16:9 box loses a third of itself off
    /// the sides — `.fmbot` read ".fmbo" that way.
    @Test("A banner carries the ratio it was authored at")
    func bannerCarriesItsRatio() throws {
        var app = ActivityApp(id: id, name: "Fmbot", botBannerHash: "banner")
        let banner = try #require(AppModel.appBanner(for: app, width: 300))
        #expect(banner == .profileBanner(banner.url))
        // Typed on the way in: `#expect` compares a `CGFloat` against a `Double`
        // literal through an implicit conversion, and the two 2.5s do not match.
        let bannerRatio: CGFloat = 5 / 2
        #expect(banner.aspectRatio == bannerRatio)

        app.tileAssetID = "embeddedcover"
        let cover = try #require(AppModel.appBanner(for: app, width: 300))
        #expect(cover == .embeddedCover(cover.url))
        let coverRatio: CGFloat = 16 / 9
        #expect(cover.aspectRatio == coverRatio)
    }

    /// **An app with no picture at all has no hero**, rather than a band the
    /// height of one. Most bots are that app: none of the five candidates.
    @Test("A page with no artwork draws no hero")
    func pageWithNoArtworkHasNoHero() {
        let bare = ActivityApp(id: id, name: "FluxiBot")
        #expect(!ActivityDetailPage.heroHasPicture(bare))

        var withBanner = bare
        withBanner.botBannerHash = "abc"
        #expect(ActivityDetailPage.heroHasPicture(withBanner))
    }

    /// The loop and the still it starts on are the same asset id at two
    /// extensions — probed, and the reason the crossing is invisible.
    @Test("The loop and its poster are one asset at two extensions")
    func loopAndPosterShareAnAsset() throws {
        let app = ActivityApp(
            id: id,
            name: "Farm Merge Valley",
            config: EmbeddedActivityConfig(previewVideoAssetID: "1232355776870223923")
        )
        let card = AppModel.directoryCard(for: app)
        let video = try #require(card.videoURL)
        let still = try #require(card.bannerURL)
        #expect(video.path().hasSuffix(".mp4"))
        #expect(still.path().hasSuffix(".png"))
        // Paths, not URLs: the still takes a `?size=` rung and the video, being
        // a video, takes none.
        #expect(
            video.deletingPathExtension().path() == still.deletingPathExtension().path()
        )
    }

    /// **An `a_` bot banner is the hover motion for an app with no preview
    /// loop**, and Discord offers exactly one of the two: its component passes
    /// `animatedUrl: undefined` down the video branch.
    @Test("An animated bot banner hovers, and only where there is no video")
    func animatedBannerIsTheOtherHoverMotion() throws {
        var app = ActivityApp(
            id: id,
            name: "Nekotina",
            botBannerHash: "a_7ec0920422783afa8a6f1f5fdd822aa9"
        )
        let card = AppModel.directoryCard(for: app)
        let film = try #require(card.animatedBannerURL)
        // The same asset as the still: an `a_` hash resolves to `.gif`, and the
        // still underneath is that file's first frame.
        #expect(film == card.bannerURL)
        #expect(film.pathExtension == "gif")

        // A preview loop wins, and the banner's film is not offered beside it.
        app.config = EmbeddedActivityConfig(previewVideoAssetID: "1232355776870223923")
        #expect(AppModel.directoryCard(for: app).animatedBannerURL == nil)

        // A still banner has no film at all.
        app.config = nil
        app.botBannerHash = "5b4d978e173354ec88cba5888a8a457f"
        #expect(AppModel.directoryCard(for: app).animatedBannerURL == nil)

        // Neither has an artwork that is not the profile banner.
        app.botBannerHash = "a_7ec0920422783afa8a6f1f5fdd822aa9"
        app.tileAssetID = "embeddedcover"
        #expect(AppModel.directoryCard(for: app).animatedBannerURL == nil)
    }

    /// An app with no `embedded_activity_config` is a bot, and a bot has no
    /// loop — so nothing hovers into a player that cannot exist.
    @Test("An app with no preview has no loop")
    func botsHaveNoLoop() {
        let card = AppModel.directoryCard(
            for: ActivityApp(id: id, name: "Dank Memer", tagline: "A bot.")
        )
        #expect(card.videoURL == nil)
        #expect(card.subtitle == "A bot.")
    }

    /// The shelf knows `embedded_cover` for the apps it carries and the
    /// directory's own answer does not, so the grid fills it in where the two
    /// overlap.
    @Test("The grid takes the shelf's cover where the directory has none")
    func gridUsesTheShelfCover() throws {
        let app = ActivityApp(id: id, name: "Farm Merge Valley")
        let model = model(app)
        model.activityDirectory = ActivityDirectory(
            collections: [],
            apps: [id: ActivityApp(id: id, name: "Farm Merge Valley", tileAssetID: "shelfcover")]
        )
        let card = try #require(model.discoveryAppCards.first)
        #expect(card.bannerURL?.path().contains("shelfcover") == true)
    }
}

// MARK: - The app page's own sections

/// Everything the page draws that was on the wire and read by nothing.
/// `fmbot.har` and `OwO bot.har` are the two ends of each: `.fmbot` has eight
/// permissions, two data-access rows, five commands and a support server;
/// OwO has one data-access row.
@Suite("App page sections")
struct AppPageSectionTests {

    /// **Two bits per intent, and both mean the app has it.** Discord splits
    /// every privileged intent into an approved flag and a `_LIMITED` one for an
    /// app under the hundred-server threshold.
    @Test("Data access is read from the flags, in Discord's order")
    func dataAccessFromFlags() {
        // `.fmbot`: bits 14, 15 and 18 — its page lists Members and Read
        // Messages, in that order on screen.
        let fmbot = AppDataAccess.all(flags: 10_797_056)
        #expect(fmbot.map(\.title) == ["Read Messages", "Members"])

        // OwO: bit 18 alone.
        #expect(AppDataAccess.all(flags: 10_747_904).map(\.title) == ["Read Messages"])

        // An app with no privileged intent has no section at all.
        #expect(AppDataAccess.all(flags: 0).isEmpty)

        // Presence is the third, and the `_LIMITED` bit alone is enough.
        #expect(AppDataAccess.all(flags: 1 << 13).map(\.title) == ["Presence"])
    }

    /// `install_params.permissions` is a decimal **string** — every permission
    /// bitfield on this wire is, because it does not fit a JSON number — and
    /// `.fmbot`'s names exactly the eight its page lists.
    @Test("The required permissions are the eight the page names")
    func requiredPermissions() {
        let permissions = Permissions(rawValue: 275_415_092_288)
        let named = PermissionCatalog.groups
            .flatMap(\.entries)
            .filter { permissions.contains($0.permission) }
        #expect(named.count == 8)
        #expect(permissions.contains(.manageWebhooks))
        #expect(permissions.contains(.sendMessagesInThreads))
        #expect(permissions.contains(.useExternalEmojis))
        #expect(!permissions.contains(.administrator))
    }
}

// MARK: - The five defects the first live run found

/// Each of these shipped, was seen on screen, and is pinned here so it cannot
/// come back. Four of the five were silent — nothing failed, the surface simply
/// answered wrongly.
@Suite("Discovery regressions")
@MainActor
struct DiscoveryRegressionTests {

    private let joinedID = GuildID(rawValue: 1000)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 1)
        model.guilds = [
            joinedID: Guild(id: joinedID, name: "Lumen Club", ownerID: UserID(rawValue: 1)),
        ]
        return model
    }

    /// **The toolbar's search field sat over discovery**, offering to search a
    /// server nobody could see. `ChannelChrome.none` empties every control the
    /// bar *builds*, and the field is the system's — installed by `.searchable`,
    /// and unreachable from a chrome value. The whole bar goes instead.
    @Test("A takeover hides the window toolbar, search field included")
    func takeoverHidesTheToolbar() {
        let model = model()
        #expect(!model.isColumnTakenOver)
        model.toggleDiscovery()
        #expect(model.isColumnTakenOver)
    }

    /// **A refused preview used to dump the reader out of discovery.** The page
    /// closed on the click, so at the hundred-server cap — which a lurk counts
    /// against, captured — they landed in whatever channel was underneath,
    /// reading a notice about a server no longer on screen.
    @Test("A card click does not close discovery until the preview starts")
    func discoveryStaysUpUntilThePreviewStarts() {
        let model = model()
        model.toggleDiscovery()
        model.discovery?.page = DiscoveryPage(
            guilds: [
                DiscoverableGuild(
                    id: GuildID(rawValue: 2000),
                    name: "Somewhere",
                    features: ["DISCOVERABLE", "PREVIEW_ENABLED"]
                ),
            ],
            total: 1
        )
        let card = model.discoveryCards[0]
        model.openDiscoveryCard(card)
        // The lurk needs a gateway session, which a bare store has none of — so
        // it cannot have started, and the page must still be there.
        #expect(model.isDiscoveryShown)
    }

    /// A card for a server the account is in is navigation, and that path *does*
    /// close immediately — there is no request to wait on.
    @Test("A joined card closes discovery at once")
    func joinedCardClosesAtOnce() {
        let model = model()
        model.toggleDiscovery()
        model.discovery?.page = DiscoveryPage(
            guilds: [DiscoverableGuild(id: joinedID, name: "Lumen Club")],
            total: 1
        )
        model.openDiscoveryCard(model.discoveryCards[0])
        #expect(!model.isDiscoveryShown)
        #expect(model.selectedGuildID == joinedID)
    }

    /// **An app card opened the Add App sheet instead of the app's page.** The
    /// directory card is a question — what *is* this app — and adding it is one
    /// button on the answer.
    @Test("An app card opens its page, one level inside discovery")
    func appCardOpensItsPage() {
        let model = model()
        model.toggleDiscovery()
        let app = ActivityApp(id: ApplicationID(rawValue: 42), name: "Wordle")
        model.openDiscoveryApp(app.id)
        #expect(model.discovery?.openAppID == app.id)
        // Still discovery, and the grid underneath is not thrown away.
        #expect(model.isDiscoveryShown)
        #expect(model.applicationInstallRequest == nil)

        model.closeDiscoveryApp()
        #expect(model.discovery?.openAppID == nil)
    }

    /// **Adding raises a sheet OVER the page and does not leave it.** It closed
    /// discovery first, and the sheet is presented by the composer's launcher —
    /// so from the rail the button dismissed the page and then showed nothing at
    /// all. The page is what the reader comes back to.
    @Test("Adding an app from its page raises the install sheet over it")
    func addingRaisesTheSheet() {
        let model = model()
        model.toggleDiscovery()
        let id = ApplicationID(rawValue: 42)
        model.addDiscoveredApp(id)
        #expect(model.isDiscoveryShown)
        #expect(model.applicationInstallRequest?.applicationID == id)
    }

    /// The storefront is a third level, and the two under it survive it.
    @Test("An app's store is a level inside its page")
    func storeIsALevelInside() {
        let model = model()
        model.toggleDiscovery()
        let id = ApplicationID(rawValue: 42)
        model.openDiscoveryApp(id)
        model.openDiscoveredAppStore(id)
        #expect(model.discovery?.openStoreID == id)
        #expect(model.discovery?.openAppID == id)

        model.closeDiscoveredAppStore()
        #expect(model.discovery?.openStoreID == nil)
        #expect(model.discovery?.openAppID == id)
    }
}
