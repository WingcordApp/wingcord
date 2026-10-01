import Foundation

// MARK: - A scheduled event
//
// Everything below is from a captured `POST /guilds/{id}/scheduled-events` and
// its response, except the recurrence rule — see `Recurrence`, which says so.
//
// The one surprise in the capture is its **size**: 3.3 MB of request for one
// event, because the cover image goes in the JSON body as a `data:` URI. That
// is the emoji route's encoding rather than the sticker route's multipart, and
// there is no way to know which of the two a given upload uses except by
// watching one happen.

public struct ScheduledEvent: Hashable, Sendable, Identifiable {
    public var id: UInt64
    public var guildID: GuildID
    public var name: String
    public var description: String?
    public var creatorID: UserID?
    /// The cover, as a hash. Sent as a data URI and returned as a hash — the
    /// asymmetry every image field on these routes has.
    public var imageHash: String?
    public var startsAt: Date
    /// Required for an external event and optional for the other two, because a
    /// voice event ends when everybody leaves.
    public var endsAt: Date?
    public var status: Status
    public var location: Location
    public var recurrence: Recurrence?
    /// The rule itself, which the series' dates are computed from — see
    /// `RecurrenceRule`. `recurrence` is the editor's preset reading of it.
    public var rule: RecurrenceRule?
    /// The dates an organiser moved or cancelled, by occurrence.
    public var exceptions: [Exception]
    /// Who made it. A record the event carries, so the people list need not
    /// have met them.
    public var creator: User?
    /// How many people said they were interested. From
    /// `GET .../users/counts`, which is a separate request — the event object
    /// itself carries `user_count` only when it was asked for.
    public var interestedCount: Int?
    /// Whether the reader is one of them.
    public var isInterested: Bool

    public init(
        id: UInt64,
        guildID: GuildID,
        name: String,
        description: String? = nil,
        creatorID: UserID? = nil,
        imageHash: String? = nil,
        startsAt: Date,
        endsAt: Date? = nil,
        status: Status = .scheduled,
        location: Location,
        recurrence: Recurrence? = nil,
        rule: RecurrenceRule? = nil,
        exceptions: [Exception] = [],
        creator: User? = nil,
        interestedCount: Int? = nil,
        isInterested: Bool = false
    ) {
        self.id = id
        self.guildID = guildID
        self.name = name
        self.description = description
        self.creatorID = creatorID
        self.imageHash = imageHash
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.status = status
        self.location = location
        self.recurrence = recurrence
        self.rule = rule
        self.exceptions = exceptions
        self.creator = creator
        self.interestedCount = interestedCount
        self.isInterested = isInterested
    }

    public var coverURL: URL? {
        imageHash.flatMap { CDN.scheduledEventCover(eventID: id, hash: $0) }
    }

    /// One date of a series that an organiser moved or cancelled —
    /// `guild_scheduled_event_exceptions` on the event.
    public struct Exception: Hashable, Sendable {
        /// The occurrence it changes — see `occurrenceID(startingAt:)`.
        public var id: UInt64
        public var startsAt: Date?
        public var endsAt: Date?
        public var isCanceled: Bool

        public init(id: UInt64, startsAt: Date? = nil, endsAt: Date? = nil, isCanceled: Bool = false) {
            self.id = id
            self.startsAt = startsAt
            self.endsAt = endsAt
            self.isCanceled = isCanceled
        }
    }

    // MARK: Occurrences
    //
    // Discord names one date of a series by a snowflake whose timestamp is
    // that date's ORIGINAL start, floored to the second, with nothing else in
    // it — `fromTimestamp(floor(t / 1000) * 1000)`. Every per-date answer is
    // keyed on it: the interested counts, a single date's RSVP, its exception.

    private static let discordEpoch: UInt64 = 1_420_070_400_000

    /// The occurrence id for a date of a series starting at `date`.
    public static func occurrenceID(startingAt date: Date) -> UInt64 {
        let milliseconds = UInt64(max(0, floor(date.timeIntervalSince1970))) * 1000
        return (milliseconds - min(milliseconds, discordEpoch)) << 22
    }

    /// The original start an occurrence id stands for.
    public static func originalStart(ofOccurrence id: UInt64) -> Date {
        Date(timeIntervalSince1970: Double((id >> 22) + discordEpoch) / 1000)
    }

