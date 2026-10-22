import SwiftUI
import WingcordCore

/// A colour, as a button that opens Wingcord's own picker in a flyout — the
/// replacement for the system's `ColorPicker` well everywhere in the profile
/// editor.
struct ColourWellButton: View {
    @Binding var colour: UInt32
    var label: String
    var side: CGFloat = 30
    var fromArtwork: [UInt32] = []

    @Environment(\.motion) private var motion
    @State private var isOpen = false
    @State private var isHovering = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            Circle()
                .fill(Color(hex: colour))
                .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2.5) }
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .scaleEffect(isHovering || isOpen ? 1.08 : 1)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PlayfulColourPicker(colour: $colour, fromArtwork: fromArtwork, title: label)
        }
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(ColourText.name(colour)), \(ColourText.hex(colour))"))
    }
}
