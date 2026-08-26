import Foundation
import OSLog
import WingcordCore
import WingcordNet

/// Owns the connection and applies what it delivers to the store.
///
/// **The store never talks to the network and the network never touches the
/// store.** Everything crosses here, in one direction, which is what makes the
/// store constructible in a test and the network layer usable off the main
/// actor.
///
/// The apply path is written for one property: **a gateway event costs one
/// main-actor hop and one observation invalidation, not one per field.** A
/// presence flush on a large server carries hundreds of entries; applying them
/// one at a time would publish hundreds of changes and re-evaluate every view
/// observing presences on each. They are merged into the table and the revision
/// is bumped once.
@MainActor
final class SessionController {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Session")

    private unowned let model: AppModel
    private let metadata = ClientMetadata()
    private let rest: DiscordREST
    private var socket: GatewaySocket?
    private var eventTask: Task<Void, Never>?
    private var isTornDown = false

    /// Presence updates arriving between flushes.
    ///
    /// **Coalesced deliberately.** A large guild delivers presence changes
    /// several times a second and the roster's answer changes on almost none of
    /// them. Buffering for a beat and applying once turns a hundred
    /// invalidations into one, and the cost is that someone's dot goes green up
    /// to a fifth of a second late — which nobody has ever noticed.
    private var pendingPresences: [UserID: Presence] = [:]
    private var presenceFlushTask: Task<Void, Never>?
    private static let presenceFlushInterval = Duration.milliseconds(200)

    init(model: AppModel) {
        self.model = model
        rest = DiscordREST(metadata: metadata)
    }

    // MARK: Lifecycle

    /// Validates a freshly obtained token, stores it, and connects.
    ///
    /// **Validation comes before storage.** A token that never worked, written
    /// to the Keychain, is retried on every launch forever — and the app cannot
    /// tell "offline" from "this credential is dead".
    func beginSession(token: String) {
        model.connectionState = .connecting
        Task { [weak self] in
            guard let self else { return }
            do {
                await rest.setToken(token)
                let user = try await rest.currentUser()
                try TokenStore.store(token, forAccount: user.id.description)
                AccountLedger.upsert(StoredAccount(
                    id: user.id.description,
                    username: user.handle,
                    displayName: user.displayName,
                    avatarHash: user.avatarHash
                ))
                connect(token: token)
            } catch DiscordREST.Failure.unauthorized {
                model.connectionState = .failed("That sign-in did not produce a usable token.")
            } catch {
                model.connectionState = .failed(Self.describe(error))
            }
        }
    }

    /// Reconnects with a token already in the Keychain.
    func resumeSession(for account: StoredAccount) {
        guard let token = TokenStore.token(forAccount: account.id) else {
            AccountLedger.remove(account.id)
            model.connectionState = .failed("No stored credential for that account.")
            return
        }
        model.connectionState = .connecting
        Task { [weak self] in
            guard let self else { return }
            await rest.setToken(token)
            do {
                _ = try await rest.currentUser()
                connect(token: token)
            } catch DiscordREST.Failure.unauthorized {
                // A 401 on a stored account drops just that account and leaves
                // every other one alone.
                AccountLedger.remove(account.id)
                model.connectionState = .failed("That account's session expired. Sign in again.")
            } catch {
                model.connectionState = .failed(Self.describe(error))
            }
        }
    }

    private func connect(token: String) {
        teardownConnection()
        isTornDown = false
        let socket = GatewaySocket(metadata: metadata)
        self.socket = socket
        model.historyLoader = { [weak self] channelID, before in
            self?.loadHistory(in: channelID, before: before)
        }

        eventTask = Task { [weak self] in
            await socket.connect(token: token)
            guard let stream = await socket.events else { return }
            for await event in stream {
                guard let self, !self.isTornDown else { return }
                self.apply(event)
            }
        }
    }

