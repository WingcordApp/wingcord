import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The cosmetics a reader has asked not to see.
///
/// **Every one of these failures is silent.** A filter that missed a field would
/// go on drawing somebody's nameplate for a reader who switched nameplates off,
/// and nothing would say so; a filter that took a field it should not would drop
/// somebody's bio out of their profile card, and nothing would say that either.
/// The point of the suite is that both directions are asserted.
///
/// **Serialized**, because these move preferences on the shared `AppSettings`
/// and the projections read them back.
@MainActor
@Suite("Cosmetic suppression", .serialized)
struct CosmeticSuppressionTests {

    private let me = UserID(rawValue: 1)
    private let them = UserID(rawValue: 2)

    private func decoration() -> UserDecoration {
        UserDecoration(
            avatarDecorationHash: "deco",
            avatarDecorationSKU: "deco-sku",
            nameplate: Nameplate(asset: "nameplates/x/1/", palette: .cobalt),
            displayNameStyle: DisplayNameStyle(font: .sakura, effect: .neon, colors: [0xFF_00_00]),
            bannerHash: "banner",
            accentColor: 0x11_22_33,
            bio: "a bio",
            themeColorValues: [0xAA_BB_CC, 0xDD_EE_FF],
            badges: [],
            profileEffectSKU: "effect",
            profileFrameSKU: "frame",
            pronouns: "they/them",
            premiumTier: .nitro
        )
    }

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.users[me] = User(id: me, username: "alex", decoration: decoration())
        model.users[them] = User(id: them, username: "someone", decoration: decoration())
        return model
    }

    private func withSuppression(
        _ set: CosmeticSuppression,
        own: Bool = false,
        _ body: (AppModel) -> Void
    ) async {
        await withAppSettings(\.suppressedCosmetics, \.suppressesOwnCosmetics) { settings in
            settings.suppressedCosmetics = set
            settings.suppressesOwnCosmetics = own
            body(model())
        }
    }

    // MARK: What goes

    @Test("Each switch removes its own cosmetic and no other")
    func eachSwitchIsIndependent() async {
        await withSuppression(.nameplates) { model in
            let filtered = model.cosmetics(of: model.users[them]!)
            #expect(filtered?.nameplate == nil)
            // Everything else is still there. A filter that took a neighbour
            // would be a switch that hides two things and names one.
            #expect(filtered?.avatarDecorationHash != nil)
            #expect(filtered?.displayNameStyle != nil)
            #expect(filtered?.profileEffectSKU != nil)
            #expect(filtered?.profileFrameSKU != nil)
            #expect(filtered?.themeColorValues != nil)
        }
        await withSuppression(.avatarDecorations) { model in
            let filtered = model.cosmetics(of: model.users[them]!)
            #expect(filtered?.avatarDecorationHash == nil)
            // The SKU goes with the hash: the editor marks the worn one by SKU,
            // and leaving it would tick a decoration that is not being drawn.
            #expect(filtered?.avatarDecorationSKU == nil)
            #expect(filtered?.nameplate != nil)
        }
        await withSuppression(.nameStyles) { model in
            #expect(model.cosmetics(of: model.users[them]!)?.displayNameStyle == nil)
        }
        await withSuppression(.profileEffects) { model in
            #expect(model.cosmetics(of: model.users[them]!)?.profileEffectSKU == nil)
            #expect(model.cosmetics(of: model.users[them]!)?.profileFrameSKU != nil)
        }
        await withSuppression(.profileFrames) { model in
            #expect(model.cosmetics(of: model.users[them]!)?.profileFrameSKU == nil)
            #expect(model.cosmetics(of: model.users[them]!)?.profileEffectSKU != nil)
        }
    }

    // MARK: What stays

    @Test("Nothing that is not a cosmetic is touched")
    func peopleAreNotHidden() async {
        // This hides decoration, not people. A filter that took the bio, the
        // pronouns or the tier with the artwork would be answering a question
        // nobody asked.
        await withSuppression([.nameplates, .avatarDecorations, .nameStyles,
                         .profileEffects, .profileFrames, .profileGradients]) { model in
            let filtered = model.cosmetics(of: model.users[them]!)
            #expect(filtered?.bio == "a bio")
            #expect(filtered?.pronouns == "they/them")
            #expect(filtered?.bannerHash == "banner")
            #expect(filtered?.premiumTier == .nitro)
        }
    }

    @Test("The gradient goes, the legacy accent stays")
    func gradientAndAccentAreTwoThings() async {
        // Two different fields on the wire, and the accent predates the
        // collectible. Taking it with the pair leaves a profile with no colour
        // at all rather than with its plain one.
        await withSuppression(.profileGradients) { model in
            let filtered = model.cosmetics(of: model.users[them]!)
            #expect(filtered?.themeColorValues == nil)
            #expect(filtered?.accentColor == 0x11_22_33)
        }
    }

    // MARK: Whose

    @Test("The reader's own cosmetics are exempt unless they said otherwise")
    func ownCosmeticsAreExempt() async {
        await withSuppression(.nameplates) { model in
            #expect(model.cosmetics(of: model.users[me]!)?.nameplate != nil)
            #expect(model.cosmetics(of: model.users[them]!)?.nameplate == nil)
        }
        await withSuppression(.nameplates, own: true) { model in
            #expect(model.cosmetics(of: model.users[me]!)?.nameplate == nil)
        }
    }

    // MARK: The cost

    @Test("A reader who has switched nothing off pays nothing")
    func theCommonPathAllocatesNothing() {
        // The answer is the object that was already there, not a copy of it.
        // This is asked once per visible row per pass in two canvases.
        let model = model()
        let user = model.users[them]!
        #expect(model.cosmetics(of: user) === user.decoration)
    }

    @Test("The memo notices a changed decoration, not just a changed preference")
    func theMemoKeysOnBothInputs() async {
        // A memo keyed on the person alone goes on serving the filtered copy of
        // a nameplate they have already changed — and a gateway update replaces
        // the whole `UserDecoration`, so there is nothing else to notice it by.
        await withSuppression(.nameplates) { model in
            #expect(model.cosmetics(of: model.users[them]!)?.bio == "a bio")

            model.users[them] = User(
                id: them,
                username: "someone",
                decoration: UserDecoration(
                    nameplate: Nameplate(asset: "nameplates/y/2/", palette: .clover),
                    bio: "a different bio"
                )
            )
            let after = model.cosmetics(of: model.users[them]!)
            #expect(after?.bio == "a different bio")
            #expect(after?.nameplate == nil)
        }
    }
}
