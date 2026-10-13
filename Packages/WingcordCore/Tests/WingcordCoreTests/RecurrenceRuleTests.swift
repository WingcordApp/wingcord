import Foundation
import Testing
@testable import WingcordCore

/// The dates of a repeating event, and the ids Discord names them by.
///
/// **The ids are pinned to `scheduled event.har`.** Its yearly event asked for
/// the counts of 1588436611891200000, 1720708182835200000, 1853342141644800000
/// and 1985613712588800000 — the first of January at 06:00 UTC in 2027, 2028,
/// 2029 and 2030 — and those four are what "Events in series" listed.
struct RecurrenceRuleTests {

    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 6) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test("An occurrence's id is its start as a bare snowflake, and back")
    func occurrenceIDs() {
        #expect(ScheduledEvent.occurrenceID(startingAt: Self.utc(2027, 1, 1)) == 1_588_436_611_891_200_000)
        #expect(ScheduledEvent.occurrenceID(startingAt: Self.utc(2030, 1, 1)) == 1_985_613_712_588_800_000)
        #expect(ScheduledEvent.originalStart(ofOccurrence: 1_720_708_182_835_200_000) == Self.utc(2028, 1, 1))
    }

    @Test("The captured yearly series lists the four Januaries the capture asked about")
    func yearlySeries() {
        let event = ScheduledEvent(
            id: 1_323_893_975_484_369_279,
            guildID: GuildID(rawValue: 603_970_300_668_805_120),
            name: "the last thread of the year",
            startsAt: Self.utc(2027, 1, 1),
            location: .external("pork's house"),
            rule: RecurrenceRule(start: Self.utc(2026, 1, 1), frequency: .yearly)
        )
        let dates = event.upcomingOccurrences(limit: 4, now: Self.utc(2026, 10, 1))
        #expect(dates == [
            1_588_436_611_891_200_000, 1_720_708_182_835_200_000,
            1_853_342_141_644_800_000, 1_985_613_712_588_800_000,
        ])
        #expect(event.currentOccurrenceID == 1_588_436_611_891_200_000)
        // "View more" continues after the last one shown.
        let more = event.upcomingOccurrences(
            limit: 1, after: ScheduledEvent.originalStart(ofOccurrence: dates[3]), now: Self.utc(2026, 10, 1)
        )
        #expect(more.isEmpty, "a fifth January is past four years from now")
    }

    @Test("Weekly keeps the weekday, every other week skips one")
    func weekly() {
        let start = Self.utc(2026, 10, 5, 18)  // a Monday
        let weekly = RecurrenceRule(start: start, frequency: .weekly, byWeekday: [0])
        #expect(weekly.occurrences(from: start, until: .distantFuture, limit: 3)
            == [start, Self.utc(2026, 10, 12, 18), Self.utc(2026, 10, 19, 18)])
        let biweekly = RecurrenceRule(start: start, frequency: .weekly, interval: 2, byWeekday: [0])
        #expect(biweekly.occurrences(from: start, until: .distantFuture, limit: 2)
            == [start, Self.utc(2026, 10, 19, 18)])
    }

    @Test("Monthly on the nth weekday, and weekdays only")
    func monthlyAndWeekdays() {
        // The second Wednesday of October 2026 is the 14th.
        let start = Self.utc(2026, 10, 14, 12)
        let monthly = RecurrenceRule(
            start: start, frequency: .monthly, byNWeekday: [.init(n: 2, day: 2)]
        )
        #expect(monthly.occurrences(from: start, until: .distantFuture, limit: 2)
            == [start, Self.utc(2026, 11, 11, 12)])
        // Friday the 16th, then Monday the 19th — the weekend is skipped.
        let friday = Self.utc(2026, 10, 16, 9)
        let weekdays = RecurrenceRule(start: friday, frequency: .daily, byWeekday: [0, 1, 2, 3, 4])
        #expect(weekdays.occurrences(from: friday, until: .distantFuture, limit: 2)
            == [friday, Self.utc(2026, 10, 19, 9)])
    }

    @Test("A count and an end both stop the series")
    func countAndEnd() {
        let start = Self.utc(2026, 10, 1)
        let counted = RecurrenceRule(start: start, frequency: .daily, count: 2)
        #expect(counted.occurrences(from: start, until: .distantFuture, limit: 10).count == 2)
        let ended = RecurrenceRule(start: start, end: Self.utc(2026, 10, 3), frequency: .daily)
        #expect(ended.occurrences(from: start, until: .distantFuture, limit: 10).count == 3)
    }

    @Test("A moved date takes its exception's times; a cancelled one says so")
    func exceptions() {
        let occurrence = ScheduledEvent.occurrenceID(startingAt: Self.utc(2028, 1, 1))
        let event = ScheduledEvent(
            id: 1, guildID: GuildID(rawValue: 2), name: "e",
            startsAt: Self.utc(2027, 1, 1), endsAt: Self.utc(2027, 1, 1, 8),
            location: .external("x"),
            rule: RecurrenceRule(start: Self.utc(2026, 1, 1), frequency: .yearly),
            exceptions: [.init(id: occurrence, startsAt: Self.utc(2028, 1, 2))]
        )
        #expect(event.span(of: occurrence).start == Self.utc(2028, 1, 2))
        // The length of the event follows the original start, and the moved
        // date's end comes from the event's own length.
        #expect(event.span(of: ScheduledEvent.occurrenceID(startingAt: Self.utc(2029, 1, 1))).end
            == Self.utc(2029, 1, 1, 8))
        var cancelled = event
        cancelled.exceptions = [.init(id: occurrence, isCanceled: true)]
        #expect(cancelled.status(of: occurrence) == .canceled)
    }
    /// Discord's `p$`: an event link's date is drawn only when the series
    /// could have it.
    @Test("A linked date must fall at the series' time, and on its weekday or day")
    func admitsOccurrence() {
        let yearly = RecurrenceRule(start: Self.utc(2026, 1, 1), frequency: .yearly)
        #expect(yearly.admits(occurrence: ScheduledEvent.occurrenceID(startingAt: Self.utc(2028, 1, 1))))
        #expect(!yearly.admits(occurrence: ScheduledEvent.occurrenceID(startingAt: Self.utc(2028, 1, 2))))
        #expect(!yearly.admits(occurrence: ScheduledEvent.occurrenceID(startingAt: Self.utc(2028, 1, 1, 7))))

        // 5 October 2026 is a Monday.
        let weekly = RecurrenceRule(start: Self.utc(2026, 10, 5, 18), frequency: .weekly)
        #expect(weekly.admits(occurrence: ScheduledEvent.occurrenceID(startingAt: Self.utc(2026, 10, 19, 18))))
        #expect(!weekly.admits(occurrence: ScheduledEvent.occurrenceID(startingAt: Self.utc(2026, 10, 20, 18))))

        // Monthly and daily ask only the time of day — Discord's own leniency.
        let monthly = RecurrenceRule(start: Self.utc(2026, 10, 5, 18), frequency: .monthly)
        #expect(monthly.admits(occurrence: ScheduledEvent.occurrenceID(startingAt: Self.utc(2026, 12, 9, 18))))
    }
}
