import CoreGraphics
import WingcordCore

/// One profile card in a message: whose, and in which server's clothes.
///
/// **The server is part of the key**, because a profile card opened inside a
/// server wears that server's nickname and per-server profile, and the same
/// link in a direct message wears neither — two different cards, two sizes.
nonisolated struct UserCardKey: Hashable, Sendable {
    var userID: UserID
    var guildID: GuildID?
}

/// Where a profile card sits in its row — Discord's user profile embed.
///
/// **Reserved here, drawn elsewhere.** The card is the app's own profile card,
/// hosted over the transcript by `UserCardHosts`; the row only keeps the space
/// the card measured itself at, so the rows under it land where it ends.
nonisolated struct UserCardSlot: Sendable {
    var rect: CGRect
    var key: UserCardKey
}

/// A card on screen: which one, and where, in the canvas's coordinates.
nonisolated struct UserCardPlacement: Hashable, Sendable {
    /// The message and the card's place in it — the same link twice is two
    /// cards.
    struct ID: Hashable, Sendable {
        var message: MessageID
        var index: Int
    }

    var id: ID
    var key: UserCardKey
    var frame: CGRect
}
