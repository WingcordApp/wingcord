import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `GET /users/{id}/profile`, and the one thing its shape makes easy to break.
///
/// **This route is assigned to the store WHOLE rather than merged**, so that a
/// bio somebody deleted can actually disappear — see `SessionController`. The
/// consequence is that `UserProfileDTO.domain` builds a fresh `UserDecoration`
/// by naming every field it wants to keep, and a cosmetic left off that list is
/// not merely absent from the response: it is **erased from a user who had it**,
/// in front of the reader, the instant the profile finishes loading.
///
/// That is exactly how a styled display name came to render for a few hundred
/// milliseconds and then vanish. These tests are the guard on that list.
@Suite("User profile decode")
struct UserProfileDecodeTests {

    private func decode(_ json: String) throws -> User {
        try #require(
            try? JSONDecoder().decode(UserProfileDTO.self, from: Data(json.utf8))
        ).domain
    }

    /// A response with the cosmetics on the nested user object, which is where
    /// Discord puts the ones that are not per-guild.
    private let styled = """
    {
      "user": {
        "id": "80351110225439422",
        "username": "calmrider",
        "global_name": "CalmRider",
        "discriminator": "0",
        "display_name_styles": {
          "font_id": 12,
          "effect_id": 8,
          "colors": [15378901, 11132400, 12167150, 12184267]
        },
        "collectibles": {
          "nameplate": { "asset": "nameplates/dark_roses/1/", "palette": "cobalt" }
        }
      },
      "user_profile": { "bio": "shipping it" },
      "premium_type": 2
    }
    """

    /// **The id is 8, and this fixture used to say 6.** It was written from
    /// the enum rather than from a capture, and the enum's ids were a guess —
    /// so the test agreed with the bug and kept agreeing with it. The four
    /// colours were always the tell: Gummy is the only effect that takes four,
    /// and `corvin.har` carries exactly `{"font_id": 4, "effect_id": 8, "colors":
    /// [4 values]}` for an account visibly wearing it.
    @Test("A styled display name survives the profile load")
    func displayNameStyleSurvives() throws {
        let user = try decode(styled)
        let style = try #require(user.decoration?.displayNameStyle)
        #expect(style.font == .tempo)
        #expect(style.effect == .gummy)
        #expect(style.colors == [0xEA_A9_D5, 0xA9_DD_F0, 0xB9_A7_EE, 0xB9_EA_CB])
    }

    @Test("Effect 6 is Glow, which the picker never offers and accounts still wear")
    func glowDecodes() throws {
        let user = try decode(
            styled.replacingOccurrences(of: "\"effect_id\": 8", with: "\"effect_id\": 6")
        )
        let style = try #require(user.decoration?.displayNameStyle)
        #expect(style.effect == .glow)
    }

    /// `1001…1004` are Discord's `TEST_1…TEST_4` and every one of them falls
    /// back to Solid — which is what the decoder already does with any id it
    /// does not know, and what Gummy was wrongly getting.
    @Test("An unknown effect keeps the colours and drops the effect")
    func unknownEffectFallsBack() throws {
        let user = try decode(
            styled.replacingOccurrences(of: "\"effect_id\": 8", with: "\"effect_id\": 1002")
        )
        let style = try #require(user.decoration?.displayNameStyle)
        #expect(style.effect == .solid)
        #expect(style.colors.count == 4)
    }

    /// The other cosmetics on the same list, so a future edit that rebuilds this
    /// initialiser cannot quietly drop one of them either.
    @Test("So does everything else carried off the nested user")
    func siblingCosmeticsSurvive() throws {
        let user = try decode(styled)
        let decoration = try #require(user.decoration)
        #expect(decoration.nameplate?.palette == .cobalt)
        #expect(decoration.bio == "shipping it")
        #expect(decoration.premiumTier == .nitro)
    }

    /// The save sends this list back with one kind swapped, so it has to be
    /// each layer's own — a server's never stands in for the account's.
    @Test("Each layer keeps its own worn collectibles")
    func wornCollectiblesPerLayer() throws {
        let json = """
        { "user": { "id": "1", "username": "a", "discriminator": "0" },
          "user_profile": { "collectibles": [
              { "sku_id": "10", "type": 1 }, { "sku_id": "11", "type": 3 } ] },
          "guild_member_profile": { "pronouns": "they/them" } }
        """
        let dto = try JSONDecoder().decode(UserProfileDTO.self, from: Data(json.utf8))
        #expect(dto.domain.decoration?.wornCollectibles == [
            WornCollectible(skuID: "10", kind: .profileEffect),
            WornCollectible(skuID: "11", kind: .profileFrame),
        ])
        // The server's layer said nothing about collectibles: nil, not the
        // account's list.
        #expect(dto.guildDomain?.decoration?.wornCollectibles == nil)
        // The frame is still drawn through from the account's layer.
        #expect(dto.guildDomain?.decoration?.profileFrameSKU == "11")
    }

    /// Alex, 2026-10-26: "server profiles don't show the member's pronouns".
    /// Discord sends the server layer's text fields as `""` when the member
    /// set nothing there, and the account's own show through.
    @Test("An empty server pronoun or bio shows the account's; a set one wins")
    func serverTextFallsBack() throws {
        func decode(_ guildLayer: String) throws -> UserProfileDTO {
            let json = """
            { "user": { "id": "1", "username": "a", "discriminator": "0" },
              "user_profile": { "pronouns": "she/her", "bio": "account bio" },
              "guild_member_profile": \(guildLayer) }
            """
            return try JSONDecoder().decode(UserProfileDTO.self, from: Data(json.utf8))
        }
        let unset = try decode(#"{ "guild_id": "9", "pronouns": "", "bio": "" }"#)
        #expect(unset.guildDomain?.decoration?.pronouns == "she/her")
        #expect(unset.guildDomain?.decoration?.bio == "account bio")
        let set = try decode(#"{ "guild_id": "9", "pronouns": "they/them", "bio": "server bio" }"#)
        #expect(set.guildDomain?.decoration?.pronouns == "they/them")
        #expect(set.guildDomain?.decoration?.bio == "server bio")
        // The account's own layer is untouched by either.
        #expect(set.domain.decoration?.pronouns == "she/her")
    }

    /// Absent is not the same as malformed. An account with no style must decode
    /// to nil rather than to a style that draws nothing.
    @Test("A profile with no style decodes to none")
    func noStyleIsNil() throws {
        let user = try decode("""
        { "user": { "id": "1", "username": "plain", "discriminator": "0" } }
        """)
        #expect(user.decoration?.displayNameStyle == nil)
    }

    /// Discord's own save path writes `[]` for Solid at the default colour, and
    /// the pair `{font, solid, []}` is a real style meaning "styled font,
    /// default colour" — while `{default, solid, []}` is indistinguishable from
    /// no style at all and is stored as nothing.
    @Test("Empty colours are kept for a styled face and dropped for the default")
    func emptyColoursDependOnTheFace() throws {
        let styledFace = try decode("""
        { "user": { "id": "1", "username": "a", "discriminator": "0",
          "display_name_styles": { "font_id": 8, "effect_id": 1, "colors": [] } } }
        """)
        let style = try #require(styledFace.decoration?.displayNameStyle)
        #expect(style.font == .eightBit)
        #expect(style.colors.isEmpty)

        let plain = try decode("""
        { "user": { "id": "1", "username": "a", "discriminator": "0",
          "display_name_styles": { "font_id": 1, "effect_id": 1, "colors": [] } } }
        """)
        #expect(plain.decoration?.displayNameStyle == nil)
    }

    /// Discord adds fonts and effects, and four ids in its own range are already
    /// unassigned. An id this build does not know costs the face, or the effect
    /// — never the whole style, and never the decode.
    @Test("Unknown ids degrade rather than throwing")
    func unknownIdsDegrade() throws {
        let user = try decode("""
        { "user": { "id": "1", "username": "a", "discriminator": "0",
          "display_name_styles": { "font_id": 99, "effect_id": 42, "colors": [16711680] } } }
        """)
        let style = try #require(user.decoration?.displayNameStyle)
        // The face falls back, and the colour they chose is still painted.
        #expect(style.font == .default)
        #expect(style.effect == .solid)
        #expect(style.colors == [0xFF_00_00])
    }

    /// **One boolean in one service's metadata cost a whole profile**, and the
    /// symptom was nowhere near the cause: a mini profile drew a single badge,
    /// no bio and no Nitro crest, because the response it all arrives in threw
    /// on `connected_accounts[9].metadata.verified` and the card fell back to
    /// what the gateway's user object alone can say.
    ///
    /// The bag is `[String: String]` for every service that was ever captured —
    /// PayPal and Twitter both send `"verified": "0"` — and TikTok sends a JSON
    /// boolean for the same key. Taken from a live popout response.
    @Test("A boolean in a connection's metadata does not cost the profile")
    func metadataTolerates() throws {
        let user = try decode("""
        { "user": { "id": "1", "username": "a", "discriminator": "0" },
          "premium_type": 2,
          "badges": [{ "id": "hypesquad_house_3", "description": "HypeSquad Balance",
                       "icon": "3aa41de486fa12454c3761e8e223442e" },
                     { "id": "quest_completed", "description": "Completed a Quest",
                       "icon": "cbe5d371909a84f9ee59a037e8a9cf8b" }],
          "connected_accounts": [
            { "id": "p", "type": "paypal", "name": "p", "verified": true,
              "metadata": { "verified": "0", "created_at": "2019-07-11T00:00:00+00:00" } },
            { "id": "t", "type": "tiktok", "name": "t", "verified": true,
              "metadata": { "verified": false, "follower_count": "84" } } ] }
        """)
        // The badges and the tier are the fields the throw was actually
        // costing, and they are in a different part of the response entirely.
        #expect(user.decoration?.badges.map(\.id) == ["hypesquad_house_3", "quest_completed"])
        #expect(user.decoration?.premiumTier == .nitro)
        // A boolean renders the way the same field arrives from the services
        // that send it as a string, so `ConnectionFact` reads one flag rule.
        let tiktok = try #require(user.decoration?.connectedAccounts.first { $0.service == "tiktok" })
        #expect(tiktok.metadata["verified"] == "0")
        #expect(tiktok.metadata["follower_count"] == "84")
    }

    /// A number arrives as a number on nothing captured so far, and the point of
    /// the tolerant decoder is that it does not have to.
    @Test("A number renders without a decimal point, and null is dropped")
    func metadataRendersScalars() throws {
        let user = try decode("""
        { "user": { "id": "1", "username": "a", "discriminator": "0" },
          "connected_accounts": [
            { "id": "s", "type": "steam", "name": "s",
              "metadata": { "game_count": 16, "ratio": 1.5, "missing": null } } ] }
        """)
        let steam = try #require(user.decoration?.connectedAccounts.first)
        #expect(steam.metadata["game_count"] == "16")
        #expect(steam.metadata["ratio"] == "1.5")
        #expect(steam.metadata["missing"] == nil)
    }

}
