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
