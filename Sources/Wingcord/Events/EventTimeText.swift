import Foundation
import WingcordCore

/// The line over an event that says when it is — Discord's `103355`, with the
/// words worked out the way its `974930.CC` works them out.
///
/// Pure and `nonisolated` so the rules are tested rather than looked at: the
/// six states, the "Today at" / "Tomorrow at" window, the end written as a
/// bare time when it falls on the start's own day, and the year written only
/// when it is not this one.
nonisolated struct EventTimeText: Equatable, Sendable {
    /// Which of Discord's six states the line is in — its `timeStatus`.
    enum State: Equatable, Sendable {
        /// More than an hour off.
        case later
        /// Within the hour: "Starting in 12m".
        case soon
        /// Its start has passed and nobody has started it.
        case due
        case live
        case ended
        case canceled
    }

    var state: State
    /// What the line says.
    var text: String
    /// The part of `text` drawn in the live green — the "Happening Now" in
    /// "Happening Now — Ends 9:00 PM". Nil where the line has no such part.
    var liveLead: String?
    /// The start written out, where the line says something relative instead —
    /// Discord's tooltip on "Starting soon".
    var detail: String?
    /// What a screen reader hears — Discord's own `aria-label` for a date of a
    /// series, which says "Canceled" where the line only colours it.
    var spoken: String

    init(
        start: Date,
        end: Date?,
        status: ScheduledEvent.Status,
        isExternal: Bool,
        isCanceled: Bool = false,
        now: Date,
        clock: EventClock
    ) {
        let startText = clock.startText(start, now: now)
        let endText = end.map { clock.endText($0, start: start, now: now) }
        let span = endText.map { "\(startText) — \($0)" } ?? startText

        if status == .canceled || isCanceled {
            state = .canceled
        } else if status == .active {
            state = .live
        } else if status == .completed {
            state = .ended
        } else if start <= now {
            state = .due
        } else if start <= now.addingTimeInterval(3600) {
            state = .soon
        } else {
            state = .later
        }

        let live = isExternal ? "Happening Now" : "Live Now"
        liveLead = nil
        detail = nil
        switch state {
        case .soon:
            // moment's `diff(…, "minutes")`, which truncates.
            let minutes = Int(start.timeIntervalSince(now) / 60)
            text = minutes > 0 ? "Starting in \(minutes)m" : "Starting soon"
            detail = startText
            spoken = text
        case .due:
            text = "Starting soon"
            detail = startText
            spoken = text
        case .live:
            liveLead = live
            text = endText.map { "\(live) — Ends \($0)" } ?? live
            spoken = endText.map { "\(live) — \($0)" } ?? live
        case .canceled:
            text = span
            spoken = "\(startText), Canceled"
        case .later, .ended:
            text = span
            spoken = span
        }
    }

    // MARK: The repeat line

    /// The second line under a repeating event's time — "Repeats every
    /// Wednesday" — or nil for a rule Discord has no words for (`974930.z7`).
    ///
    /// The day and date are the shown date's own, in the reader's time zone, as
    /// Discord reads them.
    static func repeatLine(for rule: RecurrenceRule, at date: Date, clock: EventClock) -> String? {
        let calendar = clock.calendar
        let weekday = clock.weekdayName(date)
        switch rule.frequency {
        case .weekly:
            switch rule.interval {
            case 1: return "Repeats every \(weekday)"
            case 2: return "Repeats every other \(weekday)"
            default: return nil
            }
        case .yearly:
            return "Repeats every \(clock.monthAndDay(date))"
        case .monthly:
            let nth = (calendar.component(.day, from: date) + 6) / 7
            let ordinals = ["first", "second", "third", "fourth", "fifth"]
            guard (1...5).contains(nth) else { return nil }
            return "Repeats monthly on the \(ordinals[nth - 1]) \(weekday)"
        case .daily:
            guard let days = rule.byWeekday, !days.isEmpty else { return "Repeats every day" }
            // The rule is written in UTC, so a week that starts late in the
            // reader's evening is stored a day on — Discord's `B` and `V`.
            let shift = clock.utcDayShift(date)
            let named = Set(days)
            if named == Set([0, 1, 2, 3, 4].map { ($0 + shift + 7) % 7 }) {
                return "Repeats every weekday (Monday to Friday)"
            }
            if named == Set([5, 6].map { ($0 + shift + 7) % 7 }) {
                return "Repeats every weekend (Saturday and Sunday)"
            }
            return nil
        }
    }
}

