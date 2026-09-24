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
    }

    public var isRunHead: Bool { flags.contains(.head) }
    public var isRunTail: Bool { flags.contains(.tail) }
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

        var previous: Message?
        var runLength = 0
        var dividerPlaced = false
        // The index in `rows` of the run head currently open, so its tail flag
        // can be set when the run closes. Nil while no run is open.
        var openHeadIndex: Int?
        var lastMessageRowIndex: Int?

        for message in messages {
            let startsDay = previous.map {
                !calendar.isDate($0.sentAt, inSameDayAs: message.sentAt)
            } ?? true

            let isUnreadBoundary = !dividerPlaced && Self.isFirstUnread(
                message: message,
                previous: previous,
                anchor: unreadAnchor
            )

            // No allocation per message: the list is one or two marks at most,
            // and a filter here would build an empty array for every message
            // of a three-hundred-message window.
            let startsMark = marks.contains { $0.starts(at: message.id) }

            // A day change, an unread divider, a mark, a different author, a
            // system event, a reply, or too long a gap all break the run. Each
            // of these puts something between the two messages, and a run whose
            // members are not adjacent is not a run.
            let breaksRun = startsDay
                || isUnreadBoundary
                || startsMark
                || previous?.authorID != message.authorID
                || message.kind == .reply
                || message.isSystemEvent
                || previous?.isSystemEvent == true
                || runLength >= maximumRunLength
                || previous.map { message.sentAt.timeIntervalSince($0.sentAt) > runGap } ?? true

            if breaksRun, let index = lastMessageRowIndex {
                Self.setTail(in: &rows, at: index)
                openHeadIndex = nil
            }

            if startsDay {
                rows.append(.daySeparator(calendar.startOfDay(for: message.sentAt)))
            }
            if isUnreadBoundary {
                rows.append(.unreadDivider)
                dividerPlaced = true
            }
            if startsMark {
                for mark in marks where mark.starts(at: message.id) {
                    rows.append(.marker(mark.kind, id: mark.id, title: mark.title))
                }
            }

            var flags: TimelineMessage.RunFlags = []
            if breaksRun { flags.insert(.head) }
            if isUnreadBoundary { flags.insert(.firstUnread) }
            if Self.mentions(message, ids: mentionedIDs, everyoneCounts: mentionsEveryoneCountsAsMention) {
                flags.insert(.mentionsMe)
            }

            rows.append(.message(TimelineMessage(message: message, flags: flags)))
            lastMessageRowIndex = rows.count - 1
            if breaksRun {
                openHeadIndex = rows.count - 1
                runLength = 1
            } else {
                runLength += 1
            }
            previous = message
        }

        // The newest message always closes its run.
        if let index = lastMessageRowIndex { Self.setTail(in: &rows, at: index) }
        _ = openHeadIndex

        if hasMoreNewer {
            for index in skeletonDepth..<(skeletonDepth * 2) {
                rows.append(.historySkeleton(index: index))
            }
        }

        return rows
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
