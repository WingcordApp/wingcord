import Foundation

/// One of a forum's tags.
///
/// A forum defines up to twenty; a post applies up to five of them. The post
/// carries only the ids, so a tag is always resolved against its parent forum's
/// `availableTags` — which is why `ForumTagID` is its own phantom type and why
/// nothing here caches a name.
public struct ForumTag: Hashable, Sendable, Codable, Identifiable {
    public var id: ForumTagID
    public var name: String
    /// Whether adding or removing it needs `MANAGE_THREADS`. A reader without
    /// that permission still *sees* the tag; they cannot set it.
    public var isModerated: Bool
    /// The chip's emoji, if it has one. Nil is common and draws no glyph rather
    /// than a placeholder.
    public var emoji: EmojiRef?

    public init(
        id: ForumTagID,
        name: String,
        isModerated: Bool = false,
        emoji: EmojiRef? = nil
    ) {
        self.id = id
        self.name = name
        self.isModerated = isModerated
        self.emoji = emoji
    }
}

/// How a forum's posts are ordered.
///
/// **Captured**, `forums.har`: the wire sends this as `sort_by=last_message_time`
/// on `threads/search`, *not* as the integer the channel object stores. Both
/// spellings are here because both are needed — the integer is what the forum
/// channel declares as its default, and the string is what a query asks for.
public enum ForumSortOrder: Int, Hashable, Sendable, CaseIterable, Codable {
    case recentActivity = 0
    case creationDate = 1

    public var title: String {
        switch self {
        case .recentActivity: "Recently Active"
        case .creationDate: "Date Posted"
        }
    }

    /// The `sort_by` query value.
    public var queryValue: String {
        switch self {
        case .recentActivity: "last_message_time"
        case .creationDate: "creation_time"
        }
    }
}

/// How a forum's posts are laid out.
///
/// Discord's `default_forum_layout`: 0 means "the reader has not chosen", which
/// it resolves to the list. That third state is not modelled — a layout that can
/// be "unset" forces every reader to coalesce, and the coalesce is always to the
/// same answer.
public enum ForumLayout: Int, Hashable, Sendable, CaseIterable, Codable {
    case list = 1
    case gallery = 2

    /// Reads the channel's raw value, resolving Discord's 0 to the list.
    public init(rawChannelValue: Int) {
        self = rawChannelValue == 2 ? .gallery : .list
    }

    public var title: String {
        switch self {
        case .list: "List"
        case .gallery: "Gallery"
        }
    }

    public var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .gallery: "square.grid.2x2"
        }
    }
}

/// Whether a tag filter wants any of the chosen tags or all of them.
///
/// **Captured**, `forums.har`: `tag_setting=match_some` by default, and
/// `match_all` after toggling the control. The query is sent with the parameter
/// present in both cases — there is no "omit it" state.
public enum TagMatching: String, Hashable, Sendable, CaseIterable, Codable {
    case some = "match_some"
    case all = "match_all"

    public var title: String {
        switch self {
        case .some: "Match Some"
        case .all: "Match All"
        }
    }
}

/// The channel bitfield.
///
/// Only the bits this client can act on are named. The rest are carried in
/// `rawValue` and written back untouched — `INVARIANTS.md` §1: a bitfield
/// written back must carry the bits this client cannot draw.
public struct ChannelFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// A post pinned to the top of its forum. Pinned posts do not auto-archive.
    public static let pinned = ChannelFlags(rawValue: 1 << 1)
    /// The forum refuses a post with no tag on it.
    public static let requireTag = ChannelFlags(rawValue: 1 << 4)
    /// Discord's own spam classification for a thread.
    public static let isSpam = ChannelFlags(rawValue: 1 << 5)
    /// The server turned summaries off for this one channel. Discord's
    /// `SUMMARIES_DISABLED`, 2048 in its channel-flag table.
    public static let summariesDisabled = ChannelFlags(rawValue: 1 << 11)
    /// Discord's `HIDE_MEDIA_DOWNLOAD_OPTIONS` — set when the Overview's "Show
    /// Option to Save and Copy Embedded Media" is off.
    public static let hideMediaDownloadOptions = ChannelFlags(rawValue: 1 << 15)
    /// Discord's `IS_MODERATOR_REPORT_CHANNEL`, 524288 in its table: a
    /// server's moderator-report forum, and each report posted in it. A report
    /// is resolved rather than edited, so most of a thread's menu leaves it
    /// alone — see `ThreadGate`.
    public static let isModeratorReportChannel = ChannelFlags(rawValue: 1 << 19)
    /// Discord's `IS_SPOILER_CHANNEL`, Content Visibility's one bit.
    public static let spoilerChannel = ChannelFlags(rawValue: 1 << 21)
}

/// What a forum's post list was asked for.
///
/// One value rather than four properties on the store, so that a change to any
/// part of it is one write and one comparison — the list reloads when this
/// changes and on nothing else.
public struct ForumQuery: Hashable, Sendable {
    public var sortOrder: ForumSortOrder
    public var layout: ForumLayout
    public var tagMatching: TagMatching
    /// The tag chips the reader has lit. Empty means no tag filter at all, which
    /// is not the same as "match none" — the parameter is simply omitted.
    public var tags: Set<ForumTagID>

    public init(
        sortOrder: ForumSortOrder = .recentActivity,
        layout: ForumLayout = .list,
        tagMatching: TagMatching = .some,
        tags: Set<ForumTagID> = []
    ) {
        self.sortOrder = sortOrder
        self.layout = layout
        self.tagMatching = tagMatching
        self.tags = tags
    }

    /// The query a forum channel's own defaults imply, before the reader touches
    /// anything.
    ///
    /// **A media channel is always a gallery**, whatever it says: Discord's
    /// `getDefaultLayout`, which is why its menu has no View as.
    public init(defaultsOf channel: Channel) {
        self.init(
            sortOrder: channel.defaultSortOrder ?? .recentActivity,
            layout: channel.kind == .media ? .gallery : channel.defaultForumLayout ?? .list,
            tagMatching: channel.defaultTagMatching ?? .some
        )
    }

    /// Discord's "Reset to default": the forum's own sort, layout and matching, and
    /// the tags the reader has lit stay lit (`sE`).
    public func resettingToDefaults(_ defaults: ForumQuery) -> ForumQuery {
        var next = defaults
        next.tags = tags
        return next
    }

    /// Whether two queries ask the server the same question.
    ///
    /// **Layout is excluded, and that is the point.** Switching between list and
    /// gallery re-lays out posts the client already holds; re-fetching for it
    /// would throw away the pages already loaded and put a spinner over a purely
    /// visual change.
    public func matchesFetch(_ other: ForumQuery) -> Bool {
        sortOrder == other.sortOrder
            && tagMatching == other.tagMatching
            && tags == other.tags
    }
}
