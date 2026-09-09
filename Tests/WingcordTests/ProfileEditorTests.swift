import Foundation
import Testing
import WingcordCore
import WingcordNet
@testable import Wingcord

/// The editor's draft, and what it turns into on the wire.
///
/// **The board's write is where a mistake is expensive.** `PUT
/// /users/@me/widgets` replaces the whole array, so an entry that is wrong does
/// not fail alone — it takes the reader's other widgets with it, or deletes
/// them.
@Suite("Profile editor")
@MainActor
struct ProfileEditorTests {

    private func widget(_ id: String, _ content: ProfileWidget.Content) -> ProfileWidget {
        ProfileWidget(id: id, updatedAt: nil, content: content)
    }

    private func encoded(_ write: ProfileWidgetWrite) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(write)) as? [String: Any]
        )
    }

    /// **The bug this exists for.** A widget the reader has just added needs an
    /// id locally — a `ForEach` and a drag both key off it — and sending that id
    /// is a `400 Invalid Form Body`, because Discord's `widgets[].id` is a
    /// snowflake or absent and never `draft:<uuid>`.
    @Test("A widget added in this session sends no id at all")
    func draftWidgetSendsNoID() throws {
        let draft = widget(ProfileEditor.draftIDPrefix + UUID().uuidString, .playedGames([]))
        let write = try #require(draft.write)
        let object = try encoded(write)
        #expect(object["id"] == nil)
        #expect(object["data"] != nil)
    }

    @Test("A widget that came from Discord keeps its id")
    func savedWidgetKeepsID() throws {
        let saved = widget("1539974257327743066", .currentGames([]))
        let object = try encoded(try #require(saved.write))
        #expect(object["id"] as? String == "1539974257327743066")
    }

    /// A kind this build cannot name has no safe representation on a route that
    /// replaces the whole board — see `ProfileWidget.write`.
    @Test("An unrecognised widget refuses to be written")
    func unknownWidgetIsNotWritable() {
        #expect(widget("1", .unknown("some_future_kind")).write == nil)
    }

    // MARK: Dirt

    private func presentation(displayName: String = "alex") -> ProfilePresentation {
        ProfilePresentation(
            userID: UserID(rawValue: 1),
            displayName: displayName,
            handle: "alexsample",
            monogram: "A",
            status: .online,
            isBot: false,
            badges: [],
            roles: [],
            accountCreated: .distantPast,
            isSelf: true,
            connections: [],
            premiumTier: .none,
            mutualServers: [],
            mutualFriends: [],
            isProfilePrivate: false,
            note: "",
            isLoading: false
        )
    }

    @Test("An untouched draft is not dirty")
    func cleanDraft() {
        let editor = ProfileEditor(profile: presentation(), widgets: [], scope: .account)
        #expect(editor.isDirty == false)
    }

    /// Typing a character and deleting it again has changed nothing, and a save
    /// bar that stays up for it is a bar the reader learns to ignore.
    @Test("A field returned to its original value is clean again")
    func roundTripIsClean() {
        let editor = ProfileEditor(profile: presentation(), widgets: [], scope: .account)
        editor.bio = "hello"
        #expect(editor.isDirty)
        editor.bio = ""
        #expect(editor.isDirty == false)
    }

    @Test("Reordering the board is a change")
    func reorderIsDirty() {
        let widgets = [
            widget("1", .playedGames([])),
            widget("2", .currentGames([])),
        ]
        let editor = ProfileEditor(profile: presentation(), widgets: widgets, scope: .account)
        editor.widgets.reverse()
        #expect(editor.isDirty)
        editor.reset()
        #expect(editor.isDirty == false)
        #expect(editor.widgets.map(\.id) == ["1", "2"])
    }

    // MARK: The style picker's samples

    /// **A sample with the wrong number of colours draws the wrong effect.**
    /// Gummy takes four and Prism five; hand either a single colour and the
    /// tile renders something the reader will never get. The two lists are
    /// declared in different files — `colorCount` in Core, `sampleColors` in the
    /// sheet — so nothing but this stops them drifting apart when an effect is
    /// added.
    @Test("Every effect's sample has exactly the colours that effect takes")
    func effectSamplesMatchTheirCount() {
        for effect in DisplayNameEffect.allCases {
            #expect(
                effect.sampleColors.count == effect.colorCount,
                "\(effect.title) samples \(effect.sampleColors.count) of \(effect.colorCount)"
            )
        }
    }

    /// The one value Discord publishes as CSS rather than only in pixels:
    /// `linear-gradient(to right bottom, rgb(42,174,166) 10%, rgb(255,196,144) 90%)`.
    @Test("Gradient's sample is Discord's published pair")
    func gradientSampleIsExact() {
        #expect(DisplayNameEffect.gradient.sampleColors == [0x2A_AE_A6, 0xFF_C4_90])
    }

    // MARK: The palette presets

    /// **A preset with the wrong number of stops is unselectable and wrong.**
    /// The well binds `colors` to the effect's own count, so a four-colour
    /// preset offered under Prism could never match the selection and would
    /// never show its checkmark — and applying it would leave the style short a
    /// colour.
    @Test("Every preset has exactly the stops its effect takes")
    func presetsMatchTheirCount() {
        for effect in DisplayNameEffect.allCases {
            for preset in effect.presets {
                #expect(
                    preset.count == effect.colorCount,
                    "\(effect.title) preset has \(preset.count) of \(effect.colorCount)"
                )
            }
        }
    }

    /// Discord shows one grid of twelve under all four single-colour effects.
    @Test("Neon, Toon and Pop share Solid's presets")
    func solidEffectsShareOnePalette() {
        let solid = DisplayNameEffect.solid.presets
        #expect(solid.count == 12)
        for effect in [DisplayNameEffect.neon, .toon, .pop] {
            #expect(effect.presets == solid)
        }
    }

    /// The multi-stop sets are the ones that would rot silently — a dropped
    /// entry still compiles and still renders.
    @Test("Each multi-stop effect offers the sets Discord shows")
    func multiStopPresetCounts() {
        #expect(DisplayNameEffect.gradient.presets.count == 8)
        #expect(DisplayNameEffect.gummy.presets.count == 6)
        #expect(DisplayNameEffect.prism.presets.count == 6)
    }

    // MARK: The live preview

    /// **The editor's whole promise.** Every control writes to the draft and
    /// nothing reaches Discord until Save, so a surface drawn from the stored
    /// profile shows the reader none of their own changes.
    @Test("The preview carries the draft, not what is saved")
    func previewFollowsTheDraft() {
        let editor = ProfileEditor(profile: presentation(), widgets: [], scope: .account)
        editor.displayName = "alex1"
        editor.pronouns = "they/them"
        editor.accentColor = 0xFF_00_00

        let shown = editor.applied(to: presentation())
        #expect(shown.displayName == "alex1")
        #expect(shown.pronouns == "they/them")
        #expect(shown.accentColorValue == 0xFF_00_00)
    }

    /// A name cleared in the field is not a nameless profile on screen — the
    /// account's own is what Discord falls back to when the field is sent null.
    @Test("An emptied name falls back rather than drawing nothing")
    func emptiedNameFallsBack() {
        let editor = ProfileEditor(profile: presentation(), widgets: [], scope: .account)
        editor.displayName = ""
        #expect(editor.applied(to: presentation()).displayName == "alex")
    }

    /// Removing the avatar has to be visible, and `nil` is the only way to say
    /// it — which is why `AvatarEdit` has a case for it rather than being an
    /// `ImageData?`.
    @Test("A removed avatar clears the preview's picture")
    func removedAvatarIsVisible() {
        let editor = ProfileEditor(profile: presentation(), widgets: [], scope: .account)
        editor.avatar = .removed
        #expect(editor.applied(to: presentation()).avatarURL == nil)
    }

    // MARK: Cosmetics the profile already wears

    /// **The bug this exists for, twice over.** Both the nameplate's and the
    /// decoration's `sku_id` are on the wire and were decoded past — nothing
    /// that only *draws* a cosmetic needs one — so every picker opened with
    /// "None" selected on an account that was wearing something, and Apply would
    /// have cleared it.
    @Test("The draft starts out wearing what the profile wears")
    func draftSeedsWornCosmetics() {
        var profile = presentation()
        profile.avatarDecorationSKU = "1144059132517826601"
        profile.nameplate = Nameplate(
            asset: "nameplates/nameplate_bonanza/cosmic_storm/",
            palette: .violet,
            label: "Purple and pink nebula clouds.",
            skuID: "1417311919664005231"
        )
        let editor = ProfileEditor(profile: profile, widgets: [], scope: .account)
        #expect(editor.avatarDecorationSKU == "1144059132517826601")
        #expect(editor.nameplate?.skuID == "1417311919664005231")
        // Seeding is not an edit.
        #expect(editor.isDirty == false)
    }

    @Test("Taking a decoration off is a change, and reset puts it back")
    func removingADecorationIsDirty() {
        var profile = presentation()
        profile.avatarDecorationSKU = "1144059132517826601"
        let editor = ProfileEditor(profile: profile, widgets: [], scope: .account)
        editor.avatarDecorationSKU = nil
        #expect(editor.isDirty)
        editor.reset()
        #expect(editor.avatarDecorationSKU == "1144059132517826601")
    }
}
