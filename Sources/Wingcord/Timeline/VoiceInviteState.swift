import Foundation
import WingcordCore

/// The room a voice invite leads to, as the reader may see it right now — what
/// the transcript's voice invite card draws (`InviteCardLayoutEngine`'s voice
/// body, Discord's `dF`).
///
/// **Built on the main actor and handed to the layout**, like every other
/// card's facts: the layout engine cannot reach the store. One per channel, not
/// per message — the same invite posted twice draws the same room; what
/// differs per message is who posted it, which the layout reads from the row.
nonisolated struct VoiceInviteState: Hashable, Sendable {
    var guildName: String
    var channelName: String
    /// Everybody in the channel, by id — a stable order, so a card does not
    /// reshuffle as people come and go.
    var people: [Person]
    /// Drawn as Discord's channel-row variant rather than its card — see
    /// `AppModel.usesVoiceChannelRow`.
    var asChannelRow = false

    struct Person: Hashable, Sendable {
        var id: UserID
        var name: String
        var avatarURL: URL?
        var isStreaming = false
    }
}
