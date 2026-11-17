import SwiftUI
import WingcordCore

/// Discord's "Limited Time Font" (`f5b687ab`'s `eM`): the reader's own name set
/// in the Vice City campaign's face, on a wide tile, under the font grid
/// (docs/ACTIVITY-CARDS.md decision 4).
///
/// **The campaign's own colours, drawn here** — its theme's gradient
/// (`BG_GRADIENT_HEXAGON_1…4` at 135°) with Discord's 52 % shade toward the
/// foot for the words — rather than Discord's artwork fetched at run time.
struct ViceCityFontTile: View {
    var name: String
    var isSelected: Bool
    /// "Free for everyone until December 13, …".
    var terms: String
    /// Days left for this account, for the corner's count.
    var daysLeft: Int
    var pick: () -> Void

    @State private var isHovered = false

    private static let gradient = Gradient(stops: [
        .init(color: Color(hex: 0x4645FF), location: 0),
        .init(color: Color(hex: 0xAF01F3), location: 0.3333),
        .init(color: Color(hex: 0xFF6698), location: 0.6667),
        .init(color: Color(hex: 0xF89A03), location: 1),
    ])

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.tight) {
                Text("Limited Time Font")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                Spacer(minLength: 0)
                Text(daysLeft == 1 ? "1 day left" : "\(daysLeft) days left")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(InkColor.secondary)
                    .monospacedDigit()
            }
            Button(action: pick) {
                ZStack {
                    LinearGradient(gradient: Self.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                    LinearGradient(colors: [.clear, .black.opacity(0.42)], startPoint: .top, endPoint: .bottom)
                    StyledDisplayName(
                        text: name,
                        style: DisplayNameStyle(font: .hexagon, effect: .solid, colors: [0xFF_FF_FF]),
                        textStyle: .title2,
                        weight: .bold,
                        pointSize: 28
                    )
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .padding(.horizontal, Spacing.margin)
                }
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.white : Color.white.opacity(isHovered ? 0.4 : 0.16),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .contentShape(.rect(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Vice City")
            .accessibilityLabel(Text("Vice City font"))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            Text(terms)
                .font(.system(.caption))
                .foregroundStyle(InkColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
