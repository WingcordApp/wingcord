import AppKit
import Foundation

/// What the reader's preferences contribute to a laid-out transcript.
///
/// The sibling of `MessageTextStyle`: that one carries what the *appearance*
/// contributes — fonts and colours — and this one carries what the *settings* do.
/// Both are resolved once by `PresentationRevision`, handed to the layout engine
/// inside its `Input`, and read from the layout task off the main actor.
///
/// **Nothing here is read from `AppSettings` at layout time**, and that is the
/// whole point. The engine is `nonisolated` and runs off the main actor, so it
/// could not read a main-actor singleton even if it wanted to — and a surface
/// that reached for one would also be reading a value the row cache cannot see,
/// which is a stale row that never invalidates. Settings arrive as a value, the
/// value participates in the presentation revision, and the cache key carries
/// the revision. Change a setting and every affected row misses exactly once.
///
/// `@unchecked Sendable`: the stored properties are four scalars and three
/// `DateFormatter`s. `DateFormatter` is documented thread-safe for *formatting*
/// once configured, and these are configured in `init` and never mutated after —
/// the same arrangement, and the same reasoning, as `MessageTextStyle`'s fonts.
nonisolated struct TimelineSettings: @unchecked Sendable {

    // MARK: The inputs
    //
    // Equality compares these and nothing else. The formatters below are derived
    // from them, and comparing two `DateFormatter`s would be comparing object
    // identity — which is never equal, so every appearance signal would discard
    // every laid-out row in the app.

    /// Tighter runs. Not a smaller font: the reader chose a text size, and a
    /// density control that quietly overrode it would be answering a question
    /// nobody asked.
    var isCompact: Bool
    /// Whether a link's card is laid out at all. Off means the embed is not
    /// measured, not merely hidden — a card that is laid out and then not drawn
    /// costs its framesetting for nothing.
    var showsEmbeds: Bool
    var uses24HourTime: Bool
    /// Whether a time carries seconds. Part of the key because the formatters
    /// below are built from it.
    var showsSeconds: Bool
    /// Whether a continuation row's gutter time is always drawn, or only under
    /// the pointer. **Layout, not paint**: the gutter is the same width either
    /// way, but a row that always draws one is a row whose repaint no longer
    /// depends on hover.
    var alwaysShowsTimestamps: Bool
    /// Extra air between runs, on top of what `isCompact` sets.
    var groupSpacing: CGFloat
    /// Part of the key because the formatters below are built against it, and a
    /// locale change has to rebuild them.
    var localeIdentifier: String

    // MARK: Derived

    private let timeFormatter: DateFormatter
    private let dayFormatter: DateFormatter
    private let dateAndTimeFormatter: DateFormatter

    init(
        isCompact: Bool,
        showsEmbeds: Bool,
        uses24HourTime: Bool,
        showsSeconds: Bool = false,
        alwaysShowsTimestamps: Bool = false,
        groupSpacing: CGFloat = 0,
        locale: Locale
    ) {
        self.isCompact = isCompact
        self.showsEmbeds = showsEmbeds
        self.uses24HourTime = uses24HourTime
        self.showsSeconds = showsSeconds
        self.alwaysShowsTimestamps = alwaysShowsTimestamps
        self.groupSpacing = groupSpacing
        self.localeIdentifier = locale.identifier

        // **One formatter each, built here and reused for the life of the
        // revision.** `Date.formatted(.dateTime…)` resolves its skeleton against
        // the locale on every single call: measured at 1.96 µs against 0.36 µs
        // for a configured `DateFormatter`, and the transcript formats two or
        // three timestamps per message on every relayout. That is most of a
        // millisecond per width change, spent re-deriving an answer that cannot
        // have changed.
        //
        // Templates rather than literal patterns, so the SEPARATOR and the
        // running order stay the locale's own — a hard-coded "HH:mm" is correct
        // in Britain and wrong in a dozen places.
        let hour = uses24HourTime ? "H" : "h"
        // Seconds go in the template, not on the end of the string: the
        // separator and the running order are the locale's own, and a
        // hard-coded ":ss" is wrong wherever the minute separator is not a
        // colon.
        let clock = hour + "mm" + (showsSeconds ? "ss" : "")
        timeFormatter = Self.formatter(template: clock, locale: locale)
        dayFormatter = Self.formatter(template: "EEEEdMMMMy", locale: locale)
        dateAndTimeFormatter = Self.formatter(template: "dMy" + clock, locale: locale)
    }

    private static func formatter(template: String, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    // MARK: Metrics

    /// The gap above a run's first message.
    ///
    /// The density's own value plus whatever the slider adds. Compact is a
    /// *shape* — it closes the run's bottom padding and shrinks the author
    /// gutter as well — and the slider is the air between one person's block and
    /// the next, so the two compose rather than override each other.
    var runSpacing: CGFloat {
        (isCompact ? TimelineMetrics.compactRunSpacing : TimelineMetrics.runSpacing)
            + groupSpacing
    }

    /// The gap under a run's last message.
    var runBottomPadding: CGFloat {
        isCompact ? 0 : TimelineMetrics.runBottomPadding
    }

    // MARK: Labels

    /// `HH:mm`, or `h:mm a` — the gutter time on a continuation row.
    func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// A day separator's label.
    func dayLabel(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    /// The timestamp beside an author's name.
    func timestampLabel(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today at " + time(date) }
        if calendar.isDateInYesterday(date) { return "Yesterday at " + time(date) }
        return dateAndTimeFormatter.string(from: date)
    }

    /// A fixed, locale-independent value for tests and previews.
    ///
    /// Pinned to `en_US_POSIX` on purpose: a test that formatted against the
    /// machine's locale would pass in London and fail in Berlin, and the thing
    /// under test is the layout, not the calendar.
    static let comfortable = TimelineSettings(
        isCompact: false,
        showsEmbeds: true,
        uses24HourTime: false,
        locale: Locale(identifier: "en_US_POSIX")
    )

    // MARK: Resolution

    /// Read from the store. Main-actor, called once per revision.
    @MainActor
    static func current() -> TimelineSettings {
        let settings = AppSettings.shared
        return TimelineSettings(
            isCompact: settings.isCompactMode,
            showsEmbeds: settings.showsEmbeds,
            uses24HourTime: settings.uses24HourTime,
            showsSeconds: settings.showsSeconds,
            alwaysShowsTimestamps: settings.alwaysShowsTimestamps,
            groupSpacing: settings.messageGroupSpacing,
            locale: .current
        )
    }
}

extension TimelineSettings: Equatable {
    /// The inputs only — see the note on the stored properties.
    /// **Every input, or the revision swallows the change.**
    /// `PresentationRevision.invalidate` guards on this being different before
    /// it bumps the counter — several system signals fire together and each bump
    /// discards every laid-out row in the app — so a field left out here is a
    /// preference that persists and changes nothing, which is §1's forbidden
    /// shape.
    nonisolated static func == (lhs: TimelineSettings, rhs: TimelineSettings) -> Bool {
        lhs.isCompact == rhs.isCompact
            && lhs.showsEmbeds == rhs.showsEmbeds
            && lhs.uses24HourTime == rhs.uses24HourTime
            && lhs.showsSeconds == rhs.showsSeconds
            && lhs.alwaysShowsTimestamps == rhs.alwaysShowsTimestamps
            && lhs.groupSpacing == rhs.groupSpacing
            && lhs.localeIdentifier == rhs.localeIdentifier
    }
}
