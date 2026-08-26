import CoreGraphics
import Foundation
import WingcordCore

/// A request to show someone's profile.
///
/// **One value on the store, one presenter at the window root — never a
/// presentation modifier on a row.** A `.popover` or `.sheet` written inline in
/// a member row or a message header is evaluated as part of *that row's* body,
/// by every row, on every evaluation, including its title strings. Routing the
/// request through the store means the rows carry a click handler and nothing
/// else, and there is exactly one presenter in the window instead of one per
/// visible row.
struct ProfileRequest: Equatable, Identifiable {
    enum Depth: Equatable {
        /// The card that appears beside the row that was clicked.
        case mini
        /// The full profile, as its own window.
        case full
    }

    var userID: UserID
    /// The guild whose nickname, roles and colour apply. Nil in a DM.
    var guildID: GuildID?
    /// The frame of the control that opened it, in **window** coordinates, so
    /// the card can appear beside its origin rather than at the pointer. A card
    /// that follows the click reads as a menu.
    var anchor: CGRect
    var depth: Depth = .mini

    var id: UInt64 { userID.rawValue }
}

/// Everything a profile surface draws, resolved once.
struct ProfilePresentation: Equatable, Sendable {
    var userID: UserID
    var displayName: String
    var handle: String
    /// The per-guild nickname, when it differs from the display name. Shown as a
    /// second line rather than replacing the first: a nickname that silently
    /// replaces someone's real name makes them unfindable.
    var nickname: String?
    var avatarURL: URL?
    var monogram: String
    var decorationURL: URL?
    var bannerURL: URL?
    /// The profile accent. Nil and zero are different states — zero is a
    /// deliberate black accent — so this stays optional all the way down.
    var accentColorValue: UInt32?
    var status: PresenceStatus
    var customStatus: String?
    var activity: Activity?
    var bio: String?
    var isBot: Bool
    var badges: [ProfileBadge]
    var roles: [ProfileRole]
    var memberSince: Date?
    var accountCreated: Date
    var isSelf: Bool
}

struct ProfileRole: Equatable, Sendable, Identifiable {
    var id: RoleID
    var name: String
    var colorValue: UInt32?
}

struct ProfileBadge: Equatable, Sendable, Identifiable {
    var id: String
    var symbolName: String
    var label: String
}

extension UserFlags {
    /// The badges a set of account flags earns.
    ///
    /// SF Symbols rather than Discord's own artwork: the badge row is chrome,
    /// and chrome that ships bitmaps has to ship a light and a dark set, at three
    /// scales, and re-ship them whenever Discord changes one.
    var badges: [ProfileBadge] {
        var result: [ProfileBadge] = []
        func add(_ flag: UserFlags, _ id: String, _ symbol: String, _ label: String) {
            guard contains(flag) else { return }
            result.append(ProfileBadge(id: id, symbolName: symbol, label: label))
        }
        add(.staff, "staff", "shield.lefthalf.filled", "Discord Staff")
        add(.partner, "partner", "checkmark.seal.fill", "Partnered Server Owner")
        add(.certifiedModerator, "mod", "checkmark.shield.fill", "Moderator Programs Alumni")
        add(.hypesquadEvents, "hypesquad", "sparkles", "HypeSquad Events")
        add(.hypesquadBravery, "bravery", "shield.fill", "HypeSquad Bravery")
        add(.hypesquadBrilliance, "brilliance", "flame.fill", "HypeSquad Brilliance")
        add(.hypesquadBalance, "balance", "scalemass.fill", "HypeSquad Balance")
        add(.bugHunterLevel1, "bug1", "ant.fill", "Bug Hunter")
        add(.bugHunterLevel2, "bug2", "ant.circle.fill", "Bug Hunter Level 2")
        add(.earlySupporter, "early", "heart.fill", "Early Supporter")
        add(.activeDeveloper, "activedev", "hammer.fill", "Active Developer")
        add(.verifiedDeveloper, "verifieddev", "chevron.left.forwardslash.chevron.right", "Early Verified Bot Developer")
        return result
    }
}
