import Foundation

/// When a message may be scheduled for, and the times Discord suggests.
///
/// **Discord's own rules (module `566908`)**: no sooner than ten minutes from
/// now and no later than eight days. Its three suggestions move with the clock —
/// 9 am and 1 pm today while each is still more than ten minutes off, the same
/// times tomorrow once it is not, and next Monday at 9 — and their titles are
/// fixed strings, lower-case "am" and all.
///
/// Every function takes the clock and the calendar from its caller: a value
/// sent to Discord is no place for a hidden `Date.now`.
public enum ScheduleWindow {
    /// How soon a message may be scheduled for.
    public static let lead: TimeInterval = 600
    /// How far ahead it may be scheduled.
    public static let reach: TimeInterval = 691_200

    public struct Preset: Hashable, Sendable, Identifiable {
        public var title: String
        public var date: Date
        public var id: String { title }
    }

    /// Why a chosen time is refused — Discord's two sentences.
    public enum Problem: Hashable, Sendable {
        case tooSoon
        case tooFar

        public var message: String {
            switch self {
            case .tooSoon: "Scheduled time is too soon"
            case .tooFar: "Scheduled time is too far away"
            }
        }
    }

    /// The Schedule Message submenu, above its Custom… row.
    public static func presets(at now: Date, calendar: Calendar = .current) -> [Preset] {
        let earliest = now.addingTimeInterval(lead)
        let today = calendar.startOfDay(for: now)
        func at(_ hour: Int, on day: Date) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        func nextDay(_ date: Date) -> Date {
            calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        }
        let morning = at(9, on: today)
        let afternoon = at(13, on: today)
        return [
            morning > earliest
                ? Preset(title: "Today at 9:00am", date: morning)
                : Preset(title: "Tomorrow at 9:00am", date: nextDay(morning)),
            afternoon > earliest
                ? Preset(title: "Today at 1:00pm", date: afternoon)
                : Preset(title: "Tomorrow at 1:00pm", date: nextDay(afternoon)),
            Preset(title: "Monday at 9:00am", date: at(9, on: nextMonday(after: now, calendar: calendar))),
        ]
    }

    /// Where the custom picker starts: the top of the next hour, or of the one
    /// after when that is inside the ten minutes.
    public static func suggestedTime(at now: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let next = hour.addingTimeInterval(3600)
        return next < now.addingTimeInterval(lead) ? next.addingTimeInterval(3600) : next
    }

    /// What is wrong with a chosen time, if anything.
    public static func problem(with date: Date, at now: Date) -> Problem? {
        if date < now.addingTimeInterval(lead) { return .tooSoon }
        if date > now.addingTimeInterval(reach) { return .tooFar }
        return nil
    }

    /// Midnight on the Monday of next week — moment's `startOf("isoWeek")` plus
    /// a week, so a Sunday's "Monday" is tomorrow and a Monday's is in seven
    /// days.
    private static func nextMonday(after now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        // `weekday` is 1 for Sunday; an ISO week starts on Monday.
        let sinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -sinceMonday, to: today) ?? today
        return calendar.date(byAdding: .day, value: 7, to: monday) ?? monday
    }
}
