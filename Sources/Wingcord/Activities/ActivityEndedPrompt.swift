import Foundation
import WingcordCore

/// The activity someone meant to join had ended: offer a new one there.
struct ActivityEndedPrompt: Identifiable {
    let id = UUID()
    var app: ActivityApp
    var channelID: ChannelID
    var guildID: GuildID?
}
