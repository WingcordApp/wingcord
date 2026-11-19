import Foundation
import WingcordCore

/// What a thread's card knows beyond the message that started it: its newest
/// message and its count, kept where Discord keeps them (`ThreadMessageStore`,
/// module `456874`).
struct ThreadCardState: Equatable, Sendable {
    /// Whether Discord has said what the newest message is. With `latest` nil
    /// it means there is none left to show — the card says so in Discord's words.
    var latestKnown = false
    var latest: ThreadLatestMessage?
    var count: Int?
}

/// Thread cards in the transcript (docs/QUEUE-NOV19.md, T1–T3).
///
/// **The state is copied onto the message that started the thread**, in the
/// parent's box, rather than looked up while laying out: the row's message is
/// what its layout is cached on, so a card whose newest message changed is a
/// message that changed, and redraws without a second invalidation path.
extension AppModel {
    /// Rewrites the thread record of every message in `box` that carries a
    /// thread this model has news of. Returns whether anything changed.
    func applyThreadCards(to box: inout MessageBox) -> Bool {
        guard !threadCards.isEmpty else { return false }
        var changed = false
        for index in box.messages.indices {
            guard let thread = box.messages[index].thread,
                  let state = threadCards[thread.id]
            else { continue }
            var updated = thread
            if state.latestKnown { updated.latest = state.latest }
            if let count = state.count { updated.messageCount = count }
            guard updated != thread else { continue }
            box.messages[index].payload = box.messages[index].payload?.replacingThread(updated)
            changed = true
        }
        return changed
    }

    /// A thread's own box changed: its newest message is the card's, as
    /// Discord's store takes it from the thread's newest page.
    func noteThreadNewest(of box: MessageBox, in channelID: ChannelID) {
        guard !box.hasMoreNewer,
              let channel = channelIndex[channelID], channel.kind.isThread,
              let newest = box.messages.last(where: { ThreadLatestMessage.counts($0, inThread: channelID) })
        else { return }
        let latest = ThreadLatestMessage(newest)
        guard threadCards[channelID]?.latest != latest || threadCards[channelID]?.latestKnown != true else { return }
        updateThreadCard(channelID) { state in
            state.latestKnown = true
            state.latest = latest
        }
    }

    /// `THREAD_LIST_SYNC`: every active thread's count, and its newest message
    /// where Discord sent one.
    func receiveThreadSync(threads: [Channel], newestMessages: [Message]) {
        var parents = Set<ChannelID>()
        for thread in threads {
            guard let count = thread.threadMessageCount, threadCards[thread.id]?.count != count else { continue }
            threadCards[thread.id, default: ThreadCardState()].count = count
            if let parentID = thread.parentID { parents.insert(parentID) }
        }
        for message in newestMessages {
            let threadID = message.channelID
            guard ThreadLatestMessage.counts(message, inThread: threadID) else { continue }
            let latest = ThreadLatestMessage(message)
            guard threadCards[threadID]?.latest != latest else { continue }
            threadCards[threadID, default: ThreadCardState()].latestKnown = true
            threadCards[threadID]?.latest = latest
            if let parentID = channelIndex[threadID]?.parentID { parents.insert(parentID) }
        }
        for parentID in parents { refreshThreadCards(inParent: parentID) }
    }

    /// A message landed in a thread: one more on its count (Discord caps the
    /// count at 100,000). The newest message follows from the thread's box.
    func noteThreadMessageCreated(_ message: Message) {
        let threadID = message.channelID
        guard channelIndex[threadID]?.kind.isThread == true,
              ThreadLatestMessage.counts(message, inThread: threadID),
              let count = threadCards[threadID]?.count ?? starterThread(of: threadID)?.messageCount
        else { return }
        updateThreadCard(threadID) { state in
            state.count = min(count + 1, 100_000)
            state.latestKnown = true
            state.latest = ThreadLatestMessage(message)
        }
    }

    /// An edit to a thread's newest message changes what its card quotes.
    func noteThreadMessageUpdated(_ message: Message) {
        let threadID = message.channelID
        guard let state = threadCards[threadID], state.latest?.id == message.id else { return }
        var latest = ThreadLatestMessage(message)
        // An edit can arrive partial: keep what it left out.
        if message.content.isEmpty, let old = state.latest { latest.excerpt = old.excerpt }
        if let old = state.latest { latest.hasAttachment = latest.hasAttachment || old.hasAttachment }
        guard latest != state.latest else { return }
        updateThreadCard(threadID) { $0.latest = latest }
    }

    /// A message left a thread. Its card's newest goes with it, as Discord's
    /// does ("There are no recent messages in this thread"), and the count
    /// drops — except for the thread's own opening message, which Discord
    /// never counted.
    func noteThreadMessageDeleted(_ messageID: MessageID, in threadID: ChannelID) {
        guard channelIndex[threadID]?.kind.isThread == true else { return }
        let wasNewest = threadCards[threadID]?.latest?.id == messageID
        let counted = messageID.rawValue != threadID.rawValue
        let count = counted ? (threadCards[threadID]?.count ?? starterThread(of: threadID)?.messageCount) : nil
        guard wasNewest || count != nil else { return }
        updateThreadCard(threadID) { state in
            if wasNewest {
                state.latestKnown = true
                state.latest = nil
            }
            if let count { state.count = max(count - 1, 0) }
        }
    }

    // MARK: - Helpers

    private func updateThreadCard(_ threadID: ChannelID, _ body: (inout ThreadCardState) -> Void) {
        var state = threadCards[threadID] ?? ThreadCardState()
        body(&state)
        guard threadCards[threadID] != state else { return }
        threadCards[threadID] = state
        if let parentID = channelIndex[threadID]?.parentID { refreshThreadCards(inParent: parentID) }
    }

    /// The thread record on the message that started it, where that page is
    /// loaded.
    private func starterThread(of threadID: ChannelID) -> MessageThread? {
        guard let parentID = channelIndex[threadID]?.parentID,
              let box = messageBoxes.peek(parentID)
        else { return nil }
        return box.messages.last(where: { $0.thread?.id == threadID })?.thread
    }
}
