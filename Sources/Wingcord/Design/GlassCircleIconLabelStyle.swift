import SwiftUI

/// An icon-only label for a glass circle: the glyph at one size in one box, so
/// every circle is the same circle whatever symbol sits in it.
///
/// **The stock circle hugs its symbol.** `.buttonStyle(.glass)` with
/// `.buttonBorderShape(.circle)` around a bare `.iconOnly` label sizes the
/// circle from the symbol at its own size, so a wide one — the diagonal
/// expand arrows — fills its circle edge to edge while a narrow one floats in a
/// smaller one (Alex, 2026-11-18: the trailer's enlarge button and the
/// picture-in-picture bars). `INVARIANTS.md`: an icon-only glass circle takes a
/// fixed glyph and a fixed box — this, `MediaGlassButton` over media, or
/// `HeaderCircleButton` in a header.
///
/// The title stays the label's accessible name: the box is drawn inside an
/// `.iconOnly` label rather than in place of one.
struct GlassCircleIconLabelStyle: LabelStyle {
    /// The glyph's box; the glass adds its own margin around it.
    static let box: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
                .font(Typeface.controlGlyph)
                .frame(width: Self.box, height: Self.box)
        }
        .labelStyle(.iconOnly)
    }
}

extension LabelStyle where Self == GlassCircleIconLabelStyle {
    /// See `GlassCircleIconLabelStyle`.
    static var glassCircleIcon: GlassCircleIconLabelStyle { GlassCircleIconLabelStyle() }
}
