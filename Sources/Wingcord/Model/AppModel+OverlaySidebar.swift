import Foundation
import WingcordCore

// MARK: - The overlay's sidebar, resolved once
//
// Three lists and an identity card, out of tables the store already holds.
// **Nothing here asks the network for anything**: a friend is a `relationships`
// entry, a conversation is a private channel in the order `patchLastMessage`
// keeps them, and a room is a `voiceStates` value grouped by the channel it
// names.
//
// It is memoized for the reason every projection in this app is — it is read by
// a surface drawn over a running game, and a roster rebuilt per frame there is
// the one cost this overlay may not have. It is also only ever *read* while the
// sidebar is on screen, so a key that moves on every inbound message in the
// account is affordable here where it would not be in the rail.

/// What can change the sidebar's contents.
struct OverlaySidebarMemoKey: Hashable, Sendable {
    /// Channels appearing and disappearing.
    var structureRevision: UInt64
    /// A `lastMessageID` moving, which is what the Messages tab is ordered by.
    var valueRevision: UInt64
    /// Friend nicknames, the favourite bit, **and every acknowledgement** —
    /// `acknowledge` and `markUnread` both bump it, so the bold on a row is
    /// covered by this and needs no counter of its own.
    var sidebarRevision: UInt64
    /// Relationships, notes, blocks — who is in the Friends tab at all.
    var identityRevision: UInt64
    /// Statuses and activities, which decide the bands and every subtitle.
    var presenceRevision: UInt64
    /// Somebody joining or leaving a room.
    var voiceRevision: UInt64
    var currentUserID: UserID?
    var connectedVoiceChannelID: ChannelID?
}

extension AppModel {

    /// Everything the overlay sidebar draws.
    var overlaySidebarPresentation: OverlaySidebarPresentation {
        // Every observable input is read before the cache is consulted. A memo
        // that answers from its cache without touching them registers no
        // dependency and is never invalidated again — `INVARIANTS.md` §2.
        let key = OverlaySidebarMemoKey(
            structureRevision: channelIndex.structureRevision,
            valueRevision: channelIndex.valueRevision,
            sidebarRevision: sidebarRevision,
            identityRevision: identityRevision,
            presenceRevision: presenceRevision,
            voiceRevision: voiceRevision,
            currentUserID: currentUserID,
            connectedVoiceChannelID: connectedVoiceChannelID
        )
        if let overlaySidebarCache, overlaySidebarCache.key == key {
            return overlaySidebarCache.value
        }

        let conversations = overlayConversations()
        let value = OverlaySidebarPresentation(
            identity: overlayIdentity(),
            friends: overlayFriends(conversations: conversations),
            conversations: conversations.rows,
            rooms: overlayRooms()
        )
        overlaySidebarCache = (key, value)
        return value
    }

    // MARK: The card at the top

    private func overlayIdentity() -> OverlayIdentity {
        guard let currentUserID, let user = users[currentUserID] else {
            return .signedOut
        }
        let decoration = user.decoration
        let presence = presences[currentUserID]
        return OverlayIdentity(
            userID: currentUserID,
            displayName: user.preferredName,
            handle: user.handle,
            avatarURL: avatarURL(for: user, side: Metrics.avatarMessage),
            monogram: user.monogram,
            decorationURL: decoration?.avatarDecorationHash
                .flatMap { CDN.avatarDecoration(hash: $0) },
            // **The reader's own switch, not the gateway's echo of it.**
            // `selfStatus` is what they picked a moment ago and what every other
            // surface in this app draws; the presence table lags it by a round
            // trip, and a dot that takes a second to follow a menu reads as the
            // menu having missed.
            status: selfStatus,
            customStatus: selfCustomStatus?.current()?.text ?? presence?.customStatus?.state,
            customStatusEmoji: selfCustomStatus?.current()?.emoji
                ?? presence?.customStatus?.emoji,
            bannerURL: decoration?.bannerHash.flatMap {
                CDN.userBanner(userID: currentUserID, hash: $0, width: 512)
            },
            themeColorValues: themeColorValues(of: user, decoration),
            accentColorValue: decoration?.accentColor
        )
    }

    // MARK: Friends

