import CoreGraphics
import Foundation
import SwiftUI
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
    /// Show the account's own profile rather than the one it wears here.
    ///
    /// **Not the same as a nil `guildID`, which is why this is a flag and not
    /// an absence.** Nil means "no server in play" and falls back to whichever
    /// guild is selected — the behaviour every caller wants by default. This
    /// means "a server IS in play and the reader asked to look past it", which
    /// is Discord's own "View Main Profile".
    var showsMainProfile = false
    /// The frame of the control that opened it, in **window** coordinates, so
    /// the card can appear beside its origin rather than at the pointer. A card
    /// that follows the click reads as a menu.
    var anchor: CGRect
    var depth: Depth = .mini
    /// Open with the editor already showing, on this page.
    ///
    /// **A scope rather than a flag**, because the one caller that wants this —
    /// the server menu's Edit Per-server Profile — wants a *specific* page, and
    /// a bool would land on the account's. Nil is every other caller, which
    /// opens the profile to read.
    var editsScope: ProfileEditor.Scope?
    /// Whether the card carries the reader's own controls — Edit Profile, the
    /// status picker and the account rows.
    ///
    /// **A flag rather than `profile.isSelf`**, because the reader's own card is
    /// opened from four places and only one of them is asking for the controls:
    /// clicking your own name in a transcript opens the card to *read*.
    var showsOwnActions = false
    /// The tab the full profile opens on. **Set by a peek**: the edge of a
    /// second card under an activity opens Activity, under a widget opens the
    /// board — Discord's own destinations. Nil is the sheet's own default.
    var tab: ProfileTab?

    var id: UInt64 { userID.rawValue }
}

/// Everything a profile surface draws, resolved once.
struct ProfilePresentation: Equatable, Sendable {
    var userID: UserID
    var displayName: String
    /// The face, effect and colours the name is drawn with. Nil for nearly
    /// everyone, and nil is what keeps them on the plain label — see
    /// `StyledDisplayName`.
    var displayNameStyle: DisplayNameStyle?
    var handle: String
    /// The per-guild nickname, when it differs from the display name. Shown as a
    /// second line rather than replacing the first: a nickname that silently
    /// replaces someone's real name makes them unfindable.
    ///
    /// **On a per-server profile it IS the display name**, so the line that
    /// draws it is already guarded on the two differing and disappears.
    var nickname: String?
    /// Which of the two profiles is showing.
    var showsMainProfile = false
    /// What the *other* profile calls them, or nil when there is no other one.
    ///
    /// Discord subtitles its menu item with this — "View Per-server Profile /
    /// AKA Corvin KQZRA-TMWB" — so the reader knows what they are switching to
    /// before they switch.
    var alternateName: String?
    var avatarURL: URL?
    var monogram: String
    var decorationURL: URL?
    /// The product the avatar decoration came from. The URL above draws it;
    /// this is what says which one is worn — see `Nameplate.skuID` for the same
    /// distinction.
    var avatarDecorationSKU: String?
    /// The nameplate they wear, whole rather than as a URL.
    ///
    /// **The editor needs the sku, not the picture.** A row that only draws one
    /// can take `artworkURL` and stop; the rail's tile has to say which product
    /// is current so the picker can mark it, and it has to be able to send that
    /// sku back.
    var nameplate: Nameplate?
    var bannerURL: URL?
    /// The profile accent. Nil and zero are different states — zero is a
    /// deliberate black accent — so this stays optional all the way down.
    var accentColorValue: UInt32?
    /// The profile's own two-colour theme, primary first. Empty when unthemed —
    /// which is most people, and the card must look deliberate for them too.
    var themeColorValues: [UInt32] = []
    var status: PresenceStatus
    var customStatus: String?
    /// The glyph beside it. Kept apart from the text because the wire keeps them
    /// apart, and because a status that is *only* an emoji is a real state that
    /// a single concatenated string cannot represent.
    var customStatusEmoji: EmojiRef?
    /// Everything they are doing, in Discord's order — one card each.
    var activities: [Activity] = []
    /// The first of them: the activity a surface with room for one shows, and
    /// the one whose buttons and store offers are fetched.
    var activity: Activity? { activities.first }
    /// Where that activity's custom buttons go, once the metadata route has
    /// answered.
    ///
    /// **Empty is the common case and it is also the honest one.** A presence
    /// carries the button *labels* and never their links, so a button drawn
    /// before this array arrives is a control that opens nothing. The count is
    /// matched against the labels at the draw, and a label with no address is
    /// not drawn.
    var activityButtonURLs: [URL] = []
    /// Where the game they are playing is sold.
    ///
    /// **Empty until `/games` has answered for the activity's application**, and
    /// empty forever for an activity that is not a tracked game — Spotify, a
    /// bot's own presence, an editor. That is the same gate Discord's button
    /// has: its store CTA reads the game record, so an application the games
    /// route says nothing about gets no button rather than a guessed address.
    var activityStoreOffers: [GameStoreOffer] = []
    var bio: String?
    var isBot: Bool
    /// A verified app's badge carries a check — `AppBadge`.
    var isVerifiedBot = false
    /// Discord's own account, which wears OFFICIAL rather than APP.
    var isSystem = false
    /// An app's own facts — its intents, its install routes, its store and
    /// its two links. Nil for a person, and for an app until its profile has
    /// answered.
    var application: ProfileApplication? = nil
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
    /// The artwork wrapping the card's edges, once its SKU has resolved.
    ///
    /// Separate from `effect` because they are separate purchases and an
    /// account can wear both — torriel wears Nevermore and Dark Roses at once,
    /// and folding one into the other would make each hide the other.
    var frame: ProfileFrame?
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
    /// People both accounts know.
    var mutualFriends: [MutualFriend]
    /// Whether they have turned their profile private. A label, never a filter
    /// — see `UserDecoration.isProfilePrivate`.
    var isProfilePrivate: Bool
    /// The profile route refused, so what only it answers — the bio, the
    /// banner, the mutuals — could not be loaded. Discord's notice
    /// (`559506`), which it never shows for a friend or for somebody who has
    /// asked to be one.
    var isPartlyUnavailable = false
    /// The reader's own private note about them.
    var note: String
    /// What the account is to them — which is the whole of what the foot bar's
    /// primary button says and does.
    var relationship: Relationship = .none
    /// Whether a relationship write is in flight, so the button holds rather
    /// than offering a second click into the same route.
    var isRelationshipBusy: Bool = false
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
    /// Whether the frame this profile names is still on its way: its SKU has
    /// arrived and its artwork's description has not.
    ///
    /// **Only the DM column waits on it.** There a frame moves the card — the
    /// column widens by its side overhangs and the card gives up its top and
    /// bottom — so Discord's sidebar draws nothing until the frame has
    /// resolved (`r5`). A popout shows the card and fades the frame in.
    var isFrameLoading = false
}

