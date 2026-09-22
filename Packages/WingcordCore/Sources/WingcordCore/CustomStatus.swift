import Foundation

/// What somebody wrote about themselves, with the emoji beside it and the
/// moment it stops being true.
///
/// **One value, because the three travel together.** Text without its emoji is
/// half a status, and an expiry with no status to expire is a timer for
/// nothing — Discord carries all three in one `CustomStatus` message and the
/// write replaces the whole of it.
public struct CustomStatus: Hashable, Sendable {
    public var text: String?
    public var emoji: EmojiRef?
    /// When it clears itself. Nil is "Don't clear".
    public var expiresAt: Date?

    public init(text: String? = nil, emoji: EmojiRef? = nil, expiresAt: Date? = nil) {
        self.text = text.flatMap { $0.isEmpty ? nil : $0 }
        self.emoji = emoji
        self.expiresAt = expiresAt
    }

    /// Whether there is anything to show.
    public var isEmpty: Bool { text == nil && emoji == nil }

    /// Whether it is still current.
    ///
    /// **An expired status is not cleared on the wire.** Discord leaves it in
    /// the settings blob and lets the moment pass, exactly as it does with a
    /// mute — so every read goes through here rather than trusting the value's
    /// presence. A client that skipped this would keep broadcasting a status
    /// somebody asked it to drop hours ago.
    public func isActive(at date: Date = .now) -> Bool {
        guard !isEmpty else { return false }
        guard let expiresAt else { return true }
        return expiresAt > date
    }

    /// The value as it should be published, or nil once it has lapsed.
    public func current(at date: Date = .now) -> CustomStatus? {
        isActive(at: date) ? self : nil
    }

    /// Discord's own character limit on the text.
    public static let textLimit = 128
}

/// How long a custom status lasts.
///
/// **Read out of Discord's own bundle**, where the five sit in one frozen table
/// with the three timed ones as milliseconds and the other two as sentinels:
/// `MINUTES_30: 18e5, HOURS_1: 36e5, HOURS_4: 144e5, TODAY, DONT_CLEAR` — and
/// the menu's order is `[TODAY, HOURS_4, HOURS_1, MINUTES_30, DONT_CLEAR]`,
/// which is longest first.
public enum CustomStatusDuration: Hashable, Sendable, CaseIterable {
    case today
    case fourHours
    case oneHour
    case thirtyMinutes
    case never

    /// The order Discord's own menu draws.
    public static let allCases: [CustomStatusDuration] = [
        .today, .fourHours, .oneHour, .thirtyMinutes, .never,
    ]

    /// What the row says before the time in brackets.
    public var title: String {
        switch self {
        case .today: "24 hours"
        case .fourHours: "4 hours"
        case .oneHour: "1 hour"
        case .thirtyMinutes: "30 minutes"
        case .never: "Don't clear"
        }
    }

    /// When a status set now under this rule would lapse. Nil for `.never`.
    ///
    /// **`.today` is twenty-four hours, not midnight**, however its constant is
    /// named: Discord's own menu, opened at 10:39, offered "24 hours (tomorrow
    /// at 10:39 AM)". The name is the wire's; the arithmetic is the capture's.
    public func expiry(from now: Date = .now) -> Date? {
        switch self {
        case .today: now.addingTimeInterval(24 * 60 * 60)
        case .fourHours: now.addingTimeInterval(4 * 60 * 60)
        case .oneHour: now.addingTimeInterval(60 * 60)
        case .thirtyMinutes: now.addingTimeInterval(30 * 60)
        case .never: nil
        }
    }

    /// Which row is ticked for a status that already has an expiry.
    ///
    /// **The nearest rule at or above the time left**, rather than an exact
    /// match: the stored value is a moment and these are durations, so by the
    /// time the sheet is reopened no rule computes that moment any more.
    public static func matching(_ expiry: Date?, at now: Date = .now) -> CustomStatusDuration {
        guard let expiry else { return .never }
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else { return .never }
        for duration in allCases where duration != .never {
            guard let candidate = duration.expiry(from: now) else { continue }
            if remaining <= candidate.timeIntervalSince(now) { return duration }
        }
        return .today
    }
}

/// The greyed prompt in an empty status field.
///
/// **Discord rotates a list of them**, and its own enum names thirty-odd:
/// `PLAYING`, `LISTENING_TO`, `SONG_STUCK`, `EMOJI_DAY`, `CANT_WAIT` and so on.
/// The enum is in the bundle; the sentences are not — they live in a locale
/// file this client does not fetch. The ones below are the ones actually seen
/// rendered, in captures and in screenshots of Discord's own card; the rest are
/// written in this app's own voice rather than guessed at Discord's, which is
/// the same trade `OAuthScope.description` makes.
public enum CustomStatusPrompt {
    /// Verbatim from Discord, in the order they were seen.
    public static let all: [String] = [
        "Best emoji to describe your day?",
        "Last song stuck in your head?",
        "Can't wait for...",
        "What's on your mind?",
        "Something you learned today?",
        "A useless talent of yours?",
        "What are you playing?",
        "What are you reading?",
    ]

    /// One of them, chosen per opening rather than per frame.
    ///
    /// **Seeded by the caller, not by `random()` in a body.** A view body runs
    /// on every hover, and a prompt that changed under the pointer would read as
    /// a field that cannot make up its mind.
    public static func prompt(seed: Int) -> String {
        all[abs(seed) % all.count]
    }
}
