import Foundation

// MARK: - Auto Clips: when to keep a moment nobody asked to keep
//
// docs/CLIPS-PRESENCE.md, Phase 7.2 (D19). Discord's Auto Clips (build
// 643186) scores every second on two axes — a **game axis** from the game's
// own events and an **emotion axis** from an on-device model listening for
// laughter and shouting — with game-state modifiers (out of a match a quarter,
// a planted bomb double) and a threshold per game (Counter-Strike and Dota
// 0.35, League 0.17, Rocket League 0.25 on their scales); some events can
// *anchor a reaction* — a laugh just after a kill belongs to the kill. Its
// clips are filed as `clipMethod: "auto"` with the signal that chose them,
// and labelled "In-game event", "LOL" or "Shouting".
//
// This is the same idea on the signals a Mac can read, small enough to state
// in a test: each signal scores, the scores of the last few seconds add up, a
// reaction after an anchoring event counts half again, and a moment is kept
// when the sum reaches one — then nothing for a while, so one fight is one
// clip.

/// Something that happened, as the policy weighs it.
public enum AutoClipSignal: Hashable, Sendable {
    /// The classifier's laughter labels, at its confidence (0…1).
    case laughter(confidence: Double)
    /// Its shouting labels — shout, yell, screaming, battle cry.
    case shouting(confidence: Double)
    /// An event the game reported, in its own words.
    case game(GameEventKind, name: String)
}

/// Why a moment was kept — what the library's chip says.
public struct AutoClipReason: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// Discord's "In-game event".
        case gameEvent
        /// Discord's "LOL".
        case laughter
        /// Discord's "Shouting".
        case shouting
    }

    public var kind: Kind
    /// The game's words for an event ("Triple Kill"), or the chip's.
    public var name: String
    /// How strongly it was chosen — Discord's `clip_auto_clip_score`.
    public var score: Double

    public init(kind: Kind, name: String, score: Double) {
        self.kind = kind
        self.name = name
        self.score = score
    }

    /// Discord's label for the kind.
    public var label: String {
        switch kind {
        case .gameEvent: "In-game event"
        case .laughter: "LOL"
        case .shouting: "Shouting"
        }
    }
}

/// A moment to keep: when, from when, and why.
public struct AutoClipTrigger: Hashable, Sendable {
    /// The moment itself, on the caller's clock.
    public var time: Double
    /// The earliest signal that counted towards it.
    public var start: Double
    public var reason: AutoClipReason
}

public struct AutoClipPolicy: Sendable {
    /// What a moment has to add up to.
    public var threshold = 1.0
    /// How far back signals still count, in seconds.
    public var window = 8.0
    /// How long after a kept moment nothing else is kept.
    public var cooldown = 30.0
    /// How long after an anchoring event a reaction belongs to it.
    public var reactionWindow = 6.0
    /// Discord's two switches.
    public var listensForEmotion = true
    public var listensForGameEvents = true

    private struct Counted: Hashable, Sendable {
        var time: Double
        var score: Double
        var reason: AutoClipReason
        var anchors: Bool
    }

    private var counted: [Counted] = []
    private var lastKept = -Double.infinity

    public init() {}

    /// Weighs `signal` at `time` and answers a moment when the sum reaches the
    /// threshold. Signals must arrive in time order.
    public mutating func observe(_ signal: AutoClipSignal, at time: Double) -> AutoClipTrigger? {
        let base: Double
        let reason: AutoClipReason
        var anchors = false
        switch signal {
        case .laughter(let confidence):
            guard listensForEmotion, confidence >= Self.laughterFloor else { return nil }
            base = confidence * 1.15
            reason = AutoClipReason(kind: .laughter, name: "LOL", score: 0)
        case .shouting(let confidence):
            guard listensForEmotion, confidence >= Self.shoutingFloor else { return nil }
            base = confidence * 0.9
            reason = AutoClipReason(kind: .shouting, name: "Shouting", score: 0)
        case .game(let kind, let name):
            guard listensForGameEvents else { return nil }
            base = Self.score(kind, name: name)
            guard base > 0 else { return nil }
            anchors = Self.anchors(kind)
            reason = AutoClipReason(kind: .gameEvent, name: name, score: 0)
        }

        counted.removeAll { $0.time < time - window }
        // A reaction just after an anchoring event belongs to it, and counts
        // half again — Discord's `canAnchorReaction`.
        var score = base
        if reason.kind != .gameEvent,
           counted.contains(where: { $0.anchors && time - $0.time <= reactionWindow }) {
            score *= 1.5
        }
        counted.append(Counted(time: time, score: score, reason: reason, anchors: anchors))

        guard time - lastKept >= cooldown else { return nil }
        let total = counted.reduce(0) { $0 + $1.score }
        guard total >= threshold else { return nil }

        // Named for its strongest game event when there is one — "Triple
        // Kill" says more than "LOL" — else for its strongest reaction.
        let events = counted.filter { $0.reason.kind == .gameEvent }
        let lead = (events.isEmpty ? counted : events).max { $0.score < $1.score }!
        var chosen = lead.reason
        chosen.score = min(total, 9.99)
        let trigger = AutoClipTrigger(
            time: time,
            start: counted.map(\.time).min() ?? time,
            reason: chosen
        )
        lastKept = time
        counted.removeAll()
        return trigger
    }

    /// Below these the classifier is guessing.
    public static let laughterFloor = 0.6
    public static let shoutingFloor = 0.7

    /// What a game event is worth alone. A multikill, a victory or a named
    /// big moment is a clip by itself; a kill needs a reaction or a second.
    public static func score(_ kind: GameEventKind, name: String) -> Double {
        switch kind {
        case .multikill, .victory: return 1.0
        case .objectiveKill: return 0.7
        case .kill: return 0.45
        case .death, .defeat: return 0.3
        case .assist, .treasure: return 0.2
        case .levelUp: return 0.1
        case .item: return 0
        case .unclassified:
            // **At the start of a word**, not anywhere: "Ward Placed" holds
            // "ace" and is not an Ace; "Pentakill" starts with "penta" and is.
            let words = " " + name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " } + " "
            func names(_ key: String) -> Bool { words.contains(" " + key) }
            if bigMoments.contains(where: names) { return 1.0 }
            if notableMoments.contains(where: names) { return 0.6 }
            return 0.2
        }
    }

    /// Whether a reaction just after this belongs to it.
    public static func anchors(_ kind: GameEventKind) -> Bool {
        switch kind {
        case .kill, .multikill, .death, .objectiveKill: true
        default: false
        }
    }

    /// Discord's named events that are a clip on their own — Counter-Strike's
    /// Ace and round winners, League's pentakill and steals, Dota's won fight.
    static let bigMoments = [
        "ace", "game winning", "round winning", "penta", "team fight won", "steal",
        "rampage", "clutch",
    ]
    /// Ones that are worth most of one.
    static let notableMoments = [
        "bomb defused", "bomb exploded", "roshan", "elder", "baron", "dragon", "team fight", "first blood",
    ]
}
