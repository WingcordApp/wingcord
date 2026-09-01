import Foundation
import Observation
import WingcordCore
import WingcordNet

/// The session's state.
///
/// One store, and views read **narrow properties** of it. Observation tracks
/// per-property, so a view that reads `railRevision` is not invalidated by a
/// message arriving — but only if it genuinely reads that and nothing else,
/// which is what the `…Presentation` projections and the thin container views
/// exist to guarantee.
///
/// The tables are flat and keyed by id rather than nested inside their owners.
/// A single inbound message rewrites one channel's `lastMessageID`; with
/// channels stored as an array on `Guild`, that write would copy the whole guild
/// — every role, every channel — several times a second and invalidate every
/// view observing any part of it.
@Observable
@MainActor
final class AppModel {

    // MARK: Identity

    var currentUserID: UserID?
    /// Every role the reader holds anywhere, plus their own id, as one flat set.
    /// A mention test is then one lookup rather than a scan over roles per
    /// message per evaluation.
    var mentionableIDs: Set<UInt64> = []

    // MARK: Tables

    var guilds: [GuildID: Guild] = [:]
    var channelIndex = ChannelIndex()
    var users: [UserID: User] = [:]
    var members: [GuildID: [UserID: Member]] = [:]
    var roles: [GuildID: [RoleID: Role]] = [:]
    /// A server's own emoji and stickers, for the expression picker.
    ///
    /// Beside the guilds rather than on them, exactly as `roles` and `members`
    /// are: these are per-guild collections most of the app never reads, and a
    /// `Guild` is a value copied on every scalar change.
    ///
    /// Servers with none are **absent rather than empty** — the picker's rail
    /// shows one icon per server that has something, and a stored empty array
    /// would put an icon there that opens onto nothing.
    var guildEmojis: [GuildID: [EmojiRef]] = [:]
    var guildStickers: [GuildID: [StickerRef]] = [:]
    var presences: [UserID: Presence] = [:]
    var readStates: [ChannelID: ReadState] = [:]
    /// The rail's arrangement, from the account's own client settings.
    var folders: [GuildFolder] = []
    var expandedFolderIDs: Set<UInt64> = []
    var collapsedCategoryIDs: Set<ChannelID> = []

    // MARK: Messages

    /// Loaded transcripts, LRU-evicted.
    ///
    /// Bounded at three, not ten. People open a DM, read it, open the next — and
    /// ten resident channels also pin every avatar, emoji and attachment those
    /// rows pulled into the image caches, so the real cost of a high bound is
    /// paid in the media budget rather than here.
    private(set) var messageBoxes: [ChannelID: MessageBox] = [:]
    private var boxRecency: [ChannelID] = []
    static let residentChannelLimit = 3

    // MARK: Navigation

    var selectedGuildID: GuildID?
    var selectedChannelID: ChannelID?
    /// The server page the detail column is showing instead of a transcript.
    ///
    /// **Beside the channel rather than instead of it**, so leaving the page
    /// returns to the conversation that was open rather than to the top of the
    /// list. Cleared by selecting a channel and by switching servers — a guide
    /// belongs to the server it describes.
    var openGuildSurface: GuildSurface?
    /// A channel being read beside one of those pages.
    ///
    /// Its own property rather than a second meaning for `selectedChannelID`:
    /// the preview and the conversation the reader will return to are two
    /// different channels, and one property holding both is how following a
    /// resource loses the channel you came from.
    var previewedChannelID: ChannelID?
    /// The last channel visited in each guild, so switching back returns where
    /// you were rather than to the top of the list.
    var lastChannelByGuild: [GuildID: ChannelID] = [:]
    /// Seeded from the reader's preference. A per-guild override still lives in
    /// the toolbar toggle; this is only where a fresh window starts.
    var isMemberListShown = AppSettings.shared.showsMemberListByDefault
    /// Whether a direct message shows the other person's profile beside it.
    ///
    /// Its own flag rather than sharing the member list's: a DM has no member
    /// list and a guild channel has no profile pane, so one flag would mean
    /// hiding the roster in a server also hides the profile in every DM.
    var isDirectMessageProfileShown = true

    // MARK: Self state

