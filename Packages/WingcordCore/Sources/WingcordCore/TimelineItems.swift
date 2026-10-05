import Foundation

/// One row of a transcript.
///
/// The timeline is a flat array of these, not a nested tree of days containing
/// runs containing messages. Flat is what makes a virtualised canvas possible:
/// the row at scroll offset *y* is found by binary search over one array of
/// cumulative heights, and a nested shape would need that search to descend.
public enum TimelineItem: Hashable, Sendable {
    /// A calendar-day heading.
    case daySeparator(Date)
    /// The "new messages" line. At most one per transcript.
    case unreadDivider
    /// A message, plus everything about its neighbours that the painter needs.
    case message(TimelineMessage)
    /// Messages folded into one line — from somebody the reader blocked or
    /// ignored, or from a suspended account. See `CollapsedGroup`.
    case collapsedGroup(CollapsedGroup)
    /// The channel's beginning — the "this is the start of #general" block.
    case conversationStart
    /// A placeholder group while a page of history is in flight.
    ///
    /// **This is a scrolling ROW, not a spinner pinned above the content**, and
    /// the difference is the whole reason it exists. A one-line sentinel gives a
    /// flick nowhere to travel: the gesture hits the end of the content and
    /// rubber-bands back while the fetch is still out, which reads as the list
    /// refusing to scroll. A deep runway of these is somewhere to go, and it
    /// also means the request goes out earlier, because the placeholder
    /// materialises as the viewport approaches it rather than when it arrives.
    ///
    /// **It only appears BESIDE messages that already exist** — above them while
    /// older history remains, and below them while the transcript is cut off
    /// from the present. A runway is a gesture affordance — somewhere for a
    /// flick that is already travelling to go — and there is no such gesture on
    /// a channel that has not loaded yet. Twenty placeholder groups filling an
    /// empty viewport is not a loading state, it is a wall of grey bars that
    /// looks like the real content failed.
    ///
    /// The index runs on across both runways, so no two rows of one transcript
    /// are equal values.
    case historySkeleton(index: Int)
    /// A titled mark above the message a stretch of the channel begins with —
    /// the open topic's, or the summary the reader went to. See `TimelineMark`.
    case marker(TimelineMark.Kind, id: UInt64, title: String)
    /// The first page is still in flight. One quiet row, not a runway.
    case loadingFirstPage
    /// The first page was asked for and did not arrive.
    ///
    /// **A distinct case, because "loading" and "failed" look identical from the
    /// outside and only one of them is going to change on its own.** Without it
    /// a channel whose fetch was refused sits under "Loading messages..."
    /// forever, which is the difference between a client that is slow and a
    /// client that is broken — and the reader cannot tell which.
    case historyUnavailable(reason: String)

    public var messageID: MessageID? {
        if case .message(let item) = self { return item.id }
        return nil
    }
}

/// A message as the timeline needs it: the record, plus its position in its run.
///
/// **Neighbour facts are computed once, in the reducer, and stored.** A row that
/// asks "is the message before me by the same author?" during layout has to
/// reach outside itself, which either means the painter holds the whole array
/// and indexes backwards on every row, or the row holds a reference to its
/// neighbour and the array can never be diffed cheaply. Both were avoidable by
/// spending three bytes here.
public struct TimelineMessage: Hashable, Sendable, Identifiable {
    public var id: MessageID { message.id }
    public var message: Message
    public var flags: RunFlags

    public init(message: Message, flags: RunFlags) {
        self.message = message
        self.flags = flags
    }

