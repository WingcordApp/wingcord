import Foundation

/// One entry of the reader's activity feed — what people they talk to did,
/// as `GET /content-inventory/users/@me` ranks it for them.
///
/// **The entry as sent is kept whole**, because a reply to it carries it back:
/// Discord's DM sends the content object as `content_inventory_entry.
/// unverified_content` (`428249`), signature and all, and a re-encoding of the
/// fields this client reads would not be the entry the server signed.
public struct ActivityFeedEntry: Hashable, Sendable, Identifiable {
    public var activity: RecentActivity
    /// The server's order, best first.
    public var rank: Int
    /// Everybody it is about — the author first, and anyone who did it with
    /// them.
    public var participants: [UserID]
    /// The content object, byte for byte.
    public var raw: Data

    public var id: String { activity.id }

    public init(activity: RecentActivity, rank: Int, participants: [UserID], raw: Data) {
        self.activity = activity
        self.rank = rank
        self.participants = participants
        self.raw = raw
    }

    /// When it happened, by its id — Discord's clock for these cards. Nil for
    /// an id that is not a snowflake, which a top-artist entry's is not.
    public var snowflakeDate: Date? {
        guard let value = UInt64(activity.id), value > (1 << 32) else { return nil }
        return Date(timeIntervalSince1970: Double((value >> 22) + 1_420_070_400_000) / 1000)
    }
}

/// The reader's feed, and when to ask again.
public struct ActivityInbox: Hashable, Sendable {
    public var entries: [ActivityFeedEntry]
    /// Sent back on the next fetch, so the server answers with what changed.
    public var refreshToken: String?
    /// When the server wants to be asked again — `wait_ms_until_next_fetch`
    /// from now, as Discord sets `expired_at`.
    public var expiresAt: Date?
    /// Whether the server will say when the feed goes stale — the gateway's
    /// `CONTENT_INVENTORY_INBOX_STALE` — rather than leaving it to the expiry.
    public var announcesStaleness: Bool

    public init(entries: [ActivityFeedEntry], refreshToken: String?, expiresAt: Date?, announcesStaleness: Bool) {
        self.entries = entries
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.announcesStaleness = announcesStaleness
    }
}

// MARK: - Discord's rules for the member list's cards

/// The member list's Activity section, rule for rule: which servers have one
/// (`376261`), which entries it may show (`946228`, `808323`), and what the
/// cards say (`506326`, `583846`).
public enum ActivityCardRules {

    /// How many cards the section shows until it is expanded.
    public static let collapsedCount = 3

    /// Whether a server shows the section: what its members chose, where they
    /// chose — `ACTIVITY_FEED_ENABLED_BY_USER` or `…_DISABLED_BY_USER` — and
    /// otherwise only below ten thousand members. Never beside a forum.
    public static func isOffered(features: Set<String>, memberCount: Int?, isForum: Bool) -> Bool {
        guard !isForum else { return false }
        let enabled = features.contains("ACTIVITY_FEED_ENABLED_BY_USER")
        if enabled || features.contains("ACTIVITY_FEED_DISABLED_BY_USER") { return enabled }
        return (memberCount ?? .max) < 10_000
    }

    /// The entries the section may show, in the server's order.
    ///
    /// - Parameters:
    ///   - canSee: whether the author is a member here who may see the
    ///     channel — the section is the channel's audience's.
    ///   - mutedOrBlocked: people whose conversation the reader muted, or who
    ///     are blocked; an entry naming any of them is left out.
    ///   - offline: people who are offline or invisible — whose "live" entry
    ///     has outlived them.
    ///   - capped: entries the reader has seen for three days.
    public static func cards(
        from entries: [ActivityFeedEntry],
        canSee: (UserID) -> Bool,
        mutedOrBlocked: Set<UserID>,
        offline: Set<UserID>,
        capped: Set<String>,
        now: Date
    ) -> [ActivityFeedEntry] {
        entries
            .sorted { $0.rank < $1.rank }
            .filter { entry in
                let author = entry.activity.authorID
                guard canSee(author) else { return false }
                guard !entry.participants.contains(where: mutedOrBlocked.contains),
                      !mutedOrBlocked.contains(author)
                else { return false }
                let isLive = entry.activity.isLive
                if isLive, offline.contains(author) { return false }
                // A live entry is never capped (`583846`'s `JM`).
                return isLive || !capped.contains(entry.id)
            }
    }

