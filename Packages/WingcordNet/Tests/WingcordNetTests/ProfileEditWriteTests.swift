import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The two partial updates the profile editor sends.
///
/// **These bodies cannot be checked by reading them.** Both routes treat an
/// absent key and a null key as opposite instructions — leave it alone, take it
/// away — so the whole correctness of a save is in which keys are *not* there,
/// and that is invisible in the source of an `Encodable` whose fields all look
/// present. The failure mode is a reader who changed their bio and lost their
/// banner.
@Suite("Profile edit writes")
struct ProfileEditWriteTests {

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
    }

    // MARK: The three states

    @Test("An untouched field is absent from the request entirely")
    func unchangedSendsNothing() throws {
        let body = try json(
            CurrentUserPatch(global_name: .set("alex"))
        )
        #expect(body["global_name"] as? String == "alex")
        // Every other key was left alone, so the request is one key long.
        #expect(body.keys.sorted() == ["global_name"])
    }

    /// `.cleared` is the *only* way to take a banner off, and it has to arrive
    /// as an explicit `null` rather than as a missing key.
    @Test("A cleared field is sent as null, not omitted")
    func clearedSendsNull() throws {
        let body = try json(CurrentUserPatch(avatar: .cleared))
        #expect(body.keys.sorted() == ["avatar"])
        #expect(body["avatar"] is NSNull)
    }

    @Test("An image is sent as a data URI, prefix and all")
    func imageIsADataURI() throws {
        let image = ImageData(mimeType: "image/png", bytes: Data([0x1, 0x2, 0x3]))
        let body = try json(CurrentUserPatch(avatar: .set(image.dataURI)))
        #expect(body["avatar"] as? String == "data:image/png;base64,AQID")
    }

    // MARK: The display name style

    /// **One `FieldEdit`, three keys.** A style whose font was sent without its
    /// effect is a half-applied style, and clearing has to take all three off
    /// together or the account keeps a font nothing selected.
    @Test("A display name style is three flat keys, and clears as three nulls")
    func displayNameStyleFansOut() throws {
        let set = try json(
            CurrentUserPatch(
                style: .set(
                    DisplayNameStyleWrite(fontID: 8, effectID: 7, colors: [16_683_586, 3_534_206])
                )
            )
        )
        #expect(set["display_name_font_id"] as? Int == 8)
        #expect(set["display_name_effect_id"] as? Int == 7)
        #expect((set["display_name_colors"] as? [Int])?.count == 2)
        #expect(set["display_name_colors"] as? [Int] == [16_683_586, 3_534_206])
        #expect(set["display_name_styles"] == nil)

        let cleared = try json(CurrentUserPatch(style: .cleared))
        #expect(cleared.keys.sorted() == [
            "display_name_colors", "display_name_effect_id", "display_name_font_id",
        ])
        #expect(cleared["display_name_font_id"] is NSNull)
    }

    /// **The unofficial documentation says two and the wire says five.** A
    /// Prism display name captured on a live account carries five colours, so a
    /// write type that truncated to the documented ceiling would flatten every
    /// effect above a gradient into a gradient.
    @Test("A style keeps every colour its effect takes")
    func styleColoursAreNotTruncated() throws {
        let prism = [16_683_586, 3_534_206, 16_769_095, 16_731_346, 5_793_266]
        let style = DisplayNameStyleWrite(fontID: 8, effectID: 7, colors: prism)
        #expect(style.colors == prism)

        let body = try json(CurrentUserPatch(style: .set(style)))
        #expect((body["display_name_colors"] as? [Int])?.count == 5)
    }

    // MARK: The profile half

    @Test("The profile patch carries only its own fields")
    func profilePatchIsPartial() throws {
        let body = try json(
            ProfilePatch(bio: .set("hello"), pronouns: .cleared)
        )
        #expect(body.keys.sorted() == ["bio", "pronouns"])
        #expect(body["bio"] as? String == "hello")
        #expect(body["pronouns"] is NSNull)
    }

    @Test("Theme colours travel as a pair of integers")
    func themeColours() throws {
        let body = try json(ProfilePatch(theme_colors: .set([0x46_1F_63, 0x7A_2A_5C])))
        #expect(body["theme_colors"] as? [Int] == [0x46_1F_63, 0x7A_2A_5C])
    }

    // MARK: Dirt

    @Test("Only a touched field reports itself dirty")
    func dirt() {
        #expect(FieldEdit<String>.unchanged.isDirty == false)
        #expect(FieldEdit<String>.cleared.isDirty)
        #expect(FieldEdit.set("x").isDirty)
    }

    // MARK: The owned cosmetics

    /// **The purchases list is not a list of cosmetics.** Captured, it carries
    /// an "Orbs Apprentice Badge" as `type: 3000` with **no `items` key at
    /// all** — so a decoder that assumed a known type would draw a badge in the
    /// nameplate grid, and one that assumed an item was present would fail the
    /// whole list and leave every picker empty.
    @Test("A product that is not a cosmetic is dropped, not fatal")
    func purchasesTolerateOtherProducts() throws {
        let json = """
        [
          {"sku_id":"1417311919664005231","name":"Cosmic Storm","type":2,"premium_type":0,
           "purchased_at":"2025-10-02T19:33:11.184910+00:00",
           "items":[{"type":2,"asset":"nameplates/nameplate_bonanza/cosmic_storm/",
                     "label":"Purple and pink nebula clouds.","palette":"violet"}]},
          {"sku_id":"1144059132517826601","name":"Smoke","type":0,"premium_type":2,
           "purchased_at":"2025-09-05T00:00:00.000000+00:00",
           "items":[{"type":0,"asset":"a_10b9f886b513b77ccdd67c8784f1a496",
                     "label":"Smoke with Green Shining Border, Animated"}]},
          {"sku_id":"1391000000000000000","name":"Orbs Apprentice Badge","type":3000,
           "premium_type":0,"purchased_at":"2025-07-14T00:00:00.000000+00:00"}
        ]
        """
        let owned = try JSONDecoder()
            .decode([CollectiblePurchaseDTO].self, from: Data(json.utf8))
            .compactMap(\.domain)

        #expect(owned.count == 2)
        let nameplate = try #require(owned.first { $0.kind == .nameplate })
        #expect(nameplate.name == "Cosmic Storm")
        #expect(nameplate.asset.hasSuffix("/"))
        #expect(nameplate.palette == "violet")
        #expect(nameplate.isNitroExclusive == false)

        // A decoration's asset is a bare hash, not a path — the two shapes are
        // not interchangeable and the picker addresses them differently.
        let decoration = try #require(owned.first { $0.kind == .avatarDecoration })
        #expect(decoration.asset == "a_10b9f886b513b77ccdd67c8784f1a496")
        #expect(decoration.palette == nil)
        #expect(decoration.isNitroExclusive)
    }
}
