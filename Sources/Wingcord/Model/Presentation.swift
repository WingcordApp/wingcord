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
    /// What is happening in this server's voice channels, if anything.
    ///
    /// **Nil is silence, and silence is the common case.** Resolved from one
    /// pass over the whole account rather than a lookup per tile — see
    /// `AppModel.voiceMarksByGuild`. It draws the mark Discord puts on the tile
    /// itself, which is the only thing on the rail that says a room is busy
    /// without hovering anything.
    var voiceMark: RailVoiceMark?
}

/// What a rail tile's voice mark says.
///
/// **One glyph per tile, chosen by Discord's own ranking** (module `771640`):
/// a live stage, then a screen share, then a camera, then a room with people
/// talking in it. `Comparable` in that order, so the one pass that finds them
/// keeps the highest whatever order the voice table is walked in.
///
/// The first version drew a screen for a stream *or* a camera and nothing for a
/// quiet room; the second added the room. Discord keeps a camera and a screen
/// apart, and a stage is not a voice channel at all.
enum RailVoiceMark: Int, Hashable, Sendable, Comparable {
    /// Somebody is talking in a voice channel here.
    case voice
    /// …and somebody in one has a camera on.
    case video
    /// …and somebody is sharing their screen.
    case screenShare
    /// A stage is live.
    case stage
    /// An event is happening now — Discord's `CalendarIcon`, which outranks
    /// every room's mark (`771640`'s `oi`).
    case event

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var symbolName: String {
        switch self {
        case .voice: "speaker.wave.2.fill"
        case .video: "video.fill"
        // A monitor, as Discord's `ScreenIcon` is.
        case .screenShare: "display"
        case .stage: "person.wave.2.fill"
        case .event: "calendar"
        }
    }
}

/// Who is in voice in one server, for the chip that names it.
///
/// **Resolved on hover, for one server, and never carried on `RailGuild`.** The
/// rail's memo rebuilds on every inbound message in the account; putting a face
/// list on all ninety-seven tiles would resolve avatars for every server on the
/// rail to draw them for the one under the pointer.
struct RailHoverPresence: Hashable, Sendable {

    struct Face: Hashable, Sendable, Identifiable {
        var id: UserID
        var avatarURL: URL?
        var monogram: String
    }

    /// One row of faces, and the count drawn after them.
    struct Row: Hashable, Sendable {
        var faces: [Face] = []
        /// How many people the row stands for and does not draw. Zero draws
        /// nothing.
        var overflow: Int = 0

        var isEmpty: Bool { faces.isEmpty }
        /// Everybody the row stands for, for the one sentence VoiceOver reads.
        var count: Int { faces.count + overflow }
    }

    /// Who is speaking on this server's live stages.
    var stage = Row()
    /// Everybody else on those stages, as a count beside the speakers.
    var stageListeners = 0
    /// Everybody talking in a voice channel here who is not in the row below.
    var voice = Row()
    /// Everybody sharing a screen. **Not a camera**: somebody with video on is
    /// somebody in voice, and Discord lists them there.
    var streams = Row()

    /// The slots in a row of voices or streams — Discord's own `max: 6`.
    static let faceSlots = 6
    /// A stage's speakers get three.
    static let stageFaceSlots = 3

    var isEmpty: Bool { stage.isEmpty && voice.isEmpty && streams.isEmpty }
    /// How many rows the chip grows by. Pure arithmetic, so the host can centre
    /// the chip on its tile without measuring it — §2.
    var rowCount: Int { [stage, voice, streams].count { !$0.isEmpty } }

    /// How many faces a row of `slots` draws for `count` people, and the count
    /// it shows after them.
    ///
    /// **Discord's facepile, exactly** (module `104171`). A row that fits, or is
    /// exactly full, draws everybody; one that overflows gives its last slot to
    /// the count. So six people are six faces, and sixty-seven are five faces
    /// and "+62". The count stops at 99.
    static func pile(count: Int, slots: Int) -> (faces: Int, overflow: Int) {
        let faces = min(count == slots ? slots : slots - 1, count)
        return (faces, count > faces ? min(count - faces, 99) : 0)
    }
}

