import Foundation
import WingcordCore

// MARK: - Presentation values
//
// What each surface is handed. Plain `Equatable` values with no store
// reference, no closures and no `AnyView` — which is the precondition for
// `.equatable()` to be worth anything, and the reason a message arriving cannot
// invalidate the guild rail.
//
// Each of these is built ONCE per change in the store and handed down as an
// array. `Array ==` short-circuits on buffer identity, so a surface whose
// snapshot did not change settles in a pointer comparison rather than in a
// per-row rebuild.

/// One entry in the guild rail.
enum RailItem: Hashable, Sendable, Identifiable {
    case guild(RailGuild)
    case folder(RailFolder)

    var id: UInt64 {
        switch self {
        case .guild(let entry): entry.id.rawValue
        // Folder ids and guild ids are both snowflakes from different
        // sequences, so they can collide. The high bit distinguishes them, and
        // it is free because no real snowflake sets it.
        case .folder(let folder): folder.id | (1 << 63)
        }
    }
}

struct RailGuild: Hashable, Sendable, Identifiable {
    var id: GuildID
    var name: String
    var iconURL: URL?
    var monogram: String
    /// Mentions addressed to the reader. Drawn as a red count.
    var mentionCount: Int
    /// Any unread at all, mention or not. Drawn as the leading pip.
    var hasUnread: Bool
    var isMuted: Bool
    /// Whether a voice channel in this guild currently has the reader in it.
    var isConnectedToVoice: Bool
}

struct RailFolder: Hashable, Sendable, Identifiable {
    var id: UInt64
    var name: String?
    var colorValue: UInt32?
    var guilds: [RailGuild]
    var isExpanded: Bool
    var mentionCount: Int
    var hasUnread: Bool
}

/// The channel column's contents for one guild.
///
/// One flat array rather than categories containing channels, for the same
/// reason the timeline is flat: a `LazyVStack` over a flat array can be
/// virtualised and diffed; a nested one re-materialises whole sections.
struct SidebarPresentation: Hashable, Sendable {
    var header: SidebarHeader?
    var rows: [SidebarRow]

    static let empty = SidebarPresentation(header: nil, rows: [])
}

struct SidebarHeader: Hashable, Sendable {
    /// Nil for the direct-message home, which is a real destination with a real
    /// channel list and no guild behind it.
    var guildID: GuildID?
    var name: String
    var bannerURL: URL?
    /// Whether the guild's own banner exists. Most do not — it is a boost perk —
    /// and a header that draws a placeholder block regardless is a permanent
    /// 168pt of chrome standing in for artwork that will never arrive.
    var hasBanner: Bool { bannerURL != nil }
}

enum SidebarRow: Hashable, Sendable, Identifiable {
    case category(SidebarCategory)
    case channel(SidebarChannel)
    /// A followed thread, under the channel it hangs off.
    ///
    /// **A flat row with a flag, not a nested model.** §2's rule holds: a nested
    /// sidebar model re-materialises whole sections on every rebuild and cannot
    /// be diffed per row. The view draws the elbow and the indent from
    /// `isLast`; the array stays one sequence `ForEach` can diff.
    case thread(SidebarThread)
    /// Server Guide, Channels & Roles and Game Servers — the rows above the
    /// first category that go somewhere other than a transcript.
    case guildAction(GuildSurface)

    var id: UInt64 {
        switch self {
        case .category(let category): category.id.rawValue
        case .channel(let channel): channel.id.rawValue
        case .thread(let thread): thread.id.rawValue
        // A surface's raw value is a small integer and a channel id is a
        // snowflake, so the two spaces cannot collide inside one list.
        case .guildAction(let surface): surface.rawValue
        }
    }
}

/// A followed thread's row.
struct SidebarThread: Hashable, Sendable, Identifiable {
    var id: ChannelID
    var name: String
    var isUnread: Bool
    var mentionCount: Int
    var isMuted: Bool
    /// Whether this is the last thread under its channel, so the view knows to
    /// draw the elbow rather than the tee. Precomputed here because a row that
    /// indexes forward into the array to ask about its neighbour cannot be
    /// diffed cheaply — §2, the same reason `TimelineMessage.RunFlags` exists.
    var isLast: Bool
}

/// What the sidebar is currently pointing at.
///
/// **One value rather than a channel id plus a flag.** A guild surface and a
/// channel are mutually exclusive destinations, and holding them as two
/// properties is how a selected channel keeps its pill while Channels & Roles is
/// open — two rows lit, one of them wrong.
enum SidebarTarget: Hashable, Sendable {
    case none
    case channel(ChannelID)
    case surface(GuildSurface)
}

