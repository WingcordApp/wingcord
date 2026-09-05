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
    var storeLink: GameWebsite?
    /// The card offering to link an in-game account, when the game's widget
    /// application publishes an address for it.
    var accountLink: GameAccountLink?
    var community: GameCommunityCard?
    var reviews: GameReviews?
    var openCriticURL: URL?
    var announcements: [GameAnnouncementCard]
    /// Where "View All" goes: the game's own announcements channel.
    var announcementsChannel: (guildID: GuildID, channelID: ChannelID)?
    var similar: [BoardGame]
    var isLoading: Bool

    static func == (lhs: GamePresentation, rhs: GamePresentation) -> Bool {
        lhs.gameID == rhs.gameID
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
            && lhs.storeLink == rhs.storeLink
            && lhs.accountLink == rhs.accountLink
            && lhs.community == rhs.community
            && lhs.reviews == rhs.reviews
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
    case trailer(URL)
    case still(URL)

    var id: URL {
        switch self {
        case .trailer(let url), .still(let url): url
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
    var isVerified: Bool
    var inviteCode: String
    /// Whether the reader is already in it — the button says Open rather than
    /// Join, because a Join that does nothing is the inert control §5.5 is about.
    var isJoined: Bool
}

/// One post from the game's own server, digested down to a card.
///
/// **A digest, not a rendering.** The transcript paints components v2 into a
/// canvas of absolutely-placed slots; a horizontally-scrolling shelf card is not
/// that surface and does not want a container's accent rule or its buttons. What
/// a card needs is the first picture, the words, when it was posted and how many
/// people reacted — and every one of those is reachable without the canvas.
struct GameAnnouncementCard: Hashable, Sendable, Identifiable {
    var id: MessageID
    var imageURL: URL?
    var text: String
    var postedAt: Date
    var reactionCount: Int
}
