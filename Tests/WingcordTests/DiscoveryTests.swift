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

    /// Seventeen primary headings are a picker; forty-nine is a list nobody
    /// reads to the end of. The subcategories stay decoded, because a search
    /// facet answers with them.
    @Test("Only primary headings are offered for browsing")
    func onlyPrimaryCategoriesAreOffered() {
        let model = model()
        model.toggleDiscovery()
        model.discovery?.categories = [
            DiscoveryCategory(id: 1, name: "Gaming", isPrimary: true),
            DiscoveryCategory(id: 30, name: "LFG", isPrimary: false),
        ]
        #expect(model.discoveryCategories.map(\.name) == ["Gaming"])
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

    /// The two id spaces are different — `6` is Games in the app directory and
    /// Education in server discovery — so the two pickers cannot share a value.
    @Test("The app headings are their own id space")
    func appCategoriesAreSeparate() {
        let model = model()
        model.toggleDiscovery()
        model.selectDiscoveryCategory(6)
        model.selectDiscoveryTab(.apps)
        #expect(model.discovery?.appCategoryID == nil)
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
