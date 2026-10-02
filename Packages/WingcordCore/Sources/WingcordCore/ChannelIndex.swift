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
    /// Direct and group-DM channels, newest activity first — every one,
    /// requests included.
    private var privateChannels: [ChannelID] = []
    /// The two halves of that list: the conversations the reader has, and the
    /// ones still asking — partitioned once per change rather than per read,
    /// for the reason `channelsByGuild` is stored.
    private var conversations: [ChannelID] = []
    private var requests: [ChannelID] = []
    /// Threads, grouped by the channel they hang off, newest activity first.
    ///
    /// **A separate partition, and it has to be.** A thread resolves through
    /// `subscript` like any other channel — the timeline, the chrome and the
    /// permission gate all look it up that way — but it must never appear in
    /// `channelIDs(inGuild:)`: its `parentID` is a *channel*, not a category, so
    /// the sidebar's builder would file it under a bucket it never emits, and
    /// the browse list would offer it as a top-level row. Keeping it out of
    /// `channelsByGuild` also means `replaceChannels` cannot silently drop the
    /// followed threads on every GUILD_CREATE.
    private var threadsByParent: [ChannelID: [ChannelID]] = [:]
    /// The parent each known thread hangs off, so a removal costs one lookup
    /// rather than a sweep over every parent's array.
    private var parentOfThread: [ChannelID: ChannelID] = [:]

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

    /// The conversations the reader has, newest activity first.
    ///
    /// **Not the message requests.** Discord keeps those out of the list, the
    /// badges, the notifications and everything else that walks the reader's
    /// conversations (module `309199`), so the one list everything here reads
    /// leaves them out, and the requests have a list of their own.
    public func privateChannelIDs() -> [ChannelID] { conversations }

    /// Every private channel, requests included — for the few things that are
    /// about the channel rather than the conversation list: a mute setting, and
    /// whether a conversation with somebody already exists.
    public func allPrivateChannelIDs() -> [ChannelID] { privateChannels }

    /// The conversations still waiting as message requests or filtered as
    /// spam, newest activity first — Discord's order for both tabs.
    public func messageRequestIDs(_ standing: MessageRequestStanding) -> [ChannelID] {
        requests.filter { channels[$0]?.messageRequest == standing }
    }

    /// The known threads under one channel, most recently active first.
    ///
    /// "Known" is the operative word: a user account is told about the threads
    /// it **follows**, so this is never the full set of a channel's threads and
    /// must not be presented as one.
    public func threadIDs(inParent parentID: ChannelID) -> [ChannelID] {
        threadsByParent[parentID] ?? []
    }

    /// The channel a thread hangs off, or nil if this is not a known thread.
    public func parentID(ofThread threadID: ChannelID) -> ChannelID? {
        parentOfThread[threadID]
    }

    public var count: Int { channels.count }

    /// Every channel the account knows, in no order — the stored values
    /// themselves, not a copy of them.
    public var allChannels: Dictionary<ChannelID, Channel>.Values { channels.values }

    // MARK: Writing

    /// Replaces every channel of one guild. Structural.
    public mutating func replaceChannels(_ list: [Channel], inGuild guildID: GuildID) {
        // Drop the guild's previous membership before inserting, or a channel
        // deleted while the app was away lingers in both indexes forever.
        let surviving = Set(list.map(\.id))
        for channelID in channelsByGuild[guildID] ?? [] {
            channels[channelID] = nil
            guildOfChannel[channelID] = nil
            // A channel that did not come back takes its threads with it. The
            // threads are not in `channelsByGuild`, so nothing else in this
            // sweep would ever reach them.
            guard !surviving.contains(channelID) else { continue }
            for threadID in threadsByParent.removeValue(forKey: channelID) ?? [] {
                channels[threadID] = nil
                guildOfChannel[threadID] = nil
                parentOfThread[threadID] = nil
            }
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
        let previous = channels[channel.id]
        let existed = previous != nil
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
        } else if previous?.messageRequest != channel.messageRequest {
            // Accepted, or moved between Requests and Spam: the same channel
            // changes which list it is in.
            partitionPrivateChannels()
            structureRevision &+= 1
        }
        valueRevision &+= 1
    }

    public mutating func remove(_ channelID: ChannelID) {
        guard let channel = channels.removeValue(forKey: channelID) else { return }
        if let parentID = parentOfThread.removeValue(forKey: channelID) {
            threadsByParent[parentID]?.removeAll { $0 == channelID }
            if threadsByParent[parentID]?.isEmpty == true { threadsByParent[parentID] = nil }
            guildOfChannel[channelID] = nil
        } else if let guildID = guildOfChannel.removeValue(forKey: channelID) {
            channelsByGuild[guildID]?.removeAll { $0 == channelID }
            // A channel going takes its threads with it. Left behind they are
            // unreachable rows holding a parent that no longer resolves.
            for threadID in threadsByParent.removeValue(forKey: channelID) ?? [] {
                channels[threadID] = nil
                guildOfChannel[threadID] = nil
                parentOfThread[threadID] = nil
            }
        } else if channel.kind.isPrivate {
            privateChannels.removeAll { $0 == channelID }
            partitionPrivateChannels()
        }
        structureRevision &+= 1
        valueRevision &+= 1
    }

    // MARK: Threads

    /// Adds or replaces one thread.
    ///
    /// Structural, because a thread appearing or moving changes the sidebar. A
    /// thread whose `parentID` is missing is dropped rather than filed under
    /// nothing — every payload that carries a thread carries its parent, so a
    /// nil here is a decode fault and hiding it under a placeholder key would
    /// make it unfindable.
    public mutating func upsertThread(_ thread: Channel) {
        guard let parentID = thread.parentID else { return }
        let previousParent = parentOfThread[thread.id]
        channels[thread.id] = thread
        if let guildID = thread.guildID { guildOfChannel[thread.id] = guildID }

        if previousParent != parentID {
            if let previousParent {
                threadsByParent[previousParent]?.removeAll { $0 == thread.id }
            }
            parentOfThread[thread.id] = parentID
            threadsByParent[parentID, default: []].append(thread.id)
        }
        threadsByParent[parentID] = sortedThreadIDs(threadsByParent[parentID] ?? [])
        structureRevision &+= 1
        valueRevision &+= 1
    }

    /// Replaces the known threads under the named parents.
    ///
    /// **A nil `parentIDs` means every parent in the guild**, which is what
    /// `THREAD_LIST_SYNC` sends when it is resyncing the lot — see
    /// `ThreadListSyncDTO.channel_ids`. Reading that as "no parents" would leave
    /// every stale thread in place, which is the exact bug the event exists to
    /// prevent.
    public mutating func replaceThreads(
        _ list: [Channel],
        inParents parentIDs: [ChannelID]?,
        guildID: GuildID?
    ) {
        let cleared: [ChannelID]
        if let parentIDs {
            cleared = parentIDs
        } else if let guildID {
            cleared = threadsByParent.keys.filter { guildOfChannel[$0] == guildID }
        } else {
            cleared = Array(threadsByParent.keys)
        }

        for parentID in cleared {
            for threadID in threadsByParent.removeValue(forKey: parentID) ?? [] {
                channels[threadID] = nil
                guildOfChannel[threadID] = nil
                parentOfThread[threadID] = nil
            }
        }
        for thread in list { upsertThread(thread) }
        structureRevision &+= 1
        valueRevision &+= 1
    }

    /// Most recently active first, ties broken on id so the order is stable
    /// between two identical payloads — the same reason `Channel.listOrder`
    /// breaks its own tie.
    private func sortedThreadIDs(_ ids: [ChannelID]) -> [ChannelID] {
        ids.sorted { lhs, rhs in
            let a = channels[lhs]?.lastMessageID?.rawValue ?? lhs.rawValue
            let b = channels[rhs]?.lastMessageID?.rawValue ?? rhs.rawValue
            return a != b ? a > b : lhs.rawValue > rhs.rawValue
        }
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
        if channel.guildID == nil {
            sortPrivateChannels()
        } else if let parentID = parentOfThread[channelID] {
            // A thread's order under its parent genuinely is recency, so this
            // re-sorts where a guild channel's position would not. Still not
            // structural: the set is unchanged, and bumping `structureRevision`
            // here would clear the sidebar's memo on every message in a thread.
            threadsByParent[parentID] = sortedThreadIDs(threadsByParent[parentID] ?? [])
        }
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
        partitionPrivateChannels()
    }

    private mutating func partitionPrivateChannels() {
        conversations.removeAll(keepingCapacity: true)
        requests.removeAll(keepingCapacity: true)
        for channelID in privateChannels {
            if channels[channelID]?.messageRequest == nil {
                conversations.append(channelID)
            } else {
                requests.append(channelID)
            }
        }
    }
}
