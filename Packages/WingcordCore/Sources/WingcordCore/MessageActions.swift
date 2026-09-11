import Foundation

/// Everything a reader can do to one message.
///
/// **An `OptionSet` resolved once, not a dozen predicates asked one at a
/// time.** The hover pill, the menu and the keyboard all need the same answer
/// for the same row, and three surfaces each calling six gate methods is
/// eighteen resolutions of the same permission bitfield per hovered row. One
/// value, computed once, compared in a word.
public struct MessageActions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// React with an emoji that is **not** already on the message.
    public static let addReaction = MessageActions(rawValue: 1 << 0)
    /// Add yourself to a reaction somebody else already started.
    ///
    /// **A separate bit, and it is Discord's rule rather than a refinement.**
    /// `ADD_REACTIONS` gates a *new* emoji only; joining one already on the
    /// message needs nothing but being able to see the channel. A client that
    /// collapses the two greys out the chips in every channel where reactions
    /// are restricted — which is exactly the channels where the existing chips
    /// are the only ones anybody may use.
    public static let joinReaction = MessageActions(rawValue: 1 << 1)
    public static let reply = MessageActions(rawValue: 1 << 2)
    public static let forward = MessageActions(rawValue: 1 << 3)
    public static let edit = MessageActions(rawValue: 1 << 4)
    public static let delete = MessageActions(rawValue: 1 << 5)
    public static let pin = MessageActions(rawValue: 1 << 6)
    public static let unpin = MessageActions(rawValue: 1 << 7)
    public static let copyText = MessageActions(rawValue: 1 << 8)
    public static let copyLink = MessageActions(rawValue: 1 << 9)
    public static let markUnread = MessageActions(rawValue: 1 << 10)
    public static let report = MessageActions(rawValue: 1 << 11)
    public static let copyID = MessageActions(rawValue: 1 << 12)
    /// Saving a message for later — Discord's "Bookmark Message".
    ///
    /// **Nothing gates it but being able to read the message.** It is a note
    /// to yourself on the account, visible to nobody else and refused by no
    /// permission, which is why it sits beside `copyLink` rather than behind a
    /// role check.
    public static let bookmark = MessageActions(rawValue: 1 << 13)
    public static let unbookmark = MessageActions(rawValue: 1 << 14)

    /// Setting a time to be nudged about a message — Discord's "Create
    /// Reminder".
    ///
    /// **The same act as a bookmark with one field set.** One route,
    /// `PUT /users/@me/saved-messages/{channel}/{message}`, and a `due_at` is
    /// the whole of the difference — which is why this is gated exactly as
    /// `bookmark` is, and why it is offered *alongside* Remove Bookmark rather
    /// than instead of it: putting a time on a message already saved is how a
    /// bookmark becomes a reminder.
    public static let remindMe = MessageActions(rawValue: 1 << 15)

    /// Whether anything at all is offered. A row with no actions draws no pill
    /// and opens no menu, rather than opening an empty one.
    public var isEmpty: Bool { rawValue == 0 }
}

/// What the reader may do to one message, as a pure function.
///
/// **No store, no actor, no I/O** — the whole policy is a table of cases, which
/// is the only way a permission rule stays checkable. Every input is something
/// the caller already has in hand.
///
/// The rules are Discord's, and the three that are easy to get wrong are called
/// out where they are applied:
///
///  - **Editing is never granted by a permission.** `MANAGE_MESSAGES` allows
///    deleting other people's messages and never editing them, so a client that
///    offers Edit to a moderator offers an action the API refuses.
///  - **Pinning works in a direct message.** There are no roles there and no
///    `MANAGE_MESSAGES` to hold, and both parties may pin — but only their own
///    messages may be *deleted*, which is why the two cannot share a predicate.
///  - **A timed-out member may not act**, whatever their roles say. Discord
///    suppresses sending, reacting and pinning for the duration.
public enum MessageActionPolicy {

