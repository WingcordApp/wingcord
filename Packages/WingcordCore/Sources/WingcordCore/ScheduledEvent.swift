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
        self.interestedCount = interestedCount
        self.isInterested = isInterested
    }

    public var coverURL: URL? {
        imageHash.flatMap { CDN.scheduledEventCover(eventID: id, hash: $0) }
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
    public var frequency: Int {
        switch self {
        case .weekly, .biweekly, .weekdays: 2
        case .monthly: 1
        case .annually: 0
        case .daily: 3
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
        case (3, 1, _, _, _, _):
            self = .daily
        case (2, 1, let days?, _, _, _) where days == [0, 1, 2, 3, 4]:
            self = .weekdays
        case (2, 1, let days?, _, _, _) where days.count == 1:
            self = .weekly(weekday: days[0])
        case (2, 2, let days?, _, _, _) where days.count == 1:
            self = .biweekly(weekday: days[0])
        case (1, 1, _, let entries?, _, _) where entries.count == 1:
            self = .monthly(week: entries[0].n, weekday: entries[0].day)
        case (0, 1, _, _, let months?, let days?) where months.count == 1 && days.count == 1:
            self = .annually(month: months[0], day: days[0])
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
