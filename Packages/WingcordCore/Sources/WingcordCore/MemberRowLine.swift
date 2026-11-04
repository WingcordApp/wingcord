import Foundation

/// The line under a name in the member list — Discord's friends sidebar
/// (`tT`, module `763349`, experiment `2026-09-friends-sidebar`).
///
/// **Not the line the direct-message list draws.** `ActivityStatusLine` says
/// everything at once: a glyph, a count of the rest, a bullet, the custom status.
/// This one says one thing and how long for, because the row beside it has a
/// picture of the game: `🎮 Escape from Tarkov · 2h`.
///
/// ```
/// 🎮 Escape from Tarkov · 2h      a game, green
/// 🔊 Playing for 2h               in a room and playing, green
/// 🔊 In voice                     in a room, green
/// ♪  Devon Hendryx · 3m           the glyph green, the words not
/// 😴 back in 10                   the custom status, when nothing else is going on
/// ```
public struct MemberRowLine: Hashable, Sendable {
    /// In front of the words, always green — Discord's `--icon-voice-connected`
    /// whatever it stands for.
    public var glyph: ActivityStatusLine.Glyph?
    /// A custom status's emoji, in the glyph's place.
    public var emoji: EmojiRef?
    /// The words. **They truncate; the time after them never does**, which is
    /// `Escape from Ta… · 2h` under the pointer (Alex's screenshot 45).
    public var text: String?
    /// When it began, for the time after the words.
    public var since: Date?
    /// What goes between the words and the time: `Escape from Tarkov · 2h`, and
    /// `Playing for 2h`.
    public var joiner: String
    /// Whether the words are green too: a game, or a room. Everything else is
    /// muted beside its green glyph.
    public var isLive: Bool
    /// The line as a sentence, for VoiceOver and the tooltip.
    public var spoken: String

    public init(
        glyph: ActivityStatusLine.Glyph? = nil,
        emoji: EmojiRef? = nil,
        text: String? = nil,
        since: Date? = nil,
        joiner: String = " · ",
        isLive: Bool = false,
        spoken: String = ""
    ) {
        self.glyph = glyph
        self.emoji = emoji
        self.text = text
        self.since = since
        self.joiner = joiner
        self.isLive = isLive
        self.spoken = spoken
    }

    /// Discord's rules, from a presence's activities.
    ///
    /// - Parameters:
    ///   - activities: in Discord's order, which `PresenceActivities` already is.
    ///   - voice: where they are talking, when the reader may see the room. It
    ///     takes the line, and a game then only gives it a clock.
    ///   - isStreaming: sharing their screen in that room.
    ///   - isBot: **an app's "Playing /help" is a slogan, not somebody playing**:
    ///     no glyph, no clock and no green.
    ///   - inGameSection: under the game's own heading, which already names it,
    ///     so the line says what they are doing in it.
    ///   - isInVoiceGroup: under the room's own heading, which already names it.
    ///   - connectedAt: when they joined that room, the clock a voice group draws
    ///     for somebody with nothing else going on.
    public static func resolve(
        activities: [Activity],
        voice: ActivityStatusLine.VoicePlace? = nil,
        isStreaming: Bool = false,
        isBot: Bool = false,
        inGameSection: Bool = false,
        isInVoiceGroup: Bool = false,
        connectedAt: Date? = nil
    ) -> MemberRowLine? {
        let game = isBot ? nil : activities.first(where: \.isGame)

        if let voice, !isInVoiceGroup {
            let glyph: ActivityStatusLine.Glyph = voice == .stage ? .stage : .voice
            if isStreaming {
                let text = game.flatMap { nonEmpty($0.name) } ?? "Sharing their screen"
                return MemberRowLine(glyph: .screen, text: text, isLive: true, spoken: text)
            }
            if let start = game?.startedAt {
                return MemberRowLine(
                    glyph: glyph, text: "Playing for", since: start, joiner: " ",
                    isLive: true, spoken: "\(voice.label), playing \(game?.name ?? "")"
                )
            }
            return MemberRowLine(glyph: glyph, text: voice.label, isLive: true, spoken: voice.label)
        }

        let timer = connectedAt.map {
            MemberRowLine(since: $0, joiner: "", isLive: true, spoken: "In voice")
        }
        guard let lead = game
            ?? activities.first(where: { $0.kind == .listening })
            ?? activities.first
        else { return timer }

        switch lead.kind {
        case .playing, .competing, .listening, .watching, .streaming:
            let words = ActivityStatusLine.words(for: lead)
            var text = words?.text
            if inGameSection, lead.isGame, !isBot {
                let showsName = lead.statusDisplay == nil || lead.statusDisplay == .name
                if showsName { text = lead.details.flatMap(nonEmpty) ?? lead.state.flatMap(nonEmpty) }
            }
            guard let text else { return timer }
            return MemberRowLine(
                glyph: isBot ? nil : ActivityStatusLine.glyph(for: lead),
                text: text,
                since: isBot ? nil : lead.startedAt,
                isLive: !isBot && lead.isGame,
                spoken: words?.spoken ?? text
            )
        case .custom:
            let state = lead.state
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap(nonEmpty)
            guard state != nil || lead.emoji != nil else { return timer }
            return MemberRowLine(
                emoji: lead.emoji,
                text: state,
                since: lead.startedAt,
                spoken: [lead.emoji?.name, state].compactMap(\.self).joined(separator: " ")
            )
        case .unknown:
            return timer
        }
    }

    /// How long something has been going on, in Discord's short words (`381849`):
    /// `1m` under a minute, then minutes, hours, days, months and years. Its month
    /// is thirty days and its year twelve of them.
    public static func duration(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start).rounded()))
        switch seconds {
        case ..<60: return "1m"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        case ..<2_592_000: return "\(seconds / 86_400)d"
        case ..<31_104_000: return "\(seconds / 2_592_000) mo"
        default: return "\(seconds / 31_104_000)y"
        }
    }

    private static func nonEmpty(_ string: String) -> String? {
        string.isEmpty ? nil : string
    }
}

extension Activity {
    /// Discord's test for "playing something": what makes somebody Active Now,
    /// what earns a row its squircle, and what a game's section gathers.
    /// **Listening is not it.**
    public var isGame: Bool { kind == .playing || kind == .competing }
}
