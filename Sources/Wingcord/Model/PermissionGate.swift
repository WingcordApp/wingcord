import Foundation
import WingcordCore

/// Resolves and caches what the reader may do, everywhere.
///
/// **This is a correctness boundary, and it is also on the hottest path in the
/// app** — the channel list asks it per channel per rebuild, the composer asks
/// it per keystroke's worth of evaluation, and the guild badge asks it per
/// channel per unread pass. Those two facts pull in opposite directions, so the
/// design resolves them by splitting the work at the point where the inputs stop
/// changing:
///
///  1. **Base permissions** — the union of `@everyone` and every role the reader
///     holds in a guild — change only when the reader's roles or the guild's
///     roles change. Computed once per guild and cached.
///  2. **Channel permissions** are the base with that channel's own overwrites
///     applied. That is O(overwrites), typically zero to five entries, and it is
///     cached per channel.
///
/// So the steady state is a dictionary lookup, and a role change is one
/// invalidation rather than a re-walk of every role in the guild per row.
///
/// **Nothing here fails open.** Every unknown — a guild not loaded, a member
/// record not yet fetched, a channel whose guild is missing — resolves to *no*
/// permissions rather than to all of them. A permissive default shows the reader
/// channels they cannot open and a composer that will 403, which is worse than
/// showing nothing: it is showing something untrue.
@MainActor
final class PermissionGate {
    private unowned let model: AppModel

    /// Guild-level permissions for the reader, per guild.
    private var base: [GuildID: Permissions] = [:]
    /// Fully resolved per-channel permissions for the reader.
    private var channels: [ChannelID: Permissions] = [:]
    /// What the caches were built against. Any change discards them wholesale —
    /// a partial invalidation here is how a stale `viewChannel` survives a role
    /// change and leaks a private channel into the list.
    private var builtStructureRevision: UInt64 = .max
    private var builtRoleRevision: UInt64 = .max

    init(model: AppModel) {
        self.model = model
    }

    /// Discards everything. Called on any role, member or channel-structure
    /// change, on account switch, and when a preview starts or ends — a lurk
    /// changes every answer in one guild and the cache cannot see it happen.
    func invalidate() {
        base.removeAll(keepingCapacity: true)
        channels.removeAll(keepingCapacity: true)
        builtStructureRevision = .max
        builtRoleRevision = .max
    }

    /// Everything the reader may do in one channel.
    func permissions(in channelID: ChannelID) -> Permissions {
        refreshIfStale()
        if let cached = channels[channelID] { return cached }

        guard let channel = model.channelIndex[channelID] else { return [] }

        // A DM is not governed by guild permissions at all: both parties may
        // read and write, and there are no roles to resolve. Returning the
        // guild-resolved answer here would deny every DM, because there is no
        // guild to resolve against.
        guard let guildID = channel.guildID else {
            let resolved: Permissions = [
                .viewChannel, .sendMessages, .readMessageHistory, .addReactions,
                .attachFiles, .embedLinks, .useExternalEmojis, .useExternalStickers,
                .sendVoiceMessages,
                // A direct message has no roles to take this away, and the
                // capture proves it is granted: both interactions in
                // `Slash commands.har` were posted from one.
                .useApplicationCommands,
            ]
            channels[channelID] = resolved
            return resolved
        }

        guard let guild = model.guilds[guildID], let userID = model.currentUserID else {
            channels[channelID] = []
            return []
        }

        let memberRoles = model.members[guildID]?[userID]?.roleIDs ?? []
        // **A thread is resolved against its PARENT's overwrites.** A thread
        // carries none of its own — Discord's model is that it inherits the
        // channel it hangs off — so resolving against the thread itself finds an
        // empty overwrite list and hands back the reader's guild-level
        // permissions. That fails open: a thread inside a channel `@everyone` is
        // denied `viewChannel` on would resolve as *visible*.
        let governing = channel.kind.isThread
            ? channel.parentID.flatMap { model.channelIndex[$0] } ?? channel
            : channel
        let resolved = PermissionResolver.permissions(
            forMember: memberRoles,
            userID: userID,
            guildID: guildID,
            guildOwnerID: guild.ownerID,
            roles: model.roles[guildID] ?? [:],
            channel: governing
        ).intersection(lurkerMask(for: guildID, channel: governing))
        channels[channelID] = resolved
        return resolved
    }

