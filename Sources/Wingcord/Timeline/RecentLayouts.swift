import WingcordCore

/// The layouts of the conversations a transcript most recently left, newest
/// last, so going back to one is a cache hit instead of a layout of every row
/// (Alex, 2026-10-15) — the back-and-forth between two conversations, and one
/// more.
///
/// **Each is only good at the width it was laid out at**, and every entry in it
/// still checks itself against its message (`CacheEntry.matches`), so a
/// conversation that moved on while it was away relays only what moved.
nonisolated struct RecentLayouts<Cache: Collection> {
    struct Kept {
        var channelID: ChannelID
        var width: Int
        var cache: Cache
    }

    private(set) var kept: [Kept] = []
    var limit = 2

    /// Puts the conversation being left aside with its layouts and hands back
    /// the arriving one's, if they were kept at this width.
    mutating func swap(leaving: ChannelID?, cache: Cache, arriving: ChannelID, width: Int) -> Cache? {
        kept.removeAll { $0.channelID == leaving || $0.channelID == arriving && $0.width != width }
        let back = kept.firstIndex { $0.channelID == arriving }.map { kept.remove(at: $0).cache }
        if let leaving, !cache.isEmpty {
            kept.append(Kept(channelID: leaving, width: width, cache: cache))
            if kept.count > limit { kept.removeFirst(kept.count - limit) }
        }
        return back
    }

    mutating func removeAll() {
        kept.removeAll()
    }
}