    var selfStatus: PresenceStatus = .online
    var selfCustomStatus: String?
    /// The glyph beside the reader's own custom status. Kept beside the text
    /// rather than inside it: the wire carries them as two fields, and a status
    /// with an emoji and no words is a real state.
    var selfCustomStatusEmoji: String?
    var isSelfMuted = false
    var isSelfDeafened = false
    var connectedVoiceChannelID: ChannelID?

    // MARK: Voice
    //
    // Facts about calls. **Nothing here moves at the frame rate** — the audio
    // level, the packet counters and the per-frame speaking energy live in the
    // engine and arrive only when the answer changes. A store property carrying
    // somebody's live level would invalidate every tile fifty times a second.

    /// Who is in which voice channel, across the whole account.
    ///
    /// One flat table rather than one per guild, for the same reason the
    /// channels are flat: a person is in exactly one voice channel anywhere, so
    /// the guild is a property of the row and "am I in a call" is one lookup
    /// instead of a sweep.
    var voiceStates: [UserID: VoiceState] = [:]
    /// Bumped when a voice state moves. Every voice memo keys on this and on
    /// nothing that a message can move.
    var voiceRevision: UInt64 = 0
    /// Who is talking **now**, as the engine hears it. A few changes a
    /// sentence, not fifty a second.
    var speakingUserIDs: Set<UserID> = []
    /// Whether our own gate is open. Separate from the set above because there
    /// is no loopback: nothing we send comes back to us, so a self tile driven
    /// by the received-audio set would never light.
    var isSelfSpeaking = false
    /// Whose video has actually arrived. Distinct from their camera *flag*: a
    /// tile that reserves a picture on the flag shows a black rectangle until
    /// the first keyframe, which is up to two seconds.
    var liveVideoUserIDs: Set<UserID> = []
    var isCameraOn = false
    var isScreenSharing = false
    /// Who the reader pinned to the stage. A share fills it by itself.
    var spotlightUserID: UserID?
    var voiceQuality: VoiceQuality = .idle
    /// Our own microphone level, for the meter and for nothing else.
    var selfInputLevel: Float = 0
    /// True while the voice processor is hearing speech through a muted input.
    var isTalkingWhileMuted = false
    /// Direct-message calls, by conversation. A call exists here before anybody
    /// has joined it — that is what ringing is.
    var directCalls: [ChannelID: DirectCall] = [:]
    /// A call this client did not start, ringing right now.
    var incomingCallChannelID: ChannelID?
    /// Whether the voice channel's own text chat is showing beside the stage.
    var isVoiceChatShown = false
    /// The screen picker.
    ///
    /// A window-level flag because it is a *sheet*: it anchors to nothing, it
    /// is modal, and it is raised from two control clusters that are never both
    /// on screen. The soundboard is the opposite case and is deliberately not
    /// here — it is a popover that has to point at the button that opened it,
    /// so it lives on that button.
    var isScreenSharePickerOpen = false

    // MARK: The soundboard

    /// Discord's own six. Fetched once per session — the set is global and
    /// changes about once a year.
    var defaultSoundboardSounds: [SoundboardSound] = []
    var guildSoundboardSounds: [GuildID: [SoundboardSound]] = [:]
    var soundboardRevision: UInt64 = 0
    /// The sound somebody just pressed, and who pressed it. Drawn as a chip
    /// over their tile for a beat, then cleared.
    var soundboardEffects: [UserID: String] = [:]

    // MARK: Connection

    enum ConnectionState: Equatable, Sendable {
        case signedOut
        case connecting
        case ready
        case reconnecting
        case failed(String)
    }

    var connectionState: ConnectionState = .signedOut

    // MARK: Window-level presentations
    //
    // One property per surface that can be raised from a row, presented ONCE at
    // the window root. A `.popover` or `.sheet` written inline in a row is
    // evaluated as part of that row's body — including its title strings — by
    // every row on every evaluation.