    /// The friends list, banded.
    ///
    /// **Blocked people are left out and outstanding requests are not friends.**
    /// The tab says Friends, and a list that quietly included somebody the
    /// reader has blocked — or somebody who has merely *asked* — would be the
    /// surface answering a different question than its label.
    private func overlayFriends(
        conversations: (rows: [OverlayConversation], byUser: [UserID: ChannelID])
    ) -> [OverlayPeopleSection] {
        let favouriteUserIDs = favouriteFriendIDs(conversations: conversations.byUser)
        var banded: [OverlayPeopleGroup: [OverlayPerson]] = [:]

        for (userID, relationship) in relationships where relationship == .friend {
            guard userID != currentUserID, !blockedUserIDs.contains(userID) else { continue }
            guard let user = users[userID] else { continue }
            let presence = presences[userID]
            let status = presence?.status ?? .offline
            let activity = presence?.primaryActivity
            let person = OverlayPerson(
                id: userID,
                // **The reader's own name for them beats the one they chose**,
                // which is the whole of what a friend nickname is for — and is
                // what the DM list already does.
                displayName: friendNicknames[userID] ?? user.preferredName,
                avatarURL: avatarURL(for: user, side: Metrics.avatarRow),
                monogram: user.monogram,
                decorationURL: user.decoration?.avatarDecorationHash
                    .flatMap { CDN.avatarDecoration(hash: $0) },
                status: status,
                isOnMobile: presence?.isOnMobile ?? false,
                subtitle: activity?.rowSubtitle ?? presence?.customStatus?.rowSubtitle,
                subtitleEmoji: activity == nil ? presence?.customStatus?.emoji : nil,
                gameIconURL: applicationIconURL(
                    activity?.applicationID, side: Metrics.voiceGameMark
                ),
                isStreaming: activity?.kind == .streaming,
                channelID: conversations.byUser[userID],
                // Folded once, here — §2. Both the display name and the handle,
                // because somebody with a name nobody can spell is found by
                // their handle and by nothing else.
                searchKey: QuickSwitchRank.fold(
                    (friendNicknames[userID] ?? user.preferredName) + " " + user.handle
                )
            )
            let band = group(
                status: status,
                activity: activity,
                isFavourite: favouriteUserIDs.contains(userID)
            )
            banded[band, default: []].append(person)
        }

        return OverlayPeopleGroup.allCases.compactMap { group in
            guard var people = banded[group] else { return nil }
            // **Sorted by name inside a band, never by status.** The bands
            // already carry the status, so sorting by it again would reorder
            // rows every time somebody idled — a list that reshuffles under the
            // pointer mid-game is worse than one that is a line out of date.
            people.sort {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return OverlayPeopleSection(id: group, people: people)
        }
    }

    /// Which band somebody belongs in.
    ///
    /// Favourites win outright: a favourite who is offline is still a favourite,
    /// and a list that moved them to the bottom would defeat the pin.
    ///
    /// **Banded on the activity, never on whether its picture resolved.** The
    /// first attempt keyed *In Game* on `gameIconURL != nil`, which is a fact
    /// about the application table rather than about the person — so a friend
    /// playing something this session had not resolved an icon for was banded
    /// Online, and would have moved bands when a fetch landed. What the band
    /// means is what they are doing.
    ///
    /// **And only a game counts.** `primaryActivity` is the first non-custom
    /// activity, which includes Spotify; a band called In Game with somebody's
    /// music in it is the heading saying something untrue.
    private func group(
        status: PresenceStatus,
        activity: Activity?,
        isFavourite: Bool
    ) -> OverlayPeopleGroup {
        if isFavourite { return .favorites }
        guard status.isOnline else { return .offline }
        return switch activity?.kind {
        case .playing, .streaming, .competing: .inGame
        default: .online
        }
    }

    /// The people behind the reader's favourited conversations.
    ///
    /// **The favourite is a bit on a channel, not on a person** — Discord calls
    /// it FAVORITED and stores it in the channel override — so the set is
    /// resolved through the conversation table rather than looked up per friend.
    private func favouriteFriendIDs(conversations: [UserID: ChannelID]) -> Set<UserID> {
        guard !pinnedChannelIDs.isEmpty else { return [] }
        var found: Set<UserID> = []
        for (userID, channelID) in conversations where pinnedChannelIDs.contains(channelID) {
            found.insert(userID)
        }
        return found
    }

    // MARK: Messages

    /// The conversations, newest first, and the person behind each one-to-one.
    ///
    /// **Both halves in one pass**, because the friends list needs the second
    /// and walking the private channels twice for it would be two passes over
    /// the account's whole DM list per rebuild.
    private func overlayConversations()
        -> (rows: [OverlayConversation], byUser: [UserID: ChannelID])
    {
        // The order is `ChannelIndex`'s own — recency, already maintained by
        // `patchLastMessage` — partitioned so favourites float. A stable
        // partition rather than a sort: favourites keep recency order among
        // themselves, which is what the DM list does one window over.
        var channelIDs = channelIndex.privateChannelIDs()
        if !pinnedChannelIDs.isEmpty {
            let pinned = pinnedChannelIDs
            channelIDs = channelIDs.filter { pinned.contains($0) }
                + channelIDs.filter { !pinned.contains($0) }
        }

        var rows: [OverlayConversation] = []
        rows.reserveCapacity(channelIDs.count)
        var byUser: [UserID: ChannelID] = [:]
        byUser.reserveCapacity(channelIDs.count)

        for channelID in channelIDs {
            guard let channel = channelIndex[channelID] else { continue }
            let partnerID = channel.kind == .directMessage
                ? channel.recipientIDs.first { $0 != currentUserID }
                : nil
            if let partnerID { byUser[partnerID] = channelID }
            // A conversation with somebody the reader has blocked is not one
            // they want offered over a game — §5.5, as a destination.
            if let partnerID, blockedUserIDs.contains(partnerID) { continue }

            let partner = partnerID.flatMap { users[$0] }
            let name = partnerID.flatMap { friendNicknames[$0] } ?? displayName(of: channel)
            let state = unreadState(of: channel)
            let avatarURL: URL? = switch channel.kind {
            case .directMessage:
                partner.flatMap { avatarURL(for: $0, side: Metrics.avatarRow) }
            case .groupDirectMessage:
                channel.iconHash.flatMap {
                    CDN.channelIcon(channelID: channelID, hash: $0, side: Metrics.avatarRow)
                }
            default:
                nil
            }

            rows.append(OverlayConversation(
                id: channelID,
                title: name,
                avatarURL: avatarURL,
                monogram: partner?.monogram ?? Self.monogram(of: name),
                status: partnerID.map { presences[$0]?.status ?? .offline },
                preview: overlayPreview(of: channelID) ?? partner.map { "@\($0.handle)" },
                isUnread: state.unread,
                mentionCount: state.mentions,
                isMuted: state.muted,
                isFavorite: pinnedChannelIDs.contains(channelID),
                searchKey: QuickSwitchRank.fold(name + " " + (partner?.handle ?? ""))
            ))
        }
        return (rows, byUser)
    }

    /// One line of the last thing said, for a conversation this session has
    /// actually opened.
    ///
    /// **Folded by the same function the reply header uses.** A second folder
    /// here would be a second answer to "what does this message say in one
    /// line", and the two would drift.
    private func overlayPreview(of channelID: ChannelID) -> String? {
        guard let message = messageBoxes[channelID]?.messages.last else { return nil }
        if !message.content.isEmpty {
            let line = MessageReference.excerpt(of: message.content)
            if !line.isEmpty { return line }
        }
        if !message.attachments.isEmpty { return "Sent an attachment" }
        if !message.stickers.isEmpty { return "Sent a sticker" }
        if !message.embeds.isEmpty { return "Sent a link" }
        return nil
    }

    // MARK: Voice

    /// The rooms with anybody in them, the reader's own first.
    ///
    /// **Rooms rather than channels**, which is the whole difference between
    /// this and the quick switcher's voice filter: an empty channel is a place
    /// somebody could go and a room with five people in it is a place somebody
    /// would go, and over a game only the second is worth a row.
    private func overlayRooms() -> [OverlayVoiceRoom] {
        var occupants: [ChannelID: [VoiceState]] = [:]
        for state in voiceStates.values {
            guard let channelID = state.channelID else { continue }
            // **A stage is not a voice channel**, and the tab says Voice. Joining
            // one puts you in an audience, suppressed, with a hand to raise —
            // which is a different act with a whole pane of its own in the
            // window. A row that said "join" and did that would be the list
            // answering a question nobody asked it.
            if channelIndex[channelID]?.kind == .stage { continue }
            occupants[channelID, default: []].append(state)
        }
        guard !occupants.isEmpty else { return [] }

        var rooms: [OverlayVoiceRoom] = []
        rooms.reserveCapacity(occupants.count)
        for (channelID, states) in occupants {
            guard let channel = channelIndex[channelID] else { continue }
            // A room the reader cannot see is not a room they can join — §5.5.
            guard channel.guildID == nil || permissionGate.canView(channelID) else { continue }
            let guild = channel.guildID.flatMap { guilds[$0] }
            // **Ordered by join time, which is what the id encodes.** Sorting
            // by name reshuffles the row whenever somebody is renamed, and
            // sorting by nothing reshuffles it on every dictionary rehash —
            // which reads as the faces twitching.
            let ordered = states.sorted { $0.userID.rawValue < $1.userID.rawValue }
            let limit = OverlayVoiceRoom.faceLimit
            rooms.append(OverlayVoiceRoom(
                id: channelID,
                name: displayName(of: channel),
                guildName: guild?.name,
                guildIconURL: guild.flatMap { guild in
                    guild.iconHash.flatMap {
                        CDN.guildIcon(guildID: guild.id, hash: $0, side: Metrics.avatarRow)
                    }
                },
                guildMonogram: guild?.monogram ?? Self.monogram(of: displayName(of: channel)),
                status: voiceChannelInfo[channelID]?.status,
                limit: channel.userLimit ?? 0,
                faces: ordered.prefix(limit).map { state in
                    OverlayVoiceFace(
                        id: state.userID,
                        avatarURL: avatarURL(
                            forUserID: state.userID,
                            inGuild: state.guildID,
                            side: Metrics.avatarInline
                        ),
                        monogram: users[state.userID]?.monogram ?? "?",
                        isStreaming: state.isStreaming
                    )
                },
                overflow: max(0, ordered.count - limit),
                isJoined: connectedVoiceChannelID == channelID,
                searchKey: QuickSwitchRank.fold(
                    displayName(of: channel) + " " + (guild?.name ?? "")
                )
            ))
        }

        // The reader's own room first, then the busiest — which is the order
        // somebody scanning for a room to join actually wants. Name breaks a
        // tie, so the list does not reshuffle on a dictionary rehash.
        rooms.sort { lhs, rhs in
            if lhs.isJoined != rhs.isJoined { return lhs.isJoined }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return rooms
    }
}
