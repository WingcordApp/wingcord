import Foundation

/// A link to a server's event — `https://discord.com/events/{guild}/{event}`,
/// with the date on the end for one date of a series. Discord's
/// `GUILD_EVENT_DETAILS` route, which is what its Copy Event Link writes.
///
/// Parsed on `ChannelLink`'s terms: Discord's own hosts and nothing that
/// merely looks like one.
public struct EventLink: Hashable, Sendable {
    public var guildID: GuildID
    public var eventID: UInt64
    /// One date of a series, or nil for the event as a whole.
    public var occurrence: UInt64?

    public init(guildID: GuildID, eventID: UInt64, occurrence: UInt64? = nil) {
        self.guildID = guildID
        self.eventID = eventID
        self.occurrence = occurrence
    }

    public static func parse(_ url: String) -> EventLink? {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              ChannelLink.hosts.contains(host)
        else { return nil }
        var segments = components.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
        if segments.last?.isEmpty == true { segments = segments.dropLast() }
        let parts = Array(segments)
        guard (3...4).contains(parts.count), parts[0] == "events",
              let guild = UInt64(parts[1]), let event = UInt64(parts[2])
        else { return nil }
        var occurrence: UInt64?
        if parts.count == 4 {
            guard let date = UInt64(parts[3]) else { return nil }
            occurrence = date
        }
        return EventLink(guildID: GuildID(rawValue: guild), eventID: event, occurrence: occurrence)
    }
}
