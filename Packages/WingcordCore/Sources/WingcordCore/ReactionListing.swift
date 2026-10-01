import Foundation

/// One entry down the side of the reactors list: an emoji, in one of its two
/// halves, and how many are in it.
///
/// **Discord's own split and order** (the reactors modal, `112753`): an emoji
/// that has super reactions and plain ones is two entries, the super one first,
/// and the whole list is sorted by count, largest first — ties keeping the
/// order the message has them in.
public struct ReactionListing: Hashable, Sendable, Identifiable {
    public var emoji: EmojiRef
    public var kind: ReactionKind
    public var count: Int
    /// The super reaction's colours, for a super entry.
    public var burstColors: [UInt32]

    public var id: Key { Key(emoji: emoji.reactionKey, kind: kind) }

    public struct Key: Hashable, Sendable {
        public var emoji: ReactionEmojiKey
        public var kind: ReactionKind

        public init(emoji: ReactionEmojiKey, kind: ReactionKind) {
            self.emoji = emoji
            self.kind = kind
        }
    }

    public static func entries(of reactions: [Reaction]) -> [ReactionListing] {
        var entries: [ReactionListing] = []
        for reaction in reactions {
            if reaction.burstCount > 0 {
                entries.append(ReactionListing(
                    emoji: reaction.emoji, kind: .burst,
                    count: reaction.burstCount, burstColors: reaction.burstColors
                ))
            }
            if reaction.count > 0 {
                entries.append(ReactionListing(
                    emoji: reaction.emoji, kind: .normal, count: reaction.count, burstColors: []
                ))
            }
        }
        // Stated as a tie-break rather than trusted to the sort: Discord's
        // `Array.sort` is stable and the order it keeps is part of the list.
        return entries.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element)
    }
}