    var profileRequest: ProfileRequest?
    /// Whose detail fetch is still in flight. Observed, so a card can show a
    /// skeleton while it waits and swap to the real thing when it lands.
    var profilesLoading: Set<UserID> = []
    /// The emoji or sticker whose card is open.
    var expressionInfoRequest: ExpressionInfoRequest?
    /// The media the lightbox is showing, and the rest of its message's.
    ///
    /// **A snapshot, not a pointer back into the store.** The channel it came
    /// from can be evicted by the LRU and the message can be deleted while
    /// somebody is looking at the picture; neither should make it disappear.
    var mediaViewer: MediaViewerRequest?
    /// Server tag cards, by guild rather than by wearer: a tag is worn by
    /// everyone in the server, and fetching it per person would ask for the same
    /// answer once a name.
    var guildProfiles: [GuildID: GuildProfile] = [:]
    var guildProfilesLoading: Set<GuildID> = []
    /// Where a foreign emoji or sticker came from, keyed by its own snowflake.
    ///
    /// **One table for both**, because an emoji id and a sticker id are both
    /// snowflakes from the same space and the answer has the same shape. It is
    /// only ever asked for an expression **no resident server owns** — one of
    /// the reader's own is nameable with no round trip at all.
    var expressionSources: [UInt64: ExpressionSource] = [:]
    var expressionSourcesLoading: Set<UInt64> = []
    /// The message the transcript is being sent to, if any. Consumed by the
    /// timeline coordinator, which clears it once it has scrolled.
    var pendingJump: MessageJump?
    /// Distinguishes two jumps to the same message. `@ObservationIgnored`
    /// because nothing reads it — it exists only to make `pendingJump` differ.
    @ObservationIgnored var jumpToken: UInt64 = 0

    // MARK: What a message raises
    //
    // Each is written by a row and presented ONCE at the window root, with the
    // rect that summoned it — the transcript is a drawn canvas and cannot host
    // a presentation at all. See `MessageActionRequests`.

    /// What the pointer is resting on in the transcript. Drives the hover pill
    /// and nothing else, so a hover invalidates one small overlay.
    var messageHover: MessageHover?
    var messageMenu: MessageMenuRequest?
    var reactionPicker: ReactionPickerRequest?
    var forwardRequest: ForwardRequest?
    /// Channels a forward is being written to. Keyed by target so two can be in
    /// flight and neither blocks the other.
    var forwardsInFlight: Set<ChannelID> = []
    var deleteRequest: DeleteMessageRequest?
    var reportRequest: ReportRequest?
    var userMenu: UserMenuRequest?
    /// The channel whose pinned messages are on screen.
    var openPinsChannelID: ChannelID?

    /// One channel's pins, newest first. Absent means "not asked"; empty means
    /// "asked, and there are none" — collapsing the two makes the pane refetch
    /// on every open for every channel that has never pinned anything.
    var pinnedMessages: [ChannelID: [Message]] = [:]
    var pinsLoading: Set<ChannelID> = []
    /// Why the last pins fetch failed, in the reader's words.
    var pinsFailure: [ChannelID: String] = [:]

    /// Reactions being written, as `(message, emoji)`. Keyed so two chips on one
    /// message can be pressed in either order without one cancelling the other.
    var reactionsInFlight: Set<PendingReaction> = []

    /// The report questionnaires, fetched once per kind per session.
    ///
    /// **A session cache and no refresh.** The taxonomy changes about as often
    /// as Discord's own client ships, and re-fetching it per report would put a
    /// round trip in front of the reader every time they open the flow.
    var reportMenus: [ReportSubjectKind: ReportMenu] = [:]
    var reportMenusLoading: Set<ReportSubjectKind> = []
    /// How the last submission went, so the flow's last screen can say.
    var reportSubmission: ReportSubmissionState?

    /// People the account has blocked, and people it has ignored.
    ///
    /// **Two sets, because they are two independent facts** — you can ignore a
    /// friend, and blocking somebody does not ignore them. Read from READY's
    /// relationship list and kept current by the routes that write them.
    var blockedUserIDs: Set<UserID> = []
    var ignoredUserIDs: Set<UserID> = []
    /// What the account is to each person it has a relationship with. An absent
    /// entry is `.none`, which is what the table already says — storing every
    /// stranger as `.none` would be a row per person the reader has ever seen.
    var relationships: [UserID: Relationship] = [:]
    /// The reader's private notes, straight off READY. Nobody else can see one,
    /// and no route is needed to read one back.
    var notes: [UserID: String] = [:]
    /// Notes being written, so a field that is saving can say so and a second
    /// save cannot race the first.
    var notesInFlight: Set<UserID> = []
    /// Relationship writes in flight, so a double press sends once.
    var relationshipsInFlight: Set<UserID> = []

