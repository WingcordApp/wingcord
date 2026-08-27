import Foundation

/// A link to one message, as Discord writes them.
///
/// `https://discord.com/channels/{guild|@me}/{channel}/{message}` — the URL the
/// "Copy Message Link" item produces, and the one people paste at each other all
/// day. Rendered as a bare blue URL it says nothing: the three snowflakes in it
/// are the only content, and none of them is readable.
///
/// **Parsed by splitting, not by a regex.** A Swift regex literal is re-parsed
/// on every call and this runs once per link per message layout — see
/// `INVARIANTS.md` §2.
public struct MessageLink: Hashable, Sendable {
    /// Nil for `@me`, which is a direct message and belongs to no guild.
    public var guildID: GuildID?
    public var channelID: ChannelID
    public var messageID: MessageID

    public init(guildID: GuildID?, channelID: ChannelID, messageID: MessageID) {
        self.guildID = guildID
        self.channelID = channelID
        self.messageID = messageID
    }

    /// Discord's own hosts, and only those.
    ///
    /// The release channels serve the same account, so a link copied from canary
    /// resolves here exactly as one copied from stable. Anything else is a URL
    /// that merely looks like one of these and must open in a browser — a
    /// client that navigates on a hostname it did not check is a client that
    /// can be steered by a message.
    private static let hosts: Set<String> = [
        "discord.com",
        "www.discord.com",
        "canary.discord.com",
        "ptb.discord.com",
        "discordapp.com",
        "www.discordapp.com",
    ]

    /// The link, or nil for anything that is not one.
    public static func parse(_ url: String) -> MessageLink? {
        guard let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              hosts.contains(host)
        else { return nil }

        // `path` is already percent-decoded and always starts with "/", so the
        // leading empty segment is dropped rather than filtered — a channel id
        // cannot be empty, so an empty segment anywhere else fails the parse
        // below on its own.
        var segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 4, segments[0] == "channels" else { return nil }
        segments.removeFirst()

        let guildID: GuildID?
        if segments[0] == "@me" {
            guildID = nil
        } else if let raw = UInt64(segments[0]) {
            guildID = GuildID(rawValue: raw)
        } else {
            return nil
        }
        guard let channel = UInt64(segments[1]), let message = UInt64(segments[2]) else {
            return nil
        }
        return MessageLink(
            guildID: guildID,
            channelID: ChannelID(rawValue: channel),
            messageID: MessageID(rawValue: message)
        )
    }
}