    /// Closes the connection and clears everything belonging to the account.
    ///
    /// **One funnel.** Anything cleared by "sign out then relaunch" has to be
    /// cleared here too, because a switch keeps the process — and every
    /// per-account table left standing gets answered from the previous account:
    /// presences against invisible ids, cached rosters, folders, and every badge
    /// derived from them.
    func signOut() {
        teardownConnection()
        model.currentUserID = nil
        model.mentionableIDs = []
        model.guilds = [:]
        model.channelIndex = ChannelIndex()
        model.users = [:]
        model.members = [:]
        model.roles = [:]
        model.presences = [:]
        model.readStates = [:]
        model.folders = []
        model.expandedFolderIDs = []
        model.collapsedCategoryIDs = []
        model.selectedGuildID = nil
        model.selectedChannelID = nil
        model.lastChannelByGuild = [:]
        model.clearAllMessages()
        model.railCache = nil
        model.sidebarCache = nil
        model.timelineCache = nil
        model.rosterCache = nil
        model.permissionGate.invalidate()
        model.connectionState = .signedOut
        ImageStore.shared.purge()
        Task { await rest.setToken(nil) }
    }

    private func teardownConnection() {
        isTornDown = true
        eventTask?.cancel()
        eventTask = nil
        presenceFlushTask?.cancel()
        presenceFlushTask = nil
        pendingPresences.removeAll(keepingCapacity: false)
        model.historyLoader = nil
        if let socket {
            Task { await socket.stop() }
        }
        socket = nil
    }

    // MARK: Applying

    private func apply(_ event: GatewaySocket.Event) {
        switch event {
        case .connecting:
            if model.connectionState != .ready { model.connectionState = .connecting }
        case .ready(let snapshot):
            applyReady(snapshot)
        case .resumed:
            model.connectionState = .ready
        case .update(let update):
            apply(update)
        case .disconnected(_, let willRetry):
            model.connectionState = willRetry ? .reconnecting : .signedOut
        case .authenticationFailed:
            if let userID = model.currentUserID {
                AccountLedger.remove(userID.description)
            }
            signOut()
            model.connectionState = .failed("The session expired. Sign in again.")
        }
    }

    /// Installs the bootstrap payload.
    ///
    /// One assignment per table and **one bump per revision**, at the end. Every
    /// intermediate write would publish a change that every view observing that
    /// table would answer, and READY writes every table there is.
    private func applyReady(_ snapshot: ReadySnapshot) {
        var index = ChannelIndex()
        for guild in snapshot.guilds {
            index.replaceChannels(
                snapshot.channelsByGuild[guild.id] ?? [],
                inGuild: guild.id
            )
        }
        index.replacePrivateChannels(snapshot.privateChannels)

        var guilds: [GuildID: Guild] = [:]
        guilds.reserveCapacity(snapshot.guilds.count)
        for guild in snapshot.guilds { guilds[guild.id] = guild }

        var readStates = snapshot.readStates
        for channelID in snapshot.mutedChannelIDs {
            readStates[channelID, default: ReadState()].isMuted = true
        }

        model.currentUserID = snapshot.currentUser.id
        model.users = snapshot.users
        model.guilds = guilds
        model.channelIndex = index
        model.roles = snapshot.rolesByGuild
        model.members = snapshot.membersByGuild
        model.presences = snapshot.presences
        model.readStates = readStates
        model.folders = Self.railOrder(
            settingsFolders: snapshot.settings.folders,
            guilds: snapshot.guilds
        )
        model.selfStatus = snapshot.settings.status
        model.selfCustomStatus = snapshot.settings.customStatus
        model.mutedGuildIDs = snapshot.mutedGuildIDs

        // Every role the reader holds, plus their own id, as one flat set. A
        // mention test is then one lookup rather than a scan over roles per
        // message per evaluation.
        var mentionable: Set<UInt64> = [snapshot.currentUser.id.rawValue]
        for (guildID, table) in snapshot.membersByGuild {
            guard let member = table[snapshot.currentUser.id] else { continue }
            for roleID in member.roleIDs { mentionable.insert(roleID.rawValue) }
            _ = guildID
        }
        model.mentionableIDs = mentionable

        model.permissionGate.invalidate()
        model.railCache = nil
        model.sidebarCache = nil
        model.rosterCache = nil
        model.railRevision &+= 1
        model.sidebarRevision &+= 1
        model.roleRevision &+= 1
        model.memberRevision &+= 1
        model.presenceRevision &+= 1
        model.identityRevision &+= 1
        model.connectionState = .ready

        restoreNavigation()
    }