    /// The channel whose read cursor the reader deliberately rewound.
    ///
    /// **A latch, and without it Mark Unread does nothing anybody can see.** The
    /// reader is still standing in the channel, so the next inbound message
    /// takes the "they are looking at it" path and acknowledges — undoing the
    /// rewind a beat after it was asked for. Cleared by leaving the channel,
    /// which is also exactly when the reader has stopped meaning it.
    var suppressedAckChannelID: ChannelID?

    /// The last act that did not land, in the reader's words.
    ///
    /// **One slot, not a queue.** These are transient notices for a click that
    /// was just made; a second failure while the first is on screen replaces it,
    /// because the reader is looking at the thing they just did and a backlog of
    /// stale refusals is noise. Cleared by the notice's own timer.
    var actionFailure: ActionFailure?
    /// Distinguishes two identical refusals. `@ObservationIgnored` because
    /// nothing reads it — it exists only to make `actionFailure` differ.
    @ObservationIgnored var actionFailureToken: UInt64 = 0
    /// Profile effects, by SKU rather than by person: an effect is a purchase
    /// twenty people in one server may share, and fetching it per wearer would
    /// ask for the same composition twenty times.
    var profileEffects: [String: ProfileEffect] = [:]
    /// Profile frames, by SKU and for the same reason: a frame is a purchase,
    /// and a server where twenty people wear Dark Roses resolves it once.
    var profileFrames: [String: ProfileFrame] = [:]
    /// Profile colours quantised out of somebody's artwork, keyed by that
    /// artwork's URL.
    ///
    /// **By URL rather than by person**, which is Discord's own key and is the
    /// one that cannot go stale: change your avatar and the key changes with
    /// it, where a key on the account would keep serving the colours of a
    /// picture nobody has any more.
    var derivedPalettes: [URL: [UInt32]] = [:]

    // MARK: The server's own pages
    //
    // Server Guide, Channels & Roles and Game Servers. All five tables are
    // **keyed by guild and filled once per session**: a guide, a set of
    // questions and a rented server change about as often as the server's name,
    // so there is no refresh timer and no invalidation on any gateway event.
    //
    // An absent entry means "not asked yet" and an *empty* one means "asked, and
    // there is nothing". Collapsing the two into one is what makes a page ask
    // again on every appearance for a server that has no guide.

    var serverGuides: [GuildID: ServerGuide] = [:]
    var guildOnboardings: [GuildID: GuildOnboarding] = [:]
    /// How many people hold each role, for the server whose questions are open.
    var roleMemberCounts: [GuildID: [RoleID: Int]] = [:]
    var memberVerifications: [GuildID: MemberVerification] = [:]
    var gameServers: [GuildID: [GameServer]] = [:]
    /// Connection instructions, by SKU rather than by instance: two servers on
    /// one plan share an answer.
    var gameServerProducts: [String: GameServerProduct] = [:]
    /// Which of the above are in flight, as one set rather than five.
    ///
    /// A page asks "is my thing loading" once per body, so one lookup in one set
    /// beats five sets that each have to be kept in step with a `defer`.
    var loadingGuildSurfaces: Set<GuildSurfaceFetch> = []
    /// Whose ballot is being written. Distinct from the loading set: a page
    /// whose questions have arrived is not loading, and a click on it must still
    /// be able to say it is working.
    var savingOnboardingGuilds: Set<GuildID> = []
    /// The connect sheet, presented once at the window root like every other
    /// raised surface.
    var gameServerConnect: GameServerConnectRequest?
    /// The rules sheet, same.
    var serverRulesGuildID: GuildID?
    /// Whose agreement is being sent, and how the last one went.
    ///
    /// One value rather than a flag plus a result: "sending" and "rejected" are
    /// states of the same act, and two properties is how a sheet ends up showing
    /// a spinner beside a refusal.
    var serverRulesSubmission: ServerRulesSubmission?

