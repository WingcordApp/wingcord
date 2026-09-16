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
    var badgeURL: URL?
    var badgeColorPrimary: UInt32?
    var badgeColorSecondary: UInt32?
    var standing: GuildProfile.Standing?
    var description: String?
    var memberCount: Int?
    var onlineCount: Int?
    var traits: [GuildTrait]
    var createdAt: Date
    /// Whether the reader is in this server, which is what turns the footer from
    /// a promise this client cannot keep into a real destination.
    var isJoined: Bool
    var isLoading: Bool
    /// What the card offers somebody who is not in this server.
    var entry: Entry

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
        /// `PUT /guilds/{id}/members/@me` and you are in.
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
    /// over — the card then has no name, no icon and no date, and saying "You
    /// are not in this server" there answers a question nobody asked.
    var isUnnamed: Bool { name == "Private Server" }
}
