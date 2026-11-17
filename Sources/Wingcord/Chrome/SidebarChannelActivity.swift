import Foundation
import WingcordCore

/// An activity running in a voice room, as its sidebar row draws it.
struct SidebarChannelActivity: Hashable, Sendable, Identifiable {
    var id: ApplicationID { applicationID }
    var applicationID: ApplicationID
    var name: String
    var iconURL: URL?
    var playerCount: Int
}
