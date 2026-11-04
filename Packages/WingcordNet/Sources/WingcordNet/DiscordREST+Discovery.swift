import Foundation
import WingcordCore

// Discovery — finding a server, or an app, that the account is not in yet.
//
// **Captured**, `discoverchannels.har` (servers, every category plus a search
// for "marvel" with the filters played with), `discoverableapps.har` (the app
// directory) and `join discoverable server.har` (a card pressed through to a
// join). Three facts in those the documentation does not carry, and each one
// changes what a client must do:
//
//  1. **The browse route's plain pagination is a SHORTLIST.** `docs.discord.food`
//     says it: paginated normally, only verified or partnered guilds come back.
//     The captured first page is Marvel Rivals, Fortnite, Genshin — 6,459 of
//     them, all official. Every other discoverable server is reachable only
//     through a category or a search. A client that browsed the plain list and
//     stopped would look finished and be showing about a twentieth of discovery.
//  2. **A category still paginates.** The reference client sends `categories=1`
//     with no `limit` or `offset` and the route defaults to 30 and 0 — the
//     documented "pagination is ignored" applies to `guild_ids` and
//     `application_ids`, not to this.
//  3. **The two routes answer different envelopes.** See `DiscoveryPage`.

extension DiscordREST {

    // MARK: Servers

    /// How many servers a page holds. The reference client's own — 30 for the
    /// browse, 12 for the search, and both are echoed back in the envelope.
    public static let discoveryPageSize = 30
    public static let discoverySearchPageSize = 12

    /// A page of discoverable servers.
    ///
    /// - Parameter categoryID: nil for the front page, which is the verified and
    ///   partnered shortlist described above. Any other value is a real browse
    ///   of everything filed under that heading.
    public func discoverableGuilds(
        categoryID: Int? = nil,
        limit: Int = discoveryPageSize,
        offset: Int = 0
    ) async throws -> DiscoveryPage {
        var query = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        // **Repeated keys, not a comma-joined value.** The parameter is an array
        // and the capture sends one key per id; a comma-joined value is accepted
        // and matches nothing, which is the same trap message search has.
        if let categoryID { query.append(URLQueryItem(name: "categories", value: String(categoryID))) }
        return try await get(
            "/discoverable-guilds",
            route: "discoverable-guilds",
            query: query,
            as: DiscoverBrowseDTO.self
        ).domain
    }

    /// Named servers, as discovery describes them — a game profile's
    /// Communities (`c82450…`'s `tl`: `GET /discoverable-guilds` with
    /// `guild_ids`, the answer's `guilds`).
    ///
    /// **One key per id**, as the browse's `categories` is, and pagination is
    /// ignored for `guild_ids` (the docs, and point 2 above) — so one request
    /// carries the whole list.
    public func discoverableGuilds(ids: [GuildID]) async throws -> [DiscoverableGuild] {
        guard !ids.isEmpty else { return [] }
        return try await get(
            "/discoverable-guilds",
            route: "discoverable-guilds",
            query: ids.map { URLQueryItem(name: "guild_ids", value: String($0.rawValue)) },
            as: DiscoverBrowseDTO.self
        ).domain.guilds
    }

