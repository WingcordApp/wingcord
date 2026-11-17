import Foundation
import Testing
@testable import Wingcord

/// Discord's Friend Anniversaries window: a week either side of the day the
/// friendship began, any year but the first, across New Year too.
struct FriendAnniversaryRuleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func aWeekEitherSide() {
        let since = date(2020, 11, 17)
        #expect(FriendAnniversaryRule.isNear(since, now: date(2026, 11, 17), calendar: calendar))
        #expect(FriendAnniversaryRule.isNear(since, now: date(2026, 11, 10), calendar: calendar))
        #expect(FriendAnniversaryRule.isNear(since, now: date(2026, 11, 24), calendar: calendar))
        #expect(!FriendAnniversaryRule.isNear(since, now: date(2026, 11, 25), calendar: calendar))
        #expect(!FriendAnniversaryRule.isNear(since, now: date(2026, 11, 9), calendar: calendar))
    }

    @Test func notTheFirstDay() {
        let since = date(2026, 11, 15)
        #expect(!FriendAnniversaryRule.isNear(since, now: date(2026, 11, 17), calendar: calendar))
    }

    @Test func acrossNewYear() {
        // Friends since 2 January; on 29 December the anniversary is next year's.
        #expect(FriendAnniversaryRule.isNear(date(2019, 1, 2), now: date(2026, 12, 29), calendar: calendar))
        // Friends since 30 December; on 3 January it was last year's.
        #expect(FriendAnniversaryRule.isNear(date(2019, 12, 30), now: date(2027, 1, 3), calendar: calendar))
    }

    @Test func leapDayInACommonYear() {
        #expect(FriendAnniversaryRule.isNear(date(2020, 2, 29), now: date(2026, 2, 28), calendar: calendar))
    }

    @Test func yearsRoundLikeDiscord() {
        // Six years less three days is still "6 years".
        #expect(FriendAnniversaryRule.years(since: date(2020, 11, 20), now: date(2026, 11, 17), calendar: calendar) == 6)
        #expect(FriendAnniversaryRule.years(since: date(2020, 11, 10), now: date(2026, 11, 17), calendar: calendar) == 6)
    }
}
