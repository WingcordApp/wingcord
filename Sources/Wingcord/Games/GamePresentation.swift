import Foundation
import WingcordCore

/// Everything the game profile draws, resolved once.
///
/// The same contract the profile and the board have: the view holds flat values,
/// and the joins across `games`, `gameAnnouncements`, `similarGames` and
/// `gameCommunities` happen here rather than inside a `body` that re-runs on
/// every hover.
struct GamePresentation: Equatable, Sendable {
    var gameID: ApplicationID
    var name: String
    var genreLine: String
    var summary: String?
    /// Box art, portrait. The header's poster.
    var coverURL: URL?
    /// Whether that art is a real cover or the square icon standing in.
    var hasCoverArt: Bool
    /// The square icon, for the condensed header bar — a 26-point sliver of box
    /// art is unrecognisable where the mark still reads.
    var markURL: URL?
    var artworkURL: URL?
    /// What the picture across the top of the page (`GameBackdrop`) is drawn
    /// from: the banner alone where there is one, else every screenshot, one
    /// of which the page picks at random when it opens — Discord's rule.
    var backdropChoices: [URL]
    /// The rank badge, or nil for a game Discord does not rank. Absent for most
    /// games and for two of the three captured ones.
    var globalRank: Int?
    /// The hero and the tray, in the order they are shown. **The trailer first
    /// where there is one** — it is the thing this page has that a shelf of
    /// stills does not, and Discord leads with it too.
    var media: [GameMediaItem]
    /// Free-text themes, already localised by the server. Drawn as chips under
    /// the summary, which is the space the mockup spent on a stat trio whose
    /// three numbers were all invented.
    var themes: [String]
    var details: [GameDetailRow]
    var links: [GameWebsite]
    /// Where to get or play the game, in Discord's own order — see
    /// `Game.launchOffers`.
    var launchOffers: [GameStoreOffer]
    /// The card offering to link an in-game account, when the game's widget
    /// application publishes an address for it.
    var accountLink: GameAccountLink?
    var community: GameCommunityCard?
    var reviews: GameReviews?
    /// The App Store and Play Store lines, each with its page — see
    /// `Game.mobileStoreReviews`.
    var mobileReviews: [MobileStoreReview] = []
    /// The game's Steam page, which the Reviews card's Steam lines open — and
    /// which decides whether there are any.
    var steamURL: URL?
    var openCriticURL: URL?
    var announcements: [GameAnnouncementCard]
    /// Where "View All" goes: the game's own announcements channel.
    var announcementsChannel: (guildID: GuildID, channelID: ChannelID)?
    var similar: [BoardGame]
    var isLoading: Bool
    /// Whether the profile has a Communities tab — the game lists three
    /// servers or more (`AppModel.communitiesThreshold`).
    var hasCommunities = false

    static func == (lhs: GamePresentation, rhs: GamePresentation) -> Bool {
        lhs.gameID == rhs.gameID
            && lhs.hasCommunities == rhs.hasCommunities
            && lhs.name == rhs.name
            && lhs.genreLine == rhs.genreLine
            && lhs.summary == rhs.summary
            && lhs.coverURL == rhs.coverURL
            && lhs.hasCoverArt == rhs.hasCoverArt
            && lhs.markURL == rhs.markURL
            && lhs.artworkURL == rhs.artworkURL
            && lhs.globalRank == rhs.globalRank
            && lhs.media == rhs.media
            && lhs.themes == rhs.themes
            && lhs.details == rhs.details
            && lhs.links == rhs.links
            && lhs.launchOffers == rhs.launchOffers
            && lhs.accountLink == rhs.accountLink
            && lhs.community == rhs.community
            && lhs.reviews == rhs.reviews
            && lhs.mobileReviews == rhs.mobileReviews
            && lhs.steamURL == rhs.steamURL
            && lhs.openCriticURL == rhs.openCriticURL
            && lhs.announcements == rhs.announcements
            && lhs.announcementsChannel?.channelID == rhs.announcementsChannel?.channelID
            && lhs.similar == rhs.similar
            && lhs.isLoading == rhs.isLoading
    }
}

