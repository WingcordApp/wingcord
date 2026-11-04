import Foundation
import Testing
@testable import Wingcord

/// The eight Nitro tenure badges.
///
/// **Everything here was read out of Discord's own bundle**, so these tests pin
/// the transcription rather than a judgement: the ids are what the profile route
/// sends, and getting one wrong means a badge falls back to a one-line label
/// with no page behind it and nobody notices, because the row still draws.
@MainActor
@Suite("Premium tenure")
struct PremiumTenureTests {

    @Test("Eight tiers, at Discord's own thresholds")
    func eightTiers() {
        #expect(PremiumTenure.all.count == 8)
        let months = [1, 3, 6, 12, 24, 36, 60, 72]
        #expect(PremiumTenure.all.map(\.id) == months.map { "premium_tenure_\($0)_month_v2" })
        // Ascending, which is the order the modal's grid reads in.
        #expect(PremiumTenure.all.map(\.name)
            == ["Bronze", "Silver", "Gold", "Platinum", "Diamond", "Emerald", "Ruby", "Opal"])
    }

    @Test("Every id resolves, and nothing else does")
    func lookup() {
        for tier in PremiumTenure.all {
            #expect(PremiumTenure.named(tier.id) == tier)
            #expect(PremiumTenure.isTenure(tier.id))
        }
        // The other badges on a real row, which must keep the plain label.
        for other in ["hypesquad_house_3", "guild_booster_lvl1", "quest_completed",
                      "legacy_username", "orb_profile_badge", "premium"] {
            #expect(PremiumTenure.named(other) == nil)
        }
        // The v1 ids are not what this route sends, and a lookup that matched
        // them loosely would draw the wrong tier's artwork.
        #expect(PremiumTenure.named("premium_tenure_3_month") == nil)
    }

    @Test("Each tier has its own artwork, and it is the SVG Discord serves")
    func artwork() {
        let urls = PremiumTenure.all.compactMap(\.artworkURL)
        #expect(urls.count == 8)
        #expect(Set(urls).count == 8)
        for url in urls {
            #expect(url.host() == "discord.com")
            #expect(url.pathExtension == "svg")
        }
    }

    @Test("Requirements are Discord's own words, not arithmetic on the months")
    func requirements() {
        #expect(PremiumTenure.all.map(\.requirement) == [
            "1 Month", "3 Months", "6 Months", "1 Year",
            "2 Years", "3 Years", "5 Years", "6+ Years",
        ])
    }

    @Test("The date line is the card's, not the badge's description")
    func subscriberLine() throws {
        let tier = try #require(PremiumTenure.named("premium_tenure_3_month_v2"))
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 5
        parts.day = 24
        let date = try #require(Calendar(identifier: .gregorian).date(from: parts))
        // Word for word what the directory's own `info_label` says, in any region.
        #expect(tier.subscriberLine(since: date) == "Subscriber since 5/24/26")
        // Nothing to say without a date, and an empty line is worse than none.
        #expect(tier.subscriberLine(since: nil) == nil)
    }
}
