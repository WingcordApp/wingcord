import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// The Boost progress bar at the head of a server's channels.
@MainActor
@Suite("Boost progress bar")
struct BoostGoalBarTests {

    private let guildID = GuildID(rawValue: 4_200)
    private let ownerID = UserID(rawValue: 9)

    private func model(isEnabled: Bool = true, count: Int = 9, level: Int = 2) -> AppModel {
        let model = AppModel()
        var guild = Guild(
            id: guildID, name: "Bar", ownerID: ownerID,
            premiumTier: level, premiumSubscriptionCount: count
        )
        guild.premiumProgressBarEnabled = isEnabled
        model.guilds[guildID] = guild
        return model
    }

    private func rollout(_ name: String, bucket: Int) -> GuildExperiment {
        GuildExperiment(hash: MurmurHash3.hash32(name), overrides: [guildID.rawValue: bucket])
    }

    @Test("Drawn only with the server's switch on, and first above the channels")
    func shownOnTheSwitch() throws {
        let on = model()
        let goal = try #require(on.sidebarBoostGoal(for: guildID))
        #expect(goal.goal == 33)
        #expect(on.sidebarPresentation(for: guildID).rows.first == .boostGoal(goal))
        #expect(model(isEnabled: false).sidebarBoostGoal(for: guildID) == nil)
    }

    @Test("The menu is offered to administrators only — the owner is one")
    func menuForAdministrators() {
        let model = model()
        #expect(model.sidebarBoostGoal(for: guildID)?.canSwitchOff == false)
        model.currentUserID = ownerID
        model.permissionGate.invalidate()
        #expect(model.sidebarBoostGoal(for: guildID)?.canSwitchOff == true)
    }

    @Test("Game servers count where their rollout reaches; the theme needs both of its halves")
    func rollouts() {
        let model = model()
        model.experiments = ExperimentSnapshot(guild: [
            MurmurHash3.hash32(AppModel.gameServersExperiment): rollout(AppModel.gameServersExperiment, bucket: 1),
            MurmurHash3.hash32(AppModel.serverThemeServerExperiment): rollout(AppModel.serverThemeServerExperiment, bucket: 1),
        ])
        #expect(model.sidebarBoostGoal(for: guildID)?.goal == 36)
        model.experiments.apex = [ApexAssignment(
            hash: MurmurHash3.hash32(AppModel.serverThemeAccountExperiment), variantID: 1, isOverride: false, revision: 1
        )]
        #expect(model.sidebarBoostGoal(for: guildID)?.goal == 39)
        // Control is in the experiment and has no theme.
        model.experiments.guild[MurmurHash3.hash32(AppModel.serverThemeServerExperiment)] =
            rollout(AppModel.serverThemeServerExperiment, bucket: 0)
        #expect(model.sidebarBoostGoal(for: guildID)?.goal == 36)
    }

    @Test("Discord's labels: N/M until the goal, N once it is met")
    func labels() {
        #expect(SidebarBoostGoal.countLabel(9, goal: 33) == "9/33 Boosts")
        #expect(SidebarBoostGoal.countLabel(33, goal: 33) == "33 Boosts")
        // In the reader's own digits.
        #expect(SidebarBoostGoal.countLabel(1_204, goal: 33) == "\(1_204.formatted()) Boosts")
    }

    @Test("The next level and how far it is; none past level 3")
    func nextLevel() {
        let goal = SidebarBoostGoal(guildID: guildID, count: 11, goal: 33, level: 2, canSwitchOff: false)
        #expect(goal.nextLevel?.level == 3)
        #expect(goal.nextLevel?.wanted == 3)
        #expect(SidebarBoostGoal(guildID: guildID, count: 20, goal: 33, level: 3, canSwitchOff: false).nextLevel == nil)
    }

    @Test("The flyout's road: three even stops, linear between them")
    func road() {
        #expect(SidebarBoostGoal.roadPosition(of: 0) == 0)
        #expect(SidebarBoostGoal.roadPosition(of: 1) == 1.0 / 6)
        #expect(SidebarBoostGoal.roadPosition(of: 2) == 1.0 / 3)
        #expect(abs(SidebarBoostGoal.roadPosition(of: 11) - (2 + 4.0 / 7) / 3) < 1e-9)
        #expect(SidebarBoostGoal.roadPosition(of: 14) == 1)
        #expect(SidebarBoostGoal.roadPosition(of: 90) == 1)
    }

    @Test("Switching it off takes the row away at once")
    func switchedOff() {
        let model = model()
        model.guilds[guildID]?.premiumProgressBarEnabled = false
        model.sidebarRevision &+= 1
        #expect(!model.sidebarPresentation(for: guildID).rows.contains { if case .boostGoal = $0 { true } else { false } })
    }
}
