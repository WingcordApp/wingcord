import Foundation
import Testing
@testable import WingcordCore

/// The member list's Activity section, on Discord's rules.
struct ActivityCardRulesTests {

    private let now = Date(timeIntervalSince1970: 1_790_856_000)

    private func entry(_ id: String, author: UInt64, rank: Int, live: Bool = false, with others: [UInt64] = []) -> ActivityFeedEntry {
        ActivityFeedEntry(
            activity: RecentActivity(
                id: id, authorID: UserID(rawValue: author),
                subject: .game(name: "Game", applicationID: nil),
                traits: live ? [.live] : []
            ),
            rank: rank,
            participants: [UserID(rawValue: author)] + others.map(UserID.init(rawValue:)),
            raw: Data()
        )
    }

    @Test("A server's own choice wins; otherwise only under ten thousand members, and never beside a forum")
    func offered() {
        #expect(ActivityCardRules.isOffered(features: [], memberCount: 9_999, isForum: false))
        #expect(!ActivityCardRules.isOffered(features: [], memberCount: 10_000, isForum: false))
        #expect(ActivityCardRules.isOffered(features: ["ACTIVITY_FEED_ENABLED_BY_USER"], memberCount: 500_000, isForum: false))
        #expect(!ActivityCardRules.isOffered(features: ["ACTIVITY_FEED_DISABLED_BY_USER"], memberCount: 10, isForum: false))
        #expect(!ActivityCardRules.isOffered(features: [], memberCount: 10, isForum: true))
    }

    @Test("Only the channel's audience, nobody muted, no stale live entry, nothing seen for three days")
    func filtered() {
        let entries = [
            entry("1", author: 1, rank: 3),
            entry("2", author: 2, rank: 1),
            entry("3", author: 3, rank: 2),
            entry("4", author: 4, rank: 4, live: true),
            entry("5", author: 5, rank: 5, live: true),
            entry("6", author: 1, rank: 6, with: [9]),
        ]
        let shown = ActivityCardRules.cards(
            from: entries,
            canSee: { $0.rawValue != 3 },
            mutedOrBlocked: [UserID(rawValue: 9)],
            offline: [UserID(rawValue: 4)],
            capped: ["1", "5"],
            now: now
        )
        // 3 cannot see the channel, 4 is live but offline, 1 was seen for
        // three days, 6 names somebody muted — and 5, live, is never capped.
        #expect(shown.map(\.id) == ["2", "5"])
    }

    @Test("Discord's short clock")
    func timeAgo() {
        #expect(ActivityCardRules.timeAgo(since: now.addingTimeInterval(-30), now: now) == "30s ago")
        #expect(ActivityCardRules.timeAgo(since: now.addingTimeInterval(-90 * 60), now: now) == "2h ago")
        #expect(ActivityCardRules.timeAgo(since: now.addingTimeInterval(-11 * 3600), now: now) == "11h ago")
        #expect(ActivityCardRules.timeAgo(since: now.addingTimeInterval(-13 * 3600), now: now) == "1d ago")
        #expect(ActivityCardRules.timeAgo(since: now.addingTimeInterval(-10 * 86_400), now: now) == "1w ago")
        #expect(ActivityCardRules.elapsed(since: now.addingTimeInterval(-247), now: now) == "4:07")
        #expect(ActivityCardRules.elapsed(since: now.addingTimeInterval(-3753), now: now) == "1:02:33")
    }

    @Test("A streak shows from three days, on an entry from the last two")
    func streak() {
        #expect(ActivityCardRules.showsStreak(days: 3, entryDate: now.addingTimeInterval(-3600), now: now))
        #expect(!ActivityCardRules.showsStreak(days: 2, entryDate: now, now: now))
        #expect(!ActivityCardRules.showsStreak(days: 5, entryDate: now.addingTimeInterval(-49 * 3600), now: now))
    }

    @Test("An entry first seen more than three days ago is capped; the record keeps thirty days")
    func impressions() {
        var record = ActivityImpressions()
        let first = record.record(["a", "b"], at: now)
        let again = record.record(["a"], at: now.addingTimeInterval(60))
        #expect(first)
        #expect(!again)
        #expect(record.capped(at: now.addingTimeInterval(2 * 86_400)).isEmpty)
        #expect(record.capped(at: now.addingTimeInterval(4 * 86_400)) == ["a", "b"])
        record.record(["c"], at: now.addingTimeInterval(31 * 86_400))
        #expect(record.sightings.map(\.id) == ["c"])
    }

    @Test("The entry's own id dates it; a top artist's id is not a snowflake")
    func snowflakeDate() {
        #expect(entry("1538208195229115405", author: 1, rank: 1).snowflakeDate != nil)
        #expect(entry("2055703272", author: 1, rank: 1).snowflakeDate == nil)
    }
}
