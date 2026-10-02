import Foundation
import WingcordCore
import WingcordNet

// MARK: - The wire side of the inbox
//
// Same pattern as every other controller file here: the store has already
// written the optimistic answer, this sends it, and a refusal puts the store
// back exactly as it was.
//
// **Unreads is absent on purpose.** It has no route — it is derived from read
// states the client already holds — so the only fetching it needs is the
// message *bodies* of a group the reader has scrolled to, which is
// `loadUnreadGroup` at the bottom.

extension SessionController {

    /// How many unread groups may be fetching their messages at once.
    ///
    /// Three, because roughly that many groups fit in the flyout at its tallest
    /// and the reader cannot be reading a fourth. Higher spends the rate-limit
    /// bucket on rows nobody has scrolled to; lower makes scrolling feel like it
    /// is waiting.
    static let concurrentUnreadFetches = 3

    /// Fetches one tab's list.
    ///
    /// The "ask once" decision is the store's (`AppModel.loadInboxTab`); this
    /// only guards against two requests for the same list being in flight at
    /// once, which is a different race — a retry pressed while the first is
    /// still running.
    func loadInbox(_ tab: InboxTab) {
        switch tab {
        case .unreads:
            // Nothing to fetch. The groups are already derivable.
            return
        case .mentions:
            loadMentions()
        case .bookmarks, .reminders:
            // **One fetch for two tabs.** Whichever the reader opened, the
            // route answers both lists, so the flag is `.bookmarks` for both
            // and flipping between them never asks again.
            loadSavedMessages()
        case .scheduled:
            loadScheduledMessages()
        }
    }

