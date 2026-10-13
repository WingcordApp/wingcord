import CoreGraphics
import Foundation
import WingcordCore

// MARK: - What a reader can do to a conversation
//
// Half of this menu is about the *channel* — pin it, mute it, mark it read,
// close it — and half is about whoever is in it, which `AppModel+Relationships`
// already owns. The split is why the request carries a channel and an optional
// person rather than a person and a channel: a group direct message is the
// first half with nothing at all in the second.
//
// Every write here is optimistic and reverted by the controller on a refusal,
// which is the rule the rest of the store follows: a state that arrives a round
// trip after the click reads as the click having missed.

extension AppModel {

    /// Raises the conversation's menu beside the row that asked for it.
    func openDirectMessageMenu(for channelID: ChannelID, anchor: CGRect, callUserID: UserID? = nil) {
        guard let channel = channelIndex[channelID], channel.kind.isPrivate else { return }
        dismissMessageSurfaces()
        directMessageMenu = DirectMessageMenuRequest(
            channelID: channelID,
            // The other person, and only for a one-to-one. A group has several,
            // so it has none — see `DirectMessageActions.userID`.
            userID: channel.kind == .directMessage
                ? channel.recipientIDs.first { $0 != currentUserID }
                : nil,
            anchor: anchor,
            callUserID: callUserID
        )
    }

    func dismissDirectMessageMenu() {
        if directMessageMenu != nil { directMessageMenu = nil }
    }

    /// Everything the conversation's menu needs, resolved once.
    ///
    /// Nil for a channel that is not a private one, which is the same guard
    /// `openDirectMessageMenu` applies — a menu built for a server channel
    /// would offer Close DM on a room somebody else owns.
    func directMessageActions(for channelID: ChannelID) -> DirectMessageActions? {
        guard let channel = channelIndex[channelID], channel.kind.isPrivate else { return nil }
        let userID = channel.kind == .directMessage
            ? channel.recipientIDs.first { $0 != currentUserID }
            : nil
        let state = unreadState(of: channel)
        return DirectMessageActions(
            channelID: channelID,
            userID: userID,
            name: displayName(of: channel),
            isGroup: channel.kind == .groupDirectMessage,
            isUnread: state.unread,
            isPinned: pinnedChannelIDs.contains(channelID),
            isPinBusy: pinsInFlight.contains(channelID),
            isMuted: state.muted,
            // **Friends only, and Discord's rule rather than this client's.**
            // The route refuses a nickname on anybody else, so offering the row
            // would be offering a control that cannot work — §5.5.
            nickname: userID.flatMap { friendNicknames[$0] },
            canRename: userID.map { relationship(with: $0) == .friend } ?? false,
            note: userID.flatMap { notes[$0] },
            person: userID.flatMap { userActions(for: $0) },
            developerMode: AppSettings.shared.developerMode
        )
    }

    /// What to call a conversation.
    ///
    /// **The reader's own name for somebody beats everything.** A friend
    /// nickname is a private renaming the account carries, and it is the whole
    /// point of it that it wins over the display name they chose — see
    /// `friendNicknames`.
    func preferredName(of userID: UserID, fallback: String) -> String {
        friendNicknames[userID] ?? fallback
    }

    // MARK: Pinning

    /// Pins a conversation to the top of the list, or unpins it.
    ///
    /// **It carries to Discord**, which is the whole reason this is a route and
    /// not a local set: the bit lives on the reader's channel override and the
    /// web client reads the same one. See
    /// `DiscordREST.setDirectMessagePinned`.
    func setDirectMessagePinned(_ isPinned: Bool, channelID: ChannelID) {
        guard channelIndex[channelID]?.kind.isPrivate == true else { return }
        guard pinsInFlight.insert(channelID).inserted else { return }
        if isPinned {
            pinnedChannelIDs.insert(channelID)
        } else {
            pinnedChannelIDs.remove(channelID)
        }
        sessionController.writeDirectMessagePin(isPinned, channelID: channelID)
    }

