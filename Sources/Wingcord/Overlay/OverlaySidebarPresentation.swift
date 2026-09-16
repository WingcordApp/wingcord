import Foundation
import WingcordCore

// MARK: - What the overlay's sidebar draws
//
// Three lists behind one control, and **nothing new on the wire**: friends are
// `relationships`, conversations are `ChannelIndex`'s private channels in the
// order `patchLastMessage` already keeps them, and the rooms are `voiceStates`
// grouped by the channel they name. `AppModel+OverlaySidebar` is the one place
// any of it is resolved.
//
// Plain `Hashable` values with no store reference and no closures — the contract
// every other presentation in this app has, and the reason this one can be
// `.equatable()` over a memo rather than rebuilt per frame of a game.

/// Which of the three lists is on screen.
///
/// The raw value is a persistence key: the reader's last tab survives the game
/// going away, because reopening the overlay onto a tab they did not choose is
/// the surface forgetting something it was watching them do.
enum OverlaySidebarTab: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case friends
    case messages
    case voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friends: "Friends"
        case .messages: "Messages"
        case .voice: "Voice"
        }
    }

    /// What the search field promises, which is different per tab and is the
    /// only thing telling somebody what it will actually filter.
    var searchPrompt: String {
        switch self {
        case .friends: "Search friends"
        case .messages: "Search messages"
        case .voice: "Search voice channels"
        }
    }

    var emptyTitle: String {
        switch self {
        case .friends: "No friends here"
        case .messages: "No conversations"
        case .voice: "No rooms in use"
        }
    }

    var emptySymbol: String {
        switch self {
        case .friends: "person.2"
        case .messages: "bubble.left.and.bubble.right"
        case .voice: "waveform"
        }
    }
}

// MARK: - The reader, at the top of it

/// The card above the tabs: banner, face, name, status.
///
/// **It carries the reader's own colours**, because this surface is the one
/// place in the app that is theirs rather than a server's — and because over a
/// game a panel with no identity reads as a system dialog. `ProfileGround` turns
/// the pair into a ground, and the banner fills the strip that would otherwise
/// be a flat block of nothing.
struct OverlayIdentity: Hashable, Sendable {
    var userID: UserID
    var displayName: String
    var handle: String
    var avatarURL: URL?
    var monogram: String
    var decorationURL: URL?
    var status: PresenceStatus
    var customStatus: String?
    var customStatusEmoji: EmojiRef?
    /// The reader's own banner, drawn across the head of the panel.
    var bannerURL: URL?
    /// `theme_colors`, or the pair quantised out of their artwork.
    var themeColorValues: [UInt32]
    /// The legacy single swatch, which is what stands in for a banner nobody
    /// uploaded — see `ProfileGround.plateStyle(accentColorValue:)`.
    var accentColorValue: UInt32?

    static let signedOut = OverlayIdentity(
        userID: UserID(rawValue: 0),
        displayName: "Signed out",
        handle: "",
        monogram: "?",
        status: .offline,
        themeColorValues: []
    )
}

// MARK: - Friends

/// Which band of the friends list a person is in.
///
/// **Four, and the order is the declaration order.** Discord's own overlay
/// groups Favorites, In Game and then everybody online; offline is last because
/// it is the only band nobody is scanning for.
enum OverlayPeopleGroup: String, Hashable, Sendable, CaseIterable, Identifiable, Codable {
    case favorites
    case inGame
    case online
    case offline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .inGame: "In Game"
        case .online: "Online"
        case .offline: "Offline"
        }
    }
}

struct OverlayPeopleSection: Hashable, Sendable, Identifiable {
    var id: OverlayPeopleGroup
    var people: [OverlayPerson]

    var title: String { id.title }
}

/// One friend, as the list draws them.
///
/// Everything on it is resolved: the store answers the presence, the avatar and
/// the application table once per rebuild and the row draws what it was handed.
/// A row that held a user id and looked things up would do those lookups inside
/// a body evaluation, for every person in the account, over somebody's game.
struct OverlayPerson: Hashable, Sendable, Identifiable {
    var id: UserID
    var displayName: String
    var avatarURL: URL?
    var monogram: String
    var decorationURL: URL?
    var status: PresenceStatus
    var isOnMobile: Bool
    /// What they are doing — an activity, or the status they typed. Nil is a
    /// real state and the row keeps its height either way.
    var subtitle: String?
    /// The emoji beside a custom status. Only ever set when the subtitle came
    /// from one, never beside an activity line.
    var subtitleEmoji: EmojiRef?
    /// The mark of the game they are in, at the size the row draws it.
    ///
    /// **The application's own icon, not the presence's key art**, for the
    /// reason the voice chip already gives: rich-presence artwork is a
    /// 512-point screenshot and what belongs at the end of a row is the small
    /// square mark people recognise.
    var gameIconURL: URL?
    var isStreaming: Bool
    /// The conversation with them, when one already exists. Nil is somebody the
    /// account has never written to, and the row opens one on click.
    var channelID: ChannelID?
    /// **Folded once, when the list is built.** The field the search matches
    /// against, case- and diacritic-folded — the same fold the quick switcher
    /// uses, for the same reason: done per keystroke it is a string allocation
    /// per friend per character typed.
    var searchKey: String
}

