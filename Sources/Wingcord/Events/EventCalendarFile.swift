import AppKit
import Foundation
import WingcordCore

/// An event as an iCalendar file — Discord's "Add to Calendar", which writes
/// one with ics.js and offers it as `discord-event.ics` (`399893`).
///
/// **The event's own start and end, not the shown date's**: Discord's builder
/// takes `scheduled_start_time` and `scheduled_end_time` and the rule, so a
/// series lands in the calendar as a series from its current date on.
nonisolated enum EventCalendarFile {

    /// The file's text.
    static func contents(
        of event: ScheduledEvent,
        description: String,
        location: String,
        stamp: Date
    ) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Wingcord//Events//EN",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:\(event.id)@wingcord",
            "DTSTAMP:\(utc(stamp))",
            "DTSTART:\(utc(event.startsAt))",
            "DTEND:\(utc(event.endsAt ?? event.startsAt))",
            "SUMMARY:\(escaped(event.name))",
        ]
        if !description.isEmpty { lines.append("DESCRIPTION:\(escaped(description))") }
        lines.append("LOCATION:\(escaped(location))")
        if let rule = event.rule { lines.append("RRULE:\(recurrence(rule))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        // RFC 5545: CRLF line ends, and lines folded at 75 octets.
        return lines.map(folded).joined(separator: "\r\n") + "\r\n"
    }

    /// Where Discord says the event is: the place for an event somewhere
    /// else, "Discord: {server} server, {channel}" for one in a room.
    static func location(of event: ScheduledEvent, guildName: String?, channelName: String?) -> String {
        if let place = event.location.externalLocation { return place }
        if let guildName, let channelName { return "Discord: \(guildName) server, \(channelName)" }
        return "Discord"
    }

    /// Writes the file and hands it to the system, which opens it in the
    /// reader's calendar.
    @MainActor
    static func open(_ contents: String) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("discord-event.ics")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
            NSWorkspace.shared.open(file)
        } catch {
            DiagnosticLog.trace("events", "calendar file failed: \(error.localizedDescription)")
        }
    }

    // MARK: The rule

    /// rrule's own string for the rule, which is what ics.js writes.
    static func recurrence(_ rule: RecurrenceRule) -> String {
        let frequency = switch rule.frequency {
        case .yearly: "YEARLY"
        case .monthly: "MONTHLY"
        case .weekly: "WEEKLY"
        case .daily: "DAILY"
        }
        let names = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
        var parts = ["FREQ=\(frequency)"]
        if rule.interval != 1 { parts.append("INTERVAL=\(rule.interval)") }
        var days = (rule.byWeekday ?? []).filter { (0..<7).contains($0) }.map { names[$0] }
        days += (rule.byNWeekday ?? []).filter { (0..<7).contains($0.day) }.map { "\($0.n)\(names[$0.day])" }
        if !days.isEmpty { parts.append("BYDAY=\(days.joined(separator: ","))") }
        if let months = rule.byMonth, !months.isEmpty {
            parts.append("BYMONTH=\(months.map(String.init).joined(separator: ","))")
        }
        if let monthDays = rule.byMonthDay, !monthDays.isEmpty {
            parts.append("BYMONTHDAY=\(monthDays.map(String.init).joined(separator: ","))")
        }
        if let count = rule.count { parts.append("COUNT=\(count)") }
        if let end = rule.end { parts.append("UNTIL=\(utc(end))") }
        return parts.joined(separator: ";")
    }

    // MARK: Text

    private static func utc(_ date: Date) -> String {
        stamp.string(from: date)
    }

    /// iCalendar's UTC form, "20270101T060000Z". `DateFormatter` is safe to
    /// share for formatting once configured.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    /// RFC 5545's TEXT: backslash, semicolon, comma and line ends escaped.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// A line broken at 75 octets, each continuation starting with a space —
    /// and never inside a character.
    private static func folded(_ line: String) -> String {
        var pieces: [String] = []
        var current = ""
        var octets = 0
        for character in line {
            let size = String(character).utf8.count
            let limit = pieces.isEmpty ? 75 : 74
            if octets + size > limit {
                pieces.append(current)
                current = ""
                octets = 0
            }
            current.append(character)
            octets += size
        }
        pieces.append(current)
        return pieces.joined(separator: "\r\n ")
    }
}
