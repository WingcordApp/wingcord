import Foundation

/// One entry of somebody's content inventory: a thing they did, recently.
///
/// This is what Discord's profile calls **Recent Activity**, and it is a
/// different fact from a presence. A presence is what somebody is doing *now*
/// and vanishes the moment they stop; an inventory entry is a durable record
/// with a beginning, an end and a set of **traits** — the small chips that say
/// "20x Streak", "Trending", "New Player".
///
/// **Everything below is out of a capture** — `GET /content-inventory/users/
/// {id}/outbox`, September 2026, twenty-six entries across three shapes. The
/// wrapper differs by route and only the outbox is drawn here: the outbox
/// answers `{"entries": [content…]}` with the content objects bare, while the
/// inbox wraps each in `{"content": …, "rank": n}`.
///
/// **No playtime is derivable from this.** `duration_seconds` is the length of
/// *that one session*, not a total — the same game appears several times with
/// different durations — so it is drawn as "3h 20m" against that entry and
/// never summed into "312h played", which is the number the mockup invented.
public struct RecentActivity: Hashable, Sendable, Identifiable {
    public var id: String
    public var authorID: UserID
    /// What was done. The subject decides the row's picture and its two lines.
    public var subject: Subject
    /// The chips, in the order the payload sent them.
    public var traits: [Trait]
    public var startedAt: Date?
    /// When it finished. **Absent while it is still happening**, which is the
    /// only difference on the wire between a live entry and a finished one
    /// besides the `is_live` trait — a live entry carries `expires_at` instead.
    public var endedAt: Date?
    /// When a live entry stops counting as live, if nothing ends it first.
    public var expiresAt: Date?

    public init(
        id: String,
        authorID: UserID,
        subject: Subject,
        traits: [Trait] = [],
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.authorID = authorID
        self.subject = subject
        self.traits = traits
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.expiresAt = expiresAt
    }

    /// Whether this is happening now — Discord's own test (module `583846`'s
    /// `Hd`): live, and not past its `expires_at`.
    ///
    /// **An entry that is happening now is the current activity, not a recent
    /// one.** Discord's profile leaves it out of Recent activity (module
    /// `146655`) and draws its chips on the current card instead; listed in
    /// both, the game somebody is playing sat under itself.
    public func isOngoing(at now: Date) -> Bool {
        isLive && !(expiresAt.map { $0 < now } ?? false)
    }

    /// Whether this entry is the record of `activity` — Discord's match for a
    /// game (module `83971`'s `_`): the same application, or failing an id,
    /// the same name.
    public func records(_ activity: Activity) -> Bool {
        switch subject {
        case .game(let name, let applicationID), .activity(let name, let applicationID):
            if let applicationID, applicationID == activity.applicationID { return true }
            return name == activity.name
        case .listening:
            return false
        }
    }

    /// What the entry is about.
    ///
    /// **Keyed on `extra.type`, not on `content_type`.** Both are on the wire
    /// and they agree — `1` with `played_game_extra`, `8` with
    /// `launched_activity_extra`, `6` with `top_artist_extra` — but the string
    /// is the one that says what the *payload shape* is, and it is the shape
    /// that decides what can be read out of it. A content type this client has
    /// never seen then costs one dropped row rather than a misread one.
    public enum Subject: Hashable, Sendable {
        /// `played_game_extra`. The application id is what makes the row open a
        /// game profile.
        case game(name: String, applicationID: ApplicationID?)
        /// `launched_activity_extra` — an embedded activity, not a game.
        /// Wordle, Watch Together, Putt Party.
        case activity(name: String, applicationID: ApplicationID?)
        /// `top_artist_extra`, whose nested `media` is the track.
        ///
        /// The row prints the track over the artist, which is the order
        /// Discord's own list uses and the order that reads: a title nobody
        /// recognises under an artist they do is a row about the artist.
        case listening(track: String, artist: String?, artworkURL: URL?)

        /// The game or activity behind this row, when there is one to open.
        public var applicationID: ApplicationID? {
            switch self {
            case .game(_, let id), .activity(_, let id): id
            case .listening: nil
            }
        }

        /// The line the row is titled with.
        public var title: String {
            switch self {
            case .game(let name, _), .activity(let name, _): name
            case .listening(let track, _, _): track
            }
        }

        /// The second line, where the subject has one. Only music does.
        public var subtitle: String? {
            switch self {
            case .game, .activity: nil
            case .listening(_, let artist, _): artist
            }
        }

        /// The glyph that stands for this kind of thing, beside the timestamp.
        public var symbolName: String {
            switch self {
            case .game: "gamecontroller.fill"
            case .activity: "person.2.fill"
            case .listening: "music.note"
            }
        }
    }

    /// One chip on a row.
    ///
    /// **Only the trait types a capture named.** Eight of them appear across
    /// twenty-six entries — `1, 2, 3, 4, 6, 8, 9, 10, 11, 12` — and the ones
    /// left over are decoded as nothing rather than guessed at, because a chip
    /// with the wrong words in it is worse than a chip that is missing. Types
    /// `5` and `7` have never been captured; one of them is the "Returning
    /// after a month" chip Discord draws, and it stays undrawn until a capture
    /// says which.
    public enum Trait: Hashable, Sendable {
        /// `{"type": 1, "first_time": true}`.
        case newPlayer
        /// `{"type": 2, "duration_seconds": 5400}` — this session's length, not
        /// a total.
        case duration(TimeInterval)
        /// `{"type": 3, "is_live": true}` — still happening.
        case live
        /// `{"type": 6, "marathon": true}` — a long sitting.
        case marathon
        /// `{"type": 8, "streak_count_days": 8}`.
        case streak(days: Int)
        /// `{"type": 9, "trending": 1}`.
        case trending

        /// The chip's words, or nil for a trait that is a *state* rather than a
        /// label — `live` colours the row's timestamp and prints nothing of its
        /// own, and a duration is folded into that timestamp too.
        public var label: String? {
            switch self {
            case .newPlayer: "New Player"
            case .marathon: "Marathon"
            case .streak(let days): "\(days)x Streak"
            case .trending: "Trending"
            case .duration, .live: nil
            }
        }

        /// The mark in front of those words.
        public var symbolName: String? {
            switch self {
            case .newPlayer: "person.fill.badge.plus"
            case .marathon: "flame.fill"
            case .streak: "bolt.fill"
            case .trending: "chart.line.uptrend.xyaxis"
            case .duration, .live: nil
            }
        }
    }

    /// Whether this is still going on.
    public var isLive: Bool { traits.contains(.live) }

    /// How long that sitting lasted, when the payload said.
    public var duration: TimeInterval? {
        for trait in traits {
            if case .duration(let seconds) = trait { return seconds }
        }
        return nil
    }

    /// The instant the row dates itself from.
    ///
    /// **The end, falling back to the start.** A row reads "1d ago" about when
    /// the person *stopped*, and an entry still in flight has no end — for that
    /// one the start is right, because what it is saying is how long ago they
    /// began.
    public var occurredAt: Date? { endedAt ?? startedAt }
}
