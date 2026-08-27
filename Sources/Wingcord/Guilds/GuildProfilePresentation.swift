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
}
