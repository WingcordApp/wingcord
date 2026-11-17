import Foundation

/// The account's `perks` object — which perks it holds and where each came
/// from (Discord's `948325`): `{active_perks_bitmask, config_by_perk:
/// {"2": {source: [4], kind: {…}}}, rules_version}`.
///
/// **One question is asked of it today**: whether the display-name-style
/// perk came from the Vice City campaign (source 4, `SOURCE_HEXAGON_CAMPAIGN`),
/// which is what lets an account without Nitro wear the campaign's font. Its
/// own value beside the tier, for `AccountEntitlements`' reason: only the
/// reader's own objects carry it.
public struct AccountPerks: Hashable, Sendable {
    /// Discord's perk ids (`948325`): 2 is display name styles.
    public static let displayNameStylesPerk = "2"
    /// `SOURCE_HEXAGON_CAMPAIGN`.
    public static let campaignSource = 4

    /// Where each perk came from, by perk id: 1 Nitro, 4 the campaign.
    public var sources: [String: Set<Int>]

    public init(sources: [String: Set<Int>] = [:]) {
        self.sources = sources
    }

    /// Whether the account may wear the Vice City font because it joined the
    /// campaign (`773527`'s `Rd`).
    public var hasCampaignDisplayNameStyle: Bool {
        sources[Self.displayNameStylesPerk]?.contains(Self.campaignSource) == true
    }
}
