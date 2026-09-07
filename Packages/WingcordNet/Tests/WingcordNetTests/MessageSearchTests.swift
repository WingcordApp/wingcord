import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The message-search grammar and its answer.
///
/// **Every query string asserted here is one Discord's own client sent**, taken
/// from `search messages1.har`. The route has twenty-odd parameters and no body,
/// so the grammar *is* the feature — and a parameter written the wrong way
/// (comma-joined instead of repeated, a date instead of a snowflake) does not
/// fail loudly. It returns results, just not the ones that were asked for.
@Suite("Message search")
struct MessageSearchTests {

    private let guildID = GuildID(rawValue: 1_520_000_000_000_000_001)

    private func query() -> MessageSearchQuery {
        MessageSearchQuery(scope: .guild(guildID))
    }

    /// Renders a query the way the URL will carry it, so the assertions below
    /// read as the captured query string rather than as an array of pairs.
    private func string(_ query: MessageSearchQuery) -> String {
        DiscordREST.queryItems(for: query)
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
    }

    // MARK: The captured queries

    /// `?content=hey&sort_by=timestamp&sort_order=desc&offset=0`
    @Test("A plain text search is the captured query string")
    func plainContentSearch() {
        var value = query()
        value.content = "hey"
        #expect(string(value) == "content=hey&sort_by=timestamp&sort_order=desc&offset=0")
    }

    /// The three sort combinations the capture exercises.
    @Test("Sort and order travel as captured", arguments: [
        (MessageSearchSort.timestamp, MessageSearchOrder.descending, "sort_by=timestamp&sort_order=desc"),
        (.timestamp, .ascending, "sort_by=timestamp&sort_order=asc"),
        (.relevance, .descending, "sort_by=relevance&sort_order=desc"),
    ])
    func sorting(sort: MessageSearchSort, order: MessageSearchOrder, expected: String) {
        var value = query()
        value.content = "hey"
        value.sort = sort
        value.order = order
        #expect(string(value) == "content=hey&\(expected)&offset=0")
    }

    /// **`sort_order` is sent even for relevance, where the route ignores it** —
    /// because the capture sends it. The client says so in `honoursOrder`
    /// instead, which is what stops the *control* being offered.
    @Test("Relevance still carries an order on the wire, and says it has none")
    func relevanceCarriesOrder() {
        var value = query()
        value.sort = .relevance
        #expect(string(value).contains("sort_order=desc"))
        #expect(!MessageSearchSort.relevance.honoursOrder)
        #expect(MessageSearchSort.timestamp.honoursOrder)
    }

