import Foundation

/// "19m", "5d", "3mo" — the compact ages on a forum board.
///
/// **Computed rather than formatted, and that is the point.** A board four pages
/// deep draws a hundred of these, and `RelativeDateTimeFormatter` is documented
/// as expensive to construct and is not cheap to call either. `.formatted(
/// .relative(presentation: .named))` is the app's choice everywhere a date has
/// room to be a sentence; this is for the places where it has room for four
/// characters.
///
/// Deliberately not localised, for the same reason the timestamp beside it is
/// not: these are abbreviations of units, and the app has no localisation
/// catalog. The accessibility label on a row spells the age out in full.
nonisolated enum RelativeTime {

    /// The age of `date`, shortest sensible unit, clamped at "now".
    ///
    /// A future date reads as "now" rather than as a negative age: clock skew
    /// between this machine and Discord's is real and small, and a post stamped
    /// four seconds from now is not worth a different string.
    static func compact(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }

        let days = hours / 24
        if days < 7 { return "\(days)d" }

        // Weeks stop at four rather than running to five: a five-week gap and a
        // one-month gap are the same fact, and "5w" reads as more precise than
        // the number actually is.
        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w" }

        let months = days / 30
        if months < 12 { return "\(months)mo" }

        return "\(days / 365)y"
    }
}