    /// The rail's order.
    ///
    /// Discord's settings only list guilds the account has *arranged*. Anything
    /// joined since — and on a fresh account, everything — is absent, so a rail
    /// built from the settings alone silently hides servers. The missing ones go
    /// on the end, which is where Discord puts them.
    private static func railOrder(
        settingsFolders: [GuildFolder],
        guilds: [Guild]
    ) -> [GuildFolder] {
        var placed = Set<GuildID>()
        var result: [GuildFolder] = []
        for folder in settingsFolders {
            let present = folder.guildIDs.filter { id in guilds.contains { $0.id == id } }
            guard !present.isEmpty else { continue }
            placed.formUnion(present)
            result.append(GuildFolder(
                id: folder.id,
                name: folder.name,
                colorValue: folder.colorValue,
                guildIDs: present
            ))
        }
        for guild in guilds where !placed.contains(guild.id) {
            result.append(GuildFolder(guildIDs: [guild.id]))
        }
        return result
    }

    private func restoreNavigation() {
        guard model.selectedChannelID == nil else { return }
        // The first guild in rail order with a channel the reader can actually
        // open. Not simply the first guild: landing on a server whose every
        // channel is private shows an empty window on launch.
        for item in model.railItems {
            let candidates: [RailGuild] = switch item {
            case .guild(let guild): [guild]
            case .folder(let folder): folder.guilds
            }
            for candidate in candidates {
                let channelID = model.channelIndex
                    .channelIDs(inGuild: candidate.id)
                    .first {
                        (model.channelIndex[$0]?.kind.isConversation ?? false)
                            && model.permissionGate.canView($0)
                    }
                guard let channelID else { continue }
                model.selectedGuildID = candidate.id
                model.selectChannel(channelID)
                return
            }
        }
    }

