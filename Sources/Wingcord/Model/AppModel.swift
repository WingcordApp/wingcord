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

    private func touchBox(_ channelID: ChannelID) {
        boxRecency.removeAll { $0 == channelID }
        boxRecency.append(channelID)
        while boxRecency.count > Self.residentChannelLimit {
            let evicted = boxRecency.removeFirst()
            // The transcript goes; unsent user input never does. A draft the
            // reader typed and a reply they were composing are not cache.
            messageBoxes[evicted]?.evictTranscript()
        }
    }

    /// Responds to real memory pressure by dropping everything not on screen.
    func relieveMemoryPressure() {
        let keep = selectedChannelID
        for channelID in messageBoxes.keys where channelID != keep {
            messageBoxes[channelID]?.evictTranscript()
        }
        boxRecency = keep.map { [$0] } ?? []
        ImageStore.shared.purge()
    }
}

/// One channel's loaded transcript and the state that belongs with it.
struct MessageBox: Sendable {
    /// Oldest first. Kept sorted by the store, never re-sorted per read — a
    /// re-sort per evaluation hides an ordering bug in the writer.
    var messages: [Message] = []
    var hasMoreHistory = true
    var isLoadingHistory = false
    var historyFailed = false
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