    // MARK: Revisions
    //
    // Memos key on these rather than on the tables themselves. A revision is one
    // integer to compare where a table is a whole dictionary to hash, and — more
    // importantly — a revision can be moved by exactly the writes that can
    // change the answer, which a table cannot.
    //
    // Getting this wrong is invisible from the outside. A memo keyed on a
    // counter that moves far more often than its answer can change is the same
    // as no memo at all: the cache is present, correct, and never hit.

    /// Moves when the rail's arrangement or badges change. NOT when a message
    /// arrives in a guild that is already unread.
    var railRevision: UInt64 = 0
    /// Moves when the selected guild's channel tree or its read state changes.
    var sidebarRevision: UInt64 = 0
    /// Moves when the roster of the selected channel changes.
    var rosterRevision: UInt64 = 0
    /// Moves when any server's emoji or sticker set changes — a server becoming
    /// available, or one of the two catalog events.
    ///
    /// **Deliberately its own counter.** The picker's sections are built from
    /// every guild in the account, which is the most expensive snapshot in the
    /// app to rebuild; keyed on `railRevision` it would rebuild on every unread
    /// badge, and keyed on nothing it would rebuild per frame.
    var expressionRevision: UInt64 = 0
    /// Moves when a guild's member records change — someone joined, left, was
    /// renamed, or had roles changed.
    var memberRevision: UInt64 = 0
    /// Moves on a presence flush. **The most frequent event in the app**: on a
    /// large server it arrives several times a second and moves nobody across
    /// the online line the overwhelming majority of the time, which is exactly
    /// why the roster is memoized on it rather than rebuilt.
    var presenceRevision: UInt64 = 0
    /// Moves when a message's CONTENT changes without the set changing — an
    /// edit, a reaction added, an embed unfurling. Distinct from the message
    /// count, which cannot see any of those.
    var messageContentRevision: UInt64 = 0
    /// Moves when a name, nickname or role colour anywhere could have changed.
    /// The mention memo keys on it; a memo keyed on the text alone serves
    /// whichever surface rendered it first, forever.
    var identityRevision: UInt64 = 0
    /// Moves when ANY input to a permission answer changes: the reader's roles,
    /// a role's own permissions, a channel's overwrites, a guild's owner, or the
    /// signed-in account. `PermissionGate` discards its whole cache on a change,
    /// because a partial invalidation is how a stale `viewChannel` survives a
    /// role change and leaks a private channel into the list.
    var roleRevision: UInt64 = 0

    // MARK: Memo storage
    //
    // `@ObservationIgnored` so writing a cache does not itself invalidate
    // anything. The dependency a reader needs comes from the revision it reads
    // BEFORE the cache is consulted — see the projections.

    @ObservationIgnored var railCache: (key: RailMemoKey, value: [RailItem])?
    @ObservationIgnored var sidebarCache: (key: SidebarMemoKey, value: SidebarPresentation)?
    @ObservationIgnored var timelineCache: (key: TimelineMemoKey, value: [TimelineItem])?
    @ObservationIgnored var rosterCache: (key: RosterMemoKey, value: [MemberSection])?
    @ObservationIgnored var emojiCatalogCache: (key: ExpressionMemoKey, value: ExpressionCatalog)?
    @ObservationIgnored var stickerCatalogCache: (key: ExpressionMemoKey, value: ExpressionCatalog)?
    /// Discord's own sticker packs, fetched once per launch. Not per guild and
    /// not per channel: the set is the same for every account.
    @ObservationIgnored var defaultStickerPacks: [ExpressionSection] = []
    /// The mention table. The most expensive memo in the app to miss — it is
    /// proportional to the whole account rather than to a page — and the one
    /// most often asked for, because the timeline rebuilds its layout input on
    /// every inbound message.
    @ObservationIgnored var mentionCache: (key: MentionMemoKey, value: MentionContext)?
    @ObservationIgnored
    var voicePresentationCache: (key: VoiceMemoKey, value: VoicePresentation?)?
    @ObservationIgnored
    var soundboardCache: (key: SoundboardMemoKey, value: SoundboardPresentation)?
    /// The Channels & Roles page. Memoized because building it walks every
    /// channel in the server through the permission gate, and the page is on
    /// screen while the store publishes for reasons that cannot change it.
    @ObservationIgnored
    var channelsAndRolesCache: (key: GuildSurfaceMemoKey, value: ChannelsAndRolesPresentation)?
    /// Everywhere a message can be forwarded to. **The most expensive snapshot
    /// in the app after the expression catalog** — it walks every channel in
    /// every server through the permission gate — and the search field it feeds
    /// filters it per keystroke, which is why it is built once and filtered in
    /// the view rather than rebuilt per query.
    @ObservationIgnored
    var forwardTargetCache: (key: ForwardTargetMemoKey, value: [ForwardTarget])?