    private func apply(_ update: GatewayUpdate) {
        switch update {
        case .messageCreated(let message, let author, _, _):
            model.users[author.id] = author
            model.mutateBox(message.channelID) { $0.upsert(message) }
            model.channelIndex.patchLastMessage(message.id, in: message.channelID)
            model.messageContentRevision &+= 1
            bumpUnread(for: message)

        case .messageUpdated(let message):
            // An edit arrives as a PARTIAL message: only the fields that changed
            // are present, so replacing wholesale drops the attachments and
            // reactions the edit did not mention. Merge onto what is held.
            model.mutateBox(message.channelID) { box in
                guard let index = box.messages.firstIndex(where: { $0.id == message.id }) else {
                    return
                }
                var merged = box.messages[index]
                merged.content = message.content
                merged.editedAt = message.editedAt
                merged.flags = message.flags
                if let payload = message.payload { merged.payload = payload }
                box.messages[index] = merged
            }
            model.messageContentRevision &+= 1

        case .messageDeleted(let messageID, let channelID):
            model.mutateBox(channelID) { $0.remove(messageID) }
            model.messageContentRevision &+= 1

        case .reactionAdded(let messageID, let channelID, let emoji, let userID):
            model.applyReaction(
                emoji, to: messageID, in: channelID, added: true,
                isMine: userID == model.currentUserID
            )

        case .reactionRemoved(let messageID, let channelID, let emoji, let userID):
            model.applyReaction(
                emoji, to: messageID, in: channelID, added: false,
                isMine: userID == model.currentUserID
            )

        case .guildAvailable(let guild, let channels, let roles, let members, let users, let presences):
            model.guilds[guild.id] = guild
            model.channelIndex.replaceChannels(channels, inGuild: guild.id)
            model.roles[guild.id] = roles
            if !members.isEmpty { model.members[guild.id] = members }
            model.users.merge(users) { _, new in new }
            model.presences.merge(presences) { _, new in new }
            model.permissionGate.invalidate()
            model.railRevision &+= 1
            model.sidebarRevision &+= 1
            model.roleRevision &+= 1
            model.memberRevision &+= 1

        case .guildUpdated(let guild):
            model.guilds[guild.id] = guild
            model.railRevision &+= 1
            model.sidebarRevision &+= 1

        case .guildRemoved(let guildID, let wasLeft):
            guard wasLeft else { return }
            model.guilds[guildID] = nil
            model.roles[guildID] = nil
            model.members[guildID] = nil
            model.folders = model.folders.compactMap { folder in
                let remaining = folder.guildIDs.filter { $0 != guildID }
                return remaining.isEmpty
                    ? nil
                    : GuildFolder(
                        id: folder.id, name: folder.name,
                        colorValue: folder.colorValue, guildIDs: remaining
                    )
            }
            if model.selectedGuildID == guildID {
                model.selectedGuildID = nil
                model.selectedChannelID = nil
            }
            model.permissionGate.invalidate()
            model.railRevision &+= 1
            model.roleRevision &+= 1

        case .channelUpserted(let channel):
            model.channelIndex.upsert(channel)
            model.permissionGate.invalidate()
            model.sidebarRevision &+= 1
            model.roleRevision &+= 1

        case .channelRemoved(let channelID):
            model.channelIndex.remove(channelID)
            if model.selectedChannelID == channelID { model.selectedChannelID = nil }
            model.sidebarRevision &+= 1

        case .presenceUpdated(let presence):
            enqueue(presence)

        case .typingStarted(let channelID, let userID, let at):
            model.mutateBox(channelID) {
                // Discord's own indicator expires after ten seconds with no
                // further signal, and matching that is what stops a "typing…"
                // from a closed tab hanging on the composer forever.
                $0.typing[userID] = at.addingTimeInterval(10)
            }

        case .membersChunk(let guildID, let members, let users, let presences),
             .memberListUpdated(let guildID, let members, let users, let presences):
            guard !members.isEmpty else { return }
            model.members[guildID, default: [:]].merge(members) { _, new in new }
            model.users.merge(users) { _, new in new }
            model.presences.merge(presences) { _, new in new }
            model.permissionGate.invalidate()
            model.memberRevision &+= 1
            model.presenceRevision &+= 1
            model.roleRevision &+= 1

        case .channelAcknowledged(let channelID, let messageID, let mentionCount):
            model.readStates[channelID, default: ReadState()].lastAcknowledgedID = messageID
            model.readStates[channelID, default: ReadState()].mentionCount = mentionCount
            model.sidebarRevision &+= 1
            model.railRevision &+= 1

        case .currentUserUpdated(let user):
            model.users[user.id] = user
            model.identityRevision &+= 1
        }
    }

    private func bumpUnread(for message: Message) {
        guard message.channelID != model.selectedChannelID else {
            // The reader is looking at it. Acknowledge rather than counting an
            // unread nobody will ever clear.
            acknowledge(message.id, in: message.channelID)
            return
        }
        var state = model.readStates[message.channelID] ?? ReadState()
        if message.mentionsEveryone
            || message.mentionedUserIDs.contains(where: { model.mentionableIDs.contains($0.rawValue) })
        {
            state.mentionCount += 1
        }
        model.readStates[message.channelID] = state
        model.sidebarRevision &+= 1
        model.railRevision &+= 1
    }

    // MARK: Presence coalescing