    /// "12m ago", "3h ago", "2d ago" — Discord's short clock (`583846`'s
    /// `aJ`): seconds under a minute, minutes under an hour, hours under
    /// twelve, days under nine, weeks under four, then months.
    public static func timeAgo(since date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        let magnitude = abs(seconds)
        if magnitude < 60 { return "\(Int(seconds))s ago" }
        if magnitude < 3600 { return "\(Int((seconds / 60).rounded()))m ago" }
        if magnitude < 12 * 3600 { return "\(Int((seconds / 3600).rounded()))h ago" }
        if magnitude < 9 * 86_400 { return "\(Int((seconds / 86_400).rounded()))d ago" }
        if magnitude < 28 * 86_400 { return "\(Int((seconds / (7 * 86_400)).rounded()))w ago" }
        return "\(Int((seconds / (30 * 86_400)).rounded()))mo ago"
    }

    /// "4:07", "1:02:33" — the running clock on a card for something still
    /// going on.
    public static func elapsed(since start: Date, now: Date) -> String {
        let total = max(Int(now.timeIntervalSince(start)), 0)
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        let paddedSeconds = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        guard hours > 0 else { return "\(minutes):\(paddedSeconds)" }
        let paddedMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        return "\(hours):\(paddedMinutes):\(paddedSeconds)"
    }

    /// The streak chip shows from three days, and only on an entry from the
    /// last two days (`583846`'s `M`).
    public static func showsStreak(days: Int, entryDate: Date?, now: Date) -> Bool {
        guard days >= 3, let entryDate else { return false }
        return now.timeIntervalSince(entryDate) <= 48 * 3600
    }

    /// A game released in the last week wears "New Release" — read off the
    /// application's own id (`506326`'s `eu`).
    public static func isNewRelease(_ applicationID: ApplicationID?, now: Date) -> Bool {
        guard let applicationID else { return false }
        let created = Date(
            timeIntervalSince1970: Double((applicationID.rawValue >> 22) + 1_420_070_400_000) / 1000
        )
        return now.timeIntervalSince(created) <= 7 * 86_400
    }
}

// MARK: - What the reader has already seen

/// Each entry the section showed, and when first — Discord's impression
/// record (`435738`). An entry first shown more than three days ago is not
/// shown again; the record keeps thirty days, and two thousand entries at most.
public struct ActivityImpressions: Codable, Hashable, Sendable {
    public struct Sighting: Codable, Hashable, Sendable {
        public var id: String
        public var at: Date
    }

    public private(set) var sightings: [Sighting] = []

    public static let capAfter: TimeInterval = 3 * 86_400
    public static let keptFor: TimeInterval = 30 * 86_400
    public static let limit = 2048

    public init() {}

    /// Records the first sight of each id not already recorded. Answers
    /// whether anything changed.
    @discardableResult
    public mutating func record(_ ids: [String], at now: Date) -> Bool {
        let known = Set(sightings.map(\.id))
        var changed = false
        for id in ids where !known.contains(id) {
            sightings.append(Sighting(id: id, at: now))
            changed = true
        }
        let pruned = prune(now: now)
        return changed || pruned
    }

    /// The entries no longer to be shown.
    public func capped(at now: Date) -> Set<String> {
        Set(sightings.lazy.filter { now.timeIntervalSince($0.at) > Self.capAfter }.map(\.id))
    }

    private mutating func prune(now: Date) -> Bool {
        let before = sightings.count
        sightings.removeAll { now.timeIntervalSince($0.at) > Self.keptFor }
        if sightings.count > Self.limit { sightings.removeFirst(sightings.count - Self.limit) }
        return sightings.count != before
    }
}
