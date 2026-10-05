import Foundation

/// A Community server's Welcome Screen — Discord's older greeting for a new
/// member ("Explore the Server": a sentence about the server and up to five
/// channels to start in), and the settings page that keeps what is left of it.
///
/// **Discord froze it.** Its settings page now says "Changes to the Welcome
/// Screen are disabled" and points at Onboarding: the description cannot be
/// edited and no channel can be added. What remains is turning it off, and
/// taking a channel out or moving one — so those are the only writes here.
///
/// `GET /guilds/{id}/welcome-screen` answers `{description, welcome_channels}`.
/// **Whether it is on is not in that answer**: Discord reads it off the
/// server's `WELCOME_SCREEN_ENABLED` feature (`WelcomeScreenSettingsStore`).
public struct WelcomeScreen: Hashable, Sendable {
    public var description: String?
    public var channels: [Channel]

    public init(description: String? = nil, channels: [Channel] = []) {
        self.description = description
        self.channels = channels
    }

    /// Discord's `isEmpty` (`684407`): no channels is no Welcome Screen, and
    /// the settings row is not offered.
    public var isEmpty: Bool { channels.isEmpty }

    /// The feature that says it is on.
    public static let enabledFeature = "WELCOME_SCREEN_ENABLED"

    /// One of the "Top things to do": a channel, the words that sell it, and
    /// an emoji.
    ///
    /// **The emoji is kept as the wire has it** — an id, a name, or both — so
    /// a write sends back exactly what was read. The wire carries no
    /// animation flag; whoever draws a custom one looks it up.
    public struct Channel: Hashable, Sendable {
        public var channelID: ChannelID
        public var description: String
        public var emojiID: EmojiID?
        public var emojiName: String?

        public init(
            channelID: ChannelID,
            description: String,
            emojiID: EmojiID? = nil,
            emojiName: String? = nil
        ) {
            self.channelID = channelID
            self.description = description
            self.emojiID = emojiID
            self.emojiName = emojiName
        }
    }
}
