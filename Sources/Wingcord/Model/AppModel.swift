import Foundation
import Observation
import WingcordCore

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
    /// The last channel visited in each guild, so switching back returns where
    /// you were rather than to the top of the list.
    var lastChannelByGuild: [GuildID: ChannelID] = [:]
    var isMemberListShown = true

    // MARK: Self state

    var selfStatus: PresenceStatus = .online
    var selfCustomStatus: String?
    var isSelfMuted = false
    var isSelfDeafened = false
    var connectedVoiceChannelID: ChannelID?

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
    /// Profile effects, by SKU rather than by person: an effect is a purchase
    /// twenty people in one server may share, and fetching it per wearer would
    /// ask for the same composition twenty times.
    var profileEffects: [String: ProfileEffect] = [:]

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
            guard candidate != selectedChannelID else {
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
        let keep = selectedChannelID
        for channelID in messageBoxes.keys where channelID != keep {
            messageBoxes[channelID]?.evictTranscript()
        }
        boxRecency = keep.map { [$0] } ?? []

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
        emojiCatalogCache = nil
        stickerCatalogCache = nil
        mentionCache = nil
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
