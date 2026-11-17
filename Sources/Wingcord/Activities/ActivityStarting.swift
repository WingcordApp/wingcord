import WingcordCore

/// An activity on its way: launched or joined, not yet open.
///
/// Shown the moment the reader clicks ("Starting Wordle…"): the frame waits
/// for Discord's update listing this session, about half a second, and a click
/// that shows nothing for that long reads as one that missed.
struct ActivityStarting: Hashable, Sendable {
    var applicationID: ApplicationID
    var channelID: ChannelID
    var name: String
}
