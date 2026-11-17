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
public struct RecentActivity: Hashable, Sendable, Identifiable, Codable {
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
    /// What the entry says beyond its subject — see `Details`.
    public var details: Details

    public init(
        id: String,
        authorID: UserID,
        subject: Subject,
        traits: [Trait] = [],
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        expiresAt: Date? = nil,
        details: Details = Details()
    ) {
        self.id = id
        self.authorID = authorID
        self.subject = subject
        self.traits = traits
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.expiresAt = expiresAt
        self.details = details
    }

    /// The rest of an entry's `extra`, read where Discord's cards and popouts
    /// draw it (docs/ACTIVITY-CARDS.md, `420018`).
    public struct Details: Hashable, Sendable, Codable {
        /// `extra.platform`: 1 Xbox, 2 PlayStation — the mark a popout wears.
        public var platform: Int?
        /// Music: the album (`media.parent_title`), what a top artist's
        /// popout is titled with.
        public var album: String?
        /// Spotify's ids for the artist and the album, which the popout's
        /// title and subtitle open.
        public var artistExternalID: String?
        public var albumExternalID: String?
        /// `media.provider`: 1 Spotify.
        public var provider: Int?
        /// Watched media: Discord's "Season 1, Episode 3" (`media_assets_large_text`),
        /// the picture's asset key, and the show's own link.
        public var episodeText: String?
        public var mediaImage: String?
        public var url: URL?
        /// The channel the entry happened in, where it names one.
        public var channelID: ChannelID?

        public init(
            platform: Int? = nil, album: String? = nil, artistExternalID: String? = nil,
            albumExternalID: String? = nil, provider: Int? = nil, episodeText: String? = nil,
            mediaImage: String? = nil, url: URL? = nil, channelID: ChannelID? = nil
        ) {
            self.platform = platform
            self.album = album
            self.artistExternalID = artistExternalID
            self.albumExternalID = albumExternalID
            self.provider = provider
            self.episodeText = episodeText
            self.mediaImage = mediaImage
            self.url = url
            self.channelID = channelID
        }

