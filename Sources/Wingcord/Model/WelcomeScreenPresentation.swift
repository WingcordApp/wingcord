import Foundation
import WingcordCore

/// What "Explore the Server" draws — Discord's welcome modal (`954784`),
/// resolved from the resident server and its channels.
struct WelcomeScreenPresentation: Hashable, Sendable {
    var serverName: String
    var iconURL: URL?
    var monogram: String
    var description: String?
    /// The "Top things to do here" — only channels that exist and the reader
    /// can open, as Discord draws only those (`L` returns null otherwise).
    var options: [Option]

    struct Option: Hashable, Sendable, Identifiable {
        /// Its place in the list: a channel may be recommended twice, which is
        /// why Discord keys these by channel and index.
        var id: Int
        var channelID: ChannelID
        var channelName: String
        var channelSymbol: String
        var description: String
        var emoji: EmojiRef?
    }
}

/// The Welcome Screen a new member is shown after joining by invite — what
/// Discord's channel view raises from the invite's `guild.welcome_screen`.
struct WelcomeScreenNotice: Identifiable, Hashable, Sendable {
    var guildID: GuildID
    var screen: WelcomeScreen

    var id: GuildID { guildID }
}

extension WelcomeScreen.Channel {
    /// The emoji as a glyph can draw it.
    ///
    /// **A custom one is looked up in the server's own set** for whether it
    /// moves — the welcome screen's object does not say, and Discord resolves
    /// it from its emoji store the same way. One the reader's client has never
    /// seen is drawn still.
    func emoji(among serverEmoji: [EmojiRef]) -> EmojiRef? {
        if let emojiID {
            return serverEmoji.first { $0.id == emojiID }
                ?? EmojiRef(id: emojiID, name: emojiName ?? "", isAnimated: false)
        }
        return emojiName.map { EmojiRef(name: $0) }
    }
}
