import Foundation

/// What Discord's activity card says, line by line — `UserProfileActivityCard`
/// (module `580763`), its header (module `160376`) and its row of entries
/// (modules `282197` and `78871`).
///
/// **Words and facts only.** The card's art, its buttons and its ground belong
/// to the view; which line says what is a rule, and a rule is testable.
///
/// ```
/// Watching YouTube ▶︎                 header, and the platform's mark
/// [art]  How to setup BL2 Mods        title
///        WholyMilk                    subtitle
///        🖥 0:02                       the clock, in the kind's glyph
/// ```
public struct ActivityCardContent: Hashable, Sendable {

    /// "Watching YouTube", "Playing on Xbox", "Listening to Spotify".
    public var header: String?
    /// The service whose mark rides the header, as a connection type — the key
    /// `BrandMark` knows it by.
    public var platform: String?
    public var title: String
    public var titleURL: URL?
    public var subtitle: String?
    public var subtitleURL: URL?
    /// A third line: an Activity's head count, a game's state, or the large
    /// image's caption.
    public var detail: String?
    public var detailURL: URL?
    /// "In Queue (2 of 5)" — a game's party, which rides beside the clock.
    public var party: String?
    /// "S1E5", for a show that names its episode.
    public var episode: String?
    /// The glyph the clock wears.
    public var clockGlyph: ActivityStatusLine.Glyph
    /// Where the clock counts from, where it runs at all.
    public var clockStart: Date?
    /// Music or a video with both ends known shows a bar instead of a clock.
    public var showsProgress: Bool

    public init(_ activity: Activity) {
        let details = activity.details.flatMap(Self.nonEmpty)
        let state = activity.state.flatMap(Self.nonEmpty)
        let isPlaying = activity.kind == .playing

        platform = Self.platform(of: activity)
        header = Self.header(for: activity, platform: platform, hasDetails: details != nil)

        // A game names itself and says what it is doing; everything else leads
        // with what is playing.
        if isPlaying || activity.isStageActivity || details == nil {
            title = activity.name
        } else {
            title = details ?? activity.name
            titleURL = activity.detailsURL
        }
        if activity.kind == .unknown {
            subtitle = nil
        } else if isPlaying {
            subtitle = details
            subtitleURL = activity.detailsURL
        } else if activity.isStageActivity {
            subtitle = activity.smallText
        } else {
            subtitle = state
            subtitleURL = activity.stateURL
        }

        if activity.kind == .watching {
            detail = nil
        } else if isPlaying {
            if activity.isEmbedded, let size = activity.partySize, size.count >= 2 {
                let count = size[1] == 0 ? "(\(size[0]))" : "(\(size[0]) of \(size[1]))"
                detail = [state, count].compactMap(\.self).joined(separator: " ")
            } else if activity.partyID == nil, activity.partySize == nil {
                detail = state
            }
        } else if let caption = activity.largeText.flatMap(Self.nonEmpty) {
            detail = caption
            detailURL = activity.largeImageURL
        }

        // A game's party rides beside the clock — which is why, when there is
        // one, the state is not also the third line.
        if isPlaying, !activity.isEmbedded, activity.partyID != nil || activity.partySize != nil {
            party = Self.party(state: state, size: activity.partySize)
        }
        if activity.kind == .watching {
            episode = activity.largeText.flatMap(Self.episode)
        }

        showsProgress = (activity.kind == .listening || activity.kind == .watching)
            && activity.startedAt != nil && activity.endsAt != nil
        clockStart = showsProgress || activity.isStageActivity || activity.kind == .streaming
            ? nil
            : activity.startedAt ?? activity.createdAt
        clockGlyph = if activity.isEmbedded {
            .activity
        } else {
            switch activity.kind {
            case .listening: .music
            case .watching: .screen
            case .playing, .streaming, .competing, .custom, .unknown: .game
            }
        }
    }

    /// Discord's clock — `m:ss` under an hour and `h:mm:ss` over it, with the
    /// minutes unpadded until there are hours to pad them against (module
    /// `583846`).
    public static func clock(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        let s = seconds % 60, m = (seconds / 60) % 60, h = seconds / 3600
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    // MARK: The rules

    /// The service whose mark the header carries.
    ///
    /// Spotify, Crunchyroll and the two consoles by their own tests; otherwise a
    /// platform whose name the activity *is* — Discord's short list of four.
    static func platform(of activity: Activity) -> String? {
        if activity.isSpotify { return "spotify" }
        if activity.isCrunchyroll { return "crunchyroll" }
        if activity.applicationID?.rawValue == 438_122_941_302_046_720 || activity.platform == "xbox" {
            return "xbox"
        }
        if activity.platform == "ps4" || activity.platform == "ps5" { return "playstation" }
        return switch activity.name {
        case "YouTube": "youtube"
        case "Twitch": "twitch"
        case "Roblox": "roblox"
        case "League of Legends": "leagueoflegends"
        default: nil
        }
    }

    static func header(for activity: Activity, platform: String?, hasDetails: Bool) -> String? {
        let name = activity.name
        switch (activity.kind, platform) {
        case (.playing, "xbox"): return "Playing on Xbox"
        case (.playing, "playstation"): return "Playing on PlayStation"
        case (.streaming, "twitch"): return "Streaming Twitch"
        case (.streaming, "youtube"): return "Streaming YouTube"
        default: break
        }
        if activity.kind == .playing { return "Playing" }
        if activity.kind == .streaming { return "Streaming" }
        if activity.isStageActivity { return "Watching \(name)" }
        return switch activity.kind {
        case .listening: hasDetails ? "Listening to \(name)" : "Listening to"
        case .watching: hasDetails ? "Watching \(name)" : "Watching"
        case .competing: hasDetails ? "Competing in \(name)" : "Competing in"
        case .playing, .streaming, .custom, .unknown: nil
        }
    }

    /// "In Queue (2 of 5)", "(3)", or the state alone.
    static func party(state: String?, size: [Int]?) -> String? {
        let current = size?.first ?? 0
        let maximum = size.flatMap { $0.count > 1 ? $0[1] : nil } ?? 0
        let count: String? = current > 0 && maximum > 0 ? "\(current) of \(maximum)"
            : current > 0 ? "\(current)" : nil
        guard let count else { return state }
        return state.map { "\($0) (\(count))" } ?? count
    }

    /// "S1E5", from a caption that reads like "Season 1, Episode 5" anywhere in
    /// it — Discord's `/\w+ (\d+), \w+ (\d+)/`, scanned by hand because a regex
    /// on a render path is parsed on every call.
    static func episode(_ caption: String) -> String? {
        let words = caption.split(separator: " ")
        guard words.count >= 4 else { return nil }
        func isWord(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber || character == "_")
        }
        func digits(_ text: Substring) -> Int? {
            let run = text.prefix { $0.isASCII && $0.isNumber }
            return run.isEmpty ? nil : Int(run)
        }
        for index in 0...(words.count - 4) {
            let seasonWord = words[index + 1]
            guard words[index].last.map(isWord) == true,
                  seasonWord.hasSuffix(","),
                  let season = digits(seasonWord.dropLast()),
                  season == Int(seasonWord.dropLast()),
                  words[index + 2].allSatisfy(isWord),
                  let episode = digits(words[index + 3])
            else { continue }
            return "S\(season)E\(episode)"
        }
        return nil
    }

    private static func nonEmpty(_ string: String) -> String? {
        string.isEmpty ? nil : string
    }
}
