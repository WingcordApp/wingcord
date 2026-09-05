import Foundation

/// A game, as `GET /games` answers for one.
///
/// **A game is an application, and its id is an application id.** The same
/// snowflake names it in a profile widget, in a presence, in an invite's
/// `game_application_ids` and on `/applications/public` — so there is one id
/// type here and no separate `GameID`. What `/games` adds over an application is
/// everything a *store page* needs: artwork, genres, companies, ratings, review
/// aggregates and a popularity rank.
///
/// Every field is optional on the wire and most are absent for most games. The
/// game profile is built to draw whatever subset arrived: a game with no
/// screenshots shows no carousel, one with no `l30Rank` wears no rank badge, one
/// with no Discord website has no community card. Discord's own client does the
/// same, and the three captured profiles differ from each other in exactly those
/// ways.
public struct Game: Hashable, Sendable, Identifiable {
    public var id: ApplicationID
    public var name: String
    /// The store blurb. Often several sentences; never a title.
    public var summary: String?
    public var media: GameMedia
    /// IGDB's, in the order Discord sent them — which is the order they are
    /// printed under the title.
    public var genres: [GameGenre]
    public var platforms: [GamePlatform]
    public var websites: [GameWebsite]
    public var companies: [GameCompany]
    public var releaseDate: Date?
    public var reviews: GameReviews?
    /// Where OpenCritic's own page is, when there is one to open.
    public var openCriticURL: URL?
    /// Popularity over a rolling thirty days. Absent for most games, and its
    /// absence is what decides whether the rank badge is drawn at all.
    public var globalRank: Int?
    public var screenshotURLs: [URL]
    /// Screenshots Discord hosts itself rather than proxying. Resolved through
    /// `CDN.gameScreenshot`.
    public var screenshotHashes: [String]
    public var trailers: [GameTrailer]
    /// Free-text themes, already localised by the server — `"Action"`,
    /// `"Science fiction"`. **Strings on the wire, not the documented integer
    /// enum**, in every captured response.
    public var themes: [String]

    public init(
        id: ApplicationID,
        name: String,
        summary: String? = nil,
        media: GameMedia = GameMedia(),
        genres: [GameGenre] = [],
        platforms: [GamePlatform] = [],
        websites: [GameWebsite] = [],
        companies: [GameCompany] = [],
        releaseDate: Date? = nil,
        reviews: GameReviews? = nil,
        openCriticURL: URL? = nil,
        globalRank: Int? = nil,
        screenshotURLs: [URL] = [],
        screenshotHashes: [String] = [],
        trailers: [GameTrailer] = [],
        themes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary.flatMap { $0.isEmpty ? nil : $0 }
        self.media = media
        self.genres = genres
        self.platforms = platforms
        self.websites = websites
        self.companies = companies
        self.releaseDate = releaseDate
        self.reviews = reviews
        self.openCriticURL = openCriticURL
        self.globalRank = globalRank
        self.screenshotURLs = screenshotURLs
        self.screenshotHashes = screenshotHashes
        self.trailers = trailers
        self.themes = themes
    }

    /// The genres, printed the way the header prints them.
    public var genreLine: String {
        genres.map(\.title).joined(separator: ", ")
    }

    /// The companies that published it.
    ///
    /// A company can hold both roles — Beat Games publishes *and* develops Beat
    /// Saber — so these two lists overlap rather than partition, and both rows
    /// are drawn.
    public var publishers: [String] {
        companies.filter { $0.roles.contains(.publisher) }.map(\.name)
    }

    public var developers: [String] {
        companies.filter { $0.roles.contains(.developer) }.map(\.name)
    }

    /// The invite code for the game's own Discord, or nil when it has none.
    ///
    /// **This is the whole of how the community card is gated.** Beat Saber has
    /// no `DISCORD` website and draws no card; The Sims has `discord.com/invite/
    /// thesims` and draws one. There is no separate route that answers "does
    /// this game have a server" — the link is the answer.
    public var communityInviteCode: String? {
        websites.first { $0.category == .discord }?.inviteCode
    }

    /// Where the game is sold on Steam, when it is.
    public var steamURL: URL? {
        websites.first { $0.category == .steam }?.url
    }

    /// The links the profile prints as a row of marks.
    ///
    /// **The store and reference links are deliberately not here.** Steam has
    /// its own button above the fold and Discord has its own card; a wiki entry
    /// is not somewhere the game speaks from. What is left is the set the three
    /// captures actually draw — the official site and the social accounts — and
    /// each of those has a brand mark, so the row reads as marks rather than as
    /// a line of identical globes.
    public var socialLinks: [GameWebsite] {
        websites.filter(\.category.isSocialLink)
    }
}