    /// Asks the session for a page of history above what is loaded.
    ///
    /// A closure rather than a direct call into the network layer, so the store
    /// stays free of it: the store is what a test constructs, and a store that
    /// reaches for a socket is a store that cannot be constructed in a test.
    @ObservationIgnored var historyLoader: ((ChannelID, MessageID?) -> Void)?

    /// What the reader may do, cached.
    ///
    /// `lazy` so it can take `self`, and `@ObservationIgnored` so reading it
    /// registers no dependency — the dependency a view needs comes from
    /// `roleRevision`, which the gate itself keys on.
    @ObservationIgnored lazy var permissionGate = PermissionGate(model: self)

    /// The connection, and the only thing in the app that talks to it.
    ///
    /// `lazy` so it can take `self`, and `@ObservationIgnored` because it is
    /// machinery rather than state — nothing observes it, and everything it
    /// changes it changes through the properties above.
    @ObservationIgnored lazy var sessionController = SessionController(model: self)

    /// The account's favourite GIFs, from its settings blob. Read-only here —
    /// this client has no route that writes one back.
    var favoriteGIFs: [GIF] = []

    /// Guilds the account has muted. Their unread never reaches the rail.
    var mutedGuildIDs: Set<GuildID> = []

    /// Channels and categories the reader has opted into, across every server.
    ///
    /// **One flat set, not a table per guild**, because that is the shape the
    /// answer arrives in and the shape every read wants: a browse row asks
    /// "is this one followed" and gets a hash lookup, where a nested table would
    /// be two.
    var followedChannelIDs: Set<ChannelID> = [] { didSet { followRevision &+= 1 } }
    /// Follows being written. Keyed by channel so two rows can be in flight at
    /// once and neither blocks the other.
    var followsInFlight: Set<ChannelID> = [] { didSet { followRevision &+= 1 } }
    /// Moves when either of the two sets above does.
    ///
    /// **A counter rather than the sets themselves in a memo key.** The channel
    /// list keys on this, and it is read on every evaluation of the sidebar's
    /// container — hashing a few hundred `ChannelID`s there is the cost a
    /// revision exists to avoid.
    ///
    /// **Bumped by a `didSet` rather than by each writer.** A revision a caller
    /// has to remember to move is the "memo keyed on the wrong counter" trap
    /// with an extra step: the cache stays present, correct, and never invalid.
    /// Assigning to a *different* property from a `didSet` is safe — the
    /// recursion §5 warns about is assigning to the same one — and `AppModel`'s
    /// `init` sets none of these, so the launch hazard `AppSettings` documents
    /// cannot arise here.
    var followRevision: UInt64 = 0

    init() {}

    // MARK: Message boxes

    func messages(in channelID: ChannelID) -> MessageBox? {
        messageBoxes[channelID]
    }

    func setMessages(_ box: MessageBox, in channelID: ChannelID) {
        messageBoxes[channelID] = box
        touchBox(channelID)
    }

    func mutateBox(_ channelID: ChannelID, _ body: (inout MessageBox) -> Void) {
        var box = messageBoxes[channelID] ?? MessageBox()
        body(&box)
        messageBoxes[channelID] = box
        touchBox(channelID)
    }

    /// Drops every loaded transcript. Part of the sign-out funnel, which is the
    /// only caller — the table is `private(set)` so eviction can only happen
    /// through `touchBox`, and a second place that empties it would be a second
    /// place to forget the recency list.
    func clearAllMessages() {
        messageBoxes.removeAll(keepingCapacity: false)
        boxRecency.removeAll(keepingCapacity: false)
    }

