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
    static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Session")
    /// GIFs whose favourite write is out.
    ///
    /// The route reads the account's whole settings blob, edits it and writes it
    /// back, so two overlapping toggles would both start from the state before
    /// either — and the later would undo the earlier. See `toggleFavorite`.
    var favoriteWritesInFlight: Set<URL> = []

    nonisolated static func trace(_ message: @autoclosure () -> String) {
        DiagnosticLog.trace("session", message())
    }

    /// The store, and the connection.
    ///
    /// `internal` rather than `private` so a group of routes can live in an
    /// extension in another file. The controller is one object with one owner;
    /// what the visibility buys is that its 1,500 lines are not also one file.
    unowned let model: AppModel
    /// `internal` alongside `rest` and `socket`: the directory routes are
    /// locale-scoped, and the locale lives here.
    let metadata = ClientMetadata()
    let rest: DiscordREST
    /// `internal` for the same reason `rest` and `model` are: a group of
    /// routes lives in an extension in another file. The launch needs the
    /// gateway's session id, and an interaction without one is refused.
    var socket: GatewaySocket?
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
    private var collectibleFetches: Set<String> = []
    private var paletteFetches: Set<URL> = []
    /// The same guard for an activity's icon. Keyed by application rather than
    /// by URL because an app has one icon and the card asks for it once.
    var activityAccentFetches: Set<ApplicationID> = []
    /// A launch whose instance id has not arrived yet. See
    /// `awaitActivityInstance`; at most one, because a launch is a click.
    var pendingActivityLaunch: PendingActivityLaunch?
    /// Whether the account's command frecency table has been asked for.
    ///
    /// A flag rather than "is the array empty": an account that has never run a
    /// command answers an empty table, and that is a real answer — one the `/`
    /// list would otherwise re-ask for on every open.
    var hasLoadedCommandFrecency = false
    /// The same latch for the GIF picker's Favourites tile, which reads the same
    /// blob from a different surface.
    var hasLoadedFavoriteGIFs = false
    /// And again for the quick switcher's ordering, which is a fourth table in
    /// that one blob. Read from `SessionController+QuickSwitch`.
    var hasLoadedNavigationFrecency = false
    /// Server-tag fetches in flight. A busy channel can show one tag on twenty
    /// consecutive rows; every one of them must share a single request.
    private var guildProfileFetches: Set<GuildID> = []
    /// Servers whose voice-channel labels and clocks have been asked for on this
    /// gateway session. See `requestVoiceChannelInfo`.
    ///
    /// **Cleared by READY, not by navigation.** A new socket is a new
    /// subscription state, so the answer has to be asked for again; leaving
    /// somewhere and coming back on the same socket does not.
    private var voiceInfoRequestedGuildIDs: Set<GuildID> = []
    /// Stream-thumbnail requests in flight, by stream key. Read from
    /// `SessionController+Presence`.
    var streamPreviewFetches: Set<String> = []
    private var expressionSourceFetches: Set<UInt64> = []
    /// Widget-template fetches in flight, by application. Read from
    /// `SessionController+Board`.
    var widgetConfigFetches: Set<ApplicationID> = []
    /// Game-profile fetches in flight. A game profile can be reached from four
    /// tiles on one board and every one of them must share a request.
    var gameProfileFetches: Set<ApplicationID> = []
    /// Recent-activity fetches in flight, by person. Read from
    /// `SessionController+Presence`.
    var recentActivityFetches: Set<UserID> = []
    /// Activity-metadata fetches in flight, keyed by the session the activity
    /// belongs to — the same key its answer is filed under.
    var activityMetadataFetches: Set<String> = []
    /// Whether `/widget-configs/featured` has been asked for this session.
    ///
    /// A latch rather than "is the table empty": the set is shared with the
    /// per-application route, so an account whose featured call answered nothing
    /// would otherwise re-ask on every board opened.
    var didLoadFeaturedWidgetConfigs = false
    /// Connect-instruction fetches in flight, by SKU.
    var gameServerProductFetches: Set<String> = []
    /// The two connected-apps lists in flight, so a pane appearing twice in one
    /// beat cannot fire the same fetch twice. Not `private`: read from
    /// `SessionController+ConnectedApps`, the same way `rulesSubmissions` is
    /// from `+Actions`.
    var connectedAppsFetches: Set<ConnectedAppsFetch> = []
    /// Not `private`: read from `SessionController+Account`.
    var accountStandingFetchInFlight = false
    /// Rules agreements in flight. Two presses on one button must send once —
    /// this route creates a join request, and a second one is a second request.
    var rulesSubmissions: Set<GuildID> = []
    /// The settled pre-fetch for the open server. Replaced on every selection
    /// change, which is what stops a sweep through the rail asking about ninety
    /// servers nobody stopped on.
    var guildPrefetchTask: Task<Void, Never>?
    /// The message search in flight, replaced rather than queued: an answer to
    /// a question the reader has moved past is worse than no answer.
    var searchTask: Task<Void, Never>?
    /// The invite resolve behind the Add a Server field, replaced per keystroke.
    var inviteLookupTask: Task<Void, Never>?
    /// Discovery's grid, replaced whenever the tab, the category or the field
    /// moves. Its page-two fetch is a *second* task: a scroll to the bottom must
    /// not cancel the request that is filling the grid it is scrolling.
    var discoveryTask: Task<Void, Never>?
    var discoveryPageTask: Task<Void, Never>?
    /// Both category lists, once per session — neither has changed in years.
    var hasLoadedDiscoveryCategories = false
    var hasLoadedAppDirectoryCategories = false
    /// The quick switcher's game autocomplete, replaced per keystroke and
    /// debounced inside — see `SessionController+QuickSwitch`.
    var gameSearchTask: Task<Void, Never>?
    /// Whose join gate is being submitted, so a double-click on Finish sends
    /// one agreement rather than two.
    var joinGateSubmissions: Set<GuildID> = []
    /// The last ballot the server confirmed, per guild. What an optimistic write
    /// is rolled back to when the route refuses it.
    var lastConfirmedOnboarding: [GuildID: Set<UInt64>] = [:]
    /// Channels whose transcript is being re-anchored around a linked message.
    private var jumpFetches: Set<ChannelID> = []
    /// When the reader was last reported as typing, per channel.
    ///
    /// Discord's own indicator lasts ten seconds, so the client re-posts at
    /// eight — often enough that it never lapses mid-sentence, rarely enough
    /// that a fast typist sends one request per eight seconds rather than one
    /// per keystroke.
    private var lastTypingSent: [ChannelID: Date] = [:]
    private static let typingInterval: TimeInterval = 8
    private var pendingPresences: [UserID: Presence] = [:]
    private var presenceFlushTask: Task<Void, Never>?
    private static let presenceFlushInterval = Duration.milliseconds(200)

    /// The call, and everything that follows from being in one.
    ///
    /// Its own object rather than a fifth extension on this one: it owns a
    /// media engine with four threads in it, and the thing that owns that must
    /// be constructible, testable and tearable-down on its own.
    let voice: VoiceController

    init(model: AppModel) {
        self.model = model
        let rest = DiscordREST(metadata: metadata)
        self.rest = rest
        voice = VoiceController(model: model, rest: rest)
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
        voice.attach(socket: socket)
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
        // Where the *previous* account had been, and how much it used each
        // place. Both are as per-account as a roster is, and a switcher opened
        // after a switch would otherwise offer the last account's channels.
        model.recentChannelIDs = []
        model.placeFrecency = [:]
        hasLoadedNavigationFrecency = false
        model.closeQuickSwitch()
        // The banners belong to the account that earned them.
        model.notifier.clearAll()
        model.notificationPreferences = .none
        // Discovery answers per account — the front page is a recommendation
        // and the grid says which servers the reader is already in.
        model.closeDiscovery()
        hasLoadedDiscoveryCategories = false
        hasLoadedAppDirectoryCategories = false
        model.clearAllMessages()
        // Everything a message action or a person's row holds. **Per-account,
        // every one of them** — a note, a block and a channel's pins all answer
        // for the account that fetched them, and a switch keeps the process.
        model.pinnedMessages = [:]
        model.pinsLoading = []
        model.pinsFailure = [:]
        model.openPinsChannelID = nil
        model.openTopicChannelID = nil
        model.pinnedCardCache = nil
        model.reactionsInFlight = []
        model.blockedUserIDs = []
        model.ignoredUserIDs = []
        model.relationships = [:]
        model.notes = [:]
        model.notesInFlight = []
        model.relationshipsInFlight = []
        model.suppressedAckChannelID = nil
        // A call does not survive a sign-out: the media session belongs to the
        // account whose token opened it.
        voice.leave()
        model.voiceStates = [:]
        model.directCalls = [:]
        model.defaultSoundboardSounds = []
        model.guildSoundboardSounds = [:]
        model.soundboardEffects = [:]
        model.voicePresentationCache = nil
        model.soundboardCache = nil
        model.dismissMessageSurfaces()
        model.messageHover = nil
        model.forwardRequest = nil
        model.forwardsInFlight = []
        model.deleteRequest = nil
        model.dismissReport()
        // The report trees are the ONE thing here that is not per-account: the
        // taxonomy is Discord's and is the same for everybody. Kept, so a
        // switch does not re-fetch it.
        model.railCache = nil
        model.sidebarCache = nil
        model.timelineCache = nil
        model.rosterCache = nil
        model.forwardTargetCache = nil
        model.quickSwitchCache = nil
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
            // **Before the snapshot lands, not after.** A READY is a NEW gateway
            // session, and a lurk lives on the old one — so the previewed guild
            // is already gone server-side and its channels are about to be
            // absent from the store. Clearing first means the rail never draws a
            // frame with a server in it that nothing can open.
            dropPreviewForNewSession()
            applyReady(snapshot)
        case .readySupplemental(let snapshot):
            applyReadySupplemental(snapshot)
        case .resumed:
            model.connectionState = .ready
            // A call that was up when the socket blipped has to ask again —
            // see `VoiceController.gatewayDidReconnect`.
            voice.gatewayDidReconnect()
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
            // After that guild's channels, never before — `replaceChannels`
            // sweeps the threads of any parent it does not see.
            for thread in snapshot.threadsByGuild[guild.id] ?? [] {
                index.upsertThread(thread)
            }
        }
        index.replacePrivateChannels(snapshot.privateChannels)

        // **A thread in READY is KNOWN, not followed**, and synthesising a
        // membership for each one was wrong — it nested every one of them in the
        // sidebar.
        //
        // Membership comes from where it is actually stated: the `members` array
        // on a `threads/search` page, `THREAD_MEMBER_UPDATE`, and the reader's
        // own follow.
        //
        // The count below is worth keeping. It reads `threads=4 across 3 guilds`
        // on a real account, which is what proved a forum's live posts do NOT
        // arrive over the socket and sent the board to fetch them instead — see
        // `DiscordREST.activeThreads`.
        Self.trace(
            "ready: threads=\(snapshot.threadsByGuild.values.reduce(0) { $0 + $1.count }) "
            + "across \(snapshot.threadsByGuild.count) guilds"
        )

        var guilds: [GuildID: Guild] = [:]
        guilds.reserveCapacity(snapshot.guilds.count)
        for guild in snapshot.guilds { guilds[guild.id] = guild }

        var readStates = snapshot.readStates
        for channelID in snapshot.mutedChannelIDs {
            readStates[channelID, default: ReadState()].isMuted = true
        }

        model.followedChannelIDs = snapshot.followedChannelIDs
        model.pinnedChannelIDs = snapshot.pinnedChannelIDs
        model.blockedUserIDs = snapshot.blockedUserIDs
        model.ignoredUserIDs = snapshot.ignoredUserIDs
        model.relationships = snapshot.relationships
        model.friendNicknames = snapshot.friendNicknames
        model.notes = snapshot.notes
        model.stageInstances = snapshot.stages
        model.voiceChannelInfo = snapshot.voiceChannelInfo
        voiceInfoRequestedGuildIDs.removeAll(keepingCapacity: true)
        voice.applyReady(
            voiceStates: snapshot.voiceStates,
            soundboards: snapshot.soundboardsByGuild
        )
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
        model.selfStatus = snapshot.settings.status
        model.selfCustomStatus = snapshot.settings.customStatus
        model.mutedGuildIDs = snapshot.mutedGuildIDs
        model.notificationPreferences = snapshot.notificationPreferences

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
        // **Nothing in READY mentions an outstanding application**, so this is
        // the one fetch that has to follow it: without it a submitted
        // application is invisible across a relaunch and the tag card offers
        // to apply again. See `JoinRequestGuild`.
        loadJoinRequestGuilds()
        voice.gatewayDidReconnect()

        restoreNavigation()
    }

    /// Applies what a voice channel just said about itself.
    ///
    /// Writes nothing when nothing changed: three gateway events feed this and
    /// one of them — the opcode-43 answer — restates a whole server's channels
    /// every time a guild is opened, so an unconditional write would invalidate
    /// the sidebar on every navigation for an answer that is usually identical.
    private func applyVoiceChannelInfo(_ patches: [ChannelID: VoiceChannelPatch]) {
        var changed = false
        for (channelID, patch) in patches {
            var info = model.voiceChannelInfo[channelID] ?? VoiceChannelInfo()
            let before = info
            info.apply(patch)
            guard info != before else { continue }
            model.voiceChannelInfo[channelID] = info.isEmpty ? nil : info
            changed = true
        }
        guard changed else { return }
        model.sidebarCache = nil
        model.sidebarRevision &+= 1
    }

    /// The half of the bootstrap that arrives second.
    ///
    /// **This is where the people in voice channels come from.** READY carries
    /// none: the `PRIORITIZED_READY_PAYLOAD` capability this client identifies
    /// with moves every guild's `voice_states` out of it and into this event,
    /// which the app had never read — so every voice channel in the sidebar drew
    /// empty until somebody happened to move while the reader was watching.
    ///
    /// **Merged, never assigned.** It lands a beat after READY and the reader
    /// may already have opened a channel by then, so a member-list answer or a
    /// presence flush can be in the store before this arrives. The voice states
    /// are the exception: nothing else can have written one yet, and a merge
    /// there would keep a state from a *previous* gateway session alive.
    private func applyReadySupplemental(_ snapshot: ReadySupplementalSnapshot) {
        Self.trace(
            "applying READY_SUPPLEMENTAL: voice=\(snapshot.voiceStates.count) "
            + "presences=\(snapshot.presences.count)"
        )
        if !snapshot.privateChannels.isEmpty {
            for channel in snapshot.privateChannels { model.channelIndex.upsert(channel) }
        }
        for (guildID, table) in snapshot.membersByGuild {
            model.members[guildID, default: [:]].merge(table) { _, new in new }
        }
        // **Anything already in the table wins**, and the rule is that simple
        // because of when this lands: READY assigns a fresh presence table a
        // moment earlier, so the only entries that can already be here came
        // from something *later* — a `PRESENCE_UPDATE`, or the member-list
        // answer for a channel `restoreNavigation` has already opened. Both are
        // fresher and more complete than a bootstrap-age subset.
        model.presences.merge(snapshot.presences) { existing, _ in existing }
        voice.applyReadySupplemental(voiceStates: snapshot.voiceStates)
        refreshVoiceActivityIcons()

        if !snapshot.membersByGuild.isEmpty { model.memberRevision &+= 1 }
        if !snapshot.presences.isEmpty { model.presenceRevision &+= 1 }
        model.sidebarCache = nil
        model.sidebarRevision &+= 1
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

        let settings = AppSettings.shared
        // "Direct messages" is the ABSENCE of a guild selection, which is
        // already the state this function was called in — so there is nothing to
        // restore and nothing to pick.
        guard settings.launchDestination == .lastChannel else { return }

        // Back where the reader was, if it is still there and still readable.
        // Both conditions matter: a channel can be deleted between launches, and
        // a role can be taken away — and either one, unchecked, opens the window
        // on a conversation that renders as an error.
        if let channelRaw = settings.lastChannelID {
            let channelID = ChannelID(rawValue: channelRaw)
            if model.canOpen(channelID) {
                model.selectedGuildID = settings.lastGuildID.map(GuildID.init(rawValue:))
                model.selectChannel(channelID)
                return
            }
        }

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
        case .interactionAcknowledged(let id, let nonce):
            // A launch this client is waiting on. This arrives for **every**
            // entry point — including the `handler: 1` kind that posts no
            // invitation message at all — and about four hundred milliseconds
            // after the interaction rather than whenever a message lands.
            resolveActivityLaunch(interaction: id, nonce: nonce)
            // …and it is the same dispatch that says a slash command was taken.
            // Both are looked up by nonce and only one of them can match, so the
            // order between them does not matter.
            resolveInteraction(nonce: nonce)

        case .interactionFailed(let nonce):
            failInteraction(nonce: nonce)

        case .messageCreated(let message, let author, let quotedAuthor, _, _):
            let merged = author.merged(over: model.users[author.id])
            if model.users[author.id] != merged {
                model.users[author.id] = merged
                model.identityRevision &+= 1
            }
            // Whoever the message quotes, if this is the first the client has
            // heard of them. Merged rather than written over: a quoted user
            // object is as thin as a roster one and would wipe a fetched card.
            if let quotedAuthor, model.users[quotedAuthor.id] == nil {
                model.users[quotedAuthor.id] = quotedAuthor
                model.identityRevision &+= 1
            }
            model.mutateBox(message.channelID) { $0.upsert(message) }
            model.channelIndex.patchLastMessage(message.id, in: message.channelID)
            model.messageContentRevision &+= 1
            bumpUnread(for: message)
            // **After the unread, and it is not the same question.** The unread
            // is bumped for a channel that is merely not selected; a banner is
            // posted only for one the reader is not *looking at*, which needs
            // the window's state as well — see `NotificationPolicy.Subject`.
            announce(message)
            // A launch this client is still waiting on: the invitation message
            // is the only thing that carries the instance Discord actually
            // minted. See `awaitActivityInstance`.
            resolveActivityLaunch(with: message)

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

        case .voiceStateChanged(let state, let member, let user):
            voice.apply(state: state, member: member, user: user)
            refreshVoiceActivityIcons()

        case .voiceServerChanged(let server):
            voice.apply(server: server)

        case .voiceEffect(let effect):
            voice.apply(effect: effect)

        case .voiceChannelInfoChanged(_, let patches):
            applyVoiceChannelInfo(patches)

        case .passiveGuildUpdate(
            let guildID, let states, let departed, let members, let users, let unreads
        ):
            // **The unreads are half of this event and cost two lines**, so
            // they are read here rather than left as a field on the wire that
            // nothing looks at. `PASSIVE_GUILD_UPDATE_V2` is what Discord sends
            // *instead of* `CHANNEL_UNREAD_UPDATE` for an unsubscribed guild —
            // a client that enables the capability and reads only the voice half
            // has asked to stop being told about new messages in every server it
            // is not currently looking at.
            for entry in unreads {
                guard let messageID = entry.lastMessageID else { continue }
                model.channelIndex.patchLastMessage(messageID, in: entry.channelID)
            }
            voice.applyPassive(
                guildID: guildID,
                states: states,
                departedUserIDs: departed,
                members: members,
                users: users
            )
            refreshVoiceActivityIcons()
            if !unreads.isEmpty {
                model.sidebarCache = nil
                model.railCache = nil
                model.railRevision &+= 1
                model.sidebarRevision &+= 1
            }

        case .callChanged(let call):
            voice.apply(call: call)

        case .callEnded(let channelID):
            voice.applyCallEnded(channelID)

        case .soundboardSoundsChanged(let guildID, let sounds):
            voice.applySoundboard(guildID: guildID, sounds: sounds)

        case .streamChanged(let owner, _, let key, let session, let viewers):
            voice.applyStreamViewers(owner: owner, viewers: viewers)
            voice.applyStreamCreated(owner: owner, key: key, session: session)

        case .streamEnded(let owner):
            voice.applyStreamEnded(owner: owner)

        case .streamServerChanged(let server):
            voice.apply(streamServer: server)

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
            let guild, let channels, let voiceChannelInfo, let threads, let roles,
            let members, let users, let presences, let emojis, let stickers, let stages
        ):
            model.guilds[guild.id] = guild
            model.voiceChannelInfo.merge(voiceChannelInfo) { _, new in new }
            // The stages already running here. A server arriving mid-session
            // is the only place they come from besides READY and the three
            // `STAGE_INSTANCE_*` events.
            for stage in stages { model.applyStage(stage) }
            model.channelIndex.replaceChannels(channels, inGuild: guild.id)
            // After the channels, never before: `replaceChannels` drops the
            // threads of any parent that did not come back, so threads inserted
            // first would be swept straight out again.
            for thread in threads { model.channelIndex.upsertThread(thread) }
            model.roles[guild.id] = roles
            if !members.isEmpty { model.members[guild.id] = members }
            model.guildEmojis[guild.id] = emojis.isEmpty ? nil : emojis
            model.guildStickers[guild.id] = stickers.isEmpty ? nil : stickers
            // **Merged, never replaced.** A roster user carries no bio, no
            // banner and no badges, so writing one straight over a
            // profile-fetched record wipes the card the reader is looking at.
            model.users.merge(users) { existing, new in new.merged(over: existing) }
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

        case .stageChanged(let stage):
            model.applyStage(stage)

        case .stageEnded(let channelID):
            model.applyStageEnded(channelID)

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

        case .threadUpserted(let thread, _, let membership):
            model.applyThreadUpsert(thread, membership: membership)

        case .threadRemoved(let threadID, _):
            model.applyThreadRemoval(threadID)

        case .threadListSynced(let guildID, let channelIDs, let threads, let memberships):
            model.applyThreadListSync(
                threads, parentIDs: channelIDs, memberships: memberships, guildID: guildID
            )

        case .threadMembershipChanged(let membership):
            model.applyThreadMembership(membership)

        case .threadMemberCountChanged(let threadID, let count):
            model.applyThreadMemberCount(count, in: threadID)

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
            // **Merged, never replaced.** A roster user carries no bio, no
            // banner and no badges, so writing one straight over a
            // profile-fetched record wipes the card the reader is looking at.
            model.users.merge(users) { existing, new in new.merged(over: existing) }
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
            model.users[user.id] = user.merged(over: model.users[user.id])
            model.identityRevision &+= 1

        case .friendNicknameChanged(let userID, let nickname):
            // Applied whatever set it: the reader's own rename settles on the
            // same answer its optimistic write already made, and one made on a
            // phone reaches this window without a refetch.
            model.applyFriendNickname(nickname, for: userID)

        case .guildSettingsChanged(let guildID, let pinned, let muted):
            // **Only the private-channel entry carries pins**, and it is the
            // one whose `guild_id` is null. A server's entry arriving here
            // would otherwise clear every pin in the direct-message list,
            // because its own override set has none in it.
            if guildID == nil { model.applyPinnedChannels(pinned) }
            for channelID in model.channelIndex.privateChannelIDs() {
                model.applyChannelMute(muted.contains(channelID), channelID: channelID)
            }

        case .relationshipChanged(let userID, let kind, let isIgnored, let user):
            // **Applied whatever the client did.** These arrive for the reader's
            // own acts as well as for somebody else's, so the optimistic write
            // and the echo settle on the same answer — and a request accepted
            // on a phone reaches this window without a refetch.
            if let user, model.users[userID] == nil { model.users[userID] = user }
            if kind == .none {
                model.relationships[userID] = nil
                model.blockedUserIDs.remove(userID)
                model.ignoredUserIDs.remove(userID)
            } else {
                model.relationships[userID] = kind
                if kind == .blocked {
                    model.blockedUserIDs.insert(userID)
                } else {
                    model.blockedUserIDs.remove(userID)
                }
                if isIgnored {
                    model.ignoredUserIDs.insert(userID)
                } else {
                    model.ignoredUserIDs.remove(userID)
                }
            }
            model.identityRevision &+= 1
        }
    }

    /// Posts a banner for a message that earns one.
    ///
    /// **The authorisation is asked for HERE**, the first time there is genuinely
    /// something to tell somebody about, rather than at launch — a permission
    /// sheet in front of an app nobody has signed into yet is a question about
    /// something they have not seen.
    private func announce(_ message: Message) {
        guard let notice = model.notice(for: message) else { return }
        let notifier = model.notifier
        let playsSound = AppSettings.shared.playsNotificationSound
        Task {
            await notifier.requestAuthorizationIfNeeded()
            notifier.post(
                title: notice.title,
                subtitle: notice.subtitle,
                body: notice.body,
                channelID: notice.channelID,
                messageID: notice.messageID,
                playsSound: playsSound
            )
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
        // **A role ping is a mention**, and this counted only a direct one —
        // `mentionedRoleIDs` was on the payload and had no accessor, so the
        // badge silently missed every `@moderators`. `mentionableIDs` is one
        // flat set of the reader's roles *and* their own id for exactly this.
        // `contains(where:)` rather than a trailing closure: after `||` the
        // parser reads a trailing brace as the start of a block, not a closure.
        if message.mentionsEveryone
            || message.mentionedUserIDs.contains(where: { model.mentionableIDs.contains($0.rawValue) })
            || message.mentionedRoleIDs.contains(where: { model.mentionableIDs.contains($0.rawValue) })
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
        // **Checked before the merge, over the pending set only.** The sidebar's
        // voice rows draw what their people are playing, and this is what tells
        // them to — a dictionary lookup per flushed presence, against a scan
        // over every voice state in the account or a rebuild of the whole
        // channel tree on every flush.
        let touchesVoice = pendingPresences.keys.contains { model.voiceStates[$0] != nil }
        model.presences.merge(pendingPresences) { _, new in new }
        pendingPresences.removeAll(keepingCapacity: true)
        model.presenceRevision &+= 1
        if touchesVoice {
            model.voicePresenceRevision &+= 1
            refreshVoiceActivityIcons()
        }
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
                for (userID, author) in page.authors {
                    let merged = author.merged(over: model.users[userID])
                    guard model.users[userID] != merged else { continue }
                    model.users[userID] = merged
                    namesChanged = true
                }
                if namesChanged { model.identityRevision &+= 1 }
                model.applyThreadsFromMessages(page.threads)
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
        // Arriving anywhere ends a deliberate rewind: the reader has stopped
        // meaning "leave this unread" the moment they navigate.
        if model.suppressedAckChannelID != channelID { model.suppressedAckChannelID = nil }
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
        requestVoiceChannelInfo(inGuild: guildID)
        // The server on screen just changed, and with it the set of people whose
        // games the sidebar has to draw a mark for.
        refreshVoiceActivityIcons()
    }

    /// Asks a server for the labels and session clocks on its voice channels.
    ///
    /// **Once per server per session, on the first channel opened in it.** The
    /// statuses arrive on READY and are then kept current by
    /// `VOICE_CHANNEL_STATUS_UPDATE` for as long as the guild is subscribed —
    /// which it is from this moment on. What this closes is the gap before it:
    /// anything set while the reader was elsewhere, and the session clock, which
    /// no channel object anywhere carries.
    ///
    /// A repeat per navigation would restate a whole server's channels on every
    /// click for an answer that cannot have changed since the subscription
    /// started, so the guild is remembered rather than the request debounced.
    private func requestVoiceChannelInfo(inGuild guildID: GuildID) {
        guard let socket, voiceInfoRequestedGuildIDs.insert(guildID).inserted else { return }
        Task { await socket.requestChannelInfo(guildID: guildID) }
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
                let fetched = try await rest.profile(of: userID, inGuild: guildID)
                let user = fetched.user
                // **Assigned whole, not merged.** This route is the
                // authoritative answer for every cosmetic field, so a bio
                // somebody deleted has to be able to disappear — see
                // `User.merged(over:)`, which every OTHER write goes through.
                //
                // Only if it actually added something. Replacing an equal value
                // still publishes, and this runs while a popover is open.
                if model.users[userID] != user {
                    model.users[userID] = user
                    model.identityRevision &+= 1
                }
                // The board arrives on this route and nowhere else — assigned
                // whole for the same reason, so a tile somebody deleted stops
                // being drawn. Its games, templates and identities are three
                // further routes, started here rather than from the tab: the tab
                // only exists because these widgets arrived.
                if model.profileWidgets[userID] != fetched.widgets {
                    model.profileWidgets[userID] = fetched.widgets
                }
                loadBoard(of: userID, widgets: fetched.widgets)
                // The profile names each collectible by SKU; the artwork is a
                // second request, and only for a SKU nothing has resolved yet.
                if let sku = user.decoration?.profileEffectSKU,
                   model.profileEffects[sku] == nil
                {
                    loadCollectible(sku: sku)
                }
                // The frame is a separate purchase from the effect and an
                // account can wear both, so this is an `if`, not an `else`.
                if let sku = user.decoration?.profileFrameSKU,
                   model.profileFrames[sku] == nil
                {
                    loadCollectible(sku: sku)
                }
                deriveTheme(of: user)
            } catch {
                Self.trace("profile \(userID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Resolves the card behind a server tag.
    ///
    /// Cached on the store by guild, so the same tag opened on twenty different
    /// people is one request. Nothing invalidates it during a session: a
    /// server's description, badge and traits change about as often as its name.
    func loadGuildProfile(_ guildID: GuildID) {
        guard model.guildProfiles[guildID] == nil,
              guildProfileFetches.insert(guildID).inserted
        else { return }
        model.guildProfilesLoading.insert(guildID)
        Task { [weak self] in
            guard let self else { return }
            defer {
                guildProfileFetches.remove(guildID)
                model.guildProfilesLoading.remove(guildID)
            }
            do {
                model.guildProfiles[guildID] = try await rest.guildProfile(of: guildID)
            } catch {
                Self.trace("guild profile \(guildID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Resolves where a foreign emoji or sticker came from.
    ///
    /// Cached on the store by id, so an expression clicked twice asks once. Only
    /// ever called for one **no resident server owns**.
    ///
    /// The two routes answer differently shaped payloads for the same idea, so
    /// which one to call is decided here and nowhere else.
    func loadExpressionSource(_ id: UInt64, isSticker: Bool) {
        guard model.expressionSources[id] == nil,
              expressionSourceFetches.insert(id).inserted
        else { return }
        model.expressionSourcesLoading.insert(id)
        Task { [weak self] in
            guard let self else { return }
            defer {
                expressionSourceFetches.remove(id)
                model.expressionSourcesLoading.remove(id)
            }
            do {
                let source = isSticker
                    ? try await rest.stickerSource(id)
                    : try await rest.emojiSource(EmojiID(rawValue: id))
                guard let source else { return }
                model.expressionSources[id] = source
            } catch {
                // A refusal is a real answer here — an expression whose server
                // has gone, or one the account may not ask about. The card falls
                // back to what it could already say.
                Self.trace("expression source \(id) failed: \(Self.describe(error))")
            }
        }
    }

    /// Re-anchors a transcript around one message and asks the timeline to go
    /// to it.
    ///
    /// **The page has to be fetched with `around`, not `before`.** A link can
    /// point anywhere in a channel's history, and paging backwards to reach it
    /// is an unbounded chain of round trips the reader watches — on a busy
    /// channel, thousands of them. One request centred on the target is the only
    /// shape that answers in constant time.
    ///
    /// The existing transcript is **replaced**, not merged. A page from a year
    /// ago and the newest page are two disjoint runs, and keeping both would put
    /// a silent gap in the middle of the transcript with nothing to say it is
    /// there.
    func jumpToMessage(_ messageID: MessageID, in channelID: ChannelID) {
        model.selectChannel(channelID)

        if model.messages(in: channelID)?.messages.contains(where: { $0.id == messageID }) == true {
            model.requestJump(to: messageID, in: channelID)
            return
        }
        guard jumpFetches.insert(channelID).inserted else { return }
        model.mutateBox(channelID) { box in
            box.isLoadingHistory = true
            box.historyFailure = nil
        }
        Task { [weak self] in
            guard let self else { return }
            defer { jumpFetches.remove(channelID) }
            do {
                let page = try await rest.messages(in: channelID, around: messageID)
                var namesChanged = false
                for (userID, author) in page.authors {
                    let merged = author.merged(over: model.users[userID])
                    guard model.users[userID] != merged else { continue }
                    model.users[userID] = merged
                    namesChanged = true
                }
                if namesChanged { model.identityRevision &+= 1 }
                model.applyThreadsFromMessages(page.threads)
                model.mutateBox(channelID) { box in
                    box.messages = page.messages
                    box.isLoadingHistory = false
                    box.historyFailure = nil
                    box.hasMoreHistory = page.messages.count >= DiscordREST.historyPageSize
                }
                model.messageContentRevision &+= 1
                model.requestJump(to: messageID, in: channelID)
            } catch {
                Self.trace("jump \(messageID) failed: \(Self.describe(error))")
                model.mutateBox(channelID) { box in
                    box.isLoadingHistory = false
                    box.historyFailure = Self.describe(error)
                }
                model.messageContentRevision &+= 1
            }
        }
    }

    /// Sends a vote, and puts the poll back if it does not land.
    ///
    /// **The revert carries the whole previous poll, not a delta.** A vote that
    /// failed has to leave the tally exactly as it was, and reversing the
    /// optimistic write by arithmetic gets that wrong the moment a real update
    /// arrives from the gateway in between.
    func castVote(
        _ answerID: Int,
        on messageID: MessageID,
        in channelID: ChannelID,
        revertingTo previous: Poll
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.vote(answerIDs: [answerID], onPoll: messageID, in: channelID)
            } catch {
                Self.trace("vote \(messageID) failed: \(Self.describe(error))")
                model.restorePoll(previous, on: messageID, in: channelID)
            }
        }
    }

    /// Tells the channel the reader is typing, at most once every eight seconds.
    ///
    /// **Throttled at the call site's own clock rather than with a timer.** A
    /// timer per channel is a timer that outlives the channel; a timestamp is
    /// one comparison on a keystroke and nothing at all when nobody is typing.
    func reportTyping(in channelID: ChannelID) {
        let now = Date()
        if let last = lastTypingSent[channelID], now.timeIntervalSince(last) < Self.typingInterval {
            return
        }
        lastTypingSent[channelID] = now
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.typing(in: channelID)
            } catch {
                // A dropped typing signal costs a reader three dots they never
                // knew were coming. It is never worth a retry and never worth a
                // message on screen.
                Self.trace("typing \(channelID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Publishes the reader's own status.
    ///
    /// Over the socket, because the settings route stores a status without
    /// broadcasting one — an account that changed status there stays green to
    /// everyone else until it reconnects.
    func publishPresence() {
        guard let socket else { return }
        let status = model.selfStatus.rawValue
        let text = model.selfCustomStatus
        let emoji = model.selfCustomStatusEmoji
        // **The activity rides along.** `activities` is one array and the write
        // replaces all of it, so publishing a status without the running
        // activity would erase it from everybody's roster.
        let activity = model.publishedActivity
        Task {
            await socket.updatePresence(
                status: status,
                customStatus: text,
                customEmoji: emoji,
                activity: activity
            )
        }
    }

    /// Resolves one collectible SKU to its artwork.
    ///
    /// **One route, two shapes.** A profile effect and a profile frame are both
    /// named on a profile by SKU and both described by
    /// `/collectibles-products/{sku}`, and the answer says which it is — see
    /// `Collectible`. The dedupe set is shared because the *request* is shared:
    /// keying it per kind would let a frame and an effect with the same SKU
    /// both be in flight, which is one round trip too many for an answer that
    /// can only be one of them.
    func loadCollectible(sku: String) {
        guard collectibleFetches.insert(sku).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { collectibleFetches.remove(sku) }
            do {
                switch try await rest.collectible(sku: sku) {
                case .effect(let effect): model.profileEffects[sku] = effect
                case .frame(let frame): model.profileFrames[sku] = frame
                case nil: break
                }
            } catch {
                Self.trace("collectible \(sku) failed: \(Self.describe(error))")
            }
        }
    }

    /// Quantises somebody's artwork into the colours they never chose.
    ///
    /// **Only for a profile that has none**, and only once per picture —
    /// `themeArtworkURL` answers nil for everybody else, so this costs a
    /// dictionary lookup on the overwhelming majority of profiles and nothing
    /// at all on a second look at the same person.
    ///
    /// The decode goes through the ordinary image cache, so a picture already
    /// resident is not fetched again; the quantisation itself is handed off the
    /// main actor, because it walks every sampled pixel and a profile card
    /// opening is the worst possible moment to spend that on the main thread.
    func deriveTheme(of user: User) {
        guard let url = model.themeArtworkURL(of: user, user.decoration),
              model.derivedPalettes[url] == nil,
              paletteFetches.insert(url).inserted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { paletteFetches.remove(url) }
            let key = ImageStore.Key(
                url: url, maximumPixelSize: ProfileThemePalette.pixelSize
            )
            guard let image = await ImageStore.shared.image(for: key, bucket: .artwork)
            else { return }
            let palette = await Task.detached(priority: .utility) {
                ProfileThemePalette.derive(from: image)
            }.value
            guard !palette.isEmpty else { return }
            model.derivedPalettes[url] = palette
            model.identityRevision &+= 1
        }
    }

    func acknowledge(_ messageID: MessageID, in channelID: ChannelID) {
        // **The reader asked for this channel to stay unread.** Marking unread
        // while standing in the channel is only meaningful if the client stops
        // acknowledging it — otherwise the next inbound message quietly undoes
        // it. The latch is cleared by leaving.
        guard model.suppressedAckChannelID != channelID else { return }
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
    /// - Parameter attachments: Files already staged in the composer. A message
    ///   may be nothing but these, which is the second such path.
    func send(
        _ content: String,
        in channelID: ChannelID,
        replyingTo: MessageID?,
        stickerIDs: [UInt64] = [],
        attachments: [PendingAttachment] = []
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !stickerIDs.isEmpty || !attachments.isEmpty,
              model.currentUserID != nil
        else { return }
        // A nonce, so the gateway's echo can be matched to this send and replace
        // the optimistic row rather than appearing beside it.
        let nonce = String(UInt64(Date.now.timeIntervalSince1970 * 1000))
        if !attachments.isEmpty { model.mutateBox(channelID) { $0.isUploading = true } }
        Task { [weak self] in
            guard let self else { return }
            defer {
                if !attachments.isEmpty {
                    model.mutateBox(channelID) { $0.isUploading = false }
                }
            }
            do {
                let uploaded = try await upload(attachments, in: channelID)
                let message = try await rest.sendMessage(
                    in: channelID,
                    content: trimmed,
                    nonce: nonce,
                    replyingTo: replyingTo,
                    stickerIDs: stickerIDs,
                    attachments: uploaded
                )
                model.mutateBox(channelID) { box in
                    box.upsert(message)
                    box.attachments.removeAll()
                }
                model.messageContentRevision &+= 1
            } catch {
                Self.log.error("send failed: \(Self.describe(error), privacy: .public)")
                // **The files stay staged.** A refused upload that also cleared
                // the tray would ask somebody to find five pictures again
                // because the network dropped; the reason goes where the tray
                // already draws one.
                model.mutateBox(channelID) { box in
                    box.attachmentRefusal = attachments.isEmpty
                        ? nil
                        : .sendFailed(Self.describe(error))
                    for index in box.attachments.indices { box.attachments[index].progress = nil }
                }
            }
        }
    }

    /// Puts the staged files up, in order, reporting each one's progress.
    ///
    /// **Serially, and that is deliberate.** These are the largest transfers the
    /// app makes — up to half a gigabyte each — and running five at once splits
    /// one connection's bandwidth five ways while holding five buffers. One at a
    /// time also makes the progress figure mean something: it is *this* file,
    /// not an average across a set whose sizes differ by two orders of
    /// magnitude.
    private func upload(
        _ attachments: [PendingAttachment],
        in channelID: ChannelID
    ) async throws -> [UploadedAttachment] {
        guard !attachments.isEmpty else { return [] }
        let slots = try await rest.createUploadSlots(
            in: channelID, for: attachments.map(\.uploadRequest)
        )
        var uploaded: [UploadedAttachment] = []
        uploaded.reserveCapacity(slots.count)
        for (attachment, slot) in zip(attachments, slots) {
            try await rest.upload(attachment.url, to: slot) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.reportUpload(fraction, of: attachment.id, in: channelID)
                }
            }
            uploaded.append(UploadedAttachment(
                id: slot.id,
                filename: slot.filename,
                uploadedFilename: slot.uploadedFilename,
                altText: attachment.altText
            ))
        }
        return uploaded
    }

    /// Writes a progress figure into the tray, on a change worth drawing.
    ///
    /// **Coalesced on a hundredth**, for the reason `MediaCanvasView` coalesces
    /// a pinch: `URLSession` reports every buffer it hands to the socket —
    /// thousands of times for a large file — and the thing reading this is a bar
    /// a few dozen points wide that cannot show a ten-thousandth.
    @MainActor
    private func reportUpload(_ fraction: Double, of id: PendingAttachment.ID, in channelID: ChannelID) {
        guard let box = model.messages(in: channelID),
              let index = box.attachments.firstIndex(where: { $0.id == id })
        else { return }
        let previous = box.attachments[index].progress ?? -1
        guard fraction >= 1 || fraction - previous >= 0.01 else { return }
        model.mutateBox(channelID) { $0.attachments[index].progress = fraction }
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

// MARK: - The server's own pages
//
// Server Guide, Channels & Roles and Game Servers. Five routes, all per-guild
// and all cached on the store for the life of the session: a guide, a set of
// questions and a rented server change about as often as the server's name.
//
// TWO RULES DECIDE WHEN THEY FIRE, and both exist to keep a rail sweep from
// becoming a burst of requests.
//
//  1. **The pre-fetch is settled and cancellable.** Arrow-keying through
//     ninety-seven servers would otherwise ask three questions about each. One
//     task, replaced on every selection change, waits out a short settle and the
//     scroll gate before it asks anything — so only servers somebody actually
//     stopped on are asked about.
//  2. **Everything else is asked for on the click that needs it.** The rules,
//     the role counts and a plan's connect steps are each one request made by
//     one surface opening, and each is skipped entirely once it has an answer.

extension SessionController {

    /// What a server is asked when the reader opens it.
    ///
    /// Only the two that decide whether a **row** exists at all. Everything
    /// else waits for the page itself to be opened, because a question asked
    /// about a page nobody looked at is a request spent on nothing.
    func guildDidOpen(_ guildID: GuildID) {
        guildPrefetchTask?.cancel()
        guildPrefetchTask = Task { [weak self] in
            // Long enough that stepping through the rail asks about nothing,
            // short enough that stopping on a server has its rows before the
            // list's own entrance animation has finished.
            try? await Task.sleep(for: .milliseconds(320))
            await ScrollWorkGate.waitUntilInactive()
            guard !Task.isCancelled, let self, model.selectedGuildID == guildID else { return }
            loadServerGuide(guildID)
            loadOnboarding(guildID)
            loadGameServers(guildID)
            // **A server can be gated and this client never asked.** Joining on
            // a phone or on discord.com lands the membership here over the
            // socket with no gate raised, which is exactly the case that made
            // Wingcord drop somebody into a channel of a server whose questions
            // it had never shown. The rules route is the one that says so, and
            // it is only worth asking where the guild claims the feature — every
            // other server answers it with an empty form.
            if model.guilds[guildID]?.features.contains(Self.verificationFeature) == true {
                loadMemberVerification(guildID)
            }
            // Both tables can already be filled from an earlier visit, in which
            // case neither loader runs and neither offers.
            model.offerJoinGateIfNeeded(guildID)
        }
    }

    /// The guild feature that says a server has a rules gate at all.
    static let verificationFeature = "MEMBER_VERIFICATION_GATE_ENABLED"

    /// The page a server shows a new arrival.
    ///
    /// **A 404 is stored as an empty guide**, not left absent. Absent means "not
    /// asked", so a server without one would be asked again every time it was
    /// opened — and the answer would be the same 404 every time.
    func loadServerGuide(_ guildID: GuildID) {
        let fetch = GuildSurfaceFetch(guildID: guildID, subject: .guide)
        guard model.serverGuides[guildID] == nil,
              model.loadingGuildSurfaces.insert(fetch).inserted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.loadingGuildSurfaces.remove(fetch) }
            do {
                model.serverGuides[guildID] = try await rest.serverGuide(of: guildID)
            } catch {
                model.serverGuides[guildID] = ServerGuide(guildID: guildID, isEnabled: false)
                Self.trace("server guide \(guildID) failed: \(Self.describe(error))")
            }
        }
    }

    /// The questions a community server asks. Decides the channel-list row's
    /// own name, which is why it is asked before anybody opens the page.
    func loadOnboarding(_ guildID: GuildID) {
        let fetch = GuildSurfaceFetch(guildID: guildID, subject: .onboarding)
        guard model.guildOnboardings[guildID] == nil,
              model.loadingGuildSurfaces.insert(fetch).inserted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.loadingGuildSurfaces.remove(fetch) }
            do {
                model.guildOnboardings[guildID] = try await rest.onboarding(of: guildID)
            } catch {
                model.guildOnboardings[guildID] = GuildOnboarding(
                    guildID: guildID, isEnabled: false
                )
                Self.trace("onboarding \(guildID) failed: \(Self.describe(error))")
            }
            // **Offered as the answer lands, not when the server was opened.**
            // Whether a server gates is computed from tables that fill
            // asynchronously, so a single check on selection would run before
            // there was anything to check and never run again.
            model.offerJoinGateIfNeeded(guildID)
            // A gate raised by a fresh join exists before its questions do, so
            // this is the moment its answer set can be seeded. No-op once seeded.
            if model.joinGate?.guildID == guildID { model.seedJoinGateSelection() }
        }
    }

    /// How many people hold each role, so an option can say how many chose it.
    ///
    /// Asked when the page opens rather than with the guild, because it is the
    /// largest of the five answers — nearly two hundred entries on a big
    /// server — and it is worth nothing to a reader who never opens the page.
    func loadRoleMemberCounts(_ guildID: GuildID) {
        let fetch = GuildSurfaceFetch(guildID: guildID, subject: .memberCounts)
        guard model.roleMemberCounts[guildID] == nil,
              model.loadingGuildSurfaces.insert(fetch).inserted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.loadingGuildSurfaces.remove(fetch) }
            do {
                model.roleMemberCounts[guildID] = try await rest.roleMemberCounts(inGuild: guildID)
            } catch {
                // An empty table is a real answer: the counts are an
                // embellishment on a chip, and a page that refuses to draw
                // without them would be a page held hostage by a footnote.
                model.roleMemberCounts[guildID] = [:]
                Self.trace("role counts \(guildID) failed: \(Self.describe(error))")
            }
        }
    }

    /// The rules a server makes people agree to.
    func loadMemberVerification(_ guildID: GuildID, inviteCode: String? = nil) {
        let fetch = GuildSurfaceFetch(guildID: guildID, subject: .rules)
        guard model.memberVerifications[guildID] == nil,
              model.loadingGuildSurfaces.insert(fetch).inserted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.loadingGuildSurfaces.remove(fetch) }
            do {
                model.memberVerifications[guildID] = try await rest.memberVerification(
                    of: guildID, inviteCode: inviteCode
                )
            } catch {
                model.memberVerifications[guildID] = MemberVerification(guildID: guildID)
                Self.trace("member verification \(guildID) failed: \(Self.describe(error))")
            }
            model.offerJoinGateIfNeeded(guildID)
        }
    }

    /// Follows or unfollows one channel or category.
    ///
    /// **The store moves first**, because a checkbox that waits for a round trip
    /// reads as a control that did not take the click. The reply carries the
    /// guild's complete follow set, which replaces this guild's share of the
    /// local one — that is also how a change made on another client lands.
    ///
    /// A failure restores exactly what was flipped rather than the whole set: a
    /// second row's write may have landed in between, and rolling back to a
    /// snapshot taken before it would undo somebody else's success.
    func setChannelFollowed(
        _ isFollowed: Bool,
        channelID: ChannelID,
        inGuild guildID: GuildID
    ) {
        guard model.followsInFlight.insert(channelID).inserted else { return }
        if isFollowed {
            model.followedChannelIDs.insert(channelID)
        } else {
            model.followedChannelIDs.remove(channelID)
        }
        Task { [weak self] in
            guard let self else { return }
            defer { model.followsInFlight.remove(channelID) }
            do {
                let followed = try await rest.setChannelFollowed(
                    isFollowed, channelID: channelID, inGuild: guildID
                )
                // Only this guild's entries are replaced. The set is flat and
                // spans every server, so taking the reply wholesale would drop
                // every other server's follows on one checkbox.
                let guildChannels = Set(model.channelIndex.channelIDs(inGuild: guildID))
                var next = model.followedChannelIDs.subtracting(guildChannels)
                next.formUnion(followed)
                guard model.followedChannelIDs != next else { return }
                model.followedChannelIDs = next
            } catch {
                Self.trace("follow \(channelID) failed: \(Self.describe(error))")
                if isFollowed {
                    model.followedChannelIDs.remove(channelID)
                } else {
                    model.followedChannelIDs.insert(channelID)
                }
            }
        }
    }

    /// Records the reader's agreement to a server's rules.
    ///
    /// **The optimistic write is the member's own pending flag**, and only on an
    /// approval: the gateway's `GUILD_MEMBER_UPDATE` is the authority and lands a
    /// beat later, but the sheet has to close on the click rather than on the
    /// round trip. A request left pending a moderator clears nothing, because
    /// nothing has changed yet.
    func agreeToRules(_ verification: MemberVerification, inGuild guildID: GuildID) {
        guard rulesSubmissions.insert(guildID).inserted else { return }
        model.serverRulesSubmission = ServerRulesSubmission(guildID: guildID, state: .sending)
        Task { [weak self] in
            guard let self else { return }
            defer { rulesSubmissions.remove(guildID) }
            do {
                let outcome = try await rest.agreeToRules(verification, inGuild: guildID)
                switch outcome {
                case .approved:
                    if let userID = model.currentUserID {
                        model.members[guildID]?[userID]?.isPending = false
                        model.memberRevision &+= 1
                    }
                    model.serverRulesSubmission = nil
                    model.serverRulesGuildID = nil
                case .pending, .unknown:
                    model.serverRulesSubmission = ServerRulesSubmission(
                        guildID: guildID, state: .pending
                    )
                case .rejected(let reason):
                    model.serverRulesSubmission = ServerRulesSubmission(
                        guildID: guildID, state: .rejected(reason)
                    )
                }
            } catch {
                Self.trace("rules agreement \(guildID) failed: \(Self.describe(error))")
                model.serverRulesSubmission = ServerRulesSubmission(
                    guildID: guildID,
                    // The reader's words, not the decoder's: they are being told
                    // their agreement did not land, and "decoding(…)" tells them
                    // nothing they can act on.
                    state: .failed("That did not go through. Try again in a moment.")
                )
            }
        }
    }

    /// The game servers a community has rented.
    func loadGameServers(_ guildID: GuildID) {
        let fetch = GuildSurfaceFetch(guildID: guildID, subject: .gameServers)
        guard model.gameServers[guildID] == nil,
              model.loadingGuildSurfaces.insert(fetch).inserted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.loadingGuildSurfaces.remove(fetch) }
            do {
                model.gameServers[guildID] = try await rest.gameServers(inGuild: guildID)
            } catch {
                // 403 and 404 both mean the same thing to the row that reads
                // this: there is nothing to show, and nothing to ask again.
                model.gameServers[guildID] = []
                Self.trace("game servers \(guildID) failed: \(Self.describe(error))")
            }
        }
    }

    /// The steps a game needs to reach a rented server.
    ///
    /// By SKU, so two servers on one plan share an answer and a sheet opened
    /// twice asks once.
    func loadGameServerProduct(sku skuID: String) {
        guard !skuID.isEmpty,
              model.gameServerProducts[skuID] == nil,
              gameServerProductFetches.insert(skuID).inserted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { gameServerProductFetches.remove(skuID) }
            do {
                model.gameServerProducts[skuID] = try await rest.gameServerProduct(sku: skuID)
            } catch {
                // The sheet's own reason to exist is the address, which it
                // already has. An empty product is what makes it stop asking.
                model.gameServerProducts[skuID] = GameServerProduct(skuID: skuID)
                Self.trace("game server product \(skuID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Writes the reader's answers back.
    ///
    /// **The store has already moved**, optimistically, so this exists to make
    /// the server agree — and to correct the store when it does not. The reply
    /// carries the ballot as the server now holds it, which is the only way an
    /// option it refused comes back off the page.
    ///
    /// A failure restores what the server last confirmed rather than leaving the
    /// optimistic set standing: a chip that stayed lit after the write failed is
    /// a role the reader believes they have.
    func saveOnboardingResponses(_ responses: Set<UInt64>, inGuild guildID: GuildID) {
        guard let onboarding = model.guildOnboardings[guildID] else { return }
        let prompts = onboarding.prompts
        let confirmed = lastConfirmedOnboarding[guildID]
        model.savingOnboardingGuilds.insert(guildID)
        Task { [weak self] in
            guard let self else { return }
            defer { model.savingOnboardingGuilds.remove(guildID) }
            do {
                let applied = try await rest.setOnboardingResponses(
                    responses, prompts: prompts, inGuild: guildID
                )
                lastConfirmedOnboarding[guildID] = applied
                // Only if it differs. Assigning an equal value still publishes,
                // and this lands while the page is on screen.
                guard model.guildOnboardings[guildID]?.responses != applied else { return }
                model.guildOnboardings[guildID]?.responses = applied
            } catch {
                Self.trace("onboarding responses \(guildID) failed: \(Self.describe(error))")
                guard let confirmed,
                      model.guildOnboardings[guildID]?.responses != confirmed
                else { return }
                model.guildOnboardings[guildID]?.responses = confirmed
            }
        }
    }
}
