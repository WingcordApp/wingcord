import AppKit
import Foundation
import WingcordCore

// MARK: - Badges in `--demo`
//
// docs/CLIPS-PRESENCE.md, Phase 8. The reader's directory, so the row's cards,
// the directory and "Customize your badges" can be looked at without an
// account: Streaming part way from Breakout to Standout, Account Age at
// Sequoia, Game Time part way to Serious, Nitro at Gold, and three still to
// earn. The levels' names are the ones in Alex's screenshots; the artwork is
// drawn here from system symbols — Discord's own is never copied in.

enum DemoBadges {

    static func populate(_ model: AppModel, me: UserID) {
        func tiers(_ names: [(String, String)], symbol: String, colour: NSColor) -> [BadgeTier] {
            names.enumerated().map { index, entry in
                let shade = colour.blended(withFraction: CGFloat(index) / CGFloat(max(names.count, 1)) * 0.5, of: .white) ?? colour
                let url = icon(symbol, colour: shade, name: "\(symbol)-\(index)")
                return BadgeTier(
                    key: entry.0.lowercased(), name: entry.0, milestoneText: entry.1,
                    simpleIconURL: url, complexIconURL: url,
                    rarity: index >= names.count - 1 ? .mythic : index >= names.count / 2 ? .epic : .rare
                )
            }
        }
        let now = Date.now
        let streaming = tiers(
            [("Newcomer", "1 hour"), ("Fledgling", "5 hours"), ("Breakout", "20 hours"), ("Standout", "75 hours")],
            symbol: "display", colour: NSColor(srgbRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)
        )
        let gameTime = tiers(
            [("Casual", "1 hour"), ("Recreational", "5 hours"), ("Dedicated", "20 hours"), ("Committed", "75 hours"),
             ("Serious", "150 hours"), ("Devoted", "300 hours"), ("Seasoned", "500 hours"), ("Ironclad", "1,000 hours")],
            symbol: "bolt.fill", colour: NSColor(srgbRed: 0.85, green: 0.35, blue: 0.85, alpha: 1)
        )
        let nitro = tiers(
            [("Starter", ""), ("Bronze", "1 month"), ("Silver", "3 months"), ("Gold", "6 months"),
             ("Platinum", "1 year"), ("Diamond", "2 years"), ("Emerald", "3 years"), ("Ruby", "5 years")],
            symbol: "seal.fill", colour: NSColor(srgbRed: 0.95, green: 0.3, blue: 0.45, alpha: 1)
        )
        // The booster's nine as the directory sends them: keys and
        // milestones, and no names — which is what drew "LEVEL_1".
        let booster = ["1 month", "2 months", "3 months", "6 months", "9 months", "12 months", "15 months",
                       "18 months", "24+ months"].enumerated().map { index, milestone in
            let url = icon(
                "diamond.fill",
                colour: NSColor(srgbRed: 0.96, green: 0.5, blue: 1, alpha: 1).blended(withFraction: CGFloat(index) / 16, of: .white) ?? .systemPink,
                name: "booster-\(index)"
            )
            return BadgeTier(key: "LEVEL_\(index + 1)", name: nil, milestoneText: milestone, simpleIconURL: url, complexIconURL: url)
        }
        let ageIcon = icon("tree.fill", colour: NSColor(srgbRed: 0.6, green: 0.4, blue: 0.95, alpha: 1), name: "age")
        let catalog: [CatalogBadge] = [
            CatalogBadge(
                badgeID: BadgeKind.streaming.rawValue, name: "Streaming",
                description: "Stream more hours to other users to level up this badge.",
                isOwned: true, currentTierKey: "breakout", nextTierKey: "standout", tiers: streaming,
                progress: (23, 75), tierObtainedAt: ["breakout": now.addingTimeInterval(-84 * 86_400)],
                infoLabel: "23 hours streamed to others"
            ),
            CatalogBadge(
                badgeID: BadgeKind.accountAge.rawValue, name: "Account Age",
                description: "Badges that grow with your account.",
                isOwned: true, currentTierKey: "sequoia",
                tiers: [BadgeTier(key: "sequoia", name: "Sequoia", simpleIconURL: ageIcon, complexIconURL: ageIcon, rarity: .mythic)],
                obtainedAt: now.addingTimeInterval(-30 * 86_400), infoLabel: "7 years, 9 months"
            ),
            CatalogBadge(
                badgeID: BadgeKind.gameTime.rawValue, name: "Game Time",
                description: "Play 1 hour of detectable PC games with Discord open to unlock this badge.",
                isOwned: true, currentTierKey: "committed", nextTierKey: "serious", tiers: gameTime,
                progress: (92, 150), tierObtainedAt: ["committed": now.addingTimeInterval(-12 * 86_400)],
                infoLabel: "92 hours of games played"
            ),
            CatalogBadge(
                badgeID: BadgeKind.premiumTenure.rawValue, name: "Nitro",
                description: "Subscribe to Nitro to unlock this badge.",
                isOwned: true, currentTierKey: "gold", nextTierKey: "platinum", tiers: nitro,
                progress: (7, 12), tierObtainedAt: ["gold": now.addingTimeInterval(-40 * 86_400)],
                infoLabel: "Subscriber since 3/2/26"
            ),
            CatalogBadge(
                badgeID: BadgeKind.guildBooster.rawValue, name: "Server Booster",
                description: "Boost a server to unlock this badge.",
                isOwned: true, currentTierKey: "LEVEL_3", nextTierKey: "LEVEL_4", tiers: booster,
                tierObtainedAt: ["LEVEL_3": now.addingTimeInterval(-20 * 86_400)],
                infoLabel: "Server boosting since 7/27/26"
            ),
            CatalogBadge(
                badgeID: BadgeKind.gameVariety.rawValue, name: "Game Variety",
                description: "Play different games with Discord open to unlock this badge.",
                isOwned: false, isEarnable: true,
                simpleIconURL: icon("gamecontroller.fill", colour: .systemTeal, name: "variety")
            ),
            CatalogBadge(
                badgeID: BadgeKind.gifting.rawValue, name: "Gifting",
                description: "Gift Nitro to a friend to unlock this badge.", isOwned: false, isEarnable: true,
                simpleIconURL: icon("gift.fill", colour: .systemBlue, name: "gift")
            ),
            CatalogBadge(
                badgeID: BadgeKind.questCompleted.rawValue, name: "Quests",
                description: "Complete a Quest to unlock this badge.", isOwned: false, isEarnable: true,
                simpleIconURL: icon("flag.checkered", colour: .systemGray, name: "quest")
            ),
        ]
        model.badgeCatalogs[me] = catalog

        // The profile names them as the route does, so the row draws them.
        guard let user = model.users[me] else { return }
        var badged = user
        badged.decoration = UserDecoration(badges: [
            AccountBadge(id: "premium_tenure_6_month_v2", iconHash: nil, label: "Subscriber since Mar 2, 2026"),
            AccountBadge(id: "streaming", iconHash: nil, label: "Streaming"),
            AccountBadge(id: "account_age", iconHash: nil, label: "Account Age"),
            AccountBadge(id: "game_time", iconHash: nil, label: "Game Time"),
            AccountBadge(id: "guild_booster_lvl3", iconHash: nil, label: "Server boosting since Jul 27, 2026"),
        ])
        model.users[me] = badged.merged(over: user)
    }

    /// A system symbol drawn on a tinted disc, as a file — written once.
    private static func icon(_ symbol: String, colour: NSColor, name: String) -> URL? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wingcord Demo Badges", isDirectory: true)
        let file = folder.appendingPathComponent("\(name).png")
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let side: CGFloat = 128
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            colour.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        try? png.write(to: file)
        return file
    }
}
