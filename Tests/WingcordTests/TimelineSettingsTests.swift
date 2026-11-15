import Foundation
import Testing
@testable import Wingcord

/// The settings half of the presentation.
///
/// What is worth pinning here is not the numbers but the two properties that
/// make the whole arrangement safe: that equality compares the *inputs* and not
/// the derived formatters, and that a value carries its own formatters rather
/// than reaching for the store. Break the first and every appearance signal
/// discards every laid-out row in the app; break the second and the layout
/// engine, which is `nonisolated`, cannot compile.
@Suite("Timeline settings")
struct TimelineSettingsTests {

    private func settings(
        compact: Bool = false,
        embeds: Bool = true,
        twentyFourHour: Bool = false,
        locale: String = "en_US_POSIX"
    ) -> TimelineSettings {
        TimelineSettings(
            isCompact: compact,
            showsEmbeds: embeds,
            uses24HourTime: twentyFourHour,
            locale: Locale(identifier: locale)
        )
    }

    // MARK: Equality

    @Test("Two values built from the same inputs are equal")
    func equalityIgnoresTheFormatters() {
        // Each carries three freshly allocated `DateFormatter`s. If equality
        // reached them it would be comparing object identity, which is never
        // equal — and `PresentationRevision.invalidate()` would then bump on
        // every appearance signal, discarding the whole row cache each time.
        #expect(settings() == settings())
    }

    @Test("Each input moves equality")
    func everyInputIsPartOfTheKey() {
        let base = settings()
        #expect(base != settings(compact: true))
        #expect(base != settings(embeds: false))
        #expect(base != settings(twentyFourHour: true))
        #expect(base != settings(locale: "de_DE"))
    }

    // MARK: Density

    @Test("Compact tightens the run gap without collapsing it")
    func compactIsDenserButStillGrouped() {
        let comfortable = settings()
        let compact = settings(compact: true)
        #expect(compact.runSpacing < comfortable.runSpacing)
        #expect(compact.runBottomPadding < comfortable.runBottomPadding)
        // Runs are what the eye groups by. A compact gap that fell to the gap
        // *inside* a run would leave one undifferentiated column, which is a
        // denser page that is harder to read rather than one that fits more.
        #expect(compact.runSpacing > TimelineMetrics.lineSpacing)
    }

    // MARK: The clock

    @Test("The clock setting changes the time it writes")
    func clockIsHonoured() {
        // 21:05 UTC, read back in a fixed zone so the assertion is about the
        // FORMAT and not about where the test is run.
        let date = Date(timeIntervalSince1970: 1_700_257_500)
        let twelve = settings().time(date)
        let twentyFour = settings(twentyFourHour: true).time(date)
        #expect(twelve != twentyFour)
        #expect(twelve.contains(":"))
        #expect(twentyFour.contains(":"))
        // The twelve-hour form carries a period marker; the other must not.
        #expect(twelve.uppercased().contains("AM") || twelve.uppercased().contains("PM"))
        #expect(!twentyFour.uppercased().contains("AM"))
        #expect(!twentyFour.uppercased().contains("PM"))
    }

    @Test("Today and yesterday are named, not dated")
    func nearDatesAreNamed() {
        let value = settings()
        let calendar = Calendar(identifier: .gregorian)
        #expect(value.dayLabel(.now, calendar: calendar) == "Today")
        #expect(value.dayLabel(.now.addingTimeInterval(-86_400), calendar: calendar) == "Yesterday")
        // A week back is a real date, whatever the locale writes it as.
        let old = value.dayLabel(.now.addingTimeInterval(-7 * 86_400), calendar: calendar)
        #expect(old != "Today" && old != "Yesterday" && !old.isEmpty)
    }

    @Test("A run head's timestamp names the day and carries the time")
    func timestampCombinesBoth() {
        let value = settings()
        let label = value.timestampLabel(.now, calendar: Calendar(identifier: .gregorian))
        #expect(label.hasPrefix("Today at "))
        #expect(label.hasSuffix(value.time(.now)))
    }

    // MARK: The shared value

    @Test("The test value is locale-pinned, so a formatting assertion travels")
    func comfortableIsDeterministic() {
        #expect(TimelineSettings.comfortable.localeIdentifier == "en_US_POSIX")
        #expect(!TimelineSettings.comfortable.isCompact)
        #expect(TimelineSettings.comfortable.showsEmbeds)
    }
}

// MARK: - Every input reaches the transcript

/// **A preference that persists and changes nothing is worse than no
/// preference** — `INVARIANTS.md` §1 — and this is the shape it takes here.
/// Three things have to be true for one of these to reach a drawn row, and each
/// of them is a separate place somebody can forget:
///
/// 1. `TimelineSettings.current()` reads it off the store.
/// 2. `==` compares it, or `PresentationRevision.invalidate()`'s guard swallows
///    the change and no cached row is discarded.
/// 3. the setter calls `notifyPresentation()`, or nothing asks until some
///    unrelated signal happens along.
///
/// Two of the three were missing when the density slider and the timestamp
/// switches were added, and neither failure says anything on screen: the
/// setting sticks, the window keeps the old layout, and it comes right the next
/// time the appearance changes.
@MainActor
@Suite("Timeline settings reach the transcript", .serialized)
struct TimelineSettingsReachTests {

