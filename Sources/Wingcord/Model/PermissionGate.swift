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
                .attachFiles, .embedLinks, .useExternalEmojis, .sendVoiceMessages,
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
        ).intersection(lurkerMask(for: guildID))
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
    private func lurkerMask(for guildID: GuildID) -> Permissions {
        model.guildPreview?.guildID == guildID ? .lurker : .all
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
                developerMode: AppSettings.shared.developerMode
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