    /// Servers matching what somebody typed.
    ///
    /// **A proxy for Algolia, and the only search there is.** Discord revoked the
    /// public Algolia credentials in December 2024, so the index cannot be
    /// reached directly any more; this route is what is left.
    ///
    /// It carries three immutable filters the caller cannot lift —
    /// `approximate_member_count > 200`, `approximate_presence_count > 0`, and
    /// `auto_removed: false` — so a small server is unfindable here by design and
    /// an empty answer is not necessarily a wrong query.
    ///
    /// - Parameter wantsCounts: asks for the per-category facet. **The name is
    ///   Discord's and it is misleading**: member counts come back either way,
    ///   and what this controls is `DiscoveryPage.counts`. The reference client
    ///   asks for it once per query and drops it for every refinement of that
    ///   query, which is what the default mirrors.
    ///
    /// **Both filters are captured, in one order, and they compose.**
    /// `Show filters.har` walks the facet a bucket at a time and
    /// `HAR language code and category_id.har` walks three languages and then
    /// two categories on top of the last of them:
    ///
    /// ```
    /// search?query=hey&offset=0&limit=12&with_counts=true                       ← the facet
    /// search?query=hey&category_id=1&offset=0&limit=12&with_counts=false        ← a bucket
    /// search?query=mid&offset=0&limit=12&language_code=en-US&with_counts=false  ← a language
    /// search?query=mid&category_id=3&offset=0&limit=12&language_code=en-US&…    ← both
    /// ```
    ///
    /// The keys go out in that order — `query`, `category_id`, `offset`,
    /// `limit`, `language_code`, `with_counts` — which is why `category_id` is
    /// appended before the paging rather than after it.
    public func searchDiscoverableGuilds(
        query text: String,
        categoryID: Int? = nil,
        languageCode: String? = nil,
        limit: Int = discoverySearchPageSize,
        offset: Int = 0,
        wantsCounts: Bool = true
    ) async throws -> DiscoveryPage {
        var query = [URLQueryItem(name: "query", value: text)]
        if let categoryID {
            query.append(URLQueryItem(name: "category_id", value: String(categoryID)))
        }
        query.append(URLQueryItem(name: "offset", value: String(offset)))
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        // Undocumented and captured: the reference client re-runs the same query
        // per language when the reader picks one, with the facet turned off.
        if let languageCode {
            query.append(URLQueryItem(name: "language_code", value: languageCode))
        }
        query.append(URLQueryItem(name: "with_counts", value: wantsCounts ? "true" : "false"))

        var page = try await get(
            "/discoverable-guilds/search",
            route: "discoverable-guilds/search",
            query: query,
            as: DiscoverSearchDTO.self
        ).domain
        // The search envelope carries no offset of its own, so the caller's
        // stands — without this a second page reports itself as the first.
        page.offset = offset
        return page
    }

    /// Every heading a server can be filed under.
    ///
    /// Fetched whole rather than `primary_only=true`: the seventeen primary ones
    /// are what a picker offers, and the other thirty-two are still needed to
    /// *name* a category a search facet comes back with.
    public func discoveryCategories(locale: String) async throws -> [DiscoveryCategory] {
        try await get(
            "/discovery/categories",
            route: "discovery/categories",
            query: [
                URLQueryItem(name: "locale", value: locale),
                URLQueryItem(name: "primary_only", value: "false"),
            ],
            as: [DiscoveryCategoryDTO].self
        ).compactMap(\.domain)
    }

    // MARK: Apps

    /// The app directory's five headings.
    ///
    /// A different id space from `discoveryCategories` — see
    /// `AppDirectoryCategory`.
    public func appDirectoryCategories(locale: String) async throws -> [AppDirectoryCategory] {
        try await get(
            "/application-directory-static/categories",
            route: "application-directory-static/categories",
            query: [URLQueryItem(name: "locale", value: locale)],
            as: [AppCategoryDTO].self
        ).compactMap(\.domain)
    }

    /// A page of the app directory.
    ///
    /// **The same route as the activity launcher's search, and deliberately not
    /// the same query.** `searchActivities` sends five filter flags that narrow
    /// the answer to apps which can be *used from a message box* — installed
    /// commands, no custom install URL, embedded apps only with an entry point.
    /// That is correct there and wrong here: this is a directory, and a bot with
    /// a custom install URL is a real entry in it. The captured browse sends
    /// none of those flags and `source=0` where the launcher sends `1`.
    ///
    /// Browsing a category is a search with an **empty** query — that is how the
    /// reference client draws every category grid, and it is why one function
    /// serves both.
    public func directoryApps(
        query text: String = "",
        categoryID: Int? = nil,
        page: Int = 1,
        pageSize: Int = 48,
        locale: String
    ) async throws -> ActivitySearchPage {
        var query = [
            URLQueryItem(name: "query", value: text),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "locale", value: locale),
            URLQueryItem(name: "source", value: "0"),
        ]
        if let categoryID {
            query.append(URLQueryItem(name: "category_id", value: String(categoryID)))
        }
        let dto = try await get(
            "/application-directory-static/search",
            route: "application-directory-static/search",
            query: query,
            as: SearchDTO.self
        )
        return ActivitySearchPage(
            apps: (dto.results ?? []).compactMap { $0.data?.domain },
            page: page,
            pageCount: dto.num_pages ?? 1,
            totalCount: dto.result_count ?? 0
        )
    }
}

