import Foundation
import WingcordCore

// MARK: - The Boost progress bar
//
// Discord's bar at the top of a server's channels (`35a17d…`'s
// `GuildPowerupsProgressBarUI`): how many boosts the server has against how
// many unlock everything — docs/SHEETS-SETTINGS.md D9.

extension AppModel {

    /// The server half of Discord's Server Theme rollout, a classic server
    /// experiment: treatments 1 and 2 have it, control does not.
    static let serverThemeServerExperiment = "2026-04_server_theme"
    /// The account half — an apex experiment, variant 1.
    static let serverThemeAccountExperiment = "2026-05-server-theme-user"
    /// Game server hosting's server experiment, treatment 1.
    static let gameServersExperiment = "2025-08_portkey_enabled"

    /// The bar's row for a server — nil where the server has the bar switched
    /// off, which is Discord's own rule (`useGuildActionRows`).
    ///
    /// Discord gives the slot first to an owner's onboarding checklist and a
    /// newcomer's to-do bar; this client draws neither, so the bar is never
    /// displaced here.
    func sidebarBoostGoal(for guildID: GuildID) -> SidebarBoostGoal? {
        guard let guild = guilds[guildID], guild.premiumProgressBarEnabled else { return nil }
        let goal = boostGoal(for: guild)
        guard goal > 0 else { return nil }
        return SidebarBoostGoal(
            guildID: guildID,
            count: guild.premiumSubscriptionCount,
            goal: goal,
            level: guild.premiumTier,
            // Discord offers the bar's menu to administrators only (`363487`),
            // though the write itself needs Manage Server.
            canSwitchOff: permissionGate.permissions(inGuild: guildID).contains(.administrator)
        )
    }

    /// Discord's goal for one server: level 3, every power-up outside the
    /// levels, and the two it offers only where their rollouts reach.
    ///
    /// **The theme's rollout has a third half this client cannot read**: a
    /// server outside `2026-04_server_theme` falls back to an apex server
    /// experiment (`2026-06-server-theme-apex-shadow`) whose assignments
    /// Discord fetches per server and READY does not carry. Such a server's
    /// goal here is three short of Discord's.
    func boostGoal(for guild: Guild) -> Int {
        BoostGoal.goal(
            features: guild.features,
            offersThemes: offersServerThemePowerUp(in: guild.id),
            offersGameServers: (guildExperimentBucket(Self.gameServersExperiment, in: guild.id) ?? 0) >= 1
        )
    }

    private func offersServerThemePowerUp(in guildID: GuildID) -> Bool {
        let account = MurmurHash3.hash32(Self.serverThemeAccountExperiment)
        guard experiments.apex.contains(where: { $0.hash == account && $0.variantID == 1 }) else { return false }
        return (guildExperimentBucket(Self.serverThemeServerExperiment, in: guildID) ?? 0) >= 1
    }

    /// Switches a server's bar on or off — Discord's "Enable Progress Bar".
    ///
    /// **Shown at once and put back if Discord refuses**, as a pin is: the
    /// GUILD_UPDATE that follows a write that landed agrees with it.
    func setBoostProgressBar(_ isOn: Bool, in guildID: GuildID) {
        guard var guild = guilds[guildID], guild.premiumProgressBarEnabled != isOn else { return }
        guild.premiumProgressBarEnabled = isOn
        guilds[guildID] = guild
        sidebarRevision &+= 1
        guard !LaunchOptions.current.usesDemoFixtures else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await sessionController.rest.updateBoostPerks(in: guildID, progressBar: isOn)
            } catch {
                guard var current = guilds[guildID] else { return }
                current.premiumProgressBarEnabled = !isOn
                guilds[guildID] = current
                sidebarRevision &+= 1
                reportActionFailure("The Boost progress bar couldn't be changed.")
            }
        }
    }
}

/// The Boost progress bar's row, resolved for drawing.
struct SidebarBoostGoal: Hashable, Sendable {
    var guildID: GuildID
    /// The server's boosts.
    var count: Int
    /// What unlocks everything — `BoostGoal.goal`.
    var goal: Int
    /// The server's level, 0–3.
    var level: Int
    /// Whether the reader is offered the bar's menu.
    var canSwitchOff: Bool

    /// The goal is met — Discord's 🎉.
    var isReached: Bool { count >= goal }

    /// How full the bar is, 0…1.
    var fraction: Double { goal > 0 ? min(Double(count) / Double(goal), 1) : 0 }

    /// Discord's two counts: "9/39 Boosts", and "41 Boosts" once the goal is met.
    static func countLabel(_ count: Int, goal: Int) -> String {
        count >= goal ? "\(count.formatted()) Boosts" : "\(count.formatted())/\(goal.formatted()) Boosts"
    }

    /// The boosts each level needs — Discord's `M2T`.
    static let levelThresholds = [0, 2, 7, 14]

    /// The next level and how many boosts are still wanted for it — nil at
    /// level 3.
    var nextLevel: (level: Int, wanted: Int)? {
        guard level < 3 else { return nil }
        let next = level + 1
        return (next, max(Self.levelThresholds[next] - count, 0))
    }

    /// How far along the road to level 3 a count is, 0…1, with the three
    /// levels evenly spaced and the count linear between them — the flyout's
    /// track.
    static func roadPosition(of count: Int) -> Double {
        let stops = levelThresholds
        for level in 0..<3 where count < stops[level + 1] {
            let span = Double(stops[level + 1] - stops[level])
            return (Double(level) + Double(max(count, 0) - stops[level]) / span) / 3
        }
        return 1
    }
}