// MARK: - Messages

/// One conversation in the recent list.
struct OverlayConversation: Hashable, Sendable, Identifiable {
    var id: ChannelID
    var title: String
    var avatarURL: URL?
    var monogram: String
    /// Nil for a group, which has several people and no single presence.
    var status: PresenceStatus?
    /// The last thing said, already folded to one line.
    ///
    /// **Only for a conversation whose transcript this session has opened**, and
    /// that is an honest limit rather than a gap: `lastMessageID` is on the
    /// channel and the message behind it is not, so a client that promised a
    /// preview for every row would have to fetch the account's whole DM list to
    /// keep it. The row draws the handle instead, which is the other thing
    /// somebody scans for.
    var preview: String?
    var isUnread: Bool
    var mentionCount: Int
    var isMuted: Bool
    var isFavorite: Bool
    var searchKey: String
}

// MARK: - Voice

/// A room worth joining, and who is in it.
struct OverlayVoiceRoom: Hashable, Sendable, Identifiable {
    var id: ChannelID
    var name: String
    /// The server it belongs to. Nil for a call in a direct message, which has
    /// no server above it.
    var guildName: String?
    var guildIconURL: URL?
    var guildMonogram: String
    /// The label anybody in the room can set.
    var status: String?
    /// How many people the room holds. **Zero is no limit**, which is what
    /// Discord means by it and what removes the counter rather than drawing
    /// `03 / 00`.
    var limit: Int
    /// The faces, capped — see `OverlayVoiceRoom.faceLimit`.
    var faces: [OverlayVoiceFace]
    /// How many more there are than the row drew.
    var overflow: Int
    /// Whether the reader is already in this one, which turns the row from an
    /// invitation into a destination.
    var isJoined: Bool
    var searchKey: String

    /// How many faces a row carries before it starts counting instead.
    ///
    /// **Four, because the row is one line.** A room with thirty people in it
    /// drawn as thirty faces is a row that wraps, and a wrapped row in a list
    /// somebody is glancing at mid-game is the list failing at its one job.
    static let faceLimit = 4

    var count: Int { faces.count + overflow }
}

struct OverlayVoiceFace: Hashable, Sendable, Identifiable {
    var id: UserID
    var avatarURL: URL?
    var monogram: String
    var isStreaming: Bool
}

// MARK: - The whole panel

struct OverlaySidebarPresentation: Hashable, Sendable {
    var identity: OverlayIdentity
    var friends: [OverlayPeopleSection]
    var conversations: [OverlayConversation]
    var rooms: [OverlayVoiceRoom]

    static let empty = OverlaySidebarPresentation(
        identity: .signedOut,
        friends: [],
        conversations: [],
        rooms: []
    )

    /// The friends list narrowed to a query, sections that empty out removed.
    ///
    /// **Filtered here rather than in the view**, so the three tabs share one
    /// matcher and the view holds no algorithm. The matcher is a fold-free
    /// substring test over keys folded when the list was built — §2.
    func friends(matching folded: String) -> [OverlayPeopleSection] {
        guard !folded.isEmpty else { return friends }
        return friends.compactMap { section in
            let people = section.people.filter { $0.searchKey.contains(folded) }
            return people.isEmpty ? nil : OverlayPeopleSection(id: section.id, people: people)
        }
    }

    func conversations(matching folded: String) -> [OverlayConversation] {
        guard !folded.isEmpty else { return conversations }
        return conversations.filter { $0.searchKey.contains(folded) }
    }

    func rooms(matching folded: String) -> [OverlayVoiceRoom] {
        guard !folded.isEmpty else { return rooms }
        return rooms.filter { $0.searchKey.contains(folded) }
    }

    /// Whether the tab has anything at all, before a query narrows it.
    func isEmpty(_ tab: OverlaySidebarTab) -> Bool {
        switch tab {
        case .friends: friends.allSatisfy(\.people.isEmpty)
        case .messages: conversations.isEmpty
        case .voice: rooms.isEmpty
        }
    }
}