struct RailFolder: Hashable, Sendable, Identifiable {
    var id: UInt64
    var name: String?
    var colorValue: UInt32?
    var guilds: [RailGuild]
    var isExpanded: Bool
    var mentionCount: Int
    var hasUnread: Bool

    /// The colour of a folder nobody coloured — `--background-brand`, which
    /// Discord's stylesheet falls back to for the folder's glyph
    /// (`folderIcon`), and the swatch its Folder Settings calls the default.
    static let defaultColor: UInt32 = 0x5865F2

    /// What the folder is called: its name, or for a folder nobody named, its
    /// servers' names.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return Self.defaultName(for: guilds.map(\.name))
    }

    /// Discord's name for an unnamed folder (`n8`'s `O`): its servers' names
    /// joined by commas, **as many as fit in 64 characters** — twice a folder
    /// name's limit — with ", ..." for the rest. A name longer than what is
    /// left is skipped rather than ending the list, so a short one after it can
    /// still fit; the first is always taken. Counted in UTF-16, as JavaScript
    /// counts.
    static func defaultName(for names: [String]) -> String {
        var budget = 64
        var taken: [String] = []
        for name in names where name.utf16.count < budget || taken.isEmpty {
            taken.append(name)
            budget -= name.utf16.count
        }
        return taken.joined(separator: ", ") + (taken.count < names.count ? ", ..." : "")
    }
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
    /// The mark Discord draws before the name — see `GuildMark`.
    var mark: GuildMark? = nil
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
    /// "3 Events" — Discord's events row, which opens the events panel.
    case events(SidebarEventsRow)

    var id: UInt64 {
        switch self {
        case .category(let category): category.id.rawValue
        case .channel(let channel): channel.id.rawValue
        case .thread(let thread): thread.id.rawValue
        // A surface's raw value is a small integer and a channel id is a
        // snowflake, so the two spaces cannot collide inside one list.
        case .guildAction(let surface): surface.rawValue
        // Beside the surfaces' small integers, and as far from a snowflake.
        case .events: 99
        }
    }
}

/// The card at the top of a server's channels while one of its events is on —
/// Discord's live channel notice (`263294`'s `nM`).
struct LiveEventNotice: Hashable, Sendable {
    var eventID: UInt64
    var guildID: GuildID
    var name: String
    /// "Happening Now" for an event somewhere else, "Live Now" for one in a
    /// room — Discord's two headings.
    var heading: String
    /// Where: an external event's location, or its room's name.
    var place: String
    var placeSymbol: String
    /// The room to join, for an event in one the reader may connect to.
    var joinChannelID: ChannelID?
    /// The reader is in that room already, so the button goes to it rather
    /// than joining — the sidebar's join toggles, and would leave.
    var isJoined = false
    var isStage = false

    /// Discord's words for the way in (`428978`).
    var joinTitle: String {
        if isJoined { return "Go To Channel" }
        return isStage ? "Listen In" : "Join"
    }
}

/// The sidebar's events row: how many are coming, and whether any is new.
///
/// **Offered on Discord's terms** (`useGuildActionRows`): when something is
/// coming, or when the reader may make something. Clicking it opens the events
/// panel rather than a page, as Discord's opens its modal.
struct SidebarEventsRow: Hashable, Sendable {
    var guildID: GuildID
    var count: Int
    /// An event the reader has not seen, which lights the row as an unread
    /// channel is lit.
    var hasUnread: Bool

