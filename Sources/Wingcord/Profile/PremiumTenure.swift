import Foundation

/// The eight Nitro tenure badges, and everything drawn for one.
///
/// **A table read out of Discord's bundle, not assembled from screenshots.**
/// The ids, the month thresholds and the glow are the `tN` map in `web.*.js`; the
/// artwork paths are module `425713`, which is the only place the two are joined.
/// See `HANDOFF.md` for how to fetch that bundle — it is public and greppable, and
/// everything here was read rather than fitted.
///
/// **The badge these belong to arrives already named.** `GET /users/{id}/profile`
/// sends `{"id": "premium_tenure_3_month_v2", "description": "Earned 5/24/26.
/// 3 months: Silver", "icon": …}`, so the id is the whole lookup and nothing has
/// to be inferred from the description — which is a sentence Discord is free to
/// rewrite, and which a locale other than English writes differently.
///
/// The names are English because this client has no localisation; Discord keeps
/// them behind message ids and they are the same eight words in the modal it
/// draws them in.
nonisolated struct PremiumTenure: Identifiable, Hashable, Sendable {
    /// Discord's badge id, and the key everything else is found by.
    let id: String
    /// "Silver". What the modal's grid labels each tier with.
    let name: String
    /// "Nitro Silver". What the flyout puts above the date, in caps.
    let nitroName: String
    /// How long it takes. Drawn as Discord writes it rather than derived: the
    /// last tier is "6+ Years" for 72 months, which no arithmetic produces.
    let requirement: String
    /// The colour the small badge glows under the pointer —
    /// `drop-shadow(0 0 5px …)` in Discord, and a `.shadow` here.
    let glow: UInt32
    /// The large artwork, which is an **SVG**, and drawn edge to edge. `ImageStore` grew a branch for
    /// that: `CGImageSource` cannot open one at all, and everything Discord
    /// draws large under `/assets/` is in this format.
    let artworkURL: URL?

    /// The eight, in the order the modal lays them out.
    static let all: [PremiumTenure] = [
        Self(1, "Bronze", "1 Month", 0xB5_49_13, "242f4d0069d97414"),
        Self(3, "Silver", "3 Months", 0x9E_9E_9E, "a28ccbd2a55e8413"),
        Self(6, "Gold", "6 Months", 0xFF_A8_13, "45bb84c5fd852085"),
        Self(12, "Platinum", "1 Year", 0x5E_AC_C2, "d343a0b3439e81d1"),
        Self(24, "Diamond", "2 Years", 0x6D_5C_F2, "bb018f1613e8d528"),
        Self(36, "Emerald", "3 Years", 0x32_C1_02, "11a893d07ab86fe4"),
        Self(60, "Ruby", "5 Years", 0xF2_9C_C3, "2801bd9ef48c1d87"),
        Self(72, "Opal", "6+ Years", 0x07_82_92, "c20bd44dcc3b5ecb"),
    ]

    /// The widest authored aspect across the eight — Opal, at 104x69.
    ///
    /// **They share a HEIGHT and grow sideways.** Every drawing from Gold up is
    /// 69 tall; the width goes 68, 69, 78, 84, 99, 104 as the ornaments and
    /// wings appear. Anything that decodes or frames these by a single "side"
    /// squashes the top four, which is what Discord's own
    /// `height: 75px; width: auto` avoids.
    static let widestAspect: CGFloat = 104.0 / 69.0

    /// The tier a badge id names, or nil for a badge that is not one of these.
    static func named(_ badgeID: String) -> PremiumTenure? {
        all.first { $0.id == badgeID }
    }

    /// Whether any of these is worth drawing for this account at all.
    static func isTenure(_ badgeID: String) -> Bool { named(badgeID) != nil }

    private init(
        _ months: Int,
        _ name: String,
        _ requirement: String,
        _ glow: UInt32,
        _ asset: String
    ) {
        self.id = "premium_tenure_\(months)_month_v2"
        self.name = name
        self.nitroName = "Nitro \(name)"
        self.requirement = requirement
        self.glow = glow
        self.artworkURL = URL(string: "https://discord.com/assets/\(asset).svg")
    }

    /// "Subscriber since 5/24/26", which is what the card draws under the name —
    /// **not** the badge's own `description`. Discord writes that one as "Earned
    /// 5/24/26. 3 months: Silver", which is the accessibility label and says the
    /// tier twice on a card that already names it.
    ///
    /// **American whatever this Mac's region is**, for the reason the names are
    /// English: it stands in for the directory's own `info_label` until that
    /// arrives, and must read the same or the line changes under the pointer.
    func subscriberLine(since date: Date?) -> String? {
        guard let date else { return nil }
        let style = Date.FormatStyle(locale: Locale(identifier: "en_US"))
            .month(.defaultDigits).day().year(.twoDigits)
        return "Subscriber since \(date.formatted(style))"
    }
}

/// Which tenure badge's page is open, and whose.
///
/// The date rides along rather than being looked up again by the presenter: the
/// page is raised from a row that already has the profile in hand, and a second
/// lookup is a second answer that can disagree with the badge the reader
/// clicked.
struct TenureBadgeRequest: Equatable, Identifiable {
    var tenure: PremiumTenure
    var premiumSince: Date?

    var id: String { tenure.id }
}
