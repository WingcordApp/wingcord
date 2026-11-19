import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore
@testable import WingcordNet

/// The Void (docs/QUEUE-NOV19.md §2): who it is offered to, what a throw may
/// do, and the badge's levels read from its milestones.
@MainActor
@Suite("The Void")
struct OrbVoidTests {
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = UserID(rawValue: 7)
        return model
    }

    @Test("A throw needs the Void open, an Orb left and room in the batch")
    func canThrow() {
        let model = model()
        #expect(!model.canThrowOrb)
        model.orbVoid.status = OrbVoidStatus(balance: 2, totalBurned: 0, isEligible: true, maxBatchQuantity: 1)
        #expect(model.canThrowOrb)
        model.orbVoid.pending = 1
        #expect(!model.canThrowOrb)
        #expect(model.orbVoidBalance == 1)
        #expect(model.orbVoidTotal == 1)
        model.orbVoid.pending = 0
        model.orbVoid.status?.isEligible = false
        #expect(!model.canThrowOrb)
    }

    @Test("Offered by Discord's assignment or the preview")
    func gate() async {
        let model = model()
        await withAppSettings(\.showsOrbVoid) { settings in
            settings.showsOrbVoid = false
            #expect(!model.offersOrbVoid)
            settings.showsOrbVoid = true
            #expect(model.offersOrbVoid)
        }
    }

    @Test("The badge's levels come from its milestones, in order")
    func levels() {
        let model = model()
        let me = UserID(rawValue: 7)
        model.badgeCatalogs[me] = [CatalogBadge(
            badgeID: BadgeKind.orbVoid.rawValue,
            name: "The Void",
            isOwned: true,
            tiers: [
                BadgeTier(key: "2", name: "Stardust", milestoneText: "500 Orbs"),
                BadgeTier(key: "1", name: "Eclipse", milestoneText: "1 Orb"),
                BadgeTier(key: "3", name: "Meteorite", milestoneText: "1,000 Orbs"),
            ]
        )]
        #expect(model.orbVoidLevels.map(\.threshold) == [1, 500, 1_000])
        #expect(model.orbVoidLevels.first?.tier.name == "Eclipse")
    }
}