/// One thing the media tray can show.
///
/// **Two cases, because a trailer is not a big screenshot.** It has to be
/// played, it has a poster that is not itself, and it is the one item on the
/// page whose thumbnail needs a mark saying so. Folding it into the URL list
/// is how a page ends up trying to decode an `.mp4` as a picture.
enum GameMediaItem: Hashable, Sendable, Identifiable {
    /// The video, and its poster — the same store asset as a `.webp`.
    case trailer(video: URL, poster: URL?)
    case still(URL)

    var id: URL {
        switch self {
        case .trailer(let url, _), .still(let url): url
        }
    }

    /// What a thumbnail draws: a still itself, a trailer's poster.
    var picture: URL? {
        switch self {
        case .trailer(_, let poster): poster
        case .still(let url): url
        }
    }

    var isTrailer: Bool {
        if case .trailer = self { return true }
        return false
    }
}

/// One row of the Details table.
///
/// **A row exists only when its field arrived.** Beat Saber has one platform and
/// no rank; The Sims has four platforms, three developers and a rank. A table
/// that drew every row with an em dash in the empty ones would be listing what
/// Discord does not know rather than what it does.
struct GameDetailRow: Hashable, Sendable, Identifiable {
    var title: String
    var content: Content

    var id: String { title }

    enum Content: Hashable, Sendable {
        case text(String)
        /// The platforms row, which is marks rather than words.
        case platforms([GamePlatform.DisplayGroup])
    }
}

/// The Link Account card on a game with a linkable in-game profile.
struct GameAccountLink: Hashable, Sendable {
    var applicationName: String
    var iconURL: URL?
    var url: URL
}

/// The Community card: the game's own Discord.
struct GameCommunityCard: Hashable, Sendable {
    var guildID: GuildID
    var name: String
    var iconURL: URL?
    var monogram: String
    var description: String?
    var memberCount: Int?
    var onlineCount: Int?
    /// Discord's mark for the server — the partner badge for Valorant's, a
    /// verified one for others — drawn as Discord draws it (`GuildMarkBadge`).
    var mark: GuildMark?
    var inviteCode: String
    /// Whether the reader is already in it — the button says Open rather than
    /// Join, because a Join that does nothing is the inert control §5.5 is about.
    var isJoined: Bool
}

/// One post from the game's own server, digested down to a card — Discord's
/// own digest (`pp` in `05ea9e44…`), field for field.
///
/// **A digest of the post, rendered.** The words stay markdown, and the card
/// draws them with the app's prose renderer: bold, links, mentions and emoji
/// as they were written. What is digested is the shape: the post's opening
/// heading becomes the card's title, its first picture (a gallery's, an
/// attachment's, a video's first frame, an embed's) becomes the card's
/// picture, and a poll or a link's embed gets the card of its own Discord gives
/// it.
struct GameAnnouncementCard: Hashable, Sendable, Identifiable {
    var id: MessageID
    /// The post's own heading, when its first line is one (`#` to `###`).
    var title: String?
    /// Everything after the title, as markdown.
    var body: String
    var media: Media?
    var postedAt: Date
    var reactionCount: Int
    var poll: PollDigest?
    /// Where the words came from, when they are a link's embed rather than the
    /// post's own — Discord's `embedSource`.
    var source: Source?
    /// The words read aloud: the title and the body with their marks folded.
    var spokenText: String

    /// The card's picture, already sized for it.
    struct Media: Hashable, Sendable {
        var url: URL
        /// Width over height of the asset itself. The card's frame is 16∶9
        /// whatever this is; it is what the request to the media proxy asks
        /// for, so the proxy neither crops nor stretches.
        var aspect: Double
    }

    struct PollDigest: Hashable, Sendable {
        var question: String
        /// The first three, as Discord's card shows.
        var answers: [String]
        /// How many more there are.
        var more: Int
        var expiresAt: Date?
        var isClosed: Bool
    }

    struct Source: Hashable, Sendable {
        var url: String?
        var authorName: String?
        var authorIconURL: URL?
        var colorValue: UInt32?
    }
}
