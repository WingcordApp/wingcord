import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The line over an event, on Discord's rules (`103355` over `974930.CC`).
///
/// Pinned to `en_US_POSIX` and UTC, `TimelineSettings.comfortable`'s reason:
/// what is under test is the rule, not the machine's calendar. ICU puts a
/// narrow no-break space (U+202F) before the AM/PM marker.
struct EventTimeTextTests {

    private let clock = EventClock(
        uses24HourTime: false,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone(identifier: "UTC")!
    )

    /// Thursday 1 October 2026, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_790_856_000)

    private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    private func line(
        _ start: Date,
        end: Date? = nil,
        status: ScheduledEvent.Status = .scheduled,
        isExternal: Bool = true,
        isCanceled: Bool = false
    ) -> EventTimeText {
        EventTimeText(
            start: start, end: end, status: status, isExternal: isExternal,
            isCanceled: isCanceled, now: now, clock: clock
        )
    }

    @Test("Today and tomorrow are named; other days are dated, with the year only when it differs")
    func startWording() {
        #expect(line(at(4)).text == "Today at 4:00\u{202F}PM")
        #expect(line(at(28)).text == "Tomorrow at 4:00\u{202F}PM")
        #expect(line(at(76)).text == "Sun, Oct 4 · 4:00\u{202F}PM")
        #expect(line(at(24 * 100)).text == "Sat, Jan 9, 2027 · 12:00\u{202F}PM")
    }

    @Test("An end on the start's own day is a bare time; on another day it is dated")
    func endWording() {
        #expect(line(at(76), end: at(78)).text == "Sun, Oct 4 · 4:00\u{202F}PM — 6:00\u{202F}PM")
        #expect(line(at(76), end: at(100)).text == "Sun, Oct 4 · 4:00\u{202F}PM — Mon, Oct 5 · 4:00\u{202F}PM")
    }

    @Test("Within the hour it counts down, in whole minutes; past its start it is due")
    func soonAndDue() {
        let soon = line(now.addingTimeInterval(12 * 60 + 30))
        #expect(soon.state == .soon)
        #expect(soon.text == "Starting in 12m")
        #expect(soon.detail == "Today at 12:12\u{202F}PM")
        #expect(line(now.addingTimeInterval(30)).text == "Starting soon")
        let due = line(at(-0.5))
        #expect(due.state == .due)
        #expect(due.text == "Starting soon")
    }

    @Test("On now: Happening Now somewhere else, Live Now in a room, and when it ends")
    func live() {
        let external = line(at(-1), end: at(2), status: .active)
        #expect(external.state == .live)
        #expect(external.text == "Happening Now — Ends 2:00\u{202F}PM")
        #expect(external.liveLead == "Happening Now")
        #expect(line(at(-1), status: .active, isExternal: false).text == "Live Now")
    }

    @Test("A cancelled date keeps its date on the line and says so to a screen reader")
    func canceled() {
        let canceled = line(at(76), isCanceled: true)
        #expect(canceled.state == .canceled)
        #expect(canceled.text == "Sun, Oct 4 · 4:00\u{202F}PM")
        #expect(canceled.spoken == "Sun, Oct 4 · 4:00\u{202F}PM, Canceled")
        #expect(line(at(-30), status: .completed).state == .ended)
    }

    // MARK: The repeat line

    @Test("Each rule Discord has words for, named from the shown date")
    func repeatWording() {
        let saturday = Date(timeIntervalSince1970: 1_791_028_800) // 3 October 2026, 12:00 UTC
        let rule = { (frequency: RecurrenceRule.Frequency, interval: Int) in
            RecurrenceRule(start: saturday, frequency: frequency, interval: interval)
        }
        #expect(EventTimeText.repeatLine(for: rule(.weekly, 1), at: saturday, clock: clock) == "Repeats every Saturday")
        #expect(EventTimeText.repeatLine(for: rule(.weekly, 2), at: saturday, clock: clock) == "Repeats every other Saturday")
        #expect(EventTimeText.repeatLine(for: rule(.weekly, 3), at: saturday, clock: clock) == nil)
        #expect(EventTimeText.repeatLine(for: rule(.monthly, 1), at: saturday, clock: clock) == "Repeats monthly on the first Saturday")
        #expect(EventTimeText.repeatLine(for: rule(.yearly, 1), at: saturday, clock: clock) == "Repeats every Oct 03")
        #expect(EventTimeText.repeatLine(for: rule(.daily, 1), at: saturday, clock: clock) == "Repeats every day")
    }

    @Test("Weekdays and weekends are read through the day the rule's UTC shifts them by")
    func weekdaysAcrossTheDateLine() {
        let newYork = EventClock(
            uses24HourTime: false,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(identifier: "America/New_York")!
        )
        // Monday 5 October 2026, 21:00 in New York — already Tuesday in UTC,
        // so Discord stores Monday to Friday as Tuesday to Saturday.
        let monday = Date(timeIntervalSince1970: 1_791_248_400)
        let shifted = RecurrenceRule(start: monday, frequency: .daily, byWeekday: [1, 2, 3, 4, 5])
        #expect(EventTimeText.repeatLine(for: shifted, at: monday, clock: newYork) == "Repeats every weekday (Monday to Friday)")
        let plain = RecurrenceRule(start: monday, frequency: .daily, byWeekday: [0, 1, 2, 3, 4])
        #expect(EventTimeText.repeatLine(for: plain, at: monday, clock: clock) == "Repeats every weekday (Monday to Friday)")
        let weekend = RecurrenceRule(start: monday, frequency: .daily, byWeekday: [5, 6])
        #expect(EventTimeText.repeatLine(for: weekend, at: monday, clock: clock) == "Repeats every weekend (Saturday and Sunday)")
    }

    // MARK: The calendar file

    @Test("The calendar file carries the event's own times, its rule, and escaped text")
    func calendarFile() {
        let event = ScheduledEvent(
            id: 1_323_893_975_484_369_279,
            guildID: GuildID(rawValue: 603_970_300_668_805_120),
            name: "pork's last shower, of the year; again",
            startsAt: Date(timeIntervalSince1970: 1_798_783_200), // 2027-01-01 06:00 UTC
            location: .external("pork's house"),
            rule: RecurrenceRule(
                start: Date(timeIntervalSince1970: 1_798_783_200),
                frequency: .yearly, byMonth: [1], byMonthDay: [1]
            )
        )
        let text = EventCalendarFile.contents(
            of: event, description: "line one\nline two", location: "pork's house", stamp: now
        )
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines.contains("DTSTART:20270101T060000Z"))
        #expect(lines.contains("DTEND:20270101T060000Z"))
        #expect(lines.contains("SUMMARY:pork's last shower\\, of the year\\; again"))
        #expect(lines.contains("DESCRIPTION:line one\\nline two"))
        #expect(lines.contains("RRULE:FREQ=YEARLY;BYMONTH=1;BYMONTHDAY=1"))
        #expect(lines.allSatisfy { $0.utf8.count <= 75 })
    }

    @Test("A room's event is placed in its server and channel, as Discord writes it")
    func calendarLocation() {
        let event = ScheduledEvent(
            id: 1, guildID: GuildID(rawValue: 2), name: "Movie night",
            startsAt: now, location: .voice(ChannelID(rawValue: 3))
        )
        #expect(EventCalendarFile.location(of: event, guildName: "Wingcord", channelName: "Lounge")
            == "Discord: Wingcord server, Lounge")
        #expect(EventCalendarFile.location(of: event, guildName: nil, channelName: nil) == "Discord")
    }
}
