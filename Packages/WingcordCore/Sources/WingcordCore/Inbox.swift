import Foundation

/// The inbox: five lists of messages the reader has not dealt with.
///
/// **Four of the five tabs are the same shape** — a time-ordered list of
/// messages, grouped into runs by the channel they are in — and that is the
/// whole reason this file is small. `InboxGrouping.runs(of:)` is the one rule,
/// and Unreads, Mentions, Bookmarks and Reminders each hand it a differently
/// sourced list. A tab that drew its own grouping would be a fifth place for
/// "which header does this message belong under" to be decided, and the four
/// would drift.
///
/// Nothing here knows what a view is. The decisions are pure so they can be
/// tested against the capture rather than looked at.

// MARK: - The tabs

/// Which list the inbox is showing.
///
/// **The raw values are Discord's, and they are load-bearing.** The selected tab
/// is persisted in `PreloadedUserSettings.inbox.current_tab` — field 2 of the
/// settings protobuf — so a client that numbered its own tabs would write a
/// number Discord's own clients read as a different tab. Captured
/// `inbox.har`: a `PATCH /users/@me/settings-proto/1` carrying `EgQIBxAB`,
/// which is `inbox { current_tab: 7, viewed_tutorial: true }`, sent while the
/// Scheduled tab was open. 7 is `SCHEDULED` below.
public enum InboxTab: Int, Hashable, Sendable, CaseIterable, Codable {
    case mentions = 1
    case unreads = 2
    case reminders = 3
    case bookmarks = 6
    case scheduled = 7

    /// The order the tabs are drawn in, which is **not** `allCases` — that is
    /// raw-value order, and it would put Mentions before Unreads.
    public static let displayOrder: [InboxTab] = [
        .unreads, .mentions, .bookmarks, .reminders, .scheduled,
    ]

    public var title: String {
        switch self {
        case .unreads: "Unreads"
        case .mentions: "Mentions"
        case .bookmarks: "Bookmarks"
        case .reminders: "Reminders"
        case .scheduled: "Scheduled"
        }
    }

    /// The default when the account has never chosen one.
    ///
    /// Discord's `UNSPECIFIED` is 0, which is an absence rather than a tab — so
    /// an unset value resolves here rather than decoding to a case that would
    /// then have to be handled everywhere.
    public static let fallback: InboxTab = .unreads

    /// Two tabs Discord numbers that this client does not draw: `FOR_YOU` (4)
    /// is the recommendation feed and `GAME_INVITES` (5) is the activity
    /// invitations list. Neither is an inbox of the reader's own messages, and
    /// decoding a stored `4` as a tab that does not exist would leave the
    /// picker with no selection — so they resolve to `fallback` on the way in.
    public static func decoded(rawValue: Int) -> InboxTab {
        InboxTab(rawValue: rawValue) ?? .fallback
    }
}

// MARK: - Saved messages

/// A message the reader put aside, with or without a time attached.
///
/// **A bookmark and a reminder are one object and one route.** Discord's
/// `GET /users/@me/saved-messages` answers both lists at once, and the only
/// thing separating them is whether `dueAt` is set. Two routes were assumed on
/// the first read of the screenshots — the Bookmarks tab and the Reminders tab
/// look like separate surfaces — and the docs settle it: one list, partitioned
/// on one nullable field. `InboxTab.bookmarks` is `dueAt == nil`.
public struct SavedMessage: Hashable, Sendable, Identifiable {
    /// **Optional, and the absence is real.** The saved message can outlive the
    /// message it points at: somebody deletes it, or the reader loses access to
    /// the channel. Discord keeps the save and sends `message: null`, which is
    /// a row that must still be drawn — with its own remove button — or the
    /// reader has a bookmark they cannot get rid of.
    public var message: Message?
    public var saveData: SaveData

    /// Keyed on the save, never on the message: the message may be gone.
    public var id: MessageID { saveData.messageID }

    /// Whether this is a reminder rather than a plain bookmark.
    public var isReminder: Bool { saveData.dueAt != nil }

    public init(message: Message?, saveData: SaveData) {
        self.message = message
        self.saveData = saveData
    }
}