    /// Everything the policy needs to know about the message and the reader.
    ///
    /// A parameter object rather than twelve arguments: the call site is one
    /// place in the app and the failure mode of a long positional list is two
    /// `Bool`s swapped, which resolves to a plausible and wrong answer.
    public struct Input: Hashable, Sendable {
        public var permissions: Permissions
        /// Whether the reader may write in this channel at all.
        ///
        /// **Taken rather than derived from `permissions`, and that is the
        /// point.** A thread gates on `sendMessagesInThreads` and a channel on
        /// `sendMessages`; deciding it here would be a second copy of that rule,
        /// and the failure of a second copy is a Reply offered in a thread
        /// nobody may write in. One definition, in `PermissionGate.canSend`.
        public var canSend: Bool
        public var isAuthor: Bool
        /// The reader is under a timeout in this guild.
        public var isTimedOut: Bool
        /// A join, a boost, a pin notice, a call record — anything the client
        /// composed rather than somebody typed.
        public var isSystemEvent: Bool
        /// Whether there is a body worth putting on the pasteboard.
        public var hasText: Bool
        public var isPinned: Bool
        /// A DM or a group DM: no roles, and Discord's own implicit grants.
        public var isDirectMessage: Bool
        /// The reader is **lurking** this server rather than in it.
        ///
        /// **Not expressible as a permission, which is why it is its own
        /// input.** Joining a reaction somebody else started needs no bit at all
        /// — see `joinReaction` — so a lurker with `viewChannel` would be
        /// offered every chip on the message and refused by the API on each. The
        /// three actions that touch the server (react, reply, edit) are already
        /// gated by bits a lurker does not hold; this is the fourth.
        public var isPreviewing: Bool
        /// Whether this message is already saved to the account.
        ///
        /// **Answered by the account once the inbox has been opened, and by
        /// this session alone before that.** `GET /users/@me/saved-messages`
        /// is the authority and the inbox is what fetches it, so until the
        /// flyout has been opened this is only as good as what the reader
        /// bookmarked in this run — which is what it was built for. See
        /// `AppModel.bookmarkedMessageIDs` and `SessionController.loadInbox`.
        public var isBookmarked: Bool
        /// Whether the reader turned developer mode on.
        public var developerMode: Bool

        public init(
            permissions: Permissions,
            canSend: Bool,
            isAuthor: Bool,
            isTimedOut: Bool = false,
            isSystemEvent: Bool = false,
            hasText: Bool = true,
            isPinned: Bool = false,
            isDirectMessage: Bool = false,
            isPreviewing: Bool = false,
            isBookmarked: Bool = false,
            developerMode: Bool = false
        ) {
            self.permissions = permissions
            self.canSend = canSend
            self.isAuthor = isAuthor
            self.isTimedOut = isTimedOut
            self.isSystemEvent = isSystemEvent
            self.hasText = hasText
            self.isPinned = isPinned
            self.isDirectMessage = isDirectMessage
            self.isPreviewing = isPreviewing
            self.isBookmarked = isBookmarked
            self.developerMode = developerMode
        }
    }

    public static func resolve(_ input: Input) -> MessageActions {
        // Not being able to see the channel settles every case at once. It is
        // also the state a permission answer resolves to when *anything* is
        // unknown — see `PermissionGate` — so this is where a missing guild, a
        // missing member record and a channel from a server still loading all
        // land, and they land on no actions rather than on all of them.
        guard input.permissions.contains(.viewChannel) else { return [] }

        var actions: MessageActions = []
        // A lurker is in the same position as a timed-out member for everything
        // that reaches the server, and in a different one for everything that
        // does not: they may still forward, copy and mark unread.
        let canAct = !input.isTimedOut && !input.isPreviewing

        // Reacting. Two bits, because Discord gates them differently — see the
        // note on `joinReaction`.
        if canAct {
            actions.insert(.joinReaction)
            if input.permissions.contains(.addReactions) { actions.insert(.addReaction) }
        }

        // Writing. A reply is a message, so whatever decides the composer
        // decides this — see the note on `canSend`.
        if canAct, !input.isSystemEvent, input.canSend { actions.insert(.reply) }
        // Forwarding does not write *here*; the target channel is gated on its
        // own when one is chosen. What this decides is whether the message is
        // the sort of thing that can be carried at all: a call record delivered
        // to a channel it did not happen in is a row nobody can read.
        if !input.isSystemEvent { actions.insert(.forward) }

        if input.isAuthor, !input.isSystemEvent { actions.insert(.edit) }

        // **Deleting is the one place a DM must NOT inherit an implicit grant.**
        // Both parties may pin in a conversation; only the author may delete.
        if input.isAuthor || (!input.isDirectMessage && input.permissions.contains(.manageMessages)) {
            actions.insert(.delete)
        }

        // Pinning, which a DM does grant to both sides.
        if canAct, input.isDirectMessage || input.permissions.contains(.manageMessages) {
            actions.insert(input.isPinned ? .unpin : .pin)
        }

        if input.hasText { actions.insert(.copyText) }
        actions.insert(.copyLink)

        // A bookmark is the reader's own note about a message and no
        // permission touches it — but a *system* event is not a message
        // anybody would come back to, and Discord does not offer it there.
        if !input.isSystemEvent {
            actions.insert(input.isBookmarked ? .unbookmark : .bookmark)
            // **Offered in both states**, because a reminder is a bookmark with
            // a time on it: a message already saved can still have one set, and
            // hiding the row there would make "remind me" reachable only by
            // un-bookmarking first.
            actions.insert(.remindMe)
        }

        // Marking unread rewinds the read cursor, which means nothing in a
        // channel whose history the reader cannot load.
        if input.permissions.contains(.readMessageHistory) { actions.insert(.markUnread) }

        // Reporting your own message is a control with nothing behind it.
        if !input.isAuthor, !input.isSystemEvent { actions.insert(.report) }

        if input.developerMode { actions.insert(.copyID) }

        return actions
    }
}
