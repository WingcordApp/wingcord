import Foundation

/// moment.js's `fromNow()` with its default thresholds and English words —
/// what Discord's client prints wherever it calls it bare: "a few seconds ago",
/// "an hour ago", "3 days ago".
///
/// **Its own arithmetic, not Foundation's**: every unit is the whole duration
/// rounded in that unit, the first threshold met wins, and a month is
/// 146097 / 4800 days — so "45 minutes ago" is already "an hour ago", and 26
/// days is "a month ago".
public enum MomentRelativeTime {
    public static func fromNow(_ date: Date, now: Date = .now) -> String {
        let interval = date.timeIntervalSince(now)
        let phrase = phrase(for: abs(interval))
        return interval > 0 ? "in \(phrase)" : "\(phrase) ago"
    }

    /// moment's `relativeTime` over its default thresholds: ss 44, s 45, m 45,
    /// h 22, d 26, M 11.
    static func phrase(for seconds: TimeInterval) -> String {
        let days = seconds / 86_400
        let months = days * 4_800 / 146_097
        let roundedSeconds = seconds.rounded()
        let minutes = (seconds / 60).rounded()
        let hours = (seconds / 3_600).rounded()
        let wholeDays = days.rounded()
        let wholeMonths = months.rounded()
        let years = (months / 12).rounded()

        if roundedSeconds <= 44 { return "a few seconds" }
        if minutes <= 1 { return "a minute" }
        if minutes < 45 { return "\(Int(minutes)) minutes" }
        if hours <= 1 { return "an hour" }
        if hours < 22 { return "\(Int(hours)) hours" }
        if wholeDays <= 1 { return "a day" }
        if wholeDays < 26 { return "\(Int(wholeDays)) days" }
        if wholeMonths <= 1 { return "a month" }
        if wholeMonths < 11 { return "\(Int(wholeMonths)) months" }
        if years <= 1 { return "a year" }
        return "\(Int(years)) years"
    }
}
