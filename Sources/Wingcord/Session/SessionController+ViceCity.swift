import Foundation
import WingcordCore
import WingcordNet

// MARK: - Joining the Vice City campaign before wearing its font

extension SessionController {

    /// Joins Discord's Vice City campaign unless the account already has, and
    /// waits — up to ten seconds, as Discord's own client does — for the perk
    /// to reach the account before the font is written (`471865`'s `Br`).
    /// Discord saves after the wait whether or not the perk showed; so does
    /// this.
    func enrollInViceCityCampaignIfNeeded() async throws {
        guard !LaunchOptions.current.usesDemoFixtures,
              model.entitlements.perks?.hasCampaignDisplayNameStyle != true
        else { return }
        do {
            try await rest.enrollInViceCityCampaign()
        } catch {
            Self.trace("vice city: enroll failed: \(Self.describe(error))")
            throw ViceCityFailure.enroll
        }
        for _ in 0 ..< 40 {
            if model.entitlements.perks?.hasCampaignDisplayNameStyle == true { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let synced = model.entitlements.perks?.hasCampaignDisplayNameStyle == true
        Self.trace("vice city: enrolled, perk \(synced ? "on the account" : "not seen within 10 s")")
    }

    enum ViceCityFailure: LocalizedError {
        case enroll

        var errorDescription: String? {
            "Discord didn\u{2019}t let this account join the Vice City event, so the font wasn\u{2019}t saved."
        }
    }
}