    /// Everything a lurker keeps, or everything, for a server they are in.
    ///
    /// **The resolver cannot see this and must not try to.** A lurker has no
    /// member record, so it falls back to `@everyone` alone — which on most
    /// public servers grants `SEND_MESSAGES` and `ADD_REACTIONS`, and the
    /// resolver is right to answer that: those *are* `@everyone`'s permissions.
    /// What it does not know is that the reader is not one of them yet. That is
    /// a fact about the session, it lives on the store, and it is applied here
    /// where the two meet.
    ///
    /// An intersection rather than a subtraction, so a permission Discord adds
    /// next year is denied to a lurker without anybody remembering to add it —
    /// see `Permissions.lurker`.
    ///
    /// **Discord's own rule, and it is wider than previews** (module `316031`'s
    /// `w`): the mask applies to a member who is still *pending* — who has not
    /// yet agreed to a server's rules — exactly as it does to a lurker, and a
    /// public stage keeps its listeners' way in (`Permissions.publicStageLurker`).
    private func lurkerMask(for guildID: GuildID, channel: Channel? = nil) -> Permissions {
        let isLurking = model.guildPreview?.guildID == guildID
        let isPending = model.currentUserID.flatMap { model.members[guildID]?[$0]?.isPending } == true
        guard isLurking || isPending else { return .all }
        if let channel, channel.kind == .stage,
           model.stageInstances[channel.id]?.privacyLevel == .publicStage
        {
            return .publicStageLurker
        }
        return .lurker
    }

    /// Guild-level permissions, with no channel in the picture.
    func permissions(inGuild guildID: GuildID) -> Permissions {
        refreshIfStale()
        if let cached = base[guildID] { return cached }
        guard let guild = model.guilds[guildID], let userID = model.currentUserID else {
            base[guildID] = []
            return []
        }
        let resolved = PermissionResolver.permissions(
            forMember: model.members[guildID]?[userID]?.roleIDs ?? [],
            userID: userID,
            guildID: guildID,
            guildOwnerID: guild.ownerID,
            roles: model.roles[guildID] ?? [:],
            channel: nil
        ).intersection(lurkerMask(for: guildID))
        base[guildID] = resolved
        return resolved
    }

    // MARK: The questions the UI actually asks

    /// Whether the reader may give themselves a nickname in this server.
    ///
    /// **`CHANGE_NICKNAME`, and it is withheld more often than it looks.**
    /// Discord's own editor draws the name as a plain label with a padlock and
    /// the sentence "You don't have permission to change your nickname in this
    /// server." rather than a text field that refuses every keystroke — which is
    /// `INVARIANTS.md` §5.5, and the reason this question is asked before the
    /// field is drawn rather than after `PATCH /guilds/{id}/members/@me` answers
    /// 403.
    ///
    /// **Or `MANAGE_NICKNAMES`**, which covers everybody's nickname and so
    /// the reader's own — Discord's own check takes either. A moderator whose
    /// role grants only the second was shown a padlock over their own name.
    ///
    /// Guild-level rather than channel-level: a nickname is not scoped to a
    /// channel, so a permission resolved against one would be right by accident.
    func canChangeNickname(in guildID: GuildID) -> Bool {
        !permissions(inGuild: guildID).isDisjoint(with: [.changeNickname, .manageNicknames])
    }

    /// Whether a channel appears in the list at all.
    ///
    /// A category is visible when *any* of its children is — a category whose
    /// every channel is hidden is a heading over nothing, and Discord hides it.
    /// That test is made by the sidebar builder, which already has the children
    /// in hand; this answers only for the channel itself.
    func canView(_ channelID: ChannelID) -> Bool {
        permissions(in: channelID).contains(.viewChannel)
    }

