import SwiftUI

/// The fill a capsule region draws under the pointer and under a press.
///
/// **A press state on every one** (HIG, Buttons: "Always give a custom button a
/// press state"), shown on the way down rather than on release.
struct CallRegionStyle: ButtonStyle {
    enum Part {
        /// A disc on its own.
        case whole
        /// The disc half of a control with a ▾.
        case leading
        /// The ▾ half.
        case trailing
    }

    var part: Part
    var isActive: Bool
    var isLeave: Bool

    func makeBody(configuration: Configuration) -> some View {
        CallRegionBody(
            label: configuration.label,
            part: part,
            isActive: isActive,
            isLeave: isLeave,
            isPressed: configuration.isPressed
        )
    }
}

private struct CallRegionBody<Label: View>: View {
    var label: Label
    var part: CallRegionStyle.Part
    var isActive: Bool
    var isLeave: Bool
    var isPressed: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        label
            .background {
                ZStack {
                    // Leave is red at all times: the one emphasised control in
                    // the capsule, and the one that can't be undone by pressing
                    // it again.
                    if isLeave {
                        shape.fill(Palette.destructive)
                    }
                    shape.fill(overlay)
                }
                .padding(insets)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
            .animation(motion.hover, value: isHovering)
    }

    /// Light over a quiet region, shade over a lit one or over Leave's red, so
    /// the answer reads on every ground.
    private var overlay: Color {
        guard isEnabled else { return .clear }
        if isLeave || isActive {
            if isPressed { return .black.opacity(0.18) }
            return isHovering ? (isLeave ? .white.opacity(0.14) : .black.opacity(0.08)) : .clear
        }
        if isPressed { return CallButtonLook.regionPressed }
        return isHovering ? CallButtonLook.regionHovered : .clear
    }

    private var shape: AnyShape {
        let radius = CallCapsuleMetrics.disc / 2
        return switch part {
        // **A capsule, not a circle** (Alex, 2026-11-18, his Image 151): in
        // the call capsule's square slots the two are the same shape, but the
        // activity capsule's Leave carries its word, and a circle fitted to a
        // wide label is a red disc behind half of it.
        case .whole: AnyShape(Capsule())
        case .leading:
            AnyShape(UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius))
        case .trailing:
            AnyShape(UnevenRoundedRectangle(bottomTrailingRadius: radius, topTrailingRadius: radius))
        }
    }

    /// Two points in from the slot, except where the two halves of a split
    /// control meet.
    private var insets: EdgeInsets {
        let inset = CallCapsuleMetrics.fillInset
        return switch part {
        case .whole: EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
        case .leading: EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: 0)
        case .trailing: EdgeInsets(top: inset, leading: 0, bottom: inset, trailing: inset)
        }
    }
}
