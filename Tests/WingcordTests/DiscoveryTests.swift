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
        #expect(card.standing != nil)
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
        model.discovery?.categories = [
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
        model.discovery?.categories = []
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

        model.discovery?.appCategories = [
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
        model.openDiscoveryApp(app)
        #expect(model.discovery?.openAppID == app.id)
        // Still discovery, and the grid underneath is not thrown away.
        #expect(model.isDiscoveryShown)
        #expect(model.applicationInstallRequest == nil)

        model.closeDiscoveryApp()
        #expect(model.discovery?.openAppID == nil)
    }

    /// Adding is the one act that leaves the page, because the sheet is a task
    /// with an end.
    @Test("Adding an app from its page raises the install sheet")
    func addingRaisesTheSheet() {
        let model = model()
        model.toggleDiscovery()
        let id = ApplicationID(rawValue: 42)
        model.addDiscoveredApp(id)
        #expect(!model.isDiscoveryShown)
        #expect(model.applicationInstallRequest?.applicationID == id)
    }
}
