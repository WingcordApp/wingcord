import CoreGraphics
import Foundation
import WingcordCore

/// Everything the card draws.
///
/// A presentation rather than the domain value, because two of the four things
/// it shows are the reader's own: whether they are already in the server, and
/// what its icon looks like out of the cache they already hold.
struct GuildProfilePresentation: Equatable, Sendable {
    var guildID: GuildID
    var name: String
    var tag: String?
    var iconURL: URL?
    var monogram: String
    var bannerURL: URL?
    /// The banner's glow where there is no artwork — the brand colour, or the
    /// icon's; nil for Discord's neutral. See `GuildBannerArt`.
    var bannerColor: UInt32?
    var badgeURL: URL?
    var mark: GuildMark?
    var description: String?
    var memberCount: Int?
    var onlineCount: Int?
    var traits: [GuildTrait]
    /// The games this server says it plays, resolved to names and icons.
    ///
    /// **Resolved here rather than in the card**, for the reason the profile
    /// board's covers are: joining twelve ids to twelve games is a table lookup
    /// each, and doing it in a body would redo it on every hover anywhere on the
    /// card.
    var games: [GuildProfileGame]
    var createdAt: Date
    /// Whether the reader is in this server, which is what turns the footer from
    /// a promise this client cannot keep into a real destination.
    var isJoined: Bool
    var isLoading: Bool
    /// What the card offers somebody who is not in this server.
    var entry: Entry
    /// Why the profile is not there, when Discord refused or failed it — the
    /// card then says so in Discord's words (`109026`).
    var refusal: GuildProfileRefusal? = nil

    /// The way in, decided by the server's own feature list.
    ///
    /// **A case rather than a Bool, because the two ways in are different
    /// acts.** An open server is entered with one request; a server that
    /// reviews applications is *applied to*, and the reader answers a form and
    /// waits. Discord's own button says Join for the first and Apply to Join
    /// for the second, and a client that offered Join for both would report
    /// success on a request that only queued.
    enum Entry: Equatable, Sendable {
        /// Nothing to offer: already a member, or the profile has not landed.
        case none
        /// A look inside — Discord's Join from a tag card is a preview.
        case join
        /// The server asks first — `MEMBER_VERIFICATION_GATE_ENABLED`.
        case apply
        /// Applied, and waiting on a moderator.
        case pending
    }

    /// Whether this card is standing in for a server it could not name.
    ///
    /// **The placeholder is the answer, not a failure.** A tag can be worn from
    /// a server the reader is not in and whose profile the route will not hand
    /// over — the card then has no name, no icon and no date, and Discord's
    /// "The server has limited who can see this profile" is what it says.
    var isUnnamed: Bool { name == "Private Server" }
}


/// One game on a server's tag card.
struct GuildProfileGame: Equatable, Sendable, Identifiable {
    var id: ApplicationID
    var name: String
    var iconURL: URL?
    /// Whether it wears the little flame — see `GuildGameActivity.isHot`.
    var isHot: Bool
}

/// Why a server's profile could not be shown.
enum GuildProfileRefusal: Equatable, Sendable {
    /// Discord's 50001: "The server has limited who can see this profile."
    case limited
    /// Anything else: "Unable to load server profile", and another try.
    case failed
}