    public struct RunFlags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// First message of a run: draws the avatar, the author name and the
        /// full timestamp.
        public static let head = RunFlags(rawValue: 1 << 0)
        /// Last message of a run: carries the run's bottom spacing.
        public static let tail = RunFlags(rawValue: 1 << 1)
        /// The first message the reader has not seen.
        public static let firstUnread = RunFlags(rawValue: 1 << 2)
        /// The message mentions the reader, directly or through a role.
        public static let mentionsMe = RunFlags(rawValue: 1 << 3)
        /// A local echo that has not been acknowledged by the server yet.
        public static let pending = RunFlags(rawValue: 1 << 4)
        /// A send that failed and is offering a retry.
        public static let failed = RunFlags(rawValue: 1 << 5)
        /// The message is in a fold the reader opened, and sits on its tint.
        public static let inOpenGroup = RunFlags(rawValue: 1 << 6)
    }

    public var isRunHead: Bool { flags.contains(.head) }
    public var isRunTail: Bool { flags.contains(.tail) }
}

/// Messages Discord folds into one line: "3 blocked messages — Show".
///
/// **Discord's `MESSAGE_GROUP_*`, by its own stream builder's rule.** Consecutive
/// messages folded for the same reason are one fold; a day's heading or a mark
/// between two of them starts another, because both are pushed between the
/// stream's items and a fold only ever grows from the item before it. An unread
/// line does not split one — Discord keeps it inside, and draws it above the
/// fold while the fold is shut. An AutoMod action never folds: Discord's
/// `NON_COLLAPSIBLE` is that one type.
///
/// Shut, a fold's messages are not rows at all. Open, they follow it as ordinary
/// rows on the pointer's tint, the fold's own line still above them saying Hide.
public struct CollapsedGroup: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// Somebody the reader blocked — "{count} blocked messages".
        case blocked
        /// Somebody the reader ignored — "{count} ignored messages".
        case ignored
        /// A suspended account — "Some messages removed from a suspended
        /// account." Discord gives this fold no Show.
        case suspended
    }

    public var reason: Reason
    /// Its messages, oldest first. The first is the fold's identity.
    public var messageIDs: [MessageID]
    public var isOpen: Bool

    public init(reason: Reason, messageIDs: [MessageID], isOpen: Bool) {
        self.reason = reason
        self.messageIDs = messageIDs
        self.isOpen = isOpen
    }

    public var id: MessageID { messageIDs[0] }
    public var count: Int { messageIDs.count }
    /// Whether the reader may open it — Discord's `canUncollapse`.
    public var canOpen: Bool { reason != .suspended }

    /// Why Discord folds a message, if it does — its `eg`, in its order: a
    /// suspended account's flag first, then a block, then an ignore, each
    /// tested against the author and against whoever ran the command the
    /// message answers.
    public static func reason(
        for message: Message,
        blocked: Set<UserID>,
        ignored: Set<UserID>
    ) -> Reason? {
        if message.kind == .autoModerationAction { return nil }
        if message.flags.contains(.hiddenSuspendedUser) { return .suspended }
        let invoker = message.interaction?.userID
        if blocked.contains(message.authorID) || invoker.map(blocked.contains) == true {
            return .blocked
        }
        if ignored.contains(message.authorID) || invoker.map(ignored.contains) == true {
            return .ignored
        }
        return nil
    }
}

/// A stretch of the channel marked in its transcript, above the message it
/// begins with.
///
/// **Two of Discord's, one row shape.** Its stream builder (module `247933`)
/// places a summary's divider and a conversation's header at the same point —
/// before the stretch's first message, and only when the stretch is more than
/// one message — and differs only in what the row does.
public struct TimelineMark: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The open topic — Discord's conversation header. The topic's panel
        /// goes back to it, so it is a control.
        case topic
        /// The summary the reader went to — Discord's summary divider. A label;
        /// it opens nothing.
        case summary
    }

    public var kind: Kind
    /// The topic's or the summary's own id. Two id spaces, both snowflakes, so
    /// no two marks of one transcript share one.
    public var id: UInt64
    public var title: String
    public var startMessageID: MessageID
    public var messageCount: Int

    public init(
        kind: Kind,
        id: UInt64,
        title: String,
        startMessageID: MessageID,
        messageCount: Int
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.startMessageID = startMessageID
        self.messageCount = messageCount
    }

    /// Whether this mark goes above `messageID` — **only over a stretch of more
    /// than one message**, as Discord's own stream does: a mark over a single
    /// line labels nothing.
    func starts(at messageID: MessageID) -> Bool {
        messageCount > 1 && startMessageID == messageID
    }
}

