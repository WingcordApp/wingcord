import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The reader's own nameplate, on the one surface that is always on screen.
///
/// **A plate colours the whole capsule, not its trailing third.** The bar's
/// glass is tinted with the palette and the artwork sits over it, which is what
/// Discord's own bar does and what this one did not — it drew the strip alone
/// and stayed neutral everywhere the strip is transparent.
/// **Serialized**, because one of these flips a preference on the shared
/// `AppSettings` and the rest read the projection that consults it. Run in
/// parallel they race for it, and the failure would be intermittent.
@MainActor
@Suite("The now bar's plate", .serialized)
struct NowBarPlateTests {

    private let me = UserID(rawValue: 1)

    private func model(nameplate: Nameplate?) -> AppModel {
        let model = AppModel()
        model.currentUserID = me
        model.users[me] = User(
            id: me,
            username: "alex",
            decoration: nameplate.map { UserDecoration(nameplate: $0) }
        )
        return model
    }

    private static let darkRoses = Nameplate(
        asset: "nameplates/dark_roses/1526656194121568256/", palette: .cobalt
    )

    /// The strip's width in the bar, which is the one line in
    /// `NowBarPlate.artWidth` — a plate is fitted to its HEIGHT and hung off the
    /// trailing edge, never fitted to the width.
    private static var artWidth: CGFloat {
        (Metrics.nowBarHeight * Nameplate.artworkAspect).rounded()
    }

    /// The capsule's own width at a given channel-column width: the bar carries
    /// `Spacing.base` of margin at each end.
    private static func barWidth(column: CGFloat) -> CGFloat {
        column - 2 * Spacing.base
    }

    @Test("Which end of the strip overflows depends on the column's width")
    func theStripOverflowsOnlyOnANarrowColumn() {
        // Two independent constants decide this and neither knows about the
        // other, so it is worth saying out loud. At the sidebar's narrow and
        // ideal widths the 245-point strip is wider than the bar and the clip
        // takes its leading, transparent end; dragged wide, the bar outgrows
        // the strip and there is bare bar beside it.
        //
        // **Both cases have to look right, and that is the whole argument for
        // putting the colour in the material.** A wash drawn under the artwork
        // can only cover the second case by guessing how much bar there is; a
        // tint covers the capsule whatever width the reader chose.
        #expect(Self.artWidth > Self.barWidth(column: Proportions.channelColumnMin))
        #expect(Self.artWidth > Self.barWidth(column: Proportions.channelColumnIdeal))
        #expect(Self.artWidth < Self.barWidth(column: Proportions.channelColumnMax))
    }

    @Test("The strip keeps its own proportions in the bar")
    func fitsToTheBarsHeight() {
        // Fitted to the height: a 46-point bar draws the 672x126 strip 245
        // points wide. Fitting it to the *width* instead is the defect
        // `NameplateLayoutTests` records on the roster, and it decodes the
        // asset at a tenth of the size it is drawn at.
        #expect(abs(Self.artWidth / Metrics.nowBarHeight - Nameplate.artworkAspect) < 0.02)
    }

    @Test("A reader with no plate leaves the bar its own colour")
    func noPlateNoColour() {
        let bar = model(nameplate: nil).nowBarPresentation
        #expect(bar.nameplateURL == nil)
        // `.none` is what sends `NowBar.tint` back to `Palette.selectionFill`.
        // A fallback hue here would paint a colour on somebody who owns none.
        #expect(bar.nameplatePalette == .none)
        #expect(bar.nameplatePalette.colorValue == nil)
    }

    @Test("A plate carries its artwork and its colour together")
    func plateCarriesBoth() {
        let bar = model(nameplate: Self.darkRoses).nowBarPresentation
        #expect(bar.nameplateURL == Self.darkRoses.artworkURL)
        #expect(bar.nameplateAnimatedURL == Self.darkRoses.animatedArtworkURL)
        #expect(bar.nameplatePalette == .cobalt)
    }

    @Test("Switching the plate off in Settings takes its colour with it")
    func thePreferenceDropsTheColourToo() {
        // The regression this exists for. The two URLs were gated on the
        // preference and the palette was read unconditionally, which was
        // harmless only while nothing but the artwork drew it — the bar's
        // material now takes the colour, so a reader who switched the plate off
        // would have lost the picture and kept a violet capsule.
        AppSettings.shared.showsNameplateInNowBar = false
        defer { AppSettings.shared.showsNameplateInNowBar = true }

        let bar = model(nameplate: Self.darkRoses).nowBarPresentation
        #expect(bar.nameplateURL == nil)
        #expect(bar.nameplateAnimatedURL == nil)
        #expect(bar.nameplatePalette == .none)
    }
}
