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
          "effect_id": 6,
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

    @Test("A styled display name survives the profile load")
    func displayNameStyleSurvives() throws {
        let user = try decode(styled)
        let style = try #require(user.decoration?.displayNameStyle)
        #expect(style.font == .tempo)
        #expect(style.effect == .gummy)
        #expect(style.colors == [0xEA_A9_D5, 0xA9_DD_F0, 0xB9_A7_EE, 0xB9_EA_CB])
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
}
