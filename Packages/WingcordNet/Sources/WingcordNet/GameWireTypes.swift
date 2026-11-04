import Foundation
import WingcordCore

/// One entry of `GET /games?game_ids=…`.
///
/// The route answers with an array of these — a superset of the detectable
/// application, which is why it also carries `executables` and `overlay*`
/// fields. None of those are read: this client does not detect running games,
/// and decoding a field nothing draws is work with no reader.
struct GameDTO: Decodable, Sendable {
    var id: ApplicationID?
    var name: String?
    var description: String?
    var icon_hash: String?
    var banner_hash: String?
    var media: MediaDTO?
    var genres: [Int]?
    var platforms: [Int]?
    var websites: [WebsiteDTO]?
    var companies: [CompanyDTO]?
    var first_release_date: String?
    var screenshot_urls: [String]?
    var screenshot_hashes: [String]?
    var trailers: [TrailerDTO]?
    var themes: [String]?
    var reviews: ReviewsDTO?
    var opencritic_url: String?
    var l30_rank: Int?
    var community_guild_ids: [GuildID]?
    var game_flags: Int?
    var linked_applications: [LinkedApplicationDTO]?
    var third_party_skus: [SKUDTO]?

    struct LinkedApplicationDTO: Decodable, Sendable {
        var id: ApplicationID?
        var type: Int?
    }
    /// Discord's `SteamReleaseStatus`. Only this route sends it — the same
    /// field is absent from every `/applications/public` body on disk, which is
    /// why the store offer is resolved from the game record and not from the
    /// application.
    var steam_release_status: Int?

    /// `{"distributor": "steam", "id": "730"}`, plus a `sku` that repeats the
    /// id on the routes that send one. See `GameSKU`.
    struct SKUDTO: Decodable, Sendable {
        var distributor: String?
        var id: String?

        var domain: GameSKU? {
            guard let distributor, !distributor.isEmpty, let id else { return nil }
            return GameSKU(distributor: distributor, id: id)
        }
    }

    struct MediaDTO: Decodable, Sendable {
        var icon: RefDTO?
        var banner: RefDTO?
        var cover: RefDTO?
        var artwork: [RefDTO]?
    }

    /// `{"type": "hash" | "url", "value": …}`.
    ///
    /// **Both forms appear in one response.** Arknights' cover is a hash and
    /// Wuthering Waves' is a URL, in the same `/games` array — so the tag is
    /// read rather than the value sniffed, and a `type` neither of those
    /// resolves to nothing.
    struct RefDTO: Decodable, Sendable {
        var type: String?
        var value: String?

        var domain: GameMediaRef? {
            guard let value, !value.isEmpty else { return nil }
            switch type {
            case "hash": return .hash(value)
            case "url": return URL(string: value).map(GameMediaRef.url)
            default: return nil
            }
        }
    }

    struct WebsiteDTO: Decodable, Sendable {
        var url: String?
        var category: Int?

        var domain: GameWebsite? {
            guard let url, let address = URL(string: url),
                  let category, let kind = GameLinkCategory(rawValue: category)
            else { return nil }
            return GameWebsite(url: address, category: kind)
        }
    }

    struct CompanyDTO: Decodable, Sendable {
        var name: String?
        var roles: [Int]?

        var domain: GameCompany? {
            guard let name, !name.isEmpty else { return nil }
            return GameCompany(
                name: name,
                roles: Set((roles ?? []).map(GameCompanyRole.init(rawValue:)))
            )
        }
    }

    struct TrailerDTO: Decodable, Sendable {
        var id: String?
        var application_id: ApplicationID?
        var width: Int?
        var height: Int?
        var mime_type: String?

        func domain(fallbackApplicationID: ApplicationID) -> GameTrailer? {
            guard let id else { return nil }
            return GameTrailer(
                id: id,
                applicationID: application_id ?? fallbackApplicationID,
                width: width,
                height: height,
                mimeType: mime_type
            )
        }
    }

    struct ReviewsDTO: Decodable, Sendable {
        var steam: SteamDTO?
        var opencritic: OpenCriticDTO?

        struct SteamDTO: Decodable, Sendable {
            var rating: Double?
            var rating_count: Int?
            var recent_rating: Double?
            var recent_rating_count: Int?
            var localized_rating: Double?
            var localized_rating_count: Int?
        }

        struct OpenCriticDTO: Decodable, Sendable {
            var top_critic_rating: Double?
            var top_critic_rating_count: Int?
            var tier: Int?
        }

        var domain: GameReviews? {
            let steamReviews = steam.map {
                GameReviews.SteamReviews(
                    rating: $0.rating,
                    ratingCount: $0.rating_count,
                    recentRating: $0.recent_rating,
                    recentRatingCount: $0.recent_rating_count,
                    localizedRating: $0.localized_rating,
                    localizedRatingCount: $0.localized_rating_count
                )
            }
            let criticReviews = opencritic.map {
                GameReviews.OpenCriticReviews(
                    topCriticRating: $0.top_critic_rating,
                    topCriticRatingCount: $0.top_critic_rating_count,
                    tier: $0.tier.flatMap(OpenCriticTier.init(rawValue:))
                )
            }
            let reviews = GameReviews(steam: steamReviews, openCritic: criticReviews)
            return reviews.isEmpty ? nil : reviews
        }
    }