/// Where a game's pictures are.
///
/// **Two representations for one idea, and Discord mixes them within a single
/// response.** `media.cover` arrives as `{"type": "hash"}` for Arknights and
/// `{"type": "url"}` for Wuthering Waves, in the same array. So each slot is a
/// `GameMediaRef` that knows which it is, and the caller resolves it once
/// through `CDN.gameAsset` rather than every call site guessing.
public struct GameMedia: Hashable, Sendable {
    /// The square icon — the cover art on a widget tile and beside the title.
    public var icon: GameMediaRef?
    /// The wide artwork behind the profile header.
    public var banner: GameMediaRef?
    /// The portrait store cover.
    public var cover: GameMediaRef?
    /// Every artwork, banner included. The header takes the first.
    public var artwork: [GameMediaRef]

    public init(
        icon: GameMediaRef? = nil,
        banner: GameMediaRef? = nil,
        cover: GameMediaRef? = nil,
        artwork: [GameMediaRef] = []
    ) {
        self.icon = icon
        self.banner = banner
        self.cover = cover
        self.artwork = artwork
    }
}

/// One picture, named either by a hash on Discord's CDN or by a whole URL.
public enum GameMediaRef: Hashable, Sendable {
    case hash(String)
    case url(URL)
}

/// A link off a game's profile.
public struct GameWebsite: Hashable, Sendable, Identifiable {
    public var url: URL
    public var category: GameLinkCategory

    public var id: URL { url }

    public init(url: URL, category: GameLinkCategory) {
        self.url = url
        self.category = category
    }

    /// The invite code, for a `DISCORD` link.
    ///
    /// Discord writes these three ways — `discord.gg/x`, `discord.com/invite/x`
    /// and either with a `?proof=` query — so the code is the last path
    /// component and the query is dropped. Wuthering Waves' link carries the
    /// proof; The Sims' does not.
    public var inviteCode: String? {
        guard category == .discord else { return nil }
        let code = url.lastPathComponent
        return code.isEmpty || code == "/" ? nil : code
    }
}

/// What kind of place a game's link goes to.
public enum GameLinkCategory: Int, Hashable, Sendable {
    case official = 1
    case wikia = 2
    case wikipedia = 3
    case facebook = 4
    case twitter = 5
    case twitch = 6
    case instagram = 8
    case youtube = 9
    case iphone = 10
    case ipad = 11
    case android = 12
    case steam = 13
    case reddit = 14
    case itch = 15
    case epicGames = 16
    case gog = 17
    case discord = 18
    case bluesky = 19
    case battleNet = 20
    case riot = 21
    case roblox = 22
    case minecraft = 23

    /// Whether it belongs in the profile's links row. See `Game.socialLinks`.
    public var isSocialLink: Bool {
        switch self {
        case .official, .facebook, .twitter, .twitch, .instagram, .youtube,
             .reddit, .bluesky:
            true
        default:
            false
        }
    }

    /// The connection `type` whose brand mark names this link, or nil where the
    /// app has no mark and the row falls back to a symbol.
    ///
    /// Reusing the connection table rather than starting a second one: these are
    /// the same brands a profile already draws under Connections, and two tables
    /// is how Twitch ends up purple in one place and grey in another.
    public var brandService: String? {
        switch self {
        case .facebook: "facebook"
        case .twitter: "twitter"
        case .twitch: "twitch"
        case .instagram: "instagram"
        case .youtube: "youtube"
        case .reddit: "reddit"
        case .bluesky: "bluesky"
        case .steam: "steam"
        case .epicGames: "epicgames"
        case .roblox: "roblox"
        case .battleNet: "battlenet"
        case .riot: "riotgames"
        // `official` is a website rather than a brand and takes the same
        // treatment a `domain` connection does.
        case .official: "domain"
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .official: "Official site"
        case .wikia: "Fandom"
        case .wikipedia: "Wikipedia"
        case .facebook: "Facebook"
        case .twitter: "X"
        case .twitch: "Twitch"
        case .instagram: "Instagram"
        case .youtube: "YouTube"
        case .iphone: "App Store"
        case .ipad: "App Store"
        case .android: "Google Play"
        case .steam: "Steam"
        case .reddit: "Reddit"
        case .itch: "itch.io"
        case .epicGames: "Epic Games Store"
        case .gog: "GOG"
        case .discord: "Discord"
        case .bluesky: "Bluesky"
        case .battleNet: "Battle.net"
        case .riot: "Riot Games"
        case .roblox: "Roblox"
        case .minecraft: "Minecraft"
        }
    }
}

/// A studio or publisher, and what it did.
public struct GameCompany: Hashable, Sendable, Identifiable {
    public var name: String
    public var roles: Set<GameCompanyRole>

    public var id: String { name }

    public init(name: String, roles: Set<GameCompanyRole>) {
        self.name = name
        self.roles = roles
    }
}

