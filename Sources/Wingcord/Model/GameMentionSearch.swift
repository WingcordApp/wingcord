import Foundation
import WingcordCore

/// `@game`'s search: Discord's game autocomplete store (`243264`) — answers by
/// query, every game they named by id, and what is on its way.
struct GameMentionSearch {
    /// Answers, by normalised query.
    var results: [String: [GameSummary]] = [:]
    /// Every game an answer has named — where a picked game's name and icon
    /// are found again, as Discord's `getGameById` is.
    var byID: [ApplicationID: GameSummary] = [:]
    var inFlight: Set<String> = []

    /// Discord's `C7`: trimmed, lowercased, underscores read as spaces, at
    /// most a hundred characters — and nil for nothing at all.
    static func normalized(_ query: String) -> String? {
        let key = String(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .prefix(100)
        )
        return key.isEmpty ? nil : key
    }

    /// The answer for the longest start of the query that has one.
    func closestResults(for key: String) -> [GameSummary]? {
        var prefix = key[...]
        while !prefix.isEmpty {
            if let found = results[String(prefix)] { return found }
            prefix = prefix.dropLast()
        }
        return nil
    }

    /// Whether asking is pointless — Discord's `shouldSuppressFetch`: the
    /// longest shorter query answered found nothing, and was seven or more
    /// characters long, so a longer one will not find anything either.
    func isPointless(_ key: String) -> Bool {
        guard results[key] == nil, !inFlight.contains(key) else { return false }
        var prefix = key.dropLast()
        while !prefix.isEmpty {
            if let found = results[String(prefix)] { return found.isEmpty && prefix.count >= 7 }
            prefix = prefix.dropLast()
        }
        return false
    }
}
