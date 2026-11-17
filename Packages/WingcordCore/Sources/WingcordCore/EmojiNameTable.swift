import Foundation

/// Every emoji name the reader can type, as Discord names them — its
/// `DisambiguatedEmojiContext` (web.js, 2026-11-17).
///
/// **Unicode first, then everybody else, and a later duplicate is renamed.**
/// Discord counts the Unicode emoji's names before any custom emoji is seen,
/// then walks the current server's emoji, every other server's in the server
/// list's order, then the Nitro Emoji Packs'; an emoji whose name was already
/// taken becomes `name~1`, `name~2`. So `:sob:` is always 😭, and a server's own
/// `sob` is `:sob~1:` — what GitHub #25 asked for ("like it is in the original
/// client"). Before this the app offered custom emoji first and the closing
/// colon took whichever came first.
///
/// **Its search is Discord's too** (`getSearchResultsOrder`): a match anywhere
/// in the name (underscores and spaces ignored), scored
/// `1 + 4·exact + 2·whole word + 1·prefix`, multiplied by how much the reader
/// uses it (frecency score ÷ 100, at least 1), ties by name.
public nonisolated struct EmojiNameTable: Sendable {

    /// Whose emoji it is.
    public enum Owner: Hashable, Sendable {
        case unicode(glyph: String)
        case guild(GuildID)
        case pack(UInt64)
    }

    /// One custom emoji, in the order the table should meet it.
    public struct Custom: Hashable, Sendable {
        public var id: UInt64
        public var name: String
        public var isAnimated: Bool
        public var owner: Owner

        public init(id: UInt64, name: String, isAnimated: Bool, owner: Owner) {
            self.id = id
            self.name = name
            self.isAnimated = isAnimated
            self.owner = owner
        }
    }

    /// One name the reader can type.
    public struct Entry: Hashable, Sendable {
        /// What goes between the colons: Discord's name, `~1` on a duplicate.
        public var name: String
        /// The name the emoji was given, which is what a message carries.
        public var originalName: String
        /// Every other name a Unicode emoji answers to.
        public var aliases: [String]
        public var owner: Owner
        public var id: UInt64?
        public var isAnimated: Bool

        public var glyph: String? {
            if case .unicode(let glyph) = owner { glyph } else { nil }
        }

        /// The key the reader's frecency is kept under: a Unicode emoji's
        /// name, a custom emoji's id.
        public var usageKey: String { id.map(String.init) ?? name }

        /// What a message carries for it.
        public var messageToken: String {
            if let glyph { return glyph }
            return "<\(isAnimated ? "a" : ""):\(originalName):\(id ?? 0)>"
        }
    }

    public private(set) var entries: [Entry] = []
    /// Exact names (and Unicode aliases) to entries.
    private var exact: [String: Int] = [:]
    /// Lowercased names to entries, for a closing colon typed in another case;
    /// nil where two names differ only by case.
    private var folded: [String: Int?] = [:]
    private var byID: [UInt64: Int] = [:]
    /// Per entry, built once: its names lowercased with underscores gone
    /// (what a query is matched against) and its own name lowercased. A
    /// keystroke then compares strings and allocates none.
    private var searchKeys: [(stripped: [String], lower: String)] = []

    /// - Parameters:
    ///   - unicode: every Unicode emoji with its names, Discord's own first.
    ///   - custom: the custom emoji in Discord's order — this server's, the
    ///     other servers' in the server list's order, then the packs'.
    public init(unicode: [(glyph: String, names: [String])], custom: [Custom]) {
        var counts: [String: Int] = [:]
        entries.reserveCapacity(unicode.count + custom.count)
        for emoji in unicode {
            guard let primary = emoji.names.first else { continue }
            counts[primary, default: 0] += 1
            insert(Entry(
                name: primary,
                originalName: primary,
                aliases: Array(emoji.names.dropFirst()),
                owner: .unicode(glyph: emoji.glyph),
                id: nil,
                isAnimated: false
            ))
        }
        for emoji in custom {
            let seen = counts[emoji.name, default: 0]
            counts[emoji.name] = seen + 1
            insert(Entry(
                name: seen > 0 ? "\(emoji.name)~\(seen)" : emoji.name,
                originalName: emoji.name,
                aliases: [],
                owner: emoji.owner,
                id: emoji.id,
                isAnimated: emoji.isAnimated
            ))
        }
    }

    private mutating func insert(_ entry: Entry) {
        let index = entries.count
        entries.append(entry)
        searchKeys.append((
            ([entry.name] + entry.aliases).map { $0.lowercased().replacingOccurrences(of: "_", with: "") },
            entry.name.lowercased()
        ))
        for name in [entry.name] + entry.aliases where exact[name] == nil {
            exact[name] = index
            let lower = name.lowercased()
            if let existing = folded[lower] {
                if existing != nil, existing != index { folded[lower] = .some(nil) }
            } else {
                folded[lower] = index
            }
        }
        if let id = entry.id, byID[id] == nil { byID[id] = index }
    }

    /// The emoji a finished `:name:` stands for: the exact name first, then a
    /// name that differs only by case when exactly one does.
    public func entry(named name: String) -> Entry? {
        if let index = exact[name] { return entries[index] }
        if let index = folded[name.lowercased()] ?? nil { return entries[index] }
        return nil
    }

    /// What a custom emoji is called here — `sob~1` for a duplicate.
    public func name(ofCustom id: UInt64) -> String? {
        byID[id].map { entries[$0].name }
    }

    /// Discord's search, best first.
    ///
    /// - Parameters:
    ///   - offers: whether an entry may be offered here (a locked server's
    ///     emoji is left out, as Discord leaves it out of the unlocked list).
    ///   - score: the reader's frecency score for a usage key, if any.
    public func search(
        _ query: String,
        limit: Int,
        offers: (Entry) -> Bool = { _ in true },
        score: (String) -> Int? = { _ in nil }
    ) -> [Entry] {
        let lowered = query.lowercased()
        let stripped = lowered.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        guard !stripped.isEmpty else { return [] }
        let wholeWord = Self.wholeWordPattern(lowered)
        var scored: [(entry: Entry, value: Double, key: String)] = []
        for (index, entry) in entries.enumerated() {
            let keys = searchKeys[index]
            guard keys.stripped.contains(where: { $0.contains(stripped) }), offers(entry) else { continue }
            let shown = entry.name
            let lowerShown = keys.lower
            var value = 1.0
            if lowerShown == lowered { value += 4 }
            if Self.matches(wholeWord, lowerShown) || Self.matches(wholeWord, shown) { value += 2 }
            if lowerShown.hasPrefix(lowered) { value += 1 }
            if let usage = score(entry.usageKey) { value *= max(1, Double(usage) / 100) }
            scored.append((entry, value, shown))
        }
        scored.sort { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        return Array(scored.prefix(limit).map(\.entry))
    }

    /// `(^|_|[A-Z])query s?([A-Z]|_|$)` — Discord's "a whole word of the name".
    private static func wholeWordPattern(_ query: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: query)
        return try? NSRegularExpression(pattern: "(^|_|[A-Z])\(escaped)s?([A-Z]|_|$)")
    }

    private static func matches(_ pattern: NSRegularExpression?, _ text: String) -> Bool {
        guard let pattern else { return false }
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
