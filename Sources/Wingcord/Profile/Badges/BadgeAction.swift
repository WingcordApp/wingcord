import AppKit
import WingcordCore

/// The button under a badge in the directory, as Discord's (`c9beb9de` `em`):
/// where to go to earn it or to use it. **Only where it goes somewhere** — a
/// page of this app's, or Discord's own page for what this app has none of.
struct BadgeAction {
    var title: String
    var symbol: String
    var perform: @MainActor (AppModel) -> Void

    @MainActor
    init?(badge: CatalogBadge, isOwn: Bool, model: AppModel) {
        func web(_ title: String, _ symbol: String, _ address: String) -> BadgeAction? {
            guard let url = URL(string: address) else { return nil }
            return BadgeAction(title: title, symbol: symbol) { _ in NSWorkspace.shared.open(url) }
        }
        let action: BadgeAction?
        switch badge.kind {
        case .orbVoid:
            // Only where the Void is open to this account (Discord's
            // `badge_directory_enter_void_cta`).
            guard model.offersOrbVoid else { return nil }
            action = BadgeAction(title: "Enter The Void", symbol: "circle.dotted.circle") { $0.openOrbVoid() }
        case .staff:
            action = web("Work With Us", "briefcase", "https://discord.com/careers")
        case .premiumTenure:
            action = web(badge.isOwned ? "Nitro Home" : "Get Nitro", "sparkles", "https://discord.com/nitro")
        case .guildBooster:
            action = web(badge.isOwned ? "Manage Boosts" : "Boost a server", "diamond", "https://discord.com/nitro")
        case .orbProfile:
            action = web("Orbs Shop", "bag", "https://discord.com/shop#itemSkuId=orbs")
        case .questCompleted:
            action = web("Quests Home", "scope", "https://discord.com/quest-home")
        case .gifting:
            action = web("Send Gift", "gift", "https://discord.com/nitro")
        default:
            action = nil
        }
        guard let action else { return nil }
        self = action
    }

    private init(title: String, symbol: String, perform: @escaping @MainActor (AppModel) -> Void) {
        self.title = title
        self.symbol = symbol
        self.perform = perform
    }
}
