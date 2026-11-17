import SwiftUI

/// The frosted ground under a call in a conversation: the band, and the
/// pre-join row.
///
/// **A standard material, not Liquid Glass**, and that's the HIG rather than a
/// preference: the band holds content — faces, video — and "Don't use Liquid
/// Glass in the content layer"; its controls float over it as glass. There is
/// no thicker Liquid Glass to reach for either: SwiftUI's `Glass` and AppKit's
/// `NSGlassEffectView` have only regular and clear. **Thick**, because the
/// transcript scrolls under it and Alex wanted it frosted, not see-through
/// (2026-11-17: "i wanted blur") — thicker materials keep fine detail legible
/// over busy content. Reduce Transparency makes it opaque by itself.
struct CallBandGround: View {
    var body: some View {
        Rectangle()
            .fill(.thickMaterial)
            // The band's edge against the conversation under it.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Palette.edge)
                    .frame(height: 1)
            }
            .accessibilityHidden(true)
    }
}
