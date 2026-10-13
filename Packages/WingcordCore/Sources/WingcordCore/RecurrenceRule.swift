import Foundation

/// A repeating event's rule, as the wire states it — what the dates of a
/// series are computed from.
///
/// **Discord computes the dates on the client**, with rrule.js over these
/// fields (`974930`'s `X7`), and so does this: the server sends one event and a
/// rule, never a list of dates. Every date here is in UTC, because that is the
/// calendar the rule's `start` is written in and the one rrule.js works in — a
/// weekly event starting on a Monday in UTC stays on Monday in UTC even where it
/// is Sunday evening locally.
///
/// `Recurrence` is the *editor's* reading of a rule into the presets its menu
/// offers; this is the rule itself, kept whole so a series built in Discord's
/// own client, with fields the presets do not cover, still lists its dates.
public struct RecurrenceRule: Hashable, Sendable {
    /// rrule's numbering, which is Discord's.
    public enum Frequency: Int, Hashable, Sendable {
        case yearly = 0
        case monthly = 1
        case weekly = 2
        case daily = 3
    }

    /// The nth weekday of a month — "the second Wednesday". Discord's weekday
    /// numbering: 0 is Monday.
    public struct NWeekday: Hashable, Sendable {
        public var n: Int
        public var day: Int

        public init(n: Int, day: Int) {
            self.n = n
            self.day = day
        }
    }

    public var start: Date
    public var end: Date?
    public var frequency: Frequency
    public var interval: Int
    /// 0 is Monday — see `Recurrence.byWeekday`.
    public var byWeekday: [Int]?
    public var byNWeekday: [NWeekday]?
    /// 1 is January.
    public var byMonth: [Int]?
    public var byMonthDay: [Int]?
    /// How many occurrences the series has in all, counted from its start.
    public var count: Int?

    public init(
        start: Date,
        end: Date? = nil,
        frequency: Frequency,
        interval: Int = 1,
        byWeekday: [Int]? = nil,
        byNWeekday: [NWeekday]? = nil,
        byMonth: [Int]? = nil,
        byMonthDay: [Int]? = nil,
        count: Int? = nil
    ) {
        self.start = start
        self.end = end
        self.frequency = frequency
        self.interval = max(1, interval)
        self.byWeekday = byWeekday
        self.byNWeekday = byNWeekday
        self.byMonth = byMonth
        self.byMonthDay = byMonthDay
        self.count = count
    }

    /// The occurrences starting at or after `from` and no later than `until`,
    /// at most `limit` of them — rrule's `between(from, until, inclusive)`
    /// stopped at a count, which is how Discord's "Events in series" asks.
    public func occurrences(from: Date, until: Date, limit: Int) -> [Date] {
        guard limit > 0 else { return [] }
        var found: [Date] = []
        var produced = 0
        for date in candidates() {
            if let end, date > end { break }
            if let count, produced >= count { break }
            produced += 1
            if date > until { break }
            if date >= from {
                found.append(date)
                if found.count == limit { break }
            }
        }
        return found
    }

    /// The first occurrence strictly after `date`, if the series has one.
    public func occurrence(after date: Date) -> Date? {
        occurrences(from: date.addingTimeInterval(1), until: .distantFuture, limit: 1).first
    }

    /// Whether a date's id could be one of this series' dates — Discord's
    /// `p$`, which an event link's date passes before its card is drawn: the
    /// same time of day in UTC, and for a weekly or a yearly rule the same
    /// weekday or day of the month. **Coarse on purpose**, Discord's own
    /// test: a monthly or daily date at the right time passes whatever its day.
    public func admits(occurrence id: UInt64) -> Bool {
        let date = ScheduledEvent.originalStart(ofOccurrence: id)
        let parts: Set<Calendar.Component> = [.hour, .minute, .second, .weekday, .day]
        let first = Self.calendar.dateComponents(parts, from: start)
        let asked = Self.calendar.dateComponents(parts, from: date)
        guard first.hour == asked.hour, first.minute == asked.minute, first.second == asked.second else {
            return false
        }
        switch frequency {
        case .weekly: return first.weekday == asked.weekday
        case .yearly: return first.day == asked.day
        case .monthly, .daily: return true
        }
    }

