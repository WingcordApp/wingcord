import Foundation
import Testing
@testable import Wingcord

/// Coloured names drawn straight on a wallpaper are checked against the
/// picture, not the theme (REDESIGN.md Phase 7: a red role read low on Aurora).
@Suite("Names on a wallpaper")
struct NameGroundTests {
    @Test("A bright picture in a dark room is capped dark, so names lighten rather than flip")
    func brightPictureDarkRoom() {
        let ground = WallpaperFrost.nameGround(
            levels: FrostLevels(brightest: 0.9, darkest: 0.05), veil: 0.25, isLight: false
        )
        #expect(InkContrast.luminance(ground) <= 0.125)
        // Admin pink, which read at 1.3:1 on Aurora, now reads.
        let pink = InkContrast.legible(0xE91E63, on: ground)
        #expect(InkContrast.ratio(pink, ground) >= InkContrast.textMinimum)
        #expect(InkContrast.luminance(pink) > InkContrast.luminance(0xE91E63))
    }

    @Test("A dark picture is its own veiled brightest patch")
    func darkPicture() {
        let ground = WallpaperFrost.nameGround(
            levels: FrostLevels(brightest: 0.02, darkest: 0.0), veil: 0.25, isLight: false
        )
        #expect(InkContrast.luminance(ground) < 0.02)
    }

    @Test("A light room floors the darkest patch light")
    func lightRoom() {
        let ground = WallpaperFrost.nameGround(
            levels: FrostLevels(brightest: 0.9, darkest: 0.01), veil: 0.25, isLight: true
        )
        #expect(InkContrast.luminance(ground) >= 0.34)
    }
}
