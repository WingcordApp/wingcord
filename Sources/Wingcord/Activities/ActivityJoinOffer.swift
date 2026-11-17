import Foundation
import WingcordCore

/// Join Activity on someone's card, when they're in an activity the reader
/// can get into (decision 8: Join from a profile, a member row, Active Now).
/// Shaped like `ListenAlongOffer`, its neighbour on the same card.
struct ActivityJoinOffer {
    var help: String
    var isEnabled: Bool
    var join: () -> Void
}

extension AppModel {

    /// The activity a person is in, if it's the one their card shows and the
    /// reader can see the channel it runs in. Nil otherwise.
    func activityJoinOffer(for userID: UserID, activity: Activity) -> ActivityJoinOffer? {
        guard userID != currentUserID,
              let instance = activityInstances.instance(for: userID),
              activity.applicationID == nil || activity.applicationID == instance.applicationID,
              let channel = channelIndex[instance.location.channelID]
        else { return nil }
        let isIn = runningActivity.map {
            $0.applicationID == instance.applicationID && $0.instance.location.channelID == channel.id
        } ?? false
        let name = activityApp(instance.applicationID)?.name ?? activity.name
        return ActivityJoinOffer(
            help: isIn ? "You're already in \(name)." : "Join \(name) in \(displayName(of: channel))",
            isEnabled: !isIn,
            join: { [weak self] in self?.joinActivityInstance(instance) }
        )
    }

    /// Joins a running instance wherever it is: the call first, then the app
    /// (decision 2's order).
    func joinActivityInstance(_ instance: ActivityInstance) {
        let app = activityApp(instance.applicationID)
            ?? ActivityApp(
                id: instance.applicationID, name: "Activity",
                config: EmbeddedActivityConfig(supportedPlatforms: ["web"])
            )
        Task { await sessionController.startActivity(app, in: instance.location.channelID, section: "profile") }
    }
}