/// **Not in the published enum — read off three live responses.** Electronic
/// Arts carries `[1]` and is credited as The Sims 4's publisher; The Sims Studio
/// and Maxis carry `[2]` and are credited as its developers; Beat Games carries
/// `[1, 2]` and is credited as both. A role outside the pair keeps its number
/// and is credited nowhere, which is the honest treatment for a value nothing
/// has seen.
public enum GameCompanyRole: Hashable, Sendable {
    case publisher
    case developer
    case other(Int)

    public init(rawValue: Int) {
        switch rawValue {
        case 1: self = .publisher
        case 2: self = .developer
        default: self = .other(rawValue)
        }
    }
}

/// What critics and players made of it.
public struct GameReviews: Hashable, Sendable {
    public var steam: SteamReviews?
    public var openCritic: OpenCriticReviews?

    public init(steam: SteamReviews? = nil, openCritic: OpenCriticReviews? = nil) {
        self.steam = steam
        self.openCritic = openCritic
    }

    public var isEmpty: Bool { steam == nil && openCritic == nil }

    /// Steam's three aggregates, of which a game may have one or all three.
    ///
    /// **Which rows the profile draws is decided here and not by a layout.** The
    /// Sims sends all-time, recent and locale figures and shows two rows —
    /// "Recent Reviews" and "English Reviews"; Beat Saber sends only the
    /// all-time pair and shows one — "All Reviews". So a row exists exactly when
    /// its count arrived.
    public struct SteamReviews: Hashable, Sendable {
        /// Positive share, 0–100. **Documented as 0–1 and sent as 0–100** in
        /// every captured response; the wire wins.
        public var rating: Double?
        public var ratingCount: Int?
        public var recentRating: Double?
        public var recentRatingCount: Int?
        public var localizedRating: Double?
        public var localizedRatingCount: Int?

        public init(
            rating: Double? = nil,
            ratingCount: Int? = nil,
            recentRating: Double? = nil,
            recentRatingCount: Int? = nil,
            localizedRating: Double? = nil,
            localizedRatingCount: Int? = nil
        ) {
            self.rating = rating
            self.ratingCount = ratingCount
            self.recentRating = recentRating
            self.recentRatingCount = recentRatingCount
            self.localizedRating = localizedRating
            self.localizedRatingCount = localizedRatingCount
        }

        /// The rows to draw, in Discord's order: recent, then locale, then
        /// all-time — and all-time is titled "All Reviews" only when it is the
        /// only one, because a page showing three rows names the third
        /// "Overall".
        public var rows: [Row] {
            var rows: [Row] = []
            if let rating = recentRating, let count = recentRatingCount {
                rows.append(Row(title: "Recent Reviews", rating: rating, count: count))
            }
            if let rating = localizedRating, let count = localizedRatingCount {
                rows.append(Row(title: "English Reviews", rating: rating, count: count))
            }
            if let rating, let count = ratingCount {
                let title = rows.isEmpty ? "All Reviews" : "Overall"
                rows.append(Row(title: title, rating: rating, count: count))
            }
            return rows
        }

        public struct Row: Hashable, Sendable, Identifiable {
            public var title: String
            /// 0–100.
            public var rating: Double
            public var count: Int

            public var id: String { title }

            /// Steam's own wording for this share and volume.
            public var verdict: SteamVerdict {
                SteamVerdict(rating: rating, count: count)
            }
        }
    }

    public struct OpenCriticReviews: Hashable, Sendable {
        /// The top-critic average. **Truncated, never rounded**, when printed:
        /// The Sims' 69.969 is shown as 69 and Beat Saber's 85.926 as 85 in
        /// Discord's own client, and rounding would print 70 and 86.
        public var topCriticRating: Double?
        public var topCriticRatingCount: Int?
        public var tier: OpenCriticTier?

        public init(
            topCriticRating: Double? = nil,
            topCriticRatingCount: Int? = nil,
            tier: OpenCriticTier? = nil
        ) {
            self.topCriticRating = topCriticRating
            self.topCriticRatingCount = topCriticRatingCount
            self.tier = tier
        }

        public var score: Int? { topCriticRating.map { Int($0) } }
    }
}

/// OpenCritic's badge for a game.
public enum OpenCriticTier: Int, Hashable, Sendable {
    case mighty = 1
    case strong = 2
    case fair = 3
    case weak = 4

    public var title: String {
        switch self {
        case .mighty: "Mighty"
        case .strong: "Strong"
        case .fair: "Fair"
        case .weak: "Weak"
        }
    }

    /// The tier's own colour, as OpenCritic prints it.
    public var colorValue: UInt32 {
        switch self {
        case .mighty: 0xFC_4F_28
        case .strong: 0xB4_39_C8
        case .fair: 0x40_9B_E8
        case .weak: 0x91_92_98
        }
    }
}

