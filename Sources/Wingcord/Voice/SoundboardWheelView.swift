import SwiftUI
import WingcordCore

// MARK: - The wheel, drawn
//
// Discord's geometry (`SoundboardWheelLayout`): a 288-point wheel, a ring
// 40 points thick at a radius of 104, eight 96 × 52 sounds round it, the dead
// zone in the middle, and a dot that follows the pointer's travel at half its
// distance. In the glass language: the ring is clear glass — it sits over a
// game — the sounds are glass plates, and the one pointed at takes the
// accent.

struct SoundboardWheelView: View {
    var controller: SoundboardWheelController
    @Environment(\.motion) private var motion

    private let side = SoundboardWheelLayout.wheelSide

    var body: some View {
        ZStack(alignment: .topLeading) {
            ring
            middle
            if let sounds = controller.pages[safe: controller.page] {
                GlassEffectContainer(spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(sounds.enumerated()), id: \.element.id) { slot, sound in
                            let frame = SoundboardWheelLayout.frame(of: slot, side: side)
                            WheelSound(sound: sound, isFocused: controller.focused == slot) {
                                controller.choose(slot)
                            }
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                        }
                    }
                }
                .frame(width: side, height: side, alignment: .topLeading)
            }
        }
        .frame(width: side, height: side)
        .environment(\.controlActiveState, .active)
        .animation(motion.hover, value: controller.focused)
        .animation(motion.standard, value: controller.page)
    }

    private var ring: some View {
        Circle()
            .strokeBorder(Color.black.opacity(0.28), lineWidth: 40)
            .frame(width: 248, height: 248)
            .glassEffect(.clear, in: Circle())
            .frame(width: side, height: side)
            .allowsHitTesting(false)
    }

    /// The dead zone, the pointer's dot, and — on a wheel of several pages —
    /// Discord's "Scroll for more".
    private var middle: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.35))
                .frame(width: 58, height: 58)
            if controller.focused == nil {
                Image(systemName: controller.isHolding ? "hand.point.up.left" : "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Circle()
                .fill(Palette.accent)
                .frame(width: 10, height: 10)
                .offset(x: controller.offset.dx / 2, y: controller.offset.dy / 2)
            if controller.pages.count > 1 {
                Text("Scroll for more")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: .capsule)
                    .offset(y: 44)
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One sound: its emoji over its name, Discord's `.soundButton` shape.
private struct WheelSound: View {
    var sound: SoundboardPresentation.Entry
    var isFocused: Bool
    var play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(spacing: 1) {
                emoji
                Text(sound.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isFocused ? .regular.tint(Palette.accent.opacity(0.7)).interactive() : .regular.interactive(),
            in: .rect(cornerRadius: 12)
        )
        .scaleEffect(isFocused ? 1.06 : 1)
        .accessibilityLabel(sound.name)
        .accessibilityAddTraits(isFocused ? [.isSelected] : [])
    }

    @ViewBuilder private var emoji: some View {
        if let url = sound.emojiURL {
            RemoteImage(url: url, side: 20) { Color.clear }
                .frame(width: 20, height: 20)
        } else if let emoji = sound.emoji {
            Text(emoji)
                .font(.system(size: 17))
        } else {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}