    /// Whether the transcript loads.
    ///
    /// **A separate question from `canView`, and collapsing the two is a real
    /// bug.** Losing `viewChannel` hides the row; losing `readMessageHistory`
    /// leaves the row visible and the transcript empty, which is a state Discord
    /// has and which has to be shown as itself rather than as a channel that
    /// failed to load.
    func canReadHistory(_ channelID: ChannelID) -> Bool {
        let resolved = permissions(in: channelID)
        return resolved.contains(.viewChannel) && resolved.contains(.readMessageHistory)
    }

    /// Whether the composer is live.
    ///
    /// Threads gate on `sendMessagesInThreads` rather than `sendMessages`, which
    /// is a distinct bit — a server that lets people talk in channels but not in
    /// threads is a real configuration and a client that checks the wrong bit
    /// offers a composer that always fails.
    func canSend(in channelID: ChannelID) -> Bool {
        guard let channel = model.channelIndex[channelID] else { return false }
        let resolved = permissions(in: channelID)
        guard resolved.contains(.viewChannel) else { return false }

        // A timed-out member may not post anywhere in the guild, whatever their
        // roles say.
        if let guildID = channel.guildID,
           let userID = model.currentUserID,
           model.members[guildID]?[userID]?.isTimedOut() == true
        {
            return false
        }

        if channel.kind.isThread {
            // **A lock is for everyone but the moderators** — Discord's
            // "Only moderators can send messages." A moderator still writes
            // in a locked thread.
            if channel.threadMetadata?.isLocked == true, !resolved.contains(.manageThreads) {
                return false
            }
            return resolved.contains(.sendMessagesInThreads)
        }
        if channel.kind == .announcement {
            // An announcement channel is read-only to anyone without
            // `sendMessages`; the bit is the same, but the default is far more
            // often absent, so this is called out rather than folded in.
            return resolved.contains(.sendMessages)
        }
        return resolved.contains(.sendMessages)
    }

    /// Whether a file may be attached here.
    ///
    /// **Two bits, and posting is only the first of them.** `ATTACH_FILES` is
    /// what a server takes away to keep a channel to words while leaving
    /// everybody able to talk — so a composer that offers a `+` on `canSend`
    /// alone offers an upload that is refused after the bytes have gone up.
    /// `INVARIANTS.md` §5.5: a control that cannot work must not look like one
    /// that can.
    func canAttachFiles(in channelID: ChannelID) -> Bool {
        canSend(in: channelID) && permissions(in: channelID).contains(.attachFiles)
    }

    /// Whether a voice message may be sent here: its own bit, in a server. A
    /// conversation has no such switch, which `VoiceNoteEligibility` says.
    func canSendVoiceMessages(in channelID: ChannelID) -> Bool {
        canSend(in: channelID) && permissions(in: channelID).contains(.sendVoiceMessages)
    }

    /// Whether a poll may be posted here — Discord's `I7` (module `969632`).
    ///
    /// **`SEND_POLLS` is its own bit**, the one a server clears to keep polls
    /// out of a channel everybody may talk in; a conversation has no such
    /// switch. Every kind with a composer takes polls, so posting is the rest.
    func canPostPolls(in channelID: ChannelID) -> Bool {
        guard canSend(in: channelID), let channel = model.channelIndex[channelID] else { return false }
        return channel.guildID == nil || permissions(in: channelID).contains(.sendPolls)
    }

    /// Whether the reader may connect to a voice channel.
    ///
    /// **`CONNECT` is a real bit and it was never checked.** Every other write
    /// in the app is gated and this one was reached straight from the row —
    /// which was survivable while every channel on screen belonged to a server
    /// the reader had joined, and stops being so the moment a **previewed**
    /// server puts its voice channels in the list. A lurker holds
    /// `Permissions.lurker` and nothing else, so this answers false there by
    /// construction rather than by a second rule about previews.
    func canJoinVoice(_ channelID: ChannelID) -> Bool {
        let resolved = permissions(in: channelID)
        return resolved.contains(.viewChannel) && resolved.contains(.connect)
    }

