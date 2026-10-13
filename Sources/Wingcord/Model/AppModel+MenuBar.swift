import Foundation
import WingcordCore

// MARK: - What the menu bar acts on
//
// The menu bar has no selection of its own: every item acts on where the
// reader is — the open channel, its newest message, the person a direct
// message is with. These are those answers, and the few acts that exist only
// because the menu bar offers them (DESIGN-NOTES §10.1).

/// Where the reader is, as the menu bar reads it.
///
/// **A snapshot, taken when the reader moves, and nothing the menus read
/// changes more often than that.** SwiftUI rebuilds the whole menu bar
/// whenever anything its `Commands` body read changes — while a menu is open
/// as well — and the first build of these menus read the open channel's
/// message list, the rail (which moves on every inbound message in the
/// account) and the member table. In a busy account that rebuilt every menu
/// several times a second under the pointer: items vanished and dropdowns
/// flickered shut. Taken in `selectedChannelID`'s observer instead, outside
/// any view's tracking, the reads here register nothing.
nonisolated struct MenuContext: Equatable, Sendable {
    var channelID: ChannelID?
    var guildID: GuildID?
    var parentID: ChannelID?
    var kind: ChannelKind?
    /// The person a one-to-one direct message is with.
    var recipientID: UserID?
    /// Whether the reader may make and delete channels in this server.
    var canManageChannels = false
    /// Whether the reader may invite people to this server channel.
    var canInvite = false
    /// The servers the person a direct message is with can be invited to —
    /// the person menu's Invite to Server list, taken with the rest.
    var inviteGuilds: [InvitableGuild] = []
    /// Channel › Recents — see `AppModel.recentsForMenu`.
    var recentChannels: [QuickSwitchRow] = []
    var draftChannels: [QuickSwitchRow] = []
    /// Whether the session is up — the menus' stand-in for `canNavigate`,
    /// which reads the rail.
    var isReady = false

    var isConversation: Bool { kind?.isConversation == true }
    var isPrivate: Bool { kind?.isPrivate == true }
    var showsPins: Bool { isConversation && kind != .voice }
    var showsThreads: Bool { kind == .text || kind == .announcement || kind == .forum }
    /// A voice or stage channel: a call, whose bar has no search and no
    /// roster — `WorkspacePresentation.Primary.isCall`.
    var isCall: Bool { kind == .voice || kind == .stage }
    var showsVoiceChat: Bool { isCall }
    var canStartCall: Bool { isPrivate }
}

extension AppModel {
    /// Retakes `menuContext`. Equal snapshots are not written, because an
    /// observable property written with its own value still invalidates every
    /// reader.
    func refreshMenuContext() {
        let channel = selectedChannelID.flatMap { channelIndex[$0] }
        var next = MenuContext()
        next.channelID = channel?.id
        next.guildID = channel?.guildID
        next.parentID = channel?.parentID
        next.kind = channel?.kind
        next.recipientID = channel?.kind == .directMessage ? channel?.recipientIDs.first : nil
        next.canManageChannels = channel?.guildID.map {
            permissionGate.permissions(inGuild: $0).contains(.manageChannels)
        } ?? false
        next.canInvite = channel.map {
            $0.guildID != nil && permissionGate.permissions(in: $0.id).contains(.createInvite)
        } ?? false
        next.inviteGuilds = next.recipientID.map { invitableGuilds(for: $0) } ?? []
        (next.recentChannels, next.draftChannels) = recentsForMenu()
        next.isReady = connectionState == .ready
        if next != menuContext { menuContext = next }
    }

    /// The open channel, if it is one.
    var openChannel: Channel? {
        selectedChannelID.flatMap { channelIndex[$0] }
    }

    /// The newest message in the open channel.
    var latestMessageInOpenChannel: Message? {
        selectedChannelID.flatMap { messages(in: $0)?.messages.last }
    }

