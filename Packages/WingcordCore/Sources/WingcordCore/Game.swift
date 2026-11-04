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
    /// Discord's `GAME_DISABLED` (`game_flags` bit 0): a game whose profile
    /// Discord will not open, though it answers for it. Module `921138`.
    public var isProfileDisabled = false
    /// The servers Discord lists for this game — the profile's Communities tab,
    /// shown once there are three (`c82450…`'s `eM`). Ids only; the cards come
    /// from `GET /discoverable-guilds?guild_ids=…`.
    public var communityGuildIDs: [GuildID] = []
    /// The game's own application — its `linked_applications` entry of type
    /// `OFFICIAL` (2; `LINKED` is 1 and `NVIDIA` 3), Discord's
    /// `getOfficialApplicationId`. It is the application a reader links their
    /// in-game account through, which is what the profile's Link Account card
    /// offers for any game that has one.
    public var officialApplicationID: ApplicationID?
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
    /// What this game is called in everybody else's catalogue.
    ///
    /// **Most of these are not storefronts.** `igdb`, `opencritic`, `gop`,
    /// `gdco` and `sensortower` are reference databases; `xbox_title` is a
    /// title id rather than a product. Only two of the twenty-four Discord
    /// names have a page this client can send somebody to — see `GameStore` —
    /// and the rest are kept because dropping them would make the list a lie
    /// about what the route sent.
    public var thirdPartySkus: [GameSKU]
    /// Where the game is in its life on Steam, when Discord says.
    ///
    /// Only `/games` carries it — 511 entries across the captures on disk, and
    /// not one on `/applications/public`. It is read for exactly one decision:
    /// a retired game's store page is gone, so it is not offered.
    public var steamReleaseStatus: SteamReleaseStatus?

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
        themes: [String] = [],
        thirdPartySkus: [GameSKU] = [],
        steamReleaseStatus: SteamReleaseStatus? = nil
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
        self.thirdPartySkus = thirdPartySkus
        self.steamReleaseStatus = steamReleaseStatus
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

    /// The Steam address the `websites` list itself names, when it names one.
    ///
    /// Not the answer on its own — see `storeOffers`, which prefers it only
    /// where the SKUs are ambiguous.
    public var steamURL: URL? {
        websites.first { $0.category == .steam }?.url
    }

    /// Where somebody can go and get this game, in the order Discord offers
    /// them.
    ///
    /// **Two stores out of twenty-four distributors, and that is Discord's own
    /// list rather than a judgement.** Its `useStoreCTAs` holds exactly Xbox
    /// Game Pass and Steam, in that order, and takes the **first** SKU it sees
    /// for each. Everything else in `third_party_skus` is either a catalogue id
    /// (`igdb`, `opencritic`, `gop`, `gdco`, `sensortower`) or a storefront
    /// Discord declines to link — `playstation` is the commonest value in every
    /// capture on disk and has no button anywhere in the app.
    ///
    /// **The Steam address does not come from that first SKU**, and this is the
    /// one place this client knowingly does something better than the reference:
    /// Discord ships a second derivation, `useSteamStoreURL`, which prefers the
    /// `websites` link whenever a game has more than one Steam SKU — and then
    /// its own CTA path calls the raw builder instead and never consults it.
    /// The captures say the hook is right and the CTA is wrong. **Twenty games
    /// on disk carry more than one Steam SKU, all twenty carry a STEAM website,
    /// and in nine of them the first SKU names a different app than the website
    /// does** — War Thunder's first is 2054413 and the game is 236390, Apex
    /// Legends' is 1623570 and the game is 1172470, Rocket League's is 140146
    /// and the game is 252950. Taking the first sends the reader to a DLC page
    /// or a delisted listing about half the time. So: one SKU is authoritative,
    /// several are ambiguous and the website breaks the tie, and a game with no
    /// SKU at all still gets its website.
    ///
    /// A **retired** game keeps no Steam page, so it is offered none — also
    /// `useSteamStoreURL`'s rule, and the same instinct as `INVARIANTS.md` §5.5:
    /// a control that cannot work must not look like one that can.
    public var storeOffers: [GameStoreOffer] {
        [xboxGamePassOffer, steamStoreURL.map { GameStoreOffer(store: .steam, url: $0) }]
            .compactMap(\.self)
    }

    /// Game Pass, from its SKU. No second address to fall back on: Discord
    /// publishes no `websites` category for Game Pass, so the SKU is all there
    /// is.
    private var xboxGamePassOffer: GameStoreOffer? {
        skuIDs(from: "xbox_game_pass").first
            .flatMap { GameStore.xboxGamePass.url(sku: $0) }
            .map { GameStoreOffer(store: .xboxGamePass, url: $0) }
    }

    /// Where the game profile sends somebody to get or play this game, in
    /// Discord's order — its game profile's `lU`, a richer list than the
    /// activity card's two.
    ///
    /// **The `websites` list is the source**, filtered to the six categories
    /// Discord offers a button for: Epic Games, Steam, Roblox, Battle.net,
    /// Riot and Minecraft. Roblox's own "Roblox" and Valorant's "Play on Riot"
    /// are those rows, and the SKUs never name either store. Then, as Discord:
    ///
    /// - Epic only for the two games Discord names, and Steam never for a
    ///   retired one;
    /// - Steam from the SKUs where no website names it (`steamStoreURL`);
    /// - Steam first, the rest in the order the route sent them;
    /// - Xbox Game Pass ahead of everything, where the game carries its SKU.
    public var launchOffers: [GameStoreOffer] {
        var offers: [GameStoreOffer] = websites.compactMap { website in
            guard let store = GameStore(launchCategory: website.category) else { return nil }
            if store == .epicGames, !Self.epicLaunchGames.contains(id.rawValue) { return nil }
            if store == .steam, steamReleaseStatus == .retiredAbandoned { return nil }
            return GameStoreOffer(store: store, url: website.url)
        }
        if !offers.contains(where: { $0.store == .steam }), let steam = steamStoreURL {
            offers.append(GameStoreOffer(store: .steam, url: steam))
        }
        // Stable, as Discord's comparator is: Steam first, the rest untouched.
        offers = offers.filter { $0.store == .steam } + offers.filter { $0.store != .steam }
        if let pass = xboxGamePassOffer { offers.insert(pass, at: 0) }
        return offers
    }

    /// The only games whose Epic Games link the profile offers — Discord's own
    /// list (`lL` beside `lU`).
    static let epicLaunchGames: Set<UInt64> = [1_402_418_703_554_842_694, 356_877_880_938_070_016]

    /// Steam's address for this game, resolved the way Discord's own
    /// `useSteamStoreURL` resolves it. See `storeOffers`.
    public var steamStoreURL: URL? {
        guard steamReleaseStatus != .retiredAbandoned else { return nil }
        let skus = skuIDs(from: "steam")
        if skus.count > 1, let website = steamURL { return website }
        return skus.first.flatMap { GameStore.steam.url(sku: $0) } ?? steamURL
    }

    /// The non-empty ids filed under one distributor, in the order they arrived.
    ///
    /// **Empty ids are real.** Minecraft ships `{"distributor": "microsoft",
    /// "id": ""}` and two other games do the same for `origin` and `battlenet`;
    /// none of them is a store this client links, but an empty id pasted onto a
    /// store path is an address that opens a 404 rather than a page.
    private func skuIDs(from distributor: String) -> [String] {
        thirdPartySkus.compactMap { sku in
            sku.distributor == distributor && !sku.id.isEmpty ? sku.id : nil
        }
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

/// What one game is called somewhere that is not Discord.
///
/// `{"distributor": "steam", "id": "730"}` on `/games`, and the same object with
/// a third key on `/applications/public`: `sku`, which **equalled `id` in all
/// 1,036 entries that carry it** across every capture on disk, and which
/// `/games` omits from all 6,568 of its own. So there is one identifier here,
/// not two, and the route that sends it twice is sending it twice.
///
/// The distributor is the wire's own string rather than an enum. Discord's list
/// is twenty-four names long — `steam`, `battlenet`, `origin`, `eaplay`, `gog`,
/// `glyph`, `uplay`, `twitch`, `epic`, `discord`, `google_play`,
/// `apple_app_store`, `samsung_galaxy`, `microsoft`, `playstation`, `igdb`,
/// `roblox`, `xbox`, `xbox_title`, `xbox_game_pass`, `gop`, `gdco`,
/// `opencritic`, `sensortower` — and eighteen of them appear in the captures.
/// Typing all twenty-four would invite a store page per case, which is the
/// mistake `Game.storeOffers` exists to avoid: only two of them are places to
/// send somebody.
public struct GameSKU: Hashable, Sendable {
    public var distributor: String
    public var id: String

    public init(distributor: String, id: String) {
        self.distributor = distributor
        self.id = id
    }
}

/// Where the game is in its life on Steam.
///
/// Discord's own enum, numbers included. **An unrecognised value decodes to
/// nil**, which leaves the store link standing: only `retiredAbandoned`
/// suppresses it, and a number nobody has seen is not evidence that a page has
/// gone — §5.5's "where being wrong costs different amounts in each direction".
public enum SteamReleaseStatus: Int, Hashable, Sendable {
    case preRelease = 1
    case dayOfRelease = 2
    case postRelease = 3
    case retiredAbandoned = 4
    case childApp = 6
}

/// A storefront this client can send somebody to.
///
/// **Two, and they are Discord's two.** Read out of its `useStoreCTAs`, in its
/// order — Game Pass first, because a game somebody already subscribes to is a
/// better offer than one they have to buy.
public enum GameStore: String, Hashable, Sendable, CaseIterable {
    case xboxGamePass = "xbox_game_pass"
    case steam = "steam"
    /// The five below come only from a game's `websites`, for the game
    /// profile — see `Game.launchOffers`. `storeOffers` never names them.
    case epicGames = "epicgames"
    case roblox = "roblox"
    case battleNet = "battlenet"
    case riot = "riot"
    case minecraft = "minecraft"

    /// The store a `websites` row is a launch button for, or nil.
    init?(launchCategory category: GameLinkCategory) {
        switch category {
        case .steam: self = .steam
        case .epicGames: self = .epicGames
        case .roblox: self = .roblox
        case .battleNet: self = .battleNet
        case .riot: self = .riot
        case .minecraft: self = .minecraft
        default: return nil
        }
    }

    /// What the store is called, which is what a menu row says when there are
    /// two of them.
    public var title: String {
        switch self {
        case .steam: "Steam"
        case .xboxGamePass: "Xbox Game Pass"
        case .epicGames: "Epic Games"
        case .roblox: "Roblox"
        case .battleNet: "Battle.net"
        case .riot: "Riot Games"
        case .minecraft: "Minecraft"
        }
    }

    /// What the button says.
    ///
    /// Steam's is Discord's own string, and it is worth knowing that the string
    /// does not follow from anything else on the object: the analytics event
    /// beside it is `PRESS_PLAY_ON_STEAM_BUTTON` and the label is *Get on
    /// Steam*, so a label guessed from the event name would have been wrong.
    ///
    /// **Game Pass is deliberately not Discord's string**, which is *Play with
    /// Xbox Game Pass*. Discord can say that because its own client offers cloud
    /// play; this button opens a store page in a browser and nothing here plays
    /// anything, and a control that promises more than it does is the same fault
    /// `INVARIANTS.md` §5.5 is about. So both stores take the same construction
    /// and it is the one that is true of both.
    public var callToAction: String {
        switch self {
        case .steam: "Get on Steam"
        case .xboxGamePass: "Get on Xbox Game Pass"
        case .epicGames: "Get on Epic Games"
        case .roblox: "Get on Roblox"
        case .battleNet: "Get on Battle.net"
        // Discord's own words for this one: Riot's page is where a game of
        // theirs is played from.
        case .riot: "Play on Riot"
        case .minecraft: "Get on Minecraft"
        }
    }

    /// What the game profile's button says: Discord's own words there (its
    /// `lw`), which are the store's name — and Riot's, which is "Play".
    /// Short enough for two to sit side by side, as Discord sets them.
    public var profileLabel: String {
        self == .riot ? "Play" : title
    }

    /// What that button is read out as — Discord's own accessibility labels.
    public var profileAccessibilityLabel: String {
        switch self {
        case .steam: "Get Game on Steam"
        case .xboxGamePass: "Get Game on Xbox Game Pass"
        case .epicGames: "Get Game on Epic Games Store"
        case .roblox: "Get Game on Roblox"
        case .battleNet: "Get Game on Battle.net"
        case .riot: "Play on Riot"
        case .minecraft: "Get Game on Minecraft"
        }
    }

    /// The connection `type` whose brand mark names it — the same table the
    /// profile's connections and the game profile's links already draw from.
    /// Game Pass has no mark of its own and wears Xbox's, as it does in
    /// Discord.
    public var brandService: String {
        switch self {
        case .steam: "steam"
        case .xboxGamePass: "xbox"
        case .epicGames: "epicgames"
        case .roblox: "roblox"
        case .battleNet: "battlenet"
        case .riot: "riotgames"
        // No connection carries Minecraft's mark; the row falls back to its
        // symbol, as a link with no brand does.
        case .minecraft: "minecraft"
        }
    }

    /// The store page for one SKU.
    ///
    /// **Discord's builders with its referral tags taken off.** It appends
    /// `?ocid=discord7937464` to the Xbox address and sets `utm_source=discord`
    /// on whatever it opens; both are Discord's own attribution, and sending
    /// them from here would credit this client's traffic to somebody else.
    /// Measured: both addresses answer 200 without them.
    ///
    /// Nil for a store addressed only by a game's `websites` row.
    public func url(sku: String) -> URL? {
        let encoded = sku.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sku
        return switch self {
        case .steam: URL(string: "https://store.steampowered.com/app/\(encoded)")
        case .xboxGamePass: URL(string: "https://www.xbox.com/games/store/title/\(encoded)")
        case .epicGames, .roblox, .battleNet, .riot, .minecraft: nil
        }
    }
}

/// One store, and the address it is at for this game.
public struct GameStoreOffer: Hashable, Sendable, Identifiable {
    public var store: GameStore
    public var url: URL

    public var id: GameStore { store }

    public init(store: GameStore, url: URL) {
        self.store = store
        self.url = url
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

    /// Steam's three aggregates, of which a game may send one or all three.
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
    }

    /// One Steam line of the Reviews card.
    public struct SteamRow: Hashable, Sendable, Identifiable {
        public enum Window: Hashable, Sendable {
            /// The last thirty days.
            case recent
            /// Reviews written in English.
            case english
            /// Every review.
            case all
        }

        public var window: Window
        public var rating: Double?
        public var count: Int?

        public var id: Window { window }

        /// Discord's label — "Recent", "English", "All".
        public var title: String {
            switch window {
            case .recent: "Recent"
            case .english: "English"
            case .all: "All"
            }
        }

        public var verdict: SteamVerdict {
            SteamVerdict(rating: rating, count: count, isRecent: window == .recent)
        }

        /// The tooltip's sentence, in Discord's words; "No User Reviews" where
        /// there are none to describe.
        public var sentence: String {
            guard verdict != .noUserReviews, let rating, let count else { return verdict.title }
            let share = rating.formatted(.number.precision(.fractionLength(0...3)))
            let total = count.formatted(.number)
            return switch window {
            case .recent: "\(share)% of \(total) user reviews in the last 30 days are positive"
            case .english: "\(share)% of \(total) user reviews in English are positive"
            case .all: "\(share)% of \(total) user reviews are positive"
            }
        }
    }

    /// The Steam lines Discord's Reviews card draws, in its order (`lP`, chunk
    /// `464cd197…`) — given whether the game has a Steam page at all.
    ///
    /// **At most two, and never a third "Overall".** Recent comes first, and
    /// only when its verdict is a real one. The second line is English when
    /// there are enough English reviews to stand for the whole — two hundred of
    /// them out of at least two thousand — and every review otherwise; it is
    /// drawn whenever the game has a Steam page, saying "No User Reviews" if
    /// that is the answer. Both open the store page, so with no page there are
    /// none.
    public func steamRows(hasStorePage: Bool) -> [SteamRow] {
        guard hasStorePage else { return [] }
        var rows: [SteamRow] = []
        let recent = SteamRow(window: .recent, rating: steam?.recentRating, count: steam?.recentRatingCount)
        if recent.verdict != .noUserReviews { rows.append(recent) }
        if let steam, let english = steam.localizedRating, let englishCount = steam.localizedRatingCount,
           let total = steam.ratingCount, englishCount >= 200, total >= 2000 {
            rows.append(SteamRow(window: .english, rating: english, count: englishCount))
        } else {
            rows.append(SteamRow(window: .all, rating: steam?.rating, count: steam?.ratingCount))
        }
        return rows
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

        /// The ring is drawn only for a tiered game with a real average and a
        /// real count of critics behind it (`lL`).
        public var showsRing: Bool {
            tier != nil && (topCriticRating ?? -1) > 0 && (topCriticRatingCount ?? -1) > 0
        }

        /// Discord's "Not Enough Top Critic Reviews": no tier, and no average
        /// or no critics.
        public var lacksCritics: Bool {
            tier == nil && ((topCriticRating ?? -1) <= 0 || (topCriticRatingCount ?? -1) <= 0)
        }
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

    /// The ring's colour — Discord's own per tier (`lO`), not OpenCritic's.
    public var ringColorValue: UInt32 {
        switch self {
        case .mighty: 0xFC_43_0A
        case .strong: 0x9E_00_B4
        case .fair: 0x4A_A1_CE
        case .weak: 0x80_B0_6A
        }
    }

    /// OpenCritic's badge art for the tier, which Discord serves from its own
    /// CDN (`lM`) and draws at 32 points.
    public var badgeURL: URL? {
        let hash = switch self {
        case .mighty: "35c42952234dc88292af091e1f0a5eb2189dbe0e40253245f51637c4ff587173"
        case .strong: "8d450a540daa7b1a93e760d85891273058b41ed329141c86dae484c23817e0bb"
        case .fair: "9008eb4e7484a2c84cc11e8dff3831398fedd2de795ebf7c70436fd747bab475"
        case .weak: "1538fd1d5a67d65aebc33a9b47ab87cafbd83433f31f064f8deba3f89104ac8f"
        }
        return URL(string: "https://cdn.discordapp.com/assets/content/\(hash).png")
    }
}

/// Steam's wording for a review share — Discord's own derivation (`lb`, chunk
/// `464cd197…`), which is not quite Steam's published table.
///
/// **Volume decides as much as share.** Under ten reviews there is no verdict
/// at all; eighty per cent of forty is Positive and of four hundred is Very
/// Positive. **The recent window has its own floors**: it never says plain
/// Positive or Negative, and it reaches the Overwhelmingly verdicts at a
/// hundred reviews where every other window needs five hundred.
public enum SteamVerdict: Hashable, Sendable {
    case noUserReviews
    case overwhelminglyPositive
    case veryPositive
    case positive
    case mostlyPositive
    case mixed
    case mostlyNegative
    case negative
    case veryNegative
    case overwhelminglyNegative

    /// How the verdict is coloured: Discord's `steam-review-text-*` tokens.
    public enum Tone: Hashable, Sendable {
        case positive
        case mixed
        case negative
        /// "No User Reviews", in the subtle ink.
        case none
    }

    public init(rating: Double?, count: Int?, isRecent: Bool) {
        guard let rating, let count, count >= 10 else {
            self = .noUserReviews
            return
        }
        // Discord's `t < 50 * !n`: fifty for every window but the recent one,
        // where it is zero and so never true.
        let few = isRecent ? 0 : 50
        let many = isRecent ? 100 : 500
        if rating >= 80 {
            if count < few { self = .positive }
            else if count < many || rating < 95 { self = .veryPositive }
            else { self = .overwhelminglyPositive }
        } else if rating >= 70 {
            self = .mostlyPositive
        } else if rating >= 40 {
            self = .mixed
        } else if rating >= 20 {
            self = .mostlyNegative
        } else if count < few {
            self = .negative
        } else if count < many {
            self = .veryNegative
        } else {
            self = .overwhelminglyNegative
        }
    }

    public var title: String {
        switch self {
        case .noUserReviews: "No User Reviews"
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

    public var tone: Tone {
        switch self {
        case .noUserReviews: .none
        case .overwhelminglyPositive, .veryPositive, .positive, .mostlyPositive: .positive
        case .mixed: .mixed
        case .mostlyNegative, .negative, .veryNegative, .overwhelminglyNegative: .negative
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