    /// Whether `/` may open a command list here.
    ///
    /// **A separate bit from `sendMessages`, and it is genuinely separate**:
    /// `USE_APPLICATION_COMMANDS` is what a server takes away to stop a channel
    /// filling with bot output while leaving everybody able to talk. Gating the
    /// list on posting alone would open it in exactly the channels where every
    /// command is refused.
    ///
    /// Being able to post is still required on top of it — a command posts an
    /// interaction into this channel, and a reader who cannot write here cannot
    /// make a bot write here either.
    func canUseCommands(in channelID: ChannelID) -> Bool {
        canSend(in: channelID) && permissions(in: channelID).contains(.useApplicationCommands)
    }

    /// Everything the reader may do to one message, in one value.
    ///
    /// **One resolution per message rather than a predicate per menu item.**
    /// The hover pill, the menu, the reaction chips and the keyboard all ask
    /// the same question about the same row; asking it eight times is eight
    /// walks of the same bitfield for one answer that cannot differ between
    /// them. `MessageActionPolicy` is the rules, this is the lookup that feeds
    /// them — and the split is what makes the policy checkable against a table
    /// of cases with no store in the picture.
    /// Whether a new reaction may be started anywhere in this channel — the
    /// add control at the end of every reaction row. Nothing in the rule is
    /// about the message, so the canvas asks once per channel rather than per
    /// row.
    func canAddReaction(in channelID: ChannelID) -> Bool {
        let guildID = model.channelIndex[channelID]?.guildID
        return MessageActionPolicy.canAddReaction(
            permissions: permissions(in: channelID),
            isTimedOut: isTimedOut(in: guildID),
            isPreviewing: guildID != nil && guildID == model.guildPreview?.guildID
        )
    }

    func actions(for message: Message) -> MessageActions {
        let channel = model.channelIndex[message.channelID]
        let guildID = channel?.guildID
        return MessageActionPolicy.resolve(
            MessageActionPolicy.Input(
                permissions: permissions(in: message.channelID),
                canSend: canSend(in: message.channelID),
                isAuthor: message.authorID == model.currentUserID,
                isTimedOut: isTimedOut(in: guildID),
                isSystemEvent: message.isSystemEvent,
                hasText: !message.content.isEmpty,
                isPinned: message.isPinned,
                isDirectMessage: channel?.kind.isPrivate ?? false,
                isPreviewing: guildID != nil && guildID == model.guildPreview?.guildID,
                isBookmarked: model.bookmarkedMessageIDs.contains(message.id),
                developerMode: AppSettings.shared.developerMode,
                hasReactions: !message.reactions.isEmpty,
                isInLockedArchive: channel?.threadMetadata.map { $0.isArchived && $0.isLocked } ?? false,
                canStartThread: channel.map {
                    ThreadCreation.canCreatePublic(in: $0, permissions: permissions(in: message.channelID), from: message)
                } ?? false
            )
        )
    }

    /// Whether the reader is serving a timeout in this guild.
    ///
    /// A timed-out member may not post, react or pin anywhere in the server,
    /// whatever their roles say — so this is checked once and folded into every
    /// answer rather than remembered at each call site.
    private func isTimedOut(in guildID: GuildID?) -> Bool {
        guard let guildID, let userID = model.currentUserID else { return false }
        return model.members[guildID]?[userID]?.isTimedOut() == true
    }

    // MARK: Staleness

    private func refreshIfStale() {
        let structure = model.channelIndex.structureRevision
        let roles = model.roleRevision
        guard structure != builtStructureRevision || roles != builtRoleRevision else {
            return
        }
        base.removeAll(keepingCapacity: true)
        channels.removeAll(keepingCapacity: true)
        builtStructureRevision = structure
        builtRoleRevision = roles
    }
}
