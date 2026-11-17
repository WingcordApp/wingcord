import SwiftUI
import WingcordCore

/// One emoji on the packs page: a button with Discord's `:name:` tooltip, a
/// soft plate under the pointer, and a send where the account may use it.
struct EmojiPackCell: View {
    var emoji: EmojiPack.Emoji
    var url: URL?
    var side: CGFloat
    var isEnabled: Bool
    var isUsable: Bool
    var pick: () -> Void

    @State private var isHovered = false

    private var art: CGFloat { (side * 0.8).rounded() }

    var body: some View {
        Button(action: pick) {
            RemoteImage(url: url, side: art) {
                // A soft square while the picture comes, so a row reads as a
                // row of emoji rather than a gap.
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.hoverFill)
            }
            .frame(width: art, height: art)
            .frame(width: side, height: side)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered && isEnabled ? Palette.hoverFill : .clear)
            }
            .contentShape(.rect(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(isUsable ? ":\(emoji.name):" : ":\(emoji.name): · Nitro-exclusive emoji")
        .accessibilityLabel(Text(":\(emoji.name):"))
    }
}
