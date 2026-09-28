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

    /// A shortcode the reader has **finished** typing at the end of `text`.
    ///
    /// **`:sob:`, not `:sob`.** The open form is what the completion list
    /// offers; this is the one somebody typed all the way through and expects to
    /// have become an emoji — which is what Discord does, and what pressing Tab
    /// was the only way to get here.
    ///
    /// The same boundary rules as `query`, plus the closing colon: a run with no
    /// whitespace in it, opened by a colon that starts the text or follows
    /// whitespace. `12:30:` is not a shortcode, and neither is `https://a:b:`.
    static func closedShortcode(in text: String) -> String? {
        guard text.hasSuffix(":") else { return nil }
        let body = text.dropLast()
        guard let colon = body.lastIndex(of: ":") else { return nil }
        if colon > body.startIndex {
            let before = body[body.index(before: colon)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let token = body[body.index(after: colon)...]
        guard token.count >= minimumQueryLength,
              !token.contains(where: { $0.isWhitespace || $0 == ":" })
        else { return nil }
        return String(token).lowercased()
    }

    /// The text with a finished `:name:` replaced by what it names.
    ///
    /// **No trailing space.** `applying` adds one because a completion ends a
    /// word the reader was still typing; this one is typed *past* — they have
    /// already said where it ends — and adding a space would put one where they
    /// did not.
    static func applyingClosed(_ replacement: String, to text: String) -> String {
        let body = text.dropLast()
        guard let colon = body.lastIndex(of: ":") else { return text }
        return body[..<colon] + replacement
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
    /// cannot. The catalog is already in that order, so one walk gives it.
    ///
    /// **One pass over the catalog, and a set, and each fixes a real
    /// duplicate.**
    ///
    /// This used to walk the catalog and *then* append
    /// `UnicodeEmoji.prefixed(by:)`, on the reading that the catalog held the
    /// account's custom emoji and Unicode had to be added. It has not held
    /// only custom emoji for a long time: `EmojiCatalog` appends the nine
    /// Unicode category sections itself, so every Unicode match was found
    /// twice and `:cry` listed `:cry:`, `:crying_cat_face:` and
    /// `:crystal_ball:` two times each. The second pass is gone.
    ///
    /// The `seen` set covers the other duplicate, which is not the same bug
    /// and would have survived the fix: **the same custom emoji in two
    /// servers**. An account in two servers that both use `:blobcat:` has two
    /// catalog entries with two ids and one name, and a list offering the
    /// reader the same picture twice is a choice with no difference in it.
    static func matches(
        for query: String,
        custom: [ExpressionSection],
        limit: Int = limit
    ) -> [ExpressionItem] {
        var results: [ExpressionItem] = []
        results.reserveCapacity(limit)
        var seen = Set<String>()

        for section in custom where !section.isLocked {
            for item in section.items where !item.isLocked && item.name.hasPrefix(query) {
                guard seen.insert(item.name).inserted else { continue }
                results.append(item)
                if results.count == limit { return results }
            }
        }
        return results
    }
}

/// The list itself, floating over the transcript above the composer.
///
/// **Glass, like every other floating surface in this app.** It used to be a
/// flat `surfaceRaised` panel with a hairline — a solid slab hanging over a
/// scrolling transcript, which is the one composition `INVARIANTS.md` §4 rule 3
/// singles out: an opaque fill behind a floating surface is what stops it
/// reading as glass at all. It sits directly on top of the composer, which is
/// `.regular` glass over the reading surface, so it takes the same material and
/// the two read as one object growing upward.
///
/// **The selection is a travelling pill in a shared namespace** — one shape
/// matched across the rows rather than a fill that appears and disappears per
/// row, so moving down the list is one mark sliding rather than twelve fading in
/// and out behind the pointer. It is a tinted region *inside* the panel's
/// material and not a second glass body on it; see `row`.
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

    @Environment(\.motion) private var motion
    @Namespace private var selectionNamespace

    /// The art beside a row. Sized to the row rather than to the glyph, so a
    /// custom emoji and a Unicode one occupy the same column.
    private static let artSide: CGFloat = 20
    private static let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // No container around these rows. A `GlassEffectContainer`
            // PROMOTES its glass elements above ordinary siblings and renders
            // them itself — §4 rule 4 — so a pill living in a row's
            // `.background` would be lifted above the emoji and the shortcode it
            // is meant to sit behind. There is no glass in here to contain
            // anyway; see `row`.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item, isSelected: index == selection)
                        .onHover { if $0 { onHover(index) } }
                        .onTapGesture { onPick(item) }
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.bottom, Spacing.base)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .animation(motion.glassMorph, value: selection)
        .accessibilityLabel(Text("Emoji matching \(query)"))
    }

    /// What the list is answering.
    ///
    /// The query is repeated back because the trailing token is what the list is
    /// derived from, and a reader who typed `:sob` after a URL needs to see
    /// *which* token was taken.
    private var header: some View {
        Text("MATCHING  :\(query)")
            .font(Typeface.sectionHeader)
            .foregroundStyle(Ink.tertiary)
            .padding(.horizontal, Spacing.snug)
            .padding(.top, Spacing.snug)
            .padding(.bottom, Spacing.base)
            .accessibilityHidden(true)
    }

    private func row(_ item: ExpressionItem, isSelected: Bool) -> some View {
        HStack(spacing: Spacing.base) {
            art(item.art)
                .frame(width: Self.artSide, height: Self.artSide)
            Text(":\(item.name):")
                .font(.system(.subheadline))
                .foregroundStyle(isSelected ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: Self.rowHeight)
        .background {
            if isSelected {
                // **A tinted region inside the panel's material, not a second
                // glass body on top of it.** The panel is already `.regular`
                // glass, so a `.glassEffect` here would be glass on glass — §4
                // rule 2 — and the inner surface would have the outer one's
                // blurred output to sample rather than what is behind the
                // window, which reads as a flat lighter slab. This is the same
                // shape the now bar's controls take for the same reason.
                //
                // It travels rather than fading: one shape moving between slots,
                // matched across the rows, so running down the list is a mark
                // sliding instead of twelve appearing and disappearing behind
                // the pointer.
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Palette.selectionFill)
                    .matchedGeometryEffect(id: Self.selectionID, in: selectionNamespace)
            }
        }
        .contentShape(.rect)
    }

    /// One id for the one pill. A constant, because there is only ever a single
    /// selection and giving each row its own id would make the mark cut rather
    /// than travel.
    private static let selectionID = "emoji.completion.selection"

    @ViewBuilder
    private func art(_ art: ExpressionItem.Art) -> some View {
        switch art {
        case .glyph(let glyph):
            Text(glyph).font(.system(size: 16))
        case .image(let url, _):
            // Still, even for an animated emoji: this is a list of twelve rows
            // that exists for a couple of keystrokes, and a filmstrip each is a
            // decode nobody sees finish.
            RemoteImage(url: url, side: Self.artSide) { Color.clear }
        }
    }
}
