import SwiftUI

/// A panel the window raises over everything — the reactions list, the
/// events: a solid surface with a hairline and a shadow, over the dimming
/// scrim the layer draws behind it.
///
/// **Not glass.** These were clear glass with a hand-drawn rim, so the
/// transcript read through a list of names; a modal's content is content, and
/// the HIG's sheet is an opaque surface over a dimmed window. They stay layers
/// rather than sheets for the one reason each records: a profile opened from a
/// row must come up above them in the same window.
struct ModalPanelBackground<S: InsettableShape>: ViewModifier {
    var shape: S

    func body(content: Content) -> some View {
        content
            .background(Palette.surface, in: shape)
            .overlay { shape.strokeBorder(Palette.edge).allowsHitTesting(false) }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }
}

extension View {
    func modalPanel(in shape: some InsettableShape) -> some View {
        modifier(ModalPanelBackground(shape: shape))
    }
}
