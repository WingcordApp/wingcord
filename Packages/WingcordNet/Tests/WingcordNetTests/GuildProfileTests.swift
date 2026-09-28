import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `GET /guilds/{id}/profile` — the card behind a server tag.
///
/// The two payloads below are **captured**, not invented: one partnered server
/// with traits and one verified server without. Between them they cover every
/// field the card draws, including the two that differ in kind — a `#rrggbb`
/// colour string in an API that is otherwise integers, and a `custom_banner_hash`
/// on a server whose `banner_hash` is null.
@Suite("Guild profiles")
struct GuildProfileTests {

    private func decode(_ json: String) throws -> GuildProfile {
        try JSONDecoder().decode(GuildProfileDTO.self, from: Data(json.utf8)).domain
    }

    private let partnered = """
    {"id":"494376688257372009","name":"Animal Crossing: New Horizons",
     "icon_hash":"a_3464d5c2df98d41f8468ca10f9e123e3","member_count":514437,
     "online_count":54363,"description":"The largest server for Animal Crossing.",
     "banner_hash":null,"tag":"ACNH","badge":6,"badge_color_primary":"#2be12b",
     "badge_color_secondary":"#22f33a","badge_hash":"f3c2ec0747910f73837735c1b2022306",
     "traits":[
       {"emoji_id":null,"emoji_name":"fire","emoji_animated":false,"label":"Cozy","position":0},
       {"emoji_id":null,"emoji_name":"black_cat","emoji_animated":false,"label":"Animal Crossing","position":1},
       {"emoji_id":null,"emoji_name":"tea","emoji_animated":false,"label":"Relaxed","position":2}],
     "features":["COMMUNITY","DISCOVERABLE","PARTNERED"],"visibility":1,
     "custom_banner_hash":"d66c652cf12c5f32560c682b528fe9f5",
     "premium_subscription_count":110,"premium_tier":3}
    """

    private let verified = """
    {"id":"1081121447963078238","name":"Google Gemini",
     "icon_hash":"f93404023ed2897ac6e544ff6dc442c1","member_count":74568,
     "online_count":8584,"description":"Welcome to the official Google Gemini server.",
     "banner_hash":null,"tag":"GMNI","badge":26,"badge_color_primary":"#3186ff",
     "badge_color_secondary":"#3186ff","badge_hash":"6a86b21e9ed1821d67354043b473a1fe",
     "traits":[],"features":["DISCOVERABLE","COMMUNITY","VERIFIED"],"visibility":1,
     "custom_banner_hash":"8f4e0492e986d6b38d4e9573b984e19d",
     "premium_subscription_count":29,"premium_tier":3}
    """

    @Test("Everything the card draws survives the decode")
    func fields() throws {
        let profile = try decode(partnered)
        #expect(profile.name == "Animal Crossing: New Horizons")
        #expect(profile.tag == "ACNH")
        #expect(profile.memberCount == 514_437)
        #expect(profile.onlineCount == 54_363)
        #expect(profile.badgeHash == "f3c2ec0747910f73837735c1b2022306")
        #expect(profile.premiumTier == 3)
    }

    /// **One mark, never a row of them.** This server is partnered *and*
    /// discoverable *and* a community; drawing every rosette it qualifies for is
    /// three marks saying one thing.
    @Test("The mark is Discord's highest")
    func markIsHighest() throws {
        #expect(try decode(partnered).mark?.kind == .partnered)
        #expect(try decode(verified).mark?.kind == .verified)
        #expect(try decode(partnered).mark?.isBoosted == true)
    }

    /// The one place in this API a colour is a string.
    @Test("Badge colours decode from `#rrggbb`")
    func badgeColours() throws {
        let profile = try decode(partnered)
        #expect(profile.badgeColorPrimary == 0x2B_E1_2B)
        #expect(profile.badgeColorSecondary == 0x22_F3_3A)
    }

    /// **The two banner hashes are kept apart, and this pins that they are.**
    ///
    /// They were folded — `banner_hash ?? custom_banner_hash` into one field —
    /// on the reading that they were one asset seen twice. They are not: the
    /// custom one is a discovery splash, which the banner path answers 404 for
    /// (measured; see `GuildBannerArt.artworkURL` in the app).
    @Test("The two banner hashes stay apart")
    func customBanner() throws {
        let profile = try decode(partnered)
        #expect(profile.bannerHash == nil)
        #expect(profile.customBannerHash == "d66c652cf12c5f32560c682b528fe9f5")
    }

    /// The emoji arrives as a **shortcode**, not a glyph, so the chip is blank
    /// unless it is resolved through the generated table.
    @Test("Trait emoji resolve through the Unicode table")
    func traits() throws {
        let profile = try decode(partnered)
        #expect(profile.traits.count == 3)
        #expect(profile.traits[0].label == "Cozy")
        #expect(profile.traits[0].glyph == UnicodeEmoji.glyph(for: "fire"))
        #expect(profile.traits[0].glyph != nil)
        // Position decides the order the chips are drawn in.
        #expect(profile.traits.map(\.id) == [0, 1, 2])
    }

    /// A trait with no words is decoration with nothing to decorate.
    @Test("A labelless trait is dropped")
    func labellessTrait() throws {
        let profile = try decode("""
        {"id":"1","traits":[{"emoji_name":"fire","position":0},
                            {"emoji_name":"tea","label":"Relaxed","position":1}]}
        """)
        #expect(profile.traits.count == 1)
        #expect(profile.traits[0].label == "Relaxed")
    }

    /// Discord adds fields to this route continually, and a server the reader is
    /// not in may answer with very little.
    @Test("A sparse payload decodes rather than throwing")
    func sparse() throws {
        let profile = try decode(#"{"id":"1"}"#)
        #expect(profile.name == "Unknown")
        #expect(profile.tag == nil)
        #expect(profile.memberCount == nil)
        #expect(profile.mark == nil)
    }

    /// A malformed colour must fall back to the standing's own, not to black.
    @Test("An unparsable badge colour is absent, not zero")
    func badColour() throws {
        let profile = try decode(#"{"id":"1","badge_color_primary":"rgb(1,2,3)"}"#)
        #expect(profile.badgeColorPrimary == nil)
    }
}
