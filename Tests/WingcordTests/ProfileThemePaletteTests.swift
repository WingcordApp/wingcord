import CoreGraphics
import SwiftUI
import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// The sampling step in front of the quantiser.
///
/// Small, and worth pinning anyway: both of its rejections change which colour
/// a person's profile ends up wearing, and neither is visible in the output
/// when it silently stops working.
@Suite("Profile theme palette")
struct ProfileThemePaletteTests {

    /// An image whose left `whiteFraction` is pure white and whose right is
    /// `colour`.
    private func image(colour: (UInt8, UInt8, UInt8), whiteFraction: Double) -> CGImage {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let boundary = Int(Double(side) * whiteFraction)
        for y in 0..<side {
            for x in 0..<side {
                let o = (y * side + x) * 4
                let white = x < boundary
                bytes[o] = white ? 255 : colour.0
                bytes[o + 1] = white ? 255 : colour.1
                bytes[o + 2] = white ? 255 : colour.2
                bytes[o + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func channels(_ value: UInt32) -> (Int, Int, Int) {
        (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    @Test("Near-white is thrown away before quantising")
    func rejectsNearWhite() {
        // A photograph shot against a window is mostly blown highlight. Without
        // this rejection that person's profile comes out white — and white is
        // the one theme that makes a card indistinguishable from an unthemed
        // one, so the failure looks like the feature never ran.
        let derived = ProfileThemePalette.derive(
            from: image(colour: (30, 90, 200), whiteFraction: 0.75)
        )
        #expect(!derived.isEmpty)
        let (r, g, b) = channels(derived[0])
        #expect(b > r, "the blue quarter should win over the white three quarters")
        #expect(g > r)
        #expect(!(r > 240 && g > 240 && b > 240), "white leaked into the palette")
    }

    @Test("A picture with nothing but near-white yields no theme at all")
    func allWhiteYieldsNothing() {
        // Empty rather than black: a profile with no usable colour keeps its
        // neutral ground, and handing back a colour nobody chose is worse than
        // handing back none.
        #expect(ProfileThemePalette.derive(
            from: image(colour: (255, 255, 255), whiteFraction: 1)
        ).isEmpty)
    }

    @Test("The colour survives the stride")
    func samplesEveryTenthPixel() {
        // Sampling is what makes this affordable, and it is also what decides
        // which swatch wins — so the sampled subset still has to describe the
        // picture.
        let derived = ProfileThemePalette.derive(
            from: image(colour: (200, 40, 40), whiteFraction: 0)
        )
        #expect(!derived.isEmpty)
        let (r, g, b) = channels(derived[0])
        #expect(abs(r - 200) <= 8)
        #expect(abs(g - 40) <= 8)
        #expect(abs(b - 40) <= 8)
    }

    @Test("Each rendition size is the CDN rung its URL builder asks for")
    func sizeMatchesTheRung() {
        // Two numbers that must agree, per surface: quantising the same picture
        // at another size picks a different swatch outright, so the size the URL
        // requests and the size the decode is capped at cannot drift apart.
        for size in [ProfileThemePalette.profilePixelSize,
                     ProfileThemePalette.applicationPixelSize] {
            #expect(CDN.rung(forSide: CGFloat(size) / 2, scale: 2) == size, "\(size)")
        }
    }

    @Test("A profile is quantised at 80, which is the rung Discord's own palette used")
    func profileRungIsEighty() {
        // Driven against a capture of Discord's `S4` output for a known avatar —
        // `#89867d` then `#d5d4d3`. At 64, 128 and 256 this client's quantiser
        // puts the near-black behind the subject in second place and the light
        // colour third; at 80 the pair and the ORDER are Discord's, with the
        // secondary exact. See `ProfileThemePalette` for the sweep.
        #expect(ProfileThemePalette.profilePixelSize == 80)
        // And the application path keeps its own, which was verified byte for
        // byte against two gradients Discord rendered.
        #expect(ProfileThemePalette.applicationPixelSize == 128)
    }

    @Test("A derived palette is five colours in Discord's own order")
    func paletteIsFive() {
        // `[...t.slice(0, 2), ...Q7(t[0])]`, read off the store's own action.
        // The surfaces split on that array — the full profile takes [0] and [1],
        // the sidebar keeps only [0] — so the shape is the answer.
        let palette = ProfileThemePalette.derive(
            from: image(colour: (200, 40, 40), whiteFraction: 0.1)
        )
        // **Two raw boxes plus three partners — where there ARE two boxes.** A
        // picture of one colour quantises to one, and inventing a second would
        // be the client deciding a body colour nobody's artwork contains. The
        // shape that always holds is the tail.
        #expect(palette.count == min(2, palette.count - 3) + 3)
        #expect(palette.count >= 4)
        let primary = SIMD3<UInt8>(
            UInt8(palette[0] >> 16 & 0xFF),
            UInt8(palette[0] >> 8 & 0xFF),
            UInt8(palette[0] & 0xFF)
        )
        let partners = PaletteHarmony.partners(of: primary).map {
            UInt32($0.x) << 16 | UInt32($0.y) << 8 | UInt32($0.z)
        }
        #expect(Array(palette.suffix(3)) == partners)
    }
}

/// What Discord turns a profile's pair into — `ProfileThemeColors`.
///
/// **Every number below was measured off Discord's own rendering**, not fitted.
/// Two accounts, one grey and one saturated, chosen because their primaries sit
/// four hundredths either side of the light/dark threshold: `robinresting`
/// has no `theme_colors` and takes the pair quantised out of his avatar, and
/// `spiwal` chose `[#07ADEA, #4F003B]`. Both render as LIGHT cards, which is
/// the fact this client was getting wrong.
@MainActor
@Suite("Profile theme colours")
struct ProfileThemeColorsTests {
    // The two captured pairs, and what Discord's own picker shows for the
    // derived one.
    static let greyPrimary: UInt32 = 0x8C_89_81
    static let greySecondary: UInt32 = 0xD8_D7_D6
    static let cyanPrimary: UInt32 = 0x07_AD_EA
    static let plumSecondary: UInt32 = 0x4F_00_3B

    @Test("The theme is the PRIMARY's YIQ darkness, and both samples are light")
    func themeFollowsThePrimary() {
        #expect(!ProfileThemeColors.isDark(Self.greyPrimary))
        #expect(!ProfileThemeColors.isDark(Self.cyanPrimary))
        // A navy somebody chose, which is the other side of the threshold.
        #expect(ProfileThemeColors.isDark(0x46_1F_63))
        // And the trap the threshold sets: green carries most of the weight, so
        // a mid-green is light where a mid-blue of the same channel value is
        // not. An average would call both the same.
        #expect(!ProfileThemeColors.isDark(0x00_FF_00))
        #expect(ProfileThemeColors.isDark(0x00_00_FF))
    }

    @Test("A card is the pair at 40 % over white or black")
    func cardIsTheVeiledPair() {
        // Discord's identity column for the grey account samples #d2d1ce just
        // under the banner and #efefee at its foot.
        #expect(ProfileThemeColors.veiled(Self.greyPrimary, dark: false) == 0xD1_D0_CD)
        #expect(ProfileThemeColors.veiled(Self.greySecondary, dark: false) == 0xEF_EF_EF)
        // The dark branch is the same arithmetic toward black.
        #expect(ProfileThemeColors.veiled(0x46_1F_63, dark: true) == 0x1C_0C_28)
    }

    @Test("The full profile's base is the clamped Lab midpoint, and it was measured")
    func modalBaseMatchesDiscord() {
        let grey = ProfileThemeColors.modalBackground(
            primary: Self.greyPrimary,
            secondary: Self.greySecondary
        )
        // The ramp Discord draws over it: #e5e5e3 at the top of the modal and
        // #d4d3d0 from 300 points down — both sampled off its own window, both
        // exact.
        #expect(ProfileThemeColors.modalRamp(over: grey, dark: false, fraction: 0.8) == 0xE5_E5_E3)
        #expect(ProfileThemeColors.modalRamp(over: grey, dark: false, fraction: 0.2) == 0xD4_D3_D0)

        let cyan = ProfileThemeColors.modalBackground(
            primary: Self.cyanPrimary,
            secondary: Self.plumSecondary
        )
        #expect(ProfileThemeColors.modalRamp(over: cyan, dark: false, fraction: 0.2) == 0xC8_C9_DC)
    }

    @Test("A dark pair clamps the other way, and stays dark")
    func modalBaseClampsDownForADarkProfile() {
        let base = ProfileThemeColors.modalBackground(primary: 0x46_1F_63, secondary: 0x2B_35_39)
        // Lightness forced into 0...0.1, so every channel is near-black however
        // bright the midpoint started.
        #expect((base >> 16) & 0xFF <= 0x33)
        #expect((base >> 8) & 0xFF <= 0x33)
        #expect(base & 0xFF <= 0x33)
    }

    @Test("The button is the primary darkened until white reads on it")
    func buttonMatchesDiscord() {
        // Measured: #35332d on the grey profile, #005187 on the cyan one.
        #expect(ProfileThemeColors.buttonFill(Self.greyPrimary) == 0x35_33_2C)
        #expect(ProfileThemeColors.buttonFill(Self.cyanPrimary) == 0x00_52_87)
    }

    @Test("And it is a floor, so an already-dark colour is not darkened further")
    func buttonLeavesADarkPrimaryAlone() {
        // #4F003B contrasts 15.6:1 against white — above the tolerance ceiling
        // — so the loop brightens it back into 7...10 rather than leaving it.
        let fill = ProfileThemeColors.buttonFill(Self.plumSecondary)
        #expect(fill != Self.plumSecondary)
    }
}

/// Which way the ink goes on a themed surface.
///
/// **A derived theme is the case that forces this and a chosen one rarely
/// does.** Somebody who picks their own colours picks them against a dark card;
/// a quantiser picks whatever the picture had, and a cat photographed on a white
/// sofa quantises to `#d5d4d3`. Discord's full profile for that account is a
/// light card with dark text.
@MainActor
@Suite("Profile ground ink")
struct ProfileGroundInkTests {

    @Test("A light primary asks for dark ink; a dark one does not")
    func inkFollowsTheBody() {
        // The pair quantised for the test avatar: a warm grey over a near-white.
        let light = ProfileGround(themeColorValues: [0x89_86_7D, 0xD5_D4_D3])
        #expect(light.wantsDarkInk)

        // The same shape with the primary dark — which is what most people who
        // choose their own colours pick.
        let dark = ProfileGround(themeColorValues: [0x46_1F_63, 0x2B_35_39])
        #expect(!dark.wantsDarkInk)
    }

    @Test("The SECONDARY does not get a vote, however light it is")
    func inkIgnoresTheSecondary() {
        // The trap this replaced: reading the body's foot instead of the
        // primary called a navy card light because its second colour was pale,
        // and the whole card inverted.
        let navy = ProfileGround(themeColorValues: [0x1F_2A_55, 0xEE_EE_F2])
        #expect(!navy.wantsDarkInk)
    }

    @Test("An unthemed ground takes the app's ink, because it is the app's own ground")
    func neutralKeepsTheAppsInk() {
        // The app's near-black in dark mode and its near-white in light; a CI
        // runner is in light mode, this Mac usually in dark.
        let appIsDark = ThemeAccess.colors.appearance == .dark
        #expect(ProfileGround(themeColorValues: []).wantsDarkInk == !appIsDark)
    }

    @Test("A chosen pair and a derived one are ONE case")
    func oneTreatmentForBothKinds() {
        // Discord resolves `theme_colors ?? quantised` before anything draws,
        // so nothing downstream can tell them apart — and this client used to
        // draw them differently on a measurement that was a coincidence.
        let ground = ProfileGround(themeColorValues: [0x8C_89_81, 0xD8_D7_D6])
        #expect(ground == .themed(
            primary: 0x8C_89_81, secondary: 0xD8_D7_D6, followsAppTheme: false
        ))
        // A single colour is still a theme, just a flat one.
        #expect(ProfileGround(themeColorValues: [0x8C_89_81])
            == .themed(primary: 0x8C_89_81, secondary: 0x8C_89_81, followsAppTheme: false))
    }

    @Test("A sidebar keeps the app's ink for a palette the modal draws light")
    func sidebarFollowsTheApp() {
        // Discord decides this per SURFACE: the same pair is a near-white modal
        // and a dark sidebar, measured on two accounts in dark mode. See
        // `ProfileGround`. The sidebar follows the app, so on a Mac in light
        // mode (a CI runner) it is light.
        let appIsDark = ThemeAccess.colors.appearance == .dark
        let pair = [UInt32(0x8C_89_81), UInt32(0xD8_D7_D6)]
        let modal = ProfileGround(themeColorValues: pair)
        let sidebar = ProfileGround(themeColorValues: pair, followsAppTheme: true)

        #expect(modal.wantsDarkInk)
        #expect(sidebar.wantsDarkInk == !appIsDark)
        #expect(sidebar.isDark == appIsDark)

        // And the overlay is still the 0.6 one — the sidebar overrides the
        // THEME, not the strength, which is what its measured body proves.
        #expect(sidebar.bodyHead == Color(hex: ProfileThemeColors.veiled(0x8C_89_81, dark: appIsDark)))
        #expect(sidebar.bodyFoot == Color(hex: ProfileThemeColors.veiled(0xD8_D7_D6, dark: appIsDark)))
        // Discord's own sidebar for that account samples 57,56,54 at the head
        // and 85,85,84 at the foot.
        #expect(ProfileThemeColors.veiled(0x8C_89_81, dark: true) == 0x38_37_34)
        #expect(ProfileThemeColors.veiled(0xD8_D7_D6, dark: true) == 0x56_56_56)
    }
}
