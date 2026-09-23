import CoreGraphics
import Foundation

// MARK: - What the picker draws
//
// Plain values, built once per change and handed to a view that holds no model
// reference — the same shape the member list and the sidebar already take. The
// grid is the densest surface in the app after the transcript: an account in a
// hundred servers has tens of thousands of custom emoji, and rebuilding these
// arrays per frame is what makes a picker that opens instantly scroll like tar.

/// Which of the three tabs the picker is showing.
enum ExpressionMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case emoji = "Emoji"
    case stickers = "Stickers"
    case gifs = "GIFs"

    var id: String { rawValue }

    var searchPlaceholder: String {
        switch self {
        case .emoji: "Search emoji"
        case .stickers: "Search stickers"
        case .gifs: "Search GIFs"
        }
    }
}

/// One cell.
///
/// **A glyph or a picture, never both, and the difference is the whole reason
/// the picker can draw a Unicode grid without touching the network.** A Unicode
/// emoji is text: it costs a `CTLine` and nothing else. A custom emoji or a
/// sticker is a remote image at a known size.
struct ExpressionItem: Hashable, Sendable, Identifiable {
    enum Art: Hashable, Sendable {
        /// Drawn as text, at the cell's size.
        case glyph(String)
        /// Fetched and drawn as a picture. `animated` decides which store is
        /// asked for it — a filmstrip and a single frame are different decodes
        /// of the same URL and live in different caches.
        case image(URL?, animated: Bool)
    }

    /// Stable across a rebuild: a snowflake for anything a server owns, and the
    /// shortcode for a Unicode emoji, which is unique in the generated table.
    var id: String
    var art: Art
    /// What the search field matches against, and what the tooltip says.
    var name: String
    /// What picking it does.
    var pick: Pick

    enum Pick: Hashable, Sendable {
        /// Typed into the composer — a Unicode glyph or `<:name:id>`.
        case insert(String)
        /// Sent on its own. A sticker is a message, not text.
        case sticker(UInt64)
    }
}

/// What the picker's footer says about the item under the pointer.
///
/// A value rather than the item and its section, because the footer needs four
/// small things and a section carries every emoji in a server — holding one in
/// view state to read its title would retain the whole array.
struct ExpressionHover: Hashable, Sendable {
    var art: ExpressionItem.Art
    var name: String
    /// Whether the name is a shortcode. Emoji have one and are written with
    /// their colons; a sticker is picked by name and has none, so wrapping it
    /// in colons invents a syntax that would not work if anybody typed it.
    var hasShortcode: Bool
    var source: String
    var sourceBadge: ExpressionSection.Badge
}

/// One labelled run of the grid, and one icon on the rail.
///
/// A section is a **server** on the sticker and custom-emoji tabs and a
/// **Unicode category** on the rest of the emoji tab. Both draw identically, so
/// the grid and the rail never need to know which they are showing.
struct ExpressionSection: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    /// The rail's icon: a server's own artwork, or a category's glyph.
    enum Badge: Hashable, Sendable {
        case image(URL?, monogram: String)
        case glyph(String)
    }
    var badge: Badge
    var items: [ExpressionItem]
    /// This server's expressions cannot be used from the channel the picker was
    /// opened over — another server's, without Nitro.
    ///
    /// **One flag per section rather than one per item.** It is a fact about the
    /// server, and an account with twenty thousand emoji should not carry twenty
    /// thousand copies of it.
    var isLocked: Bool = false
}

/// Everything one tab needs, built together so the rail and the grid cannot
/// disagree about what is in the picker.
struct ExpressionCatalog: Hashable, Sendable {
    var sections: [ExpressionSection] = []

    /// The sections whose items match a query, flattened to the matches
    /// themselves.
    ///
    /// Searching collapses the headings: a result's server matters much less
    /// than the match, and keeping the sections leaves a screenful of one-item
    /// headings. The empty query is the identity, so a picker at rest pays
    /// nothing for the search field existing.
    func filtered(by query: String) -> [ExpressionSection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sections }

        var matches: [ExpressionItem] = []
        var seen = Set<String>()
        for section in sections {
            for item in section.items where item.name.contains(needle) {
                guard seen.insert(item.id).inserted else { continue }
                matches.append(item)
            }
        }
        guard !matches.isEmpty else { return [] }
        return [ExpressionSection(
            id: "results",
            title: "Results",
            badge: .glyph("🔍"),
            items: matches
        )]
    }
}
