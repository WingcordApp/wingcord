import SwiftUI
import WingcordCore

/// The `:shortcode` completion that opens over the composer.
///
/// **The query is the trailing token, not the token under the caret**, and that
/// is a deliberate limit rather than an oversight: SwiftUI's `TextField` does
/// not publish a selection, and the alternatives — an `NSTextView`
/// representable, or a caret inferred from keystrokes — are a composer rewrite
/// for a case that barely occurs. People type a shortcode at the end of what
/// they are writing.
nonisolated enum EmojiAutocomplete {

    /// The shortest query worth completing.
    ///
    /// One character matches hundreds of names, which is a list nobody reads and
    /// a popover that opens on every colon typed. Two is what Discord asks for
    /// and it is the point where the list starts being about what you meant.
    static let minimumQueryLength = 2

    /// How many rows the list offers. Past a screenful the rest can only be
    /// reached by typing more, which is faster than scrolling.
    static let limit = 12

    /// The shortcode being typed at the end of `text`, without its colon.
    ///
    /// Nil unless the trailing run really is a shortcode: opened by a colon that
    /// starts the text or follows whitespace, unbroken by a space, and not
    /// already closed by a second colon — `:tada:` is finished, and offering to
    /// complete it again is offering to break it.
    static func query(in text: String) -> String? {
        guard let colon = text.lastIndex(of: ":") else { return nil }

        // A colon that follows a word is part of that word — a URL's scheme, a
        // time, a ratio — not the start of a shortcode.
        if colon > text.startIndex {
            let before = text[text.index(before: colon)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }

        let token = text[text.index(after: colon)...]
        guard token.count >= minimumQueryLength,
              !token.contains(where: { $0.isWhitespace || $0 == ":" })
        else { return nil }
        return String(token).lowercased()
    }

    /// The text with the trailing `:query` replaced by what was chosen.
    ///
    /// A trailing space follows, because a completion is the end of a word and
    /// the next thing typed is a new one.
    static func applying(_ replacement: String, to text: String) -> String {
        guard let colon = text.lastIndex(of: ":") else { return text }
        return text[..<colon] + replacement + " "
    }

    /// What to offer for a query: the account's own emoji first, then Unicode.
    ///
    /// Custom emoji lead because they are the ones a shortcode is *needed* for —
    /// a Unicode emoji can also be typed straight into the field, and a server's
    /// cannot.
    static func matches(
        for query: String,
        custom: [ExpressionSection],
        limit: Int = limit
    ) -> [ExpressionItem] {
        var results: [ExpressionItem] = []
        results.reserveCapacity(limit)

        outer: for section in custom where !section.isLocked {
            for item in section.items where item.name.hasPrefix(query) {
                results.append(item)
                if results.count == limit { break outer }
            }
        }
        guard results.count < limit else { return results }

        for item in UnicodeEmoji.prefixed(by: query, limit: limit - results.count) {
            results.append(ExpressionItem(
                id: item.name,
                art: .glyph(item.glyph),
                name: item.name,
                pick: .insert(item.glyph)
            ))
        }
        return results
    }
}

/// The list itself, floating over the transcript above the composer.
///
/// Keyboard-first: the arrow keys move the selection, Return and Tab commit, and
/// Escape dismisses. A completion list you have to reach for with the pointer is
/// slower than typing the emoji's name out.
struct EmojiAutocompleteList: View {
    var query: String
    var items: [ExpressionItem]
    var selection: Int
    var onPick: (ExpressionItem) -> Void
    var onHover: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("EMOJI MATCHING  :\(query)")
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, Spacing.snug)
                .padding(.top, Spacing.base)
                .padding(.bottom, Spacing.tight)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item, isSelected: index == selection)
                    .onHover { if $0 { onHover(index) } }
                    .onTapGesture { onPick(item) }
            }
        }
        .padding(.bottom, Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func row(_ item: ExpressionItem, isSelected: Bool) -> some View {
        HStack(spacing: Spacing.base) {
            art(item.art)
                .frame(width: 20, height: 20)
            Text(":\(item.name):")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: 28)
        .background(isSelected ? Palette.selectionFill : .clear)
        .contentShape(.rect)
    }

    @ViewBuilder
    private func art(_ art: ExpressionItem.Art) -> some View {
        switch art {
        case .glyph(let glyph):
            Text(glyph).font(.system(size: 16))
        case .image(let url, _):
            // Still, even for an animated emoji: this is a list of twelve rows
            // that exists for a couple of keystrokes, and a filmstrip each is a
            // decode nobody sees finish.
            RemoteImage(url: url, side: 20) { Color.clear }
        }
    }
}
