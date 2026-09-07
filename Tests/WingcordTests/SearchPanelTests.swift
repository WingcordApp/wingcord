import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The search panel, driven through the real store.
///
/// What is worth pinning here is not the query — `MessageSearchTests` owns that
/// — but the two states the panel has that a single query cannot express: what
/// is *typed* versus what the results *answer*, and what survives clicking a
/// result.
@Suite("Search panel")
@MainActor
struct SearchPanelTests {

    private let guildID = GuildID(rawValue: 1000)
    private let otherGuildID = GuildID(rawValue: 2000)
    private let channelID = ChannelID(rawValue: 2001)
    private let readerID = UserID(rawValue: 1)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        for id in [guildID, otherGuildID] {
            model.guilds[id] = Guild(id: id, name: "Server \(id.rawValue)", ownerID: readerID)
        }
        var index = ChannelIndex()
        index.replaceChannels(
            [Channel(id: channelID, kind: .text, guildID: guildID, name: "general", position: 0)],
            inGuild: guildID
        )
        model.channelIndex = index
        model.selectedGuildID = guildID
        model.selectedChannelID = channelID
        return model
    }

    // MARK: What is searched

    @Test("A selected server is the scope; a DM is its own channel")
    func scopeFollowsSelection() {
        let model = model()
        #expect(model.searchScope == .guild(guildID))

        model.selectedGuildID = nil
        model.selectedChannelID = channelID
        #expect(model.searchScope == .channel(channelID))
    }

    @Test("Toggling opens the panel, and toggling again closes it")
    func togglingOpensAndCloses() {
        let model = model()
        model.toggleSearch()
        #expect(model.isSearchShown)
        #expect(model.workspacePresentation.supplementary == .search)

        model.toggleSearch()
        #expect(!model.isSearchShown)
    }

    /// **Search outranks the roster.** Otherwise clicking a hit in a server with
    /// the member list on would hand the column back and close the search on its
    /// first use.
    @Test("Search takes the column ahead of the member list")
    func searchOutranksMembers() {
        let model = model()
        model.isMemberListShown = true
        #expect(model.workspacePresentation.supplementary == .members)

        model.toggleSearch()
        #expect(model.workspacePresentation.supplementary == .search)
    }

    /// The panel follows the rail, not the channel list.
    @Test("Changing server rebuilds the panel; changing channel leaves it alone")
    func scopeGuard() {
        let model = model()
        model.toggleSearch()
        model.searchText = "hey"
        #expect(model.searchScope == .guild(guildID))

        // A channel inside the same server: the results are still about here.
        model.selectChannel(channelID)
        #expect(model.searchText == "hey")
        #expect(model.isSearchShown)

        // Another server: a panel showing this one's hits would be a list about
        // somewhere else.
        model.selectGuild(otherGuildID)
        #expect(model.isSearchShown)
        #expect(model.searchText.isEmpty)
        #expect(model.messageSearch?.scope == .guild(otherGuildID))
    }

    // MARK: Typed versus answered

    /// **Two queries, deliberately.** One would let a result list disagree with
    /// the header above it.
    @Test("Editing the field does not renumber the results already on screen")
    func draftAndSubmittedAreSeparate() {
        let model = model()
        model.toggleSearch()
        model.searchText = "hey"

        // Pretend an answer landed for page 3 of that search.
        var answered = MessageSearchQuery(scope: .guild(guildID))
        answered.content = "hey"
        answered.page = 3
        model.messageSearch?.submitted = answered
        model.messageSearch?.page = MessageSearchPage(totalResults: 842)

        #expect(model.searchPresentation?.currentPage == 3)
        #expect(model.searchPresentation?.pageCount == 34)
        #expect(model.messageSearch?.isDirty == false)

        // Typing more must not move the page under the reader.
        model.searchText = "hey there"
        #expect(model.searchPresentation?.currentPage == 3)
        #expect(model.messageSearch?.isDirty == true)
    }

    /// A new question always starts at page one: the old page number would ask
    /// for results 826–850 of a search that may have twelve, and an empty page
    /// reads as "nothing found" rather than "past the end".
    @Test("Running a new search resets to page one")
    func newSearchResetsPage() {
        let model = model()
        model.toggleSearch()
        model.messageSearch?.draft.page = 7
        model.searchText = "hey"
        model.runSearch()
        #expect(model.messageSearch?.draft.page == 1)
    }

    /// Paging is built from the answer, never from the draft — so it cannot
    /// quietly adopt edits nobody asked to run.
    @Test("Paging keeps the answered question, not the edited one")
    func pagingUsesTheAnsweredQuery() {
        let model = model()
        model.toggleSearch()

        var answered = MessageSearchQuery(scope: .guild(guildID))
        answered.content = "hey"
        model.messageSearch?.submitted = answered
        model.messageSearch?.page = MessageSearchPage(totalResults: 842)
        // The reader has since typed something else without pressing Return.
        model.searchText = "unrelated"

        model.goToSearchPage(4)
        // The request that went out is the answered question on another page.
        #expect(model.messageSearch?.submitted?.content == "hey")
    }

    @Test("An empty query never runs")
    func emptyQueryDoesNotRun() {
        let model = model()
        model.toggleSearch()
        model.searchText = "   "
        model.runSearch()
        #expect(model.messageSearch?.submitted == nil)
    }

    // MARK: Tokens become filters

    private func peopled() -> AppModel {
        let model = model()
        let alex = User(id: UserID(rawValue: 77), username: "alexsample", displayName: "alex")
        model.users[alex.id] = alex
        model.members[guildID] = [
            alex.id: Member(userID: alex.id, roleIDs: [], joinedAt: .now)
        ]
        return model
    }

    /// **The field is the query.** `from: alexsample` is an `author_id`, not
    /// three words to look for — the whole point of the tokenizer.
    @Test("A from token resolves to an author, not to content")
    func fromTokenResolves() {
        let model = peopled()
        let query = model.resolvedQuery(from: "hey from: alexsample")
        #expect(query.authorIDs == [UserID(rawValue: 77)])
        #expect(query.content == "hey")
    }

    /// The display name works too, because somebody typing by hand will use it.
    @Test("A display name resolves as well as a handle")
    func displayNameResolves() {
        let model = peopled()
        #expect(model.resolvedQuery(from: "from: alex").authorIDs == [UserID(rawValue: 77)])
    }

    /// **Unresolvable filters are dropped, never guessed at.** A roster loads
    /// lazily, so an unknown handle is ordinary — and sending it as `content`
    /// would search for the literal words.
    @Test("An unknown handle narrows nothing rather than becoming words")
    func unknownHandleIsDropped() {
        let model = peopled()
        let query = model.resolvedQuery(from: "hey from: nobody-here")
        #expect(query.authorIDs.isEmpty)
        #expect(query.content == "hey")
    }

    @Test("Every other token kind resolves")
    func otherTokensResolve() {
        let model = peopled()
        let query = model.resolvedQuery(
            from: "in: general has: image pinned: true during: 2026-09-06 mentions: alexsample"
        )
        #expect(query.channelIDs == [channelID])
        #expect(query.has == [.image])
        #expect(query.isPinned == true)
        #expect(query.mentionIDs == [UserID(rawValue: 77)])
        #expect(query.dates.count == 1)
        #expect(query.content.isEmpty)
    }

    /// The sheet writes tokens back into the field, so the two cannot disagree
    /// about what is being searched.
    @Test("A query rendered to the field parses back to the same query")
    func renderRoundTrips() {
        let model = peopled()
        var query = MessageSearchQuery(scope: .guild(guildID))
        query.content = "hey"
        query.authorIDs = [UserID(rawValue: 77)]
        query.channelIDs = [channelID]
        query.has = [.image]
        query.isPinned = false

        let parsed = model.resolvedQuery(from: model.render(query))
        #expect(parsed.authorIDs == query.authorIDs)
        #expect(parsed.channelIDs == query.channelIDs)
        #expect(parsed.has == query.has)
        #expect(parsed.isPinned == false)
        #expect(parsed.content == "hey")
    }

    // MARK: Autocomplete

    /// **The list follows the rail.** A suggestion from the server you left is
    /// a name that does not exist where you are searching.
    @Test("Suggestions come from the selected scope and change with it")
    func suggestionsFollowTheScope() {
        let model = peopled()
        let here = model.searchSuggestions(for: "from: ")
        #expect(here.contains { $0.detail == "alexsample" })

        // Another server, whose roster this account has not loaded.
        model.selectGuild(otherGuildID)
        let there = model.searchSuggestions(for: "from: ")
        #expect(!there.contains { $0.detail == "alexsample" })
    }

    /// An empty field offers the grammar itself, which is what Discord's own
    /// field does.
    @Test("An empty field offers the filter keys")
    func emptyFieldOffersKeys() {
        let model = peopled()
        let titles = model.searchSuggestions(for: "").map(\.title)
        #expect(titles.contains("From a specific user"))
        #expect(titles.contains("Sent in a specific channel"))
    }

    /// `in:` means nothing in a DM — the route rejects it.
    @Test("A DM is not offered the channel key")
    func dmOmitsTheChannelKey() {
        let model = peopled()
        model.selectedGuildID = nil
        model.selectedChannelID = channelID
        let titles = model.searchSuggestions(for: "").map(\.title)
        #expect(!titles.contains("Sent in a specific channel"))
    }

    // MARK: Clicking a result

    /// **The one thing the panel exists not to do is close itself.** A search is
    /// a list somebody works through.
    @Test("Opening a result jumps and leaves the panel up")
    func openingAResultKeepsThePanel() {
        let model = model()
        model.toggleSearch()
        model.searchText = "hey"
        // Read into a local first: reading and writing `messageSearch` in one
        // statement is overlapping access to the same stored property.
        let draft = model.messageSearch?.draft
        model.messageSearch?.submitted = draft

        model.openSearchResult(MessageID(rawValue: 5_000), in: channelID)

        #expect(model.isSearchShown)
        #expect(model.searchText == "hey")
        #expect(model.workspacePresentation.supplementary == .search)
        #expect(model.selectedChannelID == channelID)
    }
}
