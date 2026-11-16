import Foundation
import WingcordCore

/// A server the reader is looking at without having joined it.
///
/// **Lurking is a property of the gateway SESSION, not of the account.** The
/// route that starts it takes the socket's own session id, and
/// `docs.discord.food` is explicit that the subscription lasts "for the lifetime
/// of the Gateway session". So this value is session-scoped by construction: it
/// is dropped when the socket goes away, and nothing persists it. A preview that
/// survived a reconnect would be a server in the rail whose channels no longer
/// load and whose messages never arrive again.
///
/// One at a time. Discord pins the previewed server to the top of the rail above
/// the divider, which is a place for one thing; a set of them would also mean a
/// set of banners, and the banner is what tells the reader they cannot talk.
struct GuildPreview: Hashable, Sendable {
    var guildID: GuildID
    /// Where the reader came from, and therefore where "Back" goes.
    var origin: Origin
    /// Whether the lurk has been acknowledged by the server yet. Until it is,
    /// the guild is not in the store and the rail has nothing to draw.
    var isStarting: Bool = true
    /// Where the reader was when the preview began — what Back returns to.
    /// **Discord's Back is a step back in history** (`goBack()` on its notice
    /// bar), so it lands on the server and channel the reader left, not on an
    /// empty column.
    var returnGuildID: GuildID?
    var returnChannelID: ChannelID?

    /// What raised the preview.
    ///
    /// **A case per surface, rather than a closure or a generic "previous
    /// screen".** Each one has to be able to draw its own return bar — the game
    /// profile's says "Return to the Sims 4 game profile" and carries the game's
    /// mark — and a stored closure could not be compared, which the store's
    /// values have to be.
    enum Origin: Hashable, Sendable {
        /// Opened from a community announcement on a game's profile.
        case gameProfile(ApplicationID)
        /// Opened from the discovery grid.
        case discovery
        /// Opened from a server tag's card — Discord's `LURK_DISCOVERABLE`
        /// Join, for a discoverable server with no invite in hand.
        case guildProfile
        /// Opened from a forwarded message's breadcrumb — Discord's
        /// `FORWARD_BREADCRUMB`, which lurks the original's server first.
        case forwardBreadcrumb
    }

    /// The game to return to, where there is one.
    var originGameID: ApplicationID? {
        if case .gameProfile(let gameID) = origin { return gameID }
        return nil
    }
}

/// What the preview's chrome draws, resolved once.
///
/// Separate from `GuildPreview` because it joins names and artwork the store
/// holds elsewhere — the banner needs the server's name, the return bar needs
/// the game's — and a projection is what keeps those lookups out of a view body
/// that re-evaluates on every scroll.
struct GuildPreviewPresentation: Equatable, Sendable {
    var guildID: GuildID
    /// For "Join The Sims".
    var guildName: String
    /// For "Return to the The Sims 4 game profile".
    var returnTitle: String?
    var returnGameID: ApplicationID?
    /// The game's square mark, drawn larger — Discord uses the same asset the
    /// board rows do rather than a second rendition.
    var returnIconURL: URL?
    /// Whether the join is in flight, so the button can say so rather than
    /// looking inert.
    var isJoining: Bool
    /// What the way back says: Discord's "Back to Discovery" for a preview
    /// from the grid, and plain "Back" otherwise.
    var backLabel: String = "Back"
}
