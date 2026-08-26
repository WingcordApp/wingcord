import Foundation
import WingcordCore

// MARK: - Memo keys

struct RailMemoKey: Hashable, Sendable {
    var revision: UInt64
    /// The rail's badges count only channels the reader can see, so a role
    /// change moves the answer.
    var roleRevision: UInt64
    var selectedGuildID: GuildID?
    var expandedFolders: Set<UInt64>
}

struct SidebarMemoKey: Hashable, Sendable {
    var structureRevision: UInt64
    var sidebarRevision: UInt64
    /// Permissions decide which channels exist at all in this list, so a role
    /// change has to rebuild it. Leaving this out of the key is how a channel
    /// the reader has just lost access to stays on screen until something
    /// unrelated happens to invalidate the memo.
    var roleRevision: UInt64
    var guildID: GuildID?
    var collapsedCategories: Set<ChannelID>
}

// MARK: - Projections
//
// Each of these builds one surface's value snapshot, memoized.
//
// THE ORDER INSIDE THEM IS LOAD-BEARING. `withObservationTracking` records the
// properties a body actually READ — so a memo that consults its cache first and
// returns early reads nothing observable, registers no dependency, and its
// reader is never invalidated. The symptom is a click that does nothing until
// some unrelated event happens to re-run the view.
//
// Every observable input is therefore read into the key BEFORE the cache is
// consulted, and the key is built unconditionally.

extension AppModel {

    /// The guild rail.
    var railItems: [RailItem] {
        let key = RailMemoKey(
            revision: railRevision,
            roleRevision: roleRevision,
            selectedGuildID: selectedGuildID,
            expandedFolders: expandedFolderIDs
        )
        // Reading `guilds` and `folders` here — not inside the builder — is what
        // registers the dependency on a cache hit. Arrays and dictionaries are
        // copy-on-write, so a `let` is a retain rather than a copy.
        let guildTable = guilds
        let folderList = folders

        if let railCache, railCache.key == key { return railCache.value }

        let value = Self.buildRail(
            folders: folderList,
            guilds: guildTable,
            expanded: expandedFolderIDs,
            badge: { [self] guildID in guildBadge(for: guildID) },
            connectedVoiceGuild: connectedVoiceChannelID.flatMap {
                channelIndex.guildID(of: $0)
            }
        )
        railCache = (key, value)
        return value
    }

    /// The channel column for the selected guild.
    var sidebarPresentation: SidebarPresentation {
        let key = SidebarMemoKey(
            structureRevision: channelIndex.structureRevision,
            sidebarRevision: sidebarRevision,
            roleRevision: roleRevision,
            guildID: selectedGuildID,
            collapsedCategories: collapsedCategoryIDs
        )
        let guildTable = guilds

        if let sidebarCache, sidebarCache.key == key { return sidebarCache.value }

        let value: SidebarPresentation
        if let guildID = selectedGuildID, let guild = guildTable[guildID] {
            value = buildGuildSidebar(guild: guild)
        } else {
            value = .empty
        }
        sidebarCache = (key, value)
        return value
    }

    /// The now bar.
    ///
    /// Not memoized: it is one small struct built from a handful of scalars, and
    /// a memo over it would cost more in key comparison than the build.
    var nowBarPresentation: NowBarPresentation {
        let user = currentUserID.flatMap { users[$0] }
        let voiceChannel = connectedVoiceChannelID.flatMap { channelIndex[$0] }
        let voiceGuild = voiceChannel?.guildID.flatMap { guilds[$0] }
        return NowBarPresentation(
            userID: currentUserID ?? UserID(rawValue: 0),
            displayName: user?.preferredName ?? "Not signed in",
            handle: user?.handle ?? "",
            avatarURL: user.flatMap { avatarURL(for: $0, side: Metrics.avatarRow) },
            monogram: user?.monogram ?? "?",
            status: selfStatus,
            customStatus: selfCustomStatus,
            isMuted: isSelfMuted,
            isDeafened: isSelfDeafened,
            voiceChannelName: voiceChannel?.name,
            voiceGuildName: voiceGuild?.name
        )
    }

    /// What the detail column is showing.
    ///
    /// **One value, and the detail column is one view type that takes it.** The
    /// split view re-resolves its column widths on a structural detail swap and
    /// steals width from the sidebar every time; with the detail's type held
    /// constant there is no swap to fire on. Anything added later becomes a case
    /// on `Primary`, never a branch in the view builder.
    var workspacePresentation: WorkspacePresentation {
        guard let channelID = selectedChannelID, let channel = channelIndex[channelID] else {
            return .empty
        }
        let primary: WorkspacePresentation.Primary = switch channel.kind {
        case .forum, .media: .forum(channelID)
        case .voice, .stage: .voice(channelID)
        default: .conversation(channelID)
        }
        let supplementary: WorkspacePresentation.Supplementary? =
            isMemberListShown && channel.guildID != nil ? .members : nil
        return WorkspacePresentation(primary: primary, supplementary: supplementary)
    }

