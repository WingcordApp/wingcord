import Foundation

/// Every Unicode emoji the picker offers, by category, with the shortcodes
/// Discord accepts and the skin tone each one can take.
///
/// The data is in `UnicodeEmojiTable.swift` and is generated; this is the whole
/// of the logic over it. See that file for where it comes from.
///
/// **Everything here is built lazily and exactly once.** A Swift `static let` is
/// a thread-safe lazy global, so the parse happens on whichever thread first
/// asks and never again — and nothing asks until a picker opens or somebody
/// types a colon. Nothing in this type is recomputed per keystroke or per frame:
/// the callers that run at those rates (`prefixed(by:)`, `glyph(for:)`) are a
/// binary search and a dictionary lookup over structures built at parse time.
public nonisolated enum UnicodeEmoji {

    /// One emoji, at its default tone.
    public struct Item: Hashable, Sendable, Identifiable {
        /// The glyph itself, with no skin tone applied.
        public let glyph: String
        /// The primary shortcode, without colons — `grinning`, not `:grinning:`.
        public let name: String
        /// Whether this emoji accepts one of the five tone modifiers.
        public let takesSkinTone: Bool

        /// The shortcode is unique across the table and is what a message
        /// carries, so it is the identity. The glyph is not: several names map
        /// to one glyph.
        public var id: String { name }
    }

    /// Unicode's own nine groups, in the order every client shows them.
    public enum Category: Int, CaseIterable, Hashable, Sendable, Identifiable {
        case smileys, people, animals, food, travel, activities, objects, symbols, flags

        public var id: Int { rawValue }

        /// The heading, matching the generated table's own section names.
        public var title: String {
            switch self {
            case .smileys: "Smileys & Emotion"
            case .people: "People & Body"
            case .animals: "Animals & Nature"
            case .food: "Food & Drink"
            case .travel: "Travel & Places"
            case .activities: "Activities"
            case .objects: "Objects"
            case .symbols: "Symbols"
            case .flags: "Flags"
            }
        }

        /// The glyph that stands for the category on a jump bar. Drawn as an
        /// emoji rather than an SF Symbol so the bar reads as being made of the
        /// same material as the grid under it.
        public var symbol: String {
            switch self {
            case .smileys: "😀"
            case .people: "👋"
            case .animals: "🐻"
            case .food: "🍔"
            case .travel: "✈️"
            case .activities: "⚽️"
            case .objects: "💡"
            case .symbols: "❤️"
            case .flags: "🏳️"
            }
        }
    }

    // MARK: The five tones

    /// A Fitzpatrick modifier, or the default yellow.
    public enum SkinTone: Int, CaseIterable, Hashable, Sendable, Identifiable, Codable {
        case `default` = 0, light, mediumLight, medium, mediumDark, dark

        public var id: Int { rawValue }

        /// The modifier scalar, or nil for the default.
        public var modifier: Unicode.Scalar? {
            switch self {
            case .default: nil
            case .light: "\u{1F3FB}"
            case .mediumLight: "\u{1F3FC}"
            case .medium: "\u{1F3FD}"
            case .mediumDark: "\u{1F3FE}"
            case .dark: "\u{1F3FF}"
            }
        }

        /// What the tone looks like in a picker: a raised hand wearing it.
        public var swatch: String { UnicodeEmoji.applying(self, to: "✋") }

        public var title: String {
            switch self {
            case .default: "Default"
            case .light: "Light"
            case .mediumLight: "Medium-Light"
            case .medium: "Medium"
            case .mediumDark: "Medium-Dark"
            case .dark: "Dark"
            }
        }
    }

    /// Applies a tone to a glyph, replacing whatever tone it already carries.
    ///
    /// **Every modifier base in the sequence takes the tone, not just the
    /// first.** A two-person emoji — 👩‍❤️‍👨 — has two of them, and toning only
    /// the leading scalar produces a couple of visibly different skin colours
    /// rather than the variant the reader picked.
    ///
    /// A modifier already present is dropped first, so switching tones is one
    /// operation rather than an accumulation, and applying `.default` is exactly
    /// the same code path as any other tone.
    public static func applying(_ tone: SkinTone, to glyph: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in glyph.unicodeScalars where !scalar.properties.isEmojiModifier {
            out.append(scalar)
            if scalar.properties.isEmojiModifierBase, let modifier = tone.modifier {
                out.append(modifier)
            }
        }
        return String(out)
    }

    // MARK: Lookups

    /// The emoji in one category, in the order the source orders them — which is
    /// the order every other client's picker shows.
    public static func items(in category: Category) -> [Item] { grouped[category.rawValue] }

    /// The glyph for a shortcode, with or without its colons, or nil for a name
    /// this table has never heard of.
    public static func glyph(for shortcode: String) -> String? {
        byName[normalize(shortcode)]?.glyph
    }

    /// The primary shortcode for a glyph, which is what a write needs.
    ///
    /// Tone is stripped first: `👍🏽` and `👍` are the same name, and a toned
    /// glyph that answered nil would be written into a message as raw text.
    public static func shortcode(for glyph: String) -> String? {
        byGlyph[applying(.default, to: glyph)]
    }

    /// The emoji whose shortcodes start with `prefix`, best first.
    ///
    /// This runs on **every keystroke** in the composer, so it is a binary
    /// search into a sorted name index rather than a scan of two thousand
    /// strings. Names are unique, but several map to one glyph — an alias and
    /// its primary would otherwise both be offered, which is one row of the
    /// list spent saying the same thing twice.
    ///
    /// - Parameter limit: How many to return. The list is a popover, not a
    ///   catalogue; past a screenful the rest can only be reached by typing
    ///   more, which is faster than scrolling.
    public static func prefixed(by prefix: String, limit: Int = 24) -> [Item] {
        let needle = normalize(prefix)
        guard !needle.isEmpty else { return [] }

        var results: [Item] = []
        var seen = Set<String>(minimumCapacity: limit)
        results.reserveCapacity(limit)

        var index = lowerBound(of: needle)
        while index < sortedNames.count, sortedNames[index].name.hasPrefix(needle) {
            let item = sortedNames[index].item
            if seen.insert(item.glyph).inserted { results.append(item) }
            if results.count == limit { return results }
            index += 1
        }
        return results
    }

    /// Everything matching a search field's contents, best first: the names that
    /// start with the query, then the ones that merely contain it.
    ///
    /// Unlike `prefixed(by:)` this is driven by a field somebody is looking at
    /// rather than by a keystroke inside a message, so it is allowed to be a
    /// scan — and it has to be, because "smile" should find `smile_cat` as well
    /// as `smiley`.
    public static func search(_ query: String, limit: Int = 300) -> [Item] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }

        var results = prefixed(by: needle, limit: limit)
        guard results.count < limit else { return results }

        var seen = Set(results.map(\.glyph))
        for entry in sortedNames where entry.name.contains(needle) {
            guard seen.insert(entry.item.glyph).inserted else { continue }
            results.append(entry.item)
            if results.count == limit { break }
        }
        return results
    }

    /// Trims the colons and case a shortcode may arrive wearing.
    private static func normalize(_ shortcode: String) -> String {
        var trimmed = Substring(shortcode.lowercased())
        while trimmed.first == ":" { trimmed.removeFirst() }
        while trimmed.last == ":" { trimmed.removeLast() }
        return String(trimmed)
    }

    // MARK: The parse
    //
    // One pass over the table, building everything any caller needs. Split apart
    // into separate lazy globals it would be several passes over the same
    // string, and the four structures would each pay their own parse.

    private struct Parsed {
        var grouped: [[Item]] = Array(repeating: [], count: Category.allCases.count)
        var byName: [String: Item] = [:]
        var byGlyph: [String: String] = [:]
        var sortedNames: [(name: String, item: Item)] = []
    }

    private static let parsed: Parsed = {
        var out = Parsed()
        out.byName.reserveCapacity(2048)
        out.byGlyph.reserveCapacity(1920)
        out.sortedNames.reserveCapacity(2048)

        var category = Category.smileys
        for line in table.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == "#" {
                let title = String(line.dropFirst())
                if let match = Category.allCases.first(where: { $0.title == title }) {
                    category = match
                }
                continue
            }

            var body = line
            let takesSkinTone = body.first == "*"
            if takesSkinTone { body = body.dropFirst() }

            var fields = body.split(separator: " ", omittingEmptySubsequences: true)
            guard let glyph = fields.first.map(String.init) else { continue }
            fields.removeFirst()
            guard let primary = fields.first.map(String.init) else { continue }

            let item = Item(glyph: glyph, name: primary, takesSkinTone: takesSkinTone)
            out.grouped[category.rawValue].append(item)
            // First name wins: the primary is emitted first, and an alias must
            // not overwrite the name the picker shows for the glyph.
            if out.byGlyph[glyph] == nil { out.byGlyph[glyph] = primary }
            for field in fields {
                let name = String(field)
                out.byName[name] = item
                out.sortedNames.append((name, item))
            }
        }

        // Sorted once, so every prefix search after this is a binary search.
        out.sortedNames.sort { $0.name < $1.name }
        return out
    }()

    private static var grouped: [[Item]] { parsed.grouped }
    private static var byName: [String: Item] { parsed.byName }
    private static var byGlyph: [String: String] { parsed.byGlyph }
    private static var sortedNames: [(name: String, item: Item)] { parsed.sortedNames }

    /// The first index whose name is not ordered before `needle`.
    private static func lowerBound(of needle: String) -> Int {
        var low = 0
        var high = sortedNames.count
        while low < high {
            let middle = (low + high) / 2
            if sortedNames[middle].name < needle { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