    var title: String {
        count == 0 ? "Events" : "\(count.formatted()) \(count == 1 ? "Event" : "Events")"
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
    /// The label anybody in the room can put on it, already split into what the
    /// row draws.
    ///
    /// **Split here rather than in the body.** A status may carry custom emoji
    /// in `<:name:id>` markup, and scanning for them is work that belongs in the
    /// memo — a hundred voice rows re-scanning their own status on every
    /// evaluation is a hundred passes for an answer that changes when somebody
    /// retypes it. Empty is a channel with no label, which is nearly all of
    /// them and costs one empty array.
    var voiceStatus: [VoiceChannelStatus.Run] = []
    /// How many people the room holds. **Zero is no limit**, which is what
    /// Discord means by it and what removes the counter rather than drawing
    /// `03 / 00`.
    var voiceLimit: Int = 0
    /// When the session in this room began, for the clock Discord runs beside
    /// the name. Nil is a silent channel.
    var voiceStartedAt: Date?
    /// A conversation's face, for the rows that have one. A DM is identified by
    /// **who** it is with, so it takes an avatar where a guild channel takes a
    /// glyph in the same gutter — same row, same metrics, different leading
    /// element. Nil everywhere else.
    var avatarURL: URL?
    var monogram: String?
    /// Drawn on the avatar. Nil for a group DM, which has no single presence.
    var status: PresenceStatus?
    /// Whether the other person is typing to the reader — the dots that take
    /// the presence dot's place, in its colour.
    var isTyping = false

    // MARK: What a direct message says about the person in it
    //
    // A guild channel is a topic; a direct message is a *person*, and the list
    // is the only place in the app where their identity has to be legible
    // without opening anything. These are the same facts the roster draws — see
    // `MemberEntry` — resolved into the same shapes, so the two surfaces cannot
    // disagree about what somebody looks like.

    /// What they are doing and their custom status — the member list's line,
    /// on the same rules. Nil is a real state and the row keeps its height
    /// either way.
    var activityLine: ActivityStatusLine?
    /// A server tag, worn beside the name.
    var tag: String?
    var tagBadgeURL: URL?
    /// The nameplate they wear, and the wash that grounds it.
    var nameplateURL: URL?
    /// The same artwork moving, played under the pointer.
    var nameplateAnimatedURL: URL?
    var nameplatePalette: NameplatePalette = .none
    /// The face and effect they chose for their name. Nil is nearly everybody
    /// and costs nothing — see `StyledDisplayName`.
    var nameStyle: DisplayNameStyle?
    /// Their name's colour, when a role or their own palette gives them one.
    var nameColorValue: UInt32?
    /// Whether the reader pinned this conversation to the top of the list.
    ///
    /// **On the value, because it decides the row's ORDER as well as its
    /// glyph.** The list is sorted by it before the rows are built, so a view
    /// that worked it out for itself would be a second copy of a decision the
    /// order already made.
    var isPinned = false

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
        voiceMembers: [VoiceMemberChip],
        voiceStatus: [VoiceChannelStatus.Run] = [],
        voiceLimit: Int = 0,
        voiceStartedAt: Date? = nil
    ) {
        self.init(
            id: id,
            name: name,
            kind: kind,
            isUnread: isUnread,
            mentionCount: mentionCount,
            isMuted: isMuted,
            voiceMembers: voiceMembers,
            voiceStatus: voiceStatus,
            voiceLimit: voiceLimit,
            voiceStartedAt: voiceStartedAt,
            avatarURL: nil,
            monogram: nil,
            status: nil
        )
    }
}

/// One person sitting in a voice channel, as the sidebar draws them.
///
/// Everything on it is a **resolved value**: the store answers the presence, the
/// role and the application table once per rebuild, and the row draws what it is
/// handed. A chip that held a user id and looked things up would do those
/// lookups inside a body evaluation, for every person in every room in the
/// server.
struct VoiceMemberChip: Hashable, Sendable, Identifiable {
    var id: UserID
    var name: String
    var avatarURL: URL?
    var monogram: String
    var isSpeaking: Bool
    /// Anything stopping them being *heard* — their own switch, or a
    /// moderator's. One flag because the row draws one crossed-out microphone
    /// for both; which of the two it is belongs on a profile, not in a list.
    var isMuted: Bool
    /// Deafened, which is a **second** glyph beside the first rather than a
    /// different one: somebody who cannot hear also cannot be heard, and
    /// Discord draws both marks because they are two different facts about the
    /// same person.
    var isDeafened: Bool
    /// Sharing a screen. Draws the LIVE chip, and is what makes a hover worth
    /// asking Discord for a picture of — see `AppModel.streamPreview`.
    var isStreaming: Bool
    var isCameraOn: Bool
    /// The custom status they set, as the little pill Discord puts after the
    /// name. Either half may be absent — a status can be one emoji.
    var statusEmoji: EmojiRef?
    var statusText: String?
    /// The mark of the game they are in, at the size the row draws it.
    ///
    /// **The application's own icon, not the presence's artwork.** Rich presence
    /// art is a 512-point key screen; what belongs at the end of a 20-point row
    /// is the small square mark people recognise, which is the icon the
    /// application registered.
    var gameIconURL: URL?
    /// What that icon is of, for the label VoiceOver reads and the flyout.
    var gameName: String?
    /// The address of their screen share, when there is one. Built by the
    /// viewer — see `GoLiveKey`.
    var streamKey: String?

