import Foundation

/// How Discord orders somebody's activities, and which of them it shows.
///
/// **Read out of its presence store** (module `290863`) rather than guessed:
/// the order decides which activity a one-line summary names and which card a
/// profile leads with, and nothing on the wire arrives sorted. Three keys, in
/// turn:
///
///  1. **The kind.** A custom status, then Competing, Streaming and Playing,
///     and everything else — Listening and Watching — last.
///  2. **A rich presence before a bare one** — an activity with details, a
///     state, art, a party or secrets ahead of a game that sent only its name.
///  3. **The newest first**, by `created_at`. One without it is the oldest.
///
/// Equal on all three keeps the order it arrived in: JavaScript's sort is
/// stable and Swift's is not, so the index is a fourth key here.
///
/// **And one Playing survives.** Somebody running two games shows the one
/// ranked first. Discord's store keeps the rest, but every surface it draws
/// reads the filtered list, and so does every surface here.
public enum ActivityOrder {

    public static func presented(_ list: [Activity]) -> [Activity] {
        guard list.count > 1 else { return list }
        var seenPlaying = false
        return list.enumerated()
            .sorted { lhs, rhs in
                let left = key(lhs.element)
                let right = key(rhs.element)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .compactMap { _, activity in
                guard activity.kind == .playing else { return activity }
                defer { seenPlaying = true }
                return seenPlaying ? nil : activity
            }
    }

    /// Discord's rank for a kind — its `N`.
    static func rank(_ kind: Activity.Kind) -> Int {
        switch kind {
        case .custom: 4
        case .competing: 3
        case .streaming: 2
        case .playing: 1
        case .listening, .watching, .unknown: 0
        }
    }

    private static func key(_ activity: Activity) -> (Int, Int, Double) {
        (
            rank(activity.kind),
            activity.isRichPresence ? 1 : 0,
            activity.createdAt?.timeIntervalSince1970 ?? 0
        )
    }
}

extension Activity {
    /// Whether the app said anything beyond its name — Discord's own test
    /// (module `682261`), and the second key of its order.
    public var isRichPresence: Bool {
        kind != .custom && (
            details != nil || state != nil
                || largeImageKey != nil || smallText != nil
                || partyID != nil || partySize != nil || hasSecrets
        )
    }

    /// Spotify's own presence, by Discord's test: listening, named Spotify,
    /// in a `spotify:` party.
    public var isSpotify: Bool {
        kind == .listening && name == "Spotify" && partyID?.hasPrefix("spotify:") == true
    }

    /// Crunchyroll's application, which names itself by the episode.
    public var isCrunchyroll: Bool {
        applicationID?.rawValue == 981_509_069_309_354_054
    }

    /// A stage's own activity — Discord's stage application.
    public var isStageActivity: Bool {
        applicationID?.rawValue == 834_488_117_758_001_152
    }
}