    /// Drives one preference through the real store and reports whether the
    /// resolved value moved.
    private func resolves(
        in settings: AppSettings,
        _ change: (AppSettings) -> Void,
        restore: (AppSettings) -> Void
    ) -> Bool {
        // From the value `restore` leaves, not whatever the store holds: on a Mac
        // whose default is already the changed value, nothing would move.
        restore(settings)
        let before = TimelineSettings.current()
        change(settings)
        let after = TimelineSettings.current()
        restore(settings)
        return before != after
    }

    @Test("Density, seconds and always-on timestamps all move the resolved value")
    func everyInputResolves() async {
        await withAppSettings(
            \.messageGroupSpacing, \.showsSeconds, \.alwaysShowsTimestamps, \.isCompactMode,
            \.uses24HourTime, \.usesMessageBubbles, \.hidesMessageTimes
        ) { settings in
            #expect(resolves(in: settings, { $0.messageGroupSpacing = 12 }, restore: { $0.messageGroupSpacing = 0 }))
            #expect(resolves(in: settings, { $0.showsSeconds = true }, restore: { $0.showsSeconds = false }))
            #expect(resolves(
                in: settings,
                { $0.alwaysShowsTimestamps = true },
                restore: { $0.alwaysShowsTimestamps = false }
            ))
            #expect(resolves(in: settings, { $0.isCompactMode = true }, restore: { $0.isCompactMode = false }))
            #expect(resolves(in: settings, { $0.uses24HourTime = true }, restore: { $0.uses24HourTime = false }))
            #expect(resolves(in: settings, { $0.usesMessageBubbles = true }, restore: { $0.usesMessageBubbles = false }))
            #expect(resolves(in: settings, { $0.hidesMessageTimes = true }, restore: { $0.hidesMessageTimes = false }))
        }
    }

    @Test("And each one moves the revision the row cache keys on")
    func everyInputBumpsTheRevision() async {
        await withAppSettings(
            \.messageGroupSpacing, \.showsSeconds, \.alwaysShowsTimestamps, \.usesMessageBubbles, \.hidesMessageTimes
        ) { settings in
            @MainActor func bumps(_ change: (AppSettings) -> Void, restore: (AppSettings) -> Void) -> Bool {
                let before = PresentationRevision.shared.value
                change(settings)
                let moved = PresentationRevision.shared.value != before
                restore(settings)
                return moved
            }
            #expect(bumps({ $0.messageGroupSpacing = 8 }, restore: { $0.messageGroupSpacing = 0 }))
            #expect(bumps({ $0.showsSeconds = true }, restore: { $0.showsSeconds = false }))
            #expect(bumps(
                { $0.alwaysShowsTimestamps = true },
                restore: { $0.alwaysShowsTimestamps = false }
            ))
            #expect(bumps({ $0.usesMessageBubbles = true }, restore: { $0.usesMessageBubbles = false }))
            #expect(bumps({ $0.hidesMessageTimes = true }, restore: { $0.hidesMessageTimes = false }))
        }
    }

    @Test("The group spacing is clamped rather than trusted")
    func spacingIsClamped() async {
        await withAppSettings(\.messageGroupSpacing) { settings in
            settings.messageGroupSpacing = 500
            #expect(settings.messageGroupSpacing == 24)
            settings.messageGroupSpacing = -10
            #expect(settings.messageGroupSpacing == 0)
        }
    }

    @Test("Density and the slider compose rather than override each other")
    func densityAndSpacingCompose() {
        // Compact is a *shape* — it closes the run's bottom padding and shrinks
        // the author gutter as well — and the slider is the air between one
        // person's block and the next.
        let comfortable = TimelineSettings(
            isCompact: false, showsEmbeds: true, uses24HourTime: false,
            groupSpacing: 6, locale: Locale(identifier: "en_US_POSIX")
        )
        let compact = TimelineSettings(
            isCompact: true, showsEmbeds: true, uses24HourTime: false,
            groupSpacing: 6, locale: Locale(identifier: "en_US_POSIX")
        )
        #expect(comfortable.runSpacing == TimelineMetrics.runSpacing + 6)
        #expect(compact.runSpacing == TimelineMetrics.compactRunSpacing + 6)
        #expect(compact.runSpacing < comfortable.runSpacing)
    }

    @Test("Seconds go through the locale's own template")
    func secondsUseTheTemplate() {
        // Not appended as ":ss" — the separator and the running order are the
        // locale's, and a hard-coded colon is wrong wherever the minute
        // separator is not one.
        let plain = TimelineSettings(
            isCompact: false, showsEmbeds: true, uses24HourTime: true,
            showsSeconds: false, locale: Locale(identifier: "en_US_POSIX")
        )
        let withSeconds = TimelineSettings(
            isCompact: false, showsEmbeds: true, uses24HourTime: true,
            showsSeconds: true, locale: Locale(identifier: "en_US_POSIX")
        )
        let noon = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(plain.time(noon).count < withSeconds.time(noon).count)
        #expect(plain != withSeconds)
    }
}
