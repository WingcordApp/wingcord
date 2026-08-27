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

    nonisolated static func trace(_ message: @autoclosure () -> String) {
        DiagnosticLog.trace("session", message())
    }

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
    /// The account a session is being brought up for, if one is.
    ///
    /// **Starting a session must be idempotent.** Two calls — a click that
    /// registers twice, an auto-resume racing a picker, a retry from a view that
    /// re-appeared — otherwise open two gateway connections, each with its own
    /// READY, its own heartbeat and its own event stream, both writing into the
    /// same store. The symptom is double the memory and every event applied
    /// twice, and nothing about it looks like a bug from the outside.
    private var startingAccountID: String?

    /// Profile fetches in flight, so opening the same card twice — or a hover
    /// and a click on the same row — asks once.
    private var profileFetches: Set<UserID> = []
    private var effectFetches: Set<String> = []
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
        guard startingAccountID == nil else {
            Self.trace("sign-in already in flight")
            return
        }
        startingAccountID = "pending"
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
            startingAccountID = nil
        }
    }

    /// Reconnects with a token already in the Keychain.
    func resumeSession(for account: StoredAccount) {
        // Already coming up for this account, or for another one. Either way a
        // second connection is never what was wanted.
        guard startingAccountID == nil else {
            Self.trace("resume ignored, \(startingAccountID ?? "?") already starting")
            return
        }
        if model.currentUserID?.description == account.id,
           model.connectionState == .ready
        {
            Self.trace("resume ignored, already signed in as \(account.id)")
            return
        }
        Self.trace("resume \(account.id)")
        startingAccountID = account.id
        model.connectionState = .connecting
        Task { [weak self] in
            guard let self else { return }

            // The Keychain read happens OFF the main thread. It can raise a
            // prompt — "Wingcord wants to use your confidential information" —
            // and `SecItemCopyMatching` does not return until that prompt is
            // answered, which on the main thread is a frozen window.
            let token: String
            do {
                token = try await Task.detached(priority: .userInitiated) {
                    try TokenStore.token(forAccount: account.id)
                }.value
            } catch TokenStore.ReadFailure.missing {
                Self.trace("no token in keychain")
                AccountLedger.remove(account.id)
                model.connectionState = .failed("No stored credential for that account.")
                startingAccountID = nil
                return
            } catch {
                // Denied, not missing. The credential is still there and may work
                // from another build or after unlocking, so the account is KEPT.
                Self.trace("keychain denied: \(error)")
                model.connectionState = .failed(
                    "Could not read the saved credential for \(account.preferredName). "
                    + "Sign in again to replace it."
                )
                startingAccountID = nil
                return
            }

            await rest.setToken(token)
            Self.trace("validating token")
            do {
                let user = try await rest.currentUser()
                Self.trace("validated as \(user.username)")
                connect(token: token)
            } catch DiscordREST.Failure.unauthorized {
                Self.trace("401 — token rejected")
                // A 401 on a stored account drops just that account and leaves
                // every other one alone.
                AccountLedger.remove(account.id)
                model.connectionState = .failed("That account's session expired. Sign in again.")
            } catch {
                Self.trace("validation failed: \(Self.describe(error))")
                model.connectionState = .failed(Self.describe(error))
            }
            startingAccountID = nil
        }
    }

    private func connect(token: String) {
        Self.trace("connecting gateway")
        teardownConnection()
        isTornDown = false
        let socket = GatewaySocket(metadata: metadata)
        self.socket = socket
        model.historyLoader = { [weak self] channelID, before in
            self?.loadHistory(in: channelID, before: before)
        }

        eventTask = Task { [weak self] in
            await socket.connect(token: token)
            guard let stream = await socket.events else {
                SessionController.trace("no event stream")
                return
            }
            SessionController.trace("consuming events")
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
        startingAccountID = nil
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
            Self.trace("applying READY")
            applyReady(snapshot)
        case .resumed:
            model.connectionState = .ready
        case .update(let update):
            apply(update)
        case .disconnected(let reason, let willRetry):
            Self.trace("disconnected (retry: \(willRetry)): \(reason)")
            // A disconnect that will NOT be retried has to say why. Falling back
            // to `.signedOut` throws the reason away and shows a sign-in screen
            // that looks like nothing happened.
            model.connectionState = willRetry ? .reconnecting : .failed(reason)
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
        model.guildEmojis = snapshot.emojisByGuild
        model.guildStickers = snapshot.stickersByGuild
        model.members = snapshot.membersByGuild
        model.presences = snapshot.presences
        model.readStates = readStates
        model.folders = Self.railOrder(
            settingsFolders: snapshot.settings.folders,
            guildPositions: snapshot.settings.guildPositions,
            guilds: snapshot.guilds
        )
        model.favoriteGIFs = snapshot.settings.favoriteGIFs
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
    /// Three sources, and each covers a case the others cannot:
    ///
    ///   1. **The folder list** gives both the grouping and the position of
    ///      everything the account has arranged. A single-guild entry here is
    ///      not a folder — it is a guild sitting loose at that position — and
    ///      `GuildFolder.isRealFolder` is what tells them apart downstream.
    ///   2. **`guild_positions`** orders what the folder list does not mention.
    ///      Discord keeps the two separate, so a client reading only folders has
    ///      no order at all for the rest, which on a 97-guild account is most of
    ///      the rail. Its absence is why the rack looked arbitrary.
    ///   3. **READY's own guild order**, last, for anything in neither — a guild
    ///      joined since the account last rearranged. Discord puts new servers at
    ///      the end, and so does this.
    ///
    /// Guilds named in the settings but no longer joined are dropped rather than
    /// carried as holes: `guild_positions` outlives leaving a server.
    private static func railOrder(
        settingsFolders: [GuildFolder],
        guildPositions: [GuildID],
        guilds: [Guild]
    ) -> [GuildFolder] {
        // One lookup rather than a linear scan per id. At 97 guilds against a
        // 97-entry position list the scan is ~9,000 comparisons on the launch
        // path, for an answer a set gives in one.
        var known = Set<GuildID>()
        known.reserveCapacity(guilds.count)
        for guild in guilds { known.insert(guild.id) }

        var placed = Set<GuildID>()
        var result: [GuildFolder] = []

        for folder in settingsFolders {
            let present = folder.guildIDs.filter { known.contains($0) && !placed.contains($0) }
            guard !present.isEmpty else { continue }
            placed.formUnion(present)
            result.append(GuildFolder(
                id: folder.id,
                name: folder.name,
                colorValue: folder.colorValue,
                guildIDs: present
            ))
        }

        for guildID in guildPositions where known.contains(guildID) && !placed.contains(guildID) {
            placed.insert(guildID)
            result.append(GuildFolder(guildIDs: [guildID]))
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
            if model.users[author.id] != author {
                model.users[author.id] = author
                model.identityRevision &+= 1
            }
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

        case .guildAvailable(
            let guild, let channels, let roles, let members, let users, let presences,
            let emojis, let stickers
        ):
            model.guilds[guild.id] = guild
            model.channelIndex.replaceChannels(channels, inGuild: guild.id)
            model.roles[guild.id] = roles
            if !members.isEmpty { model.members[guild.id] = members }
            model.guildEmojis[guild.id] = emojis.isEmpty ? nil : emojis
            model.guildStickers[guild.id] = stickers.isEmpty ? nil : stickers
            model.users.merge(users) { _, new in new }
            model.presences.merge(presences) { _, new in new }
            model.permissionGate.invalidate()
            model.railRevision &+= 1
            model.sidebarRevision &+= 1
            model.roleRevision &+= 1
            model.memberRevision &+= 1
            model.expressionRevision &+= 1

        case .guildExpressionsUpdated(let guildID, let emojis, let stickers):
            // Each event replaces one half. A nil side did not change, and
            // writing it as empty would clear a catalog the server still has.
            if let emojis { model.guildEmojis[guildID] = emojis.isEmpty ? nil : emojis }
            if let stickers { model.guildStickers[guildID] = stickers.isEmpty ? nil : stickers }
            model.expressionRevision &+= 1

        case .guildUpdated(let guild):
            model.guilds[guild.id] = guild
            model.railRevision &+= 1
            model.sidebarRevision &+= 1
            // The picker labels its sections with the server's name and draws
            // its icon on the rail, and this is the only event that changes
            // either.
            model.expressionRevision &+= 1

        case .guildRemoved(let guildID, let wasLeft):
            guard wasLeft else { return }
            model.guildEmojis[guildID] = nil
            model.guildStickers[guildID] = nil
            model.expressionRevision &+= 1
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

    func loadHistory(in channelID: ChannelID, before: MessageID?, attempt: Int = 1) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await rest.messages(in: channelID, before: before)
                Self.trace(
                    "history \(channelID): \(page.messages.count) messages, "
                    + "\(page.authors.count) authors"
                )
                // Authors first: a row laid out before its author is known draws
                // "Unknown" and would need a second relayout to correct itself.
                //
                // The revision moves only if a name actually changed. It is the
                // mention table's memo key, and that table is proportional to
                // the whole account — so bumping it for a page whose authors
                // were all already known rebuilds every name in the session to
                // discover that none of them moved.
                var namesChanged = false
                for (userID, author) in page.authors where model.users[userID] != author {
                    model.users[userID] = author
                    namesChanged = true
                }
                if namesChanged { model.identityRevision &+= 1 }
                model.mutateBox(channelID) { box in
                    for message in page.messages { box.upsert(message) }
                    box.isLoadingHistory = false
                    box.historyFailure = nil
                    // A short page is the only signal history has run out. The
                    // limit and this test read the SAME constant: drifting them
                    // either stops paging early or offers a load that can never
                    // land.
                    box.hasMoreHistory = page.messages.count >= DiscordREST.historyPageSize
                }
                model.messageContentRevision &+= 1
            } catch {
                Self.trace(
                    "history \(channelID) FAILED (attempt \(attempt)): \(Self.describe(error))"
                )
                Self.log.error("history load failed: \(Self.describe(error), privacy: .public)")

                // Retrying a refusal is pointless — the answer will not change,
                // and the log for this account shows the same 403 asked for
                // three times in a row on launch. A dropped connection is the
                // opposite: it is worth exactly one more try, and that one try
                // is what turns "messages fail to load sometimes" into a blip.
                if Self.isWorthRetrying(error), attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard !Task.isCancelled else { return }
                    // Still wanted? The reader may have moved on.
                    guard model.messages(in: channelID)?.isLoadingHistory == true else { return }
                    loadHistory(in: channelID, before: before, attempt: attempt + 1)
                    return
                }

                model.mutateBox(channelID) { box in
                    box.isLoadingHistory = false
                    box.historyFailure = Self.describe(error)
                    // A refusal is not a gap in the history; there is nothing
                    // above to page to. Leaving `hasMoreHistory` true keeps the
                    // viewport asking for a page that can never land.
                    if !Self.isWorthRetrying(error) { box.hasMoreHistory = false }
                }
                model.messageContentRevision &+= 1
            }
        }
    }

    /// Whether asking again could plausibly answer differently.
    private static func isWorthRetrying(_ error: any Error) -> Bool {
        switch error {
        case DiscordREST.Failure.forbidden,
             DiscordREST.Failure.unauthorized,
             DiscordREST.Failure.notFound:
            false
        case DiscordREST.Failure.api(let status, _, _):
            status >= 500 || status == 429
        default:
            true
        }
    }

    /// Loads the newest page when a channel is opened.
    func openChannel(_ channelID: ChannelID) {
        let permissions = model.permissionGate.permissions(in: channelID)
        guard model.permissionGate.canReadHistory(channelID) else {
            Self.trace(
                "open \(channelID) refused: view=\(permissions.contains(.viewChannel)) "
                + "history=\(permissions.contains(.readMessageHistory))"
            )
            // Not an error state: a channel the reader can see but not read the
            // history of is a real Discord configuration. It has to LOOK like
            // that rather than like a page that never arrives.
            model.mutateBox(channelID) { box in
                box.hasMoreHistory = false
                box.isLoadingHistory = false
                box.historyFailure = permissions.contains(.viewChannel)
                    ? "You do not have permission to read this channel's history."
                    : "You do not have access to this channel."
            }
            model.messageContentRevision &+= 1
            subscribeToMemberList(for: channelID)
            return
        }
        let box = model.messages(in: channelID)
        guard box?.messages.isEmpty ?? true, box?.isLoadingHistory != true else {
            Self.trace("open \(channelID) already loaded")
            return
        }
        Self.trace("open \(channelID), fetching newest page")
        model.mutateBox(channelID) { box in
            box.isLoadingHistory = true
            box.historyFailure = nil
        }
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

    /// Fills in the parts of somebody that only the profile route answers with.
    ///
    /// Fire-and-forget, and deliberately so: the card opens immediately with
    /// what the roster already knows and gains its banner, bio and colours when
    /// they land. Making the card wait would trade a complete card for a
    /// spinner, and the fields that arrive late are decorative.
    func loadProfile(of userID: UserID, inGuild guildID: GuildID?) {
        guard profileFetches.insert(userID).inserted else { return }
        model.profilesLoading.insert(userID)
        Task { [weak self] in
            guard let self else { return }
            defer {
                profileFetches.remove(userID)
                model.profilesLoading.remove(userID)
            }
            do {
                let user = try await rest.profile(of: userID, inGuild: guildID)
                // Only if it actually added something. Replacing an equal value
                // still publishes, and this runs while a popover is open.
                if model.users[userID] != user {
                    model.users[userID] = user
                    model.identityRevision &+= 1
                }
                // The profile names the effect by SKU; the artwork is a second
                // request, and only for a SKU nothing has resolved yet.
                if let sku = user.decoration?.profileEffectSKU,
                   model.profileEffects[sku] == nil
                {
                    loadEffect(sku: sku)
                }
            } catch {
                Self.trace("profile \(userID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Resolves one collectible SKU to its layered composition.
    func loadEffect(sku: String) {
        guard effectFetches.insert(sku).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { effectFetches.remove(sku) }
            do {
                guard let effect = try await rest.collectible(sku: sku) else { return }
                model.profileEffects[sku] = effect
            } catch {
                Self.trace("effect \(sku) failed: \(Self.describe(error))")
            }
        }
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

    /// - Parameter stickerIDs: Stickers to send. A sticker is a message on its
    ///   own, so this is the one path where empty content is legitimate.
    func send(
        _ content: String,
        in channelID: ChannelID,
        replyingTo: MessageID?,
        stickerIDs: [UInt64] = []
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !stickerIDs.isEmpty, let userID = model.currentUserID else {
            return
        }
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
                    replyingTo: replyingTo,
                    stickerIDs: stickerIDs
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

// MARK: - Expressions
//
// The picker's fetches. They live here rather than on the store for the reason
// `AppModel.historyLoader` gives: the store is what a test constructs, and a
// store that reaches for a socket is a store that cannot be constructed in one.

extension SessionController {
    /// Discord's own sticker packs, fetched **once per launch** and kept.
    ///
    /// The set is the same for every account and changes about twice a year, so
    /// a request per picker open is a request per open for an answer that
    /// cannot have changed.
    func loadDefaultStickerPacks() async {
        guard model.defaultStickerPacks.isEmpty else { return }
        guard let packs = try? await rest.stickerPacks(), !packs.isEmpty else { return }
        // Eight of Discord's fourteen standard packs are entirely Lottie, which
        // is why `LottieFilmstrip` exists — without it these sections were
        // headings with nothing under them.
        model.defaultStickerPacks = packs.compactMap { pack in
            guard !pack.stickers.isEmpty else { return nil }
            let cover = pack.stickers.first { $0.id == pack.coverStickerID }
                ?? pack.stickers[0]
            return ExpressionSection(
                id: "pack.\(pack.id)",
                title: pack.name,
                badge: .image(
                    CDN.sticker(id: cover.id, format: cover.format),
                    monogram: String(pack.name.prefix(1)).uppercased()
                ),
                items: pack.stickers.map { sticker in
                    ExpressionItem(
                        id: String(sticker.id),
                        art: .image(
                            CDN.sticker(id: sticker.id, format: sticker.format),
                            animated: sticker.format.isAnimated
                        ),
                        name: sticker.name.lowercased(),
                        pick: .sticker(sticker.id)
                    )
                }
            )
        }
        // The catalog is memoized on this counter, and the packs are one of its
        // inputs — without the bump a picker already open never sees them.
        model.expressionRevision &+= 1
        model.stickerCatalogCache = nil
    }

    func gifLanding() async throws -> GIFLanding { try await rest.gifLanding() }
    func trendingGIFs() async throws -> [GIF] { try await rest.trendingGIFs() }
    func searchGIFs(_ query: String) async throws -> [GIF] { try await rest.searchGIFs(query) }
}