    private func enqueue(_ presence: Presence) {
        pendingPresences[presence.userID] = presence
        guard presenceFlushTask == nil else { return }
        presenceFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.presenceFlushInterval)
            guard let self, !Task.isCancelled else { return }
            self.flushPresences()
        }
    }

    private func flushPresences() {
        presenceFlushTask = nil
        guard !pendingPresences.isEmpty else { return }
        model.presences.merge(pendingPresences) { _, new in new }
        pendingPresences.removeAll(keepingCapacity: true)
        model.presenceRevision &+= 1
    }

    // MARK: Requests

    func loadHistory(in channelID: ChannelID, before: MessageID?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await rest.messages(in: channelID, before: before)
                model.mutateBox(channelID) { box in
                    for message in page { box.upsert(message) }
                    box.isLoadingHistory = false
                    box.historyFailed = false
                    // A short page is the only signal history has run out. The
                    // limit and this test read the SAME constant: drifting them
                    // either stops paging early or offers a load that can never
                    // land.
                    box.hasMoreHistory = page.count >= DiscordREST.historyPageSize
                }
                model.messageContentRevision &+= 1
            } catch {
                model.mutateBox(channelID) { box in
                    box.isLoadingHistory = false
                    box.historyFailed = true
                }
                Self.log.error("history load failed: \(Self.describe(error), privacy: .public)")
            }
        }
    }

    /// Loads the newest page when a channel is opened.
    func openChannel(_ channelID: ChannelID) {
        guard model.permissionGate.canReadHistory(channelID) else { return }
        let box = model.messages(in: channelID)
        guard box?.messages.isEmpty ?? true, box?.isLoadingHistory != true else { return }
        model.mutateBox(channelID) { $0.isLoadingHistory = true }
        loadHistory(in: channelID, before: nil)
        subscribeToMemberList(for: channelID)
    }

    /// Asks the gateway for the roster of the channel being viewed.
    ///
    /// The op-14 lazy subscription, which is the only route that answers with
    /// members **and their presences** — the documented member request answers
    /// with members and no presence for them, so a roster built on it shows
    /// everyone offline.
    private func subscribeToMemberList(for channelID: ChannelID) {
        guard let guildID = model.channelIndex.guildID(of: channelID), let socket else {
            return
        }
        Task { await socket.subscribeToMemberList(guildID: guildID, channelID: channelID) }
    }

    func acknowledge(_ messageID: MessageID, in channelID: ChannelID) {
        var state = model.readStates[channelID] ?? ReadState()
        guard state.lastAcknowledgedID != messageID else { return }
        state.lastAcknowledgedID = messageID
        state.mentionCount = 0
        model.readStates[channelID] = state
        model.sidebarRevision &+= 1
        model.railRevision &+= 1
        Task { try? await rest.acknowledge(messageID, in: channelID) }
    }

    func send(_ content: String, in channelID: ChannelID, replyingTo: MessageID?) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let userID = model.currentUserID else { return }
        // A nonce, so the gateway's echo can be matched to this send and replace
        // the optimistic row rather than appearing beside it.
        let nonce = String(UInt64(Date.now.timeIntervalSince1970 * 1000))
        Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await rest.sendMessage(
                    in: channelID,
                    content: trimmed,
                    nonce: nonce,
                    replyingTo: replyingTo
                )
                model.mutateBox(channelID) { $0.upsert(message) }
                model.messageContentRevision &+= 1
            } catch {
                Self.log.error("send failed: \(Self.describe(error), privacy: .public)")
            }
            _ = userID
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case DiscordREST.Failure.unauthorized: "Not authorised."
        case DiscordREST.Failure.forbidden: "You do not have permission to do that."
        case DiscordREST.Failure.notFound: "That no longer exists."
        case DiscordREST.Failure.api(let status, _, let message):
            message ?? "Discord returned \(status)."
        case DiscordREST.Failure.transport(let reason): reason
        case DiscordREST.Failure.decoding: "Discord sent something this client could not read."
        default: error.localizedDescription
        }
    }
}
