import Foundation

/// The "Time formats" list `@time` offers — Discord's `timestampMentionInput`
/// autocomplete (`778572`), rule for rule, with the reading of what was typed
/// done by `NSDataDetector` where Discord uses chrono-node.
///
/// What Discord does with a reading:
///
///  - **A time with no date** ("5pm") offers the time alone first ("Time
///    only"), then reads it against today — and when today's has passed, offers
///    tomorrow's above it.
///  - **A weekday with no date** ("friday") is read against this week, and next
///    week's is offered above it when this week's has passed.
///  - **A date with no year** is read against this year, and next year's
///    offered the same way.
///  - Each reading is offered in four styles: the numeric date and time (with
///    seconds when seconds were typed), the long date and time, the long date
///    with the weekday, and the relative form.
///
/// Chrono reports which parts of a date were *written* and which it implied;
/// the detector does not, so `Reading` works that out from the words.
public enum TimestampSuggestions {

    public enum Row: Hashable, Sendable {
        /// One way to write one moment, and what Discord says beside it.
        case option(Date, TimestampStyle, label: String?)
        /// The rule between one reading and the next.
        case divider
    }

    /// The rows for what was typed after `@time`. Empty where nothing in it
    /// reads as one moment — Discord then shows only its hint.
    public static func rows(for query: String, now: Date = .now, calendar: Calendar = .current) -> [Row] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let reading: Reading
        if text.isEmpty {
            // Discord reads an empty input as now, written down to the second.
            reading = Reading(date: now, hasTime: true, hasSeconds: true, hasWeekday: false, hasDate: true, hasYear: true)
        } else {
            guard let read = Reading(text, now: now, calendar: calendar) else { return [] }
            reading = read
        }
        let style: TimestampStyle = reading.hasSeconds ? .numericDateLongTime : .numericDateTime

        var rows: [Row] = []
        var period: Period?
        if reading.hasDate || reading.hasWeekday {
            if reading.hasWeekday, !reading.hasDate {
                period = .week
            } else if !reading.hasYear {
                period = .year
            }
        } else {
            rows.append(.option(reading.date, reading.hasSeconds ? .longTime : .shortTime, label: "Time only"))
            rows.append(.divider)
            period = .day
        }

