import Testing
@testable import WingcordCore

/// Discord's server mark: which one a server wears, and what its flyout says.
/// The cases are Discord's own rule (`426983` and `176128` in its web bundle),
/// and the words are its strings.
struct GuildMarkTests {

    @Test("Staff outranks everything, then verified and partnered together")
    func order() {
        #expect(GuildMark(features: ["INTERNAL_EMPLOYEE_ONLY", "VERIFIED"])?.kind == .staff)
        #expect(GuildMark(features: ["VERIFIED", "PARTNERED", "COMMUNITY"])?.kind == .verifiedAndPartnered)
        #expect(GuildMark(features: ["VERIFIED", "COMMUNITY", "DISCOVERABLE"])?.kind == .verified)
        #expect(GuildMark(features: ["PARTNERED", "COMMUNITY", "DISCOVERABLE"])?.kind == .partnered)
    }

    /// Discoverable is a *kind of community*: without `COMMUNITY` it is no mark.
    @Test("Discoverable needs a community")
    func discoverableNeedsCommunity() {
        #expect(GuildMark(features: ["COMMUNITY", "DISCOVERABLE"])?.kind == .discoverable)
        #expect(GuildMark(features: ["COMMUNITY"])?.kind == .community)
        #expect(GuildMark(features: ["DISCOVERABLE"]) == nil)
        #expect(GuildMark(features: []) == nil)
    }

    @Test("The last line says who may join")
    func admission() {
        #expect(GuildMark(features: ["COMMUNITY", "DISCOVERABLE"])?.detail == "Anyone can join this server.")
        #expect(GuildMark(features: ["COMMUNITY"])?.detail == "People with an invite link can join.")
        let applying = GuildMark(features: [
            "COMMUNITY", "MEMBER_VERIFICATION_MANUAL_APPROVAL", "MEMBER_VERIFICATION_GATE_ENABLED",
        ])
        #expect(applying?.detail == "People must submit an application to join.")
    }

    @Test("Verified and partnered name themselves under the title")
    func subtitles() {
        let verified = GuildMark(features: ["VERIFIED", "COMMUNITY", "DISCOVERABLE"])
        #expect(verified?.title == "Community Server")
        #expect(verified?.subtitle == "Verified")
        #expect(verified?.accessibilityLabel == "Verified")
        #expect(GuildMark(features: ["PARTNERED"])?.subtitle == "Discord Partner")
        #expect(GuildMark(features: ["VERIFIED", "PARTNERED"])?.subtitle == "Verified & Partnered")
        #expect(GuildMark(features: ["COMMUNITY"])?.subtitle == nil)
    }

    /// The boost strip: any boost at all, or a level, and Discord's plural.
    @Test("The boost strip")
    func boosts() {
        let boosted = GuildMark(features: ["COMMUNITY", "DISCOVERABLE"], boostTier: 3, boostCount: 261)
        #expect(boosted?.isBoosted == true)
        #expect(boosted?.boostLevel == "Level 3")
        #expect(boosted?.boostCountLabel == "261 Boosts")
        let one = GuildMark(features: ["COMMUNITY"], boostCount: 1)
        #expect(one?.isBoosted == true)
        #expect(one?.boostLevel == "No Level")
        #expect(one?.boostCountLabel == "1 Boost")
        #expect(GuildMark(features: ["COMMUNITY"])?.isBoosted == false)
    }
}
