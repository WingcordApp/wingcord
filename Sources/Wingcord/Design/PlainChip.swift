import SwiftUI

/// A chip's ground: roles, connections, tags. **Content, so never glass.**
///
/// Translucent dark grey rather than a fixed colour, which is what the
/// reference chips do (images 19–21 in `docs/references/2026-10-05`): over a
/// person's own colour it reads a step darker than the ground, and over a
/// near-black card a step lighter, so a row of chips sits on whatever profile
/// it is drawn on without carrying a hue of its own.
struct PlainChipBackground<S: InsettableShape>: ViewModifier {
    var shape: S

    func body(content: Content) -> some View {
        content.background(plainChipFill, in: shape)
    }
}

extension View {
    func plainChip(in shape: some InsettableShape) -> some View {
        modifier(PlainChipBackground(shape: shape))
    }
}

/// Dark grey at 60% in a dark room; white at 70% in a light one.
private let plainChipFill = Color.adaptive(
    dark: NSColor(white: 0.16, alpha: 0.6),
    light: NSColor(white: 1, alpha: 0.7)
)
