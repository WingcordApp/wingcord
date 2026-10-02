import SwiftUI
import WingcordCore

/// One emoji in a square box, whichever kind it is — and moving, where it is an
/// animated one and the caller lets it.
///
/// A Unicode emoji is **text** and costs a glyph; a custom one is a picture at a
/// known size out of the shared cache. Both appear wherever a status, a chip, a
/// reaction or a line of prose carries one, and there used to be three of these
/// — each with its own answer to the two questions below, and each answer wrong.
///
/// **Both kinds keep their own shape inside the box.** Discord draws every
/// emoji `object-fit: contain`; a custom emoji can be any shape, and a wide one
/// stretched to a square is a different picture. A Unicode glyph is sized by
/// its ink, through `EmojiGlyphMetrics` — the drawn surfaces' own measurement —
/// because Apple's emoji is neither drawn at its point size nor as wide as its
/// advance, and a glyph sized to the box's height was cut off at its sides.
struct ExpressionGlyph: View {
    var emoji: EmojiRef
    var side: CGFloat
    /// Whether an animated custom emoji may play. The reader's own preference
    /// and Reduce Motion are asked after this, by `AnimatedPicture`.
    var plays = false

    var body: some View {
        if let id = emoji.id {
            // **One address for the still and the film.** An animated emoji is
            // a GIF on the CDN: the image store decodes its first frame as the
            // poster and the film plays the same URL, so a still emoji costs no
            // multi-frame decode and no clock to learn what its tag already said.
            AnimatedPicture(
                url: CDN.emoji(id: id, animated: emoji.isAnimated, side: side),
                side: side,
                allowsMotion: plays
            ) {
                // The box is reserved either way, so a line does not reflow
                // when the picture lands.
                Color.clear
            }
        } else {
            Text(emoji.name)
                .font(.system(size: EmojiGlyphMetrics.fitting(emoji.name, side: side).pointSize))
                // At its own width: the advance is wider than the ink and the
                // box, and a `Text` proposed less than its advance cuts it off.
                // What overflows is spacing, and the ink is centred with it.
                .fixedSize()
                .frame(width: side, height: side)
        }
    }
}
