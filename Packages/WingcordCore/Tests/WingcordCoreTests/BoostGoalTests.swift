import Testing
@testable import WingcordCore

/// The Boost progress bar's goal, as Discord sums it.
@Suite("Boost goal")
struct BoostGoalTests {

    @Test("Level 3 and every power-up outside the levels")
    func goal() {
        // 14 + 3 + 3 + 3 + 5 + 3 + 2.
        #expect(BoostGoal.goal(features: [], offersThemes: false, offersGameServers: false) == 33)
        #expect(BoostGoal.goal(features: [], offersThemes: true, offersGameServers: true) == 39)
    }

    @Test("A server lifted to level 3 by hand counts only the power-ups")
    func overridden() {
        #expect(BoostGoal.goal(features: ["PREMIUM_TIER_3_OVERRIDE"], offersThemes: false, offersGameServers: false) == 19)
    }
}
