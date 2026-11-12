import Foundation

/// What Discord knows about a relationship beyond its kind.
///
/// **Beside `Relationship` rather than on it, and beside `User` rather than in
/// it** — the same rule the reader's private note and their private nickname
/// already follow. `Relationship` is one slot with five values and it is
/// compared, switched on and stored by the thousand; these are three facts that
/// matter on exactly one surface, for the handful of people with a request
/// outstanding. Folding them in would put four words of padding on every
/// relationship the account has.
///
/// **All three were on the wire and read by nothing.** `RelationshipDTO`
/// decoded `id`, `type`, the ignore flag, `nickname` and `user`, and Discord sends
/// `since`, `is_spam_request` and `stranger_request` beside them on the same
/// object — documented, and present in the docs' own example payload. Without
/// `since` a friend-requests list has no ordering except the user id, which
/// sorts by when the *account* was made.
public struct RelationshipFacts: Hashable, Sendable {
    /// When they asked, or when the reader did.
    ///
    /// Optional because Discord omits it on relationships that were never a
    /// request — a friendship from before the field existed carries no `since`.
    /// A request without one sorts last; see `friendRequests(from:)`.
    public var since: Date?
    /// Discord flagged the request as spam. Its own signal, not a guess this
    /// client makes.
    public var isSpam: Bool
    /// They have no mutual friend and no small mutual server with the reader.
    ///
    /// **Not the same as spam and must not be drawn as it.** A stranger request
    /// is ordinary — somebody who found the reader by username — and Discord
    /// marks it so the reader can weigh it, not so it can be hidden.
    public var isStranger: Bool
    /// What they wrote with their request — `note` on the relationship.
    ///
    /// **Not the reader's private note about somebody**, which is a different
    /// store on a different route. Covered until the reader asks to see it, and
    /// absent altogether where they turned these off: see
    /// `AppModel.friendRequestNote(of:)`.
    public var note: String?

    public init(since: Date? = nil, isSpam: Bool = false, isStranger: Bool = false, note: String? = nil) {
        self.since = since
        self.isSpam = isSpam
        self.isStranger = isStranger
        self.note = note
    }

    /// Whether this is worth storing at all. A relationship with nothing
    /// remarkable about it does not earn a row in the table — see
    /// `SessionSnapshot.relationshipFacts`.
    public var isNoteworthy: Bool { since != nil || isSpam || isStranger || note != nil }
}

/// What may be sent as a friend request's note — Discord's rules (`237309`).
public enum FriendRequestNote {
    /// `XG`, and the counter the field draws against it.
    public static let maximumLength = 120

    /// The note as it goes on the wire: newlines become spaces, the ends are
    /// trimmed, and nothing left means no note at all. Nil too for one over the
    /// limit, which the server would refuse.
    public static func cleaned(_ raw: String) -> String? {
        guard raw.count <= maximumLength else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// One friend request, resolved for drawing.
public struct FriendRequest: Hashable, Sendable, Identifiable {
    public var id: UserID
    /// Incoming or outgoing. **Both are listed**, in that order: a request the
    /// reader sent is the other half of the same question, and a list that
    /// showed only incoming ones leaves them wondering whether theirs went out.
    public var isIncoming: Bool
    public var facts: RelationshipFacts

    public init(id: UserID, isIncoming: Bool, facts: RelationshipFacts = .init()) {
        self.id = id
        self.isIncoming = isIncoming
        self.facts = facts
    }
}

extension FriendRequest {

    /// The requests outstanding, incoming first and newest first within each.
    ///
    /// **Incoming before outgoing, because only one of the two is a question
    /// addressed to the reader.** An outgoing request is a thing they already
    /// did; sorting the two together by date would bury an answer somebody is
    /// waiting for underneath the reader's own sent requests.
    ///
    /// A request with no `since` sorts last within its half rather than first:
    /// `.distantPast` is the honest stand-in for "no date", and putting an
    /// undated row at the top would give it the position that belongs to the
    /// most recent one.
    public static func friendRequests(
        from relationships: [UserID: Relationship],
        facts: [UserID: RelationshipFacts]
    ) -> [FriendRequest] {
        var result: [FriendRequest] = []
        result.reserveCapacity(8)
        for (userID, kind) in relationships {
            switch kind {
            case .incomingRequest:
                result.append(
                    FriendRequest(id: userID, isIncoming: true, facts: facts[userID] ?? .init())
                )
            case .outgoingRequest:
                result.append(
                    FriendRequest(id: userID, isIncoming: false, facts: facts[userID] ?? .init())
                )
            case .none, .friend, .blocked:
                continue
            }
        }
        return result.sorted { left, right in
            if left.isIncoming != right.isIncoming { return left.isIncoming }
            let a = left.facts.since ?? .distantPast
            let b = right.facts.since ?? .distantPast
            // Ties broken on the id so the order is total: a `sorted(by:)` whose
            // predicate calls two elements equal may place them either way round
            // between runs, and a list that reshuffles itself while nothing
            // changed is the kind of defect nobody can reproduce.
            if a != b { return a > b }
            return left.id.rawValue > right.id.rawValue
        }
    }

    /// How many of those are addressed to the reader — the number the inbox's
    /// button wears. An outgoing request is not a badge: it is not waiting on
    /// anybody here.
    public static func incomingCount(of relationships: [UserID: Relationship]) -> Int {
        relationships.values.count { $0 == .incomingRequest }
    }
}
