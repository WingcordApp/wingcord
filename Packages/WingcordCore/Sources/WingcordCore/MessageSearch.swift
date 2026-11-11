import Foundation

// Searching a server's messages.
//
// **Captured** — `search messages1.har`, nine queries — and **documented**:
// `docs.discord.food/resources/message#search-guild-messages`, which is the one
// place the limits are written down. Where the two disagree the capture wins;
// where the capture is silent the documentation is what fills it in, and the
// notes below say which is which.
//
// The whole grammar is a query string. There is no body, no cursor object and no
// opaque page token — which is what makes "jump to page 41" a thing this client
// can actually offer.

/// What is being searched.
///
/// **Two routes, one grammar.** A guild search and a DM search take the same
/// parameters and answer the same shape; only the path differs — and one
/// parameter, `channel_id`, is meaningless on a DM because there is only one
/// channel to search.
public enum MessageSearchScope: Hashable, Sendable {
    case guild(GuildID)
    /// A direct message or group conversation.
    case channel(ChannelID)

    public var guildID: GuildID? {
        if case .guild(let id) = self { return id }
        return nil
    }
}

/// How results are ordered.
public enum MessageSearchSort: String, Hashable, Sendable, CaseIterable {
    /// The default, and the only one that can be reversed.
    case timestamp
    case relevance

    public var title: String {
        switch self {
        case .timestamp: "New"
        case .relevance: "Relevant"
        }
    }

    /// **Relevance has no direction.** The route documents `sort_order` as "not
    /// respected when sorting by relevance", so offering the control there would
    /// be a switch that changes nothing — the inert control `INVARIANTS.md` §5.5
    /// forbids.
    public var honoursOrder: Bool { self == .timestamp }
}

public enum MessageSearchOrder: String, Hashable, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

/// What a message has to carry to match.
///
/// Every value is negatable on the wire by prefixing `-`; this client offers the
/// positive set, which is what Discord's own filter sheet offers.
public enum MessageSearchHas: String, Hashable, Sendable, CaseIterable {
    case image, sound, video, file, sticker, embed, link, poll
    /// A forwarded message.
    case snapshot

    public var title: String {
        switch self {
        case .image: "Image"
        case .sound: "Sound"
        case .video: "Video"
        case .file: "File"
        case .sticker: "Sticker"
        case .embed: "Embed"
        case .link: "Link"
        case .poll: "Poll"
        case .snapshot: "Forwarded"
        }
    }

    public var symbolName: String {
        switch self {
        case .image: "photo"
        case .sound: "waveform"
        case .video: "video"
        case .file: "paperclip"
        case .sticker: "face.smiling"
        case .embed: "rectangle.on.rectangle"
        case .link: "link"
        case .poll: "chart.bar"
        case .snapshot: "arrowshape.turn.up.right"
        }
    }
}

/// Who sent it. Negatable on the wire the same way `has` is.
/// Which slice of an answer is on show — Discord's search tabs (`768570`):
/// the messages as asked, then the same question narrowed to media, links or
/// files, each counted in one request (`POST …/messages/search/tabs`).
public enum MessageSearchTab: String, Hashable, Sendable, CaseIterable {
    case messages, media, links, files

    public var title: String {
        switch self {
        case .messages: "Messages"
        case .media: "Media"
        case .links: "Links"
        case .files: "Files"
        }
    }

    public var symbolName: String {
        switch self {
        case .messages: "text.bubble"
        case .media: "photo.on.rectangle"
        case .links: "link"
        case .files: "doc"
        }
    }

    /// What the tab adds to the question — Discord's `su[B7[tab]]`:
    /// `has: image, video` for media, `link`, `file`, and nothing for messages.
    /// **The question's own `has` wins**, as Discord spreads it after the
    /// tab's, so a search that already asks for links asks every tab for links.
    public var has: [MessageSearchHas] {
        switch self {
        case .messages: []
        case .media: [.image, .video]
        case .links: [.link]
        case .files: [.file]
        }
    }
}

