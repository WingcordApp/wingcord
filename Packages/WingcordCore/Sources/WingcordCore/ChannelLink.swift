import Foundation

/// A link into a channel, or to one message in it, as Discord writes them.
///
/// Three shapes, from Discord's own two rules — `channelOrMessageUrl` and
/// `mediaPostLink`, over the patterns in module `376943`:
///
/// - `https://discord.com/channels/{guild|@me}/{channel}` — a channel;
/// - `…/{channel}/{message}` — one message in it, what "Copy Message Link"
///   produces;
/// - `…/{channel}/threads/{post}/{message}` — one message in a forum post.
///
/// Rendered as a bare blue URL none of them says anything: the snowflakes are
/// the only content, and none of them is readable. Discord draws each as a chip
/// naming the place, and so does this client.
///
/// **Parsed by splitting, not by a regex.** A Swift regex literal is re-parsed
/// on every call and this runs once per link per message layout — see
/// `INVARIANTS.md` §2.
public struct ChannelLink: Hashable, Sendable {
    /// Nil for `@me`, which is a direct message and belongs to no guild.
    public var guildID: GuildID?
    /// The channel the link names — for a post, the forum it is in.
    public var channelID: ChannelID
    /// The forum post, for a link through `/threads/`.
    public var threadID: ChannelID?
    /// Nil for a link to the channel itself.
    public var messageID: MessageID?

    public init(
        guildID: GuildID?,
        channelID: ChannelID,
        threadID: ChannelID? = nil,
        messageID: MessageID? = nil
    ) {
        self.guildID = guildID
        self.channelID = channelID
        self.threadID = threadID
        self.messageID = messageID
    }

    /// Where following the link goes: the post when there is one.
    public var destinationID: ChannelID { threadID ?? channelID }

    /// Discord's own hosts, and only those.
    ///
    /// The release channels serve the same account, so a link copied from
    /// canary resolves here exactly as one copied from stable. Anything else is
    /// a URL that merely looks like one of these and must open in a browser — a
    /// client that navigates on a hostname it did not check is a client that
    /// can be steered by a message. (`www.` is not in Discord's pattern; it is
    /// accepted here because it is the same site, and has always been.)
    private static let hosts: Set<String> = [
        "discord.com",
        "www.discord.com",
        "canary.discord.com",
        "ptb.discord.com",
        "discordapp.com",
        "www.discordapp.com",
        "canary.discordapp.com",
        "ptb.discordapp.com",
    ]

    /// The link, or nil for anything that is not one — which then stays an
    /// ordinary URL, exactly as Discord leaves it.
    public static func parse(_ url: String) -> ChannelLink? {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              hosts.contains(host)
        else { return nil }

        // `path` is percent-decoded and starts with "/". Empty segments are
        // KEPT: `/channels/@me//2` is Discord's pattern failing at the empty
        // one, which leaves a plain link, and must not collapse into a
        // channel link to 2. One trailing slash is not a segment.
        var segments = components.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
        if segments.last?.isEmpty == true { segments = segments.dropLast() }
        let parts = Array(segments)
        guard parts.count >= 3, parts[0] == "channels" else { return nil }

        let guildID: GuildID?
        if parts[1] == "@me" {
            guildID = nil
        } else if let raw = UInt64(parts[1]) {
            guildID = GuildID(rawValue: raw)
        } else {
            return nil
        }
        guard let channel = UInt64(parts[2]) else { return nil }
        let channelID = ChannelID(rawValue: channel)

        switch parts.count {
        case 3:
            return ChannelLink(guildID: guildID, channelID: channelID)
        case 4:
            guard let message = UInt64(parts[3]) else { return nil }
            return ChannelLink(
                guildID: guildID,
                channelID: channelID,
                messageID: MessageID(rawValue: message)
            )
        case 6:
            // A post lives in a guild's forum; `@me` has none.
            guard guildID != nil, parts[3] == "threads",
                  let thread = UInt64(parts[4]), let message = UInt64(parts[5])
            else { return nil }
            return ChannelLink(
                guildID: guildID,
                channelID: channelID,
                threadID: ChannelID(rawValue: thread),
                messageID: MessageID(rawValue: message)
            )
        default:
            return nil
        }
    }
}