struct SidebarCategory: Hashable, Sendable, Identifiable {
    var id: ChannelID
    var name: String
    var isExpanded: Bool
    /// Whether anything inside is unread. A collapsed category has to say so or
    /// the unread is invisible.
    var hasUnread: Bool
}

struct SidebarChannel: Hashable, Sendable, Identifiable {
    var id: ChannelID
    var name: String
    var kind: ChannelKind
    var isUnread: Bool
    var mentionCount: Int
    var isMuted: Bool
    /// People currently in this voice channel, drawn beneath the row so you can
    /// see who is in a call without joining it.
    var voiceMembers: [VoiceMemberChip]
    /// A conversation's face, for the rows that have one. A DM is identified by
    /// **who** it is with, so it takes an avatar where a guild channel takes a
    /// glyph in the same gutter — same row, same metrics, different leading
    /// element. Nil everywhere else.
    var avatarURL: URL?
    var monogram: String?
    /// Drawn on the avatar. Nil for a group DM, which has no single presence.
    var status: PresenceStatus?

    // MARK: What a direct message says about the person in it
    //
    // A guild channel is a topic; a direct message is a *person*, and the list
    // is the only place in the app where their identity has to be legible
    // without opening anything. These are the same facts the roster draws — see
    // `MemberEntry` — resolved into the same shapes, so the two surfaces cannot
    // disagree about what somebody looks like.

    /// What they are doing: an activity, or a custom status. Nil is a real
    /// state and the row keeps its height either way.
    var subtitle: String?
    /// The emoji beside a custom status, when they set one.
    var subtitleEmoji: EmojiRef?
    /// A server tag, worn beside the name.
    var tag: String?
    var tagBadgeURL: URL?
    /// The nameplate they wear, and the wash that grounds it.
    var nameplateURL: URL?
    var nameplatePalette: NameplatePalette = .none
    /// The face and effect they chose for their name. Nil is nearly everybody
    /// and costs nothing — see `StyledDisplayName`.
    var nameStyle: DisplayNameStyle?
    /// Their name's colour, when a role or their own palette gives them one.
    var nameColorValue: UInt32?

    /// Whether this row draws the taller, two-line form.
    ///
    /// **On the value, not on the view.** The row's height decides the list's
    /// scroll geometry, and a view that worked it out from three optionals is
    /// three places for the answer to differ from the one the list measured.
    var isPerson: Bool { kind == .directMessage || kind == .groupDirectMessage }
}

extension SidebarChannel {
    /// The guild-channel form: a glyph in the gutter, no face.
    init(
        id: ChannelID,
        name: String,
        kind: ChannelKind,
        isUnread: Bool,
        mentionCount: Int,
        isMuted: Bool,
        voiceMembers: [VoiceMemberChip]
    ) {
        self.init(
            id: id,
            name: name,
            kind: kind,
            isUnread: isUnread,
            mentionCount: mentionCount,
            isMuted: isMuted,
            voiceMembers: voiceMembers,
            avatarURL: nil,
            monogram: nil,
            status: nil
        )
    }
}

struct VoiceMemberChip: Hashable, Sendable, Identifiable {
    var id: UserID
    var name: String
    var avatarURL: URL?
    var isSpeaking: Bool
    var isMuted: Bool
}

/// A destination a server offers that is not a channel.
///
/// The raw values are the sidebar row's identity and the `Hashable` key every
/// per-guild cache is filed under, so they are **stable and never reordered** —
/// a reshuffle would file a fetched guide under the game servers' key.
///
/// `channelsAndRoles` and `browseChannels` open the same pane. They are separate
/// cases because they are separate *rows*: a community server asks questions and
/// a plain one does not, and a row promising roles in a server that has none is
/// a promise the page cannot keep.
enum GuildSurface: UInt64, Hashable, Sendable {
    case serverGuide = 1
    case channelsAndRoles = 2
    case browseChannels = 3
    case gameServers = 4

    var title: String {
        switch self {
        case .serverGuide: "Server Guide"
        case .channelsAndRoles: "Channels & Roles"
        case .browseChannels: "Browse Channels"
        case .gameServers: "Game Servers"
        }
    }

    /// The glyph in the sidebar's gutter and in the toolbar's pill. Both draw
    /// the same one, which is what makes the hand-off from the row to the
    /// chrome read as the same destination.
    var symbolName: String {
        switch self {
        case .serverGuide: "signpost.right.fill"
        case .channelsAndRoles, .browseChannels: "square.grid.2x2"
        case .gameServers: "gamecontroller.fill"
        }
    }
}

