import SwiftUI

/// The card the sidebar's foot is built from: the call above, the reader's own
/// identity below.
///
/// **Opaque, and under the list rather than over it.** Both used to be clear
/// glass floating over the channel list, so channel names read through the call
/// panel and the panel's own rows looked misplaced against them. Neither is
/// content the reader scrolls past: they are fixed controls at the column's
/// foot, and the list now ends above them. A solid raised surface with a
/// hairline edge is what a fixed card is, in both appearances.
struct SidebarCardBackground: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Palette.edge)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func sidebarCard(cornerRadius: CGFloat) -> some View {
        modifier(SidebarCardBackground(cornerRadius: cornerRadius))
    }
}
