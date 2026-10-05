import Foundation

// MARK: - What the reader may do to a thread

/// What the reader may do to one thread or forum post — the rules behind every
/// item of Discord's thread menus.
///
/// **Discord's rules, item by item**: close and open (`182061`), lock
/// (`707792`), pin (`41402`), edit (`200273`), tags (`565846`), Anyone can
/// invite (`707653`) and delete (`307623`). Each asks its own question, but the
/// questions are built from four predicates in one module (`406704`), and
/// those are written once here and named for what they decide:
///
/// - **moderates as owner** (`NI`): Manage Threads, or the thread's own author
///   while it is not locked;
/// - **manages** (`H_`): Manage Threads;
/// - **can reopen** (`lK`): Manage Threads on a locked thread, otherwise Send
///   Messages in Threads and Send Messages;
/// - **is writable** (`Id`): open, or closed but unlocked and reopenable.
///
/// A thread resolves its permissions against its parent's overwrites — it has
/// none of its own — so one resolved set answers for both, which is what
/// `PermissionGate.permissions(in:)` hands over for a thread.
///
/// **A moderator report loses most of it**, as Discord's does: a report in a
/// server's moderator-report forum is resolved, not closed, locked or edited.
public struct ThreadGate: Hashable, Sendable {
    /// Close Thread, or Open Thread on a closed one.
    public var canCloseOrOpen: Bool
    /// Lock Thread, or Unlock Thread on a locked one.
    public var canLock: Bool
    /// Edit Thread — its name, slowmode and when it hides.
    public var canEdit: Bool
    /// The edit page's name field: its author's while they may send, and
    /// otherwise whoever moderates it (`nw`'s `canSendMessages` and
    /// `canManageChannels`).
    public var canRename: Bool
    /// The edit page's Slowmode — a moderator's alone (`isThreadModerator`).
    public var canSetSlowmode: Bool
    /// The edit page's Hide After Inactivity, Anyone can invite and Spoiler
    /// Channel — the author's or a moderator's (`canManageThread`).
    public var canChangeSettings: Bool
    /// Edit Tags, on a post whose forum has tags the reader may use.
    public var canEditTags: Bool
    /// Pin Post — a forum's own, so only a post.
    public var canPin: Bool
    /// Anyone can invite — a private thread's switch.
    public var canSetInvitable: Bool
    /// What Delete does here, or nil where the reader may not.
    public var deletion: Deletion?
    /// The tags the reader may put on the post: every one of the forum's to
    /// somebody with Manage Threads, the unmoderated ones to everybody else
    /// (`691060`'s `OT`).
    public var usableTags: [ForumTag]

    /// Discord's three deletes, and the confirmation each asks (`572874`).
    public enum Deletion: Hashable, Sendable {
        /// Delete Thread: the thread, and everything said in it.
        case thread
        /// Delete Post. `deletesReplies` is a moderator's — every reply goes
        /// with it; the author's own post can only be deleted while nobody has
        /// answered, and Discord's sentence then says nothing about replies.
        case post(deletesReplies: Bool)
        /// Delete Message: the author's opening message alone, once others have
        /// replied — the post stays, and so do their replies. The message's id
        /// is the post's own.
        case openingMessage

        public var title: String {
            switch self {
            case .thread: "Delete Thread"
            case .post: "Delete Post"
            case .openingMessage: "Delete Message"
            }
        }

        /// Discord's confirmation, word for word (`a6Gz9J`, `su3voL`,
        /// `6/pY2+`, `RUHcyk`) — the name is bold in Discord's.
        public func message(name: String) -> String {
            switch self {
            case .thread, .post(deletesReplies: false):
                "Are you sure you want to delete \(name)? This cannot be undone."
            case .post(deletesReplies: true):
                "Are you sure you want to delete \(name)? All message replies will also be "
                    + "deleted. This cannot be undone."
            case .openingMessage:
                "Are you sure you want to delete your message? Since other members have replied "
                    + "to your post, only your original message will be deleted. This cannot be "
                    + "undone."
            }
        }
    }

    /// - Parameters:
    ///   - permissions: the reader's, resolved in the thread.
    ///   - canSend: the composer's own answer for the thread — Send Messages in
    ///     Threads, and not timed out.
    ///   - replyCount: the messages after the opening one — Discord's
    ///     `message_count`, which never counts the opener.
    ///   - hasOpeningMessage: whether the post's opening message is known to
    ///     exist. An author can delete only that message once there are
    ///     replies, and only if it is still there.
    public init(
        thread: Channel,
        parent: Channel?,
        permissions: Permissions,
        canSend: Bool,
        userID: UserID?,
        replyCount: Int,
        hasOpeningMessage: Bool
    ) {
        let metadata = thread.threadMetadata
        let isThread = thread.kind.isThread
        let isLocked = metadata?.isLocked ?? false
        let isArchived = metadata?.isArchived ?? false
        let manages = permissions.contains(.manageThreads)
        let isOwner = userID != nil && thread.ownerID == userID
        let isPost = Self.isForumPost(thread, parent: parent)
        let isReport = thread.flags.contains(.isModeratorReportChannel)
        let isReportPost = isReport && isPost

        let moderatesAsOwner = isThread && parent != nil && (manages || (!isLocked && isOwner))
        let canReopen = isThread
            && (isLocked ? manages : canSend && permissions.contains(.sendMessages))
        let isWritable = !isThread || !isArchived || (!isLocked && canReopen)
        let isLockedOut = isLocked && !manages

        canCloseOrOpen = (isArchived ? canReopen : moderatesAsOwner) && !isReportPost
        canLock = isThread && manages && !isReport
        canPin = isThread && manages && (parent?.isForumLike ?? false)
        canSetInvitable = manages && thread.kind == .privateThread
        canEdit = moderatesAsOwner && isWritable && !isLockedOut && !isReport
        canRename = isOwner ? permissions.contains(.sendMessages) : moderatesAsOwner
        canSetSlowmode = manages
        canChangeSettings = moderatesAsOwner

        let tags = parent?.availableTags ?? []
        usableTags = manages ? tags : tags.filter { !$0.isModerated }
        canEditTags = moderatesAsOwner && isPost && !usableTags.isEmpty && isWritable && !isReport

        // `307623`, letter for letter: a moderator deletes the whole post; its
        // author deletes it while nobody has answered, and only the opening
        // message once somebody has. A report whose opening message is gone is
        // the one a moderator may delete outright.
        let canView = permissions.contains(.viewChannel)
        let reportWithoutOpener = isReportPost && manages && !hasOpeningMessage
        let deletesPost = isPost && (manages || (isOwner && replyCount < 1) || reportWithoutOpener)
        let deletesOpener = isPost && isOwner && !manages && replyCount > 0 && hasOpeningMessage
        if canView, isThread, !isReportPost || reportWithoutOpener,
           manages || deletesPost || deletesOpener
        {
            deletion = !isPost ? .thread
                : deletesPost ? .post(deletesReplies: manages)
                : .openingMessage
        } else {
            deletion = nil
        }
    }

    /// Discord's `isForumPost`: a public thread in a forum or a media channel.
    /// A post takes Discord's other words — Follow Post, Close Post, Edit Post.
    public static func isForumPost(_ thread: Channel, parent: Channel?) -> Bool {
        thread.kind == .publicThread && (parent?.isForumLike ?? false)
    }
}
