import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// The bubbles under the two display options that change them: Reduce
/// Transparency (solid, no frost behind) and Increase Contrast (denser, edged).
@Suite("Bubbles and display options")
struct BubbleTintAccessibilityTests {
    private let brightPicture = FrostLevels(brightest: 0.8, darkest: 0.1)

    @Test("Reduce Transparency fills every bubble solid, in both rooms")
    func reduceTransparency() {
        for isLight in [false, true] {
            let tint = BubbleTint.resolve(frost: brightPicture, isLight: isLight, reducesTransparency: true)
            for color in [tint.own, tint.other, tint.badge, tint.ownHover, tint.otherHover] {
                #expect(color.alpha == 1)
            }
        }
    }

    @Test("Increase Contrast thickens the fill and edges every bubble")
    func increaseContrast() {
        let plain = BubbleTint.resolve(frost: brightPicture, isLight: false)
        let firm = BubbleTint.resolve(frost: brightPicture, isLight: false, increasesContrast: true)
        #expect(firm.own.alpha > plain.own.alpha)
        #expect(firm.other.alpha > plain.other.alpha)
        #expect((firm.rim?.alpha ?? 0) > (plain.rim?.alpha ?? 0))
        // On the theme's own ground too, where a bubble otherwise has no edge.
        #expect(BubbleTint.resolve(frost: nil, isLight: true).rim == nil)
        #expect(BubbleTint.resolve(frost: nil, isLight: true, increasesContrast: true).rim != nil)
    }

    @Test("Over a bright picture the smoke is enough for white words")
    func smokeKeepsContrast() {
        let tint = BubbleTint.resolve(frost: FrostLevels(brightest: 1, darkest: 0.5), isLight: false)
        // Black at alpha a over white leaves (1 - a) of it: the words need the
        // patch at or under luminance 0.155 — sRGB ~0.43.
        #expect(1 - tint.own.alpha <= 0.44)
    }
}