    /// Whether anything is drawn in the row's trailing cluster.
    var hasAccessories: Bool {
        isStreaming || isMuted || isDeafened || gameIconURL != nil
    }
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
    /// The line under the name — the member list's, on the reader's own
    /// terms. Nil draws the status's own word, "Online" or "Idle".
    var activityLine: ActivityStatusLine?
    var isMuted: Bool
    var isDeafened: Bool
    /// The reader's own nameplate, when they wear one.
    ///
    /// **The artwork and the wash, exactly as the roster carries them.** A plate
    /// is a strip whose leading two thirds are transparent plus a palette that
    /// grounds it — see `Nameplate` — and drawing only the strip reads as a
    /// picture floating beside a name rather than as a plate behind it.
    var nameplateURL: URL?
    /// The same artwork moving, played under the pointer.
    var nameplateAnimatedURL: URL?
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
        /// A stage channel. Its own case rather than a flag on `voice`,
        /// because the surface is a different arrangement of different
        /// groups — `StagePane`.
        case stage(ChannelID)
        /// A page about the server rather than about a conversation in it.
        ///
        /// **One case for all of them**, with the surface as a payload. The
        /// three panes are three view types behind one `switch` inside
        /// `WorkspacePane`, which is internal `_ConditionalContent` under a
        /// stable outer type — not the structural swap §1 forbids.
        case guildSurface(GuildID, GuildSurface)
        /// A server's onboarding gate, taking the whole column.
        ///
        /// **A case rather than a sheet**, for the reason every other
        /// destination here is one: the column holds one view type, and the rail
        /// stays live so somebody can step away from a gate and come back to it.
        case joinGate(GuildID)
        /// Discovery — servers and apps the account is not in yet.
        ///
        /// **A case here rather than a window or a sheet**, and §1 is why: the
        /// detail column must never change view *type*, so anything added to it
        /// arrives as a case on this enum. It also outranks everything else, so
        /// it carries no payload — what it is showing lives in `DiscoveryState`,
        /// which survives stepping away to a channel and back.
        case discovery
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
    /// A bar that draws nothing.
    ///
    /// **An empty name is how this bar disappears**, not a missing title: the
    /// pill is declared only for a non-empty one and every control is declared
    /// only for its own `can` flag, so this is the whole of "no chrome here".
    /// Named once because two surfaces want it — a column with no channel, and
    /// the join gate, which is a takeover rather than a page in the app.
    static let none = ChannelChrome(
        channelID: nil,
        name: "",
        symbolName: ChannelKind.text.symbolName,
        topic: nil,
        isMemberListShown: false,
        canShowMemberList: false,
        isUserProfileShown: false,
        canShowUserProfile: false,
        canShowPins: false,
        arePinsShown: false,
        canShowThreads: false,
        areThreadsShown: false,
        canStartCall: false,
        isInCall: false,
        isCallOngoing: false,
        canShowVoiceChat: false,
        isVoiceChatShown: false
    )

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
    /// Whether the summaries toggle is offered: a channel that can have
    /// summaries **and has some**. With none there is no bar to hide, and a
    /// toggle for nothing is the inert control §5.5 is about.
    var canShowSummaries = false
    /// The bar is showing — one switch for every channel. See
    /// `AppSettings.showsSummaryBar`.
    var areSummariesShown = false
}
