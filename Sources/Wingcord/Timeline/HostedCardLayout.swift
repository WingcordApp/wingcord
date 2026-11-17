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

/// One event card in a message: which event, and which date of its series —
/// Discord's event embed (`484724`), keyed as its own `guild-event[-date]`.
nonisolated struct EventCardKey: Hashable, Sendable {
    var guildID: GuildID
    var eventID: UInt64
    /// One date of a series, or nil for the event as a whole.
    var occurrence: UInt64?
    /// The invite the card stands in for, by its lookup key, where an invite
    /// with `?event=` on it became this card: the server it names is the
    /// card's footer, and its Join accepts that invite.
    var invite: String?
}

/// One text file shown as Discord's preview (`448381`'s `PLAINTEXT_PREVIEW`):
/// the attachment, and what the card needs of it without the message.
///
/// **The content type is the attachment's**, not the answer's: Discord decodes
/// with the type the attachment was sent with (`684519.eC`).
nonisolated struct PlaintextCardKey: Hashable, Sendable {
    var attachmentID: AttachmentID
    var url: String
    var filename: String
    var size: Int
    var contentType: String?

    init(_ attachment: Attachment) {
        attachmentID = attachment.id
        url = attachment.url
        filename = attachment.filename
        size = attachment.size
        contentType = attachment.contentType
    }
}

/// A card the transcript hosts rather than draws.
///
/// **Three kinds, one mechanism.** Discord's user profile embed is the app's
/// own profile card, its event embed is the events panel's own parts, and its
/// text preview scrolls, selects, and opens a picker and a menu; each is
/// SwiftUI the transcript could only redraw by keeping a second copy of. So
/// the row reserves the space a card measured itself at and `HostedCardHosts`
/// keeps the live card over it.
nonisolated enum HostedCardKey: Hashable, Sendable {
    case user(UserCardKey)
    case event(EventCardKey)
    case plaintext(PlaintextCardKey)
    /// An activity link's card: the app's cover, name, tags and Play.
    case activity(ActivityCardKey)
    /// A Spotify link's card (one height, laid out without measuring).
    case spotify(SpotifyCardKey)
}

/// What a hosted card measured itself at.
///
/// **By width**, because the two kinds size differently. A profile card is
/// 300 wide and takes whatever height its profile needs — one size, the
/// latest. An event card is as wide as its column, up to Discord's 432, and
/// its description wraps to that width, so the same card in the transcript
/// and in a narrower thread is two heights: each is kept beside the width it
/// was laid out at.
nonisolated struct HostedCardMeasure: Equatable, Sendable {
    /// The sizes taken, one a width, the most recent last.
    private(set) var sizes: [CGSize] = []

    /// The size it took last — a profile card's, which sizes itself.
    var latest: CGSize? { sizes.last }

    /// Its height at this width — or, until it has been laid out at it, at the
    /// nearest width it was, which the live card then corrects.
    func height(atWidth width: CGFloat) -> CGFloat? {
        sizes.first { $0.width == width }?.height
            ?? sizes.min { abs($0.width - width) < abs($1.width - width) }?.height
    }

    /// Takes a measurement, and says whether it changed anything a layout
    /// reads. Four widths at most, so a live resize does not grow the table a
    /// point at a time.
    mutating func note(_ size: CGSize) -> Bool {
        if let index = sizes.firstIndex(where: { $0.width == size.width }) {
            let isKnown = sizes[index].height == size.height
            sizes.remove(at: index)
            sizes.append(size)
            return !isKnown
        }
        sizes.append(size)
        if sizes.count > 4 { sizes.removeFirst(sizes.count - 4) }
        return true
    }
}

/// Where a hosted card sits in its row.
///
/// **Reserved here, drawn elsewhere.** The row only keeps the space the card
/// measured itself at, so the rows under it land where it ends.
nonisolated struct HostedCardSlot: Sendable {
    var rect: CGRect
    var key: HostedCardKey
}

/// A card on screen: which one, and where, in the canvas's coordinates.
nonisolated struct HostedCardPlacement: Hashable, Sendable {
    /// The message and the card's place in it — the same link twice is two
    /// cards.
    struct ID: Hashable, Sendable {
        var message: MessageID
        var index: Int
    }

    var id: ID
    var key: HostedCardKey
    var frame: CGRect
}
