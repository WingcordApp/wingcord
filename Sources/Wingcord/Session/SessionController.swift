import AppKit
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
    /// Servers whose linked-role configuration is being fetched.
    ///
    /// **Beside the cache rather than folded into it**, because the answer can
    /// be an empty array and "asked, nothing there" has to be distinguishable
    /// from "asking". Without it, opening the menu twice in a second on a server
    /// with no linked roles is two requests.
    var linkedRolesInFlight: Set<GuildID> = []

    nonisolated static func trace(_ message: @autoclosure () -> String) {
        DiagnosticLog.trace("session", message())
    }

    /// The four fields of a fetched profile that decide what a card draws.
    ///
    /// **By value, because the shape dump beside it is by key.**
    /// `DiscordREST.traceProfileShape` lists what a response CONTAINS, which
    /// cannot separate a field that is absent from one that arrived null — and
    /// on screen those are the same blank banner and two different faults.
    nonisolated static func describe(profile user: User, guildLayer: User?) -> String {
        let decoration = user.decoration
        let accent = decoration?.accentColor.map(String.init) ?? "-"
        let banner = decoration?.bannerHash ?? "-"
        let theme = decoration?.themeColorValues?.count ?? 0
        return "profile \(user.id) banner=\(banner) accent=\(accent) "
            + "theme=\(theme) guildLayer=\(guildLayer == nil ? "-" : "yes")"
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
    /// Conversations whose newest message has been asked for this connection
    /// — see `loadDirectMessagePreviews`. Asked once each, never again.
    var requestedPreviewChannels: Set<ChannelID> = []
    var isLoadingPreviews = false

    /// What this Mac is running, and the thing that publishes it.
    ///
    /// **Owned by the session rather than the model**, because it is a
    /// connection-shaped thing: it starts when an account connects, stops when
    /// one signs out, and its whole output is a presence write. The model holds
    /// the *result* so views can read it.
    let games = GameDetector()
    /// What macOS says is playing, as a presence — see `SessionController+NowPlaying`.
    let nowPlaying = NowPlayingPresence()

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
    var paletteFetches: Set<URL> = []
    /// The activity directory's two requests are in flight — the call's shelf
    /// and the launcher both ask, often in the same instant.
    var isLoadingActivityDirectory = false
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
    /// Spotify's own embed page, read for the card behind a link. Its own client
    /// and its own session: it goes to a host that is not Discord, so it must
    /// never be handed the account's token. See `SpotifyEmbedClient`.
    let spotify = SpotifyEmbedClient()
    /// Spotify unfurls in flight, and the ones Spotify has refused.
    ///
    /// **The refusals are remembered for the session**, which is what stops a
    /// private playlist in somebody's backlog being asked for on every page of
    /// history. Read from `SessionController+Spotify`.
    var spotifyFetches: Set<String> = []
    var spotifyRefusals: Set<String> = []
    /// The reader's own Spotify, per linked account — see
    /// `SessionController+SpotifyPlayer`.
    var spotifyFollowers: [String: Task<Void, Never>] = [:]
    var spotifyClients: [String: SpotifyPlayerClient] = [:]
    var spotifyPlaying: [String: SpotifyNowPlaying] = [:]
    var spotifyExpiries: [String: Task<Void, Never>] = [:]
    /// The waits before listening along stops — the host gone quiet, or the
    /// reader's own player moving off the host's track. See
    /// `SessionController+ListenAlong`.
    var listenAlongHostGrace: Task<Void, Never>?
    var listenAlongDrift: Task<Void, Never>?
    /// The sends in flight, by nonce — so an upload can be cancelled from its
    /// card in the transcript.
    var sendTasks: [MessageID: Task<Void, Never>] = [:]
    /// The last send's POST, which the next one waits behind — see
    /// `inSendOrder`.
    var sendQueue: Task<Void, Never>?
    private var expressionSourceFetches: Set<UInt64> = []
    /// Widget-template fetches in flight, by application. Read from
    /// `SessionController+Board`.
    var widgetConfigFetches: Set<ApplicationID> = []
    /// The next ask for the reader's activity feed, scheduled — see
    /// `SessionController+ActivityFeed`.
    var activityFeedTask: Task<Void, Never>?
    /// Game-profile fetches in flight. A game profile can be reached from four
    /// tiles on one board and every one of them must share a request.
    var gameProfileFetches: Set<ApplicationID> = []
    /// Applications `/games` has already been asked about, answer or not.
    ///
    /// Not "in flight": the route says nothing about an application that is not
    /// a tracked game, and that silence is an answer worth remembering for the
    /// session. Read from `SessionController+Board`.
    var gameFetches: Set<ApplicationID> = []
    /// Which people this session has already asked the gateway about, so a
    /// channel of two hundred messages from six people asks six times and not
    /// six hundred. See `resolveMessageMembers`.
    private var memberRequests: Set<MemberRequest> = []
    /// When each role's holders were last asked for — see `loadRoleMembers`.
    private var roleMemberFetches: [RoleMembersKey: Date] = [:]

    struct RoleMembersKey: Hashable {
        var guildID: GuildID
        var roleID: RoleID
    }

    struct MemberRequest: Hashable {
        var guildID: GuildID
        var userID: UserID
    }

    /// The member list subscription in force, so the same request is never
    /// sent twice. See `subscribeMemberListPages`.
    private var memberListSubscription: MemberListSubscription?

    struct MemberListSubscription: Equatable {
        var key: MemberListKey
        /// The channel subscribed for its list — a thread's parent, for a thread.
        var channelID: ChannelID
        var pages: [ClosedRange<Int>]
    }

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
    /// Not `private`: read from `SessionController+Actions`.
    var accountCustomThemesFetchInFlight = false
    /// Rules agreements in flight. Two presses on one button must send once —
    /// this route creates a join request, and a second one is a second request.
    var rulesSubmissions: Set<GuildID> = []
    /// The settled pre-fetch for the open server. Replaced on every selection
    /// change, which is what stops a sweep through the rail asking about ninety
    /// servers nobody stopped on.
    var guildPrefetchTask: Task<Void, Never>?
    /// The rail's arrangement waiting to be saved — see
    /// `SessionController+Rail`. Nil when there is nothing to save.
    var folderSaveTask: Task<Void, Never>?
    /// Counts the reader's changes to the rail, so a save's answer can tell
    /// whether the rail has moved on since it was sent.
    var railEdits = 0
    /// The message search in flight, replaced rather than queued: an answer to
    /// a question the reader has moved past is worse than no answer.
    var searchTask: Task<Void, Never>?
    /// The invite resolve behind the Add a Server field, replaced per keystroke.
    var inviteLookupTask: Task<Void, Never>?
    /// A clicked invite link being looked up, for its sheet.
    var inviteSheetTask: Task<Void, Never>?
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
    /// Discord's own sticker packs, while they are being fetched — one request
    /// however many things ask, the picker and a sticker's card among them.
    var stickerPacksTask: Task<Void, Never>?
    /// Channels whose transcript is being re-anchored around a linked message.
    private var jumpFetches: Set<ChannelID> = []
    /// Invite codes asked about this session — see `resolveInvites`.
    var inviteFetches: Set<String> = []
    /// Invite cards whose button is being answered: one accept per code at a
    /// time — see `joinFromInviteCard`.
    var inviteCardJoins: Set<String> = []
    /// The local RPC server, while an account is signed in — see
    /// `SessionController+LocalRPC`.
    var localRPC: LocalRPCServer?
    /// Each app's pictures by name, and links already turned into `mp:`
    /// references — Discord's asset store and `fetchAssetIds`' own cache.
    var localRPCAssetNames: [ApplicationID: [String: String]] = [:]
    var localRPCAssetLinks: [String: String] = [:]
    /// Hosted cards asked about this session — see `resolveHostedCards`.
    var hostedCardFetches: Set<HostedCardKey> = []
    /// Servers whose event answers an event card has asked for this session —
    /// once a server, however many cards it has.
    var eventCardAnswerFetches: Set<GuildID> = []
    /// Servers being joined from an event card's Join — one join at a time.
    var eventCardJoins: Set<GuildID> = []
    /// Inbox folds waiting to be written — see `foldInboxGroup`.
    var pendingInboxFolds: [InboxFoldKey: InboxFold] = [:]
    var inboxFoldWrite: Task<Void, Never>?
    /// People's volumes and mutes waiting to be written — see
    /// `scheduleAudioContextWrite`.
    var pendingAudioContext: [AudioContextKey: AudioContextProto.Change] = [:]
    var audioContextWrite: Task<Void, Never>?
    /// Unread groups whose message bodies the inbox is fetching.
    ///
    /// Its own set rather than `jumpFetches`: both fetch the same route for the
    /// same channel, but a jump is the reader waiting on a transcript and this
    /// is a summary filling in behind a flyout. Sharing the set would let a
    /// scrolling inbox suppress the jump the reader actually asked for.
    var unreadGroupFetches: Set<ChannelID> = []
    /// When the reader was last reported as typing, per channel.
    ///
    /// Discord's own indicator lasts ten seconds, so the client re-posts at
    /// eight — often enough that it never lapses mid-sentence, rarely enough
    /// that a fast typist sends one request per eight seconds rather than one
    /// per keystroke.
    private(set) var lastTypingSent: [ChannelID: Date] = [:]
    private static let typingInterval: TimeInterval = 8
    /// The one timer that lets typing indicators lapse, and when it fires.
    private var typingExpiryTask: Task<Void, Never>?
    private var typingExpiryDeadline: Date?
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
        // Expired upload links are refreshed as the account — see
        // `AttachmentLinks`. The client is this controller's for its life, so
        // it is handed over once; signing out forgets what it refreshed.
        Task { await AttachmentLinks.shared.setClient(rest) }
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
                let account = try await rest.currentUser()
                let user = account.user
                try TokenStore.store(token, forAccount: user.id.description)
                AccountLedger.upsert(StoredAccount(
                    id: user.id.description,
                    username: user.handle,
                    displayName: user.displayName,
                    avatarHash: user.avatarHash
                ))
                model.reloadAccounts()
                adoptEntitlements(of: account)
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
        // `--demo` has no Keychain to read and no server to ask: it's a switch.
        if LaunchOptions.current.usesDemoFixtures {
            switchAccount(to: account)
            return
        }
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
                model.reloadAccounts()
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
                let account = try await rest.currentUser()
                Self.trace("validated as \(account.user.username)")
                // Chosen from the picker: it's the one the next launch opens.
                AccountLedger.used(account.user.id.description)
                model.reloadAccounts()
                adoptEntitlements(of: account)
                connect(token: token)
            } catch DiscordREST.Failure.unauthorized {
                Self.trace("401 — token rejected")
                // A 401 on a stored account marks just that account and leaves
                // every other one alone. Listed, so it's clear which one wants
                // signing in again.
                AccountLedger.expire(account.id)
                model.reloadAccounts()
                model.connectionState = .failed("That account's session expired. Sign in again.")
            } catch {
                Self.trace("validation failed: \(Self.describe(error))")
                model.connectionState = .failed(Self.describe(error))
            }
            startingAccountID = nil
        }
    }

    // MARK: Switching

    /// Moves to another stored account: **checked first, and let go of after.**
    ///
    /// Discord tears down and apologises if the new account turns out to be dead. Asking
    /// first, with a client of its own, means a dead token or no network leaves the reader
    /// exactly where they were, with their channel open and their session up. The shared
    /// client's token isn't touched until the answer's in, so nothing the live session
    /// sends in the meantime goes out as somebody else.
    func switchAccount(to account: StoredAccount) {
        guard startingAccountID == nil, model.accountSwitch == nil,
              model.currentUserID?.description != account.id
        else { return }
        startingAccountID = account.id
        model.checkingAccountID = account.id
        Task { [weak self] in
            guard let self else { return }
            // Only its own marks. Signing out while this was asking clears them, and by the
            // time it gets here another press may have set them for somebody else.
            defer {
                if self.startingAccountID == account.id { self.startingAccountID = nil }
                if self.model.checkingAccountID == account.id { self.model.checkingAccountID = nil }
            }
            if LaunchOptions.current.usesDemoFixtures {
                await self.switchInDemo(to: account)
                return
            }
            let token: String
            do {
                // Off the main thread, for `resumeSession`'s reason: it can raise a prompt.
                token = try await Task.detached(priority: .userInitiated) {
                    try TokenStore.token(forAccount: account.id)
                }.value
            } catch TokenStore.ReadFailure.missing {
                AccountLedger.remove(account.id)
                self.model.reloadAccounts()
                self.model.reportAccountProblem("There's no saved sign-in for \(account.preferredName).")
                return
            } catch {
                self.model.reportAccountProblem("Couldn't read the saved sign-in for \(account.preferredName).")
                return
            }
            let probe = DiscordREST(metadata: self.metadata)
            await probe.setToken(token)
            let current: CurrentAccount
            do {
                current = try await probe.currentUser()
            } catch DiscordREST.Failure.unauthorized {
                self.accountSessionExpired(account)
                return
            } catch {
                self.model.reportAccountProblem(
                    "Couldn't reach Discord to switch to \(account.preferredName). Nothing changed."
                )
                return
            }
            // A token answering as somebody else is no longer this account's: Discord's
            // `MULTI_ACCOUNT_VALIDATE_TOKEN_USER_MISMATCH`.
            guard current.user.id.description == account.id else {
                self.accountSessionExpired(account)
                return
            }
            // Logged out, or the live session died, while that was being asked: `clearAccount`
            // took the mark, and nobody's waiting on this switch any more.
            guard self.startingAccountID == account.id else { return }
            await self.moveToValidated(account, token: token, current: current)
        }
    }

    private func rememberAccount(_ user: User) {
        AccountLedger.refresh(StoredAccount(
            id: user.id.description,
            username: user.handle,
            displayName: user.displayName,
            avatarHash: user.avatarHash
        ))
        model.reloadAccounts()
    }

    /// Marked on its row, and said out loud, since the row may be on a list that's closed
    /// by now: a card asking about a call takes the flyout with it.
    private func accountSessionExpired(_ account: StoredAccount) {
        AccountLedger.expire(account.id)
        model.reloadAccounts()
        model.reportAccountProblem("\(account.preferredName)'s session has expired. Log in again to use it.")
    }

    /// The veil's up before anything's let go of, so nothing being cleared is ever seen.
    private func moveToValidated(_ account: StoredAccount, token: String, current: CurrentAccount) async {
        let user = current.user
        let fresh = StoredAccount(
            id: account.id, username: user.handle, displayName: user.displayName, avatarHash: user.avatarHash
        )
        AccountLedger.refresh(fresh)
        AccountLedger.used(account.id)
        let serial = beginVeil(over: fresh)
        try? await Task.sleep(for: .seconds(AccountSwitch.veilIn))
        clearAccount()
        model.reloadAccounts()
        startingAccountID = account.id
        model.connectionState = .connecting
        await rest.setToken(token)
        adoptEntitlements(of: current)
        connect(token: token)
        watchSwitch(serial)
    }

    private func beginVeil(over account: StoredAccount) -> UInt64 {
        model.accountSwitchSerial &+= 1
        let serial = model.accountSwitchSerial
        model.profileRequest = nil
        model.accountSwitch = AccountSwitch(target: account, serial: serial)
        return serial
    }

    /// Nothing leaves a veil up for ever: a gateway that never answers ends at the sign-in
    /// screen, which says so and lists the accounts.
    private func watchSwitch(_ serial: UInt64) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AccountSwitch.timeout))
            guard let self, self.model.accountSwitch?.serial == serial else { return }
            self.model.accountSwitch = nil
            self.signOut()
            self.model.connectionState = .failed("Discord didn't answer. Try that account again.")
        }
    }

    /// A signed-in reader adding another: **the current session stays up until the new
    /// token's proved good**, then it's an ordinary switch, with its questions.
    func addAccount(token: String) {
        Task { [weak self] in
            guard let self else { return }
            let probe = DiscordREST(metadata: self.metadata)
            await probe.setToken(token)
            do {
                let user = try await probe.currentUser().user
                try TokenStore.store(token, forAccount: user.id.description)
                let stored = StoredAccount(
                    id: user.id.description,
                    username: user.handle,
                    displayName: user.displayName,
                    avatarHash: user.avatarHash
                )
                let isCurrent = self.model.currentUserID == user.id
                if isCurrent {
                    AccountLedger.refresh(stored)
                } else {
                    AccountLedger.add(stored)
                }
                self.model.reloadAccounts()
                if !isCurrent { self.model.requestAccountSwitch(to: stored) }
            } catch {
                self.model.reportAccountProblem("That sign-in didn't work. \(Self.describe(error))")
            }
        }
    }

    /// Really logs out: the token and the list entry both go, which is what's left for
    /// "Log Out" to mean now that a switch is how to leave an account and keep it.
    func logOut() {
        if let accountID = model.currentUserID?.description {
            AccountLedger.remove(accountID)
        }
        signOut()
        model.reloadAccounts()
    }

    /// `--demo`: the same steps at the same pace, and the fixtures seen as somebody else.
    private func switchInDemo(to account: StoredAccount) async {
        try? await Task.sleep(for: .milliseconds(450))
        if DemoFixtures.hasDeadSession(account) {
            accountSessionExpired(account)
            return
        }
        AccountLedger.used(account.id)
        _ = beginVeil(over: account)
        try? await Task.sleep(for: .seconds(AccountSwitch.veilIn))
        clearAccount()
        model.reloadAccounts()
        model.connectionState = .connecting
        model.demoTranscripts = [:]
        try? await Task.sleep(for: .milliseconds(600))
        DemoFixtures.populate(model, asAccount: account.id)
        model.reloadAccounts()
        _ = openLastPlace()
    }

    /// What the account just validated is entitled to, **replacing** whatever
    /// the last account had.
    ///
    /// The token check already asks `/users/@me`, which carries the tier and the
    /// age status, and used to throw both away — leaving every perk hanging on
    /// READY alone. Replaced rather than merged: this is a sign-in, possibly as
    /// somebody else, and a merge would lend them the previous account's tier.
    /// READY then merges over it.
    private func adoptEntitlements(of account: CurrentAccount) {
        model.ownTypingIndicatorStyle = account.typingIndicatorStyle
        model.isNSFWAllowed = account.isNSFWAllowed
        model.entitlements = AccountEntitlements().updated(
            premiumType: account.premiumType,
            ageVerificationStatus: account.ageVerificationStatus
        )
    }

    private func connect(token: String) {
        Self.trace("connecting gateway")
        teardownConnection()
        isTornDown = false
        startGameDetection()
        startLocalRPC()
        startNowPlaying()
        let socket = GatewaySocket(metadata: metadata)
        self.socket = socket
        voice.attach(socket: socket)
        model.historyLoader = { [weak self] channelID, request in
            self?.loadHistory(in: channelID, request)
        }
        model.topicLoader = { [weak self] channelID, request in
            self?.loadTopics(in: channelID, request)
        }
        model.summaryLoader = { [weak self] channelID, request in
            self?.loadSummaries(in: channelID, request)
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
        clearAccount()
        Task { await rest.setToken(nil) }
    }

    /// Everything but the shared client's token.
    ///
    /// **Apart from `signOut` because a switch sets the next token straight after**, and
    /// a task clearing it would land on the far side of that, leaving the new session
    /// asking as nobody.
    private func clearAccount() {
        Task { await AttachmentLinks.shared.forget() }
        // A note's the account's: nobody else should find it in their composer, let
        // alone send it.
        model.voicePlayer.stop()
        model.voiceRecorder.discard()
        stopLocalRPC()
        startingAccountID = nil
        teardownConnection()
        stopSpotify()
        model.drafts.close()
        model.currentUserID = nil
        model.entitlements = AccountEntitlements()
        model.accountVerification = nil
        model.mentionableIDs = []
        model.guilds = [:]
        model.channelIndex = ChannelIndex()
        model.users = [:]
        model.members = [:]
        model.memberLists = [:]
        memberListSubscription = nil
        model.roles = [:]
        model.presences = [:]
        model.readStates = [:]
        model.folders = []
        model.guildPositions = []
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
        // A wait is the account's, not the window's: the next account has sent
        // nothing yet.
        model.slowmodeCooldowns = [:]
        model.slowmodeNudge = nil
        // Topics are the account's view of each server, and so is what is open.
        model.conversationTopics = [:]
        model.topicPreviews = [:]
        model.topicMessages = [:]
        model.topicCacheOrder = []
        model.topicFetchesInFlight = []
        model.openTopic = nil
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
        // What READY and the account's own lists said about it.
        model.experiments = ExperimentSnapshot()
        model.ownTypingIndicatorStyle = nil
        model.accountCustomThemes = nil
        // Applications are the account's, and so is everything drawn of them.
        model.ownJoinRequests = [:]
        model.joinRequestGuilds = []
        model.isPendingApplicationsOpen = false
        model.showsApplicationCoachmark = false
        model.isApplicationCoachmarkQueued = false
        model.reapplyingGuildIDs = []
        model.joinRequestMenu = nil
        model.withdrawApplicationRequest = nil
        model.approvedApplication = nil
        model.welcomeScreenNotice = nil
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
        model.reactionHover = nil
        model.reactorCache = [:]
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
    }

    private func teardownConnection() {
        isTornDown = true
        requestedPreviewChannels.removeAll()
        cancelFolderSave()
        stopGameDetection()
        stopNowPlaying()
        eventTask?.cancel()
        eventTask = nil
        presenceFlushTask?.cancel()
        presenceFlushTask = nil
        pendingPresences.removeAll(keepingCapacity: false)
        typingExpiryTask?.cancel()
        typingExpiryTask = nil
        typingExpiryDeadline = nil
        model.clearAllTyping()
        model.historyLoader = nil
        model.topicLoader = nil
        model.summaryLoader = nil
        if let socket {
            Task { await socket.stop() }
        }
        socket = nil
    }

    // MARK: Applying

    private func apply(_ event: GatewaySocket.Event) {
        switch event {
        case .connecting:
            let next = model.connectionState.onSocketOpening()
            if next != model.connectionState { model.connectionState = next }
        case .ready(let snapshot):
            Self.trace("applying READY")
            // **Before the snapshot lands, not after.** A READY is a NEW gateway
            // session, and a lurk lives on the old one — so the previewed guild
            // is already gone server-side and its channels are about to be
            // absent from the store. Clearing first means the rail never draws a
            // frame with a server in it that nothing can open.
            dropPreviewForNewSession()
            // Discord's store starts over at `CONNECTION_OPEN`: the marks these
            // were counted from may have moved while the socket was down.
            model.forumPostUnreadCounts = [:]
            model.forumUnreadsRequested = []
            applyReady(snapshot)
        case .readySupplemental(let snapshot):
            applyReadySupplemental(snapshot)
            // Discord asks for the activity feed as the connection opens.
            loadActivityFeed()
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
                AccountLedger.expire(userID.description)
            }
            signOut()
            model.reloadAccounts()
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
        // **Worth keeping, for the threads count's reason**: a server's theme
        // was captured on a join's answer, never on READY, and this line is
        // what says whether READY carries it — `themes=0` on an account in a
        // themed server means the field arrives somewhere else.
        Self.trace(
            "ready: themes=\(snapshot.guilds.count { $0.theme?.resolved != nil }) "
            + "summaries=\(snapshot.guilds.count { $0.features.contains("SUMMARIES_ENABLED_GA") })"
        )
        // **Worth keeping, for the same reason.** A Nitro account once saw every
        // other server's emoji locked, and this line says what READY itself
        // carried: `absent` and `0` lock the same perks for different reasons.
        Self.trace(
            "ready: premium_type=\(snapshot.premiumType.map(String.init) ?? "absent") "
            + "age_status=\(snapshot.ageVerificationStatus.map(String.init) ?? "absent") "
            + "age_gated=\(snapshot.ageGatedFeatures.rawValue)"
        )
        // **Also worth keeping: never captured off a real READY.** Discord's
        // client reads `guild_join_requests` from it; an account with an
        // application out that reads `join_requests=0` here means the list
        // arrives some other way.
        Self.trace("ready: join_requests=\(snapshot.joinRequests.count)")
        model.entitlements = model.entitlements.updated(
            premiumType: snapshot.premiumType,
            ageVerificationStatus: snapshot.ageVerificationStatus
        )
        if let verification = snapshot.accountVerification { model.accountVerification = verification }
        model.ageGatedFeatures = snapshot.ageGatedFeatures
        // A presence the reader made that is on goes out with its pictures as
        // soon as the session can say so — DESIGN-NOTES §11.
        if model.activeCustomPresence != nil { model.customPresenceChanged(immediately: true) }

        var readStates = snapshot.readStates
        for channelID in snapshot.mutedChannelIDs {
            readStates[channelID, default: ReadState()].isMuted = true
        }

        model.followedChannelIDs = snapshot.followedChannelIDs
        model.pinnedChannelIDs = snapshot.pinnedChannelIDs
        model.blockedUserIDs = snapshot.blockedUserIDs
        model.ignoredUserIDs = snapshot.ignoredUserIDs
        model.relationships = snapshot.relationships
        model.relationshipFacts = snapshot.relationshipFacts
        model.friendNicknames = snapshot.friendNicknames
        model.notes = snapshot.notes
        model.stageInstances = snapshot.stages
        model.scheduledEvents = snapshot.scheduledEvents
        model.voiceChannelInfo = snapshot.voiceChannelInfo
        voiceInfoRequestedGuildIDs.removeAll(keepingCapacity: true)
        spotifyRefusals.removeAll(keepingCapacity: true)
        voice.applyReady(
            voiceStates: snapshot.voiceStates,
            soundboards: snapshot.soundboardsByGuild
        )
        model.currentUserID = snapshot.currentUser.id
        // Who the account is now, for a switcher that can't ask.
        rememberAccount(snapshot.currentUser)
        model.ownTypingIndicatorStyle = snapshot.typingIndicatorStyle
        model.experiments = snapshot.experiments
        // A voice invite's look can follow a server experiment.
        model.inviteSettlementChanged()
        model.restoreDrafts(for: snapshot.currentUser.id)
        // **Whether the composer may schedule** is whether this list answers
        // — see `AppModel.canScheduleMessages`. Asked once a session.
        if model.inbox.scheduled == nil { loadInbox(.scheduled) }
        followSpotify()
        model.users = snapshot.users
        model.guilds = guilds
        model.channelIndex = index
        model.roles = snapshot.rolesByGuild
        model.guildEmojis = snapshot.emojisByGuild
        model.guildStickers = snapshot.stickersByGuild
        model.members = snapshot.membersByGuild
        model.presences = snapshot.presences
        model.readStates = readStates
        model.guildEventAcks = snapshot.guildEventAcks
        model.usesNewNotifications = (snapshot.notificationFlags ?? 0) & 16 != 0
        // **A rearrangement not yet saved outlives a reconnect**: the READY
        // settings predate it, and the save still pending will write it. Only
        // the servers are brought up to date under it.
        model.folders = GuildArrangement.resolve(
            folders: hasPendingFolderSave ? model.folders : snapshot.settings.folders,
            guildPositions: hasPendingFolderSave ? [] : snapshot.settings.guildPositions,
            joined: snapshot.guilds.map(\.id)
        )
        model.guildPositions = snapshot.settings.guildPositions
        model.selfStatus = snapshot.settings.status
        model.selfCustomStatus = snapshot.settings.customStatus
        // The tab the account was last on, in any client. Seeded rather than
        // assigned wholesale: `InboxState` also holds what this session fetched,
        // and a reconnect must not throw that away underneath an open flyout.
        model.inbox.tab = snapshot.settings.inboxTab
        // Where the account shares what it is playing, and the raw bytes a
        // write has to preserve. See `ActivityPrivacyProto`.
        model.activityPrivacy = snapshot.settings.activityPrivacy
        model.activityPrivacyRaw = snapshot.settings.privacyRaw
        model.activityStatusRaw = snapshot.settings.statusRaw
        // Whose theme a themed server is drawn in. See `GuildThemeSource`.
        model.serverThemePreferences = snapshot.settings.serverThemes
        model.inboxCollapse = snapshot.settings.inboxCollapse
        model.syncedPreferences = snapshot.settings.preferences
        // The account's theme, where it is one of Discord's; and from now, the
        // reader's choices go back to it. See `SessionController+ThemeSync`.
        adoptAccountTheme(model.syncedPreferences.accountTheme)
        ThemeStore.shared.onChoose = { [weak self] choice in self?.writeAccountTheme(for: choice) }
        applyAudioContext(snapshot.settings.audioContext)
        // A new session may have missed summaries while it was away.
        model.markSummariesStale()
        model.mutedGuildIDs = snapshot.mutedGuildIDs
        model.notificationPreferences = snapshot.notificationPreferences
        model.guildUserSettings = snapshot.guildUserSettings

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
        // **What this client published before READY, mirrored now.** A game
        // already running at launch, or what is playing, goes out with the
        // first presence — before there is a reader to mirror it onto — and
        // READY then files the account's presence without it. Seen 2026-10-20:
        // Now Playing published at 3.6 s, READY at 4.9 s, the reader's own
        // card empty until the next song.
        model.reflectOwnPresenceNow()
        // READY has just put the account's stored status back; a Focus that is
        // on puts its own back on top of it.
        model.focusSync?.sessionDidBecomeReady()
        // **READY carries the reader's applications** — `guild_join_requests`,
        // which Discord's `CONNECTION_OPEN` files whole. The servers they are
        // to are asked for when the folder that draws them opens, as Discord's
        // are; an open folder is asked for now.
        model.ownJoinRequests = snapshot.joinRequests
        if model.isPendingApplicationsOpen { loadJoinRequestGuildsIfNeeded() }
        voice.gatewayDidReconnect()

        // A new gateway session starts with no lists and no subscriptions —
        // Discord's store resets on CONNECTION_OPEN — so the list on screen is
        // asked for again. On a first launch nothing is selected yet, and
        // opening the restored channel asks.
        model.memberLists = [:]
        model.memberListRevision &+= 1
        memberListSubscription = nil
        if let channelID = model.selectedChannelID {
            subscribeMemberListPages(nil, for: channelID)
        }

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

    /// Back where this account was, if that's still there and still readable.
    private func openLastPlace() -> Bool {
        guard let place = AppSettings.shared.lastPlace(forAccount: model.currentUserID?.description),
              let channelRaw = place.channelID
        else { return false }
        let channelID = ChannelID(rawValue: channelRaw)
        guard model.canOpen(channelID) else { return false }
        model.selectedGuildID = place.guildID.map(GuildID.init(rawValue:))
        model.selectChannel(channelID)
        return true
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
        if openLastPlace() { return }

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
            // Held aside while the window is cut off from the present, and the
            // oldest trimmed once it is full — see `MessageBox.receiveLive`.
            let trims = model.mayTrimOldest(in: message.channelID)
            model.mutateBox(message.channelID) { $0.receiveLive(message, trimming: trims) }
            noteGameMentions(in: [message])
            model.clearTyping(author.id, in: message.channelID)
            model.channelIndex.patchLastMessage(message.id, in: message.channelID)
            model.messageContentRevision &+= 1
            bumpUnread(for: message)
            model.countForumPostMessage(message)
            // **After the unread, and it is not the same question.** The unread
            // is bumped for a channel that is merely not selected; a banner is
            // posted only for one the reader is not *looking at*, which needs
            // the window's state as well — see `NotificationPolicy.Subject`.
            announce(message)
            speakIfReading(message)
            // A launch this client is still waiting on: the invitation message
            // is the only thing that carries the instance Discord actually
            // minted. See `awaitActivityInstance`.
            resolveActivityLaunch(with: message)
            resolveSpotifyUnfurls(in: [message])
            resolveInvites(in: [message])
            resolveHostedCards(in: [message], inGuild: model.channelIndex.guildID(of: message.channelID))
            resolveMessageMembers(in: [message], channelID: message.channelID)

        case .messageUpdated(let message):
            noteGameMentions(in: [message])
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
            model.applyOpenerUpdated(message)

        case .messageDeleted(let messageID, let channelID):
            model.mutateBox(channelID) { $0.remove(messageID) }
            model.messageContentRevision &+= 1
            model.applyOpenerDeleted(messageID, in: channelID)

        case .voiceStateChanged(let state, let member, let user):
            voice.apply(state: state, member: member, user: user)
            refreshVoiceActivityIcons()

        case .voiceServerChanged(let server):
            voice.apply(server: server)

        case .clipsRemoteTrigger(let trigger):
            model.receiveRemoteClipTrigger(trigger)
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

        case .summariesUpdated(let channelID, let summaries):
            model.mergeSummaries(summaries, in: channelID)

        case .reactionAdded(let messageID, let channelID, let emoji, let userID, let kind, let colors):
            model.applyReaction(
                emoji, kind: kind, to: messageID, in: channelID, added: true,
                isMine: userID == model.currentUserID, colors: colors
            )
            // **Every super reaction that lands plays its effect**, the reader's
            // own echo included — Discord's message list plays one for each
            // `MESSAGE_REACTION_ADD` of the burst kind that is not an optimistic
            // write, and the echo is how the reader's own gets one.
            if kind == .burst { SuperReactionStage.shared.arrived(emoji, on: messageID) }

        case .reactionRemoved(let messageID, let channelID, let emoji, let userID, let kind):
            model.applyReaction(
                emoji, kind: kind, to: messageID, in: channelID, added: false,
                isMine: userID == model.currentUserID
            )

        case .reactionsAdded(let messageID, let channelID, let reactions):
            model.applyReactionBatch(reactions, to: messageID, in: channelID)

        case .reactionsCleared(let messageID, let channelID):
            model.clearReactions(nil, on: messageID, in: channelID)

        case .reactionEmojiCleared(let messageID, let channelID, let emoji):
            model.clearReactions(emoji, on: messageID, in: channelID)

        case .guildAvailable(
            let guild, let channels, let voiceChannelInfo, let threads, let roles,
            let members, let users, let presences, let emojis, let stickers, let stages,
            let scheduledEvents
        ):
            model.guilds[guild.id] = guild
            // **A server just joined goes on top**, as Discord's rebuild on
            // `GUILD_CREATE` puts it (`GuildArrangement.resolve`). One already
            // in the rail — an outage ending — keeps its place, and a lurked
            // one stays out: its tile is the preview's until the join lands.
            if !model.isPreviewing(guild.id) {
                GuildArrangement.placeJoined(guild.id, in: &model.folders)
            }
            model.scheduledEvents[guild.id] = scheduledEvents.isEmpty ? nil : scheduledEvents
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
            // A server just joined turns its invite cards' Join into Go to Server.
            model.inviteSettlementChanged()

        case .guildExpressionsUpdated(let guildID, let emojis, let stickers):
            // Each event replaces one half. A nil side did not change, and
            // writing it as empty would clear a catalog the server still has.
            if let emojis { model.guildEmojis[guildID] = emojis.isEmpty ? nil : emojis }
            if let stickers { model.guildStickers[guildID] = stickers.isEmpty ? nil : stickers }
            model.expressionRevision &+= 1

        case .stageChanged(let stage):
            model.applyStage(stage)

        case .scheduledEventChanged(let event):
            storeScheduledEvent(event)

        case .scheduledEventRemoved(let guildID, let eventID):
            model.scheduledEvents[guildID]?.removeAll { $0.id == eventID }
            model.inbox.revision &+= 1

        case .scheduledEventRSVPAdded(let rsvp):
            applyEventAnswer(rsvp, added: true)
        case .scheduledEventRSVPRemoved(let rsvp):
            applyEventAnswer(rsvp, added: false)
        case .scheduledEventExceptionChanged(let eventID, let exception):
            applyEventException(eventID: eventID, exception, occurrence: exception.id)
        case .scheduledEventExceptionRemoved(let eventID, let occurrence):
            applyEventException(eventID: eventID, nil, occurrence: occurrence)

        case .activityInboxStale(let refreshAfter):
            activityFeedWentStale(after: refreshAfter)

        case .stageEnded(let channelID):
            model.applyStageEnded(channelID)

        case .guildUpdated(var guild, let carriesTheme):
            if !carriesTheme { guild.theme = model.guilds[guild.id]?.theme }
            model.guilds[guild.id] = guild
            model.railRevision &+= 1
            model.sidebarRevision &+= 1
            // The picker labels its sections with the server's name and draws
            // its icon on the rail, and this is the only event that changes
            // either.
            model.expressionRevision &+= 1

        case .guildRemoved(let guildID, let wasLeft):
            guard wasLeft else { return }
            // Discord's applicant store forgets a server it is removed from.
            model.ownJoinRequests[guildID] = nil
            model.guildEmojis[guildID] = nil
            model.guildStickers[guildID] = nil
            model.expressionRevision &+= 1
            model.guilds[guildID] = nil
            model.roles[guildID] = nil
            model.members[guildID] = nil
            model.memberLists = model.memberLists.filter { $0.key.guildID != guildID }
            model.memberListRevision &+= 1
            GuildArrangement.remove(guildID, from: &model.folders)
            if model.selectedGuildID == guildID {
                model.selectedGuildID = nil
                model.selectedChannelID = nil
            }
            model.permissionGate.invalidate()
            model.railRevision &+= 1
            model.roleRevision &+= 1

        case .forumUnreads(_, let counts):
            model.applyForumUnreads(counts)

        case .threadUpserted(let thread, let isNew, let membership):
            model.applyThreadUpsert(thread, membership: membership, isNewlyCreated: isNew)
            // A thread carries its own limit, and a moderator can change it.
            model.reconcileSlowmode(in: thread.id)

        case .threadRemoved(let threadID, _):
            model.applyThreadRemoval(threadID)
            model.drafts.forget(threadID)

        case .threadListSynced(let guildID, let channelIDs, let threads, let memberships):
            model.applyThreadListSync(
                threads, parentIDs: channelIDs, memberships: memberships, guildID: guildID
            )

        case .threadMembershipChanged(let membership):
            model.applyThreadMembership(membership)

        case .threadMemberCountChanged(let threadID, let count):
            model.applyThreadMemberCount(count, in: threadID)

        case .channelUpserted(let channel):
            let isNewConversation = channel.guildID == nil && model.channelIndex[channel.id] == nil
            model.channelIndex.upsert(channel)
            model.permissionGate.invalidate()
            // A group just entered turns its invite cards' Join Group DM into Joined.
            if isNewConversation { model.inviteSettlementChanged() }
            // A moderator changing the limit moves a wait that is running.
            model.reconcileSlowmode(in: channel.id)
            model.sidebarRevision &+= 1
            model.roleRevision &+= 1

        case .channelRemoved(let channelID):
            model.forgetChannel(channelID)

        case .presenceUpdated(let presence):
            enqueue(presence)

        case .typingStarted(let channelID, let userID, let at, let style):
            // Discord's own indicator expires after ten seconds with no further
            // signal, and matching that is what stops a "typing…" from a closed
            // tab hanging on the composer forever.
            let expiry = at.addingTimeInterval(10)
            model.noteTyping(userID, in: channelID, until: expiry, style: style)
            armTypingExpiry(at: expiry)

        case .membersChunk(let guildID, let members, let users, let presences):
            ingestMembers(members, users: users, presences: presences, inGuild: guildID)

        case .memberRemoved(let guildID, let userID):
            // A kick, a ban or a leave. The roster's own list op takes them out
            // of the drawn list; this takes them out of the member table every
            // gate and profile reads.
            removeMember(userID, from: guildID)

        case .bulkBanFinished(let guildID, let banned, let failed):
            applyBulkBanOutcome(in: guildID, banned: banned, failed: failed)

        case .joinRequestChanged(let request, let userID):
            applyJoinRequestEvent(request, userID: userID)

        case .joinRequestRemoved(let guildID, let userID):
            removeJoinRequest(guildID, userID: userID)

        case .memberListUpdated(let update):
            ingestMembers(
                update.members, users: update.users, presences: update.presences,
                inGuild: update.guildID
            )
            guard let listID = update.listID else { return }
            let key = MemberListKey(guildID: update.guildID, listID: listID)
            model.memberLists[key, default: MemberList()].apply(update.operations, groups: update.groups)
            model.memberListRevision &+= 1

        case .channelAcknowledged(let channelID, let messageID, let mentionCount, let isManual):
            // **Only a Mark Unread moves the cursor back.** An ordinary ack
            // landing behind where the reader already is — their own words
            // since, a message read since — is the past: Discord's divider
            // hangs on its oldest unread, which an ack clears, so a late one
            // draws nothing there. This divider hangs on the cursor, and taking
            // it back put "NEW" in front of the reader's newest message.
            if !isManual, let messageID, let current = model.readStates[channelID]?.lastAcknowledgedID,
               messageID.rawValue < current.rawValue
            {
                return
            }
            model.readStates[channelID, default: ReadState()].lastAcknowledgedID = messageID
            model.readStates[channelID, default: ReadState()].mentionCount = mentionCount
            model.noteForumPostRead(channelID)
            model.sidebarRevision &+= 1
            model.railRevision &+= 1

        case .currentUserUpdated(let user, let premiumType, let ageVerificationStatus, let verification):
            model.users[user.id] = user.merged(over: model.users[user.id])
            rememberAccount(user)
            model.entitlements = model.entitlements.updated(
                premiumType: premiumType,
                ageVerificationStatus: ageVerificationStatus
            )
            // Confirming an e-mail from its link lands here, which is what lets
            // an open application form take its row's tick without reopening.
            if let verification { model.accountVerification = verification }
            model.identityRevision &+= 1

        case .friendNicknameChanged(let userID, let nickname):
            // Applied whatever set it: the reader's own rename settles on the
            // same answer its optimistic write already made, and one made on a
            // phone reaches this window without a refetch.
            model.applyFriendNickname(nickname, for: userID)

        case .interactionModalCreated(let modal):
            // The form is the answer to the interaction that raised it, so
            // that interaction's waiting banner is done — Discord deletes its
            // own "thinking" placeholder for the same nonce.
            if let nonce = modal.nonce { model.pendingInteractions[nonce] = nil }
            model.interactionModal = InteractionModalState(modal: modal, answers: modal.initialAnswers)

        case .userSettingsChanged(let folders, let preferences, let audioContext):
            // The rail rearranged in another client — or the echo of this
            // one's own write, which changes nothing it has not already drawn.
            if let folders { applyFolderSettings(folders) }
            model.syncedPreferences.apply(preferences)
            if let theme = preferences.accountTheme { adoptAccountTheme(theme) }
            if let audioContext { applyAudioContext(audioContext) }

        case .guildSettingsChanged(let guildID, let pinned, let muted, let settings):
            // **Only the private-channel entry carries pins**, and it is the
            // one whose `guild_id` is null. A server's entry arriving here
            // would otherwise clear every pin in the direct-message list,
            // because its own override set has none in it.
            if guildID == nil { model.applyPinnedChannels(pinned) }
            for channelID in model.channelIndex.allPrivateChannelIDs() {
                model.applyChannelMute(muted.contains(channelID), channelID: channelID)
            }
            // A server's own record. Applied whatever set it: our own write
            // settles on the answer its optimistic update already made, and one
            // made on a phone reaches the open menu without a refetch.
            if let settings { model.applyGuildUserSettings(settings) }

        case .recentMentionDeleted(let messageID):
            // Dismissed here, or on another client. Applied either way: the
            // optimistic set already holds it for our own act, and `insert`
            // makes the echo a no-op.
            model.inbox.dismissedMentionIDs.insert(messageID)
            model.inbox.revision &+= 1

        case .savedMessageAdded(let saved, let author):
            if let author, model.users[author.id] == nil { model.users[author.id] = author }
            // **Upsert, not append.** Discord re-sends this when a reminder's
            // date is changed, so a blind append would draw the same bookmark
            // twice — and the second one would be the one the reader sees.
            if let index = model.inbox.saved?.firstIndex(where: { $0.id == saved.id }) {
                model.inbox.saved?[index] = saved
            } else if model.inbox.saved != nil {
                model.inbox.saved?.append(saved)
            }
            model.bookmarkedMessageIDs.insert(saved.id)
            model.inbox.revision &+= 1
            model.messageContentRevision &+= 1

        case .savedMessageRemoved(_, let messageID):
            model.inbox.saved?.removeAll { $0.id == messageID }
            model.bookmarkedMessageIDs.remove(messageID)
            model.inbox.revision &+= 1
            model.messageContentRevision &+= 1

        case .relationshipChanged(let userID, let kind, let isIgnored, let user, let facts):
            // **Applied whatever the client did.** These arrive for the reader's
            // own acts as well as for somebody else's, so the optimistic write
            // and the echo settle on the same answer — and a request accepted
            // on a phone reaches this window without a refetch.
            if let user, model.users[userID] == nil { model.users[userID] = user }
            if kind == .none {
                model.relationships[userID] = nil
                model.relationshipFacts[userID] = nil
                model.blockedUserIDs.remove(userID)
                model.ignoredUserIDs.remove(userID)
            } else {
                model.relationships[userID] = kind
                // **Only when the event carried some.** A relationship update
                // with nothing remarkable on it must not erase the `since` a
                // pending request already has — that date is the friend-request
                // list's only ordering.
                if let facts { model.relationshipFacts[userID] = facts }
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
            // A friendship made or lost moves a friend link's Add Friend.
            model.inviteSettlementChanged()
        }
    }

    /// Posts a banner for a message that earns one.
    ///
    /// **The authorisation is asked for HERE**, the first time there is genuinely
    /// something to tell somebody about, rather than at launch — a permission
    /// sheet in front of an app nobody has signed into yet is a question about
    /// something they have not seen.
    /// Interrupts VoiceOver with a message that arrived in the channel being
    /// read — and only that one.
    ///
    /// **A different question from the banner above it.** `announce` posts for a
    /// channel the reader is *not* looking at; this one fires only for the
    /// channel they are, because a screen-reader user reading a transcript has
    /// no other way to learn that something appeared below them. The banner and
    /// this are mutually exclusive by construction.
    ///
    /// **Off by default, and that is not timidity.** An interruption per message
    /// on a busy channel makes the app unusable with a screen reader, which is
    /// the opposite of what the setting is for; somebody who wants it is
    /// choosing it for a quiet conversation.
    ///
    /// `.low` priority so it queues behind whatever the reader asked for rather
    /// than cutting across it mid-word.
    private func speakIfReading(_ message: Message) {
        guard AppSettings.shared.announcesNewMessages,
              message.channelID == model.selectedChannelID,
              message.authorID != model.currentUserID,
              let window = NSApp?.keyWindow
        else { return }
        let name = model.users[message.authorID]?.preferredName ?? "Someone"
        let body = !message.content.isEmpty
            ? message.content
            : VoiceNoteWords.isVoiceNote(message) ? "sent a voice message" : "sent an attachment"
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(name): \(body)",
                .priority: NSAccessibilityPriorityLevel.low.rawValue,
            ]
        )
    }

    private func announce(_ message: Message) {
        guard let notice = model.notice(for: message) else { return }
        // **The overlay first, and then nothing else.** A system banner behind
        // a full-screen game is a banner nobody sees, and a reader who got both
        // would be told twice about one message.
        if model.announceOverOverlay(
            OverlayNotice(
                title: notice.title,
                body: notice.body,
                monogram: String(notice.title.prefix(1)).uppercased(),
                avatarURL: model.users[message.authorID]?.avatarHash.flatMap {
                    CDN.avatar(userID: message.authorID, hash: $0, side: 30)
                },
                channelID: notice.channelID,
                messageID: notice.messageID
            )
        ) { return }
        // Streamer Mode's "Disable notifications" — and its sounds, which a
        // banner would otherwise carry onto the stream.
        let streamer = StreamerMode.shared
        guard !streamer.disablesNotifications else { return }
        let notifier = model.notifier
        let playsSound = AppSettings.shared.playsNotificationSound && !streamer.disablesSounds
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
        // **The reader's own words are read**, wherever they were written —
        // except a poll of theirs ending, Discord's one `SELF_MENTIONABLE_SYSTEM`
        // kind, which is news to them.
        if message.authorID == model.currentUserID, message.kind != .pollResult {
            model.acknowledgeOwnMessage(message.id, in: message.channelID)
            return
        }
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
        let movesHost = model.listeningAlong.map { pendingPresences[$0.hostID] != nil } ?? false
        model.presences.merge(pendingPresences) { _, new in new }
        pendingPresences.removeAll(keepingCapacity: true)
        model.presenceRevision &+= 1
        if touchesVoice {
            model.voicePresenceRevision &+= 1
            refreshVoiceActivityIcons()
        }
        if movesHost { listenAlongHostMoved() }
    }

    // MARK: Requests

    /// Fetches one page of a channel's history and lands it in the window.
    ///
    /// All three directions share one path, because what happens to a page
    /// after it arrives — its authors, its threads, its unfurls, the one retry
    /// — does not depend on which way it came from. Where it lands does, and
    /// that is `TranscriptWindow`'s business.
    func loadHistory(in channelID: ChannelID, _ request: HistoryRequest, attempt: Int = 1) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = switch request {
                case .older(let before): try await rest.messages(in: channelID, before: before)
                case .newer(let after): try await rest.messages(in: channelID, after: after)
                case .present: try await rest.messages(in: channelID)
                }
                Self.trace(
                    "history \(channelID) \(request): \(page.messages.count) messages"
                    + (page.wireCount == page.messages.count
                        ? "" : " (\(page.wireCount - page.messages.count) unreadable)")
                    + ", \(page.authors.count) authors"
                )
                absorb(page)
                var landed = true
                model.mutateBox(channelID) { box in
                    switch request {
                    case .older(let before):
                        landed = box.receiveOlder(
                            page.messages, wireCount: page.wireCount, before: before
                        )
                        box.isLoadingHistory = false
                        box.historyFailure = nil
                    case .newer(let after):
                        landed = box.receiveNewer(
                            page.messages, wireCount: page.wireCount, after: after
                        )
                        box.isLoadingNewer = false
                        box.newerPageFailures = 0
                    case .present:
                        box.receivePresent(page.messages, wireCount: page.wireCount)
                        box.isLoadingNewer = false
                        box.isLoadingHistory = false
                        box.historyFailure = nil
                    }
                }
                // **A page the window moved away from is dropped whole** — see
                // `MessageBox.receiveOlder`. Nothing about it is resolved:
                // members and unfurls for rows nobody will see are requests
                // the reader pays for.
                guard landed else {
                    Self.trace("history \(channelID) \(request): window moved, page dropped")
                    return
                }
                model.messageContentRevision &+= 1
                resolveSpotifyUnfurls(in: page.messages)
                resolveInvites(in: page.messages)
                resolveHostedCards(in: page.messages, inGuild: model.channelIndex.guildID(of: channelID))
                resolveMessageMembers(in: page.messages, channelID: channelID)
            } catch {
                Self.trace(
                    "history \(channelID) \(request) FAILED (attempt \(attempt)): "
                    + Self.describe(error)
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
                    let box = model.messages(in: channelID)
                    let stillWanted = switch request {
                    case .older: box?.isLoadingHistory == true
                    case .newer, .present: box?.isLoadingNewer == true
                    }
                    guard stillWanted else { return }
                    loadHistory(in: channelID, request, attempt: attempt + 1)
                    return
                }

                model.mutateBox(channelID) { box in
                    switch request {
                    case .older:
                        box.isLoadingHistory = false
                        box.historyFailure = Self.describe(error)
                        // A refusal is not a gap in the history; there is
                        // nothing above to page to. Leaving `hasMoreHistory`
                        // true keeps the viewport asking for a page that can
                        // never land.
                        if !Self.isWorthRetrying(error) { box.hasMoreHistory = false }
                    case .newer, .present:
                        // The runway below stays. Scrolling does not ask again,
                        // or it would ask on every tick: a failure on the way is
                        // retried on a pause instead, and the jump control is the
                        // way out of a refusal.
                        box.isLoadingNewer = false
                        box.newerPageFailed = true
                        if Self.isWorthRetrying(error) { box.newerPageFailures += 1 }
                    }
                }
                model.messageContentRevision &+= 1
                if case .newer = request, Self.isWorthRetrying(error) {
                    scheduleNewerRetry(in: channelID)
                }
            }
        }
    }

    /// Asks again for a page below the window that failed on the way.
    ///
    /// **A dropped page used to be the end of the transcript.** The runway
    /// stayed under the last message, the viewport stopped asking so it would
    /// not ask on every tick, and the only way on was Jump to Present — which
    /// is a transcript that "cuts off" below a jump. A failure worth retrying
    /// now comes back by itself after a pause that doubles each time: 4, 8,
    /// 16, 32, then every minute.
    private func scheduleNewerRetry(in channelID: ChannelID) {
        let failures = max(1, model.messages(in: channelID)?.newerPageFailures ?? 1)
        let delay = min(60, 4 << min(failures - 1, 4))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled,
                  let box = model.messages(in: channelID),
                  box.hasMoreNewer, box.newerPageFailed, !box.isLoadingNewer
            else { return }
            Self.trace("history \(channelID) newer: retrying after \(delay)s")
            model.mutateBox(channelID) { $0.newerPageFailed = false }
            model.loadLaterHistory(in: channelID)
        }
    }

    /// Everything a page teaches the store beyond its rows: who wrote it, and
    /// the threads hanging off it.
    ///
    /// Authors first: a row laid out before its author is known draws
    /// "Unknown" and would need a second relayout to correct itself.
    ///
    /// The revision moves only if a name actually changed. It is the mention
    /// table's memo key, and that table is proportional to the whole account —
    /// so bumping it for a page whose authors were all already known rebuilds
    /// every name in the session to discover that none of them moved.
    func absorb(_ page: MessagePage) {
        var namesChanged = false
        for (userID, author) in page.authors {
            let merged = author.merged(over: model.users[userID])
            guard model.users[userID] != merged else { continue }
            model.users[userID] = merged
            namesChanged = true
        }
        if namesChanged { model.identityRevision &+= 1 }
        model.applyThreadsFromMessages(page.threads)
        noteGameMentions(in: page.messages)
    }

    /// Whether asking again could plausibly answer differently.
    static func isWorthRetrying(_ error: any Error) -> Bool {
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
            subscribeMemberListPages(nil, for: channelID)
            return
        }
        if let held = model.demoTranscript(for: channelID) {
            model.setMessages(held, in: channelID)
            subscribeMemberListPages(nil, for: channelID)
            return
        }
        Self.trace("open \(channelID), fetching newest page")
        model.mutateBox(channelID) { box in
            box.isLoadingHistory = true
            box.historyFailure = nil
        }
        loadHistory(in: channelID, .older(before: nil))
        subscribeToMemberList(for: channelID)
    }

    /// Asks the gateway for the roster of the channel being viewed.
    ///
    /// The op-14 lazy subscription, which is the only route that answers with
    /// members **and their presences** — the documented member request answers
    /// with members and no presence for them, so a roster built on it shows
    /// everyone offline.
    /// Asks the gateway about message authors this client holds no member
    /// record for.
    ///
    /// **A user is not a member, and only a member has roles.** Somebody who
    /// posted an hour ago is three hundred rows down the roster, or offline, or
    /// hidden in a collapsed group — so the op-14 subscription that fills the
    /// member list never names them, and they arrive at the transcript with a
    /// user record and nothing else. No roles is no name colour, no role icon,
    /// and an empty Roles section on their profile. Nothing fails; the member
    /// simply is not there, for the rest of the session.
    ///
    /// **Asked once per person per session**, because the answer is a member
    /// record that the gateway then keeps current with `GUILD_MEMBER_UPDATE`.
    /// The set is what stops a channel of two hundred messages from the same
    /// six people asking six times a page.
    ///
    /// Direct messages have no guild and no roles, so there is nothing to ask.
    func resolveMessageMembers(in messages: [Message], channelID: ChannelID) {
        guard let guildID = model.channelIndex.guildID(of: channelID), let socket else {
            return
        }
        let known = model.members[guildID]
        var wanted: [UserID] = []
        for message in messages {
            let userID = message.authorID
            // Webhooks and apps have no member record to fetch and asking for
            // one is a request Discord answers with an empty chunk.
            guard !(model.users[userID]?.isBot ?? false), message.webhookID == nil,
                  known?[userID] == nil,
                  memberRequests.insert(MemberRequest(guildID: guildID, userID: userID)).inserted
            else { continue }
            wanted.append(userID)
        }
        guard !wanted.isEmpty else { return }
        Task { await socket.requestGuildMembers(guildID: guildID, userIDs: wanted) }
    }

    /// Asks a server who goes by a name, for the member list's search.
    func queryMembers(_ query: String, inGuild guildID: GuildID) {
        guard let socket else { return }
        Task { await socket.queryGuildMembers(guildID: guildID, query: query) }
    }

    /// Everyone in a room in this server that this session has no record of — for
    /// Active Now, which is the one part of a big server's list that isn't limited
    /// to the rows the server sends. Their presences come back with them.
    func requestPeopleInRooms(inGuild guildID: GuildID) {
        guard let socket else { return }
        let known = model.members[guildID]
        var wanted: [UserID] = []
        for state in model.voiceStates.values where state.guildID == guildID && state.channelID != nil {
            guard known?[state.userID] == nil || model.presences[state.userID] == nil,
                  memberRequests.insert(MemberRequest(guildID: guildID, userID: state.userID)).inserted
            else { continue }
            wanted.append(state.userID)
        }
        guard !wanted.isEmpty else { return }
        Task { await socket.requestGuildMembers(guildID: guildID, userIDs: wanted) }
    }

    /// What a role mention's flyout needs: the role's holders by id, asked of
    /// the gateway for anybody this session has no record of, and every
    /// role's head count — Discord's preload for its role popout (`545868`).
    ///
    /// **The ids are reused for ten seconds per role**, Discord's own window,
    /// so clicking a run of mentions of one role asks once. The counts are the
    /// table the Channels & Roles page already keeps, asked once per server.
    func loadRoleMembers(_ roleID: RoleID, in guildID: GuildID) {
        let key = RoleMembersKey(guildID: guildID, roleID: roleID)
        let now = Date()
        if roleMemberFetches[key].map({ now.timeIntervalSince($0) >= 10 }) ?? true {
            roleMemberFetches[key] = now
            Task { [weak self] in
                guard let self else { return }
                do {
                    let ids = try await self.rest.roleMemberIDs(of: roleID, in: guildID)
                    let known = self.model.members[guildID]
                    let wanted = ids.filter { userID in
                        known?[userID] == nil
                            && self.memberRequests.insert(MemberRequest(guildID: guildID, userID: userID)).inserted
                    }
                    if !wanted.isEmpty, let socket = self.socket {
                        await socket.requestGuildMembers(guildID: guildID, userIDs: wanted)
                    }
                } catch {
                    // Asked again on the next click rather than never.
                    self.roleMemberFetches[key] = nil
                    Self.trace("role \(roleID) members failed: \(Self.describe(error))")
                }
            }
        }
        loadRoleMemberCounts(guildID)
    }

    private func subscribeToMemberList(for channelID: ChannelID) {
        guard let guildID = model.channelIndex.guildID(of: channelID) else { return }
        subscribeMemberListPages(nil, for: channelID)
        requestVoiceChannelInfo(inGuild: guildID)
        // The server on screen just changed, and with it the set of people whose
        // games the sidebar has to draw a mark for.
        refreshVoiceActivityIcons()
    }

    /// The rows of the member list on screen moved.
    ///
    /// Subscribes the pages around them — Discord's `updateSubscription`, which
    /// its list calls fifty milliseconds after the scroll stops moving.
    ///
    /// **All of a list that fits**, whatever's on screen: see `MemberList.pages`.
    func showMemberListRows(_ runs: [ClosedRange<Int>], margin: Int) {
        guard let channelID = model.selectedChannelID,
              let target = model.memberListTarget(for: channelID)
        else { return }
        let rowCount = model.memberLists[target.key]?.rowCount ?? 1
        subscribeMemberListPages(
            MemberList.pages(visible: runs, margin: margin, rowCount: rowCount),
            for: channelID
        )
    }

    /// Asks for `pages` of the list a channel shows, unless that is already the
    /// subscription in force — Discord's client compares the same way before it
    /// sends. The server answers new pages with `SYNC` and pages dropped from
    /// the request with `INVALIDATE`.
    ///
    /// **Nil keeps the pages of the list already subscribed**, when the channel
    /// shows that same list — most channels in a server share one — and starts
    /// at the first page otherwise. Discord keeps its last five channels
    /// subscribed to the same effect: a column scrolled to row five hundred
    /// does not blink back to placeholders because the reader changed channel.
    private func subscribeMemberListPages(_ pages: [ClosedRange<Int>]?, for channelID: ChannelID) {
        guard let target = model.memberListTarget(for: channelID), let socket else { return }
        let kept = memberListSubscription.flatMap { $0.key == target.key ? $0.pages : nil }
        let subscription = MemberListSubscription(
            key: target.key,
            channelID: target.channelID,
            pages: pages ?? kept ?? [0...MemberList.pageSize - 1]
        )
        guard subscription != memberListSubscription else { return }
        memberListSubscription = subscription
        Task {
            await socket.subscribeToMemberList(
                guildID: subscription.key.guildID,
                channelID: subscription.channelID,
                ranges: subscription.pages.map { [$0.lowerBound, $0.upperBound] }
            )
        }
    }

    /// Writes the people a roster answer names into the stores.
    ///
    /// **Merged, never replaced.** A roster user carries no bio, no banner and
    /// no badges, so writing one straight over a profile-fetched record wipes
    /// the card the reader is looking at.
    func ingestMembers(
        _ members: [UserID: Member],
        users: [UserID: User],
        presences: [UserID: Presence],
        inGuild guildID: GuildID
    ) {
        guard !members.isEmpty else { return }
        model.members[guildID, default: [:]].merge(members) { _, new in new }
        model.users.merge(users) { existing, new in new.merged(over: existing) }
        model.presences.merge(presences) { _, new in new }
        model.permissionGate.invalidate()
        model.memberRevision &+= 1
        model.presenceRevision &+= 1
        model.roleRevision &+= 1
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
        // **Not again within a minute** — a member list clicked through, a
        // card closed and reopened — except the reader's own, which an edit
        // has to be able to refresh. The card draws what it has meanwhile.
        if userID != model.currentUserID,
           let fetched = model.profileFetchedAt[ProfileFetchKey(userID: userID, guildID: guildID)],
           Date.now.timeIntervalSince(fetched) < Self.profileFreshness
        {
            return
        }
        // Marked loading on the click, not a hop later, so the card that opens
        // with it already shows its skeleton.
        guard beginProfileFetch(of: userID) else { return }
        Task { [weak self] in await self?.applyProfile(of: userID, inGuild: guildID) }
    }

    /// Fetches somebody's profile and applies it, returning once it is on the
    /// store — or at once, when a fetch for them is already out.
    func fetchProfile(of userID: UserID, inGuild guildID: GuildID?) async {
        guard beginProfileFetch(of: userID) else { return }
        await applyProfile(of: userID, inGuild: guildID)
    }

    /// How long a fetched profile is taken as current before an open asks
    /// again.
    static let profileFreshness: TimeInterval = 60

    private func beginProfileFetch(of userID: UserID) -> Bool {
        guard profileFetches.insert(userID).inserted else { return false }
        model.profilesLoading.insert(userID)
        return true
    }

    private func applyProfile(of userID: UserID, inGuild guildID: GuildID?) async {
        defer {
            profileFetches.remove(userID)
            model.profilesLoading.remove(userID)
        }
        do {
            let fetched = try await rest.profile(of: userID, inGuild: guildID)
            model.profileFetchFailures.remove(userID)
            model.profileFetchedAt[ProfileFetchKey(userID: userID, guildID: guildID)] = .now
            let user = fetched.user
            // **What the card will actually draw from, by value.** The
            // shape dump beside this one names the response's KEYS, which
            // cannot tell a field that is absent from one that arrived
            // null — and those are the same picture on screen and two
            // different faults. One line per fetch, gated on the sink.
            Self.trace(Self.describe(profile: user, guildLayer: fetched.guildUser))
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
            // The per-server layer, kept beside the account's rather than
            // folded into it — which is what lets the profile's own menu
            // offer both. Assigned whole for the same reason the account is:
            // a per-server bio somebody deleted has to be able to go.
            if let guildID = fetched.guildID {
                let guildUser = fetched.guildUser
                if model.memberProfiles[guildID]?[userID] != guildUser {
                    model.memberProfiles[guildID, default: [:]][userID] = guildUser
                    model.identityRevision &+= 1
                }
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
            // A cancelled ask says nothing about the profile.
            if !(error is CancellationError) { model.profileFetchFailures.insert(userID) }
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
                let profile = try await rest.guildProfile(of: guildID)
                model.guildProfiles[guildID] = profile
                deriveBannerColor(
                    guildID: guildID,
                    iconHash: profile.iconHash ?? model.guilds[guildID]?.iconHash,
                    brandColor: profile.brandColorPrimary
                )
                // **The profile names games by id and nothing else**, so the
                // card's row is blank until the store entries arrive — a name
                // and an icon are a second request, which is exactly what
                // Discord's own capture shows it making. Only the ones this
                // client does not already hold are asked for.
                let missing = profile.gameApplicationIDs.filter { model.games[$0] == nil }
                if !missing.isEmpty { await loadGames(ids: missing) }
            } catch {
                Self.trace("guild profile \(guildID) failed: \(Self.describe(error))")
                // Discord's two answers (`109026`): 50001 is a server that
                // limited who sees its profile; anything else is a failure
                // the card offers to try again.
                let isLimited = switch error as? DiscordREST.Failure {
                case .forbidden(let code): code == 50001 || code == nil
                case .api(_, let code, _): code == 50001
                default: false
                }
                model.guildProfileRefusals[guildID] = isLimited ? .limited : .failed
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
    /// - Parameter highlights: whether the landing message is lit — see
    ///   `MessageJump.highlights`.
    func jumpToMessage(_ messageID: MessageID, in channelID: ChannelID, highlights: Bool = true) {
        model.selectChannel(channelID)

        if model.messages(in: channelID)?.messages.contains(where: { $0.id == messageID }) == true {
            model.requestJump(to: messageID, in: channelID, highlights: highlights)
            return
        }
        reanchor(channelID, at: .message(messageID), highlights: highlights)
    }

    /// Discord's Jump To Top: a thread's first message, fetched from the very
    /// start of the channel — Discord's own target is message "0".
    ///
    /// **Not a jump to the thread's own id.** A forum post's opening message
    /// shares the post's id, but a thread started from a message does not: its
    /// id is that message's, in the parent, and nothing in the thread has it.
    func jumpToStart(of channelID: ChannelID) {
        if let box = model.messages(in: channelID), !box.hasMoreHistory, let first = box.messages.first {
            model.requestJump(to: first.id, in: channelID, highlights: false)
            return
        }
        reanchor(channelID, at: .start, highlights: false)
    }

    /// Discord's Jump to Surrounding, on an AutoMod alert: the member's
    /// channel at the moment AutoMod acted, which is the alert's own id — and
    /// no message in that channel has it, so the transcript lands on the one
    /// nearest it, unlit.
    func jumpToSurrounding(_ moment: MessageID, in channelID: ChannelID) {
        model.selectChannel(channelID)
        reanchor(channelID, at: .near(moment), highlights: false)
    }

    /// Where a re-anchored transcript is centred.
    private enum JumpAnchor {
        /// Around one message — a link, a reply, a search result.
        case message(MessageID)
        /// Around a moment no message has, landing on the nearest one.
        case near(MessageID)
        /// The channel's first page.
        case start
    }

    /// Replaces a transcript with one page fetched where the reader is going,
    /// then lands on it.
    private func reanchor(_ channelID: ChannelID, at anchor: JumpAnchor, highlights: Bool) {
        guard jumpFetches.insert(channelID).inserted else { return }
        model.mutateBox(channelID) { box in
            box.isLoadingHistory = true
            box.historyFailure = nil
        }
        Task { [weak self] in
            guard let self else { return }
            defer { jumpFetches.remove(channelID) }
            do {
                let page = switch anchor {
                case .message(let messageID), .near(let messageID):
                    try await rest.messages(in: channelID, around: messageID)
                case .start: try await rest.messages(in: channelID, after: MessageID(rawValue: 0))
                }
                absorb(page)
                let newest = model.channelIndex[channelID]?.lastMessageID
                let edges: (older: Bool, newer: Bool) = switch anchor {
                case .message(let messageID), .near(let messageID):
                    // **A jump can leave the transcript cut off from the
                    // present**, and this is where it finds out: Discord's own
                    // arithmetic over where the target landed in the page.
                    TranscriptWindow.edges(
                        ofAround: page.messages.map(\.id),
                        wireCount: page.wireCount,
                        target: messageID,
                        limit: DiscordREST.historyPageSize,
                        newestInChannel: newest
                    )
                case .start:
                    // Nothing is older than the first page. A full one stops
                    // short of the present unless it holds the newest message.
                    (false, page.wireCount >= DiscordREST.historyPageSize && page.messages.last?.id != newest)
                }
                model.mutateBox(channelID) { box in
                    box.receiveAround(page.messages, edges: edges)
                    box.isLoadingHistory = false
                    box.isLoadingNewer = false
                    box.historyFailure = nil
                }
                model.messageContentRevision &+= 1
                resolveSpotifyUnfurls(in: page.messages)
                resolveInvites(in: page.messages)
                resolveHostedCards(in: page.messages, inGuild: model.channelIndex.guildID(of: channelID))
                resolveMessageMembers(in: page.messages, channelID: channelID)
                let target: MessageID? = switch anchor {
                case .message(let messageID): messageID
                // The first at or after the moment, else the last before it.
                case .near(let moment):
                    page.messages.filter { $0.id >= moment }.min { $0.id < $1.id }?.id
                        ?? page.messages.max { $0.id < $1.id }?.id
                case .start: page.messages.first?.id
                }
                if let target {
                    model.requestJump(to: target, in: channelID, highlights: highlights)
                }
            } catch {
                Self.trace("jump in \(channelID) failed: \(Self.describe(error))")
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
        // Vencord's SilentTyping: `startTyping` dispatches nothing — no
        // request, and so no slowmode clock from its answer either.
        guard !AppSettings.shared.hidesTyping else { return }
        let now = Date()
        if let last = lastTypingSent[channelID], now.timeIntervalSince(last) < Self.typingInterval {
            return
        }
        lastTypingSent[channelID] = now
        Task { [weak self] in
            guard let self else { return }
            do {
                // **The answer is a slowmode clock.** It is the one place a
                // send made on another device shows up here, so the countdown
                // is on screen before the reader presses Return rather than
                // after the server refuses them. See `DiscordREST.typing`.
                if let remaining = try await rest.typing(in: channelID) {
                    model.applySlowmode(remaining: remaining, in: channelID)
                }
            } catch {
                // A dropped typing signal costs a reader three dots they never
                // knew were coming. It is never worth a retry and never worth a
                // message on screen.
                Self.trace("typing \(channelID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Lets typing indicators lapse: one timer for the whole session, due at
    /// the earliest expiry, re-armed by whatever it prunes.
    ///
    /// **One, not one per surface.** The composer's line, the roster's dots and
    /// the DM list's pill all read the same table, so the table is what keeps
    /// time — a surface that ran its own clock would be a timer per open
    /// conversation, each re-deriving the same answer.
    private func armTypingExpiry(at expiry: Date) {
        if let deadline = typingExpiryDeadline, deadline <= expiry { return }
        typingExpiryTask?.cancel()
        typingExpiryDeadline = expiry
        typingExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            typingExpiryDeadline = nil
            typingExpiryTask = nil
            if let next = model.pruneTyping(now: .now) { armTypingExpiry(at: next) }
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
        // **Read through `current()`, so a status whose moment has passed is
        // not re-broadcast.** Discord leaves an expired status in the blob and
        // lets the time pass, exactly as it does with a mute.
        let custom = model.selfCustomStatus?.current()
        let text = custom?.text
        let emoji = custom?.emoji
        // **The activities ride along.** `activities` is one array and the
        // write replaces all of it, so publishing a status without the running
        // game and the running activity would erase both from everybody's
        // roster. `publishedActivities` composes them and applies the sharing
        // preference.
        let activities = model.publishedActivities
        Task {
            await socket.updatePresence(
                status: status,
                customStatus: text,
                customEmoji: emoji,
                activities: activities
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
    ///
    /// **The set is the model's**, because the DM column reads it: it holds its
    /// card until a frame it names has resolved. Inserted before the task
    /// starts, so no frame can see the profile answered and the frame not yet
    /// asked for.
    func loadCollectible(sku: String) {
        guard model.collectiblesLoading.insert(sku).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.collectiblesLoading.remove(sku) }
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
        guard let url = model.themeArtworkURL(of: user, user.decoration) else { return }
        derivePalette(at: url)
    }

    /// Quantises one picture at the profile's rendition, once — a profile's
    /// artwork, or the avatar a call tile takes its colour from (Discord reads
    /// both from the same picture at 80, so they share one entry).
    func derivePalette(at url: URL) {
        guard model.derivedPalettes[url] == nil, paletteFetches.insert(url).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { paletteFetches.remove(url) }
            let key = ImageStore.Key(
                url: url, maximumPixelSize: ProfileThemePalette.profilePixelSize
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
        // **Forward only.** The cursor can already stand past the newest
        // message Discord has sent: the reader's own send is read the moment
        // its echo is drawn (`AppModel.acknowledgeOwnMessage`), under a nonce
        // newer than everything loaded. The transcript reaching its foot a
        // moment later acknowledged the newest LOADED message — older than the
        // echo — and moving the cursor back to it drew "NEW" in front of the
        // reader's own words until Discord's copy arrived. Only Mark Unread
        // moves the cursor back, and it writes the state itself.
        guard state.lastAcknowledgedID.map({ $0.rawValue < messageID.rawValue }) ?? true else { return }
        state.lastAcknowledgedID = messageID
        state.mentionCount = 0
        model.readStates[channelID] = state
        model.noteForumPostRead(channelID)
        model.sidebarRevision &+= 1
        model.railRevision &+= 1
        Task { try? await rest.acknowledge(messageID, in: channelID) }
    }

    /// Whether a send has anything in it: words, a sticker, a file or a poll.
    ///
    /// **One rule for both of its callers.** The composer asks before holding a
    /// send for slowmode — an empty Return is not a send and must not flash a
    /// refusal — and `send` asks before sending. Two copies would drift.
    static func isSendable(
        _ content: String,
        stickerIDs: [UInt64],
        attachments: [PendingAttachment],
        poll: PollDraft? = nil,
        listenAlong: ListenAlongInvite? = nil
    ) -> Bool {
        !stickerIDs.isEmpty || !attachments.isEmpty || poll != nil || listenAlong != nil
            || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends a message, drawing it at once.
    ///
    /// **Discord's eager send.** The reader's words go into the transcript the
    /// moment Return is pressed, at half strength, and Discord's answer — the
    /// POST's reply or the socket's copy, whichever is first — replaces them
    /// (`MessageBox.receiveLive`). A refusal turns them red and keeps them, with
    /// Resend in their menu. A send with files is drawn as its upload instead —
    /// a card with a bar and a cancel — and a refused one goes back to the
    /// composer, words and files, because that is where Discord puts it.
    ///
    /// - Parameter stickerIDs: Stickers to send. A sticker is a message on its
    ///   own, so this is the one path where empty content is legitimate.
    /// - Parameter attachments: Files already staged in the composer. A message
    ///   may be nothing but these, which is the second such path.
    /// - Parameter poll: A poll from the editor — the third, drawn at once like
    ///   any send, as Discord's `sendPollMessage` is.
    /// - Returns: the send's nonce — its echo's id — or nil for nothing sent.
    @discardableResult
    func send(
        _ content: String,
        in channelID: ChannelID,
        replyingTo: MessageID?,
        pingsRepliedAuthor: Bool = true,
        stickerIDs: [UInt64] = [],
        attachments: [PendingAttachment] = [],
        poll: PollDraft? = nil,
        listenAlong: ListenAlongInvite? = nil,
        mediaMention: MediaMention? = nil,
        isVoiceMessage: Bool = false
    ) -> MessageID? {
        guard Self.isSendable(
            content, stickerIDs: stickerIDs, attachments: attachments, poll: poll, listenAlong: listenAlong
        ), let author = model.currentUserID
        else { return nil }
        let attachments = PendingAttachment.anonymising(attachments)
        let request = OutgoingMessage.Request(
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            replyingTo: replyingTo,
            pingsRepliedAuthor: pingsRepliedAuthor,
            stickerIDs: stickerIDs,
            poll: poll,
            listenAlong: listenAlong,
            mediaMention: mediaMention,
            isVoiceMessage: isVoiceMessage
        )
        // **Sending from older messages brings the reader back** — first, so
        // the echo lands in the window the reader is going to. Somebody who has
        // just said something wants to see it.
        if model.messages(in: channelID)?.hasMoreNewer == true {
            model.jumpToPresent(in: channelID)
        }
        let id = Self.mintNonce()
        let entry = OutgoingMessage(
            id: id,
            request: request,
            echo: model.echo(of: request, id: id, in: channelID, author: author, files: attachments),
            state: .sending,
            files: attachments
        )
        model.mutateBox(channelID) { $0.outbox.append(entry) }
        // In the same pass as the echo, so no frame draws "NEW" in front of it.
        model.acknowledgeOwnMessage(id, in: channelID)
        sendTasks[id] = Task { [weak self] in
            await self?.deliver(entry, in: channelID)
            self?.sendTasks[id] = nil
        }
        return id
    }

    /// Sends a refused message again, as a new send.
    func resend(_ id: MessageID, in channelID: ChannelID) {
        guard let entry = model.messages(in: channelID)?.outbox.first(where: { $0.id == id }),
              entry.state == .failed
        else { return }
        model.mutateBox(channelID) { $0.outbox.removeAll { $0.id == id } }
        send(
            entry.request.content,
            in: channelID,
            replyingTo: entry.request.replyingTo,
            pingsRepliedAuthor: entry.request.pingsRepliedAuthor,
            stickerIDs: entry.request.stickerIDs,
            attachments: entry.files,
            poll: entry.request.poll,
            listenAlong: entry.request.listenAlong,
            mediaMention: entry.request.mediaMention,
            isVoiceMessage: entry.request.isVoiceMessage
        )
    }

    /// Stops an upload from its card, and gives the words back.
    ///
    /// **Discord's `cancel`**: the text goes back to a composer that is empty,
    /// and the files do not come with it — somebody who cancelled an upload
    /// meant the files.
    func cancelUpload(_ id: MessageID, in channelID: ChannelID) {
        sendTasks.removeValue(forKey: id)?.cancel()
        guard let entry = model.messages(in: channelID)?.outbox.first(where: { $0.id == id }) else { return }
        model.mutateBox(channelID) { box in
            box.outbox.removeAll { $0.id == id }
            if box.draft.isEmpty { box.draft = entry.request.content }
        }
    }

    /// Queues a message on Discord's side for later — the composer while it is
    /// scheduling, and the poll editor's Schedule Poll. Returns once Discord has
    /// taken it.
    ///
    /// **Nothing is drawn in the transcript.** Discord's send skips its eager
    /// echo when a time is set (`_sendMessage`'s `null==W`): the message will
    /// not exist for hours. The files go up first, as for any send, and the
    /// answer is a row for the inbox's Scheduled list and a line saying when it
    /// will go (`859403`'s `c_`).
    func schedule(
        _ content: String,
        in channelID: ChannelID,
        at date: Date,
        replyingTo: MessageID? = nil,
        pingsRepliedAuthor: Bool = true,
        attachments: [PendingAttachment] = [],
        poll: PollDraft? = nil
    ) async throws {
        let row: ScheduledMessage?
        do {
            let uploaded = try await upload(PendingAttachment.anonymising(attachments), in: channelID) { _ in }
            row = try await rest.scheduleMessage(
                in: channelID,
                content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                at: date,
                replyingTo: replyingTo,
                pingsRepliedAuthor: pingsRepliedAuthor,
                attachments: uploaded,
                poll: poll
            )
        } catch {
            Self.trace("schedule in \(channelID) failed: \(Self.describe(error))")
            throw error
        }
        if let row { model.noteScheduledMessage(row) }
        model.reportScheduling(
            "Message scheduled for \(date.formatted(date: .long, time: .omitted)) at \(date.formatted(date: .omitted, time: .shortened))"
        )
    }

    /// What a refused schedule says — `859403`'s `vh`: the limit sentence on
    /// 640003, otherwise "Failed to schedule message." and Discord's reason.
    static func schedulingFailure(_ error: any Error, hasNitro: Bool) -> String {
        switch error {
        case DiscordREST.Failure.api(_, 640_003?, _), DiscordREST.Failure.forbidden(640_003?):
            InboxQuota.scheduledLimitMessage(hasNitro: hasNitro)
        default:
            "Failed to schedule message. \(describe(error))"
        }
    }

    private func deliver(_ entry: OutgoingMessage, in channelID: ChannelID) async {
        // `--demo` has nobody to send to, so what the reader recorded lands as it would.
        if LaunchOptions.current.usesDemoFixtures, entry.request.isVoiceMessage {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            receiveOwn(entry.echo, in: channelID)
            return
        }
        do {
            let uploaded = try await upload(entry.files, in: channelID) { [weak self] fraction in
                self?.reportUpload(fraction, of: entry.id, in: channelID)
            }
            // An invitation names the gateway session it was sent from.
            var listenAlong: (sessionID: String, partyID: String)?
            if let invite = entry.request.listenAlong, let sessionID = await socket?.currentSessionID {
                listenAlong = (sessionID, invite.partyID)
            }
            let message = try await inSendOrder { [rest, listenAlong] in
                try await rest.sendMessage(
                    in: channelID,
                    content: entry.request.content,
                    nonce: entry.nonce,
                    replyingTo: entry.request.replyingTo,
                    pingsRepliedAuthor: entry.request.pingsRepliedAuthor,
                    stickerIDs: entry.request.stickerIDs,
                    attachments: uploaded,
                    poll: entry.request.poll,
                    listenAlong: listenAlong,
                    mediaMention: entry.request.mediaMention,
                    flags: entry.request.isVoiceMessage ? .isVoiceMessage : []
                )
            }
            // Discord's copy is newer than the echo the cursor was moved to.
            receiveOwn(message, in: channelID)
            keepVoiceNote(of: entry, as: message)
            // **When Discord has taken it, not when Return was pressed** —
            // Discord's own `SLOWMODE_RESET_COOLDOWN` follows the POST.
            // Started earlier, a send that fails would leave the reader
            // waiting out a cooldown for a message nobody received.
            model.startSlowmode(afterSendIn: channelID)
        } catch {
            // Cancelled from its card, which has already taken it down.
            guard !Task.isCancelled else { return }
            refuse(entry, in: channelID, because: error)
        }
    }

    /// A note that's gone up never has to come back down: the recording becomes the
    /// copy this machine plays from.
    private func keepVoiceNote(of entry: OutgoingMessage, as message: Message) {
        guard entry.request.isVoiceMessage,
              let file = entry.files.first,
              let attachment = message.attachments.first
        else { return }
        // It may be playing under the echo's id.
        model.voicePlayer.rename(AttachmentID(rawValue: entry.id.rawValue), to: attachment.id)
        try? VoiceNoteCache.store(file.url, for: attachment.id)
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }

    /// Takes in one of the reader's own messages a route answered with — a
    /// send's copy, a forward, a share, a scheduled message sent now — and
    /// reads it, in the same pass.
    ///
    /// **One place for every such route**, because each answers with a message
    /// newer than the read cursor: taken in without the acknowledgement, the
    /// reader's own words sat behind the "NEW" line until the socket's copy
    /// caught up (`AppModel.acknowledgeOwnMessage`).
    func receiveOwn(_ message: Message, in channelID: ChannelID) {
        let trims = model.mayTrimOldest(in: channelID)
        model.mutateBox(channelID) { $0.receiveLive(message, trimming: trims) }
        model.acknowledgeOwnMessage(message.id, in: channelID)
        model.messageContentRevision &+= 1
    }

    /// Runs one POST after every send before it.
    ///
    /// **Discord sends one message at a time** (its `MessageQueue`), so two
    /// lines typed in quick succession arrive in the order they were written.
    /// Each send in its own task let the second overtake the first, which an
    /// echo drawn at once would only make plainer. The files go up before a
    /// send joins the queue, exactly as Discord's do.
    private func inSendOrder<Value: Sendable>(
        _ post: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = sendQueue
        let turn = Task { () async throws -> Value in
            await previous?.value
            return try await post()
        }
        sendQueue = Task { _ = try? await turn.value }
        return try await turn.value
    }

    /// Answers a refused send the way Discord's client does — see
    /// `SendRefusal`.
    private func refuse(_ entry: OutgoingMessage, in channelID: ChannelID, because error: any Error) {
        Self.log.error("send failed: \(Self.describe(error), privacy: .public)")
        let channel = model.channelIndex[channelID]
        let refusal = SendRefusal.of(
            error,
            isBotDirectMessage: channel?.kind == .directMessage
                && (channel?.recipientIDs.contains { model.users[$0]?.isBot == true } ?? false),
            // A forum, or a post in one — Discord words its cap as posts for both.
            isForumLike: channel.map {
                $0.isForumLike || $0.parentID.flatMap { model.channelIndex[$0] }?.isForumLike == true
            } ?? false,
            isPrivate: channel?.guildID == nil
        )
        if case .slowmode(let retryAfter) = refusal {
            model.applySlowmodeRefusal(retryAfter: retryAfter, in: channelID)
        }
        model.mutateBox(channelID) { box in
            if entry.isUpload {
                // Discord's `j`: a refused upload leaves no row behind — its
                // words and its files go back to the composer, and the reason
                // goes where the tray already draws one.
                box.outbox.removeAll { $0.id == entry.id }
                box.returnToComposer(entry)
                box.attachmentRefusal = .sendFailed(Self.describe(error))
            } else if let index = box.outbox.firstIndex(where: { $0.id == entry.id }) {
                box.outbox[index].state = .failed
            }
        }
        if case .explained(let text) = refusal {
            let notice = Clyde.notice(text, in: channelID, id: Self.mintNonce())
            model.mutateBox(channelID) { $0.notices.append(notice) }
        }
    }

    /// Puts the files up, in order, reporting how far the lot has got.
    ///
    /// **Serially, and that is deliberate.** These are the largest transfers the
    /// app makes — up to half a gigabyte each — and running five at once splits
    /// one connection's bandwidth five ways while holding five buffers. The bar
    /// is one for the whole send, as Discord's is, weighted by size so a large
    /// file is most of it.
    func upload(
        _ chosen: [PendingAttachment],
        in channelID: ChannelID,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> [UploadedAttachment] {
        guard !chosen.isEmpty else { return [] }
        // **A HEIC or JXR picture goes up as a JPEG**, as Discord's desktop
        // sends it (`CloudUpload.upload`, DESIGN-NOTES §14) — off this thread,
        // and saying what it was chosen as, as Discord's says.
        var files: [PendingAttachment] = []
        var originalTypes: [String?] = []
        for file in chosen {
            let type = file.contentType?.preferredMIMEType
            originalTypes.append(type)
            guard let conversion = UploadConversion(filename: file.filename, contentType: type),
                  let jpeg = await Task.detached(priority: .userInitiated, operation: {
                      MediaCompressor.convertToJPEG(file.url, named: file.filename, size: file.size, conversion)
                  }).value
            else {
                files.append(file)
                continue
            }
            files.append(file.replaced(by: jpeg, named: UploadConversion.jpegName(for: file.filename)))
        }
        let slots = try await rest.createUploadSlots(
            in: channelID, for: files.map(\.uploadRequest)
        )
        let total = Double(max(1, files.reduce(0) { $0 + $1.size }))
        var sent = 0
        var uploaded: [UploadedAttachment] = []
        uploaded.reserveCapacity(slots.count)
        for (index, (file, slot)) in zip(files, slots).enumerated() {
            let before = Double(sent)
            try await rest.upload(file.url, to: slot) { fraction in
                Task { @MainActor in
                    progress((before + fraction * Double(file.size)) / total)
                }
            }
            sent += file.size
            uploaded.append(UploadedAttachment(
                id: slot.id,
                filename: slot.filename,
                uploadedFilename: slot.uploadedFilename,
                altText: file.altText,
                originalContentType: originalTypes[index],
                clip: file.clip,
                isThumbnail: file.isThumbnail,
                voice: file.voice
            ))
        }
        return uploaded
    }

    /// Writes an upload's progress, on a change worth drawing.
    ///
    /// **Coalesced on a hundredth**, for the reason `MediaCanvasView` coalesces
    /// a pinch: `URLSession` reports every buffer it hands to the socket —
    /// thousands of times for a large file — and the thing reading this is a bar
    /// a few dozen points wide that cannot show a ten-thousandth.
    @MainActor
    private func reportUpload(_ fraction: Double, of id: MessageID, in channelID: ChannelID) {
        guard let entry = model.messages(in: channelID)?.outbox.first(where: { $0.id == id }),
              fraction >= 1 || fraction - entry.progress >= 0.01
        else { return }
        model.mutateBox(channelID) { box in
            guard let index = box.outbox.firstIndex(where: { $0.id == id }) else { return }
            box.outbox[index].progress = min(1, fraction)
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case DiscordREST.Failure.unauthorized: "Not authorised."
        case DiscordREST.Failure.forbidden: "You do not have permission to do that."
        case DiscordREST.Failure.notFound: "That no longer exists."
        case DiscordREST.Failure.api(let status, _, let message):
            message ?? "Discord returned \(status)."
        case DiscordREST.Failure.slowmode:
            "Slowmode is enabled. Wait a moment, then send it again."
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
        // **One request for every caller.** The picker and a sticker's card
        // both ask, and each used to fetch the whole set for itself.
        if let stickerPacksTask {
            await stickerPacksTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self, let packs = try? await rest.stickerPacks(), !packs.isEmpty
            else { return }
            model.installStandardStickerPacks(packs)
        }
        stickerPacksTask = task
        await task.value
        // Cleared once it is done either way: a refusal must stay retryable, and
        // a success is answered by the guard above from then on.
        stickerPacksTask = nil
    }

    /// Works out what a clicked sticker is, when no server of the reader's owns
    /// it — Discord's own card, `Zq` and `Sr` in module `256449`, in order:
    ///
    /// 1. **The packs Discord still offers.** Fetched once per launch; once
    ///    they are in, a stock sticker needs no request of its own.
    /// 2. **`GET /stickers/{id}`**, which says whose sticker it is — the one
    ///    fact a message leaves out. A standard one names its pack, and a pack
    ///    that is not among the offered ones is fetched by id: Discord's card
    ///    names it and says it is no longer available.
    /// 3. **A server's sticker** goes to the source route, which names the
    ///    server. So does one nothing could answer for, because that route
    ///    can still say something true.
    func resolveSticker(_ id: UInt64) async {
        guard model.standardPackIDByStickerID[id] == nil else { return }
        switch model.stickerLookups[id] {
        case .resolving, .standard, .standardUnnamed, .guildSticker: return
        case .failed, nil: break
        }
        model.stickerLookups[id] = .resolving

        await loadDefaultStickerPacks()
        if let packID = model.standardPackIDByStickerID[id],
           let pack = model.standardStickerPacks[packID]
        {
            model.stickerLookups[id] = .standard(pack, isOffered: true)
            return
        }

        do {
            let detail = try await rest.sticker(id)
            guard detail.isStandard, let packID = detail.packID else {
                model.stickerLookups[id] = .guildSticker
                loadExpressionSource(id, isSticker: true)
                return
            }
            if let pack = model.standardStickerPacks[packID] {
                model.stickerLookups[id] = .standard(pack, isOffered: true)
            } else if let pack = try? await rest.stickerPack(id: packID) {
                model.stickerLookups[id] = .standard(pack, isOffered: false)
            } else {
                // Known to be Discord's, with a pack nothing would name. Still
                // not a server's, which is the one thing the card must not say.
                model.stickerLookups[id] = .standardUnnamed
            }
        } catch {
            Self.trace("sticker \(id) lookup failed: \(Self.describe(error))")
            model.stickerLookups[id] = .failed
            loadExpressionSource(id, isSticker: true)
        }
    }

    // `--demo` answers from its own loops — the routes are requests, and it
    // makes none (`DemoGIFs`).
    func gifLanding() async throws -> GIFLanding {
        if LaunchOptions.current.usesDemoFixtures { return DemoGIFs.landing }
        return try await rest.gifLanding()
    }

    func trendingGIFs() async throws -> [GIF] {
        if LaunchOptions.current.usesDemoFixtures { return DemoGIFs.all }
        return try await rest.trendingGIFs()
    }

    func searchGIFs(_ query: String) async throws -> [GIF] {
        if LaunchOptions.current.usesDemoFixtures { return DemoGIFs.search(query) }
        return try await rest.searchGIFs(query)
    }
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
        // A server the reader is not in — an application's page — has nothing
        // here to ask about, and every one of these routes would refuse.
        guard model.guilds[guildID] != nil else {
            if model.isJoinRequestShown { loadJoinRequestGuildsIfNeeded() }
            return
        }
        model.offerApprovedApplicationIfNeeded(guildID)
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
                let outcome = try await rest.submitJoinApplication(.agreeing(to: verification))
                switch outcome {
                case .approved:
                    if let userID = model.currentUserID {
                        model.members[guildID]?[userID]?.isPending = false
                        // A pending member is masked as a lurker is — see
                        // `PermissionGate.lurkerMask` — so agreeing opens the channels.
                        model.permissionGate.invalidate()
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
                let servers = try await rest.gameServers(inGuild: guildID)
                model.gameServers[guildID] = servers
                // Their games, for the box art each card wears — one `/games`
                // call for all of them, and none for a game already known.
                await loadGames(ids: servers.compactMap(\.gameID))
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
