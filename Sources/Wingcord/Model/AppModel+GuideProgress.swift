import Foundation
import WingcordCore

/// Get Started's progress (docs/QUEUE-NOV19.md S1–S5): which steps the reader
/// has done, and whether Discord would show them the steps at all.
extension AppModel {
    /// New here, by Discord's rule (`978165`): joined under a week ago and not
    /// yet finished the guide.
    func isNewGuideMember(in guildID: GuildID, now: Date = Date()) -> Bool {
        guard let me = currentUserID,
              let member = members[guildID]?[me],
              let joinedAt = member.joinedAt
        else { return false }
        return !member.flags.contains(.completedHomeActions)
            && now.timeIntervalSince(joinedAt) < 7 * 86_400
    }

    /// The guide's steps, where the reader is one Discord shows them to.
    func pendingGuideSteps(in guildID: GuildID) -> [ServerGuide.Action]? {
        guard let guide = serverGuides[guildID], guide.isEnabled, !guide.actions.isEmpty,
              isNewGuideMember(in: guildID)
        else { return nil }
        return guide.actions
    }

    /// "3 of 5": the channel list's Get Started header (`0ef84874` `iN`), or
    /// nil where Discord draws none.
    func guideProgressSummary(in guildID: GuildID) -> (completed: Int, total: Int)? {
        guard let steps = pendingGuideSteps(in: guildID) else { return nil }
        let done = guideProgress[guildID] ?? []
        // One step per channel, as Discord keys them.
        let channels = Set(steps.map(\.channelID))
        return (channels.filter(done.contains).count, channels.count)
    }

    func isGuideStepDone(_ channelID: ChannelID, in guildID: GuildID) -> Bool {
        guideProgress[guildID]?.contains(channelID) == true
    }

    /// The step a visit or a post in `channelID` completes, if any — Discord's
    /// rules (the home-actions manager): opening the channel does a *read*
    /// step; a message there, or a new post in it, does a *write* step.
    func guideStep(completedBy event: GuideStepEvent, in channelID: ChannelID) -> (GuildID, ChannelID)? {
        guard let guildID = channelIndex.guildID(of: channelID),
              let steps = pendingGuideSteps(in: guildID)
        else { return nil }
        let parentID = channelIndex[channelID]?.parentID
        for step in steps where !isGuideStepDone(step.channelID, in: guildID) {
            switch (event, step.kind) {
            case (.visit, .read) where step.channelID == channelID:
                return (guildID, step.channelID)
            case (.post, .write) where step.channelID == channelID || step.channelID == parentID:
                return (guildID, step.channelID)
            default:
                continue
            }
        }
        return nil
    }
}

enum GuideStepEvent {
    case visit
    case post
}