/// The identity capsule at the foot of the sidebar.
struct NowBarPresentation: Hashable, Sendable {
    var userID: UserID
    var displayName: String
    var handle: String
    var avatarURL: URL?
    var monogram: String
    var status: PresenceStatus
    var customStatus: String?
    var isMuted: Bool
    var isDeafened: Bool
    /// The reader's own nameplate, when they wear one.
    ///
    /// **The artwork and the wash, exactly as the roster carries them.** A plate
    /// is a strip whose leading two thirds are transparent plus a palette that
    /// grounds it — see `Nameplate` — and drawing only the strip reads as a
    /// picture floating beside a name rather than as a plate behind it.
    var nameplateURL: URL?
    var nameplatePalette: NameplatePalette = .none
}

/// Everything the detail column needs to decide what it is showing.
///
/// **One value, and the detail column is one view type that takes it.** That is
/// the invariant the whole split view rests on: macOS re-resolves column widths
/// on a structural detail swap, so the detail's type must never change. Adding a
/// surface later means adding a case here, never a branch in the view builder.
struct WorkspacePresentation: Hashable, Sendable {
    enum Primary: Hashable, Sendable {
        case empty
        case conversation(ChannelID)
        case forum(ChannelID)
        case voice(ChannelID)
        /// A page about the server rather than about a conversation in it.
        ///
        /// **One case for all of them**, with the surface as a payload. The
        /// three panes are three view types behind one `switch` inside
        /// `WorkspacePane`, which is internal `_ConditionalContent` under a
        /// stable outer type — not the structural swap §1 forbids.
        case guildSurface(GuildID, GuildSurface)
    }

    enum Supplementary: Hashable, Sendable {
        case members
        /// The other person, beside a direct message. A DM has no roster to
        /// show and a guild channel has no single person, so the two are
        /// different cases rather than one pane that switches contents.
        case userProfile(UserID)
        case thread(ChannelID)
        case search
        /// A voice channel's own text chat, beside its tiles.
        ///
        /// **The same channel id as the call.** Discord gives a voice channel
        /// one id for both halves, so this is the ordinary timeline pointed at
        /// the channel the tiles are for — a second case rather than a second
        /// kind of conversation.
        case voiceChat(ChannelID)
        /// A channel read beside one of the server's own pages.
        ///
        /// **A peek, not a destination.** A guide's resource is a
        /// recommendation, and following one by replacing the page loses the
        /// list of the other four — so the channel arrives in the column the
        /// roster already lives in and the page keeps its place.
        case channelPreview(ChannelID)
    }

    var primary: Primary
    var supplementary: Supplementary?

    static let empty = WorkspacePresentation(primary: .empty, supplementary: nil)
}

/// The chrome across the top of the detail column.
struct ChannelChrome: Hashable, Sendable {
    var channelID: ChannelID?
    var name: String
    /// The glyph in the pill.
    ///
    /// **A resolved symbol, not the kind.** The pill names whatever the detail
    /// column is showing, and a guild surface has no `ChannelKind` — carrying
    /// one anyway would mean picking a kind that is a lie and then special-casing
    /// it at the one place that reads it.
    var symbolName: String
    var topic: String?
    /// Whether the topic flyout is open on this channel.
    ///
    /// **A flyout is only offered where there is something in it** — a pill that
    /// opens onto an empty box is the inert control §5.5 is about — so the
    /// control is live exactly when `topic` is non-empty.
    var isTopicShown: Bool = false
    var isMemberListShown: Bool
    var canShowMemberList: Bool
    /// The DM profile pane's toggle. Its own pair rather than reusing the member
    /// list's, because the two surfaces never coexist and sharing one flag would
    /// mean hiding the roster in a server also hides the profile in every DM.
    var isUserProfileShown: Bool
    var canShowUserProfile: Bool
    /// Whether the pins control is offered. Every conversation has pins, so the
    /// only thing that removes it is there being no conversation.
    var canShowPins: Bool
    var arePinsShown: Bool
    /// Whether this channel can have threads at all. False for a forum, whose
    /// board already *is* the list — see `AppModel.canBrowseThreads`.
    var canShowThreads: Bool
    var areThreadsShown: Bool
    /// Whether a call can be started here. Direct messages and group
    /// conversations only — a guild's voice channel is joined from its own
    /// pane, and a text channel has no call at all.
    var canStartCall: Bool
    /// Whether the reader is already in this conversation's call, so the one
    /// control can say "hang up" instead of offering a second call.
    var isInCall: Bool
    /// Whether somebody else is in this conversation's call right now and the
    /// reader is not.
    ///
    /// **The third state, and leaving out is what made a call unrejoinable.**
    /// The control was one bit — start or hang up — so after hanging up it
    /// offered to *start* a call that was already running, which rings a person
    /// who is sitting in it. Discord says "Join the call" here, and so does
    /// this: joining an ongoing call must not ring anybody.
    var isCallOngoing: Bool
    /// Whether this is a voice channel with a chat to show beside it.
    var canShowVoiceChat: Bool
    var isVoiceChatShown: Bool
}