    /// Records that a channel's box was used, and evicts past the limit.
    ///
    /// **Two rules, and both exist because breaking either threw away the
    /// transcript the reader was looking at.**
    ///
    /// 1. *Only a box that HOLDS a transcript occupies a resident slot.* A box
    ///    is created by anything that writes to one — a typing indicator, a
    ///    draft keystroke, a delete for a message that was never loaded — and
    ///    those arrive for **every channel in the account**, not for the three
    ///    being read. Letting a channel with no messages claim a slot means
    ///    three strangers typing anywhere evicts the open channel.
    /// 2. *The channel on screen is never a candidate.* It is the one box whose
    ///    eviction is guaranteed to be visible, and nothing re-requests it:
    ///    `openChannel` runs on a selection change, and the selection did not
    ///    change. The transcript simply emptied, `hasMoreHistory` reset to true,
    ///    and the reducer answered `.loadingFirstPage` — which is the
    ///    "Loading messages..." that came back seconds after the messages did,
    ///    and why scrolling appeared to fix it: a scroll asks for history.
    ///
    /// The channel being **previewed** beside a server's page is protected for
    /// exactly the same reason: it is on screen, and the only thing that
    /// re-requests it is a change to `previewedChannelID` that has already
    /// happened.
    private func touchBox(_ channelID: ChannelID) {
        guard messageBoxes[channelID]?.messages.isEmpty == false else {
            // Nothing to evict later, so nothing to hold a slot with.
            boxRecency.removeAll { $0 == channelID }
            return
        }
        boxRecency.removeAll { $0 == channelID }
        boxRecency.append(channelID)

        var index = 0
        while boxRecency.count > Self.residentChannelLimit, index < boxRecency.count {
            let candidate = boxRecency[index]
            guard candidate != selectedChannelID, candidate != previewedChannelID else {
                index += 1
                continue
            }
            boxRecency.remove(at: index)
            // The transcript goes; unsent user input never does. A draft the
            // reader typed and a reply they were composing are not cache.
            messageBoxes[candidate]?.evictTranscript()
        }
    }

    /// Responds to real memory pressure by dropping everything not on screen.
    ///
    /// **The roster tables are the ones that actually grow without bound.** A
    /// transcript is already capped at three channels and the image caches have
    /// byte budgets, but `members` gains a whole guild's roster every time a
    /// channel is opened in it, and `presences` gains an entry per person seen
    /// anywhere. Over a long session on an account this size — 97 guilds — those
    /// two are the tables with no ceiling at all.
    ///
    /// Both are **re-requested on demand**: opening a channel subscribes to its
    /// guild's member list through the op-14 lazy subscription, which answers
    /// with members and their presences together. So dropping them costs a
    /// round trip on the next visit and nothing else, which is exactly the
    /// trade a pressure signal is asking for.
    ///
    /// `users` is deliberately NOT pruned. It is what turns an author id into a
    /// name, a message that outlives its author's roster entry still has to
    /// render, and the failure mode — a transcript of people called "Unknown" —
    /// is worse than the memory it would return.
    func relieveMemoryPressure() {
        // Both of what can be on screen: the conversation, and a channel being
        // previewed beside a server's own page.
        let keep: Set<ChannelID> = Set([selectedChannelID, previewedChannelID].compactMap { $0 })
        for channelID in messageBoxes.keys where !keep.contains(channelID) {
            messageBoxes[channelID]?.evictTranscript()
        }
        boxRecency = boxRecency.filter(keep.contains)

        let keptGuild = selectedGuildID
        if members.count > 1 {
            members = keptGuild.flatMap { id in members[id].map { [id: $0] } } ?? [:]
        }
        presences = survivingPresences(inGuild: keptGuild)

        ImageStore.shared.purge()
        // Filmstrips are the most expensive and least essential pixels the app
        // holds — up to forty-eight bitmaps for one ring around one avatar.
        AnimatedImageStore.shared.purge()
        // Every memo now describes tables that no longer exist.
        railCache = nil
        sidebarCache = nil
        rosterCache = nil
        channelsAndRolesCache = nil
        emojiCatalogCache = nil
        stickerCatalogCache = nil
        mentionCache = nil
        // Every channel in the account, walked through the permission gate. It
        // is rebuilt the next time the forward sheet opens, which costs a pass
        // nobody is waiting through.
        forwardTargetCache = nil
        memberRevision &+= 1
        presenceRevision &+= 1
    }