    /// Replaces the pinned set with the one the route answered with.
    ///
    /// **The reply is the whole truth, not a delta** — an override with nothing
    /// left on it is dropped by the server — so this assigns rather than
    /// merges, and it is also what rolls an optimistic write back after a
    /// refusal.
    func applyPinnedChannels(_ pinned: Set<ChannelID>) {
        guard pinnedChannelIDs != pinned else { return }
        pinnedChannelIDs = pinned
    }

    // MARK: Muting

    /// Mutes a conversation for a while, or takes the mute off.
    func setDirectMessageMuted(_ duration: MuteDuration?, channelID: ChannelID) {
        guard channelIndex[channelID]?.kind.isPrivate == true else { return }
        applyChannelMute(duration != nil, channelID: channelID)
        sessionController.writeDirectMessageMute(duration, channelID: channelID)
    }

    /// Writes a channel's mute into the two places that read it.
    ///
    /// **Both, or the sidebar and the notification policy disagree.** The row
    /// draws from the read state and the banner decision comes from
    /// `notificationPreferences`; a mute written to one of them is a
    /// conversation that looks muted and still interrupts.
    func applyChannelMute(_ isMuted: Bool, channelID: ChannelID) {
        if isMuted {
            notificationPreferences.mutedChannelIDs.insert(channelID)
        } else {
            notificationPreferences.mutedChannelIDs.remove(channelID)
        }
        if readStates[channelID]?.isMuted != isMuted {
            readStates[channelID]?.isMuted = isMuted
        }
        sidebarRevision &+= 1
    }

    // MARK: Closing

    /// Closes a conversation.
    ///
    /// **Not destructive, and that is why there is no confirmation.** A private
    /// channel is closed for the reader alone; the transcript stays on
    /// Discord's side and comes back with the conversation. The row goes
    /// immediately and `CHANNEL_DELETE` confirms it.
    func closeDirectMessage(_ channelID: ChannelID) {
        guard channelIndex[channelID]?.kind.isPrivate == true else { return }
        dismissDirectMessageMenu()
        // Step off it first: a reader looking at the conversation they just
        // closed would be left on a transcript with no row in the list.
        if selectedChannelID == channelID { selectedChannelID = nil }
        sessionController.writeCloseDirectMessage(channelID)
    }

    // MARK: Renaming

    /// Names a friend the way the reader wants to see them, or clears it.
    ///
    /// Nothing is sent for a name that did not change: the field commits on
    /// blur, and opening the editor and closing it would otherwise be a request
    /// per look — the same rule `setNote` follows.
    func setFriendNickname(_ nickname: String?, for userID: UserID) {
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard next != friendNicknames[userID] else { return }
        friendNicknames[userID] = next
        identityRevision &+= 1
        sessionController.writeFriendNickname(next, for: userID)
    }

    /// Applies a rename that arrived from the wire, or rolls one back.
    func applyFriendNickname(_ nickname: String?, for userID: UserID) {
        guard friendNicknames[userID] != nickname else { return }
        friendNicknames[userID] = nickname
        identityRevision &+= 1
        sidebarRevision &+= 1
    }
}

/// Everything the conversation menu offers, resolved once.
///
/// A plain value, so the menu holds no model reference and the container that
/// reads the store is the only thing that invalidates — §2.
struct DirectMessageActions: Hashable, Sendable {
    var channelID: ChannelID
    /// The other person. Nil for a group, which is what removes every row in
    /// the menu that is about a person rather than about the conversation.
    var userID: UserID?
    var name: String
    var isGroup: Bool
    var isUnread: Bool
    var isPinned: Bool
    var isPinBusy: Bool
    var isMuted: Bool
    /// What the reader has privately decided to call them, when they have.
    var nickname: String?
    /// Whether a nickname may be set at all — Discord offers it on friends
    /// only, and the route refuses anybody else.
    var canRename: Bool
    var note: String?
    /// The person half of the menu: block, ignore, friend, invite. Nil for a
    /// group and for the reader themselves.
    var person: UserActions?
    var developerMode: Bool
}
