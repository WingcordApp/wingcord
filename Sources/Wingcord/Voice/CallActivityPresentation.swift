import Foundation
import WingcordCore

/// An activity running in a call, as its tile draws it (docs/ACTIVITIES-CALLS-PICKER.md,
/// decision 3): "alex is playing / Wordle / Join Activity" until the reader is
/// in it, then the activity itself on the call's stage.
struct CallActivityPresentation: Hashable, Sendable, Identifiable {
    var id: ApplicationID { applicationID }
    var applicationID: ApplicationID
    var channelID: ChannelID
    var name: String
    var iconURL: URL?
    /// The app's wide artwork, behind the tile's words.
    var coverURL: URL?
    /// "alex is playing": the first person in it.
    var hostName: String?
    var players: [Face]
    var playerCount: Int
    /// The reader is in it here: the call shows the activity, not the invite.
    var isJoined: Bool
    /// Joining or launching, not open yet.
    var isStarting: Bool

    struct Face: Hashable, Sendable, Identifiable {
        var id: UserID
        var url: URL?
        var monogram: String
    }
}
