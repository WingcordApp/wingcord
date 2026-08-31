import Foundation

/// What the account is to somebody else.
///
/// **One enum, and ignoring is deliberately not in it.** Discord's relationship
/// `type` is a single slot — you are either nothing, a friend, blocked, or
/// mid-request — while *ignoring* is a flag that rides alongside it. A client
/// that folded the two together would have to un-ignore a person in order to
/// friend them, which is not a thing the API does or a thing anybody means.
public enum Relationship: Int, Hashable, Sendable, Codable, CaseIterable {
    /// No relationship. Not stored — an absent entry means this.
    case none = 0
    case friend = 1
    case blocked = 2
    /// They asked; the reader has not answered.
    case incomingRequest = 3
    /// The reader asked; they have not answered.
    case outgoingRequest = 4

    /// Anything Discord adds after this file was written resolves to `none`,
    /// which offers Add Friend — the honest answer for a state this client
    /// cannot name, and the one that fails safe rather than hiding a person.
    public init(rawValue: Int) {
        self = switch rawValue {
        case 1: .friend
        case 2: .blocked
        case 3: .incomingRequest
        case 4: .outgoingRequest
        default: .none
        }
    }

    /// What the menu row says, or nil where no row is offered.
    ///
    /// **Blocked has no row here**, because the block toggle is its own control
    /// and one act must not be reachable by two names — a "Remove Friend" that
    /// silently unblocks is worse than no row at all.
    public var friendActionTitle: String? {
        switch self {
        case .none: "Add Friend"
        case .friend: "Remove Friend"
        case .incomingRequest: "Accept Friend Request"
        case .outgoingRequest: "Cancel Friend Request"
        case .blocked: nil
        }
    }

    /// Whether acting on the row *sends* a request rather than withdrawing one.
    /// Accepting an incoming request is the same `PUT` as sending one, which is
    /// the one piece of this that reads oddly and is Discord's design.
    public var friendActionAdds: Bool {
        self == .none || self == .incomingRequest
    }

    public var friendActionSymbol: String {
        switch self {
        case .none: "person.badge.plus"
        case .friend: "person.badge.minus"
        case .incomingRequest: "checkmark"
        case .outgoingRequest: "xmark"
        case .blocked: "hand.raised"
        }
    }

    /// Whether removing is destructive enough to be tinted. Withdrawing your own
    /// request is not; dropping a friend is.
    public var friendActionIsDestructive: Bool { self == .friend }
}
