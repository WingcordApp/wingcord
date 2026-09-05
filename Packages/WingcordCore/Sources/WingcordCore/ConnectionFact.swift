import Foundation

/// One thing a linked service publishes about an account — "16 Games", "20,223
/// Karma", "Member since 2 May 2019".
///
/// **Rendered by the key's SHAPE, not by a table of every key.** Discord's
/// connection metadata is per-service and open-ended: Steam sends `game_count`
/// and `item_count_dota2`, Reddit sends `total_karma` and `gold`, Twitter sends
/// `followers_count` and `statuses_count`, and a service added next month will
/// send something nobody has seen. A closed table would draw nothing for it.
///
/// So three rules do the work, and a small table only fixes the nouns that come
/// out wrong when derived mechanically:
///
///  - `created_at` is a date and leads the line.
///  - anything ending `_count`, or beginning `total_`, is a number followed by
///    a noun made from the rest of the key.
///  - `"1"` and `"0"` are a flag, drawn only when it is `"1"`.
///
/// Anything that fits none of them is carried and not drawn, which is the
/// honest treatment for a value whose meaning nothing here knows.
public struct ConnectionFact: Hashable, Sendable, Identifiable {
    public var key: String
    public var content: Content

    public var id: String { key }

    public enum Content: Hashable, Sendable {
        /// "Member since 2 May 2019".
        case since(Date)
        /// A count and its noun — `20223` and `"Karma"`.
        case count(Int, noun: String)
        /// A badge the service grants, like Reddit Gold. Drawn only when set.
        case flag(String)
    }

    public init?(key: String, rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        self.key = key

        if key == "created_at" {
            guard let date = Self.date(from: value) else { return nil }
            content = .since(date)
            return
        }

        if let number = Int(value) {
            // **A negative count is a sentinel, not a quantity.** Steam sends
            // `item_count_dota2: "-1"` for an account that does not play Dota,
            // and "-1 Dota2 Items" is the kind of line that makes a client look
            // like it is printing a database.
            if let noun = Self.noun(for: key) {
                guard number > 0 else { return nil }
                content = .count(number, noun: noun)
                return
            }
            // A bare 1/0 with no count-shaped key is a flag.
            if number == 0 || number == 1 {
                guard number == 1, let label = Self.flagLabel(for: key) else { return nil }
                content = .flag(label)
                return
            }
        }
        return nil
    }

    /// Where this fact sits on the line. Dates first, then counts, then flags.
    public var sortRank: Int {
        switch content {
        case .since: 0
        case .count: 1
        case .flag: 2
        }
    }

    /// The noun after a count, or nil where the key is not count-shaped.
    ///
    /// The overrides exist because the mechanical answer is wrong for exactly
    /// these: `statuses_count` is "Posts" on every service that sends it, and
    /// `total_karma` is "Karma" rather than "Total Karma".
    static func noun(for key: String) -> String? {
        switch key {
        case "statuses_count": return "Posts"
        case "followers_count", "follower_count": return "Followers"
        case "following_count": return "Following"
        case "like_count", "likes_count": return "Likes"
        case "total_karma": return "Karma"
        case "game_count": return "Games"
        case "subscriber_count": return "Subscribers"
        case "video_count": return "Videos"
        case "post_count": return "Posts"
        default: break
        }
        var stem = key
        if stem.hasSuffix("_count") {
            stem = String(stem.dropLast("_count".count))
        } else if stem.hasPrefix("total_") {
            stem = String(stem.dropFirst("total_".count))
        } else if stem.contains("_count_") {
            // Steam's shape: `item_count_dota2`. The count sits in the middle,
            // so neither the suffix nor the prefix rule reaches it — and without
            // this the whole key falls through to "not renderable" and the fact
            // is silently dropped.
            stem = stem.replacingOccurrences(of: "_count_", with: "_")
        } else {
            return nil
        }
        guard !stem.isEmpty else { return nil }
        return Self.humanised(stem)
    }

    /// The badge text for a flag key, or nil for one nothing should draw.
    ///
    /// `verified` is deliberately absent: the account already wears a seal
    /// beside its name, and a second "Verified" badge under it says the same
    /// thing twice.
    static func flagLabel(for key: String) -> String? {
        switch key {
        case "verified": return nil
        case "gold": return "Gold"
        case "mod": return "Moderator"
        case "partner": return "Partner"
        case "premium": return "Premium"
        default: return humanised(key)
        }
    }

    /// `item_count_dota2` → "Dota2 Items"; `total_karma` → "Karma".
    ///
    /// Reversed for the `item_count_x` shape, because "Dota2 Items" is English
    /// and "Items Dota2" is a column name.
    static func humanised(_ stem: String) -> String {
        var parts = stem.split(separator: "_").map(String.init)
        if parts.first == "item", parts.count > 1 {
            parts = Array(parts.dropFirst()) + ["Items"]
        }
        return parts
            .map { $0.count <= 2 ? $0.uppercased() : $0.capitalized }
            .joined(separator: " ")
    }

    /// **No timezone, and that is not a bug in the capture.** Connection
    /// metadata dates arrive as `2020-08-08T15:29:17` — a bare local-looking
    /// timestamp, unlike every other date on this API. The ISO parser rejects
    /// them without a zone, so one is assumed.
    static func date(from value: String) -> Date? {
        if let date = ISO8601DateFormatter.connectionMetadata.date(from: value) { return date }
        return ISO8601DateFormatter.connectionMetadata.date(from: value + "Z")
    }
}

extension ISO8601DateFormatter {
    /// Built once: a profile with a dozen connections parses a dozen of these,
    /// and the formatter is expensive to construct.
    nonisolated(unsafe) static let connectionMetadata: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