    /// The toolbar's channel chrome.
    var channelChrome: ChannelChrome {
        guard let channelID = selectedChannelID, let channel = channelIndex[channelID] else {
            return ChannelChrome(
                channelID: nil,
                name: "",
                kind: .text,
                topic: nil,
                isMemberListShown: false,
                canShowMemberList: false
            )
        }
        return ChannelChrome(
            channelID: channelID,
            name: displayName(of: channel),
            kind: channel.kind,
            topic: channel.topic,
            isMemberListShown: isMemberListShown,
            canShowMemberList: channel.guildID != nil
        )
    }

    // MARK: Building

    private static func buildRail(
        folders: [GuildFolder],
        guilds: [GuildID: Guild],
        expanded: Set<UInt64>,
        badge: (GuildID) -> (mentions: Int, unread: Bool, muted: Bool),
        connectedVoiceGuild: GuildID?
    ) -> [RailItem] {
        var items: [RailItem] = []
        items.reserveCapacity(folders.count)

        func makeGuild(_ guildID: GuildID) -> RailGuild? {
            guard let guild = guilds[guildID] else { return nil }
            let state = badge(guildID)
            return RailGuild(
                id: guildID,
                name: guild.name,
                iconURL: guild.iconHash.flatMap {
                    CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.guildTile)
                },
                monogram: guild.monogram,
                mentionCount: state.mentions,
                hasUnread: state.unread,
                isMuted: state.muted,
                isConnectedToVoice: connectedVoiceGuild == guildID
            )
        }

        for folder in folders {
            // A single-guild "folder" is how the settings payload represents a
            // guild sitting loose in the rail. Unwrap it rather than drawing a
            // one-item folder nobody created.
            guard folder.isRealFolder else {
                if let guildID = folder.guildIDs.first, let entry = makeGuild(guildID) {
                    items.append(.guild(entry))
                }
                continue
            }

            let members = folder.guildIDs.compactMap(makeGuild)
            guard !members.isEmpty else { continue }
            items.append(.folder(RailFolder(
                id: folder.id ?? 0,
                name: folder.name,
                colorValue: folder.colorValue,
                guilds: members,
                isExpanded: expanded.contains(folder.id ?? 0),
                mentionCount: members.reduce(0) { $0 + $1.mentionCount },
                hasUnread: members.contains(where: \.hasUnread)
            )))
        }

