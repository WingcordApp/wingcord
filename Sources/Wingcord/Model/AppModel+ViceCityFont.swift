import Foundation
import WingcordCore

// MARK: - The Vice City font (docs/ACTIVITY-CARDS.md decision 4)
//
// Discord's Grand Theft Auto VI campaign ("Hexagon" in its bundle) offers its
// font — Pricedown, `DisplayNameFont.hexagon` — to every account for a while,
// in a "Limited Time Font" section of the display-name-style editor
// (`f5b687ab`'s `eM`), on these rules (`773527`'s `U5`, `855531`):
//
// - shown while the user experiment `2026-09-hexagon-campaign-client` is on
//   (variants 1 and 2), until 2027-02-20 18:00 UTC;
// - selectable until 2026-12-13 18:00 UTC without Nitro, until 2027-02-20 with
//   Nitro (not Basic) — `DiscordTheme.ViceCity`;
// - worn by joining the campaign first (`SessionController.enrollInViceCityCampaignIfNeeded`).

extension AppModel {
    static let viceCityCampaignExperiment = "2026-09-hexagon-campaign-client"

    /// Whether the editor offers the Vice City font to this account now.
    ///
    /// **The experiment where READY assigned one, the dates where it didn't**:
    /// an account Discord put in the control group doesn't see it, and one
    /// READY said nothing about gets what the campaign's own dates say.
    var offersViceCityFont: Bool {
        let hash = MurmurHash3.hash32(Self.viceCityCampaignExperiment)
        if let variant = experiments.apex.first(where: { $0.hash == hash })?.variantID,
           variant != 1, variant != 2 {
            return false
        }
        return DiscordTheme.ViceCity.isAvailable(to: entitlements.premiumTier)
    }

    /// The line under the tile: until when this account may wear it.
    var viceCityFontTerms: String {
        let style = Date.FormatStyle().month(.wide).day()
        let free = DiscordTheme.ViceCity.freeUntil.formatted(style)
        let nitro = DiscordTheme.ViceCity.nitroUntil.formatted(style)
        return entitlements.premiumTier == .nitro
            ? "Yours with Nitro until \(nitro)."
            : "Free for everyone until \(free), and with Nitro until \(nitro)."
    }
}
