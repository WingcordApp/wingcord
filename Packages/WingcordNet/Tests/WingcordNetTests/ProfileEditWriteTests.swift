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

    // MARK: The per-server half

    /// Discord's own per-server save (build 643186): the avatar, decoration,
    /// nameplate and name style go to the member route, the nameplate nested.
    @Test("A per-server member patch writes Discord's keys, the nameplate nested")
    func memberPatch() throws {
        let body = try json(
            CurrentMemberPatch(
                avatar: .set("data:image/gif;base64,R0lG"),
                avatar_decoration_sku_id: .set("111"),
                nameplate: .set("222"),
                style: .set(DisplayNameStyleWrite(fontID: 3, effectID: 1, colors: [0xFF0000]))
            )
        )
        #expect(body.keys.sorted() == [
            "avatar", "avatar_decoration_sku_id", "collectibles",
            "display_name_colors", "display_name_effect_id", "display_name_font_id",
        ])
        let collectibles = try #require(body["collectibles"] as? [String: Any])
        let plate = try #require(collectibles["nameplate"] as? [String: Any])
        #expect(plate["sku_id"] as? String == "222")
    }

    @Test("Taking a server's nameplate off writes it as null inside collectibles")
    func memberPatchClearsNameplate() throws {
        let body = try json(CurrentMemberPatch(nameplate: .cleared))
        let collectibles = try #require(body["collectibles"] as? [String: Any])
        #expect(collectibles.keys.sorted() == ["nameplate"])
        #expect(collectibles["nameplate"] is NSNull)
    }

    @Test("An emptied nickname is sent as null, an untouched one not at all")
    func memberPatchNickname() throws {
        let emptied = try json(CurrentMemberPatch(nick: .set("")))
        #expect(emptied["nick"] is NSNull)
        let untouched = try json(CurrentMemberPatch(avatar_id: .set("9")))
        #expect(untouched.keys.sorted() == ["avatar_id"])
    }

    /// What a member wears in one server rides the member object.
    @Test("A member's own decoration, plate and name style decode")
    func memberCosmetics() throws {
        let json = """
        {"user":{"id":"1","username":"a","discriminator":"0"},"nick":"lex","roles":[],
         "avatar_decoration_data":{"asset":"a_deco","sku_id":"5"},
         "collectibles":{"nameplate":{"asset":"nameplates/x/","palette":"cobalt","sku_id":"6"}},
         "display_name_styles":{"font_id":3,"effect_id":1,"colors":[16711680]}}
        """
        let member = try JSONDecoder().decode(MemberDTO.self, from: Data(json.utf8)).domain(userID: UserID(rawValue: 1))
        let worn = try #require(member.cosmetics)
        #expect(worn.avatarDecorationHash == "a_deco")
        #expect(worn.avatarDecorationSKU == "5")
        #expect(worn.nameplate?.skuID == "6")
        #expect(worn.displayNameStyle != nil)
        let plain = try JSONDecoder().decode(MemberDTO.self, from: Data(#"{"user":{"id":"1","username":"a","discriminator":"0"},"roles":[]}"#.utf8))
        #expect(plain.domain(userID: UserID(rawValue: 1)).cosmetics == nil)
    }

    // MARK: Collectibles

    /// Discord sends the profile's whole list back with the edited kind
    /// swapped — so whatever else it carried survives the save.
    @Test("Changing the effect keeps every other worn collectible")
    func collectibleSwapKeepsTheRest() {
        let worn = [
            WornCollectible(skuID: "deco", kind: .avatarDecoration),
            WornCollectible(skuID: "old-effect", kind: .profileEffect),
            WornCollectible(skuID: "frame", kind: .profileFrame),
            WornCollectible(skuID: "unknown", type: 9),
        ]
        let skus = worn.skus(effect: .set("new-effect"), frame: .unchanged)
        #expect(skus == ["deco", "frame", "unknown", "new-effect"])
        let cleared = worn.skus(effect: .unchanged, frame: .cleared)
        #expect(cleared == ["deco", "old-effect", "unknown"])
        #expect(worn.skus(effect: .unchanged, frame: .unchanged) == nil)
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
