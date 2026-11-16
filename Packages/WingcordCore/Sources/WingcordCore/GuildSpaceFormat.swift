import Foundation

/// The Server Hub's numbers in words, in Discord's own forms.
public enum GuildSpaceFormat {

    /// "44h 45m", "12h", "35m" — Discord's game time (`ez`).
    public static func playTime(seconds: Double) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        switch (hours, minutes) {
        case (0, _): return "\(minutes)m"
        case (_, 0): return "\(hours)h"
        default: return "\(hours)h \(minutes)m"
        }
    }

    /// A leaderboard entry's value for its stat: game time, days or games.
    public static func value(_ value: Double, stat: GuildSpaceLeaderboard.Stat) -> String {
        switch stat {
        case .hoursPlayed, .unspecified:
            // Milliseconds on the wire (`ez(e.value / 1000)`).
            playTime(seconds: value / 1000)
        case .daysPlayed:
            count(Int(value), "day", "days")
        case .uniqueGamesPlayed:
            count(Int(value), "game", "games")
        }
    }

    /// What a winner won with, as the system message words it: "44h 45m of
    /// game time", "5 game days", "12 unique games".
    public static func achievement(_ value: Double, stat: GuildSpaceLeaderboard.Stat) -> String {
        switch stat {
        case .hoursPlayed, .unspecified:
            "\(playTime(seconds: value / 1000)) of game time"
        case .daysPlayed:
            count(Int(value), "game day", "game days")
        case .uniqueGamesPlayed:
            count(Int(value), "unique game", "unique games")
        }
    }

    /// What a new competition is about, for "Who will be this week's winner
    /// with the most game time?".
    public static func competitionSubject(_ stat: GuildSpaceLeaderboard.Stat) -> String {
        switch stat {
        case .hoursPlayed, .unspecified: "the most game time"
        case .daysPlayed: "the most game days"
        case .uniqueGamesPlayed: "the most unique games played"
        }
    }

    public static func count(_ value: Int, _ one: String, _ other: String) -> String {
        "\(value.formatted()) \(value == 1 ? one : other)"
    }
}
