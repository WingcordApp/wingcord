import Foundation

/// The soundboard's Frequently Used — Discord's frecency (its module 283047)
/// with the soundboard store's options.
///
/// - Every play is a use; an entry keeps its last ten.
/// - A use scores by its age in whole days: 100 within three, 70 within
///   fifteen, 50 within thirty, 30 within forty-five, 10 within eighty, 1 after
///   — and **nothing before 29 June 2026**, the soundboard's own cut-off (its
///   `computeWeight`). An entry whose uses all score nothing is dropped.
/// - Frecency is ⌈total uses × score ÷ uses kept⌉, and Frequently Used is the
///   thirty-two highest.
/// - What is written back is the hundred used most recently.
///
/// **Recomputed from the uses, never trusted from the wire**: Discord marks
/// every loaded entry stale and scores it again, which is why the stored score
/// alone never reproduced its order.
public struct SoundFrecency: Hashable, Sendable {
    public struct Use: Hashable, Sendable {
        public var totalUses: Int
        /// Milliseconds since 1970, oldest first.
        public var recentUses: [UInt64]
        public var frecency: Int
        public var score: Int

        public init(totalUses: Int, recentUses: [UInt64], frecency: Int = 0, score: Int = 0) {
            self.totalUses = totalUses
            self.recentUses = recentUses
            self.frecency = frecency
            self.score = score
        }

        var lastUse: UInt64 { recentUses.last ?? 0 }
    }

    /// By sound id.
    public private(set) var history: [String: Use]

    public static let maxSamples = 10
    public static let frequentlyShown = 32
    public static let writtenLimit = 100
    /// 29 June 2026, midnight UTC — `Date.UTC(2026, 5, 29)`.
    public static let cutoff = Date(timeIntervalSince1970: 1_782_691_200)

    /// Scored as of `now`.
    public init(history: [String: Use], now: Date) {
        self.history = history
        compute(now: now)
    }

    /// One play — Discord's `SOUNDBOARD_TRACK_USAGE`.
    public mutating func track(_ soundID: String, at date: Date) {
        let stamp = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var use = history[soundID] ?? Use(totalUses: 0, recentUses: [])
        use.totalUses += 1
        use.recentUses.append(stamp)
        use.recentUses.sort()
        if use.recentUses.count > Self.maxSamples {
            use.recentUses.removeFirst(use.recentUses.count - Self.maxSamples)
        }
        history[soundID] = use
        compute(now: date)
    }

    /// The thirty-two with the highest frecency, the most recently played first
    /// among equals.
    public var frequently: [String] {
        history
            .sorted { lhs, rhs in
                if lhs.value.frecency != rhs.value.frecency { return lhs.value.frecency > rhs.value.frecency }
                return lhs.value.lastUse > rhs.value.lastUse
            }
            .prefix(Self.frequentlyShown)
            .map(\.key)
    }

    /// What goes back on the wire: the hundred played most recently.
    public var written: [String: Use] {
        guard history.count > Self.writtenLimit else { return history }
        let kept = history.sorted { $0.value.lastUse > $1.value.lastUse }.prefix(Self.writtenLimit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private mutating func compute(now: Date) {
        let daysSinceCutoff = Self.wholeDays(from: Self.cutoff, to: now)
        for (key, var use) in history {
            var score = 0
            for stamp in use.recentUses.prefix(Self.maxSamples) {
                let days = Self.wholeDays(from: Date(timeIntervalSince1970: Double(stamp) / 1000), to: now)
                score += days > daysSinceCutoff ? 0 : Self.weight(days)
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

    /// Moment's `diff(…, "days")`: whole days, truncated.
    private static func wholeDays(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) / 86_400).rounded(.towardZero))
    }
}
