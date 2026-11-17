import SwiftUI

/// One of the popout's five emoji — Discord's `d7`: no plate, 24 points, a
/// spring to 1.14 under the pointer, "Reply with :name:".
struct ActivityEmojiButton: View {
    var item: ExpressionItem
    var isEnabled: Bool
    var send: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: send) {
            art
                .frame(width: 28, height: 28)
                .scaleEffect(isHovered && !motion.reduceMotion ? 1.14 : 1)
                .animation(.spring(response: 0.24, dampingFraction: 0.62), value: isHovered)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help("Reply with :\(item.name):")
        .accessibilityLabel(Text("Reply with \(item.name)"))
    }

    @ViewBuilder
    private var art: some View {
        switch item.art {
        case .glyph(let glyph):
            Text(glyph).font(.system(size: 22))
        case .image(let url, _):
            RemoteImage(url: url, side: 24) { Color.clear }
                .frame(width: 24, height: 24)
        }
    }
}
