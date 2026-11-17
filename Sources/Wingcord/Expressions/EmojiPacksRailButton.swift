import SwiftUI

/// The picker rail's way into the Nitro Emoji Packs page: Discord's Nitro
/// mark and its tooltip, "View Nitro Emojis" (`tc` in `web.js`), as a capsule
/// exactly as wide as the rail's pill above it (Alex, 2026-11-17: "the width
/// of the server long pill"), in the rail's own clear glass.
struct EmojiPacksRailButton: View {
    var isShowing: Bool
    var width: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            BrandGlyph(service: BrandMark.nitro)
                .fill(isShowing ? Palette.accent : Ink.secondary)
                .frame(width: 18, height: 18)
                .frame(width: width, height: width + 8)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia(in: .capsule)
        .help("View Nitro Emojis")
        .accessibilityLabel(Text("View Nitro Emojis"))
        .accessibilityAddTraits(isShowing ? [.isSelected] : [])
    }
}
