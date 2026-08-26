import Foundation

/// Every channel the session knows, plus the two lookups the UI does constantly:
/// id → channel, and id → owning guild.
///
/// **The reason this is a type rather than two dictionaries on the store is one
/// specific failure.** Discord rewrites a channel's `lastMessageID` on *every
/// inbound message*. If the channel table is rebuilt or re-indexed on that
/// write, the id→guild index is torn down and rebuilt over every guild and every
/// channel several times a second — and the memo protecting it is then present,
/// correct, and never hit, which is invisible from the outside and shows up only
/// as a profile where dictionary insertion is the hottest thing in the app.
///
/// `patchLastMessage` exists so that write can say what it is: a channel's
/// **value** changed and the **set** did not, so the id→guild index cannot be
/// affected at all and the id→channel index needs exactly one entry replaced.
///
/// Its precondition is narrow and load-bearing: anything *structural* — a
/// channel created, deleted, or moved between guilds — must go through
/// `replaceAll` or `upsert`, because running it through the patch leaves both
/// indexes answering with a channel set that no longer exists.
public struct ChannelIndex: Sendable {
    private var channels: [ChannelID: Channel] = [:]
    private var guildOfChannel: [ChannelID: GuildID] = [:]
    /// Channels grouped by guild, kept in list order so the sidebar does not
    /// sort per evaluation.
    private var channelsByGuild: [GuildID: [ChannelID]] = [:]
    /// Direct and group-DM channels, newest activity first.
    private var privateChannels: [ChannelID] = []

    /// Bumped whenever the SET of channels changes — never when only a value
    /// does. Memos over the channel tree key on this, which is the difference
    /// between a cache that works and one that is cleared several times a
    /// second.
    public private(set) var structureRevision: UInt64 = 0
    /// Bumped on any change at all, including a `lastMessageID` write. Surfaces
    /// that genuinely care about recency — the DM list's ordering — key on this
    /// one instead.
    public private(set) var valueRevision: UInt64 = 0

    public init() {}

    // MARK: Reading

    public subscript(id: ChannelID) -> Channel? { channels[id] }

    public func guildID(of channelID: ChannelID) -> GuildID? {
        guildOfChannel[channelID]
    }

    /// Every channel in a guild, in Discord's list order. The array is stored,
    /// so repeated reads hand back the same buffer and `Array ==` against it
    /// short-circuits on identity.
    public func channelIDs(inGuild guildID: GuildID) -> [ChannelID] {
        channelsByGuild[guildID] ?? []
    }

    public func privateChannelIDs() -> [ChannelID] { privateChannels }

    public var count: Int { channels.count }

    // MARK: Writing

    /// Replaces every channel of one guild. Structural.
    public mutating func replaceChannels(_ list: [Channel], inGuild guildID: GuildID) {
        // Drop the guild's previous membership before inserting, or a channel
        // deleted while the app was away lingers in both indexes forever.
        for channelID in channelsByGuild[guildID] ?? [] {
            channels[channelID] = nil
            guildOfChannel[channelID] = nil
        }

        var ordered = list
        ordered.sort(by: Channel.listOrder)

        var ids: [ChannelID] = []
        ids.reserveCapacity(ordered.count)
        for channel in ordered {
            channels[channel.id] = channel
            guildOfChannel[channel.id] = guildID
            ids.append(channel.id)
        }
        channelsByGuild[guildID] = ids
        structureRevision &+= 1
        valueRevision &+= 1
    }

    /// Replaces the DM and group-DM list. Structural.
    public mutating func replacePrivateChannels(_ list: [Channel]) {
        for channelID in privateChannels {
            channels[channelID] = nil
        }
        var ids: [ChannelID] = []
        ids.reserveCapacity(list.count)
        for channel in list {
            channels[channel.id] = channel
            ids.append(channel.id)
        }
        privateChannels = ids
        sortPrivateChannels()
        structureRevision &+= 1
        valueRevision &+= 1
    }

    /// Adds or replaces one channel. Structural if the channel is new or has
    /// moved guilds.
    public mutating func upsert(_ channel: Channel) {
        let existed = channels[channel.id] != nil
        let previousGuild = guildOfChannel[channel.id]
        channels[channel.id] = channel

        if let guildID = channel.guildID {
            if previousGuild != guildID {
                if let previousGuild {
                    channelsByGuild[previousGuild]?.removeAll { $0 == channel.id }
                }
                guildOfChannel[channel.id] = guildID
                var ids = channelsByGuild[guildID] ?? []
                ids.append(channel.id)
                channelsByGuild[guildID] = sortedIDs(ids)
                structureRevision &+= 1
            } else if existed {
                // A rename or a permission change can reorder the list.
                channelsByGuild[guildID] = sortedIDs(channelsByGuild[guildID] ?? [])
                structureRevision &+= 1
            }
        } else if !existed {
            privateChannels.append(channel.id)
            sortPrivateChannels()
            structureRevision &+= 1
        }
        valueRevision &+= 1
    }

    public mutating func remove(_ channelID: ChannelID) {
        guard let channel = channels.removeValue(forKey: channelID) else { return }
        if let guildID = guildOfChannel.removeValue(forKey: channelID) {
            channelsByGuild[guildID]?.removeAll { $0 == channelID }
        } else if channel.kind.isPrivate {
            privateChannels.removeAll { $0 == channelID }
        }
        structureRevision &+= 1
        valueRevision &+= 1
    }

    /// The hot path: a message arrived, so one channel's newest-message pointer
    /// moved.
    ///
    /// Touches exactly one entry and leaves `structureRevision` alone, because
    /// the SET has not changed. Private channels are re-sorted because their
    /// order genuinely is recency; guild channels are not, because theirs is
    /// position.
    public mutating func patchLastMessage(_ messageID: MessageID, in channelID: ChannelID) {
        guard var channel = channels[channelID] else { return }
        guard channel.lastMessageID != messageID else { return }
        channel.lastMessageID = messageID
        channels[channelID] = channel
        if channel.guildID == nil { sortPrivateChannels() }
        valueRevision &+= 1
    }

    private func sortedIDs(_ ids: [ChannelID]) -> [ChannelID] {
        ids.sorted { lhs, rhs in
            guard let a = channels[lhs], let b = channels[rhs] else {
                return lhs.rawValue < rhs.rawValue
            }
            return Channel.listOrder(a, b)
        }
    }

    /// Most recent first, with never-used channels last but stably ordered.
    private mutating func sortPrivateChannels() {
        privateChannels.sort { lhs, rhs in
            let a = channels[lhs]?.lastMessageID?.rawValue ?? 0
            let b = channels[rhs]?.lastMessageID?.rawValue ?? 0
            return a != b ? a > b : lhs.rawValue > rhs.rawValue
        }
    }
}