    // MARK: Walking the calendar

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2  // rrule's default week start, Monday
        return calendar
    }()

    /// Discord's weekday for a date: 0 is Monday.
    private static func discordWeekday(_ date: Date) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    /// Every occurrence from the rule's start, in order. Bounded: a rule with
    /// no end and no count runs out at a hundred years, far past the four that
    /// anything here asks about.
    private func candidates() -> AnySequence<Date> {
        let calendar = Self.calendar
        let start = self.start
        let time = calendar.dateComponents([.hour, .minute, .second], from: start)
        let horizon = calendar.date(byAdding: .year, value: 100, to: start) ?? .distantFuture

        func at(_ day: Date) -> Date? {
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            parts.hour = time.hour
            parts.minute = time.minute
            parts.second = time.second
            return calendar.date(from: parts)
        }

        switch frequency {
        case .daily, .weekly:
            // Day by day, kept where the weekday is in the set and the week (or
            // day) falls on the interval.
            let weekdays = Set(byWeekday ?? [Self.discordWeekday(start)])
            let startDay = calendar.startOfDay(for: start)
            let startWeek = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? startDay
            var day = startDay
            return AnySequence(AnyIterator<Date> {
                while day <= horizon {
                    let current = day
                    day = calendar.date(byAdding: .day, value: 1, to: day) ?? horizon.addingTimeInterval(1)
                    let onInterval: Bool
                    if frequency == .daily {
                        let days = calendar.dateComponents([.day], from: startDay, to: current).day ?? 0
                        onInterval = days % interval == 0
                    } else {
                        let days = calendar.dateComponents([.day], from: startWeek, to: current).day ?? 0
                        onInterval = (days / 7) % interval == 0
                    }
                    let restricted = frequency == .weekly || byWeekday != nil
                    guard onInterval,
                          !restricted || weekdays.contains(Self.discordWeekday(current)),
                          let date = at(current), date >= start
                    else { continue }
                    return date
                }
                return nil
            })

        case .monthly:
            var step = 0
            return AnySequence(AnyIterator<Date> {
                while true {
                    guard let month = calendar.date(byAdding: .month, value: step * interval, to: start),
                          month <= horizon
                    else { return nil }
                    step += 1
                    let parts = calendar.dateComponents([.year, .month], from: month)
                    let day: Date?
                    if let rule = byNWeekday?.first {
                        day = Self.nthWeekday(rule, year: parts.year!, month: parts.month!)
                    } else {
                        var wanted = parts
                        wanted.day = byMonthDay?.first ?? calendar.component(.day, from: start)
                        day = calendar.date(from: wanted).flatMap {
                            // A 31st in a 30-day month is no date, not the 1st.
                            calendar.component(.month, from: $0) == parts.month ? $0 : nil
                        }
                    }
                    guard let day, let date = at(day), date >= start else { continue }
                    return date
                }
            })

        case .yearly:
            var step = 0
            return AnySequence(AnyIterator<Date> {
                while true {
                    guard let year = calendar.date(byAdding: .year, value: step * interval, to: start),
                          year <= horizon
                    else { return nil }
                    step += 1
                    var wanted = calendar.dateComponents([.year], from: year)
                    wanted.month = byMonth?.first ?? calendar.component(.month, from: start)
                    wanted.day = byMonthDay?.first ?? calendar.component(.day, from: start)
                    guard let day = calendar.date(from: wanted),
                          calendar.component(.month, from: day) == wanted.month,
                          let date = at(day), date >= start
                    else { continue }
                    return date
                }
            })
        }
    }

    /// The nth given weekday of a month — a negative n counts from its end.
    private static func nthWeekday(_ rule: NWeekday, year: Int, month: Int) -> Date? {
        let calendar = Self.calendar
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first)
        else { return nil }
        let matching = days.compactMap { day -> Date? in
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  discordWeekday(date) == rule.day
            else { return nil }
            return date
        }
        if rule.n > 0 { return rule.n <= matching.count ? matching[rule.n - 1] : nil }
        if rule.n < 0 { return -rule.n <= matching.count ? matching[matching.count + rule.n] : nil }
        return nil
    }
}
