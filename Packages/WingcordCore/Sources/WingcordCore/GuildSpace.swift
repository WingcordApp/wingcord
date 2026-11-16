import Foundation

/// A server's Server Hub — Discord's "guild space" (docs/BETA2.md, phase 9): a
/// page of widgets in two columns under a banner.
///
/// **Read from Discord's own client** (web build of 2026-11-16): `GET
/// /guilds/{id}/space` answers this, a 404 means the server has none, and a
/// `PUT` to the same route replaces it whole — the header and every widget.
public struct GuildSpace: Hashable, Sendable {
    public var guildID: GuildID
    /// The hidden channel of type 20 the hub's whiteboard runs in.
    public var channelID: ChannelID?
    /// The hub's own banner. Without one the page wears the server's.
    public var customBannerHash: String?
    public var widgets: [GuildSpaceWidget]

    public init(
        guildID: GuildID,
        channelID: ChannelID? = nil,
        customBannerHash: String? = nil,
        widgets: [GuildSpaceWidget] = []
    ) {
        self.guildID = guildID
        self.channelID = channelID
        self.customBannerHash = customBannerHash
        self.widgets = widgets
    }
}
