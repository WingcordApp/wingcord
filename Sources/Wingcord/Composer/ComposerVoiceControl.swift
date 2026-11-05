import SwiftUI

/// The one button that's a mic, then stop, then play and pause.
///
/// **One view through all of it**, so the symbol changes in place and nothing has to be
/// matched up afterwards. Stop is red glass rather than a red disc: the tint goes in the
/// material, the way every other emphasis here does.
///
/// **The glass comes and goes as a body of its own.** Swapping the modifier between a tinted
/// glass and `.identity` isn't interpolated: the red was there one frame and gone the next.
/// As a disc behind the glyph it scales and fades on the composer's spring.
struct ComposerVoiceControl: View {
    enum Mode: Hashable {
        case mic, stop, play, pause

        var symbol: String {
            switch self {
            case .mic: "mic.fill"
            case .stop: "stop.fill"
            case .play: "play.fill"
            case .pause: "pause.fill"
            }
        }

        var label: String {
            switch self {
            case .mic: "Record Voice Message"
            case .stop: "Stop Recording"
            case .play: "Play Voice Message"
            case .pause: "Pause Voice Message"
            }
        }
    }

    var mode: Mode
    /// The side while it's stop. Messages' sits at the capsule's end where the send disc
    /// sits, so it takes that disc's size; everywhere else it's a control among controls.
    var stopSide: CGFloat
    var action: () -> Void

    @Environment(\.motion) private var motion
    private var reduceMotion: Bool { motion.reduceMotion }
    @State private var isHovering = false

    private var side: CGFloat { mode == .stop ? stopSide : Metrics.composerControl }

    var body: some View {
        Button(action: action) {
            glyph
                .frame(width: side, height: side)
                .background { hoverFill }
                .contentShape(.circle)
        }
        .buttonStyle(ComposerVoicePressStyle())
        .background {
            if mode == .stop {
                Color.clear
                    .frame(width: side, height: side)
                    .glassEffect(.regular.tint(Color.red.opacity(0.75)), in: .circle)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(height: Metrics.composerControlHeight)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .help(mode.label)
        .accessibilityLabel(Text(mode.label))
    }

    @ViewBuilder
    private var glyph: some View {
        let image = Image(systemName: mode.symbol)
            .font(.system(size: mode == .stop ? 13 : mode == .mic ? 18 : 16, weight: .medium))
            .foregroundStyle(mode == .stop ? AnyShapeStyle(.white) : AnyShapeStyle(InkColor.solid))
        if reduceMotion {
            image.contentTransition(.opacity)
        } else {
            image.contentTransition(.symbolEffect(.replace))
        }
    }

    private var hoverFill: some View {
        Circle().fill(isHovering && mode != .stop ? Color.relative(dark: 0.14, light: 0.10) : .clear)
    }
}

/// A press answered at once. The glass behind the stop glyph is a body of its own, so it can't
/// be `.interactive()` and take the press itself.
private struct ComposerVoicePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Motion.pressScale : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