/// Turns a channel's messages into the rows a transcript draws.
///
/// Pure, `nonisolated`, and the single place run grouping is decided — so the
/// rule can be tested against a table of cases instead of against a running
/// session, and so the timeline, a search preview and a pinned-message list
/// cannot disagree about what a run is.
public enum TimelineReducer {

    /// How long a gap breaks a run.
    ///
    /// Seven minutes is Discord's own. It is longer than it sounds: a run is
    /// "the same person still talking", and someone typing a paragraph over five
    /// minutes has not stopped.
    public static let runGap: TimeInterval = 7 * 60

    /// The most messages one run may contain before it is broken anyway.
    ///
    /// Without a cap, a bot posting a hundred lines in a burst produces one run
    /// whose author line is a hundred rows above the newest message — the eye
    /// has nothing to attach the text to. The cap is generous enough that no
    /// human conversation reaches it.
    public static let maximumRunLength = 24

    /// Builds the row list.
    ///
    /// - Parameters:
    ///   - messages: Oldest first. The caller keeps them sorted; sorting here
    ///     would hide an ordering bug in the store behind a re-sort per
    ///     evaluation.
    ///   - unreadAnchor: The last id the reader has acknowledged. The divider
    ///     goes *before* the first message newer than this.
    ///   - mentionedIDs: The reader's own id and every role they hold, so a
    ///     mention test is one set lookup rather than a scan.
    ///   - hasMoreHistory: Whether to lay a skeleton runway above the first row.
    ///   - hasMoreNewer: Whether to lay one below the last — the transcript is
    ///     a window cut off from the present, and newer pages are still to come.
    ///   - marks: the stretches marked in the transcript, each above its first
    ///     message when that message is loaded — in the order they are drawn
    ///     when two begin at one message.
    ///   - sending: the reader's own messages Discord has not answered yet.
    ///   - failed: the ones it refused, or that never reached it.
    ///   - blockedUserIDs: whose messages fold as blocked — see `CollapsedGroup`.
    ///   - ignoredUserIDs: whose fold as ignored.
    ///   - openGroups: messages whose fold the reader opened, or jumped into.
    ///     A fold is open while any of its messages is here, so a jump target
    ///     opens the fold it lands in without knowing where that fold begins.
    ///   - calendar: Injected so a test can pin a time zone.
    public static func rows(
        messages: [Message],
        unreadAnchor: MessageID? = nil,
        mentionedIDs: Set<UInt64> = [],
        mentionsEveryoneCountsAsMention: Bool = true,
        hasMoreHistory: Bool = false,
        hasMoreNewer: Bool = false,
        marks: [TimelineMark] = [],
        failure: String? = nil,
        sending: Set<MessageID> = [],
        failed: Set<MessageID> = [],
        blockedUserIDs: Set<UserID> = [],
        ignoredUserIDs: Set<UserID> = [],
        openGroups: Set<MessageID> = [],
        skeletonDepth: Int = 20,
        calendar: Calendar = .current
    ) -> [TimelineItem] {
        guard !messages.isEmpty else {
            // Nothing loaded yet, and three different states look the same from
            // here. A page that FAILED says so; a channel with more history to
            // fetch is LOADING; one with neither is genuinely at its beginning.
            if let failure { return [.historyUnavailable(reason: failure)] }
            return hasMoreHistory ? [.loadingFirstPage] : [.conversationStart]
        }

        // One allocation for the whole reduction. The row count is bounded by
        // messages + one day separator per day + at most one divider + the
        // runway; reserving the common case avoids the array growing four times
        // on a 100-message page.
        var rows: [TimelineItem] = []
        rows.reserveCapacity(
            messages.count + 8
                + (hasMoreHistory ? skeletonDepth : 1)
                + (hasMoreNewer ? skeletonDepth : 0)
        )

        if hasMoreHistory {
            for index in 0..<skeletonDepth { rows.append(.historySkeleton(index: index)) }
        } else {
            rows.append(.conversationStart)
        }

        // Where the unread line goes, found once: a fold that is shut draws it
        // above itself, which is before the message that earns it is reached.
        let unreadIndex = messages.indices.first { index in
            Self.isFirstUnread(
                message: messages[index],
                previous: index > 0 ? messages[index - 1] : nil,
                anchor: unreadAnchor
            )
        }
        let folds = Self.folds(
            of: messages,
            blocked: blockedUserIDs,
            ignored: ignoredUserIDs,
            open: openGroups,
            marks: marks,
            calendar: calendar
        )

        var previous: Message?
        var previousFold: Int?
        var runLength = 0
        var dividerPlaced = false
        var lastMessageRowIndex: Int?

        for (index, message) in messages.enumerated() {
            let startsDay = previous.map {
                !calendar.isDate($0.sentAt, inSameDayAs: message.sentAt)
            } ?? true
            let isUnreadBoundary = !dividerPlaced && index == unreadIndex

            // No allocation per message: the list is one or two marks at most,
            // and a filter here would build an empty array for every message
            // of a three-hundred-message window.
            let startsMark = marks.contains { $0.starts(at: message.id) }

            let foldIndex = folds.byMessage[index]
            let fold = foldIndex.map { folds.list[$0] }
            let opensFold = fold?.start == index

            // A day change, an unread divider, a mark, a different author, a
            // system event, a reply, too long a gap, or a fold's edge all break
            // the run. Each of these puts something between the two messages,
            // and a run whose members are not adjacent is not a run.
            let breaksRun = startsDay
                || isUnreadBoundary
                || startsMark
                || foldIndex != previousFold
                || previous?.authorID != message.authorID
                || message.kind == .reply
                || message.isSystemEvent
                || previous?.isSystemEvent == true
                || runLength >= maximumRunLength
                || previous.map { message.sentAt.timeIntervalSince($0.sentAt) > runGap } ?? true

            if breaksRun, let index = lastMessageRowIndex {
                Self.setTail(in: &rows, at: index)
            }

            if startsDay {
                rows.append(.daySeparator(calendar.startOfDay(for: message.sentAt)))
            }
            // A shut fold's unread line goes above it, wherever in it the line
            // falls — Discord's `hasUnread`.
            var unreadInShutFold = false
            if opensFold, let fold, !fold.group.isOpen, let unreadIndex {
                unreadInShutFold = (fold.start...fold.end).contains(unreadIndex)
            }
            if isUnreadBoundary || (!dividerPlaced && unreadInShutFold) {
                rows.append(.unreadDivider)
                dividerPlaced = true
            }
            if startsMark {
                for mark in marks where mark.starts(at: message.id) {
                    rows.append(.marker(mark.kind, id: mark.id, title: mark.title))
                }
            }
            if opensFold, let fold {
                rows.append(.collapsedGroup(fold.group))
            }

            previous = message
            previousFold = foldIndex
            if let fold, !fold.group.isOpen {
                // Shut: the fold's line stands for it, and its messages are
                // not rows at all.
                runLength = 0
                continue
            }

            var flags: TimelineMessage.RunFlags = []
            if breaksRun { flags.insert(.head) }
            if isUnreadBoundary { flags.insert(.firstUnread) }
            if fold != nil { flags.insert(.inOpenGroup) }
            if Self.mentions(message, ids: mentionedIDs, everyoneCounts: mentionsEveryoneCountsAsMention) {
                flags.insert(.mentionsMe)
            }
            // Both sets are empty for every message but the reader's newest few,
            // so the test is two lookups into nothing.
            if sending.contains(message.id) { flags.insert(.pending) }
            if failed.contains(message.id) { flags.insert(.failed) }

            rows.append(.message(TimelineMessage(message: message, flags: flags)))
            lastMessageRowIndex = rows.count - 1
            runLength = breaksRun ? 1 : runLength + 1
        }

        // The newest message always closes its run.
        if let index = lastMessageRowIndex { Self.setTail(in: &rows, at: index) }

        if hasMoreNewer {
            for index in skeletonDepth..<(skeletonDepth * 2) {
                rows.append(.historySkeleton(index: index))
            }
        }

        return rows
    }

