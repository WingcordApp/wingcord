import Foundation
import WingcordCore

/// Get Started's progress, as Discord's client keeps it (docs/QUEUE-NOV19.md
/// S2, S5): loaded with the guide, a step marked as the reader does it, and the
/// finish noticed when Discord says so.
extension SessionController {
    /// Which steps are done. Asked only once the reader has started — before
    /// that there is nothing to ask, as in Discord (`STARTED_HOME_ACTIONS`).
    func loadGuideProgress(_ guildID: GuildID) {
        guard let me = model.currentUserID, let member = model.members[guildID]?[me],
              model.pendingGuideSteps(in: guildID) != nil
        else { return }
        guard member.flags.contains(.startedHomeActions) else {
            if model.guideProgress[guildID] == nil { model.guideProgress[guildID] = [] }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let done = try await rest.guideProgress(of: guildID)
                // Whatever the reader did while it was out stays done.
                model.guideProgress[guildID] = done.union(model.guideProgress[guildID] ?? [])
            } catch {
                Self.trace("guide progress for \(guildID) failed: \(Self.describe(error))")
            }
        }
    }

    /// A visit or a post that does a step: marked at once, then told to Discord.
    func noteGuideStep(_ event: GuideStepEvent, in channelID: ChannelID) {
        guard let (guildID, stepChannel) = model.guideStep(completedBy: event, in: channelID) else { return }
        model.guideProgress[guildID, default: []].insert(stepChannel)
        Log.info(.app, "guide step done in \(public: guildID.description): \(public: stepChannel.description)")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.completeGuideStep(stepChannel, in: guildID)
            } catch {
                Self.trace("guide step \(stepChannel) failed: \(Self.describe(error))")
            }
        }
    }

    /// Discord sets `COMPLETED_HOME_ACTIONS` when the last step is done; that
    /// is the moment it celebrates (`455796`).
    func noteGuideFinished(in guildID: GuildID, hadFinished: Bool) {
        guard !hadFinished,
              let me = model.currentUserID,
              model.members[guildID]?[me]?.flags.contains(.completedHomeActions) == true,
              let steps = model.serverGuides[guildID]?.actions, !steps.isEmpty
        else { return }
        model.guideProgress[guildID] = Set(steps.map(\.channelID))
        model.guideFinished = guildID
    }
}
