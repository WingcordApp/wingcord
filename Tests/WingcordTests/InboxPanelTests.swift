import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The inbox's store-side decisions: which channels the Unreads tab lists, what
/// a group's header says, and the quotas.
///
/// The grouping and sorting rules themselves are pure and live in
/// `WingcordCore`; what is tested here is everything that needs the store —
/// permissions, mutes, breadcrumbs and the Nitro gate.
@MainActor
@Suite("Inbox")
struct InboxPanelTests {

    private let readerID = UserID(rawValue: 1)
    private let guildID = GuildID(rawValue: 10)
    private let category = ChannelID(rawValue: 20)
    private let general = ChannelID(rawValue: 21)
    private let quiet = ChannelID(rawValue: 22)
    private let secret = ChannelID(rawValue: 23)
    private let older = ChannelID(rawValue: 24)
    private let dm = ChannelID(rawValue: 30)

    /// A server with four channels — one busy, one muted, one unreadable, one
    /// with older traffic — plus a conversation.
    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.users = [readerID: User(id: readerID, username: "reader")]
        // **The common case, stated**: an account on Discord's newer
        // notification settings, in a server that defaults to Only @mentions —
        // where a channel counts as unread only when somebody names the reader.
        var guild = Guild(id: guildID, name: "nice server", ownerID: readerID)
        guild.defaultMessageNotifications = .onlyMentions
        model.guilds = [guildID: guild]
        model.usesNewNotifications = true

        var index = ChannelIndex()
        index.replaceChannels(
            [
                Channel(id: category, kind: .category, guildID: guildID, name: "MAIN"),
                Channel(
                    id: general, kind: .text, guildID: guildID, name: "refill",
                    parentID: category, position: 1,
                    lastMessageID: MessageID(rawValue: 900)
                ),
                Channel(
                    id: quiet, kind: .text, guildID: guildID, name: "muted",
                    position: 2, lastMessageID: MessageID(rawValue: 901)
                ),
                Channel(
                    id: secret, kind: .text, guildID: guildID, name: "secret",
                    position: 3, lastMessageID: MessageID(rawValue: 902)
                ),
                Channel(
                    id: older, kind: .text, guildID: guildID, name: "older",
                    position: 4, lastMessageID: MessageID(rawValue: 500)
                ),
            ],
            inGuild: guildID
        )
        index.replacePrivateChannels([
            Channel(
                id: dm, kind: .directMessage, name: "",
                lastMessageID: MessageID(rawValue: 800),
                recipientIDs: [UserID(rawValue: 2)]
            ),
        ])
        model.channelIndex = index