    /// Dropped without an id or a name: a game the profile cannot name is a
    /// tile with a blank under its cover.
    var domain: Game? {
        guard let id, let name, !name.isEmpty else { return nil }
        // **`media` first, the flat hashes second.** Both arrive, and `media` is
        // the one that distinguishes a hash from a URL — the flat `icon_hash`
        // and `banner_hash` are hashes by construction and are the standby for a
        // response that omits the structured block.
        let resolved = GameMedia(
            icon: media?.icon?.domain ?? icon_hash.map(GameMediaRef.hash),
            banner: media?.banner?.domain ?? banner_hash.map(GameMediaRef.hash),
            cover: media?.cover?.domain,
            artwork: (media?.artwork ?? []).compactMap(\.domain)
        )
        var game = Game(
            id: id,
            name: name,
            summary: description,
            media: resolved,
            genres: (genres ?? []).map(GameGenre.init(rawValue:)),
            platforms: (platforms ?? []).compactMap(GamePlatform.init(rawValue:)),
            websites: (websites ?? []).compactMap(\.domain),
            companies: (companies ?? []).compactMap(\.domain),
            releaseDate: first_release_date.flatMap(Self.date(from:)),
            reviews: reviews?.domain,
            openCriticURL: opencritic_url.flatMap(URL.init(string:)),
            globalRank: l30_rank,
            screenshotURLs: (screenshot_urls ?? []).compactMap(URL.init(string:)),
            screenshotHashes: screenshot_hashes ?? [],
            trailers: (trailers ?? []).compactMap { $0.domain(fallbackApplicationID: id) },
            themes: themes ?? [],
            // An entry with an empty id is kept here and dropped where a store
            // address is built: the list stays a faithful record of what the
            // route sent, and `Game.storeOffers` is the one place that decides
            // what can be turned into a link.
            thirdPartySkus: (third_party_skus ?? []).compactMap(\.domain),
            steamReleaseStatus: steam_release_status.flatMap(SteamReleaseStatus.init(rawValue:))
        )
        game.isProfileDisabled = (game_flags ?? 0) & 1 != 0
        game.communityGuildIDs = community_guild_ids ?? []
        game.officialApplicationID = linked_applications?.first { $0.type == 2 }?.id
        return game
    }

    /// A release date arrives as midnight UTC with **no** fractional seconds —
    /// `2014-09-02T00:00:00+00:00` — so the fractional formatter alone rejects
    /// every one of them.
    static func date(from string: String) -> Date? {
        ISO8601DateFormatter.withFraction.date(from: string)
            ?? ISO8601DateFormatter.plain.date(from: string)
    }
}

/// `GET /games/{id}/announcements`.
///
/// **The announcements are messages, whole.** The envelope names the guild and
/// channel they came from and the array is Discord's ordinary message object —
/// components v2 and all, which is what the captured Arknights posts are made
/// of. So they decode through the same `MessageDTO` the transcript uses and
/// render through the same components, rather than through a second, thinner
/// reader that would have to learn container, media-gallery, text-display and
/// separator all over again.
struct GameAnnouncementsDTO: Decodable, Sendable {
    var guild_id: GuildID?
    var channel_id: ChannelID?
    var messages: [MessageDTO]?
}

/// What comes back, decoded.
public struct GameAnnouncements: Sendable {
    /// Where they were posted, so "View All" has somewhere to go.
    public var guildID: GuildID?
    public var channelID: ChannelID?
    public var messages: [Message]
    /// The webhooks and bots that posted them, which no other route names.
    public var authors: [UserID: User]

    public init(
        guildID: GuildID? = nil,
        channelID: ChannelID? = nil,
        messages: [Message] = [],
        authors: [UserID: User] = [:]
    ) {
        self.guildID = guildID
        self.channelID = channelID
        self.messages = messages
        self.authors = authors
    }

    public var isEmpty: Bool { messages.isEmpty }
}

/// `GET /content-inventory/users/@me/similar-games/{id}`.
struct SimilarGamesDTO: Decodable, Sendable {
    var game_id: ApplicationID?
    var similar_games: [ApplicationID]?
}

/// What `GET /users/{id}/profile` answers with, in two parts.
///
/// **The board is not a decoration and does not travel on the user.** Every
/// other field this route adds is a cosmetic that belongs to the person and gets
/// merged onto their `UserDecoration`; the widgets are a *document* they
/// arranged, they can be several kilobytes, and the decoration is a `Codable`
/// box shared by every copy of a user. Returning them beside the user keeps the
/// board out of that box and keeps the one call that fetches both from becoming
/// two.
public struct ProfileFetch: Sendable {
    /// The account's own profile. Never the per-server one — see `guildUser`.
    public var user: User
    /// The same account **as it presents itself in the guild that was asked
    /// about**, or nil when the response carried no guild layer.
    ///
    /// **A second value rather than a merge**, because both are real and the
    /// reader can ask for either: Discord's profile menu offers "View Main
    /// Profile" and "View Per-server Profile", and a client that folded them
    /// together could only ever draw one of the two.
    public var guildUser: User?
    /// Which guild `guildUser` belongs to.
    public var guildID: GuildID?
    public var widgets: [ProfileWidget]

    public init(
        user: User,
        guildUser: User? = nil,
        guildID: GuildID? = nil,
        widgets: [ProfileWidget] = []
    ) {
        self.user = user
        self.guildUser = guildUser
        self.guildID = guildID
        self.widgets = widgets
    }
}
