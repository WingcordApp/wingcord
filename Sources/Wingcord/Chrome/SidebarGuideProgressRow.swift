import SwiftUI

/// "Get Started · 3 of 5 ›" over a green bar, at the top of a new member's
/// channel list (Discord's `GUILD_NEW_MEMBER_ACTIONS_PROGRESS_BAR`): the
/// server's guide, and how far through its steps the reader is. Opens the
/// guide.
struct SidebarGuideProgressRow: View {
    var progress: SidebarGuideProgress
    var open: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    /// Discord's green, light to lighter (`GREEN_300` → `GREEN_230`).
    private static let bar = [
        Color(red: 0.35, green: 0.80, blue: 0.47),
        Color(red: 0.55, green: 0.88, blue: 0.62),
    ]

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Get Started")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    Spacer(minLength: 8)
                    (Text("\(progress.completed)").fontWeight(.semibold).foregroundStyle(Ink.primary)
                        + Text(" of ").foregroundStyle(Ink.tertiary)
                        + Text("\(progress.total)").fontWeight(.semibold).foregroundStyle(Ink.primary))
                        .font(.system(.caption))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill(LinearGradient(colors: Self.bar, startPoint: .leading, endPoint: .trailing))
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 6)
                .animation(motion.standard, value: fraction)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SidebarRowGeometry.highlightOutset.leading)
        .padding(.bottom, Spacing.base)
        .onHover { isHovering = $0 }
        .animation(motion.hover, value: isHovering)
        .accessibilityLabel("Get Started, \(progress.completed) of \(progress.total) done")
        .accessibilityHint("Opens the Server Guide")
    }

    /// Discord adds three points so an untouched bar still shows a sliver.
    private var fraction: CGFloat {
        guard progress.total > 0 else { return 0 }
        return min(1, (CGFloat(progress.completed) / CGFloat(progress.total)) + 0.03)
    }
}
