import Foundation

/// A Server Hub's gaming leaderboard: a week-long competition over one stat.
///
/// **Discord's shape and Discord's rules** (`9346354634fbc53a`): the top twenty
/// and the reader, a board that needs three people before it shows, a badge
/// counting the days left from the week's start, and a podium on its last day.
public struct GuildSpaceLeaderboard: Hashable, Sendable {
    public var stat: Stat
    /// What next week's competition is about, for the line under an ended one.
    public var nextStat: Stat
    /// When this week's competition began.
    public var weekStart: Date
    /// Today, as Discord's Pacific-time day ("2026-11-16").
    public var dayPT: String?
    /// When the standings were last worked out.
    public var computedAt: Date?
    public var entries: [Entry]

    public enum Stat: Int, Hashable, Sendable {
        case unspecified = 0
        case hoursPlayed = 1
        case daysPlayed = 2
        case uniqueGamesPlayed = 3

        /// Discord's title for the competition.
        public var name: String {
            switch self {
            case .hoursPlayed, .unspecified: "Most Game Time"
            case .daysPlayed: "Most Game Days"
            case .uniqueGamesPlayed: "Most Unique Games"
            }
        }

        /// The competition as a question, for the badge's tooltip.
        public var question: String {
            switch self {
            case .hoursPlayed, .unspecified: "Who has the most total game time?"
            case .daysPlayed: "Who has played on the most days?"
            case .uniqueGamesPlayed: "Who has played the most unique games?"
            }
        }
    }

    public struct Entry: Hashable, Sendable, Identifiable {
        public var userID: UserID
        public var rank: Int
        /// Milliseconds of play for game time; days or games for the others.
        public var value: Double
        /// The total time behind a count of days or games, for the line under it.
        public var timePlayedSeconds: Int?
        /// The games played, most recent first.
        public var applicationIDs: [ApplicationID]
        /// How many games in all — more than the ids, past the first few.
        public var applicationCount: Int

        public var id: UserID { userID }

        public init(
            userID: UserID,
            rank: Int,
            value: Double,
            timePlayedSeconds: Int? = nil,
            applicationIDs: [ApplicationID] = [],
            applicationCount: Int = 0
        ) {
            self.userID = userID
            self.rank = rank
            self.value = value
            self.timePlayedSeconds = timePlayedSeconds
            self.applicationIDs = applicationIDs
            self.applicationCount = max(applicationCount, applicationIDs.count)
        }
    }

    public init(
        stat: Stat,
        nextStat: Stat,
        weekStart: Date,
        dayPT: String? = nil,
        computedAt: Date? = nil,
        entries: [Entry]
    ) {
        self.stat = stat
        self.nextStat = nextStat
        self.weekStart = weekStart
        self.dayPT = dayPT
        self.computedAt = computedAt
        self.entries = entries
    }

    /// Discord shows the standings once three people are on them.
    public var hasEnoughEntries: Bool { entries.count >= 3 }

    /// When this week's competition ends: a week after it began.
    public var endsAt: Date { weekStart.addingTimeInterval(7 * 86_400) }

    /// Whole days left, rounded up as Discord's badge does ("1d left" on the
    /// last day); nil once it has ended.
    public func daysLeft(now: Date = .now) -> Int? {
        let remaining = endsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return Int((remaining / 86_400).rounded(.up))
    }

    /// Whether today is the competition's last day, when Discord raises the
    /// podium: `day_pt` falls on the week's seventh day.
    ///
    /// **Read the way Discord reads it**: `new Date(day_pt)`, then whole UTC
    /// days (`eN` in its hub module). That accepts a bare date
    /// ("2026-11-16", UTC midnight) and a full timestamp
    /// ("2026-11-16T00:00:00.000Z", which is what Discord's own fixtures write).
    /// This used to accept the bare date only, so a timestamp left the podium
    /// down on a board that had ended (Alex's account, 2026-11-17).
    public var isFinalDay: Bool {
        guard let dayPT, let day = Self.date(fromDayPT: dayPT) else { return false }
        let start = Int((weekStart.timeIntervalSince1970 / 86_400).rounded(.down))
        return Int((day.timeIntervalSince1970 / 86_400).rounded(.down)) == start + 6
    }

    /// `day_pt` as a moment: a date alone is UTC midnight, as JavaScript reads
    /// a date-only ISO string; a timestamp is read with its own offset.
    static func date(fromDayPT text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let day = dayFormat.date(from: trimmed) { return day }
        if let moment = try? Date(trimmed, strategy: .iso8601) { return moment }
        if let moment = try? Date(
            trimmed,
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        ) {
            return moment
        }
        return nil
    }

    /// The reader's place, wherever they rank.
    public func entry(for userID: UserID?) -> Entry? {
        guard let userID else { return nil }
        return entries.first { $0.userID == userID }
    }

    /// The rows a card shows: the top `limit`, then the reader's own when they
    /// rank below it — Discord's twenty-and-you.
    public func visibleEntries(limit: Int = 20, reader: UserID?) -> [Entry] {
        let top = Array(entries.prefix(limit))
        guard let own = entry(for: reader), !top.contains(own) else { return top }
        return top + [own]
    }

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
