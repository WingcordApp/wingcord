import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// How the two badge sources are merged.
///
/// Discord's own list is taken WHOLE when it is there, and nothing is added to
/// it — a merge drew two Nitro crests, because the same badge arrives from the
/// two sources under different ids AND different assets, so no de-duplication
/// key could catch it. The flag-derived branch only runs when the route sent no
/// list at all, and it now draws Discord's artwork rather than grey symbols.
@MainActor
@Suite("Account badges")
struct AccountBadgeTests {

    private func decoration(
        badges: [AccountBadge] = [],
        premium: PremiumTier = .none,
        premiumSince: Date? = nil,
        legacyUsername: String? = nil
    ) -> UserDecoration {
        UserDecoration(
            badges: badges,
            premiumTier: premium,
            premiumSince: premiumSince,
            legacyUsername: legacyUsername
        )
    }

    @Test("Flag badges carry Discord's own artwork, not a grey symbol")
    func flagBadgesHaveArtwork() throws {
        let resolved = AccountBadges.resolve(
            flags: [.hypesquadBravery, .earlySupporter],
            decoration: nil
        )
        #expect(resolved.count == 2)
        for badge in resolved {
            let url = try #require(badge.iconURL)
            #expect(url.absoluteString.contains("badge-icons"))
        }
    }

    /// Alex, 2026-11-18: "wingcord shows the nitro icon for some profiles
    /// when discord doesnt". Discord draws exactly the route's list, so an
    /// answered `[]` is no badges at all.
    @Test("The profile route's empty list is final: no Nitro, no crests added")
    func answeredEmptyListIsFinal() {
        let answered = UserDecoration(badges: [], badgesFromProfile: true, premiumTier: .nitro)
        #expect(AccountBadges.resolve(flags: [.hypesquadBalance], decoration: answered).isEmpty)
    }

    @Test("An empty named list no longer hides the flag badges")
    func emptyNamedListStillShowsFlags() {
        let resolved = AccountBadges.resolve(
            flags: [.hypesquadBalance],
            decoration: decoration(badges: [])
        )
        #expect(resolved.contains { $0.label == "HypeSquad Balance" })
    }

    /// Discord ships several assets for the same badge — Nitro, Classic, Basic
    /// and every boost tier are different pictures of the same idea, under ids
    /// that also differ. No de-duplication key catches that, which is why the
    /// named list is taken whole and nothing is added to it.
    @Test("Nothing is added to Discord's own list")
    func namedListIsTakenWhole() {
        let named = AccountBadge(
            id: "premium_tenure_24_month",
            iconHash: "some-nitro-asset",
            label: "24. 2 years: Diamond"
        )
        let resolved = AccountBadges.resolve(
            flags: [.hypesquadBravery, .staff],
            decoration: decoration(
                badges: [named],
                premium: .nitro,
                premiumSince: Date(timeIntervalSince1970: 1_700_000_000),
                legacyUsername: "Amily#2022"
            )
        )
        #expect(resolved.count == 1)
        #expect(resolved[0].id == "premium_tenure_24_month")
    }

    /// These two used to be text rows under the mutual-servers line. They are
    /// facts Discord publishes as badges, and they belong on the badge a reader
    /// hovers to ask about them.
    @Test("Nitro and the pre-2023 name become badges carrying their own facts")
    func factsBecomeBadges() throws {
        let since = Date(timeIntervalSince1970: 1_764_547_200)   // 2025-12-01
        let resolved = AccountBadges.resolve(
            flags: [],
            decoration: decoration(
                premium: .nitro,
                premiumSince: since,
                legacyUsername: "Amily#2022"
            )
        )
        let premium = try #require(resolved.first { $0.id == "premium" })
        #expect(premium.label.hasPrefix("Subscriber since"))
        let legacy = try #require(resolved.first { $0.id == "legacy_username" })
        #expect(legacy.label == "Originally Amily#2022")
    }

    @Test("An account with nothing to show shows nothing")
    func empty() {
        #expect(AccountBadges.resolve(flags: [], decoration: nil).isEmpty)
        #expect(AccountBadges.resolve(flags: [], decoration: decoration()).isEmpty)
    }
}