    /// The date of the series that is current — Discord's `G3`: the event's
    /// own start, which the server moves on to the next date as each one
    /// ends. Nil for an event that does not repeat.
    public var currentOccurrenceID: UInt64? {
        rule == nil ? nil : Self.occurrenceID(startingAt: startsAt)
    }

    public func exception(for occurrence: UInt64?) -> Exception? {
        guard let occurrence else { return nil }
        return exceptions.first { $0.id == occurrence }
    }

    /// When one date of the series starts and ends: its original start, the
    /// event's own length after it, and whatever an exception moved.
    /// Discord's `YR`. For an event that does not repeat, the event's own.
    public func span(of occurrence: UInt64?) -> (start: Date, end: Date?) {
        guard rule != nil, let occurrence else { return (startsAt, endsAt) }
        let start = Self.originalStart(ofOccurrence: occurrence)
        let end = endsAt.map { start.addingTimeInterval($0.timeIntervalSince(startsAt)) }
        guard let moved = exception(for: occurrence) else { return (start, end) }
        return (moved.startsAt ?? start, moved.endsAt ?? end)
    }

    /// One date's own status where it has one — Discord's `j`: cancelled by
    /// its exception, over when it started before the series' current date,
    /// scheduled when an exception names it, and otherwise the event's.
    public func status(of occurrence: UInt64?) -> Status {
        guard rule != nil, let occurrence else { return status }
        let moved = exception(for: occurrence)
        if moved?.isCanceled == true { return .canceled }
        if span(of: occurrence).start < startsAt { return .completed }
        if moved != nil { return .scheduled }
        return occurrence == currentOccurrenceID ? status : .scheduled
    }

    /// The next dates of the series from now, as "Events in series" lists
    /// them: from the later of the event's start and now, no more than four
    /// years out — Discord's `er`.
    public func upcomingOccurrences(limit: Int, after: Date? = nil, now: Date = .now) -> [UInt64] {
        guard let rule else { return [] }
        let from = after.map { $0.addingTimeInterval(1) } ?? max(startsAt, now)
        let until = Calendar(identifier: .gregorian).date(byAdding: .year, value: 4, to: now) ?? now
        return rule.occurrences(from: from, until: until, limit: limit)
            .map(Self.occurrenceID(startingAt:))
    }

    /// Where it happens.
    ///
    /// **An enum, not a channel plus an optional string.** The wire carries
    /// `entity_type`, `channel_id` and `entity_metadata.location`, and exactly
    /// one combination of the three is valid per type — a struct holding all
    /// three has two fields that are always nil, and the encoder would have to
    /// re-derive which. The captured external event sent `channel_id: null`
    /// *explicitly* beside a populated location.
    public enum Location: Hashable, Sendable {
        case stage(ChannelID)
        case voice(ChannelID)
        case external(String)
        /// An entity type this client has not seen. Drawn by name and, unlike
        /// the three above, **not editable** — a save would have to guess which
        /// of the three fields it wanted.
        case unrecognised(Int)

        public init(entityType: Int, channelID: ChannelID?, location: String?) {
            switch (entityType, channelID) {
            case (1, let id?): self = .stage(id)
            case (2, let id?): self = .voice(id)
            case (3, _): self = .external(location ?? "")
            default: self = .unrecognised(entityType)
            }
        }

        public var entityType: Int {
            switch self {
            case .stage: 1
            case .voice: 2
            case .external: 3
            case .unrecognised(let value): value
            }
        }

        public var channelID: ChannelID? {
            switch self {
            case .stage(let id), .voice(let id): id
            case .external, .unrecognised: nil
            }
        }

        public var externalLocation: String? {
            if case .external(let value) = self { return value }
            return nil
        }

        public var isEditable: Bool {
            if case .unrecognised = self { return false }
            return true
        }

        public var symbolName: String {
            switch self {
            case .stage: "person.wave.2.fill"
            case .voice: "speaker.wave.2.fill"
            case .external: "mappin.and.ellipse"
            case .unrecognised: "questionmark"
            }
        }
    }

    public enum Status: Hashable, Sendable {
        case scheduled
        case active
        case completed
        case canceled
        case unrecognised(Int)

        public init(rawValue: Int) {
            self = switch rawValue {
            case 1: .scheduled
            case 2: .active
            case 3: .completed
            case 4: .canceled
            default: .unrecognised(rawValue)
            }
        }

