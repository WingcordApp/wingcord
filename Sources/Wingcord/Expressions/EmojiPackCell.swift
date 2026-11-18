import SwiftUI
import WingcordCore

/// One emoji on the packs page: a button with Discord's `:name:` tooltip, a
/// soft plate under the pointer, and a send where the account may use it.
///
/// **An animated one moves**, locked or not, as on Discord's page: its picker
/// asks for the moving picture whenever animation is allowed (Alex,
/// 2026-11-18: "the nitro emoji packs dont seem to animate"), over its still
/// (`StillAndFilm`).
struct EmojiPackCell: View {
    var emoji: EmojiPack.Emoji
    var url: URL?
    var side: CGFloat
    var isEnabled: Bool
    var isUsable: Bool
    var pick: () -> Void

    @Environment(\.motion) private var motion
    @State private var settings = AppSettings.shared
    @State private var isHovered = false

    private var art: CGFloat { (side * 0.8).rounded() }

    /// The picker's own rule (`ExpressionPicker`): the reader's animation
    /// switch and Reduce Motion.
    private var plays: Bool {
        emoji.isAnimated && settings.playsAnimatedMedia && !motion.reduceMotion
    }

    var body: some View {
        Button(action: pick) {
            StillAndFilm(url: url, side: art, plays: plays) {
                // A soft square while the picture comes, so a row reads as a
                // row of emoji rather than a gap.
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.hoverFill)
            }
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