/// How the events surfaces write dates: the reader's clock and calendar.
///
/// **Formatters built once per clock** — `TimelineSettings`' reasoning: a
/// configured `DateFormatter` costs a fifth of `Date.formatted` on every call,
/// and a list of events redraws its lines each minute. Templates rather than
/// patterns, so the order and the separators are the locale's own.
///
/// `@unchecked Sendable` for `TimelineSettings`' reason: the formatters are
/// configured here and never mutated after.
nonisolated struct EventClock: @unchecked Sendable {
    let calendar: Calendar
    /// What the formatters were built from — `current()` rebuilds when any
    /// of them moves.
    private let inputs: Inputs
    private let time: DateFormatter
    private let day: DateFormatter
    private let dayInYear: DateFormatter
    private let weekday: DateFormatter
    private let monthDay: DateFormatter

    private struct Inputs: Equatable {
        var uses24HourTime: Bool
        var locale: String
        var timeZone: String
    }

    init(uses24HourTime: Bool, locale: Locale, timeZone: TimeZone = .current) {
        inputs = Inputs(uses24HourTime: uses24HourTime, locale: locale.identifier, timeZone: timeZone.identifier)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        self.calendar = calendar
        func formatter(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        time = formatter(uses24HourTime ? "Hmm" : "hmm")
        // Discord's "ddd MMM Do", and "ddd MMM Do, YYYY" for another year.
        day = formatter("EEEMMMd")
        dayInYear = formatter("EEEMMMdy")
        weekday = formatter("EEEE")
        // Discord's `{month: "short", day: "2-digit"}`: "Jan 01".
        monthDay = formatter("MMMdd")
    }

    /// The reader's own, read from the settings at the moment it is asked
    /// for — and kept, so a list of lines redrawing each minute builds its
    /// formatters once.
    @MainActor
    static func current() -> EventClock {
        let uses24HourTime = AppSettings.shared.uses24HourTime
        let inputs = Inputs(
            uses24HourTime: uses24HourTime, locale: Locale.current.identifier, timeZone: TimeZone.current.identifier
        )
        if let shared, shared.inputs == inputs { return shared }
        let clock = EventClock(uses24HourTime: uses24HourTime, locale: .current)
        shared = clock
        return clock
    }

    @MainActor private static var shared: EventClock?

    /// "Today at 4:00 PM", "Tomorrow at 4:00 PM", or the date and the time.
    func startText(_ start: Date, now: Date) -> String {
        switch dayDistance(from: now, to: start) {
        case 0: "Today at \(time.string(from: start))"
        case 1: "Tomorrow at \(time.string(from: start))"
        default: dated(start, now: now)
        }
    }

    /// The end: a bare time on the start's own day, the full date otherwise.
    func endText(_ end: Date, start: Date, now: Date) -> String {
        calendar.isDate(end, inSameDayAs: start) ? time.string(from: end) : dated(end, now: now)
    }

    func weekdayName(_ date: Date) -> String { weekday.string(from: date) }

    func monthAndDay(_ date: Date) -> String { monthDay.string(from: date) }

    /// How many days the date's UTC weekday is ahead of its local one: -1, 0
    /// or 1.
    func utcDayShift(_ date: Date) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let local = calendar.dateComponents([.year, .month, .day], from: date)
        let there = utc.dateComponents([.year, .month, .day], from: date)
        guard let localDay = calendar.date(from: local), let utcDay = calendar.date(from: there) else { return 0 }
        return calendar.dateComponents([.day], from: localDay, to: utcDay).day ?? 0
    }

    /// Discord's `L`: the weekday, month and day, the year only when it is
    /// not this one, then the time.
    private func dated(_ date: Date, now: Date) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = sameYear ? day : dayInYear
        return "\(formatter.string(from: date)) · \(time.string(from: date))"
    }

    /// Whole calendar days from `now`'s day to `date`'s — Discord's `m_`.
    private func dayDistance(from now: Date, to date: Date) -> Int {
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }
}