public enum MessageSearchAuthorKind: String, Hashable, Sendable, CaseIterable {
    case user, bot, webhook

    public var title: String {
        switch self {
        case .user: "User"
        case .bot: "Bot"
        case .webhook: "Webhook"
        }
    }

    public var symbolName: String {
        switch self {
        case .user: "person"
        case .bot: "cpu"
        case .webhook: "arrow.triangle.branch"
        }
    }
}

/// One row of the filter sheet's Date list.
///
/// **Three kinds, and Discord's own sheet offers exactly these** — Before,
/// After, During — over a calendar that picks a *day*, which is why every bound
/// lands on local midnight in the capture.
public enum MessageSearchDate: Hashable, Sendable {
    /// Sent before this day began.
    case before(Date)
    /// Sent on or after this day began.
    case after(Date)
    /// Sent on this day: both ends at once, which is the only clause that
    /// contributes a floor *and* a ceiling.
    case during(Date)

    public var day: Date {
        switch self {
        case .before(let date), .after(let date), .during(let date): date
        }
    }

    public var title: String {
        switch self {
        case .before: "Before"
        case .after: "After"
        case .during: "During"
        }
    }

    /// The field's keyword for this clause.
    public var keyword: String {
        switch self {
        case .before: "before"
        case .after: "after"
        case .during: "during"
        }
    }

    /// The window this clause opens, as local days.
    ///
    /// `during` is `[start of day, start of the next day)` — which is exactly
    /// the captured pair: `min_id` at 2026-09-06 00:00 local and `max_id` at
    /// 2026-09-07 00:00 local, one day apart.
    var lowerBound: Date? {
        switch self {
        case .before: nil
        case .after(let date), .during(let date): Calendar.current.startOfDay(for: date)
        }
    }

    var upperBound: Date? {
        switch self {
        case .after: nil
        case .before(let date): Calendar.current.startOfDay(for: date)
        case .during(let date):
            Calendar.current.date(
                byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date)
            )
        }
    }

    /// Replaces the day, keeping the kind — what the row's calendar does.
    public func withDay(_ day: Date) -> MessageSearchDate {
        switch self {
        case .before: .before(day)
        case .after: .after(day)
        case .during: .during(day)
        }
    }

    /// Replaces the kind, keeping the day — what the row's dropdown does.
    public func withKind(_ other: MessageSearchDate) -> MessageSearchDate {
        switch other {
        case .before: .before(day)
        case .after: .after(day)
        case .during: .during(day)
        }
    }
}

/// One search, complete.
///
/// A value rather than a pile of parameters because it is the thing the UI
/// edits, the thing the page is keyed on, and the thing a "search again" repeats
/// — and because `offset` moving must not be able to change anything else.
public struct MessageSearchQuery: Hashable, Sendable {
    public var scope: MessageSearchScope
    /// The text typed. Empty is legitimate: a search for "everything pinned by
    /// this person" is a real query with no words in it, and the capture makes
    /// exactly that request.
    public var content: String = ""

    // The filter sheet, field for field.
    public var authorIDs: [UserID] = []
    public var channelIDs: [ChannelID] = []
    public var mentionIDs: [UserID] = []
    public var has: Set<MessageSearchHas> = []
    public var authorKinds: Set<MessageSearchAuthorKind> = []
    public var isPinned: Bool?
    /// The date rows of the filter sheet, in the order they were added.
    ///
    /// **A list, because the sheet has "+ Add date"** — and they all collapse
    /// into the single `min_id`/`max_id` pair the route accepts. See
    /// `dateBounds`.
    public var dates: [MessageSearchDate] = []

    public var sort: MessageSearchSort = .timestamp
    public var order: MessageSearchOrder = .descending
    /// The tab on show. Part of the question — another tab is another page of
    /// answers — but not a filter: no badge counts it and Clear keeps it.
    public var tab: MessageSearchTab = .messages
    /// Which page, 1-based. Converted to `offset` at the boundary.
    public var page: Int = 1

