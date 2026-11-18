import Foundation
import Testing
@testable import Wingcord

/// The date picker's arithmetic: the month laid out in weeks, and the time
/// stepped by the arrows.
@Suite("Playful date picker")
struct PlayfulDatePickerTests {

    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("October 2026 starts on a Thursday: three blanks from Monday, four from Sunday")
    func monthGrid() {
        let monday = calendar(firstWeekday: 2)
        let days = PlayfulDatePicker.days(of: date(2026, 10, 1, in: monday), calendar: monday)
        #expect(days.prefix(3).allSatisfy { $0 == nil })
        #expect(days[3] == date(2026, 10, 1, in: monday))
        #expect(days.compactMap { $0 }.count == 31)
        // Six weeks whatever the month, so the popover never changes height
        // under the arrows.
        #expect(days.count == 42)
        let february = PlayfulDatePicker.days(of: date(2027, 2, 1, in: monday), calendar: monday)
        #expect(february.count == 42)

        let sunday = calendar(firstWeekday: 1)
        let fromSunday = PlayfulDatePicker.days(of: date(2026, 10, 1, in: sunday), calendar: sunday)
        #expect(fromSunday.prefix(4).allSatisfy { $0 == nil })
        #expect(fromSunday[4] == date(2026, 10, 1, in: sunday))
    }

    @Test("Minutes step to the fives, and the day never changes under an arrow")
    func timeSteps() {
        let calendar = calendar(firstWeekday: 2)
        let start = date(2026, 10, 27, 18, 23, in: calendar)
        #expect(PlayfulDatePicker.stepped(start, by: 5, unit: .minute, calendar: calendar) == date(2026, 10, 27, 18, 25, in: calendar))
        #expect(PlayfulDatePicker.stepped(start, by: -5, unit: .minute, calendar: calendar) == date(2026, 10, 27, 18, 20, in: calendar))
        let onFive = date(2026, 10, 27, 18, 20, in: calendar)
        #expect(PlayfulDatePicker.stepped(onFive, by: -5, unit: .minute, calendar: calendar) == date(2026, 10, 27, 18, 15, in: calendar))
        // Wrapping inside the hour and the day.
        let late = date(2026, 10, 27, 23, 55, in: calendar)
        #expect(PlayfulDatePicker.stepped(late, by: 5, unit: .minute, calendar: calendar) == date(2026, 10, 27, 23, 0, in: calendar))
        #expect(PlayfulDatePicker.stepped(late, by: 1, unit: .hour, calendar: calendar) == date(2026, 10, 27, 0, 55, in: calendar))
        let early = date(2026, 10, 27, 0, 0, in: calendar)
        #expect(PlayfulDatePicker.stepped(early, by: -1, unit: .hour, calendar: calendar) == date(2026, 10, 27, 23, 0, in: calendar))
    }
}
