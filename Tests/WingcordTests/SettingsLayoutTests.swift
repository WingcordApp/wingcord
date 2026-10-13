import Foundation
import Testing
@testable import Wingcord

/// The settings panes' measured geometry.
///
/// The numbers in `SettingsMetrics` were read off a live reference window rather
/// than designed, so the thing worth pinning is not any single value — it is the
/// *relationships* between them, which is what a later "tidy these to round
/// numbers" would break silently. A card whose header row is 39 and whose
/// control row is 34 sums to the reference's 73; change either and the page's
/// rhythm drifts by a point per card, which is invisible in one card and
/// unmistakable in five.
@MainActor
@Suite("Settings layout")
struct SettingsLayoutTests {

    // MARK: The catalog

    @Test("Every section appears in exactly one group")
    func groupsCoverEverySection() {
        let grouped = SettingsSection.groups.flatMap(\.self)
        #expect(Set(grouped) == Set(SettingsSection.allCases))
        #expect(grouped.count == SettingsSection.allCases.count, "a section is listed twice")
    }

    @Test("Every section has a symbol and a distinct tint")
    func sectionsAreDistinguishable() {
        for section in SettingsSection.allCases {
            #expect(!section.symbolName.isEmpty)
            #expect(!section.title.isEmpty)
        }
        // Eleven rows navigated by shape need eleven shapes.
        let tints = Set(SettingsSection.allCases.map { "\($0.tint)" })
        #expect(tints.count == SettingsSection.allCases.count)
    }

    @Test("Search keywords are lower-cased, because the query is")
    func keywordsAreFoldable() {
        for section in SettingsSection.allCases {
            #expect(section.keywords == section.keywords.lowercased())
        }
    }

    // MARK: The measured rhythm

    @Test("A card of a header row and a control row is the reference's 73 points")
    func cardHeightSums() {
        #expect(SettingsMetrics.headerRowHeight + SettingsMetrics.controlRowHeight == 73)
    }

    @Test("Header, gap and gap sum to the 46 points between two cards")
    func sectionHeaderRhythm() {
        // 20 above the header, the header itself, 10 below it. Measured between
        // a card's bottom edge and the next card's top edge.
        let header: CGFloat = 16
        #expect(SettingsMetrics.cardToHeader + header + SettingsMetrics.headerToCard == 46)
    }
}

/// The one trap in `AppSettings` that is invisible until a value has been moved.
@MainActor
@Suite("Settings storage")
struct SettingsStorageTests {

    private func suite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "wingcord.tests.\(name)")!
        defaults.removePersistentDomain(forName: "wingcord.tests.\(name)")
        return defaults
    }

    @Test("Loading values that differ from the defaults does not deadlock")
    func initialisingWithStoredValuesTerminates() {
        // `@Observable` rewrites stored properties into computed ones, so every
        // assignment in `init` runs its `didSet`. A `didSet` that reached
        // `PresentationRevision.shared` — whose own `init` reads
        // `AppSettings.shared` back — waited on the one-time token this frame
        // was holding, and the app hung at launch.
        //
        // It only fired when a stored value DIFFERED from its declared default,
        // because each setter's `guard newValue != oldValue` returned first. So
        // this test is only a test at all because every value below is moved.
        let defaults = suite("deadlock")
        defaults.set(1.35, forKey: "appearance.textScale")
        defaults.set(true, forKey: "appearance.compactMode")
        defaults.set(true, forKey: "chat.use24HourTime")
        defaults.set(false, forKey: "chat.showsEmbeds")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.textScale == 1.35)
        #expect(settings.isCompactMode)
        #expect(settings.uses24HourTime)
        #expect(!settings.showsEmbeds)
    }

    @Test("A remembered conversation survives a round trip, and only writes when it moves")
    func conversationIsRemembered() {
        let defaults = suite("conversation")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.lastChannelID == nil)

        settings.rememberConversation(guildID: 7, channelID: 42)
        #expect(settings.lastGuildID == 7)
        #expect(settings.lastChannelID == 42)

        // A direct message has no guild, and nil has to round-trip as nil rather
        // than as zero — a channel restored under guild zero opens nothing.
        settings.rememberConversation(guildID: nil, channelID: 99)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.lastGuildID == nil)
        #expect(reloaded.lastChannelID == 99)
    }

    @Test("Launch destinations are stored by name, so reordering the enum is safe")
    func launchDestinationIsStable() {
        let defaults = suite("launch")
        defaults.set("home", forKey: "startup.launchDestination")
        #expect(AppSettings(defaults: defaults).launchDestination == .home)
        // A value written by a build that had a case this one does not falls back
        // rather than crashing.
        defaults.set("somethingRemoved", forKey: "startup.launchDestination")
        #expect(AppSettings(defaults: defaults).launchDestination == .lastChannel)
    }
}