    @Test("A filter with no text at all is a real search")
    func filterOnlySearch() {
        var value = query()
        value.authorIDs = [UserID(rawValue: 1_311_517_818_562_199_525)]
        #expect(string(value)
            == "author_id=1311517818562199525&sort_by=timestamp&sort_order=desc&offset=0")
        #expect(!value.isEmpty)
    }

    @Test("Channel and mention filters are the captured names")
    func channelAndMentionFilters() {
        var inChannel = query()
        inChannel.channelIDs = [ChannelID(rawValue: 1_528_177_367_079_189_287)]
        #expect(string(inChannel).hasPrefix("channel_id=1528177367079189287"))

        var mentions = query()
        mentions.mentionIDs = [UserID(rawValue: 811_641_072_529_494_819)]
        #expect(string(mentions).hasPrefix("mentions=811641072529494819"))

        var hasImage = query()
        hasImage.has = [.image]
        #expect(string(hasImage).hasPrefix("has=image"))
    }

    /// **The one that a plausible reading gets wrong.** `author_type` is written
    /// three times, not once comma-joined — and the capture is the only place
    /// that says so.
    @Test("A list parameter is repeated keys, never a joined value")
    func listsAreRepeatedKeys() {
        var value = query()
        value.authorKinds = [.user, .bot, .webhook]
        let rendered = string(value)
        #expect(rendered.contains("author_type=bot&author_type=user&author_type=webhook"))
        #expect(!rendered.contains("author_type=user,bot"))

        value.authorIDs = [UserID(rawValue: 1), UserID(rawValue: 2)]
        #expect(string(value).contains("author_id=1&author_id=2"))
    }

    /// The last captured query, whole: a date range, all three author types and
    /// pinned, with no text.
    @Test("The filter sheet's full query is the captured one")
    func fullFilterQuery() {
        var value = query()
        value.dates = [
            .before(MessageID(rawValue: 1_546_626_111_897_600_000).timestamp),
            .after(MessageID(rawValue: 1_546_263_724_032_000_000).timestamp),
        ]
        value.authorKinds = [.user, .bot, .webhook]
        value.isPinned = true

        let rendered = string(value)
        #expect(rendered.contains("max_id=1546626111897600000"))
        #expect(rendered.contains("min_id=1546263724032000000"))
        #expect(rendered.contains("pinned=true"))
        #expect(rendered.hasSuffix("sort_by=timestamp&sort_order=desc&offset=0"))
    }

    /// **The captured pair is also exactly one "During" row**, which is what
    /// makes the three kinds one window rather than three parameters: the ids
    /// are 2026-09-06 00:00 and 2026-09-07 00:00 local — a single day.
    @Test("During a day is the same window as After that day plus Before the next")
    func duringIsOneDayWindow() {
        let day = MessageID(rawValue: 1_546_263_724_032_000_000).timestamp

        var during = query()
        during.dates = [.during(day)]

        var pair = query()
        pair.dates = [
            .after(day),
            .before(Calendar.current.date(byAdding: .day, value: 1, to: day)!),
        ]
        #expect(string(during) == string(pair))
        #expect(string(during).contains("min_id=1546263724032000000"))
        #expect(string(during).contains("max_id=1546626111897600000"))
    }

    /// Each kind contributes only its own end.
    @Test("Before is a ceiling, After is a floor")
    func singleClauseBounds() {
        let day = Date(timeIntervalSince1970: 1_767_225_600)

        var before = query()
        before.dates = [.before(day)]
        #expect(string(before).contains("max_id="))
        #expect(!string(before).contains("min_id="))

        var after = query()
        after.dates = [.after(day)]
        #expect(string(after).contains("min_id="))
        #expect(!string(after).contains("max_id="))
    }

    /// **N rows, one window.** The route has two date parameters, so the
    /// sheet's list intersects rather than offering alternatives.
    @Test("Several date rows narrow to a single window")
    func dateRowsIntersect() {
        let early = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01
        let late = Date(timeIntervalSince1970: 1_769_904_000)    // 2026-02-01

        var value = query()
        value.dates = [.before(late), .before(early)]
        // The tighter ceiling wins.
        #expect(value.dateBounds.before == Calendar.current.startOfDay(for: early))

        value.dates = [.after(early), .after(late)]
        #expect(value.dateBounds.after == Calendar.current.startOfDay(for: late))

        // And the whole list is one row of the badge, however many clauses.
        value.dates = [.after(early), .before(late), .during(early)]
        #expect(value.activeFilterCount == 1)
    }

    // MARK: Dates are snowflakes

    /// **There is no `before`/`after` in wall-clock time on this route.** A
    /// client that sent one would have every date filter silently ignored.
    ///
    /// **And both bounds zero their low bits** — the capture's `max_id` and
    /// `min_id` both do, which rules out the tempting "ceiling with every low
    /// bit set" design. See `Snowflake.bound(for:)`.
    @Test("A date round-trips through its snowflake bound, low bits zeroed")
    func datesBecomeSnowflakes() {
        let moment = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01Z
        let id = MessageID.bound(for: moment)
        #expect(id.rawValue & 0x3F_FFFF == 0)
        #expect(abs(id.timestamp.timeIntervalSince(moment)) < 0.001)
    }

    /// A date before Discord existed has no id. Wrapping the subtraction would
    /// produce an id far in the *future* — a filter that matches nothing.
    @Test("A pre-epoch date floors at zero rather than wrapping")
    func preEpochDateFloors() {
        #expect(MessageID.bound(for: Date(timeIntervalSince1970: 0)).rawValue == 0)
    }

    // MARK: Paging

    /// The documented ceilings: 25 a page, offset at most 9975 — exactly 400
    /// pages, whatever `total_results` claims.
    @Test("Pages become offsets, and both are clamped to the documented ceiling")
    func pagingClamps() {
        #expect(query().onPage(1).offset == 0)
        #expect(query().onPage(2).offset == 25)
        #expect(query().onPage(34).offset == 825)
        #expect(MessageSearchQuery.maximumPage == 400)
        #expect(query().onPage(400).offset == 9975)
        // Past the end, and below the start.
        #expect(query().onPage(9_999).offset == 9975)
        #expect(query().onPage(0).page == 1)
        #expect(query().onPage(-4).page == 1)
    }

    /// 842 results is 34 pages — the number in the captured screenshot.
    @Test("The page count follows the result count, then the route's ceiling")
    func pageCount() {
        #expect(MessageSearchPage(totalResults: 842).pageCount == 34)
        #expect(MessageSearchPage(totalResults: 0).pageCount == 0)
        #expect(MessageSearchPage(totalResults: 25).pageCount == 1)
        #expect(MessageSearchPage(totalResults: 26).pageCount == 2)
        // A guild with more hits than `offset` can reach is 400 pages, not
        // 1,600 — offering the 1,600th offers a 400.
        #expect(MessageSearchPage(totalResults: 40_000).pageCount == 400)
    }

    /// Changing page must change nothing else, or a page number stops meaning
    /// what it says.
    @Test("Paging holds the rest of the query still")
    func pagingIsIsolated() {
        var value = query()
        value.content = "hey"
        value.has = [.image]
        value.sort = .relevance
        let paged = value.onPage(7)
        #expect(paged.content == "hey")
        #expect(paged.has == [.image])
        #expect(paged.sort == .relevance)
        #expect(string(paged).hasSuffix("offset=150"))
    }

    // MARK: What counts as a search

    @Test("An empty query is not a search, and one filter makes it one")
    func emptiness() {
        #expect(query().isEmpty)
        var spaces = query()
        spaces.content = "   "
        #expect(spaces.isEmpty)

        var pinned = query()
        pinned.isPinned = false
        #expect(!pinned.isEmpty)
        #expect(pinned.activeFilterCount == 1)
    }

    /// Fields, not values — "Filters (2)" means two rows of the sheet are set.
    @Test("The filter badge counts fields")
    func filterBadgeCountsFields() {
        var value = query()
        value.authorIDs = [UserID(rawValue: 1), UserID(rawValue: 2), UserID(rawValue: 3)]
        value.has = [.image, .video]
        #expect(value.activeFilterCount == 2)

        let cleared = value.clearingFilters()
        #expect(cleared.activeFilterCount == 0)
    }

    /// A DM has one channel, and the route rejects the parameter there.
    @Test("channel_id is dropped on a private channel search")
    func channelFilterIsGuildOnly() {
        var dm = MessageSearchQuery(scope: .channel(ChannelID(rawValue: 42)))
        dm.channelIDs = [ChannelID(rawValue: 99)]
        #expect(!string(dm).contains("channel_id"))
    }

    // MARK: The answer

    /// The captured 200, trimmed to one group.
    private let answer = """
    {"analytics_id":"34c5afad28a69a57059b5800c1004d34",
     "doing_deep_historical_index":false,
     "total_results":15,
     "messages":[[
       {"id":"1545896271576775658","type":0,"content":"hey speaking of which",
        "channel_id":"1528177367079189287","hit":true,
        "timestamp":"2026-09-01T12:00:00.000000+00:00",
        "author":{"id":"811641072529494819","username":"_vexlor_","discriminator":"0"},
        "attachments":[],"embeds":[],"mentions":[],"mention_roles":[],"pinned":false}
     ]]}
    """

    /// **The nesting is vestigial and gets flattened.** It carried surrounding
    /// context until Discord stopped returning it; every captured group holds
    /// exactly one message.
    @Test("A page flattens its groups and keeps the server's total")
    func pageDecodes() throws {
        let page = try JSONDecoder()
            .decode(MessageSearchDTO.self, from: Data(answer.utf8))
            .domain

        #expect(page.messages.count == 1)
        #expect(page.messages.first?.id == MessageID(rawValue: 1_545_896_271_576_775_658))
        // **Never the array's length** — the route returns fewer than it counts.
        #expect(page.totalResults == 15)
        #expect(page.pageCount == 1)
        #expect(!page.isDeepIndexing)
        // Carried, or every row draws "Unknown" over a grey circle.
        #expect(page.authors[UserID(rawValue: 811_641_072_529_494_819)]?.handle.contains("vexlor") == true)
    }

    /// The captured no-results answer. A 200 with an empty array is a page to
    /// draw, not an error to report.
    @Test("No results is a page, not a failure")
    func emptyPageDecodes() throws {
        let empty = """
        {"analytics_id":"242f428966cd48d506a8a9cc5988de36","messages":[],
         "doing_deep_historical_index":false,"total_results":0}
        """
        let page = try JSONDecoder()
            .decode(MessageSearchDTO.self, from: Data(empty.utf8))
            .domain
        #expect(page.messages.isEmpty)
        #expect(page.totalResults == 0)
        #expect(page.pageCount == 0)
    }

    /// **The 202 this client would otherwise read as an empty result set.** Its
    /// body looks like an error and is not one.
    @Test("The index-not-ready notice carries a delay with a floor")
    func indexingNoticeDecodes() throws {
        let body = """
        {"message":"Index not yet available. Try again later",
         "code":110000,"documents_indexed":0,"retry_after":2}
        """
        let dto = try JSONDecoder().decode(SearchIndexingDTO.self, from: Data(body.utf8))
        #expect(dto.retry_after == 2)
        #expect(dto.documents_indexed == 0)

        // Zero means "a short delay", not "immediately" — retrying with no
        // pause on a zero is a spin against a server that just said wait.
        #expect(DiscordREST.SearchIndexing(retryAfter: 0).delay == .milliseconds(1000))
        #expect(DiscordREST.SearchIndexing(retryAfter: 2).delay == .milliseconds(2000))
    }
}
