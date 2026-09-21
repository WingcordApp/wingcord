import Foundation
import WingcordCore

/// Everything the inbox holds, in one value.
///
/// **A struct on the store rather than a dozen properties beside each other.**
/// The inbox is opened a few times a session and closed again; keeping its
/// state in one place means the tables it caches are one allocation to drop
/// when the flyout closes, and it keeps sixteen names out of `AppModel`'s own
/// surface. It is also the honest shape: none of these fields means anything
/// without the others.
///
/// **`nil` means "not asked" and `[]` means "asked, and there is nothing".**
/// The distinction is what stops every open re-fetching the three routes for an
/// account that genuinely has no bookmarks — the trap the pins pane already
/// paid for once.
struct InboxState {
    var isShown = false
    /// Which list is on screen.
    ///
    /// Seeded from the account's settings proto at launch and written back when
    /// it changes, so the tab follows the reader between clients.
    var tab: InboxTab = .fallback
    /// The friend-requests pane, which is a sixth surface behind the same
    /// flyout rather than a sixth tab.
    ///
    /// **Not an `InboxTab`.** Discord's own enum has no value for it and the
    /// settings proto could not carry it, so making it one would mean either
    /// inventing a raw value that collides with a tab Discord adds later, or
    /// special-casing it at every write. It is a mode the flyout is in.
    var isShowingFriendRequests = false

    /// The past seven days of mentions, newest first, exactly as the route
    /// sends them.
    var mentions: [Message]?
    /// Bookmarks and reminders together — **one route answers both**, and the
    /// two tabs are `bookmarks` and `reminders` over this one array.
    var saved: [SavedMessage]?
    var scheduled: [ScheduledMessage]?

    /// The messages behind each unread group, **kept out of `messageBoxes` on
    /// purpose.**
    ///
    /// This used to be written into the transcript's own boxes, and that is a
    /// three-slot LRU (`AppModel.residentChannelLimit`). So the fourth unread
    /// group to load evicted the first, the fifth evicted the second, and a
    /// list of ten unread channels could never show more than three populated
    /// at once — scrolling back up found the earlier ones empty, asked for them
    /// again, and evicted the ones below. A refetch storm through one
    /// rate-limit bucket, and a tab that reads as though it cannot fetch
    /// anything.
    ///
    /// The transcript's cap exists because a transcript is hundreds of messages
    /// and three of them is a real ceiling. This is twelve messages a channel
    /// for the groups the reader actually scrolled to, it is dropped whole when
    /// the flyout closes, and it belongs to the inbox the same way `mentions`
    /// and `saved` do.
    var unreadBodies: [ChannelID: [Message]] = [:]

    /// Which lists are in flight, so a second open does not ask again.
    var loading: Set<InboxTab> = []
    /// The last refusal per list, in the reader's words.
    var failures: [InboxTab: String] = [:]

    /// Mentions the reader dismissed, before the route has answered.
    ///
    /// **Held separately from `mentions` rather than removed from it**, so a
    /// refusal can put the row back without having to remember where it was.
    /// Cleared whenever the list is refetched, which is also when the server's
    /// answer becomes authoritative.
    var dismissedMentionIDs: Set<MessageID> = []
    /// Channels the reader marked read from the inbox, held for the same reason
    /// and cleared on the same beat. Without it the group stays on screen until
    /// the socket's `MESSAGE_ACK` lands, which reads as the button having missed.
    var acknowledgedChannelIDs: Set<ChannelID> = []
    /// Saves being written, so a double click sends one request.
    var savesInFlight: Set<MessageID> = []

    /// Moves when something the lists draw has changed. The flyout's card memo
    /// is keyed on it — see `AppModel.inboxCards`.
    var revision: UInt64 = 0

    /// Whether this list has been fetched at all.
    func hasLoaded(_ tab: InboxTab) -> Bool {
        switch tab {
        case .mentions: mentions != nil
        case .bookmarks, .reminders: saved != nil
        case .scheduled: scheduled != nil
        // Unreads has no route: it is derived from read states the client
        // already holds, so it is always "loaded".
        case .unreads: true
        }
    }

    /// Drops everything fetched, keeping what the reader chose.
    ///
    /// Called when the flyout closes. **The tab and the pane survive**; the
    /// tables do not, because a bookmark list from twenty minutes ago shown
    /// without a spinner is a lie, and re-fetching three small routes on open
    /// costs less than the memory of holding them all session.
    mutating func discardFetched() {
        mentions = nil
        saved = nil
        scheduled = nil
        unreadBodies = [:]
        loading = []
        failures = [:]
        dismissedMentionIDs = []
        acknowledgedChannelIDs = []
        revision &+= 1
    }
}

/// One header and the messages under it.
///
/// The unit every tab draws, whatever filled it: a run of mentions in one
/// channel, a channel's unread messages, a group of bookmarks. `InboxGrouping`
/// decides the runs; this is what they are resolved into.
struct InboxGroup: Identifiable {
    /// The channel plus the first row in the run — **not the channel alone.**
    /// One channel can legitimately appear twice in a list, with another
    /// channel's row between them, and a channel-keyed identity would make
    /// SwiftUI treat the second run as the first one moving.
    var id: InboxGroupID
    var channelID: ChannelID
    /// What the header calls it: `refill`, or the other person's name.
    var name: String
    /// The channel-kind glyph. Nil for a conversation, which shows a face.
    var symbolName: String?
    /// `nice server › nicealts.com` — the server, then the category. Nil for a
    /// direct message, which has no server to name and no category to be in.
    var breadcrumb: String?
    /// The server's icon, or the other person's face.
    var iconURL: URL?
    /// Drawn when there is no icon. A server's initials, or the person's.
    var monogram: String
    /// Unread mentions in this channel, for the header's badge. Zero draws none.
    var mentionCount: Int
    /// Whether the reader can be sent to this channel by clicking the header.
    /// False for a channel that has gone — a bookmark outlives its channel.
    var canOpen: Bool
    var rows: [InboxRow]
}

/// A group's identity: the channel, and which run of it this is.
///
/// **`occurrence`, not the first message's id — and that was a bug with teeth.**
/// Keyed on the lead message, a group's identity *changed the moment its
/// messages arrived*: SwiftUI saw a different row, threw the view away, built a
/// new one, and re-ran its `.task` — which asked for the messages again. Every
/// group in the list churned on every fetch that completed, which is what "it
/// starts to load all the messages and glitches out" was.
///
/// The occurrence is the index of this run among runs for the same channel, so
/// two separated runs of `#general` still differ while neither moves when its
/// content fills in.
struct InboxGroupID: Hashable {
    var channelID: ChannelID
    var occurrence: Int
}

/// One drawn row inside a group.
struct InboxRow: Identifiable {
    var id: MessageID
    /// The laid-out message. **Nil only for a saved message whose message is
    /// gone** — deleted, or in a channel the account lost. The row is still
    /// drawn, because it is the only place the reader can remove the save.
    var card: MessageCard?
    var channelID: ChannelID
    /// When a reminder is due, for the one tab that shows it.
    var dueAt: Date?
    /// When a scheduled message will be sent.
    var scheduledAt: Date?
    /// What a scheduled message will say, when there is no message object to
    /// lay out — a queued message does not exist yet, so there is nothing for
    /// the transcript's own renderer to draw.
    var draft: String?
    /// Why a scheduled send failed, when it did.
    var failureReason: String?
}
