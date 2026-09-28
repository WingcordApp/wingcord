import Foundation

/// The line Discord draws under somebody's name: what they are doing, a count
/// of the rest, and their custom status.
///
/// **One component in Discord** — `ActivityStatus`, module `394871` — drawn by
/// the member list, the direct-message list and the account panel alike. So it
/// is one value here, resolved once, that three surfaces paint.
///
/// ```
/// 🎮 Counter-Strike 2 +1          an activity, and one more
/// 🎮 +1 • 😴 back in 10           the custom status takes the text
/// 🔊 In voice                     no activity, in a call
/// ```
public struct ActivityStatusLine: Hashable, Sendable {

    /// The glyph in front of the lead.
    public enum Glyph: Hashable, Sendable {
        /// Playing or Competing.
        case game
        /// Listening.
        case music
        /// Watching or Streaming, and a screen share.
        case screen
        /// An Activity, launched in a voice channel.
        case activity
        /// A stage.
        case stage
        /// In a voice channel or a call. **The one Discord draws green.**
        case voice
    }

    /// Where somebody is talking, when the reader can see it.
    public enum VoicePlace: Hashable, Sendable {
        case voiceChannel
        case stage
        case call

        var label: String {
            switch self {
            case .voiceChannel: "In voice"
            case .stage: "In a stage"
            case .call: "In a call"
            }
        }
    }

    public var glyph: Glyph?
    /// The lead's words. **Nil where the custom status has taken the line**:
    /// the activity then keeps only its glyph — Discord's own rule for the
    /// small size every one of these surfaces draws at.
    public var text: String?
    /// How many more there are than the one drawn — "+N". Zero draws nothing.
    public var overflow: Int
    public var statusEmoji: EmojiRef?
    public var statusText: String?
    /// The lead as a sentence — "Playing Counter-Strike 2" — which is what
    /// Discord's tooltip says and what VoiceOver should.
    public var spokenLead: String?

    public init(
        glyph: Glyph? = nil,
        text: String? = nil,
        overflow: Int = 0,
        statusEmoji: EmojiRef? = nil,
        statusText: String? = nil,
        spokenLead: String? = nil
    ) {
        self.glyph = glyph
        self.text = text
        self.overflow = overflow
        self.statusEmoji = statusEmoji
        self.statusText = statusText
        self.spokenLead = spokenLead
    }

    /// Whether anything is drawn before the separator.
    public var hasLead: Bool { glyph != nil || text != nil || overflow > 0 }
    public var hasStatus: Bool { statusEmoji != nil || statusText != nil }
    public var isEmpty: Bool { !hasLead && !hasStatus }

    /// The whole line as one sentence.
    public var spokenText: String {
        var parts: [String] = []
        if let spokenLead { parts.append(spokenLead) }
        if overflow > 0 { parts.append("and \(overflow) more") }
        if hasStatus {
            parts.append([statusEmoji?.name, statusText].compactMap(\.self).joined(separator: " "))
        }
        return parts.joined(separator: ", ")
    }

    /// Discord's rules, from a presence's activities.
    ///
    /// - Parameters:
    ///   - activities: in Discord's order, which `PresenceActivities` already is.
    ///   - isStreaming: sharing their screen — the lead, whatever else they do.
    ///   - voice: where they are talking, when the reader may see the room.
    ///     A stream wins over it.
    ///   - isBot: a bot's line draws no glyph and no count.
    public static func resolve(
        activities: [Activity],
        isStreaming: Bool = false,
        voice: VoicePlace? = nil,
        isBot: Bool = false
    ) -> ActivityStatusLine {
        let custom = activities.first { $0.kind == .custom }
        let statusText = custom?.state.flatMap {
            nonEmpty($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // A screen share is named after the game they are playing, when they
        // are — Discord's `useStreamApplication` (module `834757`) — and that
        // game is not then counted a second time.
        let streamed = isStreaming
            ? activities.first { $0.kind == .playing && !$0.isEmbedded }
            : nil

        var others: [Activity] = []
        for activity in activities where activity.kind != .custom && activity.kind != .unknown {
            if let streamed, activity.name == streamed.name { continue }
            if others.contains(where: { $0.isSameSource(as: activity) }) { continue }
            others.append(activity)
        }
        let isInVoice = !isStreaming && voice != nil
        let total = others.count + (isStreaming || isInVoice ? 1 : 0)

        var glyph: Glyph?
        var text: String?
        var spoken: String?
        if isStreaming {
            glyph = isBot ? nil : .screen
            text = streamed.flatMap { nonEmpty($0.name) } ?? "Sharing their screen"
            spoken = text
        } else if let lead = others.first {
            glyph = isBot ? nil : Self.glyph(for: lead)
            let words = Self.words(for: lead)
            text = words?.text
            spoken = words?.spoken
        } else if let voice {
            glyph = .voice
            text = voice.label
            spoken = text
        }

        return ActivityStatusLine(
            glyph: glyph,
            text: statusText == nil ? text : nil,
            overflow: total > 1 && !isBot ? total - 1 : 0,
            statusEmoji: custom?.emoji,
            statusText: statusText,
            spokenLead: spoken
        )
    }

    /// The glyph for one activity — Discord's module `835072`.
    static func glyph(for activity: Activity) -> Glyph? {
        if activity.isStageActivity { return .stage }
        if activity.isEmbedded { return .activity }
        return switch activity.kind {
        case .playing, .competing: .game
        case .listening: .music
        case .watching, .streaming: .screen
        case .custom, .unknown: nil
        }
    }

    /// The words for one activity, and the sentence Discord's tooltip makes of
    /// them — module `566903`.
    ///
    /// **A name, not a verb.** The glyph already says Playing or Listening; the
    /// words are what: the game, the artists, the video.
    static func words(for activity: Activity) -> (text: String, spoken: String)? {
        let name = nonEmpty(activity.name)
        let details = activity.details.flatMap(nonEmpty)
        let state = activity.state.flatMap(nonEmpty)
        var headline = activity.kind == .streaming ? details ?? name : name
        switch activity.statusDisplay {
        case .name: if let name { headline = name }
        case .state: if let state { headline = state }
        case .details: if let details { headline = details }
        case nil: break
        }

        if activity.isEmbedded {
            let text = name ?? "In Activity"
            return (text, text)
        }
        if activity.kind == .playing, let headline {
            return (headline, "Playing \(headline)")
        }
        // Spotify names the artists, which it sends joined with semicolons.
        if activity.isSpotify, let state {
            let artists = state.components(separatedBy: "; ").joined(separator: ", ")
            return (artists, "Listening to \(artists)")
        }
        if activity.isStageActivity, let name {
            return (name, "Watching \(name)")
        }
        if activity.kind == .listening, let headline {
            return (headline, "Listening to \(headline)")
        }
        // Crunchyroll names itself by the episode.
        if activity.isCrunchyroll, let details {
            return (details, "Watching \(details)")
        }
        guard let headline else { return nil }
        return switch activity.kind {
        case .watching: (headline, "Watching \(headline)")
        case .competing: (headline, "Competing in \(headline)")
        case .streaming: (headline, "Streaming \(headline)")
        case .playing, .listening, .custom, .unknown: nil
        }
    }

    private static func nonEmpty(_ string: String) -> String? {
        string.isEmpty ? nil : string
    }
}

extension Activity {
    /// Whether two activities are the same thing twice — the same application,
    /// or the same name. Discord lists each once.
    func isSameSource(as other: Activity) -> Bool {
        if let mine = applicationID, let theirs = other.applicationID, mine == theirs {
            return true
        }
        return name == other.name
    }
}