        return items
    }

    private func buildGuildSidebar(guild: Guild) -> SidebarPresentation {
        let channelIDs = channelIndex.channelIDs(inGuild: guild.id)
        var rows: [SidebarRow] = []
        rows.reserveCapacity(channelIDs.count + 2)

        if guild.features.contains("COMMUNITY") {
            rows.append(.guildAction(SidebarAction(kind: .channelsAndRoles)))
            rows.append(.guildAction(SidebarAction(kind: .serverGuide)))
        }

        // One pass. Categories in list order, each followed by its children —
        // which is exactly the order the flat channel list is already in,
        // because `ChannelIndex` sorts by position and a category always
        // precedes its members there. Uncategorised channels come first,
        // matching Discord.
        //
        // THE PERMISSION FILTER IS HERE, once, and it is the only place a
        // channel can enter the list. A channel the reader cannot view is not
        // dimmed or disabled — it does not exist, which is what Discord does and
        // what people expect from a private channel. Filtering later, at the row,
        // would leave the channel in the navigation model where a keyboard
        // shortcut or a restored selection could still reach it.
        var byParent: [ChannelID?: [Channel]] = [:]
        var categories: [Channel] = []
        for channelID in channelIDs {
            guard let channel = channelIndex[channelID] else { continue }
            if channel.kind == .category {
                // A category's own `viewChannel` is not the gate — its children's
                // are. A category denied to @everyone but whose child is allowed
                // to a role must still show, or the channel underneath becomes
                // unreachable.
                categories.append(channel)
            } else if channel.kind.isConversation || channel.kind == .forum || channel.kind == .media {
                guard permissionGate.canView(channel.id) else { continue }
                byParent[channel.parentID, default: []].append(channel)
            }
        }

        for channel in byParent[nil] ?? [] {
            rows.append(.channel(makeSidebarChannel(channel)))
        }

        for category in categories {
            let children = byParent[category.id] ?? []
            // A category with no visible children is a heading over nothing.
            guard !children.isEmpty else { continue }
            let isExpanded = !collapsedCategoryIDs.contains(category.id)
            let hasUnread = children.contains { unreadState(of: $0).unread }
            rows.append(.category(SidebarCategory(
                id: category.id,
                name: category.name,
                isExpanded: isExpanded,
                hasUnread: hasUnread
            )))
            guard isExpanded else { continue }
            for channel in children {
                rows.append(.channel(makeSidebarChannel(channel)))
            }
        }

        return SidebarPresentation(
            header: SidebarHeader(
                guildID: guild.id,
                name: guild.name,
                bannerURL: guild.bannerHash.flatMap {
                    CDN.guildBanner(
                        guildID: guild.id,
                        hash: $0,
                        width: Proportions.channelColumnMax
                    )
                }
            ),
            rows: rows
        )
    }

    private func makeSidebarChannel(_ channel: Channel) -> SidebarChannel {
        let state = unreadState(of: channel)
        return SidebarChannel(
            id: channel.id,
            name: channel.name,
            kind: channel.kind,
            isUnread: state.unread,
            mentionCount: state.mentions,
            isMuted: state.muted,
            voiceMembers: []
        )
    }

    private func unreadState(of channel: Channel) -> (unread: Bool, mentions: Int, muted: Bool) {
        guard let state = readStates[channel.id] else {
            return (channel.lastMessageID != nil, 0, false)
        }
        return (
            state.isUnread(newest: channel.lastMessageID),
            state.mentionCount,
            state.isMuted
        )
    }

    private func guildBadge(for guildID: GuildID) -> (mentions: Int, unread: Bool, muted: Bool) {
        var mentions = 0
        var unread = false
        for channelID in channelIndex.channelIDs(inGuild: guildID) {
            guard let channel = channelIndex[channelID], channel.kind.isConversation else {
                continue
            }
            // A channel the reader cannot see must not contribute a badge. A
            // rail tile marked unread for a channel that does not appear in the
            // list is a dot nobody can ever clear.
            guard permissionGate.canView(channelID) else { continue }
            let state = unreadState(of: channel)
            guard !state.muted else { continue }
            mentions += state.mentions
            unread = unread || state.unread
        }
        return (mentions, unread, false)
    }

    // MARK: Naming and assets

    /// What to call a channel in the chrome.
    ///
    /// A DM has no name of its own — Discord sends an empty string — so it is
    /// named for whoever is in it.
    func displayName(of channel: Channel) -> String {
        guard channel.kind.isPrivate else { return channel.name }
        if !channel.name.isEmpty { return channel.name }
        let names = channel.recipientIDs.compactMap { users[$0]?.preferredName }
        return names.isEmpty ? "Direct Message" : names.joined(separator: ", ")
    }

    func avatarURL(for user: User, side: CGFloat) -> URL? {
        guard let hash = user.avatarHash else {
            return CDN.defaultAvatar(index: user.defaultAvatarIndex)
        }
        return CDN.avatar(userID: user.id, hash: hash, side: side)
    }

    /// The avatar to draw for a person in a guild, honouring a per-guild
    /// override.
    func avatarURL(forUserID userID: UserID, inGuild guildID: GuildID?, side: CGFloat) -> URL? {
        if let guildID, let member = members[guildID]?[userID], let hash = member.avatarHash {
            return CDN.guildMemberAvatar(
                guildID: guildID,
                userID: userID,
                hash: hash,
                side: side
            )
        }
        guard let user = users[userID] else { return nil }
        return avatarURL(for: user, side: side)
    }

    // MARK: Navigation

    func selectGuild(_ guildID: GuildID?) {
        guard selectedGuildID != guildID else { return }
        selectedGuildID = guildID
        // Return to where the reader was, not to the top of the list.
        if let guildID {
            selectedChannelID = lastChannelByGuild[guildID]
                ?? firstReadableChannel(inGuild: guildID)
        } else {
            selectedChannelID = channelIndex.privateChannelIDs().first
        }
    }

    func selectChannel(_ channelID: ChannelID) {
        guard selectedChannelID != channelID, canOpen(channelID) else { return }
        selectedChannelID = channelID
        if let guildID = channelIndex.guildID(of: channelID) {
            lastChannelByGuild[guildID] = channelID
        }
    }

    private func firstReadableChannel(inGuild guildID: GuildID) -> ChannelID? {
        channelIndex.channelIDs(inGuild: guildID).first {
            (channelIndex[$0]?.kind.isConversation ?? false) && permissionGate.canView($0)
        }
    }

    /// Whether a channel may be navigated to at all.
    ///
    /// Checked on every selection, not only on the ones the list offers: a
    /// restored selection from a previous launch, a jump from a message link and
    /// a keyboard shortcut all reach `selectChannel` without passing the list.
    func canOpen(_ channelID: ChannelID) -> Bool {
        permissionGate.canView(channelID)
    }

    func toggleFolder(_ folderID: UInt64) {
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
    }

    func toggleCategory(_ categoryID: ChannelID) {
        if collapsedCategoryIDs.contains(categoryID) {
            collapsedCategoryIDs.remove(categoryID)
        } else {
            collapsedCategoryIDs.insert(categoryID)
        }
    }
}
