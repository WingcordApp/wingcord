import Foundation

/// Discord's frecency (`283047`) as the emoji and sticker stores run it: a
/// bonus of 100 (a factor of one), ten samples, and each use weighed by its
/// age in whole days — 100 within three, 70 within fifteen, 50 within thirty,
/// 30 within forty-five, 10 within eighty, 1 after. Frecency is ⌈total uses ×
/// score ÷ samples kept⌉; an entry whose uses all weigh nothing is dropped.
///
/// The soundboard's table is the same arithmetic with a cut-off date of its
/// own — `SoundFrecency` — and this one has none.
///
/// **Recomputed from the uses, never trusted from the wire**: Discord marks
/// every loaded entry stale and scores it again.
public struct ExpressionFrecency: Hashable, Sendable {
    public typealias Use = SoundFrecency.Use

    /// By Discord's key: a custom emoji's id or a Unicode emoji's base name; a
    /// sticker's id.
    public private(set) var history: [String: Use]

    public static let maxSamples = 10
    /// What goes back on the wire: the hundred used most recently, as
    /// Discord's own write keeps (`Mr(usageHistory, 100)`).
    public static let writtenLimit = 100
    /// The emoji picker's Frequently Used — `numFrequentlyItems: 42`.
    public static let emojiShown = 42

    public init(history: [String: Use] = [:], now: Date) {
        self.history = history
        compute(now: now)
    }

    /// One use.
    public mutating func track(_ key: String, at date: Date) {
        let stamp = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var use = history[key] ?? Use(totalUses: 0, recentUses: [])
        use.totalUses += 1
        use.recentUses.append(stamp)
        use.recentUses.sort()
        if use.recentUses.count > Self.maxSamples {
            use.recentUses.removeFirst(use.recentUses.count - Self.maxSamples)
        }
        history[key] = use
        compute(now: date)
    }

    /// Discord's defaults, tracked now in order. Each is stamped a millisecond
    /// before the one after it, so among equals the first stays first — the
    /// order Discord's stable sort keeps them in.
    mutating func seed(_ keys: [String], now: Date) {
        for (offset, key) in keys.enumerated() {
            track(key, at: now.addingTimeInterval(-Double(offset) / 1000))
        }
    }

    /// Every key, highest frecency first and the most recently used first
    /// among equals. Discord takes its 42 after dropping what the reader can no
    /// longer use, so the caller filters and then takes.
    public var ranked: [String] {
        history
            .sorted { lhs, rhs in
                if lhs.value.frecency != rhs.value.frecency { return lhs.value.frecency > rhs.value.frecency }
                if lhs.value.lastUse != rhs.value.lastUse { return lhs.value.lastUse > rhs.value.lastUse }
                return lhs.key < rhs.key
            }
            .map(\.key)
    }

    public var written: [String: Use] {
        guard history.count > Self.writtenLimit else { return history }
        let kept = history.sorted { $0.value.lastUse > $1.value.lastUse }.prefix(Self.writtenLimit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private mutating func compute(now: Date) {
        for (key, var use) in history {
            var score = 0
            for stamp in use.recentUses.prefix(Self.maxSamples) {
                score += Self.weight(Self.wholeDays(from: Date(timeIntervalSince1970: Double(stamp) / 1000), to: now))
            }
            guard score > 0, !use.recentUses.isEmpty else {
                history[key] = nil
                continue
            }
            use.score = score
            use.frecency = Int((Double(use.totalUses) * Double(score) / Double(use.recentUses.count)).rounded(.up))
            history[key] = use
        }
    }

    private static func weight(_ days: Int) -> Int {
        switch days {
        case ...3: 100
        case ...15: 70
        case ...30: 50
        case ...45: 30
        case ...80: 10
        default: 1
        }
    }

    private static func wholeDays(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) / 86_400).rounded(.towardZero))
    }
}

/// What the account favours and reaches for — the emoji and sticker halves of
/// Discord's frecency settings (`settings-proto/2`: fields 3, 4, 5, 6, 13).
public struct ExpressionUsage: Hashable, Sendable {
    /// Starred emoji, oldest star first — Discord's keys, at most 250.
    public var favoriteEmojis: [String]
    /// Starred stickers, at most 250.
    public var favoriteStickerIDs: [UInt64]
    /// Emoji sent in messages.
    public var emojis: ExpressionFrecency
    /// Emoji reacted with — the message bar's quick reactions.
    public var reactions: ExpressionFrecency
    /// Stickers sent, keyed by the id written out.
    public var stickers: ExpressionFrecency

    /// Discord's ceiling for either list of favourites.
    public static let favoriteLimit = 250

    public init(
        favoriteEmojis: [String] = [],
        favoriteStickerIDs: [UInt64] = [],
        emojis: ExpressionFrecency,
        reactions: ExpressionFrecency,
        stickers: ExpressionFrecency
    ) {
        self.favoriteEmojis = favoriteEmojis
        self.favoriteStickerIDs = favoriteStickerIDs
        self.emojis = emojis
        self.reactions = reactions
        self.stickers = stickers
    }

    /// Nothing known yet.
    public static func empty(now: Date = .now) -> ExpressionUsage {
        ExpressionUsage(
            emojis: ExpressionFrecency(now: now),
            reactions: ExpressionFrecency(now: now),
            stickers: ExpressionFrecency(now: now)
        )
    }

    /// What Discord tracks into an empty emoji table on load, in its order.
    public static let defaultEmojis = [
        "thumbsup", "eyes", "laughing", "watermelon", "fork_and_knife",
        "yum", "weary", "tired_face", "poop", "100",
    ]
    /// And into an empty reaction table — twice for the first three, which is
    /// what puts 💯 👍 👎 on a new account's message bar.
    public static let defaultReactions = [
        "100", "100", "thumbsup", "thumbsup", "thumbsdown", "thumbsdown",
        "heart", "point_up", "eyes", "weary", "laughing", "white_check_mark", "x",
    ]

    /// The tables as Discord shows them: an empty one seeded with its
    /// defaults. **For showing only** — the seeds are never written back; a
    /// write starts from the blob as Discord holds it.
    public func seeded(now: Date = .now) -> ExpressionUsage {
        var shown = self
        if shown.emojis.history.isEmpty { shown.emojis.seed(Self.defaultEmojis, now: now) }
        if shown.reactions.history.isEmpty { shown.reactions.seed(Self.defaultReactions, now: now) }
        return shown
    }

    /// The emoji the message bar offers as quick reactions: the reactions used
    /// most, as Discord's bar takes them (`getFrequentlyUsedReactionEmojis`),
    /// skipping any the reader cannot use here.
    public func quickReactions(count: Int = 3, now: Date = .now, usable: (String) -> Bool) -> [String] {
        var picked: [String] = []
        for key in seeded(now: now).reactions.ranked where !picked.contains(key) && usable(key) {
            picked.append(key)
            if picked.count == count { break }
        }
        return picked
    }
}
