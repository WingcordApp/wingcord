import Foundation

// MARK: - The quick switcher's grammar and its scorer
//
// Everything here is pure: a string in, a tier out. The store's own walk over
// the account lives in the app, and the reason the two are split is that this
// half is the half worth pinning with tests — a ranking nobody can state is a
// ranking nobody can fix.

/// What a leading sigil narrows the switcher to.
///
/// **Discord's own five, and they are typed rather than picked.** A row of mode
/// buttons above the field would be five controls for a gesture that is one
/// character, and it would take the width the results need. The characters are
/// the reference client's exactly — anybody who already knows them keeps them.
public enum QuickSwitchFilter: Character, CaseIterable, Sendable {
    case people = "@"
    case textChannels = "#"
    case voiceChannels = "!"
    case servers = "*"
    case games = "$"

    /// What the list says it is doing, above the rows.
    ///
    /// **Named for what this client actually searches.** Discord's header for
    /// `@` says "SEARCHING ALL USERS" and answers an empty list until something
    /// is typed, because it has a directory behind it. This has the account's
    /// own people — friends, everyone in an open conversation, and the roster of
    /// whatever server is loaded — so it says that instead. A header that
    /// promises a directory and searches a roster is a promise the surface
    /// cannot keep.
    public var title: String {
        switch self {
        case .people: "People you know"
        case .textChannels: "Text channels"
        case .voiceChannels: "Voice channels"
        case .servers: "Servers"
        case .games: "Game profiles"
        }
    }
}

/// The field's text, split into the sigil and the words.
public struct QuickSwitchQuery: Hashable, Sendable {
    public var filter: QuickSwitchFilter?
    /// What to match on, case- and diacritic-folded once. Compare only against
    /// text folded the same way — `QuickSwitchRank.fold(_:)` is the one copy.
    public var needle: String

    public var isEmpty: Bool { needle.isEmpty }

    public init(filter: QuickSwitchFilter? = nil, needle: String = "") {
        self.filter = filter
        self.needle = needle
    }

    /// Splits what has been typed.
    ///
    /// **The sigil is only a sigil at the very start**, which is what lets `#`
    /// and `@` still be searched for as characters once anything precedes them.
    /// Leading whitespace is trimmed first so a stray space before `#` does not
    /// silently change what the field means.
    public static func parse(_ text: String) -> QuickSwitchQuery {
        let trimmed = text.drop { $0 == " " }
        guard let first = trimmed.first, let filter = QuickSwitchFilter(rawValue: first) else {
            return QuickSwitchQuery(filter: nil, needle: QuickSwitchRank.fold(String(trimmed)))
        }
        return QuickSwitchQuery(
            filter: filter,
            needle: QuickSwitchRank.fold(String(trimmed.dropFirst()))
        )
    }
}

/// How well a candidate answers what was typed. Ordered worst to best.
public enum QuickSwitchMatch: Int, Hashable, Sendable, Comparable, CaseIterable {
    /// The letters appear in order with anything between them — what finds
    /// `Brandon` from `bro`.
    case subsequence = 0
    /// The letters appear together, somewhere inside.
    case contains = 1
    /// The letters start a word — which for a channel means after a space, a
    /// dash or the emoji people put in front of names.
    case wordPrefix = 2
    /// The letters start the name.
    case prefix = 3
    /// The name is exactly what was typed.
    case exact = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How much the account uses one place, from Discord's own table.
///
/// See `FrecencyProto.guildsAndChannels` for where it comes from: field 12 of
/// the second settings protobuf, a map from a guild **or** channel snowflake to
/// a score Discord maintains and decays server-side. This client reads it and
/// never writes it — the same rule the command table is held to.
public struct PlaceFrecency: Hashable, Sendable {
    /// Discord's own score, 0…1000.
    public var score: Int
    /// The most recent visit, which is what "previous channels" is ordered by.
    public var lastUsedAt: Date?

    public init(score: Int, lastUsedAt: Date? = nil) {
        self.score = score
        self.lastUsedAt = lastUsedAt
    }
}

public enum QuickSwitchRank {

    /// The one fold. Both sides of every comparison go through it, or a needle
    /// and a candidate that differ only in case compare as different bytes.
    ///
    /// Diacritics are folded as well as case, so `cafe` finds `café`. It is an
    /// ICU pass and is therefore done **once per candidate when the snapshot is
    /// built**, never per keystroke.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// How well `candidate` answers `needle`, or nil for no match at all.
    ///
    /// Both arguments must already be folded. The scan is over UTF-8 bytes and
    /// allocates nothing: it is run against every channel in the account on
    /// every keystroke, and a `lowercased()` per candidate there is one string
    /// allocation per channel per character typed.
    public static func match(_ candidate: String, _ needle: String) -> QuickSwitchMatch? {
        guard !needle.isEmpty else { return nil }
        if candidate == needle { return .exact }

        let hay = candidate.utf8
        let pin = needle.utf8
        guard hay.count >= pin.count else { return nil }

        var best: QuickSwitchMatch?
        var index = hay.startIndex
        var previous: UInt8?
        while index < hay.endIndex {
            if hay[index] == pin.first, hay[index...].starts(with: pin) {
                if index == hay.startIndex { return .prefix }
                // A word boundary is anything that is not an ASCII letter or
                // digit — which deliberately includes the bytes of an emoji, so
                // `general` word-matches `🌸 | general` the way a reader expects.
                // The cost is that a letter carrying a diacritic can also read
                // as a boundary; that changes a tier, never a result.
                if let previous, !isWordByte(previous) { return .wordPrefix }
                best = .contains
            }
            previous = hay[index]
            index = hay.index(after: index)
        }
        if let best { return best }
        return isSubsequence(pin, of: hay) ? .subsequence : nil
    }

    /// What the list is ordered by: how well it matched, lifted by how much the
    /// account uses it.
    ///
    /// **Frecency is worth two tiers, and an exact match is out of its reach.**
    /// That is the whole shape of it, and both halves are deliberate.
    ///
    /// The lift is large because of what the table *is*: a hundred places the
    /// account genuinely goes. Three letters typed into a switcher almost always
    /// name one of them, and a cold candidate whose name happens to start with
    /// the same letters is almost never what was meant. It is what the reference
    /// client's own behaviour shows — `bro` puts a server the account lives in
    /// above a game whose name begins with the letters — and it is why the
    /// arithmetic is a weighted sum rather than a tier-then-frecency sort.
    ///
    /// The ceiling is there because the opposite failure is worse: a switcher
    /// that ignores what was typed in favour of what you usually open is a
    /// most-recently-used list wearing a search field. So a maxed `contains`
    /// reaches a cold `prefix` and no further, and somebody who typed a name in
    /// full always gets it.
    public static func score(_ match: QuickSwitchMatch, frecency: Int) -> Int {
        weight(match) + min(max(frecency, 0), 1000) / 25
    }

    /// Twenty points a tier, against a lift of forty.
    private static func weight(_ match: QuickSwitchMatch) -> Int {
        switch match {
        case .subsequence: 0
        case .contains: 20
        case .wordPrefix: 40
        case .prefix: 60
        case .exact: 200
        }
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
    }

    /// Greedy, which is the right answer here: the tier is the same wherever
    /// the letters land, so there is nothing an optimal alignment would buy.
    private static func isSubsequence(_ pin: String.UTF8View, of hay: String.UTF8View) -> Bool {
        var wanted = pin.startIndex
        for byte in hay {
            guard wanted < pin.endIndex else { break }
            if byte == pin[wanted] { wanted = pin.index(after: wanted) }
        }
        return wanted == pin.endIndex
    }
}
