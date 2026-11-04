import SwiftUI
import Testing
@testable import Wingcord

/// Discord's rule for a small plate on a light profile, which the tag pill and the
/// note field share. Both were grey slabs on a pale card (Alex's image 52).
@MainActor
@Suite("A plate on a light profile")
struct ProfileLightPlateTests {

    @Test("See-through white over somebody's own colours, stronger while it's active")
    func overATheme() {
        #expect(ProfileLightPlate.fill(wearsTheme: true, isRaised: false) == Color.white.opacity(0.24))
        #expect(ProfileLightPlate.fill(wearsTheme: true, isRaised: true) == Color.white.opacity(0.4))
    }

    @Test("Faint grey on an unthemed card, where white wouldn't show")
    func withoutATheme() {
        #expect(ProfileLightPlate.fill(wearsTheme: false, isRaised: false) == ProfileLightPlate.mod.opacity(0.12))
        #expect(ProfileLightPlate.fill(wearsTheme: false, isRaised: true) == ProfileLightPlate.mod.opacity(0.24))
    }
}
