import Foundation
import WingcordCore

/// A friend whose friendship turns a year older this week: Discord's Friend
/// Anniversaries row ("Friends for 6 years", Send a GIF, Gift).
struct FriendAnniversary: Identifiable, Hashable, Sendable {
    var id: UserID
    var name: String
    var avatarURL: URL?
    var monogram: String
    var status: PresenceStatus
    var client: PresenceClient
    /// Discord's count: whole months since, over twelve, rounded.
    var years: Int

    /// "Friends for 6 years", Discord's words (`S3fdq7`).
    var line: String { years == 1 ? "Friends for 1 year" : "Friends for \(years) years" }
}

/// Discord's rule (`PremiumGiftingIntentStore`, web.js 2026-11-17): the
/// anniversary of the day the friendship began, in last year, this year or
/// next (so the week across New Year counts), within seven days either side,
/// and never the first day itself.
nonisolated enum FriendAnniversaryRule {
    static let window = 7

    static func isNear(_ since: Date, now: Date, calendar: Calendar = .current) -> Bool {
        let year = calendar.component(.year, from: now)
        let sinceYear = calendar.component(.year, from: since)
        for offset in [-1, 0, 1] {
            let target = year + offset
            guard target > sinceYear, let day = anniversary(of: since, in: target, calendar: calendar) else { continue }
            let days = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)
            ).day ?? .max
            if abs(days) <= window { return true }
        }
        return false
    }

    /// The day in `year` (the 28th for a 29 February in a common year, as
    /// date-fns' `setYear` does).
    static func anniversary(of since: Date, in year: Int, calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.month, .day], from: since)
        parts.year = year
        if parts.month == 2, parts.day == 29,
           let probe = calendar.date(from: DateComponents(year: year, month: 3, day: 1)),
           calendar.component(.day, from: calendar.date(byAdding: .day, value: -1, to: probe) ?? probe) == 28 {
            parts.day = 28
        }
        return calendar.date(from: parts)
    }

    /// `Math.round(differenceInMonths(now, since) / 12)`.
    static func years(since: Date, now: Date, calendar: Calendar = .current) -> Int {
        let months = calendar.dateComponents([.month], from: since, to: now).month ?? 0
        return Int((Double(months) / 12).rounded())
    }
}

extension AppModel {

    /// Discord's Friend Anniversaries, at the top of the Friends list.
    ///
    /// **Its people are the ones you talk to.** Discord asks for a direct
    /// message probability above zero, from an affinity model this client
    /// doesn't have; an open conversation with them is the same question asked
    /// of what's here, and the order is the most recent conversation first,
    /// where Discord's is the most likely one.
    func friendAnniversaries(now: Date = .now, calendar: Calendar = .current) -> [FriendAnniversary] {
        var found: [(FriendAnniversary, MessageID?)] = []
        for (userID, relationship) in relationships where relationship == .friend {
            guard !ignoredUserIDs.contains(userID),
                  let since = relationshipFacts[userID]?.since,
                  FriendAnniversaryRule.isNear(since, now: now, calendar: calendar),
                  let conversation = directMessageChannel(with: userID)
            else { continue }
            let user = users[userID]
            let presence = presences[userID]
            found.append((
                FriendAnniversary(
                    id: userID,
                    name: friendNicknames[userID] ?? user?.preferredName ?? "Unknown",
                    avatarURL: user.flatMap { avatarURL(for: $0, side: 36) },
                    monogram: user?.monogram ?? "?",
                    status: presenceStatus(of: userID),
                    client: presence?.client ?? .desktop,
                    years: max(1, FriendAnniversaryRule.years(since: since, now: now, calendar: calendar))
                ),
                channelIndex[conversation]?.lastMessageID
            ))
        }
        return found.sorted { ($0.1?.rawValue ?? 0) > ($1.1?.rawValue ?? 0) }.map(\.0)
    }
}