    /// The folds in a page, and which fold each message is in.
    struct Folds {
        struct Fold {
            var group: CollapsedGroup
            var start: Int
            var end: Int
        }
        var list: [Fold] = []
        /// Indexed like `messages`; nil for a message that does not fold.
        var byMessage: [Int?]
    }

    /// Decides every fold before a row is written: whether one is open depends
    /// on all of its messages, and its line comes before the first of them.
    ///
    /// Cheap where nobody is blocked or ignored, which is nearly everywhere —
    /// one flag test per message and no allocation beyond the index.
    static func folds(
        of messages: [Message],
        blocked: Set<UserID>,
        ignored: Set<UserID>,
        open: Set<MessageID>,
        marks: [TimelineMark],
        calendar: Calendar
    ) -> Folds {
        var folds = Folds(byMessage: Array(repeating: nil, count: messages.count))
        var previous: Message?
        for (index, message) in messages.enumerated() {
            defer { previous = message }
            guard let reason = CollapsedGroup.reason(for: message, blocked: blocked, ignored: ignored) else {
                continue
            }
            let startsDay = previous.map {
                !calendar.isDate($0.sentAt, inSameDayAs: message.sentAt)
            } ?? true
            let startsMark = marks.contains { $0.starts(at: message.id) }
            if let last = folds.list.indices.last,
               folds.list[last].end == index - 1,
               folds.list[last].group.reason == reason,
               !startsDay, !startsMark
            {
                folds.list[last].end = index
                folds.list[last].group.messageIDs.append(message.id)
            } else {
                folds.list.append(Folds.Fold(
                    group: CollapsedGroup(reason: reason, messageIDs: [message.id], isOpen: false),
                    start: index,
                    end: index
                ))
            }
            folds.byMessage[index] = folds.list.count - 1
        }
        if !open.isEmpty {
            for index in folds.list.indices where folds.list[index].group.canOpen {
                folds.list[index].group.isOpen = folds.list[index].group.messageIDs.contains(where: open.contains)
            }
        }
        return folds
    }

