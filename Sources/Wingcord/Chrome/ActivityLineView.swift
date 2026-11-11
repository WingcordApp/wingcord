import SwiftUI
import WingcordCore

/// Discord's `ActivityStatus` in SwiftUI: the line under a name in the
/// direct-message list and in the now bar.
///
/// **The member list draws the same value into its canvas** —
/// `MemberRowPainter.drawActivityLine` — and the two follow one arrangement:
/// the glyph, the lead's words, a count, a bullet, then the status's emoji and
/// words. **Only words give way.** Every other piece is fixed-size, so a long
/// title truncates instead of pushing the count off the end.
struct ActivityLineView: View {
    var line: ActivityStatusLine
    var ink: Color = Ink.tertiary
    /// A custom status's emoji, at about the line's own height.
    var emojiSide: CGFloat = 11
    /// Whether an animated status emoji moves: under the pointer, as Discord's
    /// rows play theirs. A column of them all moving is the list §4.6 forbids.
    var playsEmoji = false

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if let glyph = line.glyph {
                Image(symbol: glyph.symbolName)
                    .imageScale(.small)
                    .foregroundStyle(Palette.presenceOnline)
            }
            if let text = line.text {
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if line.overflow > 0 {
                // Green once the status has the words — Discord's colour for it,
                // and what keeps a bare count from reading as a stray digit.
                Text("+\(line.overflow)")
                    .foregroundStyle(
                        line.statusText != nil ? AnyShapeStyle(Palette.presenceOnline) : AnyShapeStyle(ink)
                    )
                    .fixedSize()
            }
            if line.hasLead && line.hasStatus {
                Text("•")
                    .fixedSize()
            }
            if let emoji = line.statusEmoji {
                ExpressionGlyph(emoji: emoji, side: emojiSide, plays: playsEmoji)
                    .fixedSize()
            }
            if let statusText = line.statusText {
                Text(statusText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(Typeface.rowSubtitle)
        .foregroundStyle(ink)
        // One node, one sentence — "Playing Counter-Strike 2, back in 10" —
        // rather than a glyph, a count and a bullet read out one by one.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(line.spokenText))
    }
}
