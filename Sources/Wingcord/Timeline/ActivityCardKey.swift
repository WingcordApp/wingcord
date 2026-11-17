import WingcordCore

/// One activity card in a message: which app, and the channel its Play
/// starts it in (the message's own, as Discord's link launches there).
nonisolated struct ActivityCardKey: Hashable, Sendable {
    var applicationID: ApplicationID
    var channelID: ChannelID
}
