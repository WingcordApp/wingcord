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
    /// The Channels & Roles / Server Guide pair, above the first category.
    case guildAction(SidebarAction)

    var id: UInt64 {
        switch self {
        case .category(let category): category.id.rawValue
        case .channel(let channel): channel.id.rawValue
        case .guildAction(let action): action.kind.rawValue
        }
    }
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

struct SidebarAction: Hashable, Sendable {
    enum Kind: UInt64, Hashable, Sendable {
        case channelsAndRoles = 1
        case serverGuide = 2
    }

    var kind: Kind

    var title: String {
        switch kind {
        case .channelsAndRoles: "Channels & Roles"
        case .serverGuide: "Server Guide"
        }
    }

    var symbolName: String {
        switch kind {
        case .channelsAndRoles: "person.2.badge.gearshape"
        case .serverGuide: "book"
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
    /// The voice channel the reader is in, if any. Drawn as a line above the
    /// identity row rather than as a separate bar, so the sidebar's foot stays
    /// one object.
    var voiceChannelName: String?
    var voiceGuildName: String?
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
    }

    enum Supplementary: Hashable, Sendable {
        case members
        /// The other person, beside a direct message. A DM has no roster to
        /// show and a guild channel has no single person, so the two are
        /// different cases rather than one pane that switches contents.
        case userProfile(UserID)
        case thread(ChannelID)
        case search
    }

    var primary: Primary
    var supplementary: Supplementary?

    static let empty = WorkspacePresentation(primary: .empty, supplementary: nil)
}

/// The chrome across the top of the detail column.
struct ChannelChrome: Hashable, Sendable {
    var channelID: ChannelID?
    var name: String
    var kind: ChannelKind
    var topic: String?
    var isMemberListShown: Bool
    var canShowMemberList: Bool
    /// The DM profile pane's toggle. Its own pair rather than reusing the member
    /// list's, because the two surfaces never coexist and sharing one flag would
    /// mean hiding the roster in a server also hides the profile in every DM.
    var isUserProfileShown: Bool
    var canShowUserProfile: Bool
}
