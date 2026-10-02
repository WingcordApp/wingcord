import Foundation
import WingcordCore
import WingcordNet

/// Which page of a channel's history the store wants.
enum HistoryRequest: Equatable, Sendable {
    /// The page above the loaded window — or, with no anchor, the newest page
    /// of a channel that has nothing loaded yet.
    case older(before: MessageID?)
    /// The page below a window cut off from the present.
    case newer(after: MessageID)
    /// The newest page, in place of a window cut off from the present.
    case present
}

/// How much of a channel's history one transcript holds, and where it is cut.
///
/// **Discord's own rule, scaled to this client's pages.** Discord keeps at most
/// 120 messages and trims back to 60 (`UNo` and `rLJ` in module `652215`, used
/// by the channel message store, `292446`) — trimming the far end from wherever
/// the reader is heading. Its pages are a screenful, ten to thirty messages;
/// this client asks for a hundred at a time, so the same shape is three pages
/// trimmed back to two.
///
/// **Trimming is what makes a transcript's cost flat.** Every inbound message
/// re-reduces and re-lays out the whole loaded window, so a window that only
/// grows is a per-message cost that grows with how far somebody has scrolled
/// and how long the channel has sat open. It is also what makes "you are
/// looking at older messages" a real state: trim the newest away and the
/// transcript is cut off from the present until it pages back or jumps.
nonisolated enum TranscriptWindow {
    /// The most messages a transcript holds before a page trims it.
    static let limit = 3 * DiscordREST.historyPageSize
    /// What a trim leaves.
    static let keep = 2 * DiscordREST.historyPageSize
    /// The most live messages held aside while cut off from the present.
    ///
    /// **Only the race needs these.** A newer page carries everything the
    /// server had when it answered; what it cannot carry is a message that
    /// arrived between that answer and this client applying it. The newest
    /// page's worth covers that window many times over — anything older than
    /// the oldest held message is on the pages still to come.
    static let heldLimit = DiscordREST.historyPageSize

    /// Whether a page fetched `around` a message still has history past
    /// either end of it.
    ///
    /// **Discord's own arithmetic** (module `148494`, `fetchMessages`): the
    /// target's place among the page — counted whether or not the target came
    /// back, since a deleted one still has a place — decides both edges. Fewer
    /// than half the limit before it means the channel starts inside the page;
    /// fewer than half from it onward means the page reaches the present, and
    /// so does a page whose newest message is the channel's newest.
    ///
    /// - Parameter ids: the page, oldest first.
    /// - Parameter wireCount: how many messages Discord sent, including any
    ///   that could not be read — Discord's own arithmetic counts the page it
    ///   received. Defaults to the page itself.
    static func edges(
        ofAround ids: [MessageID],
        wireCount: Int? = nil,
        target: MessageID,
        limit: Int,
        newestInChannel: MessageID?
    ) -> (older: Bool, newer: Bool) {
        let half = limit / 2
        let upper = half + limit % 2
        let index = ids.firstIndex { $0.rawValue >= target.rawValue } ?? ids.count
        let older = index >= upper - 1
        var newer = max(wireCount ?? ids.count, ids.count) - index >= half
        if newer, let newest = ids.last, newest == newestInChannel { newer = false }
        return (older, newer)
    }
}

extension MessageBox {

    /// A page from above the window.
    ///
    /// - Returns: false when the page was dropped because the window moved
    ///   while it was in flight — a jump, or a return to the present, replaced
    ///   it. Landing it anyway would splice a stranger's history onto the new
    ///   window with a silent gap between them.
    /// - Parameter wireCount: how many messages Discord sent — see
    ///   `MessagePage.wireCount`. A page is short by what Discord sent, never
    ///   by what could be read.
    @discardableResult
    mutating func receiveOlder(
        _ page: [Message],
        wireCount: Int? = nil,
        before anchor: MessageID?
    ) -> Bool {
        // No anchor is a channel's first page — the newest — which lands in
        // whatever the gateway has put there since, newer than all of it. **Not
        // into a window a jump has cut off from the present**, though: a link
        // opened with the channel races its first page, and the newest hundred
        // landing after a page from last year would be the gap this guards.
        let fits = if let anchor { anchor == messages.first?.id } else { !hasMoreNewer }
        guard fits else { return false }
        for message in page { upsert(message) }
        hasMoreHistory = (wireCount ?? page.count) >= DiscordREST.historyPageSize
        if messages.count > TranscriptWindow.limit {
            // The reader is at the top — that is what asked for this page — so
            // the newest go, and with them the present.
            messages.removeLast(messages.count - TranscriptWindow.keep)
            hasMoreNewer = true
        }
        return true
    }