        /// Discord's short episode marker, "S1E3", out of "Season 1, Episode 3"
        /// (`583846`'s `kR`) — nil for words in another shape.
        public var episodeMarker: String? {
            guard let episodeText,
                  let regex = try? NSRegularExpression(pattern: #"\w+ (\d+), \w+ (\d+)"#),
                  let match = regex.firstMatch(in: episodeText, range: NSRange(episodeText.startIndex..., in: episodeText)),
                  let season = Range(match.range(at: 1), in: episodeText),
                  let episode = Range(match.range(at: 2), in: episodeText)
            else { return nil }
            return "S\(episodeText[season])E\(episodeText[episode])"
        }
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
        case .game(let name, let applicationID), .activity(let name, let applicationID),
             .topGame(let name, let applicationID):
            if let applicationID, applicationID == activity.applicationID { return true }
            return name == activity.name
        case .watched(_, _, let applicationID):
            return applicationID != nil && applicationID == activity.applicationID
        case .listening, .listeningSession:
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
    public enum Subject: Hashable, Sendable, Codable {
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
        /// `content_type: 3` — the game somebody played most this week, with
        /// the hours in its `duration` trait ("Most played: 12h").
        case topGame(name: String, applicationID: ApplicationID?)
        /// `content_type: 2` — a show watched through a connected app
        /// (Crunchyroll): its title and episode name.
        case watched(title: String, subtitle: String?, applicationID: ApplicationID?)
        /// `content_type: 5` — a Spotify session still playing: the first
        /// track, its artists, its cover. Discord draws it only while the
        /// author's presence still matches it.
        case listeningSession(track: String, artists: [String], artworkURL: URL?)

        /// The game or activity behind this row, when there is one to open.
        public var applicationID: ApplicationID? {
            switch self {
            case .game(_, let id), .activity(_, let id), .topGame(_, let id), .watched(_, _, let id): id
            case .listening, .listeningSession: nil
            }
        }

        /// The line the row is titled with.
        public var title: String {
            switch self {
            case .game(let name, _), .activity(let name, _), .topGame(let name, _): name
            case .listening(let track, _, _): track
            case .watched(let title, _, _): title
            case .listeningSession(let track, _, _): track
            }
        }

        /// The second line, where the subject has one.
        public var subtitle: String? {
            switch self {
            case .game, .activity, .topGame: nil
            case .listening(_, let artist, _): artist
            case .watched(_, let subtitle, _): subtitle
            case .listeningSession(_, let artists, _): artists.isEmpty ? nil : artists.joined(separator: ", ")
            }
        }

        /// The glyph that stands for this kind of thing, beside the timestamp.
        public var symbolName: String {
            switch self {
            case .game, .topGame: "gamecontroller.fill"
            case .activity: "square.grid.2x2.fill"
            case .listening, .listeningSession: "music.note"
            case .watched: "tv.fill"
            }
        }

        /// Whether this is about music — what the popout says "listened to" for.
        public var isMusic: Bool {
            switch self {
            case .listening, .listeningSession: true
            default: false
            }
        }
    }

    /// One chip on a row.
    ///
    /// **The trait types a capture named, and the two Discord's bundle
    /// names.** Ten appear across the captures — `1, 2, 3, 4, 6, 8, 9, 10,
    /// 11, 12`. Types `5` and `7` have not been captured, but Discord's own
    /// enum (`974690`) names them — `RESURRECTED` and `NEW_RELEASE` — and its
    /// card reads `5`'s `resurrected_last_played` as "Returning after a
    /// month" (`583846`). Anything else decodes as nothing, because a chip
    /// with the wrong words in it is worse than a chip that is missing.
    public enum Trait: Hashable, Sendable, Codable {
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
        /// `{"type": 5, "resurrected_last_played": …}` — back after a while
        /// away, and when they last played before that.
        case returning(lastPlayed: Date)
        /// `{"type": 12, "count": 130}` — how many tracks this week, on a top
        /// artist.
        case weeklyCount(Int)
        /// `{"type": 4, "range": 1}` — the entry counts a week. Discord draws a
        /// top artist or top game only over a week (`ua.j.WEEK`).
        case week

        /// The chip's words, or nil for a trait that is a *state* rather than a
        /// label — `live` colours the row's timestamp and prints nothing of its
        /// own, and a duration is folded into that timestamp too.
        public var label: String? {
            switch self {
            case .newPlayer: "New Player"
            case .marathon: "Marathon"
            case .streak(let days): "\(days)x Streak"
            case .trending: "Trending"
            case .returning(let lastPlayed): Self.returningLabel(since: lastPlayed, now: .now)
            case .duration, .live, .weeklyCount, .week: nil
            }
        }

        /// Discord's "Returning after 2 months" (`583846`'s `L`): months, or
        /// weeks under a month, or days under a week.
        public static func returningLabel(since lastPlayed: Date, now: Date) -> String {
            let calendar = Calendar(identifier: .gregorian)
            let parts = calendar.dateComponents([.month, .day], from: lastPlayed, to: now)
            let months = max(parts.month ?? 0, 0)
            let days = max(parts.day ?? 0, 0)
            func count(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s")" }
            if months > 0 { return "Returning after \(count(months, "month"))" }
            if days >= 7 { return "Returning after \(count(days / 7, "week"))" }
            return "Returning after \(count(days, "day"))"
        }

        /// The mark in front of those words.
        public var symbolName: String? {
            switch self {
            case .newPlayer: "person.fill.badge.plus"
            case .marathon: "flame.fill"
            case .streak: "bolt.fill"
            case .trending: "chart.line.uptrend.xyaxis"
            case .returning: "arrow.clockwise"
            case .duration, .live, .weeklyCount, .week: nil
            }
        }
    }

    /// Whether this is still going on.
    public var isLive: Bool { traits.contains(.live) }

    /// Whether the entry counts a week — Discord's gate for a top artist or
    /// a top game card.
    public var isWeekly: Bool { traits.contains(.week) }

    /// How many tracks this week, on a top artist.
    public var weeklyCount: Int? {
        for trait in traits {
            if case .weeklyCount(let count) = trait { return count }
        }
        return nil
    }

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
