import Foundation
import WingcordCore

/// One channel's slowmode wait, and the rules that start, correct and end it.
///
/// **Discord's own model, read out of its bundle** (module `101392`). The wait
/// is started on this side when a send lands — the channel's limit plus a tenth
/// of a second — and corrected whenever the server volunteers the real
/// remainder: in a typing answer, or in a refusal. It is never polled. A
/// moderator lowering the limit shortens a running wait to the new limit, and
/// turning slowmode off ends it.
///
/// Plain dates and a number, so every rule is a function a test can pin
/// without a clock.
nonisolated struct SlowmodeCooldown: Equatable, Sendable {
    /// When the reader may send again.
    var endsAt: Date
    /// The channel's limit, in seconds, when the wait was last set.
    ///
    /// What a channel event is compared against: `CHANNEL_UPDATE` carries the
    /// whole channel for a renamed topic too, and only a *changed* limit may
    /// move a running wait.
    var rateLimit: Int

    /// Discord's allowance on every wait it runs, so the countdown never
    /// reaches zero a beat before the server agrees.
    static let margin: TimeInterval = 0.1

    /// The wait a landed send starts, or nil where the channel has no slowmode.
    static func afterSend(rateLimit: Int, now: Date) -> SlowmodeCooldown? {
        guard rateLimit > 0 else { return nil }
        return SlowmodeCooldown(
            endsAt: now.addingTimeInterval(TimeInterval(rateLimit) + margin),
            rateLimit: rateLimit
        )
    }

    /// The wait the server says is left.
    static func reported(
        _ remaining: TimeInterval,
        rateLimit: Int,
        now: Date
    ) -> SlowmodeCooldown? {
        guard rateLimit > 0, remaining > 0 else { return nil }
        return SlowmodeCooldown(
            endsAt: now.addingTimeInterval(remaining + margin),
            rateLimit: rateLimit
        )
    }

    /// This wait once the channel's limit is `newLimit`: unchanged when the
    /// limit is, gone when slowmode is off, and never longer than the new
    /// limit from now — Discord's `min(remaining, limit)`.
    func reconciled(toRateLimit newLimit: Int, now: Date) -> SlowmodeCooldown? {
        guard newLimit > 0 else { return nil }
        guard newLimit != rateLimit else { return self }
        return SlowmodeCooldown(
            endsAt: min(endsAt, now.addingTimeInterval(TimeInterval(newLimit))),
            rateLimit: newLimit
        )
    }

    func isRunning(at now: Date) -> Bool { endsAt > now }
}

/// A send the composer held back for slowmode, so the indicator can say why
/// nothing happened.
///
/// **The token is what makes a second refusal a second flash.** Two presses of
/// Return inside one wait are two identical requests, and a value equal to the
/// one already published invalidates nothing.
nonisolated struct SlowmodeNudge: Equatable, Sendable {
    var channelID: ChannelID
    var token: UInt64
}

/// What slowmode says about a channel, in Discord's words.
nonisolated enum SlowmodeSentence {
    /// "Slowmode is enabled. Members can send one message every 2 minutes
    /// 30 seconds." — the tooltip, and what VoiceOver reads.
    ///
    /// Discord's en-US strings, with their plural rules: a zero minute or
    /// second part is left out rather than spoken as "0 seconds". Every form
    /// ends in a full stop; Discord's hour and minute forms drop it, which is a
    /// slip in the string table rather than a decision.
    static func describe(rateLimit seconds: Int) -> String {
        "Slowmode is enabled. Members can send one message every \(span(seconds))."
    }

    /// The limit as words, largest unit first.
    static func span(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        let remainder = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if remainder > 0 || parts.isEmpty { parts.append(unit(remainder, "second")) }
        return parts.joined(separator: " ")
    }

    private static func unit(_ value: Int, _ name: String) -> String {
        value == 1 ? "1 \(name)" : "\(value) \(name)s"
    }
}
