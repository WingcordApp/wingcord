import Foundation
import WingcordCore

/// The Pending Applications folder at the head of the rail — Discord's `rc`
/// (`PENDING_JOIN_REQUESTS_FOLDER`): the servers the reader has an application
/// out to, drawn only while there is one.
struct PendingApplicationsRail: Hashable, Sendable {
    /// One tile per application whose server is known. Discord draws none
    /// until the server list has answered (`rl` returns null without one).
    var guilds: [RailGuild]
    var isOpen: Bool
    /// Discord's coachmark on the folder once an application has gone in:
    /// "Your application is pending!".
    var showsCoachmark: Bool
}

/// A right-click on a pending application's tile — Discord's `97187`.
struct JoinRequestMenuRequest: Identifiable, Hashable, Sendable {
    var guildID: GuildID
    /// The tile's frame, in the window root's space — see `SecondaryClickCatcher`.
    var anchor: CGRect

    var id: GuildID { guildID }
}

/// Discord's "Are you sure?" before an application is taken back.
struct WithdrawApplicationRequest: Identifiable, Hashable, Sendable {
    var guildID: GuildID
    var serverName: String?
    /// An application never sent is discarded rather than withdrawn, and the
    /// question says so.
    var isDiscard: Bool

    var id: GuildID { guildID }
}

/// What the status page draws — Discord's `995198`, the page a pending
/// application's tile opens.
struct JoinRequestStatusPresentation: Hashable, Sendable {
    var guildID: GuildID
    /// Nil until the server list has answered, and Discord's page has words
    /// for that too.
    var serverName: String?
    var splashURL: URL?
    var state: State
    /// A reapply on its way: the button waits.
    var isReapplying: Bool

    enum State: Hashable, Sendable {
        case submitted
        case rejected(reason: String?, canReapply: Bool)
        /// STARTED — a reapply not yet sent — and whatever else Discord's own
        /// switch falls through on.
        case unfinished
    }
}

/// Discord's "You are now a member of" — an approved application, the first
/// time the reader opens the server after it.
struct ApprovedApplicationNotice: Identifiable, Hashable, Sendable {
    var guildID: GuildID
    var serverName: String

    var id: GuildID { guildID }
}