    /// Whether `message` is the first one the reader has not seen.
    ///
    /// Compared on the snowflake, never on a stored timestamp: ids are
    /// monotonic by minting time and a `Date` round-tripped through JSON is not
    /// guaranteed to preserve ordering within the same millisecond.
    private static func isFirstUnread(
        message: Message,
        previous: Message?,
        anchor: MessageID?
    ) -> Bool {
        guard let anchor else { return false }
        guard message.id.rawValue > anchor.rawValue else { return false }
        // The divider belongs before the first message past the anchor, so the
        // message before it must be at or below the anchor. With no previous
        // message this is the first row and the anchor is behind the loaded
        // page, which is still the boundary.
        guard let previous else { return true }
        return previous.id.rawValue <= anchor.rawValue
    }

    private static func mentions(
        _ message: Message,
        ids: Set<UInt64>,
        everyoneCounts: Bool
    ) -> Bool {
        guard !ids.isEmpty else { return false }
        if everyoneCounts, message.mentionsEveryone { return true }
        guard let payload = message.payload else { return false }
        for userID in payload.mentionedUserIDs where ids.contains(userID.rawValue) {
            return true
        }
        for roleID in payload.mentionedRoleIDs where ids.contains(roleID.rawValue) {
            return true
        }
        return false
    }

    private static func setTail(in rows: inout [TimelineItem], at index: Int) {
        guard case .message(var item) = rows[index] else { return }
        item.flags.insert(.tail)
        rows[index] = .message(item)
    }
}
