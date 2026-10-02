import Foundation
import Testing
@testable import WingcordCore

/// `@time`'s list, on Discord's rules (`778572`).
///
/// `NSDataDetector` reads against the real clock and has no reference date to
/// set, so these are written against now rather than a pinned moment — what
/// they hold to is the shape Discord builds round a reading.
struct TimestampSuggestionsTests {

    private let calendar = Calendar.current

    private func options(_ rows: [TimestampSuggestions.Row]) -> [(Date, TimestampStyle, String?)] {
        rows.compactMap {
            if case .option(let date, let style, let label) = $0 { return (date, style, label) }
            return nil
        }
    }

    @Test("Nothing typed is now, to the second, in four styles")
    func empty() {
        let now = Date.now
        let rows = TimestampSuggestions.rows(for: "", now: now)
        let found = options(rows)
        #expect(found.count == 4)
        #expect(found.first?.1 == .numericDateLongTime)
        #expect(found.map(\.1) == [.numericDateLongTime, .shortDateTime, .longDateTime, .relative])
        #expect(abs((found.first?.0 ?? .distantPast).timeIntervalSince(now)) < 1)
    }

    @Test("A time alone comes first on its own, then today's — and tomorrow's above it once today's has passed")
    func timeOnly() throws {
        let now = Date.now
        let rows = TimestampSuggestions.rows(for: "5pm", now: now)
        let found = options(rows)
        let first = try #require(found.first)
        #expect(first.1 == .shortTime)
        #expect(first.2 == "Time only")
        #expect(calendar.component(.hour, from: first.0) == 17)
        #expect(rows[1] == .divider)

        let today = try #require(found.first { $0.2 == "Today" })
        #expect(calendar.isDate(today.0, inSameDayAs: now))
        let passed = today.0 <= now
        #expect(found.contains { $0.2 == "Tomorrow" } == passed)
    }

    @Test("A day and a time written out read as written, with no neighbour offered")
    func tomorrowAtFive() throws {
        let now = Date.now
        let found = options(TimestampSuggestions.rows(for: "tomorrow at 5pm", now: now))
        #expect(found.count == 4)
        let first = try #require(found.first)
        #expect(first.1 == .numericDateTime)
        #expect(first.2 == nil)
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: now))
        #expect(calendar.isDate(first.0, inSameDayAs: tomorrow))
        #expect(calendar.component(.hour, from: first.0) == 17)
        #expect(calendar.component(.minute, from: first.0) == 0)
    }

    @Test("A weekday alone is read against this week, at the quarter hour nearest now")
    func weekday() throws {
        let found = options(TimestampSuggestions.rows(for: "friday", now: .now))
        let labelled = try #require(found.first { $0.2 != nil })
        #expect(["This week", "Next week", "Last week"].contains(labelled.2 ?? ""))
        #expect(calendar.component(.weekday, from: labelled.0) == 6)
        #expect(calendar.component(.minute, from: labelled.0) % 15 == 0)
        #expect(calendar.component(.second, from: labelled.0) == 0)
    }

    /// **The detector always looks forward**, so a Friday's "friday" came
    /// back a week out and the list had no This week at all — a failure that
    /// only showed on the day itself. Chrono's nearest weekday is pinned here
    /// against a fixed Friday, which works because the weekday is the only
    /// part of the detector's answer that is kept.
    @Test("A weekday is the nearest one: today on the day, yesterday's the day after")
    func nearestWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let friday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 7)))
        let found = options(TimestampSuggestions.rows(for: "friday", now: friday, calendar: calendar))
        #expect(found.first?.2 == "Next week")
        let thisWeek = try #require(found.first { $0.2 == "This week" })
        #expect(calendar.isDate(thisWeek.0, inSameDayAs: friday))

        let thursday = options(TimestampSuggestions.rows(for: "thursday", now: friday, calendar: calendar))
        let yesterday = try #require(thursday.first { $0.2 == "This week" })
        #expect(calendar.component(.day, from: yesterday.0) == 1)
    }

    @Test("Words that are not a moment, or are more than one, offer nothing")
    func nothingToRead() {
        #expect(TimestampSuggestions.rows(for: "hello there").isEmpty)
        #expect(TimestampSuggestions.rows(for: "see you tomorrow at 5pm").isEmpty)
    }

    @Test("The tokens are Discord's: the second, then the style")
    func tokens() {
        let date = Date(timeIntervalSince1970: 1_790_856_000.6)
        #expect(TimestampStyle.token(for: date, style: .numericDateTime) == "<t:1790856000:s>")
        #expect(TimestampStyle.token(for: date, style: .relative) == "<t:1790856000:R>")
    }
}
