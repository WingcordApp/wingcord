import Foundation

/// Whether a message is nothing but emoji, and how many.
///
/// Discord draws a message made only of emoji at roughly three times the size —
/// a "Nice" 👍 at body size is a full stop, and at jumbo size it is the message.
/// Every client does this and a reader who has seen one expects it everywhere,
/// so a client that draws a lone emoji at 20pt reads as broken rather than as
/// restrained.
///
/// **Decided on the parsed tree, not on the raw text.** The raw string for a
/// custom emoji is `<:name:id>`, which is not emoji by any character test, and
/// the raw string for `:thumbsup:` is a shortcode Discord expands server-side.
/// The tree is the only place both forms are already resolved to what they are.
extension MarkdownDocument {

    /// The most emoji a message may hold and still be drawn large.
    ///
    /// Discord's own ceiling. Past it the row is a wall of pictures rather than
    /// a message, and a mosaic posted as a hundred squares would take a
    /// screen-height row.
    public static let jumboEmojiLimit = 27

    /// The number of emoji when this document is **only** emoji, otherwise nil.
    ///
    /// Nil and zero are different answers and both are "draw it normally", so
    /// the caller never has to know which — but the count is what a future
    /// size ramp would need, and deriving it here costs nothing over deciding
    /// the boolean.
    public var jumboEmojiCount: Int? {
        // One paragraph. A heading, a quote, a list or a code block is
        // structure, and structure means the message is saying something the
        // emoji are only part of.
        guard blocks.count == 1, case .paragraph(let nodes) = blocks[0] else { return nil }

        var count = 0
        for node in nodes {
            switch node {
            case .customEmoji:
                count += 1
            case .text(let value):
                guard let emoji = Self.emojiOnlyCount(value) else { return nil }
                count += emoji
            case .lineBreak:
                // A newline between emoji is still only emoji.
                continue
            default:
                return nil
            }
            if count > Self.jumboEmojiLimit { return nil }
        }
        return count > 0 ? count : nil
    }

    /// The emoji clusters in a run of text, or nil if it holds anything else.
    ///
    /// Whitespace is allowed and not counted: people separate emoji with spaces,
    /// and a space is not a reason to shrink the message.
    private static func emojiOnlyCount(_ text: String) -> Int? {
        var count = 0
        for character in text {
            if character.isWhitespace { continue }
            guard character.isEmojiCluster else { return nil }
            count += 1
        }
        return count
    }
}

extension Character {
    /// Whether this grapheme cluster renders as an emoji.
    ///
    /// **A single scalar is tested for emoji *presentation*, not for
    /// `isEmoji`.** The digits, `#` and `*` all report `isEmoji` true — they are
    /// the bases of the keycap sequences — so a test on that alone calls "2025"
    /// a row of emoji and draws a year at forty-eight points.
    ///
    /// A multi-scalar cluster is a sequence: a flag, a keycap, a skin-toned
    /// person, a ZWJ family. Those are emoji when the cluster carries emoji
    /// presentation anywhere in it, which is what the variation selector and the
    /// modifiers are for.
    public var isEmojiCluster: Bool {
        var scalars = unicodeScalars.makeIterator()
        guard let first = scalars.next() else { return false }
        guard scalars.next() != nil else { return first.properties.isEmojiPresentation }
        guard first.properties.isEmoji else { return false }
        return unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.value == 0xFE0F
        }
    }
}