        // The reader owns the server, so everything is readable except what the
        // gate is told to deny below.
        model.readStates = [
            general: ReadState(lastAcknowledgedID: MessageID(rawValue: 100), mentionCount: 28),
            quiet: ReadState(lastAcknowledgedID: MessageID(rawValue: 100), isMuted: true),
            secret: ReadState(lastAcknowledgedID: MessageID(rawValue: 100)),
            older: ReadState(lastAcknowledgedID: MessageID(rawValue: 100)),
            dm: ReadState(lastAcknowledgedID: MessageID(rawValue: 100)),
        ]
        return model
    }

    // MARK: What the Unreads tab lists

    /// The rule the last port left open, read out of module `455234`: a quiet
    /// channel is listed when its unread setting resolves to All Messages —
    /// its own, its category's, the server's, or, with none set, every channel
    /// of an account still on the older notification settings.
    @Test("A quiet channel set to count every message is listed")
    func quietChannelsFollowTheUnreadSetting() {
        let model = model()
        #expect(!model.unreadInboxChannels().map(\.id).contains(secret))
        model.guildUserSettings[guildID] = GuildUserSettings(
            guildID: guildID,
            channelOverrides: [
                secret: ChannelUserSettings(flags: ChannelSettingsFlags.unreadsAllMessages),
            ]
        )
        #expect(model.unreadInboxChannels().map(\.id).contains(secret))
        // The older settings count everything, everywhere.
        let legacy = self.model()
        legacy.usesNewNotifications = false
        #expect(legacy.unreadInboxChannels().map(\.id).contains(secret))
    }
    //
    // Every rule below is a line of Discord's own unread builder, read out of
    // its bundle rather than inferred — see `AppModel.consider`. Four of them
    // this client previously had backwards, and each is marked where it bites.

    @Test("Only what named the reader is listed")
    func quietChannelsAreExcluded() {
        let model = model()
        let listed = model.unreadInboxChannels().map(\.id)
        // `general` carries 28 mentions; `secret` and `older` are merely
        // unread. Listing the quiet ones is what made this tab a wall — a bot
        // filling a feed channel sat above a person asking a question.
        #expect(listed == [general])
    }

    @Test("A conversation needs a mention too")
    func conversationsNeedAMention() {
        let model = model()
        #expect(!model.unreadInboxChannels().map(\.id).contains(dm))
        // **And it leads once it has one.** A conversation ranks above every
        // server channel, so the walk's order is overridden by the rank — which
        // is the whole reason the two are separate steps.
        model.readStates[dm]?.mentionCount = 1
        #expect(model.unreadInboxChannels().map(\.id) == [dm, general])
    }

    @Test("A muted channel is dropped even when it named the reader")
    func mutedChannelsAreExcluded() {
        let model = model()
        model.notificationPreferences.mutedChannelIDs.insert(general)
        // **The mute is checked before the mention gate.** This client had the
        // opposite rule on a guess — that a mention survives a mute — and it is
        // not what Discord does.
        #expect(model.unreadInboxChannels().isEmpty)
    }

    @Test("A muted server takes its channels with it, mentions or not")
    func mutedGuildsAreExcluded() {
        let model = model()
        model.mutedGuildIDs = [guildID]
        #expect(model.unreadInboxChannels().isEmpty)
    }

    @Test("A muted category takes its channels with it")
    func mutedCategoriesAreExcluded() {
        let model = model()
        model.notificationPreferences.mutedChannelIDs.insert(category)
        // `general` is `MAIN`'s only child.
        #expect(model.unreadInboxChannels().isEmpty)
    }

    @Test("A channel the reader cannot read is not listed")
    func unreadableChannelsAreExcluded() {
        let model = model()
        model.readStates[secret]?.mentionCount = 4
        #expect(model.unreadInboxChannels().map(\.id).contains(secret))
    }

    @Test("Nothing from before the reader joined counts as unread")
    func noCursorFallsBackToTheJoinDate() {
        let model = model()
        // No cursor at all, and a server joined long after every message in it.
        model.readStates[general] = ReadState(mentionCount: 28)
        model.guilds[guildID]?.joinedAt = Date(timeIntervalSince1970: 4_000_000_000)
        // **This is the whole of "unread messages from 2021".** With no cursor
        // every message a channel ever carried is newer than nothing, so the
        // summary opened on a conversation from before the reader arrived.
        #expect(model.unreadInboxChannels().isEmpty)

        // Joined before the messages were written, and it is unread again.
        // **Before Discord's own epoch**, which also exercises the clamp: a
        // date with no snowflake must floor at zero rather than wrap, because a
        // wrapped cursor is larger than every real id and would swallow the
        // whole channel instead of none of it.
        model.guilds[guildID]?.joinedAt = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(model.unreadInboxChannels().map(\.id) == [general])
    }

    @Test("A server with no join date is skipped rather than guessed at")
    func noJoinDateMeansNoFallback() {
        let model = model()
        model.readStates[general] = ReadState(mentionCount: 28)
        model.guilds[guildID]?.joinedAt = nil
        #expect(model.unreadInboxChannels().isEmpty)
    }

    @Test("A favourited channel leads")
    func favouritesComeFirst() {
        let model = model()
        model.readStates[secret]?.mentionCount = 1
        model.pinnedChannelIDs = [secret]
        // `secret` is later in the sidebar and still leads — rank beats the
        // walk, and a favourite is rank 0.
        #expect(model.unreadInboxChannels().map(\.id) == [secret, general])
    }

    @Test("Within one rank it is the rail's order, then each server's own")
    func orderedLikeTheSidebarWithinARank() {
        let model = model()
        model.readStates[secret]?.mentionCount = 1
        model.readStates[older]?.mentionCount = 1
        // The sidebar walk: the uncategorised channels in position order, then
        // `MAIN`'s one child. `general` is position 1 and comes **last**, which
        // a flat position sort would get backwards.
        //
        // Measured off Discord's own tab with the groups collapsed: seventeen
        // rows across five servers came out grouped by server, each server's
        // rows in its channel list's order. Under any recency ordering they
        // would interleave, because servers do not take turns.
        #expect(model.unreadInboxChannels().map(\.id) == [secret, older, general])
    }

    @Test("A busier channel does not jump the queue")
    func recencyDoesNotReorderWithinARank() {
        let model = model()
        model.readStates[secret]?.mentionCount = 1
        model.readStates[older]?.mentionCount = 1
        model.channelIndex.patchLastMessage(MessageID(rawValue: 9_999), in: older)
        #expect(model.unreadInboxChannels().map(\.id) == [secret, older, general])
    }

    @Test("A fully read channel is not listed")
    func readChannelsAreExcluded() {
        let model = model()
        model.readStates[general]?.lastAcknowledgedID = MessageID(rawValue: 5_000)
        #expect(model.unreadInboxChannels().isEmpty)
    }

    @Test("Marking a group read takes it off at once")
    func acknowledgingHidesTheGroup() {
        let model = model()
        model.markInboxGroupRead(general)
        #expect(!model.unreadInboxChannels().map(\.id).contains(general))
        // Latched rather than waiting for the socket's own MESSAGE_ACK, or the
        // row sits under the cursor after it was dismissed.
        #expect(model.inbox.acknowledgedChannelIDs.contains(general))
    }

    @Test("Mark all read is offered only when it can do something")
    func markAllIsGatedOnThereBeingSomething() {
        let model = model()
        #expect(model.canMarkAllInboxRead)
        model.markAllInboxRead()
        #expect(!model.canMarkAllInboxRead)
    }

    // MARK: A server's new events

    private func event(_ id: UInt64) -> ScheduledEvent {
        ScheduledEvent(
            id: id, guildID: guildID, name: "Game night",
            startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            location: .init(entityType: 3, channelID: nil, location: "Online")
        )
    }

    /// Discord's `guild-events` row: an event past the events cursor.
    @Test("A new event puts the server's Events group in the list")
    func newEventsAreListed() throws {
        let model = model()
        model.guildEventAcks = [guildID: MessageID(rawValue: 100)]
        model.scheduledEvents = [guildID: [event(50), event(700)]]
        model.inbox.tab = .unreads
        let group = try #require(model.inboxGroups(width: 400).first { $0.eventsGuildID == guildID })
        #expect(group.name == "Events")
        // Only what came after the cursor.
        #expect(group.events.map(\.id) == [700])
    }

    @Test("Seen events, or a muted server, list nothing")
    func seenOrMutedEventsAreNot() {
        let model = model()
        model.guildEventAcks = [guildID: MessageID(rawValue: 800)]
        model.scheduledEvents = [guildID: [event(700)]]
        #expect(!model.unreadInboxEntries(firstOnly: false).contains {
            if case .events = $0 { true } else { false }
        })
        model.guildEventAcks = [:]
        model.mutedGuildIDs = [guildID]
        #expect(!model.unreadInboxEntries(firstOnly: false).contains {
            if case .events = $0 { true } else { false }
        })
    }

    @Test("Marking the Events group read moves the events cursor")
    func markingEventsRead() {
        let model = model()
        model.guildEventAcks = [guildID: MessageID(rawValue: 100)]
        model.scheduledEvents = [guildID: [event(700)]]
        model.markInboxEventsRead(guildID)
        #expect(model.guildEventAcks[guildID] == MessageID(rawValue: 700))
        #expect(model.inbox.acknowledgedEventGuildIDs.contains(guildID))
    }

    // MARK: Headers

    @Test("A channel's header names its server and its category")
    func headerCarriesTheBreadcrumb() throws {
        let model = model()
        model.inbox.tab = .unreads
        let groups = model.inboxGroups(width: 400)
        let group = try #require(groups.first { $0.channelID == general })
        #expect(group.name == "refill")
        #expect(group.breadcrumb == "nice server › MAIN")
        // A server channel shows its kind's glyph; a conversation shows a face.
        #expect(group.symbolName != nil)
    }

    @Test("A conversation has no breadcrumb and no glyph")
    func conversationHeaderIsBare() throws {
        let model = model()
        // **Mentions, not Unreads.** A conversation is not listed in Unreads at
        // all — see `unreadInboxChannels` — so the tab that can still draw one
        // is the one that groups by wherever the message was.
        model.inbox.tab = .mentions
        model.inbox.mentions = [
            Message(
                id: MessageID(rawValue: 900),
                channelID: dm,
                authorID: UserID(rawValue: 2),
                content: "hello"
            ),
        ]
        let groups = model.inboxGroups(width: 400)
        let group = try #require(groups.first { $0.channelID == dm })
        #expect(group.breadcrumb == nil)
        // A `#` in front of somebody's name reads as a channel.
        #expect(group.symbolName == nil)
    }

    @Test("A muted channel's mention count is not badged")
    func mutedMentionsAreNotCounted() {
        let model = model()
        model.readStates[general]?.isMuted = true
        model.inbox.tab = .mentions
        model.inbox.saved = []
        // The channel is muted, so even with 28 mentions on the read state the
        // header must not wear a badge — the same rule the rail follows.
        #expect(model.unreadState(of: model.channelIndex[general]!).mentions == 28)
        #expect(model.readStates[general]?.isMuted == true)
    }

    // MARK: The memo

    @Test("The groups memo answers the same value until something moves")
    func memoIsStableAndInvalidates() {
        let model = model()
        model.inbox.tab = .unreads
        let first = model.inboxGroups(width: 400)
        let second = model.inboxGroups(width: 400)
        #expect(first.map(\.id) == second.map(\.id))

        // A different width is a different layout and must not be answered from
        // the cache.
        model.readStates[secret] = nil
        model.inbox.revision &+= 1
        let third = model.inboxGroups(width: 400)
        #expect(third.count == first.count)
    }

    // MARK: Quotas

    @Test("A free account may set one reminder")
    func freeAccountsGetOneReminder() {
        let model = model()
        model.inbox.saved = []
        #expect(model.canAddReminder)
        #expect(model.inboxLimitNotice(for: .reminders) == nil)
    }

    @Test("A second reminder is refused on a free account, with a reason")
    func secondReminderIsRefused() {
        let model = model()
        model.inbox.saved = [
            SavedMessage(
                message: nil,
                saveData: SaveData(
                    channelID: general,
                    messageID: MessageID(rawValue: 5),
                    savedAt: .now,
                    dueAt: .now.addingTimeInterval(600)
                )
            ),
        ]
        #expect(!model.canAddReminder)
        #expect(model.inboxLimitNotice(for: .reminders)?.contains("Nitro") == true)
    }

    @Test("A bookmark does not spend a reminder")
    func bookmarksAndRemindersAreCountedApart() {
        let model = model()
        model.inbox.saved = [
            SavedMessage(
                message: nil,
                saveData: SaveData(
                    channelID: general,
                    messageID: MessageID(rawValue: 5),
                    savedAt: .now
                )
            ),
        ]
        #expect(model.canAddReminder)
    }

    @Test("An unfetched list never claims a limit")
    func unknownCountsFailOpen() {
        let model = model()
        // The saved list is only read when the flyout is opened. A gate that
        // failed closed would hide Create Reminder on every message until then.
        #expect(model.inbox.saved == nil)
        #expect(model.canAddReminder)
        #expect(model.inboxLimitNotice(for: .reminders) == nil)
    }

    @Test("Nitro has a ceiling on scheduled messages too")
    func nitroScheduledMessagesAreCapped() {
        // 25, read off Discord's own banner — a client that treated Nitro as
        // unlimited would offer a 26th and be refused.
        #expect(InboxQuota.canAddScheduledMessage(current: 24, hasNitro: true))
        #expect(!InboxQuota.canAddScheduledMessage(current: 25, hasNitro: true))
        #expect(!InboxQuota.canAddScheduledMessage(current: 1, hasNitro: false))
    }

    @Test("A subscriber at the ceiling is not told to buy a subscription")
    func nitroLimitMessageDoesNotSell() {
        let notice = InboxQuota.limitMessage(for: .scheduled, hasNitro: true)
        #expect(notice != nil)
        #expect(notice?.contains("Nitro") == false)
        #expect(InboxQuota.limitMessage(for: .scheduled, hasNitro: false)?.contains("Nitro") == true)
    }

    // MARK: Reminder presets

    @Test("Tomorrow goes through the calendar, not through arithmetic")
    func tomorrowKeepsItsWallClockTime() throws {
        // Adding 86,400 seconds is wrong by an hour across a daylight-saving
        // boundary; `Calendar.date(byAdding:)` keeps the time of day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 28
        components.hour = 14
        let start = try #require(calendar.date(from: components))
        let due = ReminderPreset.tomorrow.dueDate(from: start, calendar: calendar)
        #expect(calendar.component(.hour, from: due) == 14)
        #expect(calendar.component(.day, from: due) == 29)
    }

    @Test("The short presets are true durations")
    func shortPresetsAreOffsets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ReminderPreset.twentyMinutes.dueDate(from: now) == now.addingTimeInterval(1_200))
        #expect(ReminderPreset.eightHours.dueDate(from: now) == now.addingTimeInterval(28_800))
    }

    // MARK: Opening and closing

    @Test("Closing the flyout drops what it fetched but keeps the tab")
    func closingDiscardsFetchedLists() {
        let model = model()
        model.inbox.tab = .bookmarks
        model.inbox.saved = []
        model.inbox.isShown = true
        model.closeInbox()
        #expect(model.inbox.saved == nil)
        // A bookmark list from twenty minutes ago shown without a spinner is a
        // lie; the tab is the reader's own choice and survives.
        #expect(model.inbox.tab == .bookmarks)
        #expect(!model.isInboxShown)
    }

    @Test("Opening never lands on the friend-requests pane")
    func openingReturnsToTheLists() {
        let model = model()
        model.inbox.isShowingFriendRequests = true
        model.openInbox()
        // A flyout that opens onto friend requests because that is where it was
        // left is a surprise every time.
        #expect(!model.inbox.isShowingFriendRequests)
    }

    // MARK: Friend requests

    @Test("The badge counts only what is addressed to the reader")
    func badgeCountsIncomingOnly() {
        let model = model()
        model.relationships = [
            UserID(rawValue: 2): .incomingRequest,
            UserID(rawValue: 3): .outgoingRequest,
            UserID(rawValue: 4): .friend,
        ]
        #expect(model.incomingFriendRequestCount == 1)
        // Both halves are listed, though — an outgoing request is the other
        // half of the same question.
        #expect(model.friendRequests.count == 2)
        #expect(model.friendRequests.first?.isIncoming == true)
    }

    @Test("Declining clears the relationship and its facts together")
    func decliningClearsBoth() {
        let model = model()
        let requester = UserID(rawValue: 2)
        model.users[requester] = User(id: requester, username: "somebody")
        model.relationships = [requester: .incomingRequest]
        model.relationshipFacts = [requester: RelationshipFacts(since: .now, isStranger: true)]
        model.answerFriendRequest(requester, accept: false)
        #expect(model.relationships[requester] == nil)
        // Left behind, the facts would resurface with a `since` from the
        // request that was declined if the same person asked again.
        #expect(model.relationshipFacts[requester] == nil)
    }

    // MARK: Unreads loading (Alex, 2026-11-17: "open it like 4-5 times")

    /// A box the transcript filled around an older position has nothing unread
    /// in it, and must not stand in for the group's own fetch.
    @Test("Only messages past the read cursor count as an Unreads group's")
    func holdsUnreadsOnlyPastTheCursor() {
        func message(_ id: UInt64) -> Message {
            Message(id: MessageID(rawValue: id), channelID: general, authorID: readerID, content: "m")
        }
        let older = [message(100), message(200)]
        #expect(!AppModel.holdsUnreads(older, after: MessageID(rawValue: 300)))
        #expect(AppModel.holdsUnreads(older + [message(400)], after: MessageID(rawValue: 300)))
        // No cursor: any page at all is the newest the reader has.
        #expect(AppModel.holdsUnreads(older, after: nil))
        #expect(!AppModel.holdsUnreads([], after: nil))
    }
}