/// What Discord stores beside a saved message.
public struct SaveData: Hashable, Sendable {
    public var channelID: ChannelID
    public var messageID: MessageID
    /// Absent for a direct message, which is the one place the client cannot
    /// derive it either — see `InboxGrouping`.
    public var guildID: GuildID?
    public var savedAt: Date
    /// When the reminder is due. **Nil is what makes this a bookmark.**
    public var dueAt: Date?

    /// Discord's own one-line renderings of the saved message, sent alongside
    /// it. The docs mark all four "Unknown"; the capture never carried a
    /// populated one, so nothing here reads them and they are decoded only so
    /// that a future surface does not have to re-derive the shape. They are
    /// **not** used as a fallback when `message` is nil: a summary Discord
    /// wrote is not this app's typography, and the empty-message row says what
    /// it is instead.
    public var authorSummary: String?
    public var channelSummary: String?
    public var messageSummary: String?
    public var notes: String?

    public init(
        channelID: ChannelID,
        messageID: MessageID,
        guildID: GuildID? = nil,
        savedAt: Date,
        dueAt: Date? = nil,
        authorSummary: String? = nil,
        channelSummary: String? = nil,
        messageSummary: String? = nil,
        notes: String? = nil
    ) {
        self.channelID = channelID
        self.messageID = messageID
        self.guildID = guildID
        self.savedAt = savedAt
        self.dueAt = dueAt
        self.authorSummary = authorSummary
        self.channelSummary = channelSummary
        self.messageSummary = messageSummary
        self.notes = notes
    }
}

extension Array where Element == SavedMessage {

    /// The bookmarks, newest save first.
    ///
    /// Sorted on `savedAt` rather than on the message id: the reader's ordering
    /// question is "what did I put aside most recently", and bookmarking a
    /// two-year-old message must put it at the top rather than the bottom.
    public var bookmarks: [SavedMessage] {
        filter { !$0.isReminder }.sorted { $0.saveData.savedAt > $1.saveData.savedAt }
    }

    /// The reminders, **soonest due first** — which is the opposite direction
    /// to the bookmarks and is the point of the tab. A reminder list ordered by
    /// when it was set answers a question nobody has.
    ///
    /// A due date is non-nil for every element that survives the filter, so the
    /// force-free comparison below reads the value through `?? .distantFuture`
    /// rather than unwrapping: a reminder whose `due_at` failed to parse sorts
    /// last instead of crashing the sort.
    public var reminders: [SavedMessage] {
        filter(\.isReminder).sorted {
            ($0.saveData.dueAt ?? .distantFuture) < ($1.saveData.dueAt ?? .distantFuture)
        }
    }
}

// MARK: - Scheduled messages

/// A message the reader wrote and told Discord to send later.
///
/// **The shape here is NOT captured, and that is recorded rather than hidden.**
/// `GET /users/@me/scheduled-messages` is in `inbox.har` and answered `200 []`
/// — the route exists, it is user-scoped rather than channel-scoped, and the
/// account had nothing scheduled. docs.discord.food does not document it at
/// all. So the fields below are the ones the route must carry for the screen to
/// be drawable, named the way every neighbouring Discord route names the same
/// things, and **every one of them is optional in the decoder** — see
/// `ScheduledMessageDTO`. A field that is wrong costs a nil, not a failed page.
///
/// The tell that the guess is wrong is a Scheduled tab that stays empty while
/// the account has messages queued. Capture the route with one scheduled
/// message in it and this type takes ten minutes to correct.
public struct ScheduledMessage: Hashable, Sendable, Identifiable {
    public var id: MessageID
    public var channelID: ChannelID
    public var guildID: GuildID?
    /// What will be sent.
    public var content: String
    /// When Discord will send it.
    public var scheduledAt: Date
    /// Set when a send was attempted and refused — Discord keeps the row and
    /// marks it rather than dropping the message, so a failure the reader never
    /// sees is a message they think went out.
    public var failureReason: String?

    public init(
        id: MessageID,
        channelID: ChannelID,
        guildID: GuildID? = nil,
        content: String,
        scheduledAt: Date,
        failureReason: String? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.guildID = guildID
        self.content = content
        self.scheduledAt = scheduledAt
        self.failureReason = failureReason
    }
}