        var label: String?
        if let period {
            let names = period.names
            let previous = calendar.date(byAdding: period.component, value: -1, to: now) ?? now
            var adjusted: String?
            if calendar.isDate(reading.date, equalTo: now, toGranularity: period.granularity) {
                label = names.current
                if reading.date <= now { adjusted = names.next }
            } else if calendar.isDate(reading.date, equalTo: previous, toGranularity: period.granularity) {
                label = names.previous
                adjusted = names.current
            }
            if let adjusted, let later = calendar.date(byAdding: period.component, value: 1, to: reading.date) {
                rows += options(for: later, style: style, label: adjusted)
                rows.append(.divider)
            }
        }
        rows += options(for: reading.date, style: style, label: label)
        return rows
    }

    private static func options(for date: Date, style: TimestampStyle, label: String?) -> [Row] {
        [
            .option(date, style, label: label),
            .option(date, .shortDateTime, label: nil),
            .option(date, .longDateTime, label: nil),
            .option(date, .relative, label: nil),
        ]
    }

    private enum Period {
        case day, week, year

        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .year: .year
            }
        }

        var granularity: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .year: .year
            }
        }

        var names: (previous: String, current: String, next: String) {
            switch self {
            case .day: ("Yesterday", "Today", "Tomorrow")
            case .week: ("Last week", "This week", "Next week")
            case .year: ("Last year", "This year", "Next year")
            }
        }
    }

    // MARK: Reading what was typed

    /// One moment read out of the input, and which of its parts were written —
    /// chrono's `isCertain`.
    struct Reading {
        var date: Date
        var hasTime: Bool
        var hasSeconds: Bool
        var hasWeekday: Bool
        var hasDate: Bool
        var hasYear: Bool

        init(date: Date, hasTime: Bool, hasSeconds: Bool, hasWeekday: Bool, hasDate: Bool, hasYear: Bool) {
            self.date = date
            self.hasTime = hasTime
            self.hasSeconds = hasSeconds
            self.hasWeekday = hasWeekday
            self.hasDate = hasDate
            self.hasYear = hasYear
        }

        /// Nil unless the whole of the text is one moment — Discord's
        /// `i.text === e`, and no range.
        init?(_ text: String, now: Date, calendar: Calendar) {
            guard let detector = Self.detector else { return nil }
            let whole = NSRange(text.startIndex..., in: text)
            guard let match = detector.firstMatch(in: text, range: whole),
                  match.range == whole,
                  match.duration == 0,
                  var date = match.date
            else { return nil }

            let lowered = text.lowercased()
            let isRelative = Self.matches(lowered, Self.relative)
            let hasTime = Self.matches(lowered, Self.time)
            let hasSeconds = Self.matches(lowered, Self.seconds)
            let hasCalendarDate = Self.matches(lowered, Self.calendarDate)
            let hasWeekday = !isRelative && !hasCalendarDate && Self.matches(lowered, Self.weekday)

            // What chrono implies for a part nobody wrote: the reference's
            // time for a day named by its distance from today, noon for a date
            // written out — and seconds only where they were typed.
            if !hasTime {
                let reference = calendar.dateComponents([.hour, .minute], from: now)
                let hour = isRelative || hasWeekday ? reference.hour ?? 12 : 12
                let minute = isRelative || hasWeekday ? reference.minute ?? 0 : 0
                date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
                // Discord's rounding of an unwritten time, to the quarter hour.
                let quarter = 15.0 * 60
                date = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / quarter).rounded() * quarter)
            } else if !hasSeconds {
                let second = calendar.component(.second, from: date)
                date = date.addingTimeInterval(-Double(second))
            }

            self.date = date
            self.hasTime = hasTime
            self.hasSeconds = hasSeconds
            self.hasWeekday = hasWeekday
            self.hasDate = isRelative || hasCalendarDate
            self.hasYear = isRelative || Self.matches(lowered, Self.year)
        }

        /// Built once: the composer asks on every keystroke, and a detector
        /// is immutable and safe to share once made.
        private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

        private static func matches(_ text: String, _ pattern: NSRegularExpression) -> Bool {
            pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        private static func pattern(_ source: String) -> NSRegularExpression {
            // The patterns are literals; a failure here is a typo, caught by
            // the tests on the first run.
            try! NSRegularExpression(pattern: source, options: [.caseInsensitive])
        }

        /// A clock time, a moment named by its distance from now, noon or
        /// midnight.
        static let time = pattern(
            #"\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*(am|pm|a\.m\.|p\.m\.)(\W|$)|\b(noon|midnight|now)\b"#
                + #"|\b(\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten)\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b"#
        )
        static let seconds = pattern(#"\b\d{1,2}:\d{2}:\d{2}\b|\b(seconds?|secs?|now)\b"#)
        /// A day named by where it is from today, which chrono writes down in
        /// full.
        static let relative = pattern(
            #"\b(today|tonight|tomorrow|tmrw|tmr|yesterday|now|ago)\b"#
                + #"|\b(in|after)\s+\S+\s+(days?|weeks?|months?|years?|hours?|hrs?|minutes?|mins?|seconds?|secs?)\b"#
                + #"|\b(next|last|this)\s+(week|month|year)\b"#
        )
        static let weekday = pattern(#"\b(mon|tues?|wed|thu|thurs?|fri|sat|sun)(day|nesday|rsday|urday)?\b"#)
        /// A date written out: a month's name, a numeric date, an ordinal day.
        static let calendarDate = pattern(
            #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b"#
                + #"|\b\d{1,4}[/.-]\d{1,2}([/.-]\d{1,4})?\b|\b\d{1,2}(st|nd|rd|th)\b"#
        )
        static let year = pattern(#"\b(19|20|21)\d{2}\b|\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b"#)
    }
}
