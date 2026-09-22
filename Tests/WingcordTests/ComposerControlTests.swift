import Foundation
import Testing
@testable import Wingcord

/// The composer's trailing controls: the order they sit in, and the geometry
/// they sit in.
///
/// **The order is read back out of `UserDefaults`, so the normalising is the
/// feature.** Every one of the tests below is a shape of stored value a later
/// build can produce — a control removed, a control added, a list written twice
/// by a racing write — and each of them, unnormalised, is a `ForEach` over
/// duplicate ids, a control nobody can reach, or a crash.
@Suite("Composer controls")
struct ComposerControlTests {

    // MARK: The order

    @Test("Every control appears exactly once, whatever was stored")
    func normalises() {
        // A build that removed one: the missing case is appended rather than
        // leaving the reader a control they cannot reach.
        #expect(ComposerControlOrder([.emoji]).controls == [.emoji, .gif, .sticker, .apps])
        // A duplicate keeps its FIRST position, because that is the one the
        // reader dragged it to.
        #expect(
            ComposerControlOrder([.apps, .gif, .apps]).controls
                == [.apps, .gif, .sticker, .emoji]
        )
        #expect(ComposerControlOrder([]).controls == ComposerControl.allCases)
    }

    @Test("A name from a build this one does not know is dropped, not folded")
    func unknownNamesAreDropped() {
        let order = ComposerControlOrder(storage: ["emoji", "soundboard", "gif"])
        // Not mapped onto a case it is not — which would put the reader's emoji
        // control where a control they have never seen used to be.
        #expect(order.controls == [.emoji, .gif, .sticker, .apps])
    }

    @Test("The stored form round-trips")
    func storageRoundTrips() {
        let order = ComposerControlOrder([.apps, .emoji, .gif, .sticker])
        #expect(ComposerControlOrder(storage: order.storage) == order)
        // A `[String]`, which `UserDefaults` holds natively — no JSON round trip
        // on a value written on every drag.
        #expect(order.storage == ["apps", "emoji", "gif", "sticker"])
    }

    // MARK: One drag

    @Test("A control moves in front of the one it was dropped on")
    func movesBefore() {
        var order = ComposerControlOrder.default
        order.move([.apps], before: .gif)
        #expect(order.controls == [.apps, .gif, .sticker, .emoji])
    }

    @Test("A nil destination is the end of the row")
    func movesToEnd() {
        var order = ComposerControlOrder.default
        order.move([.gif], before: nil)
        #expect(order.controls == [.sticker, .emoji, .apps, .gif])
    }

    @Test("Dropping a control on itself changes nothing")
    func selfMoveIsInert() {
        // Not merely cosmetic: lifted first and re-inserted by index, this is a
        // move to an index that has just shifted by one.
        var order = ComposerControlOrder.default
        order.move([.sticker], before: .sticker)
        #expect(order.controls == ComposerControl.allCases)
    }

    @Test("Several controls keep their own order when moved together")
    func multiMoveKeepsRelativeOrder() {
        var order = ComposerControlOrder.default
        order.move([.gif, .emoji], before: .apps)
        #expect(order.controls == [.sticker, .gif, .emoji, .apps])
    }

    // MARK: The geometry

    @Test("A control fits inside the bar rather than setting its height")
    func controlFitsTheBar() {
        // The defect this pins: a control the height of the bar has no air
        // around it, and one taller than the bar makes the bar taller than the
        // field it is built from.
        #expect(Metrics.composerControl < Metrics.composerControlHeight)
        #expect(Metrics.composerControlInset > 0)
        #expect(
            Metrics.composerControl + 2 * Metrics.composerControlInset
                == Metrics.composerControlHeight
        )
    }

    @Test("A control is bigger than the compact circles in the now bar")
    func biggerThanTheOldOne() {
        // The whole of the complaint: these were `compactControl`, which is the
        // size of a control cut into a 46-point identity capsule and far too
        // small for the one thing the reader reaches for while typing.
        #expect(Metrics.composerControl > Metrics.compactControl)
    }

    // MARK: The silhouette

    @Test("Only the boxy bar encloses the controls that flank it")
    func onlyBoxyEncloses() {
        #expect(ChromeShape.boxy.enclosesFlankingControls)
        #expect(!ChromeShape.pill.enclosesFlankingControls)
    }

    @Test("A pill's corner is half its height, which is why it cannot enclose")
    func theRuleFollowsTheCorner() {
        // The two answers have to agree: a shape whose corner is half its
        // height has circular ends, and an enclosed circle collides with them.
        let height = Metrics.composerControlHeight
        #expect(ChromeShape.pill.cornerRadius(forHeight: height) == height / 2)
        #expect(ChromeShape.boxy.cornerRadius(forHeight: height) < height / 2)
    }
}

/// The one preference behind both floating bars.
///
/// **Serialized and on its own defaults**, because these write to a suite and
/// read it back; run in parallel against `.standard` they would fight each other
/// and the reader's real settings.
@MainActor
@Suite("Chrome shape preference", .serialized)
struct ChromeShapeSettingTests {

    private func defaults(_ seed: [String: Any] = [:]) -> UserDefaults {
        let suite = UserDefaults(suiteName: "wingcord.tests.\(UUID().uuidString)")!
        for (key, value) in seed { suite.set(value, forKey: key) }
        return suite
    }

    @Test("A reader who never chose gets the house shape")
    func defaultsToBoxy() {
        #expect(AppSettings(defaults: defaults()).chromeShape == .boxy)
    }

    @Test("The composer's old preference becomes the shared one")
    func migratesFromTheComposersKey() {
        // The two bars had a preference each. Whichever the reader set on the
        // composer is the one they were looking at while choosing, so it is the
        // answer they meant — and losing it would silently reset a window they
        // had shaped.
        let settings = AppSettings(defaults: defaults(["appearance.composerShape": "pill"]))
        #expect(settings.chromeShape == .pill)
    }

    @Test("The shared preference wins once it exists")
    func theNewKeyWins() {
        let settings = AppSettings(defaults: defaults([
            "appearance.chromeShape": "boxy",
            "appearance.composerShape": "pill",
        ]))
        #expect(settings.chromeShape == .boxy)
    }

    @Test("The control order survives a relaunch")
    func theOrderPersists() {
        let suite = defaults()
        let settings = AppSettings(defaults: suite)
        settings.composerControls = ComposerControlOrder([.emoji, .apps, .gif, .sticker])
        #expect(AppSettings(defaults: suite).composerControls.controls
            == [.emoji, .apps, .gif, .sticker])
    }
}