        public var rawValue: Int {
            switch self {
            case .scheduled: 1
            case .active: 2
            case .completed: 3
            case .canceled: 4
            case .unrecognised(let value): value
            }
        }

        public var title: String {
            switch self {
            case .scheduled: "Scheduled"
            case .active: "Happening now"
            case .completed: "Ended"
            case .canceled: "Cancelled"
            case .unrecognised(let value): "Status \(value)"
            }
        }

        /// Whether the event can still be edited or cancelled. A completed or
        /// cancelled event refuses both, so the row offers neither.
        public var isLive: Bool {
            switch self {
            case .scheduled, .active: true
            case .completed, .canceled, .unrecognised: false
            }
        }
    }
}

// MARK: - Recurrence

/// How often an event repeats.
///
/// **The labels are captured and the payloads are not.** Discord's Event
/// Frequency menu offers exactly the seven cases below — read off the open menu,
/// which names the chosen day and date: "Weekly on Wednesday", "Monthly on the
/// second Wednesday", "Annually on Sep 09". The captured event was created with
/// `recurrence_rule: null`, so what each of the other six *sends* comes from
/// Discord's documentation rather than from a request.
///
/// That is why this is a small closed set rather than an editor over
/// `frequency`/`interval`/`by_weekday`/`by_n_weekday`/`by_month`: seven presets
/// whose shapes are documented can be built and checked; a general editor would
/// let somebody compose a rule no capture supports and no test covers.
public enum Recurrence: Hashable, Sendable {
    case weekly(weekday: Int)
    case biweekly(weekday: Int)
    /// The nth weekday of each month — "the second Wednesday".
    case monthly(week: Int, weekday: Int)
    case annually(month: Int, day: Int)
    case daily
    case weekdays
    /// A rule this client cannot express. Kept so an event built in Discord's
    /// own client is not silently made non-recurring by an edit here.
    case unrecognised

    /// Discord's frequency enum: 0 yearly, 1 monthly, 2 weekly, 3 daily.
    ///
    /// **Weekdays is a daily rule** limited to five days — Discord's own preset
    /// (`DAILY` with `byweekday`), which its "Repeats every weekday" line is
    /// read from. Written as a five-day weekly rule it listed the same dates
    /// but read in Discord's client as "Repeats every Monday".
    public var frequency: Int {
        switch self {
        case .weekly, .biweekly: 2
        case .monthly: 1
        case .annually: 0
        case .daily, .weekdays: 3
        case .unrecognised: 2
        }
    }

    public var interval: Int {
        if case .biweekly = self { return 2 }
        return 1
    }

    /// 0 is Monday, 6 is Sunday — **not** `Calendar`'s numbering, which starts
    /// at Sunday and is 1-based. Converting between the two is the one arithmetic
    /// mistake this type exists to contain.
    public var byWeekday: [Int]? {
        switch self {
        case .weekly(let day), .biweekly(let day): [day]
        case .weekdays: [0, 1, 2, 3, 4]
        case .monthly, .annually, .daily, .unrecognised: nil
        }
    }

    public var byNWeekday: [(n: Int, day: Int)]? {
        if case .monthly(let week, let day) = self { return [(week, day)] }
        return nil
    }

    public var byMonth: [Int]? {
        if case .annually(let month, _) = self { return [month] }
        return nil
    }

    public var byMonthDay: [Int]? {
        if case .annually(_, let day) = self { return [day] }
        return nil
    }

    /// Reads a rule back. Anything that is not one of the six presets becomes
    /// `.unrecognised` rather than being approximated to the nearest one.
    public init?(
        frequency: Int,
        interval: Int,
        byWeekday: [Int]?,
        byNWeekday: [(n: Int, day: Int)]?,
        byMonth: [Int]?,
        byMonthDay: [Int]?
    ) {
        switch (frequency, interval, byWeekday, byNWeekday, byMonth, byMonthDay) {
        // A five-day weekly rule is how this client used to write weekdays.
        case (3, 1, [0, 1, 2, 3, 4]?, _, _, _), (2, 1, [0, 1, 2, 3, 4]?, _, _, _):
            self = .weekdays
        case (3, 1, nil, _, _, _), (3, 1, []?, _, _, _):
            self = .daily
        case (2, 1, let days?, _, _, _) where days.count == 1:
            self = .weekly(weekday: days[0])
        case (2, 2, let days?, _, _, _) where days.count == 1:
            self = .biweekly(weekday: days[0])
        case (1, 1, _, let entries?, _, _) where entries.count == 1:
            self = .monthly(week: entries[0].n, weekday: entries[0].day)
        case (0, 1, _, _, let months?, let days?) where months.count == 1 && days.count == 1:
            self = .annually(month: months[0], day: days[0])
        // Any other daily rule names its days — Discord's weekends, or a week
        // shifted into UTC — and reading it as every day would rewrite it on
        // the next save.
        default:
            self = .unrecognised
        }
    }

