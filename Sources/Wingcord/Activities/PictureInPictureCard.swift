import SwiftUI

/// The picture in picture's card: the live frame, rounded, with its controls
/// (Return to Activity, Pop Out, Leave) on glass while the pointer is over it.
struct PictureInPictureCard: View {
    var name: String
    var iconURL: URL?
    var runtime: ActivityRuntime
    var isReady: Bool

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .top) {
            Palette.surfaceRaised
            ActivityWebView(runtime: runtime)
                .opacity(isReady ? 1 : 0)
            ActivityControlBar(name: name, iconURL: iconURL, showsPopOut: true, showsReturn: true)
                .padding(Spacing.tight)
                .opacity(isHovering ? 1 : 0)
        }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.edge, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(name), picture in picture"))
    }
}