    /// The reader's own newest message in the open channel: the one Edit and
    /// Delete Last Message mean, as Up in an empty composer does in Discord.
    var latestOwnMessageInOpenChannel: Message? {
        guard let channelID = selectedChannelID, let currentUserID else { return nil }
        return messages(in: channelID)?.messages.last { $0.authorID == currentUserID }
    }

    /// The open channel's link, as Discord writes it.
    var openChannelLink: String? {
        guard let channel = openChannel else { return nil }
        let place = channel.guildID.map { String($0.rawValue) } ?? "@me"
        return "https://discord.com/channels/\(place)/\(channel.id.rawValue)"
    }

    /// Up in an empty composer, and Edit › Edit Last Message — Discord's
    /// `getLastEditableMessage`: the reader's newest message they may edit.
    ///
    /// **Unless a slash command of theirs is newer**, which Discord recalls
    /// into the box instead; this client cannot rebuild one yet, so it does
    /// nothing rather than edit an older message. False when nothing was
    /// done, so Up falls through to the caret.
    @discardableResult
    func editLatestOwnMessage(in channelID: ChannelID) -> Bool {
        guard let currentUserID, let messages = messages(in: channelID)?.messages else { return false }
        guard let editable = messages.last(where: {
            $0.authorID == currentUserID && permissionGate.actions(for: $0).contains(.edit)
        }) else { return false }
        let command = messages.last {
            $0.interaction?.userID == currentUserID && $0.interaction?.commandType == 1
        }
        if let command, command.id > editable.id { return false }
        beginEdit(of: editable.id, in: channelID)
        return true
    }

    func deleteLatestOwnMessage() {
        guard let channelID = selectedChannelID, let message = latestOwnMessageInOpenChannel else { return }
        requestDelete(of: message.id, in: channelID)
    }

    func forwardLatestMessage() {
        guard let channelID = selectedChannelID, let message = latestMessageInOpenChannel else { return }
        requestForward(of: message.id, in: channelID)
    }

    /// Pins the newest message, or unpins it if it already is — the item's
    /// title says which.
    func togglePinOnLatestMessage() {
        guard let channelID = selectedChannelID, let message = latestMessageInOpenChannel else { return }
        applyPin(!message.isPinned, messageID: message.id, in: channelID)
    }

    /// The open server's menu on one of its pages — Channel › Invite to and
    /// Manage Server Notifications. See `serverMenuPageRequest`.
    func openServerMenuFromMenuBar(page: ServerOptionsMenu.Surface, inviteChannelID: ChannelID? = nil) {
        guard let guildID = menuContext.guildID else { return }
        serverMenuPageRequest = ServerMenuPageRequest(guildID: guildID, page: page, inviteChannelID: inviteChannelID)
    }

    /// Asks the open channel's composer for the file picker. The composer owns
    /// the picker, because it is the one view anchored to the window; this is
    /// the same request-and-take pattern the sticker picker uses.
    func requestFileImport() {
        guard let channelID = selectedChannelID else { return }
        fileImportRequest = channelID
    }

    /// Mutes the open channel for a while, or until it is turned back on —
    /// whichever kind of channel it is.
    func muteOpenChannel(for duration: MuteDuration) {
        guard let channel = openChannel else { return }
        if channel.kind.isPrivate {
            setDirectMessageMuted(duration, channelID: channel.id)
        } else if channel.kind.isThread {
            setThreadMute(duration, threadID: channel.id)
        } else if let guildID = channel.guildID {
            applyGuildSetting(.channelMuted(channel.id, duration), in: guildID)
        }
    }

    /// Sets the open server channel's notification level.
    func setOpenChannelNotificationLevel(_ level: MessageNotificationLevel) {
        guard let channel = openChannel, let guildID = channel.guildID else { return }
        applyGuildSetting(.channelLevel(channel.id, level), in: guildID)
    }

    /// Back into the voice channel the reader last left.
    func rejoinLastVoiceChannel() {
        guard connectedVoiceChannelID == nil, let channelID = lastVoiceChannelID else { return }
        joinVoice(channelID)
    }
}