/// A clan tag, as it is worn beside a name.
///
/// The guild id travels with the letters because the tag is a *destination*: the
/// two-to-four characters are the only thing on a profile that stands for a
/// place, and without the id the chip can say a server exists and not which one.
/// Nil where the id is not known — the member-list painter draws tags from a
/// row snapshot that carries only what it needs to paint.
extension ProfilePresentation {
    /// The tag beside the name: Discord's own account is OFFICIAL, as its
    /// messages are (`AuthorTag`); an app is APP.
    var nameTag: String? {
        if isSystem { return AuthorTag.official.label }
        return isBot ? AppBadge.label(isVerified: isVerifiedBot) : nil
    }
}

struct GuildTag: Equatable, Sendable {
    var text: String
    var badgeURL: URL?
    var guildID: GuildID?
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

/// `Hashable` as well as `Equatable`: the Channels & Roles page carries a list
/// of these inside its own memoized, hashable value.
struct ProfileRole: Hashable, Sendable, Identifiable {
    var id: RoleID
    var name: String
    var colorValue: UInt32?
    /// The **enhanced role style** — a boosted server's gradient, two or three
    /// stops. Nil on an ordinary role, which is nearly all of them.
    ///
    /// `Role.colors` has been decoded since the role editor was built and
    /// nothing has ever drawn it: the editor exposes the identifiers a renderer
    /// never needed. It reaches the chip through here.
    var colors: RoleColors?
    /// A role's own mark, which sits AFTER its name. Discord lets a server set
    /// either an uploaded icon or a unicode emoji, never both.
    var iconURL: URL?
    var unicodeEmoji: String?

    /// The stops an enhanced role's name and dot are painted with, or nil for
    /// an ordinary one.
    ///
    /// **The list wraps back to the first colour**, which is Discord's own
    /// rule and not decoration: `linear-gradient(to right, c1, c2, c1)` for two
    /// stops and `(c1, c2, c3, c1)` for three. It is written that way because
    /// the gradient is a *repeating* 100-point tile that scrolls — a list that
    /// did not return to where it started would show a seam on every cycle.
    ///
    /// This client draws the tile once across the name rather than repeating
    /// and animating it; the wrap is kept because it is what makes the two ends
    /// of a short name agree, which is most of the look.
    var gradientStops: [Color]? {
        colors.flatMap { RoleColors.wrappedStops($0) }?.map { Color(hex: $0) }
    }
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
