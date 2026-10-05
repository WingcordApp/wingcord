import Foundation

/// A forum board's live posts, in Discord's order, and which of them are new.
///
/// **Discord's active-post store (`207777`)**: the pinned post first, then the
/// board's sort — the newest message for Recently Active, the newest post for
/// Date Posted — with the reader's tag filter applied to the live posts on the
/// client. The archived posts come from the server already filtered and sorted,
/// so they are not this type's business; they follow under "Older Posts".
public enum ForumOrder {

    /// The live posts the board shows, in the order it shows them.
    public static func livePosts(_ posts: [Channel], query: ForumQuery) -> [ChannelID] {
        posts
            .filter { matches($0, query: query) }
            .sorted { lhs, rhs in
                if lhs.isPinnedPost != rhs.isPinnedPost { return lhs.isPinnedPost }
                let left = sortKey(lhs, query.sortOrder)
                let right = sortKey(rhs, query.sortOrder)
                // Ties go to the newer post, so the order never depends on
                // where the index happened to hold them.
                return left != right ? left > right : lhs.id.rawValue > rhs.id.rawValue
            }
            .map(\.id)
    }

    /// Discord's tag filter: any chosen tag, or every one of them. A post with
    /// no tags matches no filter.
    public static func matches(_ post: Channel, query: ForumQuery) -> Bool {
        guard !query.tags.isEmpty else { return true }
        switch query.tagMatching {
        case .some: return post.appliedTags.contains(where: query.tags.contains)
        case .all: return query.tags.allSatisfy(post.appliedTags.contains)
        }
    }

    /// Discord's "NEW" (`573163`'s `isNewForumThread`): a live post the reader
    /// has never opened, made after the forum was last read — as it stood when
    /// the board was opened — and after they joined the server.
    ///
    /// - Parameters:
    ///   - readMark: the forum's own read state when the board was opened. Nil —
    ///     a forum never read — makes nothing new, as Discord's does.
    ///   - isOpened: whether the post has a read state of its own.
    ///   - joinedAt: when the reader joined the server. Unknown makes nothing
    ///     new: Discord falls back to now, which no post is newer than.
    public static func isNew(_ post: Channel, readMark: MessageID?, isOpened: Bool, joinedAt: Date?) -> Bool {
        guard post.threadMetadata?.isArchived != true, !isOpened,
              let readMark, post.id.rawValue > readMark.rawValue,
              let joinedAt
        else { return false }
        return post.id.timestamp > joinedAt
    }

    private static func sortKey(_ post: Channel, _ order: ForumSortOrder) -> UInt64 {
        switch order {
        case .recentActivity: post.lastMessageID?.rawValue ?? post.id.rawValue
        case .creationDate: post.id.rawValue
        }
    }
}
