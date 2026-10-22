import SwiftUI
import WingcordCore

/// The profile's colours, as a flyout: one banner colour on a free account,
/// the two-colour theme on Nitro.
///
/// **One colour or two, and they are different fields** — `accent_color`, a
/// single integer anybody may set, and `theme_colors`, an array of exactly two
/// that Nitro may. So the flyout is not "the same control, unlocked": with a
/// theme it edits one stop at a time, with a swap between them.
struct ProfileColourFlyout: View {
    var editor: ProfileEditor

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    /// Which end of the theme the picker is on.
    @State private var stop = 0
    @State private var swapTurns = 0.0

    private var capability: ProfileEditCapability { model.profileEditCapability(for: editor.scope) }
    private var themed: Bool { capability.canEditCurrentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(themed ? "Profile Theme" : "Banner Colour")
                    .font(.system(.headline, weight: .bold))
                    .foregroundStyle(InkColor.primary)
                Spacer(minLength: Spacing.base)
                Button("Use Default") {
                    if themed { editor.themeColors = nil } else { editor.accentColor = nil }
                    Haptics.pop()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(themed ? editor.themeColors == nil : editor.accentColor == nil)
                .help(themed ? "Go back to the colours from your avatar" : "Go back to the colour from your avatar")
            }
            .padding([.horizontal, .top], Spacing.margin)
            if themed {
                stops
                    .padding(.horizontal, Spacing.margin)
                    .padding(.top, Spacing.snug)
            }
            PlayfulColourPicker(
                colour: binding,
                fromArtwork: model.artworkColours(of: editor.base),
                title: themed ? (stop == 0 ? "Primary" : "Accent") : nil
            )
            .id(themed ? stop : -1)
        }
        .frame(width: PlayfulColourPicker.width)
        .task { model.loadArtworkColours(of: editor.base) }
    }

    private var binding: Binding<UInt32> {
        if themed {
            Binding(get: { editor.themeStop(stop) }, set: { editor.setThemeStop(stop, to: $0) })
        } else {
            Binding(get: { editor.accentColor ?? editor.fallbackColour }, set: { editor.accentColor = $0 })
        }
    }

    /// The two ends, on the gradient they make, with a swap between them.
    private var stops: some View {
        HStack(spacing: Spacing.base) {
            stopChip(0, title: "Primary")
            Button {
                editor.swapThemeStops()
                swapTurns += 1
                Haptics.pop()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .rotationEffect(.degrees(swapTurns * 180))
                    .animation(motion.momentum, value: swapTurns)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help("Swap the two colours")
            .accessibilityLabel(Text("Swap the two colours"))
            stopChip(1, title: "Accent")
        }
        .padding(5)
        .background {
            Capsule().fill(.linearGradient(
                colors: [Color(hex: editor.themeStop(0)), Color(hex: editor.themeStop(1))],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .opacity(0.55)
        }
    }

    private func stopChip(_ index: Int, title: String) -> some View {
        let isCurrent = stop == index
        return Button {
            stop = index
            Haptics.tick()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: editor.themeStop(index)))
                    .overlay { Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2) }
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .glassEffect(isCurrent ? .regular.interactive() : .clear.interactive(), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .animation(motion.hover, value: isCurrent)
    }
}