    private func loadMentions() {
        guard model.inbox.loading.insert(.mentions).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.inbox.loading.remove(.mentions) }
            do {
                let page = try await rest.recentMentions()
                // **The authors come with the page and have to.** A mention
                // from six days ago in a server whose roster was never chunked
                // is written by somebody no table here carries, and without
                // them every row reads "Unknown" over a grey circle.
                model.users.merge(page.authors) { existing, new in new.merged(over: existing) }
                // The threads too: a mention inside a thread resolves to
                // nothing without its channel, and the header would say
                // "Unknown channel" for a room the reader is a member of.
                for thread in page.threads { model.channelIndex.upsert(thread) }
                model.inbox.mentions = page.messages
                model.inbox.dismissedMentionIDs = []
                model.inbox.failures[.mentions] = nil
                model.inbox.revision &+= 1
                model.identityRevision &+= 1
            } catch {
                Self.trace("inbox mentions failed: \(Self.describe(error))")
                model.inbox.failures[.mentions] = Self.describe(error)
                model.inbox.revision &+= 1
            }
        }
    }

    private func loadSavedMessages() {
        guard model.inbox.loading.insert(.bookmarks).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.inbox.loading.remove(.bookmarks) }
            do {
                let (saved, authors) = try await rest.savedMessages()
                model.users.merge(authors) { existing, new in new.merged(over: existing) }
                model.inbox.saved = saved
                // **The account's answer, not this session's.** `bookmarkedMessageIDs`
                // existed only so the message menu could say Remove Bookmark on
                // something bookmarked in this run; this is the first time the
                // real list has ever been read, and it replaces the guess.
                model.bookmarkedMessageIDs = Set(saved.map(\.id))
                model.inbox.failures[.bookmarks] = nil
                model.inbox.failures[.reminders] = nil
                model.inbox.revision &+= 1
                model.messageContentRevision &+= 1
            } catch {
                Self.trace("inbox saved failed: \(Self.describe(error))")
                let reason = Self.describe(error)
                // Both tabs, because both were waiting on this one request.
                model.inbox.failures[.bookmarks] = reason
                model.inbox.failures[.reminders] = reason
                model.inbox.revision &+= 1
            }
        }
    }

    private func loadScheduledMessages() {
        guard model.inbox.loading.insert(.scheduled).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { model.inbox.loading.remove(.scheduled) }
            do {
                model.inbox.scheduled = try await rest.scheduledMessages()
                model.inbox.failures[.scheduled] = nil
                model.inbox.revision &+= 1
            } catch {
                Self.trace("inbox scheduled failed: \(Self.describe(error))")
                model.inbox.failures[.scheduled] = Self.describe(error)
                model.inbox.revision &+= 1
            }
        }
    }

    // MARK: Acting

    /// Acknowledges one mention.
    func dismissMention(_ messageID: MessageID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.deleteRecentMention(messageID)
            } catch {
                Self.trace("dismiss mention \(messageID) failed: \(Self.describe(error))")
                model.revertMentionDismissal(messageID)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Marks many channels read at once.
    ///
    /// **Put back on a refusal.** The rows go the moment the reader asks — the
    /// read states themselves move on the socket's `MESSAGE_ACK`, which is what
    /// every other surface reads — but a list that says "all read" while
    /// Discord changed nothing is the one answer worse than a slow one, and it
    /// is exactly what the reader saw.
    func acknowledgeAll(_ updates: [ReadStateUpdate]) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.bulkAcknowledge(updates)
            } catch {
                Self.trace("inbox mark-all-read failed: \(Self.describe(error))")
                model.revertInboxAcknowledgement(of: updates.map(\.channelID))
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Takes a bookmark or reminder off, from the inbox rather than the menu.
    func unsaveMessage(_ messageID: MessageID, in channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.inbox.savesInFlight.remove(messageID) }
            do {
                try await rest.unsaveMessage(messageID, in: channelID)
            } catch {
                Self.trace("unsave \(messageID) failed: \(Self.describe(error))")
                // Refetched rather than reinserted: the row's position in the
                // list is decided by `saved_at`, and rebuilding that here would
                // be a second copy of the ordering rule.
                model.inbox.saved = nil
                model.loadInboxTab(.bookmarks)
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Sends a queued message now.
    ///
    /// **The reply is the sent message, not the scheduled row** — see
    /// `sendScheduledMessageNow`. There is nothing left to refetch on success,
    /// so the row the store already removed stays removed and the message is
    /// filed into its channel if that transcript is resident. If it is not,
    /// the gateway's own `MESSAGE_CREATE` puts it there when the reader opens
    /// the channel; a fetch here would be a page nobody is looking at.
    func sendScheduledMessageNow(_ id: MessageID) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.inbox.savesInFlight.remove(id) }
            do {
                guard let sent = try await rest.sendScheduledMessageNow(id) else { return }
                if model.messages(in: sent.channelID)?.messages.isEmpty == false {
                    let trims = model.mayTrimOldest(in: sent.channelID)
                    model.mutateBox(sent.channelID) { $0.receiveLive(sent, trimming: trims) }
                }
                model.messageContentRevision &+= 1
                model.reportScheduling("Message sent.")
            } catch {
                Self.trace("send scheduled \(id) now failed: \(Self.describe(error))")
                model.inbox.scheduled = nil
                model.loadInboxTab(.scheduled)
                model.reportActionFailure("Failed to send scheduled message. \(Self.describe(error))")
            }
        }
    }

    /// Rewrites what a queued message will say.
    func editScheduledMessage(_ id: MessageID, content: String) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.inbox.savesInFlight.remove(id) }
            do {
                guard let updated = try await rest.editScheduledMessage(id, content: content)
                else { return }
                model.applyScheduledMessage(updated)
                model.reportScheduling("Scheduled message updated")
            } catch {
                Self.trace("edit scheduled \(id) failed: \(Self.describe(error))")
                model.inbox.scheduled = nil
                model.loadInboxTab(.scheduled)
                model.reportActionFailure("Failed to update message. \(Self.describe(error))")
            }
        }
    }

    /// Moves when a queued message will be sent.
    func rescheduleMessage(_ id: MessageID, to date: Date) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.inbox.savesInFlight.remove(id) }
            do {
                guard let updated = try await rest.rescheduleMessage(id, to: date) else { return }
                model.applyScheduledMessage(updated)
                model.reportScheduling("Scheduled message updated")
            } catch {
                Self.trace("reschedule \(id) failed: \(Self.describe(error))")
                model.inbox.scheduled = nil
                model.loadInboxTab(.scheduled)
                model.reportActionFailure("Failed to update message. \(Self.describe(error))")
            }
        }
    }

    func cancelScheduledMessage(_ id: MessageID) {
        Task { [weak self] in
            guard let self else { return }
            defer { model.inbox.savesInFlight.remove(id) }
            do {
                try await rest.deleteScheduledMessage(id)
                model.reportScheduling("Successfully canceled the message.")
            } catch {
                Self.trace("cancel scheduled \(id) failed: \(Self.describe(error))")
                model.inbox.scheduled = nil
                model.loadInboxTab(.scheduled)
                model.reportActionFailure("Failed to cancel scheduled message. \(Self.describe(error))")
            }
        }
    }

    /// Remembers the selected tab on the account.
    ///
    /// **Failure is swallowed deliberately.** The worst case is an inbox that
    /// opens on the wrong tab next launch; a banner about a preference that did
    /// not save is noise about something nobody asked for.
    func writeInboxTab(_ tab: InboxTab) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setInboxTab(tab)
            } catch {
                Self.trace("inbox tab write failed: \(Self.describe(error))")
            }
        }
    }

    // MARK: Unread bodies

    /// Fetches the messages behind one unread group, when the row appears.
    ///
    /// **Per group, on demand, and never up front.** The Unreads tab derives
    /// its headers for free; fetching every unread channel's messages on open
    /// would be one request per channel — sixty on a busy account, through one
    /// rate-limit bucket. This is the same `?around=` history fetch the
    /// transcript makes, so a channel the reader then opens is already loaded.
    ///
    /// Silent on failure: the group keeps its header and shows nothing under
    /// it, which is what a channel the reader cannot fetch should look like.
    func loadUnreadGroup(_ channelID: ChannelID) {
        // Already loaded, either here or by the transcript. `hasMoreHistory` is
        // not consulted — any page at all is enough for a summary.
        guard model.inbox.unreadBodies[channelID] == nil,
              model.messages(in: channelID)?.messages.isEmpty != false
        else { return }
        // **A ceiling on how many run at once, and it is what stops the storm.**
        // `LazyVStack` materialises rows ahead of the viewport, so on an account
        // with sixty unread channels a dozen groups can appear in one pass and
        // ask together — a dozen history pages through one rate-limit bucket,
        // each landing and invalidating the list. Past the cap a group simply
        // draws its header with nothing under it and asks again the next time it
        // appears, which is what scrolling to it does.
        guard unreadGroupFetches.count < Self.concurrentUnreadFetches else { return }
        guard unreadGroupFetches.insert(channelID).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { unreadGroupFetches.remove(channelID) }
            do {
                // **Anchored on the last acknowledged message, not on the
                // newest.** `around:` centres the page, so anchoring at the
                // newest message spends half the page on messages the reader
                // has already read. Anchored at the cursor, the unread half is
                // what comes back.
                // **With a cursor, the page is centred on it; without one,
                // it is the newest page.**
                //
                // Discord sends `around=0` for a channel with no cursor and
                // this client did too, which is right for the short channels
                // the capture happens to contain — a five-message channel
                // answers with all five either way. It is wrong for a channel
                // with years in it: `around=0` is the channel's *beginning*,
                // so an account that had never opened a busy server got its
                // founding conversation instead of this week's.
                //
                // Omitting the parameter asks for the newest page, which is
                // the only page worth summarising when the reader has no
                // position at all. A deliberate deviation from the captured
                // request, and the reason is that the capture cannot show what
                // Discord *draws* from what it asked for.
                // Discord's own request: thirty around the cursor the list
                // itself uses — the read position, or the day the reader
                // joined — so the group opens on the first unread line.
                let anchor = model.channelIndex[channelID].flatMap {
                    model.unreadCursor(of: $0, inGuild: $0.guildID)
                }
                let page = try await rest.messages(in: channelID, around: anchor, limit: 30)
                model.users.merge(page.authors) { existing, new in new.merged(over: existing) }
                for thread in page.threads { model.channelIndex.upsert(thread) }
                // **The inbox's own table, never a message box.** A box is the
                // transcript's and is capped at three resident channels, so
                // writing here evicted the group loaded three rows ago — see
                // `InboxState.unreadBodies`.
                model.inbox.unreadBodies[channelID] = page.messages
                model.inbox.revision &+= 1
            } catch {
                Self.trace("inbox unread \(channelID) failed: \(Self.describe(error))")
            }
        }
    }
}