extension Array where Element == ScheduledMessage {
    /// Soonest to send first, for the reason the reminders sort that way.
    public var upcoming: [ScheduledMessage] {
        sorted { $0.scheduledAt < $1.scheduledAt }
    }
}

// MARK: - What an account may keep

/// The caps on what the inbox can hold.
///
/// **Two of these are subscription gates and one is not**, which is the
/// distinction that matters when a refusal has to be explained: a free account
/// gets one reminder and one scheduled message, and Nitro lifts both. The
/// bookmark cap is 200 for everybody, documented on the save route, and is not
/// something a subscription moves.
public enum InboxQuota {
    /// Reminders a free account may have outstanding.
    public static let freeReminders = 1
    /// Scheduled messages a free account may have queued.
    public static let freeScheduledMessages = 1
    /// **Nitro raises this to a number, not to no number.** Read off Discord's
    /// own banner: "Scheduled message limit reached. Get Nitro for 25 scheduled
    /// messages." So a subscribed account still has a ceiling, and a client that
    /// treated Nitro as unlimited would offer a 26th and be refused.
    public static let nitroScheduledMessages = 25
    /// Plain bookmarks, for every account. Discord's own number, on
    /// `PUT /users/@me/saved-messages`: "a maximum number of 200 saved messages
    /// **without a reminder**" — so a reminder does not spend a bookmark and
    /// vice versa.
    ///
    /// Discord shows free accounts a *promotional* line on the Bookmarks tab
    /// ("Save even more messages with Nitro") rather than a limit one, and it
    /// shows it beside a single saved message — so it is an advertisement, not a
    /// cap being hit. Nothing here treats it as a limit, because no number for a
    /// free account's bookmarks has ever been seen.
    public static let bookmarks = 200

    /// Whether another reminder may be set.
    ///
    /// - Parameter current: how many reminders the account already has, or
    ///   **nil when the list has not been fetched.**
    ///
    /// **Nil answers yes, and that is deliberate.** The saved list is only read
    /// when the inbox is opened, so for most of a session this client does not
    /// know the count. A gate that failed closed would hide Create Reminder on
    /// every message until somebody happened to open the flyout; failing open
    /// costs, at worst, one refusal the reader is then told about — which is
    /// the direction §5.5 says to be wrong in.
    public static func canAddReminder(current: Int?, hasNitro: Bool) -> Bool {
        guard !hasNitro else { return true }
        guard let current else { return true }
        return current < freeReminders
    }

    /// Whether another message may be queued.
    ///
    /// **Nitro is checked against its own ceiling rather than waved through**,
    /// because it has one: 25. See `nitroScheduledMessages`.
    public static func canAddScheduledMessage(current: Int?, hasNitro: Bool) -> Bool {
        guard let current else { return true }
        return current < (hasNitro ? nitroScheduledMessages : freeScheduledMessages)
    }

    /// What to tell somebody who has hit one of the two caps.
    ///
    /// Worded for the account that is reading it: a free account is told what
    /// Nitro would give, and a subscribed one is told the ceiling it reached —
    /// telling somebody who already pays to "get Nitro" is the version of this
    /// that reads as a bug.
    public static func limitMessage(for tab: InboxTab, hasNitro: Bool) -> String? {
        switch tab {
        case .reminders:
            hasNitro
                ? nil
                : "Free accounts keep one reminder at a time. Nitro raises the limit."
        case .scheduled:
            scheduledLimitMessage(hasNitro: hasNitro)
        case .unreads, .mentions, .bookmarks:
            nil
        }
    }

    /// Discord's two sentences for a full queue: the upsell a free account sees
    /// (`2o4lgw`) and the roadblock a subscribed one gets (`3AMt7r`).
    public static func scheduledLimitMessage(hasNitro: Bool) -> String {
        hasNitro
            ? "You've reached the limit of \(nitroScheduledMessages) scheduled messages. Cancel one to schedule another."
            : "Scheduled message limit reached. Get Nitro for \(nitroScheduledMessages) scheduled messages."
    }
}

