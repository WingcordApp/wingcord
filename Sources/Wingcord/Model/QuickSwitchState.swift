import Foundation
import WingcordCore

/// The quick switcher, while it is open.
///
/// **The game hits live here rather than on the store**, because they belong to
/// one open panel: they answer a query nobody is typing any more the moment the
/// switcher closes, and a table on the store would keep the last thing anybody
/// searched for until sign-out.
struct QuickSwitchState: Hashable, Sendable {
    /// What has been typed, sigil and all. The field is the query — see
    /// `QuickSwitchQuery.parse`.
    var text = ""

    /// **The lit row is deliberately NOT here.** It belongs to the panel's own
    /// `@State`: a selection on the store is a store publication per arrow key,
    /// and every read of `quickSwitchSections` walks the account and ranks it.
    /// Holding it in the view means an arrow press re-lays-out one panel and
    /// re-ranks nothing.

    /// Games from `/games/autocomplete`, and the folded needle they answer.
    ///
    /// **Held with their question.** The route is a round trip and the field is
    /// a keystroke, so an answer very often lands for a query two characters
    /// old — drawing it under the new one is a list that says `Grand Theft Auto`
    /// while the field says `grand thef`.
    var games: [GameSummary] = []
    var gamesNeedle = ""
    var isSearchingGames = false
}

/// Something the switcher can take you to.
///
/// **Four cases and no "row id", because the id *is* the destination.** A row
/// built from a target can be diffed, and a click on it needs nothing looked up
/// to act.
nonisolated enum QuickSwitchTarget: Hashable, Sendable {
    case channel(ChannelID)
    case guild(GuildID)
    /// Picking a person opens the conversation with them, making one if there is
    /// none — `AppModel.messagePerson`, which is the same act the profile's
    /// Message control performs.
    case person(UserID)
    case game(ApplicationID)
}

/// One thing the switcher can rank.
///
/// Deliberately small: an id, the folded text it matches on, and the id its
/// score is filed under. Everything a *row* draws — an avatar URL, a category
/// name, a mention count — is resolved for the twenty candidates that survive
/// ranking and never for the five thousand that are scored. Building a URL per
/// channel per open is the cost that makes a switcher feel slow to summon.
struct QuickSwitchCandidate: Hashable, Sendable {
    var target: QuickSwitchTarget
    /// The name, folded once by `QuickSwitchRank.fold`.
    var key: String
    /// A second string worth matching — a person's handle, which is how anybody
    /// who is not in the account's roster gets found. Nil elsewhere.
    var alternate: String?
    /// Which sigil narrows to this.
    var kind: QuickSwitchFilter
    /// The snowflake this candidate's frecency is filed under: a channel's own
    /// id, a guild's own id, or — for a person — the conversation with them.
    /// Zero where there is nothing to look up, which is a real answer.
    var frecencyID: UInt64
}

/// One row of the switcher.
///
/// **Three text slots and they are not interchangeable**, which is what the
/// reference client's own rows show: a handle sits beside a name at the name's
/// own size, and a category or a kind is set small and in caps. One slot drawn
/// two ways would mean uppercasing somebody's handle.
nonisolated struct QuickSwitchRow: Hashable, Sendable, Identifiable {
    var target: QuickSwitchTarget
    var title: String
    /// A person's handle, beside their name.
    var subtitle: String?
    /// A channel's category, or the kind of thing this is when nothing better
    /// names it. Drawn small and uppercased, exactly as the sidebar draws a
    /// category heading — one convention, two surfaces.
    var label: String?
    /// Right-aligned at the far end — the server a channel is in, and nothing
    /// else. It is the answer to "which #general is this", which on an account
    /// with ninety-seven servers is the only question that matters.
    var trailing: String?
    var symbolName: String?
    var iconURL: URL?
    var monogram: String?
    /// Drawn on the avatar. Only ever set for a person.
    var status: PresenceStatus?
    var mentionCount = 0
    var isUnread = false
    /// Whether the picture is a face. A person is a circle and everything else
    /// is a squircle, which is the same split every other list in this app makes.
    var isPerson = false
    /// A channel's server, as a picture: its icon, or its initials. The row
    /// leads with it, so two `#general`s are told apart at a glance.
    var serverIconURL: URL?
    var serverMonogram: String?

    var id: QuickSwitchTarget { target }
}

/// A titled group of rows.
struct QuickSwitchSection: Hashable, Sendable, Identifiable {
    var id: String
    /// Nil for the one list a ranked search produces, which needs no heading —
    /// the field above it already says what the rows are answering.
    var title: String?
    var rows: [QuickSwitchRow]
}

/// What the candidate snapshot is memoized on.
///
/// Every counter here can change the *set* of places the account has; none of
/// them moves when a message arrives. Frecency is deliberately absent: it is
/// read at ranking time rather than baked in, so the table landing re-orders the
/// list without rebuilding it.
struct QuickSwitchMemoKey: Hashable, Sendable {
    var structureRevision: UInt64
    var roleRevision: UInt64
    var identityRevision: UInt64
    var memberRevision: UInt64
    var railRevision: UInt64
}