    /// The `has` values the tab's request sends: the question's own when it
    /// has any, otherwise the tab's. Sorted, so one query is one request.
    public var tabHas: [MessageSearchHas] {
        let own = has.isEmpty ? Set(tab.has) : has
        return own.sorted { $0.rawValue < $1.rawValue }
    }

    public init(scope: MessageSearchScope) {
        self.scope = scope
    }

    // MARK: Paging

    /// **1–25, default 25** — the route's own ceiling, documented. Not a
    /// scroll-feel choice like `historyPageSize`: asking for more is refused.
    public static let pageSize = 25

    /// **9975, documented.** With a 25-message page that is exactly 400 pages,
    /// and it is the reason the page field is clamped rather than trusted: an
    /// offset past this is a 400, not an empty page.
    public static let maximumOffset = 9975

    /// The last page the route will serve, whatever the result count says.
    public static let maximumPage = maximumOffset / pageSize + 1

    public var offset: Int {
        min(max(page - 1, 0) * Self.pageSize, Self.maximumOffset)
    }

    /// Whether anything at all has been asked for.
    ///
    /// **A query with no text and no filters is not a search**, and sending it
    /// returns the channel's entire history one page at a time — which is a
    /// request nobody made and a page of results nobody can read.
    public var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && authorIDs.isEmpty && channelIDs.isEmpty && mentionIDs.isEmpty
            && has.isEmpty && authorKinds.isEmpty
            && isPinned == nil && dates.isEmpty
    }

    /// The one `(min_id, max_id)` window every date row narrows to.
    ///
    /// **N rows, one window** — the route has exactly two date parameters, so
    /// the sheet's list is an intersection rather than a set of alternatives.
    /// Two "before" rows keep the earlier ceiling; "during" contributes both
    /// ends at once. A pair that crosses over is left as it is and answers
    /// nothing, which is the honest result of asking for it.
    public var dateBounds: (after: Date?, before: Date?) {
        var lower: Date?
        var upper: Date?
        for clause in dates {
            if let start = clause.lowerBound {
                lower = lower.map { Swift.max($0, start) } ?? start
            }
            if let end = clause.upperBound {
                upper = upper.map { Swift.min($0, end) } ?? end
            }
        }
        return (lower, upper)
    }

    /// How many filter fields are set, for the "Filters (3)" badge.
    ///
    /// **Fields, not values.** Discord's own badge counts a field with four
    /// authors in it once, which is what somebody reading "Filters (2)" expects
    /// to find when they open the sheet.
    public var activeFilterCount: Int {
        var count = 0
        if !authorIDs.isEmpty { count += 1 }
        if !channelIDs.isEmpty { count += 1 }
        if !mentionIDs.isEmpty { count += 1 }
        if !has.isEmpty { count += 1 }
        if !authorKinds.isEmpty { count += 1 }
        if isPinned != nil { count += 1 }
        // The whole date list is one row of the sheet, however many clauses it
        // holds — the same "fields, not values" rule as the lists above.
        if !dates.isEmpty { count += 1 }
        return count
    }

    /// The same search on another page. Everything else is held still, which is
    /// the property that makes a page number mean what it says.
    public func onPage(_ page: Int) -> MessageSearchQuery {
        var next = self
        next.page = min(max(page, 1), Self.maximumPage)
        return next
    }

    /// The same query with `content` replaced by the field's raw text.
    ///
    /// **The draft holds what was typed, tokens and all**, because that is what
    /// the field shows; the resolved copy holds the words alone. One value with
    /// two readings would be a field that rewrites itself as you type.
    public func keepingText(_ text: String) -> MessageSearchQuery {
        var next = self
        next.content = text
        return next
    }

    /// Clears the filters and keeps the text, which is what "Clear Filters"
    /// means on a sheet that does not contain the search field.
    public func clearingFilters() -> MessageSearchQuery {
        var next = MessageSearchQuery(scope: scope)
        next.content = content
        next.sort = sort
        next.order = order
        next.tab = tab
        return next
    }
}

