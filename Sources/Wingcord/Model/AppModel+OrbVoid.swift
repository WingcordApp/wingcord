import Foundation
import WingcordCore
import WingcordNet

/// The Void's screen (`2026-10-orb-void`, docs/QUEUE-NOV19.md §2).
struct OrbVoidState {
    var isOpen = false
    var status: OrbVoidStatus?
    var loadFailed = false
    /// Throws not yet sent, and throws sent and not yet answered.
    var pending = 0
    var inFlight = 0
    /// Discord refused a batch for good; nothing more is sent this time.
    var isRejected = false
    var isTermsShown = false
}

extension AppModel {
    /// Discord's assignment (variant 1), or the reader's preview.
    var offersOrbVoid: Bool {
        if AppSettings.shared.showsOrbVoid { return true }
        let hash = MurmurHash3.hash32("2026-10-orb-void")
        return experiments.apexReader[hash]?.variantID == 1
    }

    /// From the badge's Enter The Void: the profile goes, the Void comes, as
    /// Discord pops its modals first.
    func openOrbVoid() {
        profileRequest = nil
        orbVoid.isOpen = true
        orbVoid.isRejected = false
        sessionController.loadOrbVoid()
        if let me = currentUserID { loadBadgeCatalog(of: me, force: true) }
    }

    /// The balance less what is on its way.
    var orbVoidBalance: Int? {
        orbVoid.status.map { max(0, $0.balance - orbVoid.pending - orbVoid.inFlight) }
    }

    /// Everything thrown, counting what is on its way.
    var orbVoidTotal: Int? {
        orbVoid.status.map { $0.totalBurned + orbVoid.pending + orbVoid.inFlight }
    }

    /// The Void badge's levels, by the number of Orbs each takes.
    var orbVoidLevels: [(tier: BadgeTier, threshold: Int)] {
        guard let me = currentUserID,
              let badge = badgeCatalogs[me]?.first(where: { $0.badgeID == BadgeKind.orbVoid.rawValue })
        else { return [] }
        return badge.tiers.compactMap { tier in
            guard let text = tier.milestoneText,
                  let number = Int(text.filter(\.isNumber))
            else { return nil }
            return (tier, number)
        }
        .sorted { $0.threshold < $1.threshold }
    }

    /// Whether one more throw may go: the Void open, Orbs left, and room in the
    /// batch Discord takes (`OrbVoidStore.canSpend`).
    var canThrowOrb: Bool {
        guard let status = orbVoid.status, status.isEligible, !orbVoid.isRejected,
              let balance = orbVoidBalance, balance >= 1
        else { return false }
        return orbVoid.pending + 1 <= max(1, status.maxBatchQuantity)
    }
}
