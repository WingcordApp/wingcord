import Foundation
import WingcordCore

/// One connected app's activity, by the socket that set it — an entry in
/// Discord's LocalActivityStore (`480595`'s `G`).
struct LocalRPCActivity: Equatable {
    var socket: Int
    var activity: RichPresenceActivity
}

extension AppModel {

    /// An app set or cleared its activity — Discord's `LOCAL_ACTIVITY_UPDATE`
    /// — and the presence says so.
    func setLocalRPCActivity(_ activity: RichPresenceActivity?, socket: Int) {
        var list = localRPCActivities
        if let activity {
            if let index = list.firstIndex(where: { $0.socket == socket }) {
                list[index].activity = activity
            } else {
                list.append(LocalRPCActivity(socket: socket, activity: activity))
            }
        } else {
            list.removeAll { $0.socket == socket }
        }
        guard list != localRPCActivities else { return }
        localRPCActivities = list
        reflectOwnPresenceNow()
        sessionController.publishPresence()
    }

    /// Whether a detected game is already said by its own app — Discord drops
    /// the game when an app's activity has its name, or is its app (`480595`).
    nonisolated static func isAnnounced(_ game: RichPresenceActivity, by local: [RichPresenceActivity]) -> Bool {
        local.contains { activity in
            activity.name == game.name
                || (activity.applicationID != nil && activity.applicationID == game.applicationID)
        }
    }
}