/// One page of an answer.
public struct MessageSearchPage: Hashable, Sendable {
    /// **Flattened.** The wire shape is `array[array[message]]` because the
    /// nested array once carried the messages either side of each hit — and the
    /// documentation now states outright that "surrounding context is no longer
    /// returned", which the capture confirms: every group holds exactly one
    /// message. Keeping the nesting would be modelling a feature the server
    /// stopped having.
    public var messages: [Message]
    /// **May be wrong, and the route says so**: "when messages are actively
    /// being created or deleted, the total_results field may not be accurate."
    /// It is what the page count is drawn from anyway — there is no other
    /// source — which is why the last page is a clamp rather than an assertion.
    public var totalResults: Int
    /// Whether the server is still back-filling this guild's index. Worth
    /// saying out loud: it is the honest explanation for a search that finds
    /// less than the reader knows is there.
    public var isDeepIndexing: Bool
    /// Whoever wrote the results.
    ///
    /// **They arrive with the page and they have to.** A hit is very often an
    /// old message in a channel this client never opened, written by somebody
    /// in no roster it holds — so without these the panel draws "Unknown" over
    /// a grey circle for most of its rows. The same reasoning as `MessagePage`.
    public var authors: [UserID: User]
    /// Every tab's total from the same request — empty when the answer came
    /// from the classic route, which counts only what it was asked.
    public var tabCounts: [MessageSearchTab: Int]

    public init(
        messages: [Message] = [],
        totalResults: Int = 0,
        isDeepIndexing: Bool = false,
        authors: [UserID: User] = [:],
        tabCounts: [MessageSearchTab: Int] = [:]
    ) {
        self.messages = messages
        self.totalResults = totalResults
        self.isDeepIndexing = isDeepIndexing
        self.authors = authors
        self.tabCounts = tabCounts
    }

    /// How many pages the route will serve for this answer.
    ///
    /// Clamped to `maximumPage`, because `total_results` regularly exceeds what
    /// `offset` can reach — 842 results is 34 pages, but 40,000 is 400 rather
    /// than 1,600, and offering the 1,600th is offering a 400.
    public var pageCount: Int {
        guard totalResults > 0 else { return 0 }
        let pages = (totalResults + MessageSearchQuery.pageSize - 1) / MessageSearchQuery.pageSize
        return min(pages, MessageSearchQuery.maximumPage)
    }
}

// MARK: - Dates as snowflakes

extension Snowflake {

    /// The id that stands for `date` on the search route.
    ///
    /// **The date filters are snowflake bounds, not dates.** The route has no
    /// `before`/`after` in wall-clock time at all: Discord's own filter sheet
    /// shows a calendar and sends `min_id` / `max_id`, because an id's high 42
    /// bits *are* a millisecond timestamp. This is the inverse of `timestamp`.
    ///
    /// **One function, not a floor and a ceiling — and that is the capture's
    /// answer rather than the obvious one.** The tempting design is a `min_id`
    /// with the low bits zeroed and a `max_id` with them all set, so that
    /// "before" includes everything sent during its final millisecond. Discord
    /// does not do that: both ids in `search messages1.har` have **all
    /// twenty-two low bits zero**
    ///
    /// ```
    /// max_id=1546626111897600000   low22 = 0   2026-09-07 00:00 local
    /// min_id=1546263724032000000   low22 = 0   2026-09-06 00:00 local
    /// ```
    ///
    /// and both land on **local midnight**, because the filter picks a day. So
    /// the bound is the first id of that millisecond in both directions, and a
    /// client that sent a ceiling with the low bits set would be sending an id
    /// Discord's own client never sends.
    public static func bound(for date: Date) -> Snowflake<Tag> {
        let unix = date.timeIntervalSince1970 * 1000
        // A date before Discord existed has no representable id, and letting the
        // subtraction wrap would produce an id far in the *future* — a filter
        // that silently matches nothing rather than everything before 2015.
        guard unix > Double(epochMilliseconds) else { return Snowflake(rawValue: 0) }
        return Snowflake(rawValue: (UInt64(unix) &- epochMilliseconds) << 22)
    }
}
