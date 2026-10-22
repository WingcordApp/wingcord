import WingcordCore

extension EmojiRef {
    /// What an emoji picker handed back, as the wire's own emoji reference.
    ///
    /// **A custom emoji is an id, a name and whether it moves**; a Unicode one
    /// is the glyph and nothing else. The picker hands back what it would type
    /// into the composer, so the id comes off the item rather than out of the
    /// string — parsing `<a:name:id>` back apart would be building a shape this
    /// side of the app already has. Nil for anything that is not an emoji.
    init?(picked item: ExpressionItem) {
        guard case .insert(let inserted) = item.pick else { return nil }
        if case .image(_, let animated) = item.art, let id = UInt64(item.id) {
            self.init(id: EmojiID(rawValue: id), name: item.name, isAnimated: animated)
        } else {
            self.init(name: inserted)
        }
    }
}