    /// What the menu says, given the event's own start date.
    ///
    /// The day and date come from the event rather than from the rule, which is
    /// what makes "Weekly on Wednesday" read correctly for an event that starts
    /// on a Wednesday — Discord's menu is built the same way.
    public func title(startingAt start: Date) -> String {
        switch self {
        case .weekly: "Weekly on \(Self.weekdayName(start))"
        case .biweekly: "Every other \(Self.weekdayName(start))"
        case .monthly(let week, _): "Monthly on the \(Self.ordinal(week)) \(Self.weekdayName(start))"
        case .annually: "Annually on \(start.formatted(.dateTime.month(.abbreviated).day()))"
        case .daily: "Every day"
        case .weekdays: "Every weekday (Monday to Friday)"
        case .unrecognised: "Custom"
        }
    }

    /// The six the menu offers for a given start date, in Discord's order.
    ///
    /// `unrecognised` is never offered — only kept when it is what the event
    /// already holds.
    public static func choices(startingAt start: Date) -> [Recurrence] {
        let weekday = discordWeekday(start)
        return [
            .weekly(weekday: weekday),
            .biweekly(weekday: weekday),
            .monthly(week: weekOfMonth(start), weekday: weekday),
            .annually(
                month: Calendar.current.component(.month, from: start),
                day: Calendar.current.component(.day, from: start)
            ),
            .daily,
            .weekdays,
        ]
    }

    /// `Calendar`'s 1-based Sunday-first weekday, as Discord's 0-based
    /// Monday-first one.
    public static func discordWeekday(_ date: Date) -> Int {
        (Calendar.current.component(.weekday, from: date) + 5) % 7
    }

    /// Which occurrence of its weekday this date is within its month — the "2"
    /// in "the second Wednesday".
    public static func weekOfMonth(_ date: Date) -> Int {
        let day = Calendar.current.component(.day, from: date)
        return (day - 1) / 7 + 1
    }

    private static func weekdayName(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    private static func ordinal(_ value: Int) -> String {
        switch value {
        case 1: "first"
        case 2: "second"
        case 3: "third"
        case 4: "fourth"
        default: "last"
        }
    }
}

// MARK: - Interest

/// One person's answer to an event — to the whole series, or to one date of it.
///
/// **Two levels, and the second can say no.** `scheduled event.har`'s list of
/// interested people carries both: series answers with no exception id, and
/// date answers with one — including a `response: 0`, somebody interested in
/// the series who said they would miss that one date.
public struct ScheduledEventRSVP: Hashable, Sendable {
    public enum Response: Int, Hashable, Sendable {
        case uninterested = 0
        case interested = 1
    }

    public var eventID: UInt64
    /// The date it is about, or nil for the whole series.
    public var occurrence: UInt64?
    public var userID: UserID
    public var response: Response

    public init(eventID: UInt64, occurrence: UInt64? = nil, userID: UserID, response: Response) {
        self.eventID = eventID
        self.occurrence = occurrence
        self.userID = userID
        self.response = response
    }
}

/// The interested counts the event route answers: the series', and each date
/// it was asked about — `GET …/users/counts`.
public struct ScheduledEventCounts: Hashable, Sendable {
    public var series: Int
    /// By occurrence id. A date's own count already includes the series'
    /// interested people and leaves out those who said they would miss it.
    public var occurrences: [UInt64: Int]

    public init(series: Int, occurrences: [UInt64: Int] = [:]) {
        self.series = series
        self.occurrences = occurrences
    }
}

/// One row of an event's interested people: the answer, and who gave it.
public struct ScheduledEventInterest: Hashable, Sendable {
    public var rsvp: ScheduledEventRSVP
    public var user: User
    public var member: Member?

    public init(rsvp: ScheduledEventRSVP, user: User, member: Member?) {
        self.rsvp = rsvp
        self.user = user
        self.member = member
    }
}