// MARK: - Reminder durations

/// How long to wait before being nudged about a message.
///
/// **Offsets, resolved against a clock the caller passes in.** A preset that
/// captured `Date.now` at declaration would be an hour stale by the time
/// somebody opened the menu, and one that read the clock itself could not be
/// tested. Both halves matter here because the value is sent to Discord.
///
/// Discord's own list has a Custom row that opens a date picker; this does not
/// build one. The presets cover the cases a reminder is actually set for, and a
/// picker is a second surface for a route that takes the same one field — worth
/// adding, not worth guessing at.
public enum ReminderPreset: Int, Hashable, Sendable, CaseIterable, Identifiable {
    case twentyMinutes
    case oneHour
    case threeHours
    case eightHours
    case tomorrow
    case nextWeek

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .twentyMinutes: "In 20 Minutes"
        case .oneHour: "In 1 Hour"
        case .threeHours: "In 3 Hours"
        case .eightHours: "In 8 Hours"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next Week"
        }
    }

    /// When this preset falls due.
    ///
    /// **The last two go through the calendar, not through arithmetic.**
    /// "Tomorrow" as `now + 86400` is wrong on the two days a year the clocks
    /// move, and wrong by an hour for everybody in a zone that observes them —
    /// `Calendar.date(byAdding:)` keeps the wall-clock time it started from.
    /// The first four are true durations and adding seconds is exactly right
    /// for them.
    public func dueDate(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .twentyMinutes: now.addingTimeInterval(20 * 60)
        case .oneHour: now.addingTimeInterval(60 * 60)
        case .threeHours: now.addingTimeInterval(3 * 60 * 60)
        case .eightHours: now.addingTimeInterval(8 * 60 * 60)
        case .tomorrow:
            calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        case .nextWeek:
            calendar.date(byAdding: .day, value: 7, to: now)
                ?? now.addingTimeInterval(7 * 86_400)
        }
    }
}

// MARK: - Grouping

/// The one rule four of the five tabs share.
public enum InboxGrouping {

    /// Splits a time-ordered list into runs of messages that share a channel.
    ///
    /// **Run-length, not a bucket per channel**, and the difference is visible
    /// in Discord's own inbox: two mentions in `#general` an hour apart with a
    /// mention in `#offtopic` between them draw *three* headers, not two. A
    /// `Dictionary(grouping:)` would merge the first and third and silently
    /// reorder the list around them; this preserves the order it was handed and
    /// only merges neighbours.
    ///
    /// The input's order is the output's order. Whatever sorted the list —
    /// newest message first for mentions, soonest due first for reminders — is
    /// the ordering the reader sees, and this never second-guesses it.
    public static func runs(of messages: [Message]) -> [[Message]] {
        var runs: [[Message]] = []
        for message in messages {
            if var last = runs.last, last.first?.channelID == message.channelID {
                last.append(message)
                runs[runs.count - 1] = last
            } else {
                runs.append([message])
            }
        }
        return runs
    }

    /// The same rule over saved messages, keyed on the save rather than the
    /// message — a save whose message is gone still belongs under its channel's
    /// header, and reading the channel off `message` would drop it into a run
    /// of its own every time.
    public static func runs(of saved: [SavedMessage]) -> [[SavedMessage]] {
        var runs: [[SavedMessage]] = []
        for item in saved {
            if var last = runs.last,
               last.first?.saveData.channelID == item.saveData.channelID
            {
                last.append(item)
                runs[runs.count - 1] = last
            } else {
                runs.append([item])
            }
        }
        return runs
    }
}

/// The unread groups the reader folded in the inbox — Discord's
/// `collapsed_in_inbox`, kept in the account's settings so every client
/// shows the same groups folded.
public struct InboxCollapse: Hashable, Sendable {
    public var channels: Set<ChannelID>
    /// A server's scheduled-events group, which Discord files under a fixed
    /// stand-in channel id rather than a real one.
    public var guildEvents: Set<GuildID>

    public init(channels: Set<ChannelID> = [], guildEvents: Set<GuildID> = []) {
        self.channels = channels
        self.guildEvents = guildEvents
    }
}
