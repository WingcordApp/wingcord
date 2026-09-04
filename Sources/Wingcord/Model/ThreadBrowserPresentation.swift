import Foundation
import WingcordCore

// MARK: - Every thread in a channel, as the flyout lists them
//
// The board's snapshot answers a different question — a forum post's tags,
// preview line and thumbnail — so this is its own projection over the same
// stored pages rather than a subset of it. What a browser row needs is who
// started the thread, when it was last touched, and how many people are in it.

/// One thread, as a row in the flyout.
struct ThreadBrowserRow: Hashable, Sendable, Identifiable {
    var id: ChannelID
    var name: String
    /// "Started by IMS". Nil when the owner is somebody this session has never
    /// met — the row still reads without it.
    var startedBy: String?
    /// "Last active 3d ago".
    var lastActive: String
    /// The faces this session can actually draw.
    ///
    /// **Only the ones we know.** `member_ids_preview` is five bare ids with no
    /// user objects behind them, so a session that has not met these people has
    /// nothing to draw and a row of grey circles is noise. The count beside it
    /// carries the information either way.
    var faces: [ThreadBrowserFace]
    /// "50+" or "+24" — see `ThreadBrowserPresentation`.
    var memberBadge: String?
    var isArchived: Bool
    var isLocked: Bool
    var isFollowed: Bool
}

struct ThreadBrowserFace: Hashable, Sendable, Identifiable {
    var id: UserID
    var url: URL?
    var monogram: String
}

struct ThreadBrowserPresentation: Hashable, Sendable {
    var channelID: ChannelID
    var channelName: String
    var rows: [ThreadBrowserRow]
    var isLoading: Bool
    var loadFailed: Bool
    var hasMore: Bool
    /// The server's own total, which is not the number of rows loaded.
    var totalResults: Int
    /// Whether a filter is narrowing the list, so an empty result can say why.
    var isFiltered: Bool
}

extension AppModel {

    /// The flyout's snapshot.
    ///
    /// Not memoized, unlike the board's: this is built only while a popover is
    /// open, over at most a few pages, and a memo whose key would have to carry
    /// the search text is a memo that misses on every keystroke anyway.
    func threadBrowserPresentation(for channelID: ChannelID) -> ThreadBrowserPresentation {
        let channel = channelIndex[channelID]
        let board = forumBoard(for: channelID)
        let guildID = channel?.guildID
        let filter = threadSearchText.trimmingCharacters(in: .whitespaces)

        var rows: [ThreadBrowserRow] = []
        rows.reserveCapacity(board.postIDs.count)

        for threadID in board.postIDs {
            guard let thread = channelIndex[threadID] else { continue }
            if !filter.isEmpty,
               thread.name.range(of: filter, options: .caseInsensitive) == nil {
                continue
            }
            let owner = thread.ownerID.flatMap { users[$0] }
            let ownerMember = guildID.flatMap { guild in
                thread.ownerID.flatMap { members[guild]?[$0] }
            }

            rows.append(
                ThreadBrowserRow(
                    id: threadID,
                    name: thread.name,
                    startedBy: ownerMember?.resolvedName(user: owner) ?? owner?.displayName,
                    // The id's own timestamp is the fallback: a thread nobody has
                    // answered has no last message, and its age is its own.
                    lastActive: RelativeTime.compact(
                        thread.lastMessageID?.timestamp ?? threadID.timestamp
                    ),
                    faces: faces(of: thread, inGuild: guildID),
                    memberBadge: Self.memberBadge(
                        count: thread.memberCount,
                        shown: thread.memberIDsPreview.count
                    ),
                    isArchived: thread.threadMetadata?.isArchived ?? false,
                    isLocked: thread.threadMetadata?.isLocked ?? false,
                    isFollowed: threadMemberships[threadID] != nil
                )
            )
        }

        return ThreadBrowserPresentation(
            channelID: channelID,
            channelName: channel?.name ?? "",
            rows: rows,
            isLoading: board.isLoading,
            loadFailed: board.loadFailed,
            // A filtered list must not page: the reader is looking at a subset
            // of what is loaded, and appending a page underneath them would
            // scroll the answer they were reading off the bottom.
            hasMore: board.hasMore && filter.isEmpty,
            totalResults: board.totalResults,
            isFiltered: !filter.isEmpty
        )
    }

    /// The faces a row can draw, in the order Discord sent them.
    private func faces(of thread: Channel, inGuild guildID: GuildID?) -> [ThreadBrowserFace] {
        var faces: [ThreadBrowserFace] = []
        faces.reserveCapacity(thread.memberIDsPreview.count)
        for userID in thread.memberIDsPreview {
            guard let user = users[userID] else { continue }
            faces.append(
                ThreadBrowserFace(
                    id: userID,
                    url: avatarURL(forUserID: userID, inGuild: guildID, side: Metrics.avatarInline),
                    monogram: user.monogram
                )
            )
        }
        return faces
    }

    /// The count beside a row's faces.
    ///
    /// **Captured**, `threads toolbar.har`: a thread reporting `member_count: 50`
    /// draws "50+" and one reporting 29 draws "+24" against five faces. Discord
    /// stops counting at fifty, so fifty means "at least fifty" and gets the
    /// plus after the number; anything lower is exact and the badge names how
    /// many are not pictured.
    static func memberBadge(count: Int?, shown: Int) -> String? {
        guard let count, count > 0 else { return nil }
        if count >= 50 { return "50+" }
        let remainder = count - shown
        return remainder > 0 ? "+\(remainder)" : nil
    }
}
