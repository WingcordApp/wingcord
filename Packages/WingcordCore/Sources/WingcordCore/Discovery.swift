import Foundation

// MARK: - Server discovery
//
// What `GET /discoverable-guilds` and `GET /discoverable-guilds/search` answer
// with. Both send the *same* guild shape and **two different envelopes**, which
// is the one trap in this pair — see `DiscoveryPage`.

/// A server the reader could join, as discovery describes it.
///
/// **Eleven fields, not the thirty the documentation lists.** `docs.discord.food`
/// documents the union of every route that answers a discoverable guild —
/// including `keywords`, `is_published`, `about` and `reasons_to_join`, which are
/// marked as coming only from the landing-page route. Both routes this client
/// calls send exactly the eleven below, on every hit, in `discoverchannels.har`.
/// Decoding for the rest would be decoding for a shape nothing here fetches.
///
/// **`features` is truncated by the search route and whole by the browse
/// route** — the same server came back with fifty-three features from
/// `/discoverable-guilds` and six from `/discoverable-guilds/search`. Documented,
/// and confirmed. So nothing may test a feature's *absence* on a value that came
/// from a search: `standing` reads the marks that are present and says nothing
/// about the ones that are not.
public struct DiscoverableGuild: Hashable, Sendable, Identifiable {
    public var id: GuildID
    public var name: String
    public var description: String?
    public var iconHash: String?
    public var bannerHash: String?
    public var splashHash: String?
    /// The wide artwork discovery cards are drawn on. Distinct from `splash`,
    /// which is the invite background, and very often the same hash — Marvel
    /// Rivals sends one value for both.
    public var discoverySplashHash: String?
    public var features: Set<String>
    public var memberCount: Int
    public var onlineCount: Int
    public var boostCount: Int

    public init(
        id: GuildID,
        name: String,
        description: String? = nil,
        iconHash: String? = nil,
        bannerHash: String? = nil,
        splashHash: String? = nil,
        discoverySplashHash: String? = nil,
        features: Set<String> = [],
        memberCount: Int = 0,
        onlineCount: Int = 0,
        boostCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.iconHash = iconHash
        self.bannerHash = bannerHash
        self.splashHash = splashHash
        self.discoverySplashHash = discoverySplashHash
        self.features = features
        self.memberCount = memberCount
        self.onlineCount = onlineCount
        self.boostCount = boostCount
    }

    /// Initials for a server with no icon.
    public var monogram: String {
        let letters = name.split(separator: " ").compactMap(\.first).prefix(2)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }

    /// The verified or partnered rosette, resolved the same way every other
    /// surface in this app resolves it.
    public var standing: GuildProfile.Standing? {
        GuildProfile.Standing(features: features)
    }

    /// Whether this server can be looked at before joining.
    ///
    /// **Checked rather than assumed.** Lurking needs `PREVIEW_ENABLED`, and a
    /// discoverable server does not always carry it — a card that opens a
    /// preview which the route then refuses is the inert control §5.5 forbids.
    /// The search route truncates `features` but keeps this one, which is why it
    /// is safe to read from either source.
    public var canPreview: Bool { features.contains("PREVIEW_ENABLED") }
}

/// One page of discovery results.
///
/// **Two envelopes answer this and they do not agree**, which is the whole
/// reason it is one type:
///
/// ```
/// GET /discoverable-guilds          → {"total": 6459, "guilds": […], "offset": 0, "limit": 30}
/// GET /discoverable-guilds/search   → {"guilds": […], "total_count": 332, "categories": […]}
/// ```
///
/// A decoder written for one and pointed at the other reads `total` as zero and
/// answers "no results" over a full page of them. Normalised here, once.
public struct DiscoveryPage: Hashable, Sendable {
    public var guilds: [DiscoverableGuild]
    /// How many match in total, across every page.
    public var total: Int
    /// How many results were skipped to produce this page. The browse route
    /// echoes it; the search route does not, so the caller's own offset stands.
    public var offset: Int
    /// How many servers match per category, for the query that produced this
    /// page. **Only the search route answers it, and only with
    /// `with_counts=true`** — which is a misleading name: it controls this
    /// facet, not the member counts, which are sent either way.
    ///
    /// The `-1` bucket is the total across all categories rather than a real
    /// category, so a reader that draws it as a chip draws a category that does
    /// not exist.
    public var counts: [Int: Int]

    public init(
        guilds: [DiscoverableGuild],
        total: Int,
        offset: Int = 0,
        counts: [Int: Int] = [:]
    ) {
        self.guilds = guilds
        self.total = total
        self.offset = offset
        self.counts = counts
    }

    public static let empty = DiscoveryPage(guilds: [], total: 0)

    /// The bucket that is a total rather than a category.
    public static let allCategoriesFacet = -1
}

/// One heading a server can be filed under.
///
/// **Forty-nine of them, seventeen of which are primary.** The split is the
/// whole reason `is_primary` is decoded: the primary set is a browsable list a
/// person can scan — Gaming, Music, Entertainment, Science & Tech — and the
/// other thirty-two are refinements like Theorycraft, LFG and Cryptocurrency
/// that a server picks *in addition*. A picker offering all forty-nine is a
/// picker nobody reads to the end of.
public struct DiscoveryCategory: Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    /// Whether a server may take this as its primary heading — and therefore
    /// whether it is worth offering as a way to browse.
    public var isPrimary: Bool

    public init(id: Int, name: String, isPrimary: Bool) {
        self.id = id
        self.name = name
        self.isPrimary = isPrimary
    }
}

// MARK: - The app directory
//
// Discovery's second half. The routes are `application-directory-static/*`,
// which this client already calls for the activity launcher — the difference is
// entirely in the query, and it is a real difference rather than a cosmetic one.
// See `DiscordREST.directoryApps`.

/// One heading in the app directory.
///
/// **Five of them, against server discovery's forty-nine**, and they are a
/// different space entirely — `6` is Games here and Education there. Its own
/// type for exactly that reason: one `Int` category id shared between the two
/// surfaces is a filter that silently answers the wrong list.
public struct AppDirectoryCategory: Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}
