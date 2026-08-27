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
    /// The profile's own two-colour theme, primary first. Empty when unthemed —
    /// which is most people, and the card must look deliberate for them too.
    var themeColorValues: [UInt32] = []
    var status: PresenceStatus
    var customStatus: String?
    var activity: Activity?
    var bio: String?
    var isBot: Bool
    var badges: [ProfileBadge]
    /// The clan tag they wear: the letters, and the guild badge that goes with
    /// them. Half a tag is not a tag — the badge is the half people recognise.
    var guildTag: GuildTag?
    var roles: [ProfileRole]
    var memberSince: Date?
    var accountCreated: Date
    var isSelf: Bool
    /// Free text the account chose, shown beside the handle.
    var pronouns: String?
    /// The layered animation drawn over the card, once its SKU has resolved.
    var effect: ProfileEffect?
    var connections: [ConnectedAccount]
    var premiumTier: PremiumTier
    var premiumSince: Date?
    /// The pre-2023 `name#1234`, when Discord still knows it.
    var legacyUsername: String?
    /// The servers the reader shares with them, resolved for drawing.
    ///
    /// The **list**, because the row that shows it opens onto it: a count with
    /// nothing behind it is a fact the reader then has to go and check
    /// somewhere else, and the profile route already sent the answer.
    var mutualServers: [MutualServer]
    /// The server the profile was opened in — its name and icon, so the
    /// "joined" line can say *which* server rather than showing a bare date
    /// beside an anonymous symbol. Nil in a DM.
    var guild: MutualServer?
    /// The existing direct message with them, when there is one.
    ///
    /// Nil covers both "this is you" and "you have never spoken" — and the
    /// second is not something this client can fix yet, because opening a new
    /// DM is a round trip it does not make. A Message button that silently does
    /// nothing is worse than one that is not offered, so the view keys off this
    /// rather than off `isSelf`.
    var directMessageChannelID: ChannelID?
    /// Whether the detail fetch is still out.
    ///
    /// The card opens immediately with what the roster already knows, and the
    /// banner, bio, colours and badges land afterwards. Without this the card
    /// cannot tell "this person has no bio" from "the bio has not arrived", and
    /// draws a stripped-down profile that then visibly fills in.
    var isLoading: Bool
}

/// A clan tag, as it is worn beside a name.
struct GuildTag: Equatable, Sendable {
    var text: String
    var badgeURL: URL?
}

/// One shared server, named and pictured rather than left as an id.
struct MutualServer: Equatable, Sendable, Identifiable {
    var id: GuildID
    var name: String
    var iconURL: URL?
    /// Drawn when there is no icon, which is most servers.
    var monogram: String
    /// The nickname they carry there, when it is not the name already shown.
    var nickname: String?
}

struct ProfileRole: Equatable, Sendable, Identifiable {
    var id: RoleID
    var name: String
    var colorValue: UInt32?
}

struct ProfileBadge: Equatable, Sendable, Identifiable {
    var id: String
    /// Discord's own artwork, when the profile route named it. Preferred over
    /// the symbol: the flag bits can only describe the handful of badges Discord
    /// has had longest, and every Nitro tier and boost month is invisible to
    /// them.
    var iconURL: URL?
    /// The fallback mark, for a badge derived from a flag bit.
    var symbolName: String
    /// What the badge means. Shown on hover, and read by VoiceOver.
    var label: String
}