    /// A page from below a window cut off from the present.
    ///
    /// - Returns: false when it was dropped, for `receiveOlder`'s reason.
    @discardableResult
    mutating func receiveNewer(
        _ page: [Message],
        wireCount: Int? = nil,
        after anchor: MessageID
    ) -> Bool {
        guard hasMoreNewer, anchor == messages.last?.id else { return false }
        for message in page { upsert(message) }
        // A short page is the only signal the present has been reached — the
        // rule `hasMoreHistory` already follows in the other direction.
        if (wireCount ?? page.count) < DiscordREST.historyPageSize { reachPresent() }
        if messages.count > TranscriptWindow.limit {
            messages.removeFirst(messages.count - TranscriptWindow.keep)
            hasMoreHistory = true
        }
        return true
    }

    /// The newest page, in place of whatever window was loaded.
    mutating func receivePresent(_ page: [Message], wireCount: Int? = nil) {
        messages = page
        hasMoreHistory = (wireCount ?? page.count) >= DiscordREST.historyPageSize
        reachPresent()
    }

    /// A page fetched around one message, in place of whatever was loaded.
    ///
    /// **Replaced, not merged.** A page from a year ago and the newest page are
    /// two disjoint runs; keeping both would put a silent gap in the middle of
    /// the transcript with nothing to say it is there.
    mutating func receiveAround(_ page: [Message], edges: (older: Bool, newer: Bool)) {
        messages = page
        hasMoreHistory = edges.older
        if edges.newer {
            hasMoreNewer = true
            newerPageFailed = false
            // Whatever was held belonged to the window this replaces; the
            // pages between here and the present carry it again.
            heldLive.removeAll()
        } else {
            reachPresent()
        }
    }

    /// A message the gateway delivered, or the reader's own send landing.
    ///
    /// - Parameter trimming: whether the oldest may go once the window is
    ///   full — true only when nobody looking at this channel is scrolled away
    ///   from its foot, so what goes is far above everyone.
    mutating func receiveLive(_ message: Message, trimming: Bool) {
        // **Discord's answer to one of the reader's sends retires its echo**,
        // whichever arrives first — the reply to the POST or the socket's
        // copy — and before the window decides whether to hold it, because a
        // held message is still an answered one.
        if !outbox.isEmpty, let nonce = message.payload?.nonce {
            outbox.removeAll { $0.nonce == nonce }
        }
        guard !hasMoreNewer else {
            // Appending here would put today's message straight after last
            // year's with nothing between them.
            if heldLive.count >= TranscriptWindow.heldLimit { heldLive.removeFirst() }
            heldLive.append(message)
            return
        }
        upsert(message)
        if trimming, messages.count > TranscriptWindow.limit {
            messages.removeFirst(messages.count - TranscriptWindow.keep)
            hasMoreHistory = true
        }
    }

    /// The window reaches the present again: the held messages go in behind
    /// it, and nothing is held any more.
    ///
    /// **A held message never overwrites one already loaded.** The page that
    /// reconnected carries the server's copy, which has any edit made since;
    /// the held copy is the one that arrived before it.
    private mutating func reachPresent() {
        hasMoreNewer = false
        newerPageFailed = false
        newerPageFailures = 0
        for message in heldLive where !contains(message.id) { upsert(message) }
        heldLive.removeAll()
    }

    /// Binary search: the array is kept sorted by id.
    private func contains(_ id: MessageID) -> Bool {
        var low = 0
        var high = messages.count
        while low < high {
            let mid = (low + high) / 2
            if messages[mid].id.rawValue < id.rawValue { low = mid + 1 } else { high = mid }
        }
        return low < messages.count && messages[low].id == id
    }
}