/// Steam's wording for a review share.
///
/// The thresholds are Steam's published ones and they are volume-dependent,
/// which is not a detail that can be dropped: eighty per cent of thirty reviews
/// is "Positive" and eighty per cent of thirty thousand is "Very Positive".
/// Checked against all three captures — 96%/69,711 is Overwhelmingly Positive,
/// 86%/106,026 and 80%/1,717 are both Very Positive.
public enum SteamVerdict: Hashable, Sendable {
    case overwhelminglyPositive
    case veryPositive
    case positive
    case mostlyPositive
    case mixed
    case mostlyNegative
    case negative
    case veryNegative
    case overwhelminglyNegative

    public init(rating: Double, count: Int) {
        switch rating {
        case 95...:
            self = count >= 500 ? .overwhelminglyPositive : .veryPositive
        case 80..<95:
            self = count >= 50 ? .veryPositive : .positive
        case 70..<80:
            self = .mostlyPositive
        case 40..<70:
            self = .mixed
        case 20..<40:
            self = .mostlyNegative
        default:
            if count >= 500 { self = .overwhelminglyNegative }
            else if count >= 50 { self = .veryNegative }
            else { self = .negative }
        }
    }

    public var title: String {
        switch self {
        case .overwhelminglyPositive: "Overwhelmingly Positive"
        case .veryPositive: "Very Positive"
        case .positive: "Positive"
        case .mostlyPositive: "Mostly Positive"
        case .mixed: "Mixed"
        case .mostlyNegative: "Mostly Negative"
        case .negative: "Negative"
        case .veryNegative: "Very Negative"
        case .overwhelminglyNegative: "Overwhelmingly Negative"
        }
    }

    /// Steam's own three-way colouring: blue for positive, grey-gold for mixed,
    /// red for negative.
    public var colorValue: UInt32 {
        switch self {
        case .overwhelminglyPositive, .veryPositive, .positive, .mostlyPositive:
            0x66_C0_F4
        case .mixed:
            0xB9_A0_6D
        case .mostlyNegative, .negative, .veryNegative, .overwhelminglyNegative:
            0xC1_5C_5C
        }
    }
}

/// Where a game runs.
///
/// **Five values, and three of them collapse.** Discord's own client draws one
/// monitor for `DESKTOP`, `LINUX` and `MACOS` together — measured on The Sims,
/// which carries `[0, 1, 2, 7]` and shows three marks — and draws nothing at all
/// for `IOS` and `ANDROID`, measured on Arknights, which carries `[0, 2, 3, 4]`
/// and shows two. So the enum keeps every value the wire can send and
/// `displayGroup` is what the row deduplicates by.
public enum GamePlatform: Int, Hashable, Sendable, CaseIterable {
    case desktop = 0
    case xbox = 1
    case playStation = 2
    case iOS = 3
    case android = 4
    case nintendo = 5
    case linux = 6
    case macOS = 7

    /// What the platforms row draws this as, or nil for one it draws nothing
    /// for.
    public var displayGroup: DisplayGroup? {
        switch self {
        case .desktop, .linux, .macOS: .desktop
        case .xbox: .xbox
        case .playStation: .playStation
        case .nintendo: .nintendo
        case .iOS, .android: nil
        }
    }

    public enum DisplayGroup: Hashable, Sendable, CaseIterable {
        case desktop
        case xbox
        case playStation
        case nintendo

        public var symbolName: String {
            switch self {
            case .desktop: "desktopcomputer"
            case .xbox: "xbox.logo"
            case .playStation: "playstation.logo"
            case .nintendo: "gamecontroller"
            }
        }

        public var title: String {
            switch self {
            case .desktop: "Desktop"
            case .xbox: "Xbox"
            case .playStation: "PlayStation"
            case .nintendo: "Nintendo Switch"
            }
        }
    }

    /// The groups for a set of platforms, deduplicated and in a stable order.
    public static func displayGroups(of platforms: [GamePlatform]) -> [DisplayGroup] {
        var seen = Set<DisplayGroup>()
        var result: [DisplayGroup] = []
        for platform in platforms {
            guard let group = platform.displayGroup, seen.insert(group).inserted else {
                continue
            }
            result.append(group)
        }
        return result
    }
}

/// A trailer, as a store asset on Discord's own CDN.
public struct GameTrailer: Hashable, Sendable, Identifiable {
    public var id: String
    public var applicationID: ApplicationID
    public var width: Int?
    public var height: Int?
    public var mimeType: String?

    public init(
        id: String,
        applicationID: ApplicationID,
        width: Int? = nil,
        height: Int? = nil,
        mimeType: String? = nil
    ) {
        self.id = id
        self.applicationID = applicationID
        self.width = width
        self.height = height
        self.mimeType = mimeType
    }
}
