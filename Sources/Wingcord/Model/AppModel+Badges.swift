import Foundation
import WingcordCore
import WingcordNet

// MARK: - Badges, levelled
//
// docs/CLIPS-PRESENCE.md, Phase 8. Discord's badge directory, per person:
// fetched the first time their badges are looked at closely (a badge's card,
// the directory), kept for the session, fetched again when the profile's own
// badge count stops matching what the directory says they own — Discord's
// drift check.

extension AppModel {

    /// Whether Discord lets this account hide and order its badges —
    /// `2026-08-badge-management`, and whether Nitro's own can be hidden.
    var badgeManagement: (enabled: Bool, tenureHideable: Bool) {
        let hash = MurmurHash3.hash32("2026-08-badge-management")
        guard let variant = experiments.apex.first(where: { $0.hash == hash })?.variantID else {
            return (false, false)
        }
        switch variant {
        case 1: return (true, true)
        case 2: return (true, false)
        default: return (false, false)
        }
    }

    /// Asks for `userID`'s directory once, or again when told to.
    func loadBadgeCatalog(of userID: UserID, force: Bool = false) {
        guard !LaunchOptions.current.usesDemoFixtures else { return }
        guard force || badgeCatalogs[userID] == nil, !badgeCatalogRequests.contains(userID) else { return }
        badgeCatalogRequests.insert(userID)
        let rest = sessionController.rest
        let who = userID == currentUserID ? nil : userID
        Task { [weak self] in
            defer { self?.badgeCatalogRequests.remove(userID) }
            do {
                let badges = try await rest.badgeCatalog(of: who)
                self?.badgeCatalogs[userID] = badges
            } catch {
                Breadcrumbs.record("badges: catalog failed")
            }
        }
    }

    /// The directory's entry for a badge on the profile, by the profile's id.
    func catalogBadge(forProfileBadge id: String, of userID: UserID) -> CatalogBadge? {
        guard let kind = BadgeKind.forProfileID(id) else { return nil }
        return badgeCatalogs[userID]?.first { $0.badgeID == kind.rawValue }
    }

    /// Hides or shows one of the reader's badges — optimistic, put back if
    /// Discord refuses.
    func setBadgeHidden(_ badgeID: Int, hidden: Bool) {
        guard let me = currentUserID, var badges = badgeCatalogs[me],
              let index = badges.firstIndex(where: { $0.badgeID == badgeID })
        else { return }
        let previous = badges
        badges[index].isHidden = hidden
        badgeCatalogs[me] = badges
        writeBadgeSettings(badges, restoring: previous, sendsOrder: false)
    }

    /// Orders the reader's shown badges — Nitro's.
    func setBadgeOrder(_ order: [Int]) {
        guard let me = currentUserID, let badges = badgeCatalogs[me] else { return }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let sorted = badges.sorted { (rank[$0.badgeID] ?? .max) < (rank[$1.badgeID] ?? .max) }
        badgeCatalogs[me] = sorted
        writeBadgeSettings(sorted, restoring: badges, sendsOrder: true)
    }

    private func writeBadgeSettings(_ badges: [CatalogBadge], restoring previous: [CatalogBadge], sendsOrder: Bool) {
        guard let me = currentUserID else { return }
        // `--demo` asks Discord nothing; the change stays on screen.
        guard !LaunchOptions.current.usesDemoFixtures else { return }
        let management = badgeManagement
        let arrangement = badges.arrangement(tenureHideable: management.tenureHideable)
        let hidden = arrangement.hidden.map(\.badgeID)
        let order = sendsOrder ? arrangement.ordered.map(\.badgeID) : nil
        let rest = sessionController.rest
        Task { [weak self] in
            do {
                try await rest.setBadgeSettings(displayOrder: order, hiddenBadges: hidden)
                // The profile's row is the server's to settle.
                self?.sessionController.loadProfile(of: me, inGuild: nil)
            } catch {
                self?.badgeCatalogs[me] = previous
                self?.reportActionFailure("Couldn't change your badges. \(error.localizedDescription)")
            }
        }
    }
}