// MARK: - Wire types

/// `GET /discoverable-guilds`.
struct DiscoverBrowseDTO: Decodable, Sendable {
    var guilds: [DiscoverableGuildDTO]?
    var total: Int?
    var offset: Int?

    var domain: DiscoveryPage {
        DiscoveryPage(
            guilds: (guilds ?? []).compactMap(\.domain),
            total: total ?? 0,
            offset: offset ?? 0
        )
    }
}

/// `GET /discoverable-guilds/search`. Same guilds, different envelope.
struct DiscoverSearchDTO: Decodable, Sendable {
    var guilds: [DiscoverableGuildDTO]?
    var total_count: Int?
    var categories: [FacetDTO]?

    /// **The facet's id is a STRING here** where every other category id on this
    /// surface is an integer. Parsed rather than trusted: a bucket whose id will
    /// not parse is dropped, which costs one chip rather than the whole facet.
    struct FacetDTO: Decodable, Sendable {
        var id: String?
        var count: Int?
    }

    var domain: DiscoveryPage {
        var counts: [Int: Int] = [:]
        for facet in categories ?? [] {
            guard let id = facet.id.flatMap(Int.init), let count = facet.count else { continue }
            counts[id] = count
        }
        return DiscoveryPage(
            guilds: (guilds ?? []).compactMap(\.domain),
            total: total_count ?? 0,
            counts: counts
        )
    }
}

struct DiscoverableGuildDTO: Decodable, Sendable {
    var id: GuildID?
    var name: String?
    var description: String?
    var icon: String?
    var banner: String?
    var splash: String?
    var discovery_splash: String?
    var features: [String]?
    var approximate_member_count: Int?
    var approximate_presence_count: Int?
    var premium_subscription_count: Int?
    var preferred_locale: String?

    var domain: DiscoverableGuild? {
        guard let id, let name, !name.isEmpty else { return nil }
        return DiscoverableGuild(
            id: id,
            name: name,
            // An empty description is what a server with none sends, and it is
            // the same absence as a missing key — collapsed here so no surface
            // has to draw a card with a blank line reserved in it.
            description: (description?.isEmpty ?? true) ? nil : description,
            iconHash: icon,
            bannerHash: banner,
            splashHash: splash,
            discoverySplashHash: discovery_splash,
            features: Set(features ?? []),
            memberCount: approximate_member_count ?? 0,
            onlineCount: approximate_presence_count ?? 0,
            boostCount: premium_subscription_count ?? 0,
            preferredLocale: (preferred_locale?.isEmpty ?? true) ? nil : preferred_locale
        )
    }
}

struct DiscoveryCategoryDTO: Decodable, Sendable {
    var id: Int?
    var name: String?
    var is_primary: Bool?

    var domain: DiscoveryCategory? {
        guard let id, let name, !name.isEmpty else { return nil }
        return DiscoveryCategory(id: id, name: name, isPrimary: is_primary ?? false)
    }
}

struct AppCategoryDTO: Decodable, Sendable {
    var id: Int?
    var name: String?

    var domain: AppDirectoryCategory? {
        guard let id, let name, !name.isEmpty else { return nil }
        return AppDirectoryCategory(id: id, name: name)
    }
}