    /// The presences still worth holding: the people on screen or one click from
    /// it — the selected guild's roster, whoever is in a DM, and the reader.
    private func survivingPresences(inGuild guildID: GuildID?) -> [UserID: Presence] {
        var keep: Set<UserID> = []
        if let currentUserID { keep.insert(currentUserID) }
        if let guildID, let table = members[guildID] {
            keep.formUnion(table.keys)
        }
        for channelID in channelIndex.privateChannelIDs() {
            guard let channel = channelIndex[channelID] else { continue }
            keep.formUnion(channel.recipientIDs)
        }
        guard keep.count < presences.count else { return presences }

        var result: [UserID: Presence] = [:]
        result.reserveCapacity(keep.count)
        for userID in keep {
            if let presence = presences[userID] { result[userID] = presence }
        }
        return result
    }
}

/// One reaction whose write has not come back.
///
/// A value rather than a pair in a dictionary: it is only ever asked "is this
/// exact chip busy", which is one hash lookup either way, and a `Set` of these
/// cannot grow a stale key the way a nested table can.
struct PendingReaction: Hashable, Sendable {
    var messageID: MessageID
    var emoji: EmojiRef
}

/// An act that did not land.
///
/// The token is what makes two identical refusals two notices rather than one:
/// a value equal to the one already on screen publishes nothing, so the second
/// failure would show no notice at all and read as having quietly worked.
struct ActionFailure: Hashable, Sendable, Identifiable {
    var reason: String
    var id: UInt64
}

/// How a report submission went.
enum ReportSubmissionState: Hashable, Sendable {
    case sending
    case succeeded
    case failed(String)
}

/// One channel's loaded transcript and the state that belongs with it.
struct MessageBox: Sendable {
    /// Oldest first. Kept sorted by the store, never re-sorted per read — a
    /// re-sort per evaluation hides an ordering bug in the writer.
    var messages: [Message] = []
    var hasMoreHistory = true
    var isLoadingHistory = false
    /// Why the last history request failed, in the reader's words. Nil when the
    /// last request succeeded or none has been made. A reason rather than a
    /// flag, because "you cannot read this channel" and "the network dropped"
    /// need different words and only one of them is worth retrying.
    var historyFailure: String?
    /// The reader's own unsent text. Survives eviction.
    var draft: String = ""
    /// A message being replied to. Survives eviction.
    var replyingTo: MessageID?
    /// A message being edited, and its text so far. Survives eviction, and sits
    /// *beside* the draft rather than over it — see `MessageEdit`.
    var editing: MessageEdit?
    /// Who is typing, and when their indicator expires.
    var typing: [UserID: Date] = [:]

    /// Drops the transcript, keeps the user's own input.
    mutating func evictTranscript() {
        messages.removeAll(keepingCapacity: false)
        typing.removeAll(keepingCapacity: false)
        hasMoreHistory = true
        isLoadingHistory = false
        historyFailure = nil
    }

    /// Inserts or replaces one message, keeping the array sorted.
    ///
    /// Appends without searching in the overwhelmingly common case — a live
    /// message is newer than everything loaded — and binary-searches only when
    /// it is not, which is a backfill or an out-of-order gateway delivery.
    mutating func upsert(_ message: Message) {
        if let last = messages.last, message.id.rawValue > last.id.rawValue {
            messages.append(message)
            return
        }
        var low = 0
        var high = messages.count
        while low < high {
            let mid = (low + high) / 2
            if messages[mid].id.rawValue < message.id.rawValue { low = mid + 1 } else { high = mid }
        }
        if low < messages.count, messages[low].id == message.id {
            messages[low] = message
        } else {
            messages.insert(message, at: low)
        }
    }

    mutating func remove(_ messageID: MessageID) {
        messages.removeAll { $0.id == messageID }
    }
}
